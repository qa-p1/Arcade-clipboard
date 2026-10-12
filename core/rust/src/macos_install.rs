//! macOS first run: "Move Arcade Clipboard to Applications?" (install
//! standard §7.4). The Swift bridge shows the alert; this side decides when
//! to ask, moves the bundle, and writes the receipt with Arcade Link.

use arcade_link::install::{self, platform::macos, Environment, Runtime, State};
use arcade_link::receipt::{InstallMethod, Integration, ManagedBy, Receipt};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const ID: &str = arcade_link::ids::CLIPBOARD;
const NAME: &str = "Arcade Clipboard";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn receipt(
    environment: &Environment,
    bundle: &Path,
    cli: Option<PathBuf>,
) -> std::io::Result<Receipt> {
    let old = environment.receipts().read(ID)?;
    let now = arcade_link::manifest::now_rfc3339();
    Ok(Receipt {
        schema: 1,
        id: ID.into(),
        version: VERSION.into(),
        channel: old
            .as_ref()
            .map_or_else(|| "stable".into(), |r| r.channel.clone()),
        method: InstallMethod::MacosBundle,
        managed_by: old
            .as_ref()
            .map_or(ManagedBy::SelfManaged, |r| r.managed_by),
        path: bundle.into(),
        integration: Integration {
            cli,
            ..Default::default()
        },
        previous: None,
        installed_at: old
            .as_ref()
            .map_or_else(|| now.clone(), |r| r.installed_at.clone()),
        updated_at: now,
    })
}

fn dismissed_file(environment: &Environment) -> PathBuf {
    environment
        .data
        .join("arcade")
        .join("clipboard-install-dismissed.json")
}

/// `{prompt, title, body, buttons}`. In Applications without a receipt it
/// writes one (first run of a dragged copy) and never asks.
pub fn check(args: &[String]) -> Result<Value, String> {
    let none = json!({"prompt": false});
    if std::env::var("ARCADE_NO_INSTALL_PROMPT").as_deref() == Ok("1")
        || args.iter().any(|a| a == "--background")
    {
        return Ok(none);
    }
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    let runtime = Runtime::discover().map_err(|e| e.to_string())?;
    let Some(bundle) = macos::bundle_for(&runtime.executable) else {
        return Ok(none);
    };
    let detection = install::detect(&environment, ID, &runtime).map_err(|e| e.to_string())?;
    if detection.state == State::DevBuild {
        return Ok(none);
    }
    if macos::in_applications(&environment, &bundle) {
        if detection.receipt.is_none() {
            let r = receipt(&environment, &bundle, None).map_err(|e| e.to_string())?;
            environment
                .receipts()
                .write(&r)
                .map_err(|e| e.to_string())?;
        }
        return Ok(none);
    }
    let needs_move = macos::is_translocated(&bundle)
        || bundle.starts_with(environment.home.join("Downloads"))
        || bundle.starts_with("/Volumes")
        || std::fs::metadata(&bundle)
            .map(|m| m.permissions().readonly())
            .unwrap_or(false);
    let dismissed = std::fs::read_to_string(dismissed_file(&environment))
        .is_ok_and(|t| t.trim() == bundle.to_string_lossy());
    if !needs_move || dismissed {
        return Ok(none);
    }
    let strings = install::strings::get();
    let fmt = |s: &str| install::strings::format(s, NAME, VERSION, "", VERSION);
    Ok(json!({
        "prompt": true,
        "title": fmt(&strings.macos.title),
        "body": strings.macos.body.as_deref().map(fmt),
        "buttons": strings.macos.buttons,
    }))
}

/// Moves the bundle, writes the receipt, and returns `{launch}`: the moved
/// bundle for the bridge to open before this copy quits.
pub fn run(install_cli: bool) -> Result<Value, String> {
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    let runtime = Runtime::discover().map_err(|e| e.to_string())?;
    let source = macos::bundle_for(&runtime.executable)
        .ok_or("Arcade Clipboard isn't running from an app bundle")?;
    let root = environment.home.join("Applications");
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    let target = root.join(source.file_name().ok_or("bundle has no name")?);
    let owned = environment
        .receipts()
        .read(ID)
        .ok()
        .flatten()
        .is_some_and(|r| r.path == target);
    if target.exists() && !owned {
        return Err(format!(
            "Applications already contains {NAME} without its receipt"
        ));
    }
    let stage = root.join(format!(
        ".arcade-clipboard-{}",
        arcade_link::endpoint::new_token().map_err(|e| e.to_string())?
    ));
    let staged = macos::move_to_applications(&environment, &source, Some(&stage))
        .map_err(|e| e.to_string())?;
    if target.exists() {
        std::fs::remove_dir_all(&target).map_err(|e| e.to_string())?;
    }
    std::fs::rename(&staged, &target).map_err(|e| e.to_string())?;
    let relative = runtime
        .executable
        .strip_prefix(&source)
        .map_err(|e| e.to_string())?;
    let cli = if install_cli {
        Some(
            macos::install_cli(&environment, "arcade-clipboard", &target.join(relative))
                .map_err(|e| e.to_string())?,
        )
    } else {
        None
    };
    let r = receipt(&environment, &target, cli).map_err(|e| e.to_string())?;
    environment
        .receipts()
        .write(&r)
        .map_err(|e| e.to_string())?;
    Ok(json!({"launch": target}))
}

/// "Just run it once": don't ask again for this copy's location.
pub fn dismiss() -> Result<Value, String> {
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    let runtime = Runtime::discover().map_err(|e| e.to_string())?;
    let bundle = macos::bundle_for(&runtime.executable).ok_or("not an app bundle")?;
    let file = dismissed_file(&environment);
    arcade_link::paths::write_atomic(&file, bundle.to_string_lossy().as_bytes(), true)
        .map_err(|e| e.to_string())?;
    Ok(json!({"dismissed": true}))
}
