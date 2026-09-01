use crate::error::CommandError;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};
use tiny_http::{Header, Request, Response, Server, StatusCode};
use url::Url;
use uuid::Uuid;

pub const CALLBACK_ADDRESS: &str = "127.0.0.1:32148";
pub const REDIRECT_URI: &str = "http://127.0.0.1:32148/callback";
const CALLBACK_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Debug)]
pub struct PendingAuth {
    pub state: String,
    pub verifier: String,
    pub challenge: String,
}

impl PendingAuth {
    pub fn new() -> Self {
        let verifier = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        Self {
            state: Uuid::new_v4().simple().to_string(),
            verifier,
            challenge,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum CallbackResult {
    Code(String),
    Cancelled(String),
    Ignore,
    InvalidState,
}

pub fn bind_callback_server() -> Result<Server, CommandError> {
    Server::http(CALLBACK_ADDRESS).map_err(|_| {
        CommandError::new(
            "callback_port_in_use",
            "The sign-in callback port 32148 is already in use. Close the other process and try again.",
        )
    })
}

pub fn wait_for_callback(server: Server, expected_state: &str) -> Result<String, CommandError> {
    let deadline = Instant::now() + CALLBACK_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(CommandError::new(
                "auth_timeout",
                "SoundCloud sign-in timed out. Try again.",
            ));
        }

        let Some(request) = server.recv_timeout(remaining).map_err(|_| {
            CommandError::new(
                "callback_failed",
                "The sign-in callback could not be received.",
            )
        })?
        else {
            return Err(CommandError::new(
                "auth_timeout",
                "SoundCloud sign-in timed out. Try again.",
            ));
        };

        match parse_callback(request.url(), expected_state) {
            CallbackResult::Code(code) => {
                respond(
                    request,
                    StatusCode(200),
                    "Authorization received",
                    "Return to SoundClaude to finish sign-in.",
                );
                return Ok(code);
            }
            CallbackResult::Cancelled(message) => {
                respond(
                    request,
                    StatusCode(400),
                    "Authorization cancelled",
                    "Return to SoundClaude and try again when you are ready.",
                );
                return Err(CommandError::new("auth_cancelled", message));
            }
            CallbackResult::InvalidState => {
                respond(
                    request,
                    StatusCode(400),
                    "Invalid authorization response",
                    "This response did not match the active sign-in request.",
                );
            }
            CallbackResult::Ignore => {
                respond(
                    request,
                    StatusCode(404),
                    "Not found",
                    "This local address is only used for SoundCloud sign-in.",
                );
            }
        }
    }
}

pub fn parse_callback(request_target: &str, expected_state: &str) -> CallbackResult {
    let Ok(url) = Url::parse(&format!("http://{CALLBACK_ADDRESS}{request_target}")) else {
        return CallbackResult::Ignore;
    };
    if url.path() != "/callback" {
        return CallbackResult::Ignore;
    }

    let parameters: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
    if parameters.get("state").map(String::as_str) != Some(expected_state) {
        return CallbackResult::InvalidState;
    }
    if let Some(error) = parameters.get("error") {
        let description = parameters
            .get("error_description")
            .cloned()
            .unwrap_or_else(|| error.clone());
        return CallbackResult::Cancelled(description);
    }
    parameters
        .get("code")
        .cloned()
        .map(CallbackResult::Code)
        .unwrap_or(CallbackResult::Ignore)
}

fn respond(request: Request, status: StatusCode, title: &str, message: &str) {
    let body = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>{title}</title><style>body{{font-family:-apple-system,sans-serif;max-width:520px;margin:80px auto;padding:24px;line-height:1.5}}h1{{color:#f50}}</style></head><body><h1>{title}</h1><p>{message}</p></body></html>"
    );
    let mut response = Response::from_string(body).with_status_code(status);
    if let Ok(header) = Header::from_bytes("Content-Type", "text/html; charset=utf-8") {
        response.add_header(header);
    }
    let _ = request.respond(response);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_values_have_expected_shapes() {
        let pending = PendingAuth::new();
        assert_eq!(pending.verifier.len(), 64);
        assert_eq!(pending.state.len(), 32);
        assert_eq!(pending.challenge.len(), 43);
    }

    #[test]
    fn callback_requires_path_and_matching_state() {
        assert_eq!(
            parse_callback("/callback?code=abc&state=right", "right"),
            CallbackResult::Code("abc".into())
        );
        assert_eq!(
            parse_callback("/callback?code=abc&state=wrong", "right"),
            CallbackResult::InvalidState
        );
        assert_eq!(
            parse_callback("/favicon.ico", "right"),
            CallbackResult::Ignore
        );
    }

    #[test]
    fn callback_reports_authorization_error() {
        assert_eq!(
            parse_callback(
                "/callback?error=access_denied&error_description=Nope&state=right",
                "right"
            ),
            CallbackResult::Cancelled("Nope".into())
        );
    }
}
