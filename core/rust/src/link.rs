//! Arcade Link: Arcade Clipboard's presence among the other Arcade apps.
//!
//! The server starts in the core's `initialize` (off the UI) and stops at
//! `shutdown`. Dart has no IPC code: it passes the Link settings in
//! `initialize` and `link_configure`. Desktop only; phones benefit
//! indirectly (content sent to "my devices" arrives there).

use crate::payload::{Representation, MAX_PAYLOAD_BYTES};
use crate::Core;
use arcade_link::server::{Handler, InvokeContext, Job, Reply};
use arcade_link::{
    handoff, ids, Action, Content, Handoff, InvokeRequest, InvokeResult, LinkError, Locations,
    Manifest, Presence,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock, Weak};
use std::time::Duration;
use tokio::runtime::Handle;
use tokio::sync::Notify;

use crate::portable_settings::{self, PortableSettings};
use arcade_link::app::{ImportResult, ShortcutSetResult};
use arcade_link::manifest::{Docs, ManifestAdditions, ManifestDocument, MenuItem, MenuKind};
use arcade_link::receipt::InstallMethod;
use arcade_link::trayhost::{TrayHostWatcher, TrayState, WatcherConfig};

/// The core's limit for a clip's text field; longer text also travels as a
/// `text/plain` representation, as the desktop watcher does.
const MAX_TEXT_FIELD: usize = 32 * 1024;
/// The core's limit on representations per clip.
const MAX_PARTS: usize = 32;

/// "Connect with other Arcade apps", the per-app toggles and the effective
/// picker shortcut, as Dart passes them.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct LinkSettings {
    pub enabled: bool,
    pub has_tray: bool,
    pub mode: &'static str,
    pub disabled_peers: Vec<String>,
    pub shortcut: Option<String>,
}

impl LinkSettings {
    pub(crate) fn from_request(value: Option<&Value>) -> Self {
        let value = value.cloned().unwrap_or_else(|| json!({}));
        Self {
            mode: if value["mode"] == "background" {
                "background"
            } else {
                "foreground"
            },
            enabled: value
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            has_tray: value
                .get("has_tray")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            disabled_peers: value
                .get("disabled_peers")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default(),
            shortcut: value
                .get("shortcut")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
                .map(String::from),
        }
    }
}

/// The manifest for these settings (also printed by `--arcade-manifest`).
pub(crate) fn manifest(settings: &LinkSettings) -> Manifest {
    let mut m = Manifest::new(
        ids::CLIPBOARD,
        crate::VERSION,
        &arcade_link::manifest::current_executable(),
    );
    m.launch.background = vec!["--background".into()];
    if let Some(s) = &settings.shortcut {
        m.shortcuts.push(arcade_link::manifest::Shortcut {
            id: "picker".into(),
            accelerator: s.clone(),
        });
    }
    m.settings.link_enabled = settings.enabled;
    m.actions = actions();
    m
}

/// The actions Clipboard exposes.
pub(crate) fn actions() -> Vec<Action> {
    let mut add = Action::new("clipboard.add", "Send to my devices", "send")
        .accepts(&["text/*", "file/image", "file/any[]"])
        .effects(&["sends-to-device"]);
    add.max_bytes = Some(MAX_PAYLOAD_BYTES as u64);
    vec![
        add,
        Action::new("clipboard.pick", "Choose from clipboard history", "pick")
            .produces(&["text/*", "file/*"])
            .effects(&["opens-ui"])
            .interactive(true),
        Action::new("clipboard.devices", "My devices", "list").produces(&["structured/devices"]),
    ]
}

/// Requests for the Flutter UI (quit now; the picker in `clipboard.pick`),
/// delivered by the `link_wait` long-poll. Dart has no IPC code.
struct Events {
    queue: Mutex<VecDeque<Value>>,
    ready: Notify,
}

fn events() -> &'static Events {
    static EVENTS: OnceLock<Events> = OnceLock::new();
    EVENTS.get_or_init(|| Events {
        queue: Mutex::new(VecDeque::new()),
        ready: Notify::new(),
    })
}

pub(crate) fn push_event(event: Value) {
    let mut queue = events().queue.lock().unwrap_or_else(|e| e.into_inner());
    enqueue_event(&mut queue, event);
    drop(queue);
    events().ready.notify_one();
}

fn enqueue_event(queue: &mut VecDeque<Value>, event: Value) {
    // Tray ownership is current state, not an action to replay. A busy UI must
    // not re-register an icon for an old Own event after Tools hosts it again.
    if event["kind"] == "registry_changed"
        || event["kind"] == "invoke_progress"
        || event["kind"] == "tray_host"
    {
        queue.retain(|old| old["kind"] != event["kind"] || old["request"] != event["request"]);
    }
    queue.push_back(event);
}

/// Waits for the next UI request. No timeout: an idle wait costs nothing.
pub(crate) async fn wait_event() -> Value {
    loop {
        let notified = events().ready.notified();
        if let Some(e) = events()
            .queue
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .pop_front()
        {
            return e;
        }
        notified.await;
    }
}

/// What `clipboard.add` stores: the core's `capture` request fields.
#[derive(Debug, PartialEq)]
pub(crate) struct Clip {
    pub text: String,
    pub kind: &'static str,
    pub representations: Vec<Representation>,
}

