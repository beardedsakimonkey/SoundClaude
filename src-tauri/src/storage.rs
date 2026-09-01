use crate::{error::CommandError, models::TokenRecord};
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

const SESSION_FILE_MODE: u32 = 0o600;
const SESSION_DIRECTORY_MODE: u32 = 0o700;

#[derive(Debug)]
pub struct SessionStore {
    path: PathBuf,
}

impl SessionStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn load(&self) -> Result<Option<TokenRecord>, CommandError> {
        let value = match fs::read_to_string(&self.path) {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(CommandError::storage()),
        };
        serde_json::from_str(&value)
            .map(Some)
            .map_err(|_| CommandError::new("storage", "The saved SoundCloud session is invalid."))
    }

    pub fn save(&self, record: &TokenRecord) -> Result<(), CommandError> {
        let value = serde_json::to_vec(record).map_err(|_| CommandError::storage())?;
        let directory = self.path.parent().ok_or_else(CommandError::storage)?;
        fs::create_dir_all(directory).map_err(|_| CommandError::storage())?;
        set_directory_permissions(directory)?;

        let temporary_path = directory.join(format!(
            ".{}.{}.tmp",
            self.path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("oauth-session"),
            Uuid::new_v4()
        ));
        let result = write_and_replace(&temporary_path, &self.path, &value);
        if result.is_err() {
            let _ = fs::remove_file(&temporary_path);
        }
        result
    }

    pub fn delete(&self) -> Result<(), CommandError> {
        match fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err(CommandError::storage()),
        }
    }
}

fn write_and_replace(temporary_path: &Path, path: &Path, value: &[u8]) -> Result<(), CommandError> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(SESSION_FILE_MODE);

    let mut file = options
        .open(temporary_path)
        .map_err(|_| CommandError::storage())?;
    file.write_all(value)
        .and_then(|()| file.sync_all())
        .map_err(|_| CommandError::storage())?;
    drop(file);
    fs::rename(temporary_path, path).map_err(|_| CommandError::storage())?;
    set_file_permissions(path)
}

#[cfg(unix)]
fn set_directory_permissions(path: &Path) -> Result<(), CommandError> {
    fs::set_permissions(path, fs::Permissions::from_mode(SESSION_DIRECTORY_MODE))
        .map_err(|_| CommandError::storage())
}

#[cfg(not(unix))]
fn set_directory_permissions(_path: &Path) -> Result<(), CommandError> {
    Ok(())
}

#[cfg(unix)]
fn set_file_permissions(path: &Path) -> Result<(), CommandError> {
    fs::set_permissions(path, fs::Permissions::from_mode(SESSION_FILE_MODE))
        .map_err(|_| CommandError::storage())
}

#[cfg(not(unix))]
fn set_file_permissions(_path: &Path) -> Result<(), CommandError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::UserSummary;

    fn record() -> TokenRecord {
        TokenRecord {
            access_token: "access".into(),
            refresh_token: "refresh".into(),
            expires_at: 123,
            user: Some(UserSummary {
                username: "listener".into(),
                avatar_url: None,
                permalink_url: "https://soundcloud.com/listener".into(),
            }),
        }
    }

    #[test]
    fn session_file_round_trip_and_delete() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("oauth-session.json");
        let store = SessionStore::new(path.clone());

        assert_eq!(store.load().unwrap(), None);
        store.save(&record()).unwrap();
        assert_eq!(store.load().unwrap(), Some(record()));

        #[cfg(unix)]
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            SESSION_FILE_MODE
        );

        store.delete().unwrap();
        assert_eq!(store.load().unwrap(), None);
    }

    #[test]
    fn invalid_session_file_is_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("oauth-session.json");
        fs::write(&path, "not json").unwrap();
        let store = SessionStore::new(path);

        let error = store.load().unwrap_err();
        assert_eq!(error.code, "storage");
    }
}
