mod auth;
mod credentials;
mod error;
mod models;
mod soundcloud;
mod state;
mod storage;

use crate::{
    auth::{PendingAuth, bind_callback_server, wait_for_callback},
    credentials::{CLIENT_ID, CLIENT_SECRET},
    error::CommandError,
    models::{PlaybackSource, SessionState, TrackSummary, WaveformData},
    soundcloud::SoundCloudClient,
    state::AppState,
    storage::SessionStore,
};
use tauri::{AppHandle, Manager, State};
use tauri_plugin_opener::OpenerExt;
use url::Url;

#[tauri::command]
async fn get_session(state: State<'_, AppState>) -> Result<SessionState, CommandError> {
    state.session().await
}

#[tauri::command]
async fn begin_login(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<SessionState, CommandError> {
    let _login_guard = state.login_lock.try_lock().map_err(|_| {
        CommandError::new(
            "auth_in_progress",
            "A SoundCloud sign-in request is already active.",
        )
    })?;

    let callback_server = bind_callback_server()?;
    let pending = PendingAuth::new();
    let authorization_url = state
        .client
        .authorization_url(&pending.state, &pending.challenge);
    app.opener()
        .open_url(authorization_url.as_str(), None::<&str>)
        .map_err(|_| {
            CommandError::new(
                "browser_failed",
                "The system browser could not be opened for SoundCloud sign-in.",
            )
        })?;

    let expected_state = pending.state.clone();
    let code = tauri::async_runtime::spawn_blocking(move || {
        wait_for_callback(callback_server, &expected_state)
    })
    .await
    .map_err(|_| CommandError::new("callback_failed", "The sign-in callback task stopped."))??;

    let token = state
        .client
        .exchange_code(&code, &pending.verifier)
        .await
        .map_err(|error| error.into_command())?;
    let access_token = token.access_token.clone();
    state.save_new_token(token).await?;

    let user = state
        .client
        .me(&access_token)
        .await
        .map_err(|error| error.into_command())?;
    state.save_user(user.clone()).await?;
    Ok(SessionState::signed_in(user))
}

#[tauri::command]
async fn get_liked_tracks(state: State<'_, AppState>) -> Result<Vec<TrackSummary>, CommandError> {
    let client = state.client.clone();
    let liked = state
        .authenticated(move |token| {
            let client = client.clone();
            async move { client.liked_tracks(&token).await }
        })
        .await?;
    {
        let mut known = state.known_tracks.write().await;
        known.clear();
        known.extend(liked.tracks.iter().map(|track| track.urn.clone()));
    }
    {
        let mut secrets = state.track_secret_tokens.write().await;
        *secrets = liked.secret_tokens;
    }
    Ok(liked.tracks)
}

#[tauri::command]
async fn resolve_playback(
    track_urn: String,
    state: State<'_, AppState>,
) -> Result<PlaybackSource, CommandError> {
    if !state.known_tracks.read().await.contains(&track_urn) {
        return Err(CommandError::new(
            "invalid_track",
            "Select a track from the current liked-track list.",
        ));
    }
    let secret_token = state
        .track_secret_tokens
        .read()
        .await
        .get(&track_urn)
        .cloned();
    let client = state.client.clone();
    state
        .authenticated(move |token| {
            let client = client.clone();
            let track_urn = track_urn.clone();
            let secret_token = secret_token.clone();
            async move {
                client
                    .resolve_playback(&token, &track_urn, secret_token.as_deref())
                    .await
            }
        })
        .await
}

#[tauri::command]
async fn get_waveform(
    waveform_url: String,
    state: State<'_, AppState>,
) -> Result<WaveformData, CommandError> {
    state
        .client
        .waveform(&waveform_url)
        .await
        .map_err(|error| error.into_command())
}

#[tauri::command]
async fn sign_out(state: State<'_, AppState>) -> Result<(), CommandError> {
    if let Some(record) = state.store.load()? {
        let _ = state.client.sign_out(&record.access_token).await;
    }
    state.store.delete()?;
    state.known_tracks.write().await.clear();
    state.track_secret_tokens.write().await.clear();
    Ok(())
}

#[tauri::command]
fn open_soundcloud_url(url: String, app: AppHandle) -> Result<(), CommandError> {
    let parsed = Url::parse(&url)
        .map_err(|_| CommandError::new("invalid_url", "The SoundCloud link is invalid."))?;
    let allowed = parsed.scheme() == "https"
        && parsed
            .host_str()
            .is_some_and(|host| host == "soundcloud.com" || host.ends_with(".soundcloud.com"));
    if !allowed {
        return Err(CommandError::new(
            "invalid_url",
            "Only secure SoundCloud links can be opened.",
        ));
    }
    app.opener()
        .open_url(parsed.as_str(), None::<&str>)
        .map_err(|_| {
            CommandError::new("browser_failed", "The SoundCloud link could not be opened.")
        })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let client = SoundCloudClient::production(CLIENT_ID, CLIENT_SECRET);
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(move |app| {
            let session_path = app.path().app_data_dir()?.join("oauth-session.json");
            app.manage(AppState::new(
                client.clone(),
                SessionStore::new(session_path),
            ));
            #[cfg(debug_assertions)]
            app.get_webview_window("main").unwrap().open_devtools();
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_session,
            begin_login,
            get_liked_tracks,
            resolve_playback,
            get_waveform,
            sign_out,
            open_soundcloud_url
        ])
        .run(tauri::generate_context!())
        .expect("error while running SoundClaude");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn external_url_validation_rejects_lookalike_hosts() {
        let good = Url::parse("https://soundcloud.com/user/track").unwrap();
        let bad = Url::parse("https://soundcloud.com.evil.example/user/track").unwrap();
        let allowed = |url: &Url| {
            url.scheme() == "https"
                && url.host_str().is_some_and(|host| {
                    host == "soundcloud.com" || host.ends_with(".soundcloud.com")
                })
        };
        assert!(allowed(&good));
        assert!(!allowed(&bad));
    }
}
