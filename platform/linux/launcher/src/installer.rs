//! Clipboard's AppImage self-installer around Arcade Link's receipts and
//! install APIs, and the `--install`/`--uninstall`/`--repair`/
//! `--integration-status` commands. The Flutter app itself is unchanged.
//!
//! Every operation takes an explicit Link environment, so tests and the e2e
//! runner can install into a temporary home.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use arcade_link::install::{self, AppInfo, Detection, Environment, Runtime, State};
use arcade_link::receipt::{InstallMethod, ManagedBy, Receipt};
use serde::{Deserialize, Serialize};

pub const ME: &str = arcade_link::ids::CLIPBOARD;
pub const NAME: &str = "Arcade Clipboard";
pub const CLI_NAME: &str = "arcade-clipboard";
pub const DESKTOP_ID: &str = "dev.arcade.clipboard";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn app_info() -> AppInfo {
    AppInfo {
        id: ME.into(),
        name: NAME.into(),
        filename: "Arcade-Clipboard.AppImage".into(),
        desktop_id: DESKTOP_ID.into(),
        cli_name: CLI_NAME.into(),
        background_args: vec!["--background".into()],
        legacy_desktop_ids: vec![DESKTOP_ID.into()],
        autostart_id: "arcade-clipboard".into(),
    }
}

/// How this copy was installed, for the manifest's `install` echo.
pub fn method() -> InstallMethod {
    match Environment::discover().and_then(|e| Runtime::discover().and_then(|r| install::detect(&e, ME, &r))) {
        Ok(d) if d.state == State::DevBuild => InstallMethod::Dev,
        Ok(d) => d
            .receipt
            .as_ref()
            .filter(|_| d.state == State::InstalledHere)
            .map_or(if d.is_app_image { InstallMethod::Appimage } else { InstallMethod::Manual }, |r| r.method),
        Err(_) => InstallMethod::Manual,
    }
}