fn representation(mime: &str, bytes: &[u8], name: Option<&str>) -> Representation {
    Representation {
        mime_type: mime.into(),
        data_base64: STANDARD.encode(bytes),
        name: name.map(String::from),
    }
}

/// Cuts `text` on a character boundary to the core's text field limit.
fn bounded(text: &str) -> &str {
    let mut end = text.len().min(MAX_TEXT_FIELD);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| "Shared file".into())
}

/// Turns `clipboard.add`'s input into a clip, checking the core's limits
/// first so callers get `too_large` with the limit rather than a message.
pub(crate) fn clip_for(input: &Content) -> Result<Clip, LinkError> {
    let too_large = || LinkError::too_large(MAX_PAYLOAD_BYTES as u64);
    match arcade_link::content::family(&input.kind) {
        "text" => {
            let text = handoff::read_text(input)
                .map_err(|e| LinkError::unsupported(format!("couldn't read the text: {e}")))?;
            let html = input.html.as_deref().filter(|_| input.kind == "text/rich");
            let size = text.len() + html.map_or(0, str::len);
            if size > MAX_PAYLOAD_BYTES {
                return Err(too_large());
            }
            if text.trim().is_empty() && html.is_none() {
                return Err(LinkError::unsupported("there's no text to send"));
            }
            let kind = match input.kind.as_str() {
                "text/url" => "url",
                _ if html.is_some() => "rich_text",
                _ => "text",
            };
            let mut representations = Vec::new();
            if text.len() > MAX_TEXT_FIELD || html.is_some() {
                representations.push(representation("text/plain", text.as_bytes(), None));
            }
            if let Some(html) = html {
                representations.push(representation("text/html", html.as_bytes(), None));
            }
            Ok(Clip {
                text: bounded(&text).to_string(),
                kind,
                representations,
            })
        }
        "file" => {
            let paths = input.all_paths();
            if paths.is_empty() {
                return Err(LinkError::unsupported("there's no file to send"));
            }
            if paths.len() > MAX_PARTS {
                return Err(LinkError::too_large(MAX_PAYLOAD_BYTES as u64)
                    .with_reason(format!("at most {MAX_PARTS} files")));
            }
            let mut total = 0u64;
            for p in &paths {
                let meta = std::fs::metadata(p)
                    .map_err(|_| LinkError::unsupported(format!("{p} doesn't exist")))?;
                if !meta.is_file() {
                    return Err(LinkError::unsupported(format!("{p} isn't a file")));
                }
                total += meta.len();
            }
            if total > MAX_PAYLOAD_BYTES as u64 {
                return Err(too_large());
            }
            let read = |p: &str| {
                std::fs::read(p)
                    .map_err(|e| LinkError::unsupported(format!("couldn't read {p}: {e}")))
            };
            // A single PNG or JPEG becomes an image clip (pasteable as an
            // image on every device); anything else travels as named files.
            if let [one] = paths.as_slice() {
                let ext = Path::new(one)
                    .extension()
                    .map(|e| e.to_string_lossy().to_ascii_lowercase());
                let mime = match ext.as_deref() {
                    Some("png") => Some("image/png"),
                    Some("jpg" | "jpeg") => Some("image/jpeg"),
                    _ => None,
                };
                if let Some(mime) = mime {
                    return Ok(Clip {
                        text: String::new(),
                        kind: "image",
                        representations: vec![representation(mime, &read(one)?, None)],
                    });
                }
            }
            let mut representations = Vec::new();
            for p in &paths {
                let name = file_name(Path::new(p));
                representations.push(representation(
                    "application/octet-stream",
                    &read(p)?,
                    Some(&name),
                ));
            }
            Ok(Clip {
                text: String::new(),
                kind: if paths.len() > 1 { "files" } else { "file" },
                representations,
            })
        }
        _ => Err(LinkError::unsupported(format!(
            "Arcade Clipboard can't store {}",
            input.kind
        ))),
    }
}

/// Maps the core's capture errors onto the Link's codes.
fn capture_error(message: String) -> LinkError {
    if message.contains("paused") {
        LinkError::denied("private_mode")
    } else if message.contains("mesh") {
        LinkError::unavailable("no devices are set up yet")
    } else if message.contains("revoked") {
        LinkError::unavailable("this device was removed from your devices")
    } else if message.contains("16 MiB") {
        LinkError::too_large(MAX_PAYLOAD_BYTES as u64)
    } else if message.contains("32 representations") {
        LinkError::too_large(MAX_PAYLOAD_BYTES as u64)
            .with_reason(format!("at most {MAX_PARTS} files"))
    } else {
        LinkError::unsupported(message)
    }
}

/// The content handed back by `clipboard.pick` for a stored clip.
pub(crate) fn picked_content(payload: &Value) -> Result<Content, LinkError> {
    let h = Handoff::create(&Locations::discover(), ids::CLIPBOARD)
        .map_err(|e| LinkError::internal(format!("couldn't hand the clip over: {e}")))?;
    let content = payload_content(payload, &h)?;
    // A picker caller reads the result after the job ends. Outbound consumers
    // instead retain their Handoff guard until the peer has finished.
    if content.path.is_some() || !content.paths.is_empty() {
        h.keep();
    }
    Ok(content)
}

