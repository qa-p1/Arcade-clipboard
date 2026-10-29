//! macOS first run: "Move Arcade Clipboard to Applications?" (install
//! standard §7.4). The Swift bridge shows the alert; this side decides when
//! to ask, moves the bundle, and writes the receipt with Arcade Link.

#[cfg(target_os = "macos")]
use arcade_link::install::{self, State};
use arcade_link::install::{platform::macos, Environment, Runtime};
use arcade_link::receipt::{InstallMethod, ManagedBy, Receipt};
#[cfg(target_os = "macos")]
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const ID: &str = arcade_link::ids::CLIPBOARD;
const NAME: &str = "Arcade Clipboard";
const CLI: &str = "arcade-clipboard";
const VERSION: &str = crate::VERSION;

fn receipt(
    environment: &Environment,
    bundle: &Path,
    cli: Option<PathBuf>,
    channel: Option<&str>,
) -> std::io::Result<Receipt> {
    if channel.is_some_and(|c| !matches!(c, "stable" | "nightly")) {
        return Err(std::io::Error::other("--channel must be stable or nightly"));
    }
    let old = environment.receipts().read(ID)?;
    let now = arcade_link::manifest::now_rfc3339();
    let mut integration = old
        .as_ref()
        .map(|r| r.integration.clone())
        .unwrap_or_default();
    integration.cli = cli.or(integration.cli);
    let receipt = Receipt {
        schema: 1,
        id: ID.into(),
        version: VERSION.into(),
        channel: channel.map(str::to_owned).unwrap_or_else(|| {
            old.as_ref()
                .map_or_else(|| "stable".into(), |r| r.channel.clone())
        }),
        method: InstallMethod::MacosBundle,
        managed_by: old
            .as_ref()
            .map_or(ManagedBy::SelfManaged, |r| r.managed_by),
        path: bundle.into(),
        integration,
        previous: None,
        installed_at: old
            .as_ref()
            .map_or_else(|| now.clone(), |r| r.installed_at.clone()),
        updated_at: now,
    };
    receipt.validate_native_paths()?;
    Ok(receipt)
}

/// A dragged replacement owns the existing receipt only at the same bundle.
/// Keep its integration choices, channel, ownership and original install date.
fn refresh_receipt(environment: &Environment, bundle: &Path) -> std::io::Result<()> {
    let old = environment.receipts().read(ID)?;
    match old {
        None => environment
            .receipts()
            .write(&receipt(environment, bundle, None, None)?)?,
        Some(mut old)
            if old.method == InstallMethod::MacosBundle
                && same_bundle(&old.path, bundle)
                && (old.version != VERSION || old.path != bundle) =>
        {
            old.version = VERSION.into();
            old.path = bundle.into();
            old.updated_at = arcade_link::manifest::now_rfc3339();
            environment.receipts().write(&old)?;
        }
        _ => {}
    }
    Ok(())
}

fn same_bundle(a: &Path, b: &Path) -> bool {
    a == b
        || std::fs::canonicalize(a)
            .ok()
            .zip(std::fs::canonicalize(b).ok())
            .is_some_and(|(a, b)| a == b)
}

#[cfg(target_os = "macos")]
fn dismissed_file(environment: &Environment) -> PathBuf {
    environment
        .data
        .join("arcade")
        .join("clipboard-install-dismissed.json")
}

