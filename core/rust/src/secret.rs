use rand::{rngs::OsRng, RngCore};
use snow::Builder;
use std::path::{Component, Path, PathBuf};
use uuid::Uuid;

#[cfg(not(target_os = "android"))]
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
        let profile = blake3::hash(&path_bytes(&container_relative(&data_dir)))
            .to_hex()
            .to_string();
        Self {
            profile: format!("identity-v1-{profile}"),
            data_dir,
        }
    }

    #[cfg(not(target_os = "android"))]
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

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn legacy_profiles(&self) -> Vec<PathBuf> {
        use arcade_link::paths::{app_dirs, legacy_dirs, Kind};
        let default = app_dirs(arcade_link::ids::CLIPBOARD).data;
        // A custom profile must never borrow the default profile's identity.
        if self.data_dir != canonical_profile_path(&default) {
            return Vec::new();
        }
        legacy_dirs(arcade_link::ids::CLIPBOARD)
            .into_iter()
            .filter(|old| old.kind == Kind::Data && old.into.as_os_str().is_empty())
            .map(|old| old.path)
            .collect()
    }

    #[cfg(not(target_os = "android"))]
    fn load_with_legacy(
        &self,
        legacy_paths: &[PathBuf],
        mut read: impl FnMut(&str) -> Result<Option<Vec<u8>>, String>,
        mut promote: impl FnMut(&[u8]) -> Result<(), String>,
    ) -> Result<Option<Vec<u8>>, String> {
        if let Some(current) = read(&self.profile)? {
            return Ok(Some(current));
        }
        let database = self.data_dir.join("history.sqlite");
        if !database.exists() {
            return Ok(None);
        }
        let mut recovered = None;
        for path in legacy_paths {
            let old = Self::for_data_dir(path);
            if old.profile == self.profile {
                continue;
            }
            let Some(bytes) = read(&old.profile)? else {
                continue;
            };
            let Ok(identity) = IdentityMaterial::decode(&bytes) else {
                continue;
            };
            if crate::store::Store::verify_recovery_identity(&database, &identity).is_err() {
                continue;
            }
            if recovered.as_ref().is_some_and(|prior| prior != &bytes) {
                return Err("More than one secure identity matches the migrated database; refusing to replace it".into());
            }
            recovered = Some(bytes);
        }
        if let Some(bytes) = recovered {
            // Keep the original credential. Only create the new alias after a
            // read-only check has authenticated the database and membership.
            promote(&bytes)?;
            return Ok(Some(bytes));
        }
        self.missing_secret_result()
    }
}

impl SecretStore for SystemSecretStore {
    fn load(&self) -> Result<Option<Vec<u8>>, String> {
        #[cfg(target_os = "android")]
        {
            match android::load(&self.profile)? {
                Some(bytes) => Ok(Some(bytes)),
                None => self.missing_secret_result(),
            }
        }
        #[cfg(not(target_os = "android"))]
        {
            #[cfg(not(target_os = "ios"))]
            let legacy = self.legacy_profiles();
            #[cfg(target_os = "ios")]
            let legacy = Vec::new();
            self.load_with_legacy(
                &legacy,
                |profile| {
                    let entry = keyring::Entry::new(SERVICE_NAME, profile).map_err(|e| {
                        format!("Could not access the system credential store: {e}")
                    })?;
                    match entry.get_secret() {
                        Ok(secret) => Ok(Some(secret)),
                        Err(keyring::Error::NoEntry) => Ok(None),
                        Err(e) => Err(format!("Could not read secure identity storage: {e}")),
                    }
                },
                |bytes| self.store(bytes),
            )
        }
    }