pub(crate) fn payload_content(payload: &Value, h: &Handoff) -> Result<Content, LinkError> {
    let kind = payload["kind"].as_str().unwrap_or("text");
    let text = payload["text"].as_str().unwrap_or_default();
    let reps: Vec<Representation> =
        serde_json::from_value(payload["representations"].clone()).unwrap_or_default();
    let decode = |r: &Representation| {
        STANDARD
            .decode(&r.data_base64)
            .map_err(|_| LinkError::internal("the clip's data is damaged"))
    };
    let rep_text = |mime: &str| -> Result<Option<String>, LinkError> {
        reps.iter()
            .find(|r| r.mime_type == mime)
            .map(|r| decode(r).map(|b| String::from_utf8_lossy(&b).into_owned()))
            .transpose()
    };
    let io = |e: std::io::Error| LinkError::internal(format!("couldn't hand the clip over: {e}"));
    match kind {
        "image" | "file" | "files" => {
            let mut paths = Vec::new();
            for (i, r) in reps.iter().enumerate() {
                let name = match (&r.name, r.mime_type.as_str()) {
                    (Some(n), _) => n.clone(),
                    (None, "image/png") => format!("clip-{}.png", i + 1),
                    (None, "image/jpeg") => format!("clip-{}.jpg", i + 1),
                    _ if kind == "image" => continue,
                    _ => format!("file-{}", i + 1),
                };
                paths.push(h.write(&name, &decode(r)?).map_err(io)?);
                if kind == "image" {
                    break;
                }
            }
            let content = match paths.as_slice() {
                [] => return Err(LinkError::internal("the clip has no data")),
                [one] => Content::file(one),
                many => Content::files(&many.iter().map(|p| p.as_path()).collect::<Vec<_>>()),
            };
            Ok(content.with_owner(ids::CLIPBOARD))
        }
        _ => {
            let full = rep_text("text/plain")?.unwrap_or_else(|| text.to_string());
            let kind = match kind {
                "url" => "text/url",
                "rich_text" => "text/rich",
                _ => "text/plain",
            };
            let mut content = h.text(kind, &full).map_err(io)?;
            if kind == "text/rich" {
                content.html = rep_text("text/html")?;
            }
            Ok(content)
        }
    }
}

/// `clipboard.devices`: the other devices in the mesh (no keys or ids).
pub(crate) fn device_list(devices: &Value, local_id: &str) -> Value {
    let rows = devices["devices"].as_array().cloned().unwrap_or_default();
    Value::Array(
        rows.iter()
            .filter(|d| d["state"] != "revoked" && d["device_id"] != local_id)
            .map(|d| {
                json!({
                    "name": d["device_name"],
                    "platform": d["platform"].as_str().unwrap_or("Device").to_ascii_lowercase(),
                    "online": d["state"] == "online",
                })
            })
            .collect(),
    )
}

/// `clipboard.pick` requests waiting for the user, by request number.
fn picks() -> &'static Mutex<HashMap<u64, Job>> {
    static PICKS: OnceLock<Mutex<HashMap<u64, Job>>> = OnceLock::new();
    PICKS.get_or_init(Default::default)
}

fn take_pick(request: u64) -> Option<Job> {
    picks()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&request)
}

/// Answers a pending `clipboard.pick` with the chosen clip; with neither an
/// item nor an error, the user closed the picker. Returns whether the
/// request was still waiting.
pub(crate) async fn finish_pick(
    core: &Arc<Core>,
    request: u64,
    item: Option<&str>,
    error: Option<&str>,
) -> bool {
    let Some(job) = take_pick(request) else {
        return false;
    };
    let result = match (item, error) {
        (_, Some(reason)) => Err(LinkError::unavailable(reason)),
        (None, None) => Err(LinkError::denied("user_cancelled")),
        (Some(id), None) => match core.request(json!({"op": "payload", "id": id})).await {
            Ok(payload) => tokio::task::spawn_blocking(move || picked_content(&payload))
                .await
                .unwrap_or_else(|_| Err(LinkError::internal("couldn't hand the clip over")))
                .map(|c| InvokeResult::outputs(vec![c], "Picked a clip")),
            Err(e) => Err(LinkError::unavailable(e)),
        },
    };
    job.finish(result);
    true
}

struct ClipboardHandler {
    mode: &'static str,
    core: Weak<Core>,
    runtime: Handle,
}

impl ClipboardHandler {
    fn core(&self) -> Result<Arc<Core>, LinkError> {
        self.core
            .upgrade()
            .ok_or_else(|| LinkError::unavailable("Arcade Clipboard is shutting down"))
    }

    fn add(&self, request: &InvokeRequest) -> Result<Reply, LinkError> {
        let input = match request.inputs.as_slice() {
            [one] => one,
            [] => return Err(LinkError::unsupported("there's nothing to send")),
            _ => return Err(LinkError::unsupported("send one value at a time")),
        };
        let clip = clip_for(input)?;
        let core = self.core()?;
        let capture = json!({
            "op": "capture",
            "text": clip.text,
            "kind": clip.kind,
            "representations": clip.representations,
        });
        self.runtime
            .block_on(core.request(capture))
            .map_err(capture_error)?;
        Ok(Reply::Done(InvokeResult::message("Sent to your devices")))
    }

