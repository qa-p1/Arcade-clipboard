//! The install, update and uninstall dialogs, shown before Flutter starts
//! (a small GTK dialog; the bundle already ships GTK). Wording comes verbatim from
//! Arcade Link's shared install strings, so every Arcade app reads the same.

use std::path::PathBuf;

use crate::installer::{self, DialogState, Options, ME, NAME};
use arcade_link::install::{strings, Detection, Environment, Runtime};
use arcade_link::receipt::ManagedBy;

const VERSION: &str = crate::installer::VERSION;

#[derive(Debug, Clone)]
pub enum Outcome {
    /// Start this copy as usual.
    Continue,
    /// Start the installed copy with the original arguments.
    Launch(PathBuf),
    /// Nothing more to do in this process.
    Exit,
}

fn format(s: &str, version: &str, from: &str) -> String {
    strings::format(s, NAME, version, from, VERSION)
}

fn newer_installed(installed: &str) -> bool {
    installer::parse_version(installed)
        .zip(installer::parse_version(VERSION))
        .is_some_and(|(installed, this)| installed > this)
}

/// Title, body and buttons for a dialog state.
pub fn text(state: &DialogState) -> (String, Option<String>, Vec<String>) {
    let all = strings::get();
    let (dialog, version, from) = match state {
        DialogState::Install => (&all.not_installed, VERSION, ""),
        DialogState::Update { from } => (&all.older, VERSION, from.as_str()),
        // Say so when this file is the older one, not just "already installed".
        DialogState::OpenInstalled { version } if newer_installed(version) => (
            all.newer_installed.as_ref().unwrap_or(&all.same_or_newer),
            version.as_str(),
            VERSION,
        ),
        DialogState::OpenInstalled { version } => (&all.same_or_newer, version.as_str(), ""),
        DialogState::MoveToApplications => (&all.macos, VERSION, ""),
    };
    (
        format(&dialog.title, version, from),
        dialog.body.as_ref().map(|s| format(s, version, from)),
        dialog.buttons.clone(),
    )
}

/// What the user picked: a button index and the (possibly changed) options.
struct Choice {
    button: Option<usize>,
    options: Options,
}

/// Runs the chosen action. Button 0 is always the main action; for a new
/// copy, button 2 is "Don't ask again for this file".
fn act(
    environment: &Environment,
    runtime: &Runtime,
    detection: &Detection,
    state: &DialogState,
    choice: Choice,
) -> Result<Outcome, String> {
    let managed = detection
        .receipt
        .as_ref()
        .is_some_and(|r| r.managed_by == ManagedBy::Tools)
        && installer::tools_installed(environment);
    match choice.button {
        Some(0) => {}
        Some(2) if *state == DialogState::Install => {
            installer::dismiss(&detection.running_from).map_err(|e| e.to_string())?;
            return Ok(Outcome::Continue);
        }
        // Closing the question answers nothing: don't install, don't start.
        None => return Ok(Outcome::Exit),
        _ => return Ok(Outcome::Continue),
    }
    if let DialogState::OpenInstalled { .. } = state {
        let receipt = detection
            .receipt
            .as_ref()
            .ok_or("No installed copy was found")?;
        return Ok(Outcome::Launch(installer::launch_path(receipt)));
    }
    if managed {
        installer::handoff_to_tools(environment).map_err(|e| e.to_string())?;
        return Ok(Outcome::Exit);
    }
    let receipt = installer::install_copy(environment, runtime, &choice.options)
        .map_err(|e| format(&strings::get().errors["install"], VERSION, &e.to_string()))?;
    // The installed copy replaces an older one still running.
    installer::stop_running_copy(environment);
    if let Some(command) = installer::integration_status(environment)
        .ok()
        .and_then(|s| s.path_hint)
    {
        message(&strings::format(
            &strings::get().path_hint,
            NAME,
            VERSION,
            "",
            &command,
        ));
    }
    Ok(Outcome::Launch(installer::launch_path(&receipt)))
}

pub fn run(
    environment: Environment,
    runtime: Runtime,
    detection: Detection,
    state: DialogState,
    options: Options,
) -> Result<Outcome, String> {
    let managed = detection
        .receipt
        .as_ref()
        .is_some_and(|r| r.managed_by == ManagedBy::Tools)
        && installer::tools_installed(&environment);
    #[cfg(target_os = "linux")]
    let legacy = arcade_link::install::legacy_copies(&environment, &installer::app_info());
    #[cfg(not(target_os = "linux"))]
    let legacy: Vec<PathBuf> = Vec::new();
    let choice = ask(&state, options, managed, &legacy)?;
    let result = act(&environment, &runtime, &detection, &state, choice);
    if let Err(e) = &result {
        error(e);
    }
    result
}

pub fn run_uninstall(environment: Environment, remove_data: bool) -> Result<Outcome, String> {
    let Some(remove_data) = ask_uninstall(remove_data)? else {
        return Ok(Outcome::Continue);
    };
    installer::uninstall(&environment, remove_data).map_err(|e| {
        let e = format(&strings::get().errors["uninstall"], VERSION, &e.to_string());
        error(&e);
        e
    })?;
    let _ = ME;
    Ok(Outcome::Exit)
}