/// `{prompt, title, body, buttons}`. In Applications without a receipt it
/// writes one (first run of a dragged copy) and never asks.
#[cfg(target_os = "macos")]
pub fn check(args: &[String]) -> Result<Value, String> {
    let none = json!({"prompt": false});
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
        refresh_receipt(&environment, &bundle).map_err(|e| e.to_string())?;
        return Ok(none);
    }
    if std::env::var("ARCADE_NO_INSTALL_PROMPT").as_deref() == Ok("1")
        || args.iter().any(|a| a == "--background")
    {
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
#[cfg(target_os = "macos")]
pub fn run(install_cli: bool) -> Result<Value, String> {
    run_with_channel(install_cli, None)
}

#[cfg(target_os = "macos")]
pub fn run_with_channel(install_cli: bool, channel: Option<&str>) -> Result<Value, String> {
    if channel.is_some_and(|c| !matches!(c, "stable" | "nightly")) {
        return Err("--channel must be stable or nightly".into());
    }
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    let runtime = Runtime::discover().map_err(|e| e.to_string())?;
    let source = macos::bundle_for(&runtime.executable)
        .ok_or("Arcade Clipboard isn't running from an app bundle")?;
    let existing = environment.receipts().read(ID).map_err(|e| e.to_string())?;
    let target = bundle_destination(&environment, existing.as_ref()).map_err(|e| e.to_string())?;
    let root = target.parent().ok_or("bundle has no parent")?;
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
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
    let stage = Stage(root.join(format!(
        ".arcade-clipboard-{}",
        arcade_link::endpoint::new_token().map_err(|e| e.to_string())?
    )));
    let staged = macos::move_to_applications(&environment, &source, Some(&stage.0))
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
            macos::install_cli(&environment, CLI, &target.join(relative))
                .map_err(|e| e.to_string())?,
        )
    } else {
        None
    };
    let r = receipt(&environment, &target, cli, channel).map_err(|e| e.to_string())?;
    environment
        .receipts()
        .write(&r)
        .map_err(|e| e.to_string())?;
    Ok(json!({"launch": target}))
}

#[cfg(target_os = "macos")]
struct Stage(PathBuf);

