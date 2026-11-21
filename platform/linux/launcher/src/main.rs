//! The Arcade Clipboard AppImage's entry point (`AppRun` runs it).
//!
//! `--install`, `--uninstall`, `--repair` and `--integration-status` run here
//! (SPEC §8.1). Any other start first offers to install a downloaded copy,
//! then hands the original arguments to the Flutter bundle's launcher. A start
//! that keeps a resident Clipboard first moves to the unpacked copy of the
//! image (Arcade Link RT-7, U1), so no FUSE helper stays resident.

#[cfg(target_os = "linux")]
mod installer;
#[cfg(target_os = "linux")]
mod installer_ui;

#[cfg(target_os = "linux")]
fn main() {
    use std::os::unix::process::CommandExt;
    // The AppImage starts here: the install and its relaunch of the
    // installed copy run in this process (Link detaches that copy from
    // this image), and the runtime's keep-alive pipe stays for the
    // Flutter runner exec'd below.
    arcade_link::childenv::on_startup();
    let argv: Vec<String> = std::env::args().collect();
    if let Some("--install" | "--uninstall" | "--repair" | "--integration-status") =
        argv.get(1).map(String::as_str)
    {
        match integration_command(&argv[1..]) {
            Ok(output) => {
                if !output.is_empty() {
                    println!("{output}");
                }
                return;
            }
            Err(error) => {
                eprintln!("arcade-clipboard: {error}");
                std::process::exit(1);
            }
        }
    }
    // An unknown option exits 2 with the usage, as every Arcade app does (Link conformance CLI-2), before the
    // install prompt or the window could start: rc.2 opened the install prompt, or failed on a missing display.
    if let Some(option) = unknown_option(&argv[1..]) {
        eprintln!("arcade-clipboard: unknown option {option:?}");
        eprintln!("Usage: arcade-clipboard [OPTION]. Run arcade-clipboard --help for the options.");
        std::process::exit(2);
    }
    // The AppImage's launcher already asked (and was told to continue): the
    // unpacked copy it started must not ask a second time.
    if std::env::var_os(arcade_link::runtime::UNPACKED_ENV).is_none()
        && installer::first_run_prompt(&argv)
    {
        return;
    }
    // U1: a resident runs from `<data>/arcade/runtime/clipboard-<version>-<key>/`
    // and this launcher exits at once; the copy's own launcher (same
    // `AppRun`, `ARCADE_UNPACKED` set) execs the Flutter bundle inside the copy.
    // One-shot commands answer from the mount and need no copy.
    if starts_resident(&argv[1..]) {
        if let Some(code) =
            arcade_link::runtime::relaunch_unpacked(installer::ME, installer::VERSION, false)
        {
            std::process::exit(code);
        }
    }
    let Some(app) = installer::bundled_app() else {
        eprintln!("arcade-clipboard: the Flutter bundle is missing beside the launcher");
        std::process::exit(1);
    };
    let error = std::process::Command::new(app).args(&argv[1..]).exec();
    eprintln!("arcade-clipboard: {error}");
    std::process::exit(1);
}

/// Whether a start with these arguments (without the program name) leaves a
/// resident Clipboard running. The commands below answer and exit, or only
/// talk to a running instance (`--hide` and `--quit` never start one), so
/// they run from the mount and never trigger the first extraction. Every
/// other start (the window, `--background`, `--overlay`, `--settings`,
/// `--show`, `--toggle`) can start the resident and so runs from the copy.
#[cfg(target_os = "linux")]
fn starts_resident(args: &[String]) -> bool {
    const ONE_SHOT: &[&str] = &[
        "--version",
        "--help",
        "-h",
        "--status",
        "--arcade-manifest",
        "--restart",
        "--quit",
        "--hide",
        "--integration-status",
    ];
    !args.iter().any(|arg| ONE_SHOT.contains(&arg.as_str()))
}

