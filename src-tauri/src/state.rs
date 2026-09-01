use crate::{
    error::CommandError,
    models::{SessionState, TokenRecord, UserSummary},
    soundcloud::{ScError, ScErrorKind, SoundCloudClient, TokenResponse},
    storage::SessionStore,
};
use std::{
    collections::{HashMap, HashSet},
    future::Future,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::{Mutex, RwLock};

const EXPIRY_MARGIN_SECONDS: u64 = 60;

pub struct AppState {
    pub client: SoundCloudClient,
    pub store: SessionStore,
    pub token_lock: Mutex<()>,
    pub login_lock: Mutex<()>,
    pub track_secret_tokens: RwLock<HashMap<String, String>>,
    pub known_tracks: RwLock<HashSet<String>>,
}

impl AppState {
    pub fn new(client: SoundCloudClient, store: SessionStore) -> Self {
        Self {
            client,
            store,
            token_lock: Mutex::new(()),
            login_lock: Mutex::new(()),
            track_secret_tokens: RwLock::new(HashMap::new()),
            known_tracks: RwLock::new(HashSet::new()),
        }
    }

    pub async fn session(&self) -> Result<SessionState, CommandError> {
        let Some(record) = self.store.load()? else {
            return Ok(SessionState::signed_out());
        };
        if let Some(user) = record.user {
            return Ok(SessionState::signed_in(user));
        }

        let user = self
            .authenticated(|token| async move { self.client.me(&token).await })
            .await?;
        self.save_user(user.clone()).await?;
        Ok(SessionState::signed_in(user))
    }

    pub async fn save_new_token(&self, token: TokenResponse) -> Result<(), CommandError> {
        let _guard = self.token_lock.lock().await;
        self.store.save(&TokenRecord {
            access_token: token.access_token,
            refresh_token: required_refresh_token(token.refresh_token)?,
            expires_at: now_seconds().saturating_add(token.expires_in),
            user: None,
        })
    }

    pub async fn save_user(&self, user: UserSummary) -> Result<(), CommandError> {
        let _guard = self.token_lock.lock().await;
        let mut record = self
            .store
            .load()?
            .ok_or_else(CommandError::not_authenticated)?;
        record.user = Some(user);
        self.store.save(&record)
    }

    pub async fn authenticated<T, F, Fut>(&self, operation: F) -> Result<T, CommandError>
    where
        F: Fn(String) -> Fut,
        Fut: Future<Output = Result<T, ScError>>,
    {
        let access_token = self.token_for_request().await?;
        match operation(access_token.clone()).await {
            Ok(value) => Ok(value),
            Err(error) if error.kind == ScErrorKind::Unauthorized => {
                let refreshed = self.refresh_after_unauthorized(&access_token).await?;
                match operation(refreshed).await {
                    Ok(value) => Ok(value),
                    Err(error) if error.kind == ScErrorKind::Unauthorized => {
                        let _ = self.store.delete();
                        Err(CommandError::not_authenticated())
                    }
                    Err(error) => Err(error.into_command()),
                }
            }
            Err(error) => Err(error.into_command()),
        }
    }

    async fn token_for_request(&self) -> Result<String, CommandError> {
        let _guard = self.token_lock.lock().await;
        let record = self
            .store
            .load()?
            .ok_or_else(CommandError::not_authenticated)?;
        if record.expires_at > now_seconds().saturating_add(EXPIRY_MARGIN_SECONDS) {
            return Ok(record.access_token);
        }
        self.refresh_locked(record).await
    }

    async fn refresh_after_unauthorized(&self, failed_token: &str) -> Result<String, CommandError> {
        let _guard = self.token_lock.lock().await;
        let record = self
            .store
            .load()?
            .ok_or_else(CommandError::not_authenticated)?;
        if record.access_token != failed_token {
            return Ok(record.access_token);
        }
        self.refresh_locked(record).await
    }

    async fn refresh_locked(&self, mut record: TokenRecord) -> Result<String, CommandError> {
        let token = match self.client.refresh(&record.refresh_token).await {
            Ok(token) => token,
            Err(error) if error.kind == ScErrorKind::Unauthorized => {
                let _ = self.store.delete();
                return Err(CommandError::not_authenticated());
            }
            Err(error) => return Err(error.into_command()),
        };
        record.access_token = token.access_token;
        record.refresh_token = required_refresh_token(token.refresh_token)?;
        record.expires_at = now_seconds().saturating_add(token.expires_in);
        self.store.save(&record)?;
        Ok(record.access_token)
    }
}

fn required_refresh_token(value: Option<String>) -> Result<String, CommandError> {
    value.filter(|value| !value.is_empty()).ok_or_else(|| {
        CommandError::new("auth_failed", "SoundCloud did not return a refresh token.")
    })
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