    fn pick(&self, ctx: &InvokeContext) -> Result<Reply, LinkError> {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let request = NEXT.fetch_add(1, Ordering::Relaxed);
        let job = ctx.start_job();
        let ticket = job.ticket();
        job.on_cancel(move || {
            if let Some(job) = take_pick(request) {
                push_event(json!({ "kind": "pick_cancelled", "request": request }));
                job.finish(Err(LinkError::cancelled()));
            }
        });
        // One picker at a time: a newer request replaces an open one.
        let replaced: Vec<(u64, Job)> = {
            let mut picks = picks().lock().unwrap_or_else(|e| e.into_inner());
            let old = picks.drain().collect();
            picks.insert(request, job);
            old
        };
        for (_, job) in replaced {
            job.finish(Err(LinkError::denied("user_cancelled")));
        }
        let id = &ctx.peer().id;
        let caller = match arcade_link::manifest::app_name(id) {
            name if name != id => name.to_string(),
            _ => "another app".to_string(),
        };
        push_event(json!({ "kind": "pick", "request": request, "caller_name": caller }));
        Ok(Reply::Job(ticket))
    }

    fn devices(&self) -> Result<Reply, LinkError> {
        let core = self.core()?;
        let (status, devices) = self.runtime.block_on(async {
            (
                core.request(json!({"op": "status"})).await,
                core.request(json!({"op": "devices"})).await,
            )
        });
        let status = status.map_err(LinkError::unavailable)?;
        let devices = devices.map_err(LinkError::unavailable)?;
        let local = status["device_id"].as_str().unwrap_or_default();
        Ok(Reply::Done(InvokeResult {
            outputs: vec![Content::structured("devices", device_list(&devices, local))],
            message: None,
            data: None,
        }))
    }

    fn menu_items(&self) -> Result<Vec<MenuItem>, LinkError> {
        let core = self.core()?;
        let settings = self
            .runtime
            .block_on(core.request(json!({"op": "settings"})))
            .map_err(LinkError::unavailable)?;
        let paused = settings["paused"].as_bool().unwrap_or(false);
        Ok(menu_items(paused))
    }

    fn set_paused(&self, paused: bool) -> Result<(), LinkError> {
        let _change = settings_change_lock()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let core = self.core()?;
        let old = self
            .runtime
            .block_on(core.request(json!({"op": "settings"})))
            .map_err(LinkError::unavailable)?;
        self.runtime
            .block_on(core.request(json!({
                "op": "settings",
                "values": {"paused": paused}
            })))
            .map_err(LinkError::unavailable)?;
        if let Err(error) = refresh_document(&core, &self.runtime) {
            let rollback = self.runtime.block_on(core.request(json!({
                "op": "settings",
                "values": {"paused": old["paused"].as_bool().unwrap_or(false)}
            })));
            let published = refresh_document(&core, &self.runtime);
            if rollback.is_err() || published.is_err() {
                return Err(LinkError::unavailable(format!(
                    "{error}; restoring the previous Clipboard setting also failed"
                )));
            }
            return Err(error);
        }
        Ok(())
    }

    fn export_settings(&self) -> Result<Vec<Content>, LinkError> {
        let _change = settings_change_lock()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let core = self.core()?;
        let settings = self
            .runtime
            .block_on(core.request(json!({"op": "settings"})))
            .map_err(LinkError::unavailable)?;
        portable_settings::export_file(&Locations::discover(), &settings)
    }

    fn import_settings(&self, inputs: &[Content]) -> Result<ImportResult, LinkError> {
        let document = portable_settings::read_import(inputs)?;
        let _change = settings_change_lock()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let core = self.core()?;
        let previous = self
            .runtime
            .block_on(core.request(json!({"op": "settings"})))
            .map_err(LinkError::unavailable)?;
        let previous_portable = PortableSettings::from_core(&previous)?;
        portable_settings::save_backup(core.data_dir(), &previous)
            .map_err(portable_settings::io_error)?;
        let apply = self.runtime.block_on(core.request(json!({
            "op": "settings",
            "values": document.core_values()
        })));
        if let Err(error) = apply {
            let rollback = self.runtime.block_on(core.request(json!({
                "op": "settings",
                "values": previous_portable.core_values()
            })));
            return Err(LinkError::unavailable(if rollback.is_err() {
                format!("{error}; restoring the previous settings also failed")
            } else {
                error
            }));
        }
        if let Err(error) = refresh_document(&core, &self.runtime) {
            let rollback = self.runtime.block_on(core.request(json!({
                "op": "settings",
                "values": previous_portable.core_values()
            })));
            let published = refresh_document(&core, &self.runtime);
            if rollback.is_err() || published.is_err() {
                return Err(LinkError::unavailable(format!(
                    "{error}; restoring the previous settings or manifest also failed"
                )));
            }
            return Err(error);
        }
        Ok(ImportResult {
            imported: true,
            restart_required: false,
        })
    }