/// The first argument that is not one of Clipboard's options (`--help` lists them; `--arcade-invoke` is Link's
/// one-shot mode), or `None`. `--channel` takes the next argument as its value.
#[cfg(target_os = "linux")]
fn unknown_option(args: &[String]) -> Option<&str> {
    const KNOWN: &[&str] = &[
        "--show",
        "--hide",
        "--toggle",
        "--background",
        "--overlay",
        "--settings",
        "--status",
        "--restart",
        "--quit",
        "--version",
        "-V",
        "--help",
        "-h",
        "--install",
        "--uninstall",
        "--repair",
        "--integration-status",
        "--arcade-manifest",
        "--arcade-invoke",
        "--silent",
        "--no-launch",
        "--keep-download",
        "--remove-data",
    ];
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--channel" => {
                it.next();
            }
            known if KNOWN.contains(&known) => {}
            other => return Some(other),
        }
    }
    None
}

#[cfg(target_os = "linux")]
fn integration_command(args: &[String]) -> Result<String, String> {
    let action = args[0].as_str();
    let (mut silent, mut no_launch, mut remove_data, mut channel) = (false, false, false, None);
    let mut keep_download = false;
    let mut it = args[1..].iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--silent" => silent = true,
            "--no-launch" => no_launch = true,
            // Read by the installer itself; validated here.
            "--keep-download" => keep_download = true,
            "--remove-data" => remove_data = true,
            "--channel" => {
                channel = Some(
                    it.next()
                        .filter(|c| !c.is_empty() && !c.starts_with('-'))
                        .ok_or("--channel needs a channel name")?
                        .clone(),
                )
            }
            other => return Err(format!("unexpected argument {other:?} for {action}")),
        }
    }
    if (no_launch || keep_download || channel.is_some()) && action != "--install" {
        return Err("--no-launch, --keep-download and --channel require --install".into());
    }
    if remove_data && action != "--uninstall" {
        return Err("--remove-data requires --uninstall".into());
    }
    if silent && !matches!(action, "--install" | "--uninstall") {
        return Err("--silent requires --install or --uninstall".into());
    }
    match action {
        "--install" => {
            installer::install_cli(silent, no_launch, channel.as_deref().unwrap_or("stable"))
        }
        "--uninstall" => installer::uninstall_cli(silent, remove_data),
        "--repair" => installer::repair_cli(),
        _ => installer::integration_status_cli(),
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::{starts_resident, unknown_option};

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn starts_that_keep_a_resident_run_from_the_copy() {
        for list in [
            &[][..],
            &["--background"],
            &["--show"],
            &["--toggle"],
            &["--overlay"],
            &["--settings"],
            &["--background", "--overlay"],
        ] {
            assert!(starts_resident(&args(list)), "{list:?} keeps a resident");
        }
    }

    #[test]
    fn unknown_options_are_named_and_known_ones_pass() {
        assert_eq!(
            unknown_option(&args(&["--arcade-conformance-unknown-flag"])),
            Some("--arcade-conformance-unknown-flag")
        );
        assert_eq!(
            unknown_option(&args(&["--background", "--bogus"])),
            Some("--bogus")
        );
        assert_eq!(unknown_option(&args(&["stray"])), Some("stray"));
        for list in [
            &[][..],
            &["--settings"],
            &["--background", "--overlay"],
            &[
                "--install",
                "--silent",
                "--no-launch",
                "--channel",
                "nightly",
            ],
            &["--uninstall", "--silent", "--remove-data"],
            &["--arcade-manifest"],
            &["--arcade-invoke"],
            &["-h"],
        ] {
            assert_eq!(unknown_option(&args(list)), None, "{list:?} is known");
        }
    }

    #[test]
    fn one_shot_commands_run_from_the_mount() {
        for list in [
            &["--version"][..],
            &["--help"],
            &["-h"],
            &["--status"],
            &["--arcade-manifest"],
            &["--restart"],
            &["--quit"],
            &["--hide"],
            &["--integration-status"],
            &["--background", "--status"],
        ] {
            assert!(!starts_resident(&args(list)), "{list:?} is one-shot");
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("arcade-clipboard-launcher is the Linux AppImage entry point");
    std::process::exit(1);
}