/// Whether an installer owns this copy's launcher and login entries.
pub fn has_receipt() -> bool {
    Environment::discover().ok().and_then(|e| e.receipts().read(ME).ok().flatten()).is_some()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum DialogState {
    Install,
    Update { from: String },
    OpenInstalled { version: String },
    MoveToApplications,
}

pub fn dialog_state(d: &Detection, version: &str) -> Option<DialogState> {
    match &d.state {
        State::DevBuild | State::InstalledHere => None,
        State::NotInstalled => Some(DialogState::Install),
        State::InstalledElsewhere { version: installed } => {
            let older = parse_version(installed).zip(parse_version(version)).is_some_and(|(a, b)| a < b);
            if older {
                Some(DialogState::Update { from: installed.clone() })
            } else {
                Some(DialogState::OpenInstalled { version: installed.clone() })
            }
        }
    }
}

fn parse_version(v: &str) -> Option<(u64, u64, u64)> {
    let core = v.split(['-', '+']).next()?;
    let mut parts = core.split('.').map(|p| p.parse::<u64>().ok());
    Some((parts.next()??, parts.next()??, parts.next().flatten().unwrap_or(0)))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Options {
    pub channel: String,
    pub start_at_login: bool,
    pub remove_download: bool,
    pub install_cli: bool,
}

impl Options {
    /// Clipboard keeps its own login setting; the box follows an existing entry.
    pub fn defaults(environment: &Environment) -> Self {
        let receipt = environment.receipts().read(ME).ok().flatten();
        let start_at_login = receipt.as_ref().is_some_and(|r| r.integration.autostart.as_ref().is_some_and(|p| p.exists()));
        let install_cli = environment.path.as_ref().is_some_and(|p| std::env::split_paths(p).any(|p| p == environment.bin));
        Self { channel: "stable".into(), start_at_login, remove_download: true, install_cli }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileIdentity {
    path: PathBuf,
    size: u64,
    modified: u128,
}

fn identity(path: &Path) -> io::Result<FileIdentity> {
    let meta = fs::metadata(path)?;
    Ok(FileIdentity {
        path: path.into(),
        size: meta.len(),
        modified: meta.modified()?.duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos(),
    })
}

fn dismissed_file() -> PathBuf {
    data_dir().join("install-dismissed.json")
}

pub fn dismissed(path: &Path) -> bool {
    identity(path).ok().is_some_and(|id| {
        fs::read(dismissed_file())
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<FileIdentity>>(&b).ok())
            .is_some_and(|v| v.contains(&id))
    })
}

/// "Don't ask again for this file": remembers this exact download.
pub fn dismiss(path: &Path) -> io::Result<()> {
    let id = identity(path)?;
    let file = dismissed_file();
    let mut ids: Vec<FileIdentity> = fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    ids.retain(|old| old.path != id.path);
    if ids.len() >= 128 {
        ids.remove(0);
    }
    ids.push(id);
    arcade_link::paths::write_atomic(&file, &serde_json::to_vec(&ids).map_err(io::Error::other)?, true)
}

/// Only real AppImages prompt. The
/// argument check runs first, so background and Link starts cost nothing.
pub fn automatic_prompt(args: &[String], environment: &Environment, runtime: &Runtime) -> io::Result<Option<(Detection, DialogState)>> {
    const SKIP: &[&str] = &[
        "--background", "--arcade-invoke", "--arcade-manifest", "--version", "-V", "--install", "--uninstall", "--repair",
        "--integration-status", "--quit", "--restart", "--overlay", "--help", "-h",
    ];
    if std::env::var("ARCADE_NO_INSTALL_PROMPT").as_deref() == Ok("1") || args.iter().skip(1).any(|a| SKIP.contains(&a.as_str())) {
        return Ok(None);
    }
    if !runtime.is_appimage() {
        return Ok(None);
    }
    let detection = install::detect(environment, ME, runtime)?;
    if !install::should_prompt(&detection, args, false, dismissed(&detection.running_from)) {
        return Ok(None);
    }
    Ok(dialog_state(&detection, VERSION).map(|s| (detection, s)))
}

pub fn install_copy(environment: &Environment, runtime: &Runtime, options: &Options) -> io::Result<Receipt> {
    if !runtime.is_appimage() {
        return Err(io::Error::other("--install requires a real AppImage, not an ordinary or development binary"));
    }
    let mut icons = Vec::new();
    let appdir = runtime.appdir.clone().ok_or_else(|| io::Error::other("APPDIR is not set"))?;
    let hicolor = appdir.join("usr/share/icons/hicolor");
    for size in [16u16, 24, 32, 48, 64, 128, 256, 512] {
        let source = hicolor.join(format!("{size}x{size}/apps/{DESKTOP_ID}.png"));
        if source.is_file() {
            icons.push(install::Icon { source, size: install::IconSize::Pixels(size) });
        }
    }
    let svg = hicolor.join(format!("scalable/apps/{DESKTOP_ID}.svg"));
    if svg.is_file() {
        icons.push(install::Icon { source: svg, size: install::IconSize::Scalable });
    }
    let existing = environment.receipts().read(ME)?;
    let mut receipt = install::install(
        environment,
        install::InstallOptions {
            app: &app_info(),
            runtime,
            version: VERSION,
            channel: &options.channel,
            managed_by: existing.as_ref().map_or(ManagedBy::SelfManaged, |r| r.managed_by),
            icons: &icons,
            start_at_login: options.start_at_login,
            remove_download: options.remove_download,
            refresh_caches: true,
        },
    )?;
    if !options.start_at_login {
        if let Some(path) = receipt.integration.autostart.take() {
            remove_file(&path)?;
            environment.receipts().write(&receipt)?;
        }
    }
    add_window_class(&receipt)?;
    Ok(receipt)
}




pub fn launch_path(receipt: &Receipt) -> PathBuf {
    receipt.path.clone()
}

pub fn repair(environment: &Environment, runtime: &Runtime) -> io::Result<Receipt> {
    let detection = install::detect(environment, ME, runtime)?;
    {
        let moved = (detection.state != State::DevBuild && detection.is_app_image).then_some(detection.running_from.as_path());
        let receipt = install::repair(environment, &app_info(), moved)?;
        add_window_class(&receipt)?;
        Ok(receipt)
    }
}

pub fn integration_status(environment: &Environment) -> io::Result<install::IntegrationStatus> {
    install::integration_status(environment, ME, &std::env::var("SHELL").unwrap_or_default())
}

/// Quits the running copy, then removes what the receipt lists.
pub fn uninstall(environment: &Environment, remove_data: bool) -> io::Result<bool> {
    if let Some(app) = bundled_app() {
        let _ = std::process::Command::new(app)
            .arg("--quit")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
    // Device keys stay in the system keyring (see docs/user/faq.md).
    let data_folders = [data_dir()];
    install::uninstall(environment, ME, install::UninstallOptions { remove_data, data_folders: &data_folders })
}

pub fn tools_installed(environment: &Environment) -> bool {
    arcade_link::Registry::load(&environment.locations)
        .get(arcade_link::ids::TOOLS)
        .is_some_and(|m| m.executable_exists() && m.settings.link_enabled)
}

/// Updates of a Tools-managed copy go through Tools (`tools.install`).
pub fn handoff_to_tools(environment: &Environment) -> Result<(), arcade_link::LinkError> {
    let registry = arcade_link::Registry::load(&environment.locations);
    let tools = registry.get(arcade_link::ids::TOOLS).ok_or_else(|| arcade_link::LinkError::unavailable("Arcade Tools isn't installed"))?;
    let action = tools
        .action("tools.install")
        .filter(|a| a.available)
        .ok_or_else(|| arcade_link::LinkError::unavailable("This version of Arcade Tools cannot install Clipboard"))?;
    let request = arcade_link::InvokeRequest::new(action.id.split('#').next().unwrap_or(&action.id), ME)
        .input(arcade_link::Content::text("text/plain", ME))
        .options(serde_json::json!({ "app": ME }));
    let me = arcade_link::PeerInfo { id: ME.into(), version: VERSION.into() };
    arcade_link::client::invoke_action(&environment.locations, &me, tools, &request, Default::default()).map(|_| ())
}

/// The original arguments minus the install flags, for the relaunch.
pub fn launch_args(args: &[String]) -> Vec<std::ffi::OsString> {
    let mut result = Vec::new();
    let mut it = args.iter().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--channel" => {
                it.next();
            }
            "--install" | "--silent" | "--no-launch" => {}
            _ => result.push(arg.into()),
        }
    }
    result
}

#[cfg(target_os = "linux")]
/// Flutter's application support folder (`ARCADE_DATA_DIR` in dev profiles).
pub fn data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("ARCADE_DATA_DIR").filter(|d| !d.is_empty()) {
        return dir.into();
    }
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_default()
        .join(DESKTOP_ID)
}