    fn set_shortcut(&self, id: &str, accelerator: &str) -> Result<ShortcutSetResult, LinkError> {
        if id != "picker" {
            return Err(LinkError::denied("unknown shortcut id"));
        }
        let normalized = arcade_link::accelerator::normalize(accelerator)
            .map_err(|error| LinkError::denied(&error.to_string()))?;
        if normalized.contains(' ') {
            return Err(LinkError::unavailable(
                "Clipboard's picker shortcut must be one chord",
            ));
        }
        let request = NEXT_SHORTCUT_REQUEST.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        pending_shortcuts()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .insert(request, tx);
        push_event(
            json!({"kind":"shortcut_set","request":request,"id":id,"accelerator":normalized}),
        );
        let response = rx.recv_timeout(Duration::from_secs(8));
        pending_shortcuts()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .remove(&request);
        let response = response
            .map_err(|_| LinkError::unavailable("Clipboard's shortcut UI did not answer"))?;
        if let Some(error) = response.get("error").and_then(Value::as_str) {
            return Err(LinkError::unavailable(error));
        }
        serde_json::from_value(response)
            .map_err(|error| LinkError::unavailable(format!("invalid shortcut response: {error}")))
    }
}

impl Handler for ClipboardHandler {
    fn status(&self) -> Value {
        let tray = tray_slot()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(TrayHostWatcher::state)
            .unwrap_or(TrayState::Own);
        json!({"mode": self.mode, "tray": tray.as_str()})
    }

    fn methods(&self) -> Vec<String> {
        vec![
            "app.settings".into(),
            "app.restart".into(),
            "app.menu".into(),
            "app.menu.invoke".into(),
            "app.shortcuts.set".into(),
            "app.settings.export".into(),
            "app.settings.import".into(),
        ]
    }

    fn settings(&self) -> Result<(), LinkError> {
        push_event(json!({"kind": "showSettings"}));
        Ok(())
    }

    fn restart_ready(&self, mode: &str) -> Result<(), LinkError> {
        if !matches!(mode, "normal" | "force") {
            return Err(LinkError::denied("restart mode must be normal or force"));
        }
        if mode != "force"
            && slot()
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .as_ref()
                .is_some_and(|presence| presence.busy())
        {
            return Err(LinkError::busy());
        }
        Ok(())
    }

    fn restart(&self, _mode: &str) -> Result<(), LinkError> {
        push_event(json!({"kind": "restartRequested"}));
        Ok(())
    }

    fn menu(&self) -> Result<Vec<MenuItem>, LinkError> {
        self.menu_items()
    }

    fn menu_invoke(&self, id: &str) -> Result<(), LinkError> {
        let core = self.core()?;
        let settings = self
            .runtime
            .block_on(core.request(json!({"op": "settings"})))
            .map_err(LinkError::unavailable)?;
        let paused = settings["paused"].as_bool().unwrap_or(false);
        let next = match id {
            "private-mode" => !paused,
            other => return Err(LinkError::denied(&format!("unknown menu item {other}"))),
        };
        self.set_paused(next)
    }

    fn shortcuts_set(&self, id: &str, accelerator: &str) -> Result<ShortcutSetResult, LinkError> {
        self.set_shortcut(id, accelerator)
    }

    fn settings_export(&self) -> Result<Vec<Content>, LinkError> {
        self.export_settings()
    }

    fn settings_import(&self, inputs: &[Content]) -> Result<ImportResult, LinkError> {
        self.import_settings(inputs)
    }

    fn describe(&self) -> Vec<Action> {
        actions()
    }

    fn invoke(&self, request: InvokeRequest, ctx: &InvokeContext) -> Result<Reply, LinkError> {
        match request.action.as_str() {
            "clipboard.add" => self.add(&request),
            "clipboard.pick" => self.pick(ctx),
            "clipboard.devices" => self.devices(),
            other => Err(LinkError::unavailable(format!(
                "Arcade Clipboard has no action {other}"
            ))),
        }
    }

    fn activate(&self) -> Result<(), LinkError> {
        push_event(json!({ "kind": "show" }));
        Ok(())
    }

    fn quit(&self) -> Result<(), LinkError> {
        push_event(json!({ "kind": "quit" }));
        Ok(())
    }
}

static PRESENCE: OnceLock<Mutex<Option<Arc<Presence>>>> = OnceLock::new();
static TRAY_WATCHER: OnceLock<Mutex<Option<TrayHostWatcher>>> = OnceLock::new();
static LINK_SETTINGS: OnceLock<Mutex<Option<LinkSettings>>> = OnceLock::new();
static SETTINGS_CHANGE: OnceLock<Mutex<()>> = OnceLock::new();
static NEXT_SHORTCUT_REQUEST: AtomicU64 = AtomicU64::new(1);
static PENDING_SHORTCUTS: OnceLock<Mutex<HashMap<u64, mpsc::Sender<Value>>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<Arc<Presence>>> {
    PRESENCE.get_or_init(|| Mutex::new(None))
}

fn tray_slot() -> &'static Mutex<Option<TrayHostWatcher>> {
    TRAY_WATCHER.get_or_init(|| Mutex::new(None))
}

fn settings_slot() -> &'static Mutex<Option<LinkSettings>> {
    LINK_SETTINGS.get_or_init(|| Mutex::new(None))
}

