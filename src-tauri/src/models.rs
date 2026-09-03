use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct UserSummary {
    pub username: String,
    pub avatar_url: Option<String>,
    pub permalink_url: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionState {
    pub authenticated: bool,
    pub user: Option<UserSummary>,
}

impl SessionState {
    pub fn signed_out() -> Self {
        Self {
            authenticated: false,
            user: None,
        }
    }

    pub fn signed_in(user: UserSummary) -> Self {
        Self {
            authenticated: true,
            user: Some(user),
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TrackSummary {
    pub urn: String,
    pub title: String,
    pub uploader: String,
    pub artwork_url: Option<String>,
    pub waveform_url: Option<String>,
    pub permalink_url: String,
    pub uploader_permalink_url: String,
    pub duration_ms: u64,
    pub access: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackSource {
    pub url: String,
    pub kind: String,
    pub codec: String,
    pub bitrate_kbps: u16,
    pub is_preview: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WaveformData {
    pub height: f32,
    pub samples: Vec<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TokenRecord {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: u64,
    pub user: Option<UserSummary>,
}
