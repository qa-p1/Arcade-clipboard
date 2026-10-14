//! Record the desktop bridge's login toggle in Link's installation receipt.
//! Portable copies have no receipt; installed copies must keep this path so
//! repair and uninstall also handle an entry enabled after installation.

use arcade_link::install::Environment;
use arcade_link::receipt::Receipt;
use std::{fs, io};

const ID: &str = arcade_link::ids::CLIPBOARD;

fn record(environment: &Environment, enabled: bool) -> io::Result<()> {
    environment.validate()?;
    let store = environment.receipts();
    let Some(receipt) = store.read(ID)? else {
        return Ok(());
    };
    receipt.validate_native_paths()?;
    let path = environment
        .config
        .join("autostart/arcade-clipboard.desktop");
    if receipt
        .integration
        .autostart
        .as_ref()
        .is_some_and(|old| old != &path)
    {
        return Err(io::Error::other(
            "the receipt records a different login entry",
        ));
    }
    if enabled && !path.is_file() {
        return Err(io::Error::other("the login entry is missing"));
    }
    // Preserve any installer fields unknown to this pinned Link version.
    let file = store.path(ID)?;
    let mut document: serde_json::Value =
        serde_json::from_slice(&fs::read(&file)?).map_err(io::Error::other)?;
    document["integration"]["autostart"] = if enabled {
        serde_json::to_value(path).map_err(io::Error::other)?
    } else {
        serde_json::Value::Null
    };
    document["updatedAt"] = arcade_link::manifest::now_rfc3339().into();
    let bytes = serde_json::to_vec_pretty(&document).map_err(io::Error::other)?;
    Receipt::from_json(std::str::from_utf8(&bytes).map_err(io::Error::other)?)?
        .validate_native_paths()?;
    arcade_link::paths::write_atomic(&file, &bytes, true)
}

pub(crate) fn record_current(enabled: bool) -> io::Result<()> {
    record(&Environment::discover()?, enabled)
}

#[cfg(test)]
mod tests {
    use super::*;
    use arcade_link::receipt::{InstallMethod, Integration, ManagedBy};

    #[test]
    fn a_later_login_toggle_is_recorded_and_removed_on_uninstall() {
        let root = tempfile::tempdir().unwrap();
        let environment = Environment::under(root.path());
        let binary = environment.applications.join("Arcade-Clipboard.AppImage");
        fs::create_dir_all(binary.parent().unwrap()).unwrap();
        fs::write(&binary, b"appimage").unwrap();
        let now = arcade_link::manifest::now_rfc3339();
        let receipt = Receipt {
            schema: 1,
            id: ID.into(),
            version: crate::VERSION.into(),
            channel: "nightly".into(),
            method: InstallMethod::Appimage,
            managed_by: ManagedBy::Tools,
            path: binary.clone(),
            integration: Integration::default(),
            previous: None,
            installed_at: now.clone(),
            updated_at: now,
        };
        environment.receipts().write(&receipt).unwrap();
        let file = environment.receipts().path(ID).unwrap();
        let mut document: serde_json::Value =
            serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
        document["integration"]["extra"] = "preserve".into();
        fs::write(&file, serde_json::to_vec(&document).unwrap()).unwrap();
        let path = environment
            .config
            .join("autostart/arcade-clipboard.desktop");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            "[Desktop Entry]\nType=Application\nX-Arcade-Id=arcade.clipboard\n",
        )
        .unwrap();
        record(&environment, true).unwrap();
        let updated = environment.receipts().read(ID).unwrap().unwrap();
        assert_eq!(updated.integration.autostart, Some(path.clone()));
        assert_eq!(updated.channel, receipt.channel);
        assert_eq!(updated.managed_by, receipt.managed_by);
        let document: serde_json::Value =
            serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
        assert_eq!(document["integration"]["extra"], "preserve");
        fs::remove_file(&path).unwrap();
        record(&environment, false).unwrap();
        assert!(environment
            .receipts()
            .read(ID)
            .unwrap()
            .unwrap()
            .integration
            .autostart
            .is_none());
        assert!(record(&environment, true).is_err());
        fs::write(&path, "[Desktop Entry]\nX-Arcade-Id=arcade.clipboard\n").unwrap();
        record(&environment, true).unwrap();
        arcade_link::install::uninstall(
            &environment,
            ID,
            arcade_link::install::UninstallOptions {
                remove_data: false,
                data_folders: &[],
            },
        )
        .unwrap();
        assert!(!path.exists());
        assert!(!binary.exists());
        assert!(environment.receipts().read(ID).unwrap().is_none());
    }

    #[test]
    fn portable_toggles_do_not_create_a_receipt_and_damaged_receipts_fail() {
        let root = tempfile::tempdir().unwrap();
        let environment = Environment::under(root.path());
        record(&environment, true).unwrap();
        let file = environment.receipts().path(ID).unwrap();
        assert!(!file.exists());
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, b"invalid").unwrap();
        assert!(record(&environment, false).is_err());
        assert_eq!(fs::read(file).unwrap(), b"invalid");
    }
}