fn settings_change_lock() -> &'static Mutex<()> {
    SETTINGS_CHANGE.get_or_init(|| Mutex::new(()))
}

fn pending_shortcuts() -> &'static Mutex<HashMap<u64, mpsc::Sender<Value>>> {
    PENDING_SHORTCUTS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) fn finish_shortcut(request: u64, result: Value) -> bool {
    pending_shortcuts()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .remove(&request)
        .is_some_and(|sender| sender.send(result).is_ok())
}

/// Private mode pauses capture and sharing (Clipboard's one pause setting).
fn menu_items(paused: bool) -> Vec<MenuItem> {
    vec![MenuItem {
        id: "private-mode".into(),
        title: "Private mode".into(),
        kind: MenuKind::Toggle,
        checked: Some(paused),
        enabled: true,
        effects: vec!["persists".into()],
    }]
}

fn manifest_document(
    settings: &LinkSettings,
    paused: bool,
    locations: &Locations,
    core: &Core,
) -> ManifestDocument {
    let additions = ManifestAdditions {
        menu: menu_items(paused),
        logs: Some(core.data_dir().join("logs").to_string_lossy().into_owned()),
        docs: Some(Docs {
            version: env!("CARGO_PKG_VERSION").into(),
        }),
        install: Some(install_method(locations)),
        ..ManifestAdditions::default()
    };
    ManifestDocument {
        manifest: manifest(settings),
        additions,
    }
}

fn install_method(locations: &Locations) -> InstallMethod {
    if let Ok(Some(receipt)) = arcade_link::receipt::Store::new(locations).read(ids::CLIPBOARD) {
        return receipt.method;
    }
    let executable_path = arcade_link::manifest::current_executable();
    let executable = Path::new(&executable_path);
    if std::env::var("ARCADE_DEV_BUILD").as_deref() == Ok("1")
        || arcade_link::install::is_dev_build(executable)
    {
        return InstallMethod::Dev;
    }
    if std::env::var_os("APPIMAGE").is_some() && std::env::var_os("APPDIR").is_some() {
        InstallMethod::Appimage
    } else {
        InstallMethod::Manual
    }
}

/// Publish optional manifest fields and verify the atomic write. Presence's
/// additive update API has no result, so a reader must never observe success
/// when the cached menu or settings failed to reach the registry.
fn refresh_document(core: &Arc<Core>, runtime: &Handle) -> Result<(), LinkError> {
    let settings = settings_slot()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .ok_or_else(|| LinkError::unavailable("Arcade Clipboard Link settings are unavailable"))?;
    let values = runtime
        .block_on(core.request(json!({"op": "settings"})))
        .map_err(LinkError::unavailable)?;
    let locations = Locations::discover();
    let document = manifest_document(
        &settings,
        values["paused"].as_bool().unwrap_or(false),
        &locations,
        core,
    );
    let path = locations.manifest(ids::CLIPBOARD);
    let previous = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| ManifestDocument::from_json(&text).ok());
    let presence = slot()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .ok_or_else(|| LinkError::unavailable("Arcade Clipboard Link is not running"))?;
    presence.update_document(document.clone());
    let verified = std::fs::read_to_string(&path)
        .map_err(|e| LinkError::unavailable(format!("couldn't read the published manifest: {e}")))
        .and_then(|text| ManifestDocument::from_json(&text).map_err(LinkError::unavailable))
        .map(|written| {
            let mut expected = document.clone();
            expected.manifest.written_at = written.manifest.written_at.clone();
            written == expected
        });
    if matches!(verified, Ok(true)) {
        return Ok(());
    }
    let reason = match verified {
        Ok(false) => "the published manifest differs from the requested settings".to_string(),
        Err(error) => error.to_string(),
        Ok(true) => unreachable!(),
    };
    if let Some(previous) = previous {
        presence.update_document(previous.clone());
        let rollback = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| ManifestDocument::from_json(&text).ok())
            .is_some_and(|restored| {
                let mut expected = previous;
                expected.manifest.written_at = restored.manifest.written_at.clone();
                restored == expected
            });
        if !rollback {
            return Err(LinkError::unavailable(format!(
                "{reason}; restoring the previous manifest also failed"
            )));
        }
    }
    Err(LinkError::unavailable(reason))
}

/// Writes the manifest and starts listening. Blocking: call it from a
/// blocking task of the core's runtime (requests run on that runtime).
pub(crate) fn start(core: &Arc<Core>, settings: &LinkSettings) {
    *settings_slot().lock().unwrap_or_else(|e| e.into_inner()) = Some(settings.clone());
    let runtime = Handle::current();
    let locations = Locations::discover();
    let core_settings = runtime
        .block_on(core.request(json!({"op": "settings"})))
        .unwrap_or_else(|_| json!({}));
    let handler = Arc::new(ClipboardHandler {
        mode: settings.mode,
        core: Arc::downgrade(core),
        runtime: runtime.clone(),
    });
    let document = manifest_document(
        settings,
        core_settings["paused"].as_bool().unwrap_or(false),
        &locations,
        core,
    );
    let presence = Presence::start_document(locations.clone(), document, handler);
    *slot().lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(presence));

    let watcher = TrayHostWatcher::start(
        WatcherConfig {
            locations,
            app: arcade_link::PeerInfo {
                id: ids::CLIPBOARD.into(),
                version: env!("CARGO_PKG_VERSION").into(),
            },
            link_enabled: settings.enabled,
            has_tray: settings.has_tray,
        },
        |state| {
            push_event(json!({"kind": "tray_host", "hosted": state == TrayState::Hosted}));
        },
    );
    match watcher {
        Ok(watcher) => {
            *tray_slot().lock().unwrap_or_else(|e| e.into_inner()) = Some(watcher);
        }
        Err(error) => {
            push_event(json!({"kind": "tray_host", "hosted": false}));
            eprintln!("arcade-clipboard: tray-host watch unavailable: {error}");
        }
    }
    crate::link_consumer::start(settings);
}