fn ask(state: &DialogState, mut options: Options, managed: bool, legacy: &[PathBuf]) -> Result<Choice, String> {
    use gtk::prelude::*;
    gtk::init().map_err(|e| format!("no display for the install dialog: {e}"))?;
    let (title, body, buttons) = text(state);
    let dialog = gtk::Dialog::new();
    dialog.set_title(&format!("{NAME} — Installation"));
    dialog.set_icon_name(Some(installer::DESKTOP_ID));
    dialog.set_resizable(false);
    dialog.set_position(gtk::WindowPosition::Center);
    dialog.set_default_size(460, -1);
    let content = dialog.content_area();
    content.set_spacing(10);
    content.set_border_width(18);
    let heading = gtk::Label::new(None);
    heading.set_markup(&format!(
        "<span size=\"large\" weight=\"bold\">{}</span>",
        gtk::glib::markup_escape_text(&title)
    ));
    heading.set_xalign(0.0);
    heading.set_line_wrap(true);
    content.add(&heading);
    if let Some(body) = body {
        let label = gtk::Label::new(Some(&body));
        label.set_xalign(0.0);
        label.set_line_wrap(true);
        content.add(&label);
    }
    if managed {
        let label = gtk::Label::new(Some(&format(&strings::get().managed_by_tools, VERSION, "")));
        label.set_xalign(0.0);
        label.set_line_wrap(true);
        content.add(&label);
    }
    if let (Some(note), Some(old), DialogState::Install | DialogState::Update { .. }) =
        (&strings::get().replaces_legacy, legacy.first(), state)
    {
        let label = gtk::Label::new(Some(&format(note, VERSION, &old.display().to_string())));
        label.set_xalign(0.0);
        label.set_line_wrap(true);
        content.add(&label);
    }
    let checks = matches!(state, DialogState::Install | DialogState::Update { .. });
    let login = gtk::CheckButton::with_label(&strings::get().not_installed.options[0]);
    let remove = gtk::CheckButton::with_label(&strings::get().not_installed.options[1]);
    if checks {
        login.set_active(options.start_at_login);
        remove.set_active(options.remove_download);
        content.add(&login);
        content.add(&remove);
    }
    for (i, label) in buttons.iter().enumerate().rev() {
        dialog.add_button(label, gtk::ResponseType::Other(i as u16));
    }
    dialog.set_default_response(gtk::ResponseType::Other(0));
    dialog.show_all();
    let response = dialog.run();
    if checks {
        options.start_at_login = login.is_active();
        options.remove_download = remove.is_active();
    }
    dialog.close();
    while gtk::events_pending() {
        gtk::main_iteration();
    }
    let button = match response {
        gtk::ResponseType::Other(i) => Some(i as usize),
        _ => None,
    };
    Ok(Choice { button, options })
}

fn ask_uninstall(remove_data: bool) -> Result<Option<bool>, String> {
    use gtk::prelude::*;
    gtk::init().map_err(|e| format!("no display for the uninstall dialog: {e}"))?;
    let dialog = gtk::Dialog::new();
    dialog.set_title(&format!("Uninstall {NAME}?"));
    dialog.set_resizable(false);
    dialog.set_position(gtk::WindowPosition::Center);
    let content = dialog.content_area();
    content.set_spacing(10);
    content.set_border_width(18);
    let heading = gtk::Label::new(None);
    heading.set_markup(&format!(
        "<span size=\"large\" weight=\"bold\">Uninstall {NAME}?</span>"
    ));
    heading.set_xalign(0.0);
    content.add(&heading);
    let label = gtk::Label::new(Some(
        "This removes the app, its launcher entry, terminal command and start-at-login entry.",
    ));
    label.set_xalign(0.0);
    label.set_line_wrap(true);
    content.add(&label);
    let data = gtk::CheckButton::with_label("Also remove settings and data");
    data.set_active(remove_data);
    content.add(&data);
    dialog.add_button("Cancel", gtk::ResponseType::Cancel);
    dialog.add_button("Uninstall", gtk::ResponseType::Accept);
    dialog.show_all();
    let accepted = dialog.run() == gtk::ResponseType::Accept;
    let remove_data = data.is_active();
    dialog.close();
    while gtk::events_pending() {
        gtk::main_iteration();
    }
    Ok(accepted.then_some(remove_data))
}

fn message(text: &str) {
    show(text, false);
}

/// Failures get the error icon, not the information one.
#[cfg(target_os = "linux")]
fn error(text: &str) {
    show(text, true);
}

#[cfg(not(target_os = "linux"))]
fn error(text: &str) {
    message(text);
}

#[cfg(target_os = "linux")]
fn show(text: &str, failure: bool) {
    use gtk::prelude::*;
    if gtk::init().is_err() {
        eprintln!("arcade-clipboard: {text}");
        return;
    }
    let dialog = gtk::MessageDialog::new(
        None::<&gtk::Window>,
        gtk::DialogFlags::MODAL,
        if failure {
            gtk::MessageType::Error
        } else {
            gtk::MessageType::Info
        },
        gtk::ButtonsType::Ok,
        text,
    );
    dialog.set_title(NAME);
    dialog.run();
    dialog.close();
    while gtk::events_pending() {
        gtk::main_iteration();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_the_shared_strings_verbatim() {
        let (title, body, buttons) = text(&DialogState::Install);
        assert_eq!(title, format!("Install {NAME}?"));
        assert_eq!(
            body,
            Some(format!(
                "This adds {NAME} to the app launcher and your apps folder."
            ))
        );
        assert_eq!(buttons, strings::get().not_installed.buttons);
        assert!(text(&DialogState::Update {
            from: "0.0.1".into()
        })
        .0
        .contains(&format!("0.0.1 → {VERSION}")));
    }
}
