//! Clipboard settings handoff. The wire format is an explicit allowlist,
//! separate from the encrypted history database and credential store.

use std::{
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
};

use arcade_link::{Content, Handoff, LinkError, Locations};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const MAX_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PortableSettings {
    schema: u32,
    app: String,
    version: String,
    paused: bool,
    retention_hours: u32,
    max_items: u32,
}

impl PortableSettings {
    pub(crate) fn from_core(value: &Value) -> Result<Self, LinkError> {
        let settings = Self {
            schema: 1,
            app: arcade_link::ids::CLIPBOARD.into(),
            version: env!("CARGO_PKG_VERSION").into(),
            paused: value["paused"].as_bool().unwrap_or(false),
            retention_hours: value["retention_hours"].as_u64().unwrap_or(24) as u32,
            max_items: value["max_items"].as_u64().unwrap_or(500) as u32,
        };
        settings.validate()?;
        Ok(settings)
    }

    pub(crate) fn validate(&self) -> Result<(), LinkError> {
        if self.schema != 1
            || self.app != arcade_link::ids::CLIPBOARD
            || self.version.trim().is_empty()
            || self.version.len() > 64
            || self.version.chars().any(char::is_control)
            || !(1..=720).contains(&self.retention_hours)
            || !(1..=10_000).contains(&self.max_items)
        {
            return Err(LinkError::denied(
                "invalid Arcade Clipboard settings document",
            ));
        }
        Ok(())
    }

    pub(crate) fn core_values(&self) -> Value {
        json!({
            "paused": self.paused,
            "retention_hours": self.retention_hours,
            "max_items": self.max_items,
        })
    }
}

pub(crate) fn export_file(
    locations: &Locations,
    settings: &Value,
) -> Result<Vec<Content>, LinkError> {
    let document = PortableSettings::from_core(settings)?;
    let bytes = serde_json::to_vec_pretty(&document)
        .map_err(|error| LinkError::internal(error.to_string()))?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(LinkError::denied("settings file exceeds 1 MiB"));
    }
    let handoff = Handoff::create(locations, arcade_link::ids::CLIPBOARD).map_err(io_error)?;
    let mut file = handoff
        .file("arcade-clipboard-settings.json", &bytes)
        .map_err(io_error)?;
    file.kind = "file/any".into();
    handoff.keep();
    Ok(vec![file])
}

pub(crate) fn read_import(inputs: &[Content]) -> Result<PortableSettings, LinkError> {
    let [input] = inputs else {
        return Err(LinkError::denied("import requires one settings file"));
    };
    if input.kind != "file/any" || !input.paths.is_empty() {
        return Err(LinkError::denied("import requires a file/any path"));
    }
    let path = input
        .path
        .as_deref()
        .map(Path::new)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| LinkError::denied("import requires an absolute path"))?;
    let file = fs::File::open(path).map_err(io_error)?;
    if !file.metadata().map_err(io_error)?.is_file() {
        return Err(LinkError::denied("import requires a regular file"));
    }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(io_error)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(LinkError::denied("settings file exceeds 1 MiB"));
    }
    let document: PortableSettings = serde_json::from_slice(&bytes)
        .map_err(|error| LinkError::denied(&format!("invalid settings: {error}")))?;
    document.validate()?;
    Ok(document)
}

/// Stores a private recovery copy of the allowlisted settings before import.
pub(crate) fn save_backup(data_dir: &Path, settings: &Value) -> io::Result<PathBuf> {
    let document = PortableSettings::from_core(settings)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;
    let backup_dir = data_dir.join("settings-backups");
    arcade_link::paths::ensure_private_dir(&backup_dir)?;
    let path = backup_dir.join(format!("{}.json", arcade_link::endpoint::new_token()?));
    let bytes = serde_json::to_vec_pretty(&document).map_err(io::Error::other)?;
    arcade_link::paths::write_atomic(&path, &bytes, true)?;
    Ok(path)
}

pub(crate) fn io_error(error: io::Error) -> LinkError {
    LinkError::unavailable(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn export_contains_only_allowlisted_settings() {
        let settings = json!({
            "paused": true,
            "retention_hours": 168,
            "max_items": 1000,
            "relay_url": "https://relay.invalid/?token=must-not-export",
            "device_id": "identity-must-not-export",
            "history": ["clipboard-must-not-export"],
            "token": "token-must-not-export",
        });
        let portable = PortableSettings::from_core(&settings).unwrap();
        let text = serde_json::to_string(&portable).unwrap();
        for forbidden in [
            "relay_url",
            "relay.invalid",
            "device_id",
            "identity-must-not-export",
            "history",
            "clipboard-must-not-export",
            "token",
        ] {
            assert!(
                !text.contains(forbidden),
                "portable settings contain {forbidden}"
            );
        }
        assert_eq!(
            portable.core_values(),
            json!({"paused":true,"retention_hours":168,"max_items":1000})
        );
    }

    #[test]
    fn import_rejects_unknown_identity_or_history_fields() {
        for key in ["deviceId", "history", "token", "relayUrl"] {
            let text = format!(
                r#"{{"schema":1,"app":"arcade.clipboard","version":"0.1.0","paused":false,"retentionHours":24,"maxItems":500,"{key}":"forbidden"}}"#
            );
            assert!(
                serde_json::from_str::<PortableSettings>(&text).is_err(),
                "accepted {key}"
            );
        }
    }

    #[test]
    fn import_rejects_out_of_range_values() {
        let invalid = PortableSettings {
            schema: 1,
            app: arcade_link::ids::CLIPBOARD.into(),
            version: "0.1.0".into(),
            paused: false,
            retention_hours: 0,
            max_items: 500,
        };
        assert!(invalid.validate().is_err());
    }
}