/// Applies changed settings (the Link switch, peers, the shortcut).
pub(crate) fn configure(settings: &LinkSettings) {
    let previous = settings_slot()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .replace(settings.clone());
    let presence = slot().lock().unwrap_or_else(|e| e.into_inner()).clone();
    if let Some(p) = presence {
        p.update(manifest(settings));
    }
    if previous
        .as_ref()
        .is_some_and(|old| old.has_tray != settings.has_tray)
    {
        if let Some(watcher) = tray_slot().lock().unwrap_or_else(|e| e.into_inner()).take() {
            watcher.stop();
        }
        let locations = Locations::discover();
        match TrayHostWatcher::start(
            WatcherConfig {
                locations,
                app: arcade_link::PeerInfo {
                    id: ids::CLIPBOARD.into(),
                    version: env!("CARGO_PKG_VERSION").into(),
                },
                link_enabled: settings.enabled,
                has_tray: settings.has_tray,
            },
            |state| push_event(json!({"kind":"tray_host","hosted":state == TrayState::Hosted})),
        ) {
            Ok(watcher) => *tray_slot().lock().unwrap_or_else(|e| e.into_inner()) = Some(watcher),
            Err(error) => {
                push_event(json!({"kind":"tray_host","hosted":false}));
                eprintln!("arcade-clipboard: tray-host watch unavailable: {error}");
            }
        }
    } else if let Some(watcher) = tray_slot()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
    {
        watcher.set_link_enabled(settings.enabled);
    }
    crate::link_consumer::configure(settings);
}

/// Stops listening and removes the endpoint file (the manifest stays).
/// Open picks end as cancelled.
pub(crate) fn stop() {
    crate::link_consumer::stop();
    if let Some(watcher) = tray_slot().lock().unwrap_or_else(|e| e.into_inner()).take() {
        watcher.stop();
    }
    if let Some(p) = slot().lock().unwrap_or_else(|e| e.into_inner()).take() {
        p.stop();
    }
    let open: Vec<Job> = picks()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .drain()
        .map(|(_, j)| j)
        .collect();
    for job in open {
        job.finish(Err(LinkError::cancelled()));
    }
}

/// State for the Connected apps diagnostics.
pub(crate) fn diagnostics() -> Value {
    let locations = Locations::discover();
    let presence = slot().lock().unwrap_or_else(|e| e.into_inner()).clone();
    json!({
        "registry": locations.registry.display().to_string(),
        "listening": presence.as_ref().is_some_and(|p| p.listening()),
        "last_error": presence.and_then(|p| p.last_error()),
    })
}

