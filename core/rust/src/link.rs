//! Arcade Link: Arcade Clipboard's presence among the other Arcade apps.
//!
//! The server starts in the core's `initialize` (off the UI) and stops at
//! `shutdown`. Dart has no IPC code: it passes the Link settings in
//! `initialize` and `link_configure`. Desktop only; phones benefit
//! indirectly (content sent to "my devices" arrives there).

use crate::Core;
use arcade_link::server::{Handler, InvokeContext, Reply};
use arcade_link::{ids, Action, InvokeRequest, LinkError, Locations, Manifest, Presence};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use tokio::sync::Notify;

/// "Connect with other Arcade apps", the per-app toggles and the effective
/// picker shortcut, as Dart passes them.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct LinkSettings {
    pub enabled: bool,
    pub disabled_peers: Vec<String>,
    pub shortcut: Option<String>,
}

impl LinkSettings {
    pub(crate) fn from_request(value: Option<&Value>) -> Self {
        let value = value.cloned().unwrap_or_else(|| json!({}));
        Self {
            enabled: value
                .get("enabled")
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
        env!("CARGO_PKG_VERSION"),
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
    Vec::new()
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
    events()
        .queue
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push_back(event);
    events().ready.notify_one();
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

struct ClipboardHandler {
    #[allow(dead_code)]
    core: Weak<Core>,
}

impl Handler for ClipboardHandler {
    fn describe(&self) -> Vec<Action> {
        actions()
    }

    fn invoke(&self, request: InvokeRequest, _ctx: &InvokeContext) -> Result<Reply, LinkError> {
        Err(LinkError::unavailable(format!(
            "Arcade Clipboard has no action {}",
            request.action
        )))
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

fn slot() -> &'static Mutex<Option<Arc<Presence>>> {
    PRESENCE.get_or_init(|| Mutex::new(None))
}

/// Writes the manifest and starts listening. Blocking: call it from a
/// blocking task.
pub(crate) fn start(core: &Arc<Core>, settings: &LinkSettings) {
    let handler = Arc::new(ClipboardHandler {
        core: Arc::downgrade(core),
    });
    let presence = Presence::start(Locations::discover(), manifest(settings), handler);
    *slot().lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(presence));
}

/// Applies changed settings (the Link switch, peers, the shortcut).
pub(crate) fn configure(settings: &LinkSettings) {
    let presence = slot().lock().unwrap_or_else(|e| e.into_inner()).clone();
    if let Some(p) = presence {
        p.update(manifest(settings));
    }
}

/// Stops listening and removes the endpoint file (the manifest stays).
pub(crate) fn stop() {
    if let Some(p) = slot().lock().unwrap_or_else(|e| e.into_inner()).take() {
        p.stop();
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