    fn store(&self, secret: &[u8]) -> Result<(), String> {
        #[cfg(target_os = "android")]
        {
            android::store(&self.profile, secret)
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

// The Android runner installs its application context before the Flutter
// bridge opens a profile. Only the Keystore-backed native provider persists
// these bytes; Rust never writes a plaintext identity file.
#[cfg(target_os = "android")]
mod android {
    use jni::{
        objects::{GlobalRef, JByteArray, JClass, JObject, JValue},
        sys::jboolean,
        JNIEnv, JavaVM,
    };
    use std::sync::OnceLock;

    struct Provider {
        vm: JavaVM,
        class: GlobalRef,
        context: GlobalRef,
    }

    static PROVIDER: OnceLock<Provider> = OnceLock::new();

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_dev_arcade_clipboard_mobile_CoreIdentityStore_nativeInitialize(
        env: JNIEnv,
        class: JClass,
        context: JObject,
    ) -> jboolean {
        if PROVIDER.get().is_some() {
            return 1;
        }
        let provider = (|| -> jni::errors::Result<Provider> {
            Ok(Provider {
                vm: env.get_java_vm()?,
                class: env.new_global_ref(class)?,
                context: env.new_global_ref(context)?,
            })
        })();
        match provider {
            Ok(provider) => {
                let _ = PROVIDER.set(provider);
                1
            }
            Err(_) => {
                let _ = env.exception_clear();
                0
            }
        }
    }

    pub(super) fn load(profile: &str) -> Result<Option<Vec<u8>>, String> {
        let provider = PROVIDER
            .get()
            .ok_or("Android secure storage has not been initialized")?;
        let mut env = provider
            .vm
            .attach_current_thread()
            .map_err(|_| "Could not access Android secure storage")?;
        let result = (|| -> jni::errors::Result<Option<Vec<u8>>> {
            let profile = env.new_string(profile)?;
            let class: &JClass = provider.class.as_obj().into();
            let value = env
                .call_static_method(
                    class,
                    "load",
                    "(Landroid/content/Context;Ljava/lang/String;)[B",
                    &[
                        JValue::Object(provider.context.as_obj()),
                        JValue::Object(profile.as_ref()),
                    ],
                )?
                .l()?;
            if value.is_null() {
                return Ok(None);
            }
            env.convert_byte_array(JByteArray::from(value)).map(Some)
        })();
        result.map_err(|_| {
            let _ = env.exception_clear();
            "Could not read the Android Keystore identity. Unlock this device and try again.".into()
        })
    }

    pub(super) fn store(profile: &str, bytes: &[u8]) -> Result<(), String> {
        let provider = PROVIDER
            .get()
            .ok_or("Android secure storage has not been initialized")?;
        let mut env = provider
            .vm
            .attach_current_thread()
            .map_err(|_| "Could not access Android secure storage")?;
        let result = (|| -> jni::errors::Result<()> {
            let profile = env.new_string(profile)?;
            let bytes = env.byte_array_from_slice(bytes)?;
            let class: &JClass = provider.class.as_obj().into();
            env.call_static_method(
                class,
                "store",
                "(Landroid/content/Context;Ljava/lang/String;[B)V",
                &[
                    JValue::Object(provider.context.as_obj()),
                    JValue::Object(profile.as_ref()),
                    JValue::Object(bytes.as_ref()),
                ],
            )?;
            Ok(())
        })();
        result.map_err(|_| {
            let _ = env.exception_clear();
            "Could not save the Android Keystore identity. Unlock this device and try again.".into()
        })
    }
}

/// iOS apps live in a container whose absolute path (it includes a UUID) can
/// change across updates and reinstalls, while Keychain items persist. The
/// credential name must therefore depend only on the path inside the
/// container, or an update would orphan the identity of an existing profile.
#[cfg(target_os = "ios")]
fn container_relative(path: &Path) -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| canonical_profile_path(&home))
        .and_then(|home| path.strip_prefix(&home).ok().map(Path::to_path_buf))
        .unwrap_or_else(|| path.to_path_buf())
}

#[cfg(not(target_os = "ios"))]
fn container_relative(path: &Path) -> PathBuf {
    path.to_path_buf()
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

    #[cfg(not(target_os = "android"))]
    fn recovery_fixture(path: &Path, paired: bool, history: bool) -> IdentityMaterial {
        use crate::{
            crypto,
            model::*,
            store::{now_ms, Store},
        };
        let mut identity = IdentityMaterial::generate().unwrap();
        let mut store = Store::open(&path.join("history.sqlite"), identity.database_key).unwrap();
        if paired {
            let signing = crypto::generate_owner_signing_key();
            identity.owner_signing_secret = Some(signing.to_bytes());
            let mesh = Uuid::new_v4().to_string();
            let device = identity.device_id.to_string();
            let public = crypto::encode(signing.verifying_key().as_bytes());
            let certificate = crypto::sign_member(
                &signing,
                MemberCertificate {
                    version: PROTOCOL_VERSION,
                    mesh_id: mesh.clone(),
                    device_id: device.clone(),
                    device_name: "Before migration".into(),
                    static_public: crypto::encode(&identity.static_public),
                    issued_at: now_ms(),
                    item_signing_public: String::new(),
                    platform: String::new(),
                    capabilities: Vec::new(),
                },
            )
            .unwrap();
            store
                .install_mesh(
                    &[
                        ("mesh_id", &mesh),
                        ("owner_device_id", &device),
                        ("owner_signing_public", &public),
                        ("device_name", "Before migration"),
                    ],
                    &[PeerRecord {
                        device_id: device.clone(),
                        device_name: "Before migration".into(),
                        static_public: identity.static_public.to_vec(),
                        endpoint: String::new(),
                        certificate,
                        last_seen: now_ms(),
                        revoked: false,
                        owner: true,
                    }],
                )
                .unwrap();
        }
        if history {
            let text = "preserved encrypted history";
            store
                .capture(
                    &WireItem {
                        protocol_version: PROTOCOL_VERSION,
                        id: "11111111-1111-4111-8111-111111111111".into(),
                        origin_device: identity.device_id.to_string(),
                        sender_sequence: 1,
                        source_name: "Before migration".into(),
                        created_at: now_ms(),
                        expires_at: now_ms() + 86_400_000,
                        text: text.into(),
                        kind: "text".into(),
                        content_hash: blake3::hash(text.as_bytes()).to_hex().to_string(),
                        representations: Vec::new(),
                        origin_signature: String::new(),
                    },
                    DEFAULT_MAX_ITEMS,
                )
                .unwrap();
        }
        identity
    }

    #[cfg(not(target_os = "android"))]
    #[test]
    fn migrated_identity_recovery_preserves_history_mesh_and_legacy_credential() {
        use std::{cell::RefCell, collections::HashMap};
        let root = tempfile::tempdir().unwrap();
        let data = root.path().join("new");
        let old = root.path().join("old");
        let identity = recovery_fixture(&data, true, true);
        let bytes = identity.encode();
        let current = SystemSecretStore::for_data_dir(&data);
        let old_profile = SystemSecretStore::for_data_dir(&old).profile;
        let credentials = RefCell::new(HashMap::from([(old_profile.clone(), bytes.clone())]));
        let database = data.join("history.sqlite");
        let before = std::fs::read(&database).unwrap();
        let recovered = current
            .load_with_legacy(
                &[old],
                |profile| Ok(credentials.borrow().get(profile).cloned()),
                |bytes| {
                    credentials
                        .borrow_mut()
                        .insert(current.profile.clone(), bytes.to_vec());
                    Ok(())
                },
            )
            .unwrap()
            .unwrap();
        assert_eq!(recovered, bytes);
        assert_eq!(credentials.borrow().get(&old_profile), Some(&bytes));
        assert_eq!(std::fs::read(&database).unwrap(), before);
        let material = IdentityMaterial::decode(&recovered).unwrap();
        assert_eq!(material.device_id, identity.device_id);
        let store = crate::store::Store::open(&database, material.database_key).unwrap();
        assert_eq!(
            store
                .item("11111111-1111-4111-8111-111111111111")
                .unwrap()
                .unwrap()
                .text,
            "preserved encrypted history"
        );
        assert_eq!(
            store.devices().unwrap()[0].device_id,
            identity.device_id.to_string()
        );
        drop(store);
        let restored = std::sync::Arc::new(test_support::MemorySecretStore::default());
        restored.store(&recovered).unwrap();
        crate::core::Core::open_with_secret_store(data, "After migration".into(), restored)
            .unwrap();
        // Once promoted, normal startup reads the current identity first.
        current
            .load_with_legacy(
                &[root.path().join("unrelated-old-profile")],
                |profile| Ok(credentials.borrow().get(profile).cloned()),
                |_| panic!("existing identity must not be overwritten"),
            )
            .unwrap();
    }

    #[cfg(not(target_os = "android"))]
    #[test]
    fn recovery_rejects_wrong_missing_conflicting_and_unbound_credentials_without_writes() {
        let root = tempfile::tempdir().unwrap();
        let data = root.path().join("new");
        let identity = recovery_fixture(&data, false, true);
        let current = SystemSecretStore::for_data_dir(&data);
        let aliases = [root.path().join("old-one"), root.path().join("old-two")];
        let first = SystemSecretStore::for_data_dir(&aliases[0]).profile;
        let database = data.join("history.sqlite");
        let before = std::fs::read(&database).unwrap();
        let wrong = IdentityMaterial::generate().unwrap().encode();
        for candidate in [None, Some(wrong), Some(vec![0; SECRET_SIZE])] {
            assert!(current
                .load_with_legacy(
                    &aliases,
                    |profile| Ok(if profile == current.profile {
                        None
                    } else {
                        candidate.clone()
                    }),
                    |_| panic!("unverified credential was promoted")
                )
                .is_err());
        }
        let mut conflicting = IdentityMaterial::generate().unwrap();
        conflicting.database_key = identity.database_key;
        assert!(current
            .load_with_legacy(
                &aliases,
                |profile| Ok(if profile == current.profile {
                    None
                } else if profile == first {
                    Some(identity.encode())
                } else {
                    Some(conflicting.encode())
                }),
                |_| panic!("ambiguous credential was promoted")
            )
            .unwrap_err()
            .contains("More than one"));
        assert_eq!(std::fs::read(&database).unwrap(), before);
        let empty = root.path().join("empty");
        let empty_identity = recovery_fixture(&empty, false, false);
        let current = SystemSecretStore::for_data_dir(&empty);
        assert!(current
            .load_with_legacy(
                &aliases,
                |profile| Ok((profile != current.profile).then(|| empty_identity.encode())),
                |_| panic!("empty unpaired database cannot bind a credential")
            )
            .is_err());
    }

    #[cfg(not(target_os = "android"))]
    #[test]
    fn recovery_accepts_empty_signed_mesh_but_rejects_foreign_membership_and_signing_key() {
        let root = tempfile::tempdir().unwrap();
        let identity = recovery_fixture(root.path(), true, false);
        let database = root.path().join("history.sqlite");
        crate::store::Store::verify_recovery_identity(&database, &identity).unwrap();
        let mut foreign = IdentityMaterial::generate().unwrap();
        foreign.database_key = identity.database_key;
        assert!(crate::store::Store::verify_recovery_identity(&database, &foreign).is_err());
        let mut damaged = identity;
        damaged.owner_signing_secret = Some([0; 32]);
        assert!(crate::store::Store::verify_recovery_identity(&database, &damaged).is_err());
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn custom_profiles_cannot_adopt_default_legacy_identities() {
        let root = tempfile::tempdir().unwrap();
        assert!(SystemSecretStore::for_data_dir(root.path())
            .legacy_profiles()
            .is_empty());
        let defaults = arcade_link::paths::app_dirs(arcade_link::ids::CLIPBOARD);
        assert!(!SystemSecretStore::for_data_dir(&defaults.data)
            .legacy_profiles()
            .is_empty());
    }

    #[cfg(not(target_os = "android"))]
    #[test]
    fn recovery_verifier_reads_live_wal_and_rejects_tampered_history_without_changes() {
        let root = tempfile::tempdir().unwrap();
        let identity = recovery_fixture(root.path(), true, true);
        let path = root.path().join("history.sqlite");
        let writer = crate::store::Store::open(&path, identity.database_key).unwrap();
        writer
            .set_meta("owner_signing_public", &crate::crypto::encode(&[0; 32]))
            .unwrap();
        let main_before = std::fs::read(&path).unwrap();
        let wal_before = std::fs::read(path.with_extension("sqlite-wal")).unwrap();
        assert!(crate::store::Store::verify_recovery_identity(&path, &identity).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), main_before);
        assert_eq!(
            std::fs::read(path.with_extension("sqlite-wal")).unwrap(),
            wal_before
        );
        let signing =
            ed25519_dalek::SigningKey::from_bytes(&identity.owner_signing_secret.unwrap());
        writer
            .set_meta(
                "owner_signing_public",
                &crate::crypto::encode(signing.verifying_key().as_bytes()),
            )
            .unwrap();
        crate::store::Store::verify_recovery_identity(&path, &identity).unwrap();
        drop(writer);
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute(
                "UPDATE items SET ciphertext=zeroblob(length(ciphertext))",
                [],
            )
            .unwrap();
        let main_before = std::fs::read(&path).unwrap();
        let wal_before = std::fs::read(path.with_extension("sqlite-wal")).unwrap();
        assert!(crate::store::Store::verify_recovery_identity(&path, &identity).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), main_before);
        assert_eq!(
            std::fs::read(path.with_extension("sqlite-wal")).unwrap(),
            wal_before
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    #[ignore = "requires scripts/verify-identity-migration.py's private D-Bus and keyring"]
    fn migrated_profile_recovers_from_real_secret_service() {
        use arcade_link::paths::{app_dirs, legacy_dirs, migrate_app_dirs, Kind};
        assert_eq!(
            std::env::var("ARCADE_TEST_IDENTITY_MIGRATION").as_deref(),
            Ok("1")
        );
        let old = legacy_dirs(arcade_link::ids::CLIPBOARD)
            .into_iter()
            .find(|entry| entry.kind == Kind::Data && entry.into.as_os_str().is_empty())
            .unwrap()
            .path;
        let identity = recovery_fixture(&old, true, true);
        let old_secrets = SystemSecretStore::for_data_dir(&old);
        identity.save(&old_secrets).unwrap();
        let bytes = old_secrets.entry().unwrap().get_secret().unwrap();
        let new = app_dirs(arcade_link::ids::CLIPBOARD).data;
        let new_secrets = SystemSecretStore::for_data_dir(&new);
        assert!(matches!(
            new_secrets.entry().unwrap().get_secret(),
            Err(keyring::Error::NoEntry)
        ));
        let migration = migrate_app_dirs(arcade_link::ids::CLIPBOARD);
        assert!(migration.kept.is_empty(), "folder migration failed");
        assert!(!old.join("history.sqlite").exists());
        let core = crate::core::Core::open(new.clone(), "After migration".into()).unwrap();
        assert_eq!(new_secrets.entry().unwrap().get_secret().unwrap(), bytes);
        assert_eq!(old_secrets.entry().unwrap().get_secret().unwrap(), bytes);
        drop(core);
        let store =
            crate::store::Store::open(&new.join("history.sqlite"), identity.database_key).unwrap();
        assert_eq!(
            store
                .item("11111111-1111-4111-8111-111111111111")
                .unwrap()
                .unwrap()
                .text,
            "preserved encrypted history"
        );
        assert_eq!(
            store.devices().unwrap()[0].device_id,
            identity.device_id.to_string()
        );
        drop(store);
        crate::core::Core::open(new, "After another restart".into()).unwrap();
    }

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