/// `--quit` without a desktop single-instance channel: ask the running
/// instance over the Link. Returns whether one answered.
pub(crate) fn quit_running() -> bool {
    let me = arcade_link::PeerInfo {
        id: format!("{}-cli", ids::CLIPBOARD),
        version: env!("CARGO_PKG_VERSION").into(),
    };
    arcade_link::Client::connect(&Locations::discover(), ids::CLIPBOARD, &me)
        .and_then(|mut c| c.call("app.quit", json!({ "force": true })))
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn busy_ui_receives_current_tray_ownership_without_replaying_old_icons() {
        let mut queue = VecDeque::new();
        enqueue_event(&mut queue, json!({"kind": "pick", "request": 7}));
        for _ in 0..40 {
            enqueue_event(&mut queue, json!({"kind": "tray_host", "hosted": false}));
            enqueue_event(&mut queue, json!({"kind": "tray_host", "hosted": true}));
        }
        enqueue_event(&mut queue, json!({"kind": "quit"}));
        assert_eq!(queue.len(), 3);
        assert_eq!(queue.pop_front().unwrap()["request"], 7);
        assert_eq!(
            queue.pop_front().unwrap(),
            json!({"kind": "tray_host", "hosted": true})
        );
        assert_eq!(queue.pop_front().unwrap()["kind"], "quit");
        enqueue_event(&mut queue, json!({"kind": "tray_host", "hosted": false}));
        assert_eq!(queue.pop_front().unwrap()["hosted"], false);
    }

    const PNG: &[u8] = &[
        0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', 0, 0, 0, 13, b'I', b'H', b'D', b'R', 0,
        0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89,
    ];

    #[test]
    fn exposes_the_catalog_actions() {
        let ids: Vec<_> = actions().into_iter().map(|a| a.id).collect();
        assert_eq!(
            ids,
            ["clipboard.add", "clipboard.pick", "clipboard.devices"]
        );
        let add = actions().remove(0);
        assert_eq!(add.max_bytes, Some(16 * 1024 * 1024));
        assert!(add.has_effect("sends-to-device"));
    }

    #[test]
    fn text_becomes_a_clip_with_long_text_as_a_representation() {
        let clip = clip_for(&Content::url("https://example.com")).unwrap();
        assert_eq!(
            (clip.kind, clip.text.as_str()),
            ("url", "https://example.com")
        );
        assert!(clip.representations.is_empty());

        let long = "é".repeat(20_000);
        let clip = clip_for(&Content::plain(long.clone())).unwrap();
        assert_eq!(clip.kind, "text");
        assert!(clip.text.len() <= MAX_TEXT_FIELD && long.starts_with(&clip.text));
        assert_eq!(clip.representations[0].mime_type, "text/plain");
        crate::payload::validate_payload(&clip.text, clip.kind, &clip.representations).unwrap();

        let mut rich = Content::text("text/rich", "Hi");
        rich.html = Some("<b>Hi</b>".into());
        let clip = clip_for(&rich).unwrap();
        assert_eq!(clip.kind, "rich_text");
        assert_eq!(clip.representations.len(), 2);

        assert_eq!(
            clip_for(&Content::plain("  ")).unwrap_err().code,
            arcade_link::ErrorCode::UnsupportedInput
        );
    }

    #[test]
    fn files_become_image_or_file_clips_within_the_limits() {
        let dir = tempfile::tempdir().unwrap();
        let png = dir.path().join("shot.png");
        std::fs::write(&png, PNG).unwrap();
        let clip = clip_for(&Content::file(&png)).unwrap();
        assert_eq!(clip.kind, "image");
        crate::payload::validate_payload(&clip.text, clip.kind, &clip.representations).unwrap();

        let txt = dir.path().join("notes.txt");
        std::fs::write(&txt, "hello").unwrap();
        let clip = clip_for(&Content::files(&[&png, &txt])).unwrap();
        assert_eq!(clip.kind, "files");
        assert_eq!(clip.representations[1].name.as_deref(), Some("notes.txt"));
        crate::payload::validate_payload(&clip.text, clip.kind, &clip.representations).unwrap();

        let big = dir.path().join("big.bin");
        std::fs::File::create(&big)
            .unwrap()
            .set_len(MAX_PAYLOAD_BYTES as u64 + 1)
            .unwrap();
        let err = clip_for(&Content::file(&big)).unwrap_err();
        assert_eq!(err.code, arcade_link::ErrorCode::TooLarge);
        assert_eq!(err.limit, Some(MAX_PAYLOAD_BYTES as u64));

        let many: Vec<_> = (0..33).map(|_| txt.as_path()).collect();
        assert_eq!(
            clip_for(&Content::files(&many)).unwrap_err().code,
            arcade_link::ErrorCode::TooLarge
        );
    }

    #[test]
    fn capture_errors_map_to_link_codes() {
        use arcade_link::ErrorCode::*;
        let code = |m: &str| capture_error(m.into()).code;
        assert_eq!(code("Mesh capture is paused"), Denied);
        assert_eq!(
            capture_error("Mesh capture is paused".into())
                .reason
                .as_deref(),
            Some("private_mode")
        );
        assert_eq!(
            code("Create or join a mesh before capturing clipboard text"),
            Unavailable
        );
        assert_eq!(code("Clipboard payload exceeds the 16 MiB limit"), TooLarge);
    }

    #[test]
    fn picked_clips_become_link_content() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("ARCADE_HOME", dir.path());
        let text =
            picked_content(&json!({"kind": "url", "text": "https://a.b", "representations": []}))
                .unwrap();
        assert_eq!(
            (text.kind.as_str(), text.text.as_deref()),
            ("text/url", Some("https://a.b"))
        );

        let reps = vec![representation("image/png", PNG, None)];
        let image =
            picked_content(&json!({"kind": "image", "text": "", "representations": reps})).unwrap();
        assert_eq!(image.kind, "file/image");
        assert_eq!(image.owner.as_deref(), Some(ids::CLIPBOARD));
        assert_eq!(std::fs::read(image.path.unwrap()).unwrap(), PNG);

        let reps = vec![
            representation("application/octet-stream", b"a", Some("a.txt")),
            representation("application/octet-stream", b"b", Some("b.txt")),
        ];
        let files =
            picked_content(&json!({"kind": "files", "text": "", "representations": reps})).unwrap();
        assert_eq!(files.paths.len(), 2);
        assert!(files.kind.ends_with("[]"));
    }

    #[test]
    fn devices_list_other_devices_without_ids() {
        let devices = json!({"devices": [
            {"device_id": "me", "device_name": "Laptop", "platform": "Linux", "state": "online"},
            {"device_id": "p", "device_name": "Phone", "platform": "iOS", "state": "offline"},
            {"device_id": "old", "device_name": "Old", "platform": "Android", "state": "revoked"},
        ]});
        assert_eq!(
            device_list(&devices, "me"),
            json!([{"name": "Phone", "platform": "ios", "online": false}])
        );
    }
}
