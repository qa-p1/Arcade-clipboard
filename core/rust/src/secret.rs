use rand::{RngCore, rngs::OsRng};
use snow::Builder;
use std::path::{Component, Path, PathBuf};
use uuid::Uuid;

const SERVICE_NAME: &str = "arcade-clipboard";
const SECRET_MAGIC: &[u8; 4] = b"ACV1";
const SECRET_SIZE: usize = 4 + 32 + 32 + 32 + 16 + 1 + 32;

pub trait SecretStore: Send + Sync {
    fn load(&self) -> Result<Option<Vec<u8>>, String>;
    fn store(&self, secret: &[u8]) -> Result<(), String>;
}

pub struct SystemSecretStore {
    profile: String,
    data_dir: PathBuf,
}

impl SystemSecretStore {
    pub fn for_data_dir(path: &std::path::Path) -> Self {
        let data_dir = canonical_profile_path(path);
        let profile = blake3::hash(&path_bytes(&data_dir)).to_hex().to_string();
        Self {
            profile: format!("identity-v1-{profile}"),
            data_dir,
        }
    }

    fn entry(&self) -> Result<keyring::Entry, String> {
        keyring::Entry::new(SERVICE_NAME, &self.profile)
            .map_err(|e| format!("Could not access the system credential store: {e}"))
    }

    fn missing_secret_result(&self) -> Result<Option<Vec<u8>>, String> {
        if self.data_dir.join("history.sqlite").exists() {
            Err(
                "Secure identity is missing for an existing local database; refusing to replace it"
                    .into(),
            )
        } else {
            Ok(None)
        }
    }
}

impl SecretStore for SystemSecretStore {
    fn load(&self) -> Result<Option<Vec<u8>>, String> {
        #[cfg(target_os = "android")]
        {
            return Err("Secure key storage is not configured for this Android build".into());
        }
        #[cfg(not(target_os = "android"))]
        {
            let entry = self.entry()?;
            match entry.get_secret() {
                Ok(secret) => Ok(Some(secret)),
                Err(keyring::Error::NoEntry) => self.missing_secret_result(),
                Err(e) => Err(format!("Could not read secure identity storage: {e}")),
            }
        }
    }

    fn store(&self, secret: &[u8]) -> Result<(), String> {
        #[cfg(target_os = "android")]
        {
            let _ = secret;
            return Err("Secure key storage is not configured for this Android build".into());
        }
        #[cfg(not(target_os = "android"))]
        {
            let entry = self.entry()?;
            entry.set_secret(secret).map_err(|e| {
                format!("Could not store identity in the system credential store: {e}")
            })
        }
    }
}

fn canonical_profile_path(path: &Path) -> PathBuf {
    if let Ok(path) = path.canonicalize() {
        return path;
    }
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };
    let normalized = normalize_path(&absolute);
    let mut ancestor = normalized.as_path();
    let mut missing = Vec::new();
    while !ancestor.exists() {
        let Some(name) = ancestor.file_name() else {
            break;
        };
        missing.push(name.to_os_string());
        let Some(parent) = ancestor.parent() else {
            break;
        };
        ancestor = parent;
    }
    let mut canonical = ancestor
        .canonicalize()
        .unwrap_or_else(|_| ancestor.to_path_buf());
    for component in missing.iter().rev() {
        canonical.push(component);
    }
    normalize_path(&canonical)
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if normalized.file_name().is_some() {
                    normalized.pop();
                } else {
                    normalized.push(component.as_os_str());
                }
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

#[cfg(unix)]
fn path_bytes(path: &Path) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;
    path.as_os_str().as_bytes().to_vec()
}

#[cfg(windows)]
fn path_bytes(path: &Path) -> Vec<u8> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str()
        .encode_wide()
        .flat_map(u16::to_le_bytes)
        .collect()
}

#[cfg(not(any(unix, windows)))]
fn path_bytes(path: &Path) -> Vec<u8> {
    path.to_string_lossy().as_bytes().to_vec()
}

#[derive(Clone)]
pub struct IdentityMaterial {
    pub static_private: [u8; 32],
    pub static_public: [u8; 32],
    pub database_key: [u8; 32],
    pub device_id: Uuid,
    pub owner_signing_secret: Option<[u8; 32]>,
}

impl IdentityMaterial {
    pub fn load_or_create(store: &dyn SecretStore) -> Result<Self, String> {
        match store.load()? {
            Some(bytes) => Self::decode(&bytes),
            None => {
                let value = Self::generate()?;
                store.store(&value.encode())?;
                Ok(value)
            }
        }
    }

