//! The Arcade Clipboard AppImage's entry point (`AppRun` runs it).
//!
//! `--install`, `--uninstall`, `--repair` and `--integration-status` run here
//! (SPEC §8.1). Any other start first offers to install a downloaded copy,
//! then hands the original arguments to the Flutter bundle's launcher.

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
    if installer::first_run_prompt(&argv) {
        return;
    }
    let Some(app) = installer::bundled_app() else {
        eprintln!("arcade-clipboard: the Flutter bundle is missing beside the launcher");
        std::process::exit(1);
    };
    let error = std::process::Command::new(app).args(&argv[1..]).exec();
    eprintln!("arcade-clipboard: {error}");
    std::process::exit(1);
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

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("arcade-clipboard-launcher is the Linux AppImage entry point");
    std::process::exit(1);
}