#[cfg(target_os = "macos")]
impl Drop for Stage {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn bundle_destination(
    environment: &Environment,
    receipt: Option<&Receipt>,
) -> std::io::Result<PathBuf> {
    let name = "Arcade Clipboard.app";
    if let Some(receipt) = receipt.filter(|r| r.method == InstallMethod::MacosBundle) {
        receipt.validate_native_paths()?;
        if receipt.path.file_name().is_some_and(|n| n == name)
            && receipt.path.parent().is_some_and(|p| {
                p == environment.home.join("Applications") || p == Path::new("/Applications")
            })
        {
            return Ok(receipt.path.clone());
        }
        return Err(std::io::Error::other(
            "the recorded bundle is outside its Applications folder",
        ));
    }
    Ok(environment.home.join("Applications").join(name))
}

fn bundle_cli(environment: &Environment, receipt: &Receipt) -> Option<PathBuf> {
    receipt
        .integration
        .cli
        .as_ref()
        .filter(|cli| {
            **cli == environment.bin.join(CLI)
                && std::fs::read_link(cli).is_ok_and(|target| {
                    target.starts_with(&receipt.path)
                        && !target
                            .components()
                            .any(|c| c == std::path::Component::ParentDir)
                })
        })
        .cloned()
}

fn repair_in(environment: &Environment, runtime: &Runtime) -> std::io::Result<Receipt> {
    let mut receipt = environment
        .receipts()
        .read(ID)?
        .ok_or_else(|| std::io::Error::other("Arcade Clipboard has no installation receipt"))?;
    receipt.validate_native_paths()?;
    if receipt.method != InstallMethod::MacosBundle {
        return Err(std::io::Error::other("expected a macOS bundle receipt"));
    }
    let source = macos::bundle_for(&runtime.executable)
        .ok_or_else(|| std::io::Error::other("not running from an app bundle"))?;
    let relative = runtime
        .executable
        .strip_prefix(&source)
        .map_err(std::io::Error::other)?;
    let executable = receipt.path.join(relative);
    if !executable.is_file() {
        return Err(std::io::Error::other("the installed executable is missing"));
    }
    let cli = environment.bin.join(CLI);
    if std::fs::symlink_metadata(&cli).is_ok() && bundle_cli(environment, &receipt).is_none() {
        return Err(std::io::Error::other(
            "the terminal command belongs to another installation",
        ));
    }
    receipt.integration.cli = Some(macos::install_cli(environment, CLI, &executable)?);
    // The version of a different downloaded bundle must not replace this receipt.
    if same_bundle(&source, &receipt.path) {
        receipt.version = VERSION.into();
    }
    receipt.updated_at = arcade_link::manifest::now_rfc3339();
    environment.receipts().write(&receipt)?;
    Ok(receipt)
}

#[cfg(target_os = "macos")]
pub fn repair() -> Result<Value, String> {
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    let runtime = Runtime::discover().map_err(|e| e.to_string())?;
    serde_json::to_value(repair_in(&environment, &runtime).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())
}

#[cfg(target_os = "macos")]
fn uninstall_in(
    environment: &Environment,
    remove_data: bool,
    data: &[PathBuf],
) -> std::io::Result<bool> {
    let Some(receipt) = environment.receipts().read(ID)? else {
        return Ok(false);
    };
    receipt.validate_native_paths()?;
    if receipt.method != InstallMethod::MacosBundle {
        return Err(std::io::Error::other("expected a macOS bundle receipt"));
    }
    // Link compares the link target with receipt.path (the .app), whereas
    // the macOS command points to its executable. Remember only our own link.
    let cli = bundle_cli(environment, &receipt);
    let removed = install::uninstall(
        environment,
        ID,
        install::UninstallOptions {
            remove_data,
            data_folders: data,
        },
    )?;
    if let Some(cli) = cli {
        match std::fs::remove_file(cli) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
    }
    Ok(removed)
}

#[cfg(target_os = "macos")]
pub fn uninstall(remove_data: bool) -> Result<Value, String> {
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    let _ = crate::link::quit_running();
    // Device keys stay in the system keyring, as on Linux and Windows.
    let folders = match std::env::var_os("ARCADE_DATA_DIR")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
    {
        Some(data) => vec![data],
        None => {
            // Link's folders, any older folder not moved yet, and the user
            // defaults Clipboard kept before 0.3.0.
            let dirs = arcade_link::paths::app_dirs(arcade_link::ids::CLIPBOARD);
            let mut folders = vec![dirs.data, dirs.config, dirs.cache];
            folders.extend(
                arcade_link::paths::legacy_dirs(arcade_link::ids::CLIPBOARD)
                    .into_iter()
                    .map(|legacy| legacy.path),
            );
            folders.push(
                environment
                    .home
                    .join("Library/Preferences/dev.arcade.clipboard.plist"),
            );
            folders
        }
    };
    let removed = uninstall_in(&environment, remove_data, &folders).map_err(|e| e.to_string())?;
    Ok(json!({"uninstalled": removed}))
}

/// "Just run it once": don't ask again for this copy's location.
#[cfg(target_os = "macos")]
pub fn dismiss() -> Result<Value, String> {
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    let runtime = Runtime::discover().map_err(|e| e.to_string())?;
    let bundle = macos::bundle_for(&runtime.executable).ok_or("not an app bundle")?;
    let file = dismissed_file(&environment);
    arcade_link::paths::write_atomic(&file, bundle.to_string_lossy().as_bytes(), true)
        .map_err(|e| e.to_string())?;
    Ok(json!({"dismissed": true}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn updates_keep_the_adopted_applications_folder() {
        let root = tempfile::tempdir().unwrap();
        let environment = Environment::under(root.path());
        assert_eq!(
            bundle_destination(&environment, None).unwrap(),
            environment.home.join("Applications/Arcade Clipboard.app")
        );
        let mut old = receipt(
            &environment,
            Path::new("/Applications/Arcade Clipboard.app"),
            None,
            None,
        )
        .unwrap();
        assert_eq!(
            bundle_destination(&environment, Some(&old)).unwrap(),
            old.path
        );
        old.path = environment.home.join("Downloads/Arcade Clipboard.app");
        assert!(bundle_destination(&environment, Some(&old)).is_err());
    }

    fn bundle(environment: &Environment, name: &str) -> (PathBuf, Runtime) {
        let bundle = environment
            .home
            .join("Applications")
            .join(format!("{name}.app"));
        let executable = bundle.join("Contents/MacOS/Arcade Clipboard");
        std::fs::create_dir_all(executable.parent().unwrap()).unwrap();
        std::fs::write(&executable, b"app").unwrap();
        (
            bundle,
            Runtime {
                executable,
                appimage: None,
                appdir: None,
                dev_build: false,
            },
        )
    }

    #[test]
    fn channels_and_manual_replacements_preserve_receipt_ownership_and_integration() {
        let root = tempfile::tempdir().unwrap();
        let environment = Environment::under(root.path());
        let (bundle, runtime) = bundle(&environment, NAME);
        let cli = macos::install_cli(&environment, CLI, &runtime.executable).unwrap();
        let mut old = receipt(&environment, &bundle, Some(cli.clone()), Some("nightly")).unwrap();
        old.managed_by = ManagedBy::Tools;
        old.version = "0.0.1".into();
        environment.receipts().write(&old).unwrap();
        refresh_receipt(&environment, &bundle).unwrap();
        let updated = environment.receipts().read(ID).unwrap().unwrap();
        assert_eq!(updated.version, VERSION);
        assert_eq!(updated.path, bundle);
        assert_eq!(updated.channel, "nightly");
        assert_eq!(updated.managed_by, ManagedBy::Tools);
        assert_eq!(updated.installed_at, old.installed_at);
        assert_eq!(updated.integration.cli, Some(cli));
        let (other, _) = self::bundle(&environment, "Other Clipboard");
        refresh_receipt(&environment, &other).unwrap();
        assert_eq!(environment.receipts().read(ID).unwrap().unwrap(), updated);
        assert_eq!(
            receipt(&environment, &bundle, None, Some("stable"))
                .unwrap()
                .channel,
            "stable"
        );
        assert!(receipt(&environment, &bundle, None, Some("invalid")).is_err());
    }

    #[test]
    fn repair_restores_a_missing_cli_and_leaves_foreign_links_alone() {
        let root = tempfile::tempdir().unwrap();
        let environment = Environment::under(root.path());
        let (bundle, runtime) = bundle(&environment, NAME);
        environment
            .receipts()
            .write(&receipt(&environment, &bundle, None, None).unwrap())
            .unwrap();
        let repaired = repair_in(&environment, &runtime).unwrap();
        let cli = repaired.integration.cli.as_ref().unwrap();
        assert_eq!(std::fs::read_link(cli).unwrap(), runtime.executable);
        assert_eq!(bundle_cli(&environment, &repaired), Some(cli.clone()));
        std::fs::remove_file(cli).unwrap();
        let foreign = root.path().join("foreign");
        std::os::unix::fs::symlink(&foreign, cli).unwrap();
        assert!(bundle_cli(&environment, &repaired).is_none());
        assert!(repair_in(&environment, &runtime).is_err());
        assert_eq!(std::fs::read_link(cli).unwrap(), foreign);
        std::fs::remove_file(cli).unwrap();
        std::os::unix::fs::symlink(bundle.join("../foreign"), cli).unwrap();
        assert!(bundle_cli(&environment, &repaired).is_none());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn uninstall_removes_bundle_receipt_and_cli_but_data_only_when_requested() {
        for remove_data in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let environment = Environment::under(root.path());
            let (bundle, runtime) = bundle(&environment, NAME);
            let cli = macos::install_cli(&environment, CLI, &runtime.executable).unwrap();
            environment
                .receipts()
                .write(&receipt(&environment, &bundle, Some(cli.clone()), None).unwrap())
                .unwrap();
            let data = environment.data.join("clipboard");
            std::fs::create_dir_all(&data).unwrap();
            std::fs::write(data.join("sentinel"), b"keep").unwrap();
            assert!(uninstall_in(&environment, remove_data, &[data.clone()]).unwrap());
            assert!(!bundle.exists());
            assert!(std::fs::symlink_metadata(cli).is_err());
            assert!(environment.receipts().read(ID).unwrap().is_none());
            assert_eq!(data.exists(), !remove_data);
            assert!(!uninstall_in(&environment, remove_data, &[data]).unwrap());
        }
    }
}