    pub fn save(&self, store: &dyn SecretStore) -> Result<(), String> {
        store.store(&self.encode())
    }

    pub fn generate() -> Result<Self, String> {
        let parameters = "Noise_XX_25519_ChaChaPoly_BLAKE2s"
            .parse()
            .map_err(|e| format!("Invalid Noise parameters: {e}"))?;
        let pair = Builder::new(parameters)
            .generate_keypair()
            .map_err(|e| format!("Could not generate device identity: {e}"))?;
        if pair.private.len() != 32 || pair.public.len() != 32 {
            return Err("Noise provider returned an unexpected identity key size".into());
        }
        let mut static_private = [0; 32];
        static_private.copy_from_slice(&pair.private);
        let mut static_public = [0; 32];
        static_public.copy_from_slice(&pair.public);
        let mut database_key = [0; 32];
        OsRng.fill_bytes(&mut database_key);
        Ok(Self {
            static_private,
            static_public,
            database_key,
            device_id: Uuid::new_v4(),
            owner_signing_secret: None,
        })
    }

    fn encode(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(SECRET_SIZE);
        bytes.extend_from_slice(SECRET_MAGIC);
        bytes.extend_from_slice(&self.static_private);
        bytes.extend_from_slice(&self.static_public);
        bytes.extend_from_slice(&self.database_key);
        bytes.extend_from_slice(self.device_id.as_bytes());
        if let Some(key) = self.owner_signing_secret {
            bytes.push(1);
            bytes.extend_from_slice(&key);
        } else {
            bytes.push(0);
            bytes.extend_from_slice(&[0; 32]);
        }
        bytes
    }

    fn decode(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() != SECRET_SIZE || bytes.get(..4) != Some(SECRET_MAGIC.as_slice()) {
            return Err("Stored secure identity is invalid; refusing to replace it".into());
        }
        let mut static_private = [0; 32];
        static_private.copy_from_slice(&bytes[4..36]);
        let mut static_public = [0; 32];
        static_public.copy_from_slice(&bytes[36..68]);
        let mut database_key = [0; 32];
        database_key.copy_from_slice(&bytes[68..100]);
        let device_id = Uuid::from_slice(&bytes[100..116])
            .map_err(|_| "Stored secure device ID is invalid".to_string())?;
        let owner_signing_secret = match bytes[116] {
            0 => None,
            1 => {
                let mut key = [0; 32];
                key.copy_from_slice(&bytes[117..149]);
                Some(key)
            }
            _ => return Err("Stored secure signing-key flag is invalid".into()),
        };
        let derived_public =
            x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(static_private))
                .to_bytes();
        if derived_public != static_public {
            return Err("Stored secure device identity failed key consistency validation".into());
        }
        Ok(Self {
            static_private,
            static_public,
            database_key,
            device_id,
            owner_signing_secret,
        })
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::SecretStore;
    use std::sync::Mutex;

    #[derive(Default)]
    pub struct MemorySecretStore(pub Mutex<Option<Vec<u8>>>);

    impl SecretStore for MemorySecretStore {
        fn load(&self) -> Result<Option<Vec<u8>>, String> {
            Ok(self.0.lock().unwrap().clone())
        }

        fn store(&self, secret: &[u8]) -> Result<(), String> {
            *self.0.lock().unwrap() = Some(secret.to_vec());
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_secret_profiles_are_canonical_and_isolated() {
        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first");
        let second = dir.path().join("second");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        let alias = dir.path().join("nested").join("..").join("first");
        let first_store = SystemSecretStore::for_data_dir(&first);
        let alias_store = SystemSecretStore::for_data_dir(&alias);
        let second_store = SystemSecretStore::for_data_dir(&second);
        assert_eq!(first_store.profile, alias_store.profile);
        assert_ne!(first_store.profile, second_store.profile);
    }

    #[test]
    fn missing_secret_for_existing_database_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("history.sqlite"), b"existing database").unwrap();
        let store = SystemSecretStore::for_data_dir(dir.path());
        let error = store.missing_secret_result().unwrap_err();
        assert!(error.contains("refusing to replace"));
    }

    #[test]
    fn missing_secret_without_database_allows_first_run() {
        let dir = tempfile::tempdir().unwrap();
        let store = SystemSecretStore::for_data_dir(dir.path());
        assert!(store.missing_secret_result().unwrap().is_none());
    }
}
