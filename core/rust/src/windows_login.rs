//! Receipt-backed Windows login shortcut. The installer's "Start at login"
//! task records a Startup shortcut in the receipt, and the in-app switch keeps
//! the shortcut and receipt in sync. Without a receipt the desktop bridge keeps
//! using the portable Run value. The policy also runs in tests on Linux; only
//! creating the shortcut is Windows-only.

use std::fs;
use std::io;
use std::path::Path;

use arcade_link::receipt::{Receipt, Store};

const ID: &str = arcade_link::ids::CLIPBOARD;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Status {
    /// No receipt: the bridge's Run value decides.
    Portable,
    /// Installed: the recorded Startup shortcut decides.
    Installed { enabled: bool },
}

pub(crate) fn status(store: &Store) -> Status {
    match store.read(ID) {
        Ok(Some(receipt)) => Status::Installed {
            enabled: receipt
                .integration
                .autostart
                .is_some_and(|p| p.is_absolute() && p.exists()),
        },
        Ok(None) => Status::Portable,
        // A damaged receipt must not silently select the portable backend.
        Err(_) => Status::Installed { enabled: false },
    }
}

fn remove_file(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// The caller removes the portable Run value first, so the installed and
/// portable mechanisms never both start Clipboard at login. Shortcut creation
/// is injected so tests never touch the real Startup folder.
pub(crate) fn set(
    store: &Store,
    startup: Option<&Path>,
    on: bool,
    write_shortcut: impl FnOnce(&Path, &Path) -> io::Result<()>,
) -> io::Result<()> {
    let Some(receipt) = store.read(ID)? else {
        return Err(io::Error::other(
            "Arcade Clipboard has no installation receipt",
        ));
    };
    receipt.validate_native_paths()?;
    // Read the original JSON as well: the Windows installer records extra
    // fields (such as desktopShortcut) which must survive an in-app toggle.
    let mut document: serde_json::Value =
        serde_json::from_slice(&fs::read(store.path(ID)?)?).map_err(io::Error::other)?;
    let path = receipt.integration.autostart.as_deref().or(startup);
    if on && path.is_none() {
        return Err(io::Error::other(
            "the Windows Startup folder is unavailable",
        ));
    }
    let backup = match path.map(fs::read).transpose() {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(e),
    };
    let change = || {
        if let Some(path) = path {
            if on {
                write_shortcut(path, &receipt.path)?;
            } else {
                remove_file(path)?;
            }
        }
        document["integration"]["autostart"] = if on {
            serde_json::to_value(path).map_err(io::Error::other)?
        } else {
            serde_json::Value::Null
        };
        document["updatedAt"] = arcade_link::manifest::now_rfc3339().into();
        let bytes = serde_json::to_vec_pretty(&document).map_err(io::Error::other)?;
        Receipt::from_json(std::str::from_utf8(&bytes).map_err(io::Error::other)?)?
            .validate_native_paths()?;
        arcade_link::paths::write_atomic(&store.path(ID)?, &bytes, true)
    };
    if let Err(error) = change() {
        if let Some(path) = path {
            let restore = match backup {
                Some(bytes) => arcade_link::paths::write_atomic(path, &bytes, false),
                None => remove_file(path),
            };
            if let Err(restore) = restore {
                return Err(io::Error::other(format!(
                    "{error}; restoring the login shortcut failed: {restore}"
                )));
            }
        }
        return Err(error);
    }
    Ok(())
}

fn shortcut_script(path: &Path, executable: &Path) -> String {
    let quote = |p: &Path| format!("'{}'", p.to_string_lossy().replace('\'', "''"));
    format!(
        "$ErrorActionPreference='Stop'; $s=(New-Object -ComObject WScript.Shell).CreateShortcut({}); $s.TargetPath={}; $s.Arguments='--background'; $s.WorkingDirectory={}; $s.Save()",
        quote(path),
        quote(executable),
        quote(executable.parent().unwrap_or(executable)),
    )
}

#[cfg(target_os = "windows")]
pub(crate) fn current_status() -> io::Result<Status> {
    Ok(status(
        &arcade_link::install::Environment::discover()?.receipts(),
    ))
}

#[cfg(target_os = "windows")]
pub(crate) fn set_current(on: bool) -> io::Result<()> {
    let environment = arcade_link::install::Environment::discover()?;
    let startup = std::env::var_os("APPDATA")
        .map(std::path::PathBuf::from)
        .map(|p| p.join("Microsoft/Windows/Start Menu/Programs/Startup/Arcade Clipboard.lnk"));
    set(
        &environment.receipts(),
        startup.as_deref(),
        on,
        write_shortcut,
    )
}

#[cfg(target_os = "windows")]
fn write_shortcut(path: &Path, executable: &Path) -> io::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let output = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &shortcut_script(path, executable),
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()?;
    if output.status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "could not create the Windows login shortcut: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arcade_link::receipt::{InstallMethod, Integration, ManagedBy};
    use std::path::PathBuf;

    struct Fixture {
        _dir: tempfile::TempDir,
        root: PathBuf,
        store: Store,
        startup: PathBuf,
        receipt: Receipt,
    }

    impl Fixture {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().to_path_buf();
            let store = Store::new(&arcade_link::Locations::under(&root.join("arcade")));
            let startup = root.join("Startup/Arcade Clipboard.lnk");
            let receipt = Receipt {
                schema: 1,
                id: ID.into(),
                version: "0.2.0".into(),
                channel: "stable".into(),
                method: InstallMethod::WindowsInstaller,
                managed_by: ManagedBy::Tools,
                path: root.join("Arcade Clipboard/clipboard.exe"),
                integration: Integration::default(),
                previous: None,
                installed_at: "2026-01-01T00:00:00Z".into(),
                updated_at: "2026-01-01T00:00:00Z".into(),
            };
            Self {
                _dir: dir,
                root,
                store,
                startup,
                receipt,
            }
        }

        fn set(&self, on: bool) -> io::Result<()> {
            set(&self.store, Some(&self.startup), on, |path, exe| {
                fs::create_dir_all(path.parent().unwrap())?;
                fs::write(path, exe.to_string_lossy().as_bytes())
            })
        }
    }

    #[test]
    fn receipt_selects_the_installed_shortcut() {
        let mut f = Fixture::new();
        assert_eq!(status(&f.store), Status::Portable);
        f.store.write(&f.receipt).unwrap();
        assert_eq!(status(&f.store), Status::Installed { enabled: false });
        f.receipt.integration.autostart = Some(f.startup.clone());
        f.store.write(&f.receipt).unwrap();
        assert_eq!(
            status(&f.store),
            Status::Installed { enabled: false },
            "a missing recorded shortcut is disabled"
        );
        fs::create_dir_all(f.startup.parent().unwrap()).unwrap();
        fs::write(&f.startup, b"shortcut").unwrap();
        assert_eq!(status(&f.store), Status::Installed { enabled: true });
    }

    #[test]
    fn toggle_round_trip_keeps_receipt_and_shortcut_in_sync() {
        let f = Fixture::new();
        f.store.write(&f.receipt).unwrap();
        let mut document = serde_json::to_value(&f.receipt).unwrap();
        document["integration"]["desktopShortcut"] = f
            .root
            .join("Desktop/Arcade Clipboard.lnk")
            .to_string_lossy()
            .as_ref()
            .into();
        fs::write(
            f.store.path(ID).unwrap(),
            serde_json::to_vec(&document).unwrap(),
        )
        .unwrap();
        f.set(true).unwrap();
        assert_eq!(
            fs::read_to_string(&f.startup).unwrap(),
            f.receipt.path.to_string_lossy()
        );
        let installed = f.store.read(ID).unwrap().unwrap();
        assert_eq!(installed.integration.autostart, Some(f.startup.clone()));
        assert_eq!(installed.managed_by, ManagedBy::Tools);
        assert_eq!(installed.installed_at, f.receipt.installed_at);
        assert!(installed.updated_at > f.receipt.updated_at);
        let saved: serde_json::Value =
            serde_json::from_slice(&fs::read(f.store.path(ID).unwrap()).unwrap()).unwrap();
        assert_eq!(
            saved["integration"]["desktopShortcut"],
            document["integration"]["desktopShortcut"]
        );
        f.set(false).unwrap();
        assert!(!f.startup.exists());
        assert!(f
            .store
            .read(ID)
            .unwrap()
            .unwrap()
            .integration
            .autostart
            .is_none());
        assert_eq!(status(&f.store), Status::Installed { enabled: false });
        f.set(false).unwrap();
    }

    #[test]
    fn recorded_shortcut_is_used_without_appdata() {
        let mut f = Fixture::new();
        let recorded = f.root.join("Redirected Startup/Clipboard.lnk");
        f.receipt.integration.autostart = Some(recorded.clone());
        f.store.write(&f.receipt).unwrap();
        f.set(true).unwrap();
        assert!(recorded.is_file());
        assert!(!f.startup.exists());
        set(&f.store, None, false, |_, _| {
            panic!("disable must not create a shortcut")
        })
        .unwrap();
        assert!(!recorded.exists());
    }

    #[test]
    fn portable_and_malformed_receipts_are_refused() {
        let f = Fixture::new();
        assert!(
            f.set(true).is_err(),
            "no receipt: the bridge owns the Run value"
        );
        assert!(!f.startup.exists());
        f.store.write(&f.receipt).unwrap();
        fs::write(f.store.path(ID).unwrap(), b"not a receipt").unwrap();
        assert_eq!(status(&f.store), Status::Installed { enabled: false });
        assert!(f.set(true).is_err());
        assert!(!f.startup.exists());
    }

    #[test]
    fn failed_shortcut_write_restores_previous_file_and_receipt() {
        let mut f = Fixture::new();
        f.receipt.integration.autostart = Some(f.startup.clone());
        f.store.write(&f.receipt).unwrap();
        fs::create_dir_all(f.startup.parent().unwrap()).unwrap();
        fs::write(&f.startup, b"original shortcut").unwrap();
        let result = set(&f.store, None, true, |path, _| {
            fs::write(path, b"partial shortcut")?;
            Err(io::Error::other("shortcut creation failed"))
        });
        assert!(result.is_err());
        assert_eq!(fs::read(&f.startup).unwrap(), b"original shortcut");
        assert_eq!(f.store.read(ID).unwrap(), Some(f.receipt.clone()));
    }

    #[test]
    fn powershell_shortcut_paths_are_literal_and_start_in_background() {
        let script = shortcut_script(
            Path::new("C:/User's Startup/Clipboard.lnk"),
            Path::new("C:/User's Apps/clipboard.exe"),
        );
        assert!(script.contains("CreateShortcut('C:/User''s Startup/Clipboard.lnk')"));
        assert!(script.contains("$s.TargetPath='C:/User''s Apps/clipboard.exe'"));
        assert!(script.contains("$s.WorkingDirectory='C:/User''s Apps'"));
        assert!(script.contains("$s.Arguments='--background'"));
    }
}
