use crate::{
    auth::REDIRECT_URI,
    error::CommandError,
    models::{PlaybackSource, TrackSummary, UserSummary, WaveformData},
};
use reqwest::{Client, RequestBuilder, Response, StatusCode, header, redirect::Policy};
use serde::Deserialize;
use std::{collections::HashMap, time::Duration};
use url::Url;

const API_BASE: &str = "https://api.soundcloud.com/";
const AUTHORIZE_URL: &str = "https://secure.soundcloud.com/authorize";
const TOKEN_URL: &str = "https://secure.soundcloud.com/oauth/token";
const SIGN_OUT_URL: &str = "https://secure.soundcloud.com/sign-out";
const LIKED_TRACK_LIMIT: &str = "100";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScErrorKind {
    Unauthorized,
    RateLimited,
    Network,
    Api,
    PlaybackUnavailable,
}

#[derive(Debug)]
pub struct ScError {
    pub kind: ScErrorKind,
    message: String,
}

impl ScError {
    fn new(kind: ScErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    async fn from_response(response: Response) -> Self {
        let status = response.status();
        if status == StatusCode::UNAUTHORIZED {
            return Self::new(
                ScErrorKind::Unauthorized,
                "The SoundCloud session has expired.",
            );
        }
        if status == StatusCode::TOO_MANY_REQUESTS {
            return Self::new(
                ScErrorKind::RateLimited,
                "SoundCloud is rate limiting requests. Wait a moment and try again.",
            );
        }
        let message = response
            .json::<ApiErrorBody>()
            .await
            .ok()
            .and_then(|body| body.message)
            .filter(|message| !message.trim().is_empty())
            .unwrap_or_else(|| format!("SoundCloud returned HTTP {status}."));
        Self::new(ScErrorKind::Api, message)
    }

    pub fn into_command(self) -> CommandError {
        match self.kind {
            ScErrorKind::Unauthorized => CommandError::not_authenticated(),
            ScErrorKind::RateLimited => CommandError::new("rate_limited", self.message),
            ScErrorKind::Network => CommandError::network(self.message),
            ScErrorKind::PlaybackUnavailable => {
                CommandError::new("playback_unavailable", self.message)
            }
            ScErrorKind::Api => CommandError::new("api", self.message),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SoundCloudClient {
    http: Client,
    api_base: Url,
    authorize_url: Url,
    token_url: Url,
    sign_out_url: Url,
    client_id: String,
    client_secret: String,
}

#[derive(Debug, Deserialize)]
pub struct TokenResponse {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_in: u64,
}

#[derive(Debug)]
pub struct LikedTracks {
    pub tracks: Vec<TrackSummary>,
    pub secret_tokens: HashMap<String, String>,
}

impl SoundCloudClient {
    pub fn production(client_id: &str, client_secret: &str) -> Self {
        Self::new(
            client_id,
            client_secret,
            Url::parse(API_BASE).expect("valid SoundCloud API URL"),
            Url::parse(AUTHORIZE_URL).expect("valid SoundCloud authorization URL"),
            Url::parse(TOKEN_URL).expect("valid SoundCloud token URL"),
            Url::parse(SIGN_OUT_URL).expect("valid SoundCloud sign-out URL"),
        )
    }

    fn new(
        client_id: &str,
        client_secret: &str,
        api_base: Url,
        authorize_url: Url,
        token_url: Url,
        sign_out_url: Url,
    ) -> Self {
        let http = Client::builder()
            .redirect(Policy::none())
            .build()
            .expect("HTTP client can be created");
        Self {
            http,
            api_base,
            authorize_url,
            token_url,
            sign_out_url,
            client_id: client_id.to_owned(),
            client_secret: client_secret.to_owned(),
        }
    }

    #[cfg(test)]
    fn test(client_id: &str, client_secret: &str, base: &str) -> Self {
        let base = Url::parse(&format!("{}/", base.trim_end_matches('/'))).unwrap();
        Self::new(
            client_id,
            client_secret,
            base.clone(),
            base.join("authorize").unwrap(),
            base.join("oauth/token").unwrap(),
            base.join("sign-out").unwrap(),
        )
    }

    pub fn authorization_url(&self, state: &str, challenge: &str) -> Url {
        let mut url = self.authorize_url.clone();
        url.query_pairs_mut()
            .append_pair("client_id", &self.client_id)
            .append_pair("redirect_uri", REDIRECT_URI)
            .append_pair("response_type", "code")
            .append_pair("code_challenge", challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", state);
        url
    }

    pub async fn exchange_code(
        &self,
        code: &str,
        verifier: &str,
    ) -> Result<TokenResponse, ScError> {
        self.token_request(
            &[
                ("grant_type", "authorization_code"),
                ("client_id", self.client_id.as_str()),
                ("client_secret", self.client_secret.as_str()),
                ("redirect_uri", REDIRECT_URI),
                ("code_verifier", verifier),
                ("code", code),
            ],
            false,
        )
        .await
    }

    pub async fn refresh(&self, refresh_token: &str) -> Result<TokenResponse, ScError> {
        self.token_request(
            &[
                ("grant_type", "refresh_token"),
                ("client_id", self.client_id.as_str()),
                ("client_secret", self.client_secret.as_str()),
                ("refresh_token", refresh_token),
            ],
            true,
        )
        .await
    }

    async fn token_request(
        &self,
        form: &[(&str, &str)],
        is_refresh: bool,
    ) -> Result<TokenResponse, ScError> {
        let response = self
            .send(
                self.http
                    .post(self.token_url.clone())
                    .header(header::ACCEPT, "application/json; charset=utf-8")
                    .form(form),
            )
            .await?;
        if !response.status().is_success() {
            if is_refresh
                && matches!(
                    response.status(),
                    StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
                )
            {
                return Err(ScError::new(
                    ScErrorKind::Unauthorized,
                    "The saved SoundCloud session is no longer valid.",
                ));
            }
            return Err(ScError::from_response(response).await);
        }
        let token = response.json::<TokenResponse>().await.map_err(|_| {
            ScError::new(
                ScErrorKind::Api,
                "SoundCloud returned an invalid token response.",
            )
        })?;
        if token
            .refresh_token
            .as_deref()
            .unwrap_or_default()
            .is_empty()
        {
            return Err(ScError::new(
                ScErrorKind::Api,
                "SoundCloud did not return a refresh token.",
            ));
        }
        Ok(token)
    }

    pub async fn me(&self, access_token: &str) -> Result<UserSummary, ScError> {
        let response = self
            .send(
                self.http
                    .get(self.api_url(&["me"])?)
                    .header(header::ACCEPT, "application/json; charset=utf-8")
                    .header(header::AUTHORIZATION, oauth_header(access_token)),
            )
            .await?;
        if !response.status().is_success() {
            return Err(ScError::from_response(response).await);
        }
        let user = response.json::<RawUser>().await.map_err(|_| {
            ScError::new(ScErrorKind::Api, "SoundCloud returned invalid user data.")
        })?;
        user.into_summary()
    }

    pub async fn liked_tracks(&self, access_token: &str) -> Result<LikedTracks, ScError> {
        let response = self
            .send(
                self.http
                    .get(self.api_url(&["me", "likes", "tracks"])?)
                    .header(header::ACCEPT, "application/json; charset=utf-8")
                    .header(header::AUTHORIZATION, oauth_header(access_token))
                    .query(&[
                        ("limit", LIKED_TRACK_LIMIT),
                        ("linked_partitioning", "true"),
                        ("access", "playable,preview"),
                    ]),
            )
            .await?;
        if !response.status().is_success() {
            return Err(ScError::from_response(response).await);
        }
        let payload = response.json::<TracksPayload>().await.map_err(|_| {
            ScError::new(ScErrorKind::Api, "SoundCloud returned invalid track data.")
        })?;
        Ok(map_tracks(payload.into_tracks()))
    }

    pub async fn resolve_playback(
        &self,
        access_token: &str,
        track_urn: &str,
        secret_token: Option<&str>,
    ) -> Result<PlaybackSource, ScError> {
        let mut url = self.api_url(&["tracks", track_urn, "streams"])?;
        if let Some(secret_token) = secret_token {
            url.query_pairs_mut()
                .append_pair("secret_token", secret_token);
        }
        let response = self
            .send(
                self.http
                    .get(url)
                    .header(header::ACCEPT, "application/json; charset=utf-8")
                    .header(header::AUTHORIZATION, oauth_header(access_token)),
            )
            .await?;
        if !response.status().is_success() {
            return Err(ScError::from_response(response).await);
        }
        let streams = response.json::<RawStreams>().await.map_err(|_| {
            ScError::new(ScErrorKind::Api, "SoundCloud returned invalid stream data.")
        })?;

        let candidates = [
            streams
                .hls_aac_160_url
                .map(|url| (url, "hls", "aac", 160, false)),
            streams
                .hls_mp3_128_url
                .map(|url| (url, "hls", "mp3", 128, false)),
            streams
                .preview_mp3_128_url
                .map(|url| (url, "mp3", "mp3", 128, true)),
        ];
        for candidate in candidates.into_iter().flatten() {
            match self.stream_redirect(access_token, &candidate.0).await {
                Ok(url) => {
                    return Ok(PlaybackSource {
                        url,
                        kind: candidate.1.to_owned(),
                        codec: candidate.2.to_owned(),
                        bitrate_kbps: candidate.3,
                        is_preview: candidate.4,
                    });
                }
                Err(error)
                    if matches!(
                        error.kind,
                        ScErrorKind::Unauthorized | ScErrorKind::RateLimited | ScErrorKind::Network
                    ) =>
                {
                    return Err(error);
                }
                Err(_) => continue,
            }
        }
        Err(ScError::new(
            ScErrorKind::PlaybackUnavailable,
            "This track is not available for off-platform playback.",
        ))
    }

    async fn stream_redirect(
        &self,
        access_token: &str,
        stream_url: &str,
    ) -> Result<String, ScError> {
        let stream_url = Url::parse(stream_url).map_err(|_| {
            ScError::new(
                ScErrorKind::Api,
                "SoundCloud returned an invalid stream URL.",
            )
        })?;
        if !cfg!(test)
            && (stream_url.scheme() != "https"
                || stream_url.host_str() != Some("api.soundcloud.com"))
        {
            return Err(ScError::new(
                ScErrorKind::Api,
                "SoundCloud returned an unexpected stream URL.",
            ));
        }
        let response = self
            .send(
                self.http
                    .head(stream_url)
                    .header(header::AUTHORIZATION, oauth_header(access_token)),
            )
            .await?;
        if response.status() == StatusCode::UNAUTHORIZED {
            return Err(ScError::new(
                ScErrorKind::Unauthorized,
                "The SoundCloud session has expired.",
            ));
        }
        if response.status() == StatusCode::TOO_MANY_REQUESTS {
            return Err(ScError::new(
                ScErrorKind::RateLimited,
                "SoundCloud is rate limiting playback. Wait a moment and try again.",
            ));
        }
        if !response.status().is_redirection() {
            return Err(ScError::new(
                ScErrorKind::PlaybackUnavailable,
                "The selected SoundCloud stream is unavailable.",
            ));
        }
        let location = response
            .headers()
            .get(header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .ok_or_else(|| {
                ScError::new(
                    ScErrorKind::Api,
                    "SoundCloud returned no playback location.",
                )
            })?;
        validate_cdn_url(location)
    }

    pub async fn sign_out(&self, access_token: &str) -> Result<(), ScError> {
        let response = self
            .send(
                self.http
                    .post(self.sign_out_url.clone())
                    .json(&serde_json::json!({ "access_token": access_token })),
            )
            .await?;
        if response.status().is_success() || response.status() == StatusCode::UNAUTHORIZED {
            Ok(())
        } else {
            Err(ScError::from_response(response).await)
        }
    }

    pub async fn waveform(&self, waveform_url: &str) -> Result<WaveformData, ScError> {
        let waveform_url = validate_waveform_url(waveform_url)?;
        let response = self
            .send(
                self.http
                    .get(waveform_url)
                    .header(header::ACCEPT, "application/json; charset=utf-8"),
            )
            .await?;
        if !response.status().is_success() {
            return Err(ScError::from_response(response).await);
        }
        let waveform = response.json::<WaveformData>().await.map_err(|_| {
            ScError::new(
                ScErrorKind::Api,
                "SoundCloud returned invalid waveform data.",
            )
        })?;
        if !waveform.height.is_finite()
            || waveform.height <= 0.0
            || waveform.samples.is_empty()
            || waveform
                .samples
                .iter()
                .any(|sample| !sample.is_finite() || *sample < 0.0)
        {
            return Err(ScError::new(
                ScErrorKind::Api,
                "SoundCloud returned invalid waveform data.",
            ));
        }
        Ok(waveform)
    }

    fn api_url(&self, segments: &[&str]) -> Result<Url, ScError> {
        let mut url = self.api_base.clone();
        url.path_segments_mut()
            .map_err(|_| ScError::new(ScErrorKind::Api, "The SoundCloud API URL is invalid."))?
            .clear()
            .extend(segments);
        Ok(url)
    }

    async fn send(&self, builder: RequestBuilder) -> Result<Response, ScError> {
        let request = builder.build().map_err(network_error)?;
        for attempt in 0..3_u32 {
            if attempt > 0 {
                let delay_ms = 250_u64.saturating_mul(2_u64.pow(attempt - 1));
                tokio::time::sleep(Duration::from_millis(delay_ms)).await;
            }
            let next_request = request.try_clone().ok_or_else(|| {
                ScError::new(
                    ScErrorKind::Api,
                    "The SoundCloud request could not be retried.",
                )
            })?;
            let response = self
                .http
                .execute(next_request)
                .await
                .map_err(network_error)?;
            if response.status() != StatusCode::TOO_MANY_REQUESTS || attempt == 2 {
                return Ok(response);
            }
        }
        unreachable!("the bounded retry loop always returns")
    }
}

fn oauth_header(token: &str) -> String {
    format!("OAuth {token}")
}

fn network_error(_: reqwest::Error) -> ScError {
    ScError::new(
        ScErrorKind::Network,
        "SoundCloud could not be reached. Check your connection and try again.",
    )
}

fn validate_cdn_url(value: &str) -> Result<String, ScError> {
    let url = Url::parse(value).map_err(|_| {
        ScError::new(
            ScErrorKind::Api,
            "SoundCloud returned an invalid playback URL.",
        )
    })?;
    let allowed = url.scheme() == "https"
        && url.host_str().is_some_and(|host| {
            host == "sndcdn.com"
                || host.ends_with(".sndcdn.com")
                || host == "playback.media-streaming.soundcloud.cloud"
        });
    if !allowed {
        return Err(ScError::new(
            ScErrorKind::Api,
            "SoundCloud returned an unexpected playback host.",
        ));
    }
    Ok(url.into())
}

fn validate_waveform_url(value: &str) -> Result<Url, ScError> {
    let mut url = Url::parse(value).map_err(|_| {
        ScError::new(
            ScErrorKind::Api,
            "SoundCloud returned an invalid waveform URL.",
        )
    })?;
    let allowed = url.scheme() == "https"
        && url.host_str() == Some("wave.sndcdn.com")
        && (url.path().ends_with(".json") || url.path().ends_with(".png"));
    if !allowed {
        return Err(ScError::new(
            ScErrorKind::Api,
            "SoundCloud returned an unexpected waveform URL.",
        ));
    }
    if let Some(path) = url
        .path()
        .strip_suffix(".png")
        .map(|path| format!("{path}.json"))
    {
        url.set_path(&path);
    }
    Ok(url)
}

#[derive(Debug, Deserialize)]
struct ApiErrorBody {
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawUser {
    username: Option<String>,
    avatar_url: Option<String>,
    permalink_url: Option<String>,
}

impl RawUser {
    fn into_summary(self) -> Result<UserSummary, ScError> {
        Ok(UserSummary {
            username: self.username.ok_or_else(|| {
                ScError::new(ScErrorKind::Api, "SoundCloud user data has no username.")
            })?,
            avatar_url: self.avatar_url,
            permalink_url: self.permalink_url.ok_or_else(|| {
                ScError::new(ScErrorKind::Api, "SoundCloud user data has no profile URL.")
            })?,
        })
    }
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum TracksPayload {
    Linked { collection: Vec<RawTrack> },
    List(Vec<RawTrack>),
}

impl TracksPayload {
    fn into_tracks(self) -> Vec<RawTrack> {
        match self {
            Self::Linked { collection } => collection,
            Self::List(tracks) => tracks,
        }
    }
}

#[derive(Debug, Deserialize)]
struct RawTrack {
    urn: Option<String>,
    title: Option<String>,
    artwork_url: Option<String>,
    waveform_url: Option<String>,
    permalink_url: Option<String>,
    duration: Option<u64>,
    access: Option<String>,
    secret_uri: Option<String>,
    user: Option<RawUser>,
}

fn map_tracks(raw_tracks: Vec<RawTrack>) -> LikedTracks {
    let mut tracks = Vec::new();
    let mut secret_tokens = HashMap::new();
    for raw in raw_tracks {
        let Some(urn) = raw.urn else { continue };
        let access = raw.access.unwrap_or_else(|| "blocked".into());
        if access != "playable" && access != "preview" {
            continue;
        }
        let Some(user) = raw.user else { continue };
        let (Some(title), Some(permalink_url), Some(uploader), Some(uploader_permalink_url)) = (
            raw.title,
            raw.permalink_url,
            user.username,
            user.permalink_url,
        ) else {
            continue;
        };
        if let Some(token) = raw.secret_uri.as_deref().and_then(extract_secret_token) {
            secret_tokens.insert(urn.clone(), token);
        }
        tracks.push(TrackSummary {
            urn,
            title,
            uploader,
            artwork_url: raw.artwork_url,
            waveform_url: raw.waveform_url,
            permalink_url,
            uploader_permalink_url,
            duration_ms: raw.duration.unwrap_or_default(),
            access,
        });
    }
    LikedTracks {
        tracks,
        secret_tokens,
    }
}

fn extract_secret_token(secret_uri: &str) -> Option<String> {
    let url = Url::parse(secret_uri).ok()?;
    if let Some(token) = url
        .query_pairs()
        .find_map(|(key, value)| (key == "secret_token").then(|| value.into_owned()))
    {
        return Some(token);
    }
    url.path_segments()?
        .rev()
        .find(|segment| segment.starts_with("s-"))
        .map(str::to_owned)
}

#[derive(Debug, Deserialize)]
struct RawStreams {
    hls_aac_160_url: Option<String>,
    hls_mp3_128_url: Option<String>,
    preview_mp3_128_url: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use httpmock::prelude::*;

    #[test]
    fn authorization_url_has_pkce_and_no_secret() {
        let client = SoundCloudClient::production("client", "do-not-leak");
        let url = client.authorization_url("state", "challenge");
        let query: HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(query.get("client_id").map(String::as_str), Some("client"));
        assert_eq!(
            query.get("code_challenge_method").map(String::as_str),
            Some("S256")
        );
        assert_eq!(query.get("state").map(String::as_str), Some("state"));
        assert!(!url.as_str().contains("do-not-leak"));
    }

    #[test]
    fn only_soundcloud_cdn_urls_are_accepted() {
        assert!(
            validate_cdn_url("https://cf-hls-media.sndcdn.com/path/file.m3u8?Policy=x").is_ok()
        );
        assert!(
            validate_cdn_url(
                "https://playback.media-streaming.soundcloud.cloud/track/aac_160k/id/playlist.m3u8"
            )
            .is_ok()
        );
        assert!(validate_cdn_url("http://cf-hls-media.sndcdn.com/file").is_err());
        assert!(validate_cdn_url("https://sndcdn.com.evil.example/file").is_err());
        assert!(
            validate_cdn_url("https://playback.media-streaming.soundcloud.cloud.evil.example/file")
                .is_err()
        );
    }

    #[test]
    fn only_soundcloud_waveform_urls_are_accepted() {
        assert_eq!(
            validate_waveform_url("https://wave.sndcdn.com/4bpxiWndwaCM_m.json")
                .unwrap()
                .as_str(),
            "https://wave.sndcdn.com/4bpxiWndwaCM_m.json"
        );
        assert_eq!(
            validate_waveform_url("https://wave.sndcdn.com/4bpxiWndwaCM_m.png")
                .unwrap()
                .as_str(),
            "https://wave.sndcdn.com/4bpxiWndwaCM_m.json"
        );
        assert!(validate_waveform_url("http://wave.sndcdn.com/4bpxiWndwaCM_m.json").is_err());
        assert!(validate_waveform_url("https://wave.sndcdn.com.evil.example/test_m.json").is_err());
        assert!(validate_waveform_url("https://other.sndcdn.com/test_m.json").is_err());
    }

    #[test]
    fn private_track_tokens_are_extracted() {
        assert_eq!(
            extract_secret_token("https://soundcloud.com/user/private-track/s-AbCd12"),
            Some("s-AbCd12".into())
        );
    }

    #[tokio::test]
    async fn liked_tracks_use_oauth_header_and_map_collection() {
        let server = MockServer::start();
        let request = server.mock(|when, then| {
            when.method(GET)
                .path("/me/likes/tracks")
                .header("authorization", "OAuth access")
                .query_param("limit", LIKED_TRACK_LIMIT)
                .query_param("linked_partitioning", "true")
                .query_param("access", "playable,preview");
            then.status(200).json_body(serde_json::json!({
                "collection": [{
                    "urn": "soundcloud:tracks:1",
                    "title": "Track",
                    "artwork_url": null,
                    "waveform_url": "https://wave.sndcdn.com/test_m.png",
                    "permalink_url": "https://soundcloud.com/u/t",
                    "duration": 1234,
                    "access": "playable",
                    "user": {
                        "username": "Uploader",
                        "avatar_url": null,
                        "permalink_url": "https://soundcloud.com/u"
                    }
                }],
                "next_href": null
            }));
        });
        let client = SoundCloudClient::test("id", "secret", &server.base_url());
        let result = client.liked_tracks("access").await.unwrap();
        request.assert();
        assert_eq!(result.tracks.len(), 1);
        assert_eq!(result.tracks[0].uploader, "Uploader");
        assert_eq!(
            result.tracks[0].waveform_url.as_deref(),
            Some("https://wave.sndcdn.com/test_m.png")
        );
    }

    #[tokio::test]
    async fn playback_uses_authenticated_head_and_returns_only_cdn_url() {
        let server = MockServer::start();
        let stream_endpoint = format!("{}/stream-endpoint", server.base_url());
        let streams_request = server.mock(|when, then| {
            when.method(GET)
                .path("/tracks/soundcloud:tracks:1/streams")
                .header("authorization", "OAuth access");
            then.status(200).json_body(serde_json::json!({
                "hls_aac_160_url": stream_endpoint
            }));
        });
        let head_request = server.mock(|when, then| {
            when.method(Method::HEAD)
                .path("/stream-endpoint")
                .header("authorization", "OAuth access");
            then.status(302).header(
                "location",
                "https://cf-hls-media.sndcdn.com/stream.m3u8?Policy=signed",
            );
        });
        let client = SoundCloudClient::test("id", "secret", &server.base_url());

        let source = client
            .resolve_playback("access", "soundcloud:tracks:1", None)
            .await;

        streams_request.assert();
        head_request.assert();
        let source = source.unwrap();
        assert_eq!(source.kind, "hls");
        assert_eq!(source.codec, "aac");
        assert_eq!(source.bitrate_kbps, 160);
        assert!(!source.is_preview);
        assert!(source.url.starts_with("https://cf-hls-media.sndcdn.com/"));
    }

    #[tokio::test]
    async fn playback_accepts_the_soundcloud_aac_host() {
        let server = MockServer::start();
        let stream_endpoint = format!("{}/stream-endpoint", server.base_url());
        server.mock(|when, then| {
            when.method(GET).path("/tracks/soundcloud:tracks:1/streams");
            then.status(200).json_body(serde_json::json!({
                "hls_aac_160_url": stream_endpoint
            }));
        });
        server.mock(|when, then| {
            when.method(Method::HEAD).path("/stream-endpoint");
            then.status(302).header(
                "location",
                "https://playback.media-streaming.soundcloud.cloud/track/aac_160k/id/playlist.m3u8",
            );
        });
        let client = SoundCloudClient::test("id", "secret", &server.base_url());

        let source = client
            .resolve_playback("access", "soundcloud:tracks:1", None)
            .await
            .unwrap();

        assert_eq!(source.codec, "aac");
        assert_eq!(source.bitrate_kbps, 160);
    }
}