/// The Flutter bundle's launcher beside this binary.
pub fn bundled_app() -> Option<PathBuf> {
    let app = std::env::current_exe().ok()?.parent()?.join("arcade-clipboard");
    app.is_file().then_some(app)
}

fn add_window_class(receipt: &Receipt) -> io::Result<()> {
    let Some(entry) = &receipt.integration.desktop_entry else { return Ok(()) };
    let text = fs::read_to_string(entry)?;
    if text.contains("\nStartupWMClass=") {
        return Ok(());
    }
    let text = text.replacen("\nTerminal=false\n", "\nTerminal=false\nStartupWMClass=dev.arcade.clipboard\nComment=Clipboard history for your devices\n", 1);
    arcade_link::paths::write_atomic(entry, text.as_bytes(), false)
}

fn remove_file(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

fn json(value: &impl Serialize) -> Result<String, String> {
    serde_json::to_string_pretty(value).map_err(|e| e.to_string())
}

/// `--install [--silent] [--no-launch] [--channel C]`.
pub fn install_cli(silent: bool, no_launch: bool, channel: &str) -> Result<String, String> {
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    let runtime = Runtime::discover().map_err(|e| e.to_string())?;
    let mut options = Options::defaults(&environment);
    options.channel = channel.into();
    let args: Vec<String> = std::env::args().collect();
    let (output, launch) = if silent {
        let receipt = install_copy(&environment, &runtime, &options).map_err(|e| e.to_string())?;
        if let Some(hint) = integration_status(&environment).map_err(|e| e.to_string())?.path_hint {
            eprintln!("arcade-clipboard: {hint}");
        }
        (json(&receipt)?, Some(launch_path(&receipt)))
    } else {
        let detection = install::detect(&environment, ME, &runtime).map_err(|e| e.to_string())?;
        if detection.state == State::DevBuild {
            return Err(arcade_link::install::strings::get().errors["devBuild"].clone());
        }
        let state = dialog_state(&detection, VERSION).unwrap_or(DialogState::Install);
        match crate::installer_ui::run(environment, runtime, detection, state, options)? {
            crate::installer_ui::Outcome::Launch(path) => (String::new(), Some(path)),
            _ => (String::new(), None),
        }
    };
    if let Some(path) = launch.filter(|_| !no_launch) {
        install::reexec(&path, &launch_args(&args)).map_err(|e| e.to_string())?;
    }
    Ok(output)
}

/// `--uninstall [--silent] [--remove-data]`.
pub fn uninstall_cli(silent: bool, remove_data: bool) -> Result<String, String> {
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    if silent {
        let removed = uninstall(&environment, remove_data).map_err(|e| e.to_string())?;
        return Ok(serde_json::json!({ "uninstalled": removed }).to_string());
    }
    crate::installer_ui::run_uninstall(environment, remove_data)?;
    Ok(String::new())
}

pub fn repair_cli() -> Result<String, String> {
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    let runtime = Runtime::discover().map_err(|e| e.to_string())?;
    json(&repair(&environment, &runtime).map_err(|e| e.to_string())?)
}

pub fn integration_status_cli() -> Result<String, String> {
    let environment = Environment::discover().map_err(|e| e.to_string())?;
    json(&integration_status(&environment).map_err(|e| e.to_string())?)
}

/// Before the first window: offer to install a downloaded copy. `true` when
/// this process is done (relaunched the installed copy, or handed to Tools).
pub fn first_run_prompt(args: &[String]) -> bool {
    let (Ok(environment), Ok(runtime)) = (Environment::discover(), Runtime::discover()) else { return false };
    let (detection, state) = match automatic_prompt(args, &environment, &runtime) {
        Ok(Some(prompt)) => prompt,
        Ok(None) => return false,
        Err(e) => {
            eprintln!("arcade-clipboard: install detection: {e}");
            return false;
        }
    };
    let options = Options::defaults(&environment);
    match crate::installer_ui::run(environment, runtime, detection, state, options) {
        Ok(crate::installer_ui::Outcome::Launch(path)) => match install::reexec(&path, &args.iter().skip(1).map(Into::into).collect::<Vec<_>>()) {
            Ok(()) => true,
            Err(e) => {
                eprintln!("arcade-clipboard: relaunch: {e}");
                false
            }
        },
        Ok(crate::installer_ui::Outcome::Exit) => true,
        Ok(crate::installer_ui::Outcome::Continue) => false,
        Err(e) => {
            eprintln!("arcade-clipboard: install dialog: {e}");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detection(state: State) -> Detection {
        Detection { state, running_from: PathBuf::from("/test/Arcade-Clipboard.AppImage"), is_app_image: true, receipt: None, installed_path: None }
    }

    #[test]
    fn dialog_state_covers_new_update_open_and_dev_copies() {
        assert_eq!(dialog_state(&detection(State::NotInstalled), "0.2.0"), Some(DialogState::Install));
        assert_eq!(
            dialog_state(&detection(State::InstalledElsewhere { version: "0.1.2".into() }), "0.2.0"),
            Some(DialogState::Update { from: "0.1.2".into() })
        );
        assert_eq!(
            dialog_state(&detection(State::InstalledElsewhere { version: "0.2.0".into() }), "0.2.0"),
            Some(DialogState::OpenInstalled { version: "0.2.0".into() })
        );
        assert_eq!(dialog_state(&detection(State::InstalledHere), "0.2.0"), None);
        assert_eq!(dialog_state(&detection(State::DevBuild), "0.2.0"), None);
    }

    #[test]
    fn relaunch_drops_install_flags() {
        let args: Vec<String> = ["clipboard", "--install", "--silent", "--channel", "nightly", "a.txt"].map(String::from).into();
        assert_eq!(launch_args(&args), vec![std::ffi::OsString::from("a.txt")]);
    }

    #[test]
    fn appimage_install_repair_and_uninstall_use_a_temp_environment() {
        let root = std::env::temp_dir().join(format!("clipboard-install-{}", arcade_link::endpoint::new_token().unwrap()));
        let env = Environment::under(&root.join("home"));
        let appdir = root.join("mount");
        let exe = appdir.join("usr/lib/arcade-clipboard/arcade-clipboard-launcher");
        let image = root.join("Arcade-Clipboard.AppImage");
        fs::create_dir_all(exe.parent().unwrap()).unwrap();
        fs::write(&exe, b"test binary").unwrap();
        fs::write(&image, b"test appimage").unwrap();
        let runtime = Runtime { executable: exe, appimage: Some(image), appdir: Some(appdir), dev_build: false };
        let icon = appdir.join("usr/share/icons/hicolor/scalable/apps/dev.arcade.clipboard.svg");
        fs::create_dir_all(icon.parent().unwrap()).unwrap();
        fs::write(&icon, b"<svg xmlns='http://www.w3.org/2000/svg'/>").unwrap();
        let opts = Options { channel: "stable".into(), start_at_login: true, remove_download: false, install_cli: false };
        let receipt = install_copy(&env, &runtime, &opts).unwrap();
        assert!(receipt.path.is_file());
        let desktop = fs::read_to_string(receipt.integration.desktop_entry.as_ref().unwrap()).unwrap();
        assert!(desktop.contains("StartupWMClass=dev.arcade.clipboard") && desktop.contains("X-Arcade-Id=arcade.clipboard"));
        assert!(receipt.integration.autostart.as_ref().unwrap().is_file());
        let repaired = install::repair(&env, &app_info(), None).unwrap();
        assert_eq!(repaired.path, receipt.path);
        assert!(install::uninstall(&env, ME, install::UninstallOptions { remove_data: false, data_folders: &[] }).unwrap());
        assert!(env.receipts().read(ME).unwrap().is_none());
        assert!(!receipt.path.exists());
        fs::remove_dir_all(root).unwrap();
    }
}
