//! Desktop consumers. Discovery and all file/IPC work run on Rust workers.
//! The Dart menus use snapshots; only OS directory notifications refresh them.

use crate::link::{self, LinkSettings};
use crate::Core;
use arcade_link::catalog::Catalog;
use arcade_link::client::{self, AppState};
use arcade_link::manifest::surface;
use arcade_link::offers::{Item, Prefs};
use arcade_link::wire::{JobDone, JobProgress, LineReader, Message};
use arcade_link::{
    ids, Action, Client, Content, ErrorCode, Handoff, InvokeRequest, InvokeResult, LinkError,
    Locations, Manifest, PeerInfo, SharedRegistry,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

struct Consumer {
    registry: SharedRegistry,
    settings: LinkSettings,
    watching: bool,
}

fn consumer() -> &'static Mutex<Option<Consumer>> {
    static VALUE: OnceLock<Mutex<Option<Consumer>>> = OnceLock::new();
    VALUE.get_or_init(Default::default)
}

fn jobs() -> &'static Mutex<HashMap<u64, Arc<AtomicBool>>> {
    static VALUE: OnceLock<Mutex<HashMap<u64, Arc<AtomicBool>>>> = OnceLock::new();
    VALUE.get_or_init(Default::default)
}

struct StagedImage {
    _handoff: Handoff,
    content: Content,
}

fn staged() -> &'static Mutex<HashMap<u64, StagedImage>> {
    static VALUE: OnceLock<Mutex<HashMap<u64, StagedImage>>> = OnceLock::new();
    VALUE.get_or_init(Default::default)
}

fn next_id() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

fn me() -> PeerInfo {
    PeerInfo {
        id: ids::CLIPBOARD.into(),
        version: env!("CARGO_PKG_VERSION").into(),
    }
}

pub(crate) fn start(settings: &LinkSettings) {
    let registry = SharedRegistry::load(&Locations::discover());
    let watching = registry.watch(|_| link::push_event(json!({"kind": "registry_changed"})));
    *consumer().lock().unwrap_or_else(|e| e.into_inner()) = Some(Consumer {
        registry,
        settings: settings.clone(),
        watching,
    });
    link::push_event(json!({"kind": "registry_changed"}));
}

pub(crate) fn configure(settings: &LinkSettings) {
    if let Some(c) = consumer()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
    {
        c.settings = settings.clone();
    }
    // Turning a connection off also cancels its work. No results are imported
    // after the user disables connections.
    if !settings.enabled {
        for flag in jobs().lock().unwrap_or_else(|e| e.into_inner()).values() {
            flag.store(true, Ordering::SeqCst);
        }
        staged().lock().unwrap_or_else(|e| e.into_inner()).clear();
    }
    link::push_event(json!({"kind": "registry_changed"}));
}

pub(crate) fn stop() {
    consumer().lock().unwrap_or_else(|e| e.into_inner()).take();
    for flag in jobs().lock().unwrap_or_else(|e| e.into_inner()).values() {
        flag.store(true, Ordering::SeqCst);
    }
    staged().lock().unwrap_or_else(|e| e.into_inner()).clear();
}

fn snapshot() -> Result<(arcade_link::Registry, LinkSettings), LinkError> {
    consumer()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .map(|c| (c.registry.snapshot(), c.settings.clone()))
        .ok_or_else(|| LinkError::unavailable("connections are starting"))
}

/// At most this many entries from one app on a clip's menu, the app's own order (Link's `offers`) deciding which.
const PER_APP: usize = 4;

/// The Ctrl+Alt letters Clipboard has always used for these actions, so people keep their habits. Any other entry
/// takes the first free letter of its title. This only names keys: which actions show is Link's answer.
const LETTERS: &[(&str, &str, char)] = &[
    (ids::LOOK, "look.preview", 'Q'),
    (ids::LENS, "lens.analyze", 'A'),
    (ids::LENS, "lens.pin", 'P'),
    (ids::LENS, "lens.recognize:core.ocr", 'E'),
    (ids::SHELF, "shelf.add", 'H'),
];

fn clip_type(kind: &str) -> &'static str {
    match kind {
        "image" => "file/image",
        "file" => "file/any",
        "files" => "file/any[]",
        "url" => "text/url",
        "rich_text" => "text/rich",
        _ => "text/plain",
    }
}

/// Where a clip of this kind sits among Link's surfaces: a picture or a file is what a file manager menu shows, a
/// link what a browser shows on links, text what it shows on a selection.
fn clip_surface(kind: &str) -> &'static str {
    match kind {
        "image" | "file" | "files" => surface::FILE_MENU,
        "url" => surface::BROWSER_LINK,
        _ => surface::BROWSER_SELECTION,
    }
}

/// Whether the action's result comes back into Clipboard's history: it hands back text, a file or a JSON document
/// and runs without a window of its own. Showing something (Quick Look, Pin) or keeping it (Shelf) doesn't.
fn imports_result(action: &Action) -> bool {
    !action.interactive
        && action.produces.iter().any(|t| {
            let family = arcade_link::content::family(t);
            family == "text" || family == "file" || t == "structured/json"
        })
}

/// Another app's action that Clipboard can run on a clip.
fn item_action(peer: &Manifest, action: &Action) -> bool {
    // Tools installs apps and Clipboard doesn't call itself; Box before 1.0 lists its pipelines through a generic
    // runner that needs a pipeline Clipboard doesn't pick (from 1.0 each saved pipeline is an action of its own).
    !(peer.id == ids::TOOLS
        || peer.id == ids::CLIPBOARD
        || (peer.id == ids::BOX
            && matches!(action.id.as_str(), "box.pipelines" | "box.pipeline.run")))
}

fn offers(
    locations: &Locations,
    registry: &arcade_link::Registry,
    settings: &LinkSettings,
    kind: &str,
) -> Vec<Value> {
    if !settings.enabled {
        return Vec::new();
    }
    let peers: Vec<Manifest> = registry
        .peers(ids::CLIPBOARD)
        .filter(|peer| !settings.disabled_peers.contains(&peer.id))
        .cloned()
        .collect();
    let rules = Catalog::load(locations).rules;
    let prefs = Prefs::load(locations);
    let item = Item::new(clip_type(kind));
    let mut values: Vec<Value> = Vec::new();
    let mut per_app: HashMap<String, usize> = HashMap::new();
    let mut used: Vec<char> = Vec::new();
    for offer in arcade_link::offers::offers(&[item], clip_surface(kind), &peers, &rules, &prefs) {
        // An action that needs an engine installed first: Clipboard doesn't install engines.
        if offer.install.is_some() {
            continue;
        }
        let Some(peer) = peers.iter().find(|p| p.id == offer.app) else {
            continue;
        };
        let Some(action) = peer.action(&offer.action) else {
            continue;
        };
        if !item_action(peer, action) {
            continue;
        }
        let shown = per_app.entry(offer.app.clone()).or_default();
        if *shown >= PER_APP {
            continue;
        }
        *shown += 1;
        let letter = LETTERS
            .iter()
            .find(|(app, id, _)| *app == offer.app && *id == offer.action)
            .map(|(_, _, l)| *l)
            .filter(|l| !used.contains(l))
            .or_else(|| {
                offer
                    .title
                    .chars()
                    .filter(char::is_ascii_alphabetic)
                    .map(|c| c.to_ascii_uppercase())
                    .find(|c| !used.contains(c) && !LETTERS.iter().any(|(_, _, l)| l == c))
            });
        if let Some(l) = letter {
            used.push(l);
        }
        let limit_reason = action
            .max_bytes
            .map(|limit| LinkError::too_large(limit).user_message(&peer.name));
        values.push(
            json!({"peer": offer.app, "action": offer.action, "version": action.version,
            "title": offer.title, "import": imports_result(action),
            "shortcut": letter.map(String::from).unwrap_or_default(),
            "available": true, "reason": offer.reason,
            "max_bytes": action.max_bytes, "limit_reason": limit_reason,
            "effects": action.effects, "privacy": action.privacy}),
        );
    }
    values
}

/// Box's "compress to 200 KB" preset, the one action Clipboard offers for a copied photo too large to sync (16 to
/// 32 MiB): Clipboard's own feature, so it names the action instead of taking a menu entry by its title.
const COMPRESS: &str = "box:arcade.image.compress#web-200kb";

fn compress_offer(registry: &arcade_link::Registry, settings: &LinkSettings) -> Option<Value> {
    if !settings.enabled || settings.disabled_peers.iter().any(|p| p == ids::BOX) {
        return None;
    }
    let peer = registry.get(ids::BOX).filter(|p| p.settings.link_enabled)?;
    let photo = Content {
        kind: "file/image".into(),
        ..Default::default()
    };
    let action = peer.action(COMPRESS).filter(|a| a.offer_for(&photo))?;
    Some(
        json!({"peer": ids::BOX, "action": COMPRESS, "version": action.version,
        "title": "Compress", "import": imports_result(action), "shortcut": "",
        "available": true, "reason": Value::Null, "max_bytes": action.max_bytes, "limit_reason": Value::Null,
        "effects": action.effects, "privacy": action.privacy}),
    )
}

pub(crate) fn all_offers() -> Value {
    let Ok((registry, settings)) = snapshot() else {
        return json!({"offers": {}});
    };
    let locations = Locations::discover();
    let mut by_kind: serde_json::Map<String, Value> =
        ["text", "url", "rich_text", "image", "file", "files"]
            .into_iter()
            .map(|kind| {
                (
                    kind.into(),
                    json!(offers(&locations, &registry, &settings, kind)),
                )
            })
            .collect();
    by_kind.insert(
        "compress".into(),
        json!(compress_offer(&registry, &settings)
            .into_iter()
            .collect::<Vec<_>>()),
    );
    json!({"offers": by_kind})
}

pub(crate) fn peers() -> Value {
    let locations = Locations::discover();
    let Ok((registry, settings)) = snapshot() else {
        return json!({"peers": []});
    };
    // The apps in Arcade Tools' shared app list (the built-in list without it), so a new Arcade app appears here
    // without a Clipboard update.
    let catalog = Catalog::load(&locations);
    let rows: Vec<Value> = catalog
        .app_ids()
        .into_iter()
        .filter(|id| id != ids::CLIPBOARD)
        .map(|id| {
            let (state, version) = match client::app_state(&locations, &registry, &id, &me()) {
                AppState::Running { version } => ("Running", version),
                AppState::Installed { version } => ("Installed", version),
                AppState::NotInstalled => ("Not installed", String::new()),
            };
            json!({"id": id, "name": catalog.name(&id), "state": state,
            "version": version, "enabled": !settings.disabled_peers.contains(&id),
            "link_enabled": registry.get(&id).is_none_or(|p| p.settings.link_enabled),
            "pitch": catalog.pair(ids::CLIPBOARD, &id), "url": catalog.releases_url(&id)})
        })
        .collect();
    let shortcuts: Vec<Value> = registry
        .shortcuts(ids::CLIPBOARD)
        .map(|(name, _, accelerator)| json!({"name": name, "accelerator": accelerator}))
        .collect();
    let watching = consumer()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .is_some_and(|c| c.watching);
    json!({"peers": rows, "shortcuts": shortcuts, "watching": watching,
        "tools_installed": settings.enabled && !settings.disabled_peers.iter().any(|id| id == ids::TOOLS)
            && registry.get(ids::TOOLS).is_some_and(|m| m.settings.link_enabled
                && m.action("tools.install").is_some_and(|a| a.available && a.on_this_platform()))})
}

/// Chunked local staging keeps oversized photos outside history and the mesh.
/// No request increases the existing JSON boundary's size limit.
pub(crate) fn stage(value: &Value) -> Result<Value, LinkError> {
    if value["discard"].as_bool() == Some(true) {
        if let Some(id) = value["stage"].as_u64() {
            staged()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id);
        }
        return Ok(json!({"discarded": true}));
    }
    if let Some(id) = value["stage"].as_u64() {
        let bytes = STANDARD
            .decode(value["data_base64"].as_str().unwrap_or_default())
            .map_err(|_| LinkError::unsupported("damaged image data"))?;
        let mut stages = staged().lock().unwrap_or_else(|e| e.into_inner());
        let stage = stages
            .get_mut(&id)
            .ok_or_else(|| LinkError::unavailable("the photo is no longer waiting"))?;
        let size = stage.content.size.unwrap_or(0) + bytes.len() as u64;
        if size > 32 * 1024 * 1024 {
            return Err(LinkError::too_large(32 * 1024 * 1024));
        }
        let path = stage
            .content
            .path
            .as_ref()
            .ok_or_else(|| LinkError::internal("missing image file"))?;
        std::fs::OpenOptions::new()
            .append(true)
            .open(path)
            .and_then(|mut f| f.write_all(&bytes))
            .map_err(|e| LinkError::internal(e.to_string()))?;
        stage.content.size = Some(size);
        return Ok(json!({"stage": id, "size": size}));
    }
    let (_, settings) = snapshot()?;
    if !settings.enabled || settings.disabled_peers.iter().any(|p| p == ids::BOX) {
        return Err(LinkError::denied("disabled"));
    }
    let mime = value["mime"].as_str().unwrap_or_default();
    let name = match mime {
        "image/png" => "photo.png",
        "image/jpeg" => "photo.jpg",
        _ => return Err(LinkError::unsupported("image required")),
    };
    let h = Handoff::create(&Locations::discover(), ids::CLIPBOARD)
        .map_err(|e| LinkError::internal(e.to_string()))?;
    let content = h
        .file(name, &[])
        .map_err(|e| LinkError::internal(e.to_string()))?;
    let id = next_id();
    // One waiting photo. Replaced staging is disposed immediately.
    let mut stages = staged().lock().unwrap_or_else(|e| e.into_inner());
    stages.clear();
    stages.insert(
        id,
        StagedImage {
            _handoff: h,
            content,
        },
    );
    Ok(json!({"stage": id}))
}

pub(crate) fn cancel(request: u64) -> bool {
    let map = jobs().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(flag) = map.get(&request) {
        flag.store(true, Ordering::SeqCst);
        true
    } else {
        false
    }
}

pub(crate) fn begin(core: Arc<Core>, value: Value) -> Value {
    let id = next_id();
    let cancel = Arc::new(AtomicBool::new(false));
    jobs()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, cancel.clone());
    tokio::spawn(async move {
        let peer = value["peer"].as_str().unwrap_or_default().to_string();
        let result = run(core, value, id, cancel).await;
        jobs().lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
        let event = match result {
            Ok(result) => json!({"kind": "invoke_done", "request": id, "result": result}),
            Err(e) => json!({"kind": "invoke_done", "request": id, "error": e,
                "message": e.user_message(&if e.reason.as_deref() == Some("private_mode") { "Arcade Clipboard".to_string() } else { Catalog::load(&Locations::discover()).name(&peer) })}),
        };
        link::push_event(event);
    });
    json!({"request": id})
}

async fn run(
    core: Arc<Core>,
    value: Value,
    id: u64,
    cancel: Arc<AtomicBool>,
) -> Result<InvokeResult, LinkError> {
    let install = value["peer"] == ids::TOOLS && value["action"] == "tools.install";
    let status = core
        .request(json!({"op": "status"}))
        .await
        .map_err(LinkError::internal)?;
    if !install && status["paused"] == true {
        return Err(LinkError::denied("private_mode"));
    }
    let payload = if let Some(item) = value["item_id"].as_str() {
        Some(
            core.request(json!({"op": "payload", "id": item}))
                .await
                .map_err(LinkError::unavailable)?,
        )
    } else {
        None
    };
    let peer = value["peer"].as_str().unwrap_or_default().to_string();
    let peer_for_import = peer.clone();
    let action_id = value["action"].as_str().unwrap_or_default().to_string();
    let cancel_after = cancel.clone();
    let (result, import, _handoff) = tokio::task::spawn_blocking(move || {
        let (registry, settings) = snapshot()?;
        if !settings.enabled || settings.disabled_peers.contains(&peer) {
            return Err(LinkError::denied("disabled"));
        }
        let manifest = registry
            .get(&peer)
            .ok_or_else(|| LinkError::new(ErrorCode::NotInstalled, "peer missing"))?
            .clone();
        if !manifest.settings.link_enabled {
            return Err(LinkError::denied("disabled"));
        }
        let action = manifest
            .action(&action_id)
            .ok_or_else(|| LinkError::unavailable("action is no longer available"))?
            .clone();
        if !install && !item_action(&manifest, &action) {
            return Err(LinkError::unsupported("not an item action"));
        }
        let import = !install && imports_result(&action);
        if !action.available {
            return Err(LinkError::unavailable(
                action.reason.clone().unwrap_or_default(),
            ));
        }
        let handoff = Handoff::create(&Locations::discover(), ids::CLIPBOARD)
            .map_err(|e| LinkError::internal(e.to_string()))?;
        let (input, stage_guard) = if install {
            let app = value["options"]["app"].as_str().unwrap_or_default();
            if !known_app(app) {
                return Err(LinkError::unsupported("unknown app"));
            }
            (Content::default(), None)
        } else if let Some(stage) = value["stage"].as_u64() {
            let staged = staged()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&stage)
                .ok_or_else(|| LinkError::unavailable("the photo is no longer waiting"))?;
            (staged.content.clone(), Some(staged))
        } else if let Some(payload) = payload {
            (link::payload_content(&payload, &handoff)?, None)
        } else {
            (
                serde_json::from_value::<Content>(value["input"].clone())
                    .map_err(|_| LinkError::unsupported("missing clip"))?,
                None,
            )
        };
        if input.hints.iter().any(|h| h == "secret") {
            return Err(LinkError::denied("secret"));
        }
        if !action.on_this_platform()
            || (!install && !arcade_link::content::accepts_content(&action.accepts, &input))
        {
            return Err(LinkError::unsupported("clip kind"));
        }
        let size = input
            .size
            .or_else(|| input.text.as_ref().map(|s| s.len() as u64))
            .or_else(|| {
                let paths = input.all_paths();
                (!paths.is_empty()).then(|| {
                    paths
                        .iter()
                        .filter_map(|p| std::fs::metadata(p).ok())
                        .map(|m| m.len())
                        .sum()
                })
            })
            .unwrap_or(0);
        if let Some(limit) = action.max_bytes {
            if size > limit {
                return Err(LinkError::too_large(limit));
            }
        }
        let (base_action, id_preset) = action
            .id
            .split_once('#')
            .map_or((action.id.as_str(), None), |(a, p)| (a, Some(p)));
        let mut request = InvokeRequest::new(base_action, ids::CLIPBOARD)
            .preset(action.preset.as_deref().or(id_preset));
        if install {
            request.options = json!({"app": value["options"]["app"]});
        } else {
            request.inputs.push(input);
        }
        request.version = Some(action.version);
        // Keep all Lens recognizers enabled so secret findings accompany OCR.
        let timeout = Duration::from_millis(
            value["timeout_ms"]
                .as_u64()
                .unwrap_or(120_000)
                .clamp(100, 300_000),
        );
        let mut result = invoke_bounded(&manifest, &request, id, &cancel, timeout)?;
        // A JSON document handed back inline (Box's JSON formatter) joins the
        // history as its text. Other structured results (Lens findings) stay
        // structured and aren't imported.
        if import {
            for output in &mut result.outputs {
                if output.kind == "structured/json" && output.text.is_some() {
                    output.kind = "text/plain".into();
                }
            }
        }
        Ok::<_, LinkError>((result, import, (handoff, stage_guard)))
    })
    .await
    .map_err(|_| LinkError::internal("item action worker stopped"))??;
    if cancel_after.load(Ordering::SeqCst) {
        return Err(LinkError::cancelled());
    }
    let (_, settings) = snapshot()?;
    if !settings.enabled || settings.disabled_peers.contains(&peer_for_import) {
        return Err(LinkError::denied("disabled"));
    }
    if import {
        if result.outputs.iter().any(|output| {
            output.hints.iter().any(|h| h == "secret")
                || (output.kind == "structured/findings"
                    && output
                        .data
                        .as_ref()
                        .and_then(Value::as_array)
                        .is_some_and(|findings| {
                            findings.iter().any(|f| f["capability"] == "secret")
                        }))
        }) {
            return Err(LinkError::denied("secret"));
        }
        if let Some(output) = result
            .outputs
            .iter()
            .find(|c| c.kind.starts_with("text/") || c.kind.starts_with("file/"))
        {
            let output = output.clone();
            let clip = match tokio::task::spawn_blocking(move || link::clip_for(&output))
                .await
                .map_err(|_| LinkError::internal("couldn't import result"))?
            {
                Ok(clip) => clip,
                // The app did its work and kept the result where it saves
                // results; it is only too big to become a clip.
                Err(e) if e.code == ErrorCode::TooLarge => return Ok(result),
                Err(e) => return Err(e),
            };
            core.request(json!({"op": "capture", "text": clip.text, "kind": clip.kind, "representations": clip.representations}))
                .await.map_err(|e| if e.contains("paused") { LinkError::denied("private_mode") } else { LinkError::unavailable(e) })?;
        }
    }
    Ok(result)
}

fn progress(id: u64, p: &JobProgress) {
    link::push_event(
        json!({"kind": "invoke_progress", "request": id, "fraction": p.fraction, "message": p.message}),
    );
}

/// The shared client's wait_job has no overall deadline. Bound active waits
/// here and drop the connection on timeout/cancel, which also cancels peer jobs.
fn invoke_bounded(
    manifest: &Manifest,
    request: &InvokeRequest,
    id: u64,
    cancel: &AtomicBool,
    timeout: Duration,
) -> Result<InvokeResult, LinkError> {
    let locations = Locations::discover();
    let deadline = Instant::now() + timeout;
    if cancel.load(Ordering::SeqCst) {
        return Err(LinkError::cancelled());
    }
    let connected = Client::connect(&locations, &manifest.id, &me());
    let mut client = match connected {
        Ok(c) => c,
        Err(_)
            if !manifest
                .action(&format!(
                    "{}{}",
                    request.action,
                    request
                        .preset
                        .as_ref()
                        .map(|p| format!("#{p}"))
                        .unwrap_or_default()
                ))
                .is_some_and(|a| a.interactive)
                && manifest.launch.invoke.is_some() =>
        {
            return one_shot(manifest, request, id, cancel, deadline)
        }
        Err(_) => {
            link::push_event(
                json!({"kind": "invoke_progress", "request": id, "message": "Starting app…"}),
            );
            client::launch_and_connect(&locations, manifest, &me())?
        }
    };
    let result = client.call(
        "invoke",
        serde_json::to_value(request).map_err(|e| LinkError::internal(e.to_string()))?,
    )?;
    let Some(job) = result["job"].as_str() else {
        return serde_json::from_value(result).map_err(|e| LinkError::internal(e.to_string()));
    };
    loop {
        let stopped = if cancel.load(Ordering::SeqCst) {
            Some(LinkError::cancelled())
        } else if Instant::now() >= deadline {
            Some(LinkError::new(ErrorCode::Timeout, "job deadline"))
        } else {
            None
        };
        if let Some(error) = stopped {
            return Err(error);
        }
        let wait = deadline
            .saturating_duration_since(Instant::now())
            .min(Duration::from_millis(100));
        let message = match client.next_notification(Some(wait)) {
            Ok(m) => m,
            Err(e) if e.code == ErrorCode::Timeout => continue,
            Err(_) => {
                return Err(LinkError::new(
                    ErrorCode::NotRunning,
                    "peer stopped while working",
                ))
            }
        };
        if message.params()["job"].as_str() != Some(job) {
            continue;
        }
        match message.method.as_deref() {
            Some("job.progress") => {
                if let Ok(p) = serde_json::from_value(message.params().clone()) {
                    progress(id, &p);
                }
            }
            Some("job.done") => {
                return serde_json::from_value::<JobDone>(message.params().clone())
                    .map_err(|e| LinkError::internal(e.to_string()))?
                    .into_result()
            }
            _ => {}
        }
    }
}

fn one_shot(
    manifest: &Manifest,
    request: &InvokeRequest,
    id: u64,
    cancel: &AtomicBool,
    deadline: Instant,
) -> Result<InvokeResult, LinkError> {
    let mut child = Command::new(&manifest.executable)
        .args(manifest.launch.invoke.as_deref().unwrap_or_default())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| LinkError::new(ErrorCode::LaunchFailed, e.to_string()))?;
    let sent = child
        .stdin
        .take()
        .ok_or_else(|| LinkError::internal("no input pipe"))
        .and_then(|mut stdin| {
            stdin
                .write_all(
                    Message::request(
                        1,
                        "invoke",
                        serde_json::to_value(request).unwrap_or(Value::Null),
                    )
                    .to_line()
                    .as_bytes(),
                )
                .map_err(|e| LinkError::internal(e.to_string()))
        });
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| LinkError::internal("no output pipe"))?;
    let (tx, rx) = mpsc::sync_channel(16);
    std::thread::spawn(move || {
        let mut reader = LineReader::new(stdout);
        loop {
            let message = reader.read_message();
            let end = !matches!(message, Ok(Some(_)));
            if tx.send(message).is_err() || end {
                break;
            }
        }
    });
    let result = sent.and_then(|_| loop {
        if cancel.load(Ordering::SeqCst) {
            break Err(LinkError::cancelled());
        }
        if Instant::now() >= deadline {
            break Err(LinkError::new(ErrorCode::Timeout, "job deadline"));
        }
        match rx.recv_timeout(
            deadline
                .saturating_duration_since(Instant::now())
                .min(Duration::from_millis(100)),
        ) {
            Ok(Ok(Some(m))) if m.id == Some(1) => {
                break match (m.result, m.error) {
                    (_, Some(e)) => Err(e),
                    (Some(r), _) => {
                        serde_json::from_value(r).map_err(|e| LinkError::internal(e.to_string()))
                    }
                    _ => Err(LinkError::internal("empty result")),
                }
            }
            Ok(Ok(Some(m))) if m.method.as_deref() == Some("job.progress") => {
                if let Ok(p) = serde_json::from_value(m.params().clone()) {
                    progress(id, &p);
                }
            }
            Ok(Ok(Some(_))) | Err(mpsc::RecvTimeoutError::Timeout) => {}
            _ => {
                break Err(LinkError::new(
                    ErrorCode::NotRunning,
                    "one-shot ended without a result",
                ))
            }
        }
    });
    // Even a provider that emits a result but forgets to exit must not leak.
    let _ = child.kill();
    let _ = child.wait();
    result
}

/// Another Arcade app Clipboard may ask Tools to install or link to: one in the shared app list.
fn known_app(app: &str) -> bool {
    app != ids::CLIPBOARD
        && Catalog::load(&Locations::discover())
            .app_ids()
            .iter()
            .any(|id| id == app)
}

/// Opens only the canonical release page for a known Arcade app.
pub(crate) fn open_releases(app: &str) -> Result<Value, LinkError> {
    if !known_app(app) {
        return Err(LinkError::unsupported("unknown app"));
    }
    let url = Catalog::load(&Locations::discover()).releases_url(app);
    let url = url.as_str();
    #[cfg(target_os = "linux")]
    let child = Command::new("xdg-open").arg(url).spawn();
    #[cfg(target_os = "macos")]
    let child = Command::new("open").arg(url).spawn();
    #[cfg(target_os = "windows")]
    let child = Command::new("rundll32.exe")
        .args(["url.dll,FileProtocolHandler", url])
        .spawn();
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    let child: std::io::Result<std::process::Child> = Err(std::io::Error::other("no URL opener"));
    let mut child = child.map_err(|e| LinkError::new(ErrorCode::LaunchFailed, e.to_string()))?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(json!({"opened": true}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offers_hide_missing_disabled_unavailable_and_wrong_kind() {
        let dir = tempfile::tempdir().unwrap();
        let locations = Locations {
            registry: dir.path().join("apps"),
            runtime: dir.path().join("run"),
            handoff: dir.path().join("handoff"),
        };
        let settings = LinkSettings::from_request(None);
        let mut registry = arcade_link::Registry::load(&locations);
        assert!(offers(&locations, &registry, &settings, "image").is_empty());
        let mut lens = Manifest::new(
            ids::LENS,
            "1.0.0",
            &std::env::current_exe().unwrap().to_string_lossy(),
        );
        lens.actions = vec![
            Action::new("lens.recognize", "OCR", "recognize")
                .accepts(&["file/image", "text/plain"])
                .produces(&["structured/findings", "text/plain"]),
            Action::new("lens.pin", "Pin", "pin")
                .accepts(&["file/image"])
                .unavailable("off"),
        ];
        arcade_link::manifest::write_manifest(&locations, &lens).unwrap();
        registry.refresh();
        let photo = offers(&locations, &registry, &settings, "image");
        assert_eq!(photo.len(), 1);
        // The card's own title, and its text result joins the history.
        assert_eq!(photo[0]["title"], "OCR");
        assert_eq!(photo[0]["import"], true);
        // Lens's card says it reads text too, so a text clip offers it as well.
        assert_eq!(offers(&locations, &registry, &settings, "text").len(), 1);
        assert!(offers(&locations, &registry, &settings, "file").is_empty());
        let off = LinkSettings::from_request(Some(&json!({"disabled_peers": [ids::LENS]})));
        assert!(offers(&locations, &registry, &off, "image").is_empty());
        let off = LinkSettings::from_request(Some(&json!({"enabled": false})));
        assert!(offers(&locations, &registry, &off, "image").is_empty());
        lens.settings.link_enabled = false;
        arcade_link::manifest::write_manifest(&locations, &lens).unwrap();
        registry.refresh();
        assert!(offers(&locations, &registry, &settings, "image").is_empty());
    }

    fn card(id: &str, actions: Vec<Action>) -> Manifest {
        let mut m = Manifest::new(
            id,
            "1.1.0",
            &std::env::current_exe().unwrap().to_string_lossy(),
        );
        m.actions = actions;
        m
    }

    fn ranked(id: &str, title: &str, rank: u8) -> Action {
        let mut a = Action::new(id, title, "convert")
            .accepts(&["file/image"])
            .produces(&["file/image"]);
        a.rank = [("file/image".to_string(), rank)].into();
        a
    }

    #[test]
    fn the_menu_is_links_answer_with_the_catalog_rules_and_the_users_choices() {
        let dir = tempfile::tempdir().unwrap();
        let locations = Locations::under(dir.path());
        let settings = LinkSettings::from_request(None);
        let mut preview = Action::new("look.preview", "Quick Look", "preview")
            .accepts(&["file/*", "text/url"])
            .interactive(true);
        preview.rank = [("*".to_string(), 30)].into();
        let mut inspect =
            Action::new("look.inspect", "Inspect file", "inspect").accepts(&["file/*"]);
        inspect.surfaces = vec!["internal".into()];
        let mut boxed: Vec<Action> = (0..6)
            .map(|i| {
                ranked(
                    &format!("box:arcade.image.t{i}"),
                    &format!("Tool {i}"),
                    40 + i * 5,
                )
            })
            .collect();
        boxed
            .push(Action::new("box.pipelines", "Saved pipelines", "list").accepts(&["file/image"]));
        boxed.push(
            Action::new("box.pipeline.run", "Run a pipeline", "run").accepts(&["file/image"]),
        );
        boxed.push(ranked("box:arcade.image.web", "Web export", 90));
        for m in [
            card(ids::LOOK, vec![preview, inspect]),
            card(ids::BOX, boxed),
            card(
                ids::TOOLS,
                vec![
                    Action::new("tools.install", "Install an Arcade app", "install")
                        .accepts(&["file/image"]),
                ],
            ),
            card(
                ids::LENS,
                vec![
                    Action::new("lens.recognize:core.ocr", "Read text", "recognize")
                        .accepts(&["file/image"])
                        .produces(&["text/plain"]),
                ],
            ),
        ] {
            arcade_link::manifest::write_manifest(&locations, &m).unwrap();
        }
        let registry = arcade_link::Registry::load(&locations);

        let image = offers(&locations, &registry, &settings, "image");
        let refs: Vec<String> = image
            .iter()
            .map(|o| {
                format!(
                    "{}/{}",
                    o["peer"].as_str().unwrap(),
                    o["action"].as_str().unwrap()
                )
            })
            .collect();
        // Box: its four highest-ranked tools, not its generic pipeline runner; Tools and Look's internal action: never.
        let from_box: Vec<&String> = refs.iter().filter(|r| r.starts_with(ids::BOX)).collect();
        assert_eq!(from_box.len(), PER_APP, "{refs:?}");
        assert_eq!(from_box[0], &format!("{}/box:arcade.image.web", ids::BOX));
        assert!(!refs.iter().any(|r| r.contains("box.pipeline")
            || r.starts_with(ids::TOOLS)
            || r.contains("inspect")));
        assert!(refs.contains(&format!("{}/look.preview", ids::LOOK)));
        // Keys: Clipboard's usual letters where it has one, the first free letter of the title otherwise, each once.
        let letter = |action: &str| {
            image.iter().find(|o| o["action"] == action).unwrap()["shortcut"].clone()
        };
        assert_eq!(letter("look.preview"), "Q");
        assert_eq!(letter("lens.recognize:core.ocr"), "E");
        let mut keys: Vec<&str> = image
            .iter()
            .filter_map(|o| o["shortcut"].as_str())
            .collect();
        let count = keys.len();
        keys.sort_unstable();
        keys.dedup();
        assert_eq!(keys.len(), count);
        // A result that is a file or text joins the history; Quick Look shows the clip.
        assert_eq!(
            image
                .iter()
                .find(|o| o["action"] == "box:arcade.image.web")
                .unwrap()["import"],
            true
        );
        assert_eq!(letter("look.preview"), "Q");
        assert_eq!(
            image
                .iter()
                .find(|o| o["action"] == "look.preview")
                .unwrap()["import"],
            false
        );
        // A link clip: Quick Look takes links; Box's image tools don't.
        let url = offers(&locations, &registry, &settings, "url");
        assert_eq!(url.len(), 1);
        assert_eq!(url[0]["action"], "look.preview");

        // The catalog renames and hides; the user hides.
        arcade_link::catalog::write_shared(
            &locations,
            &json!({"apps": [{"id": ids::BOX, "name": "Arcade Box"}], "rules": {
                "rename": {format!("{}/box:arcade.image.web", ids::BOX): "Make it web-ready"},
                "hide": [format!("{}/look.preview", ids::LOOK)]}})
            .to_string(),
        )
        .unwrap();
        Prefs {
            hidden: vec![format!("{}/lens.recognize:core.ocr", ids::LENS)],
            ..Prefs::default()
        }
        .save(&locations)
        .unwrap();
        let image = offers(&locations, &registry, &settings, "image");
        assert_eq!(image[0]["title"], "Make it web-ready");
        assert!(image
            .iter()
            .all(|o| o["action"] != "look.preview" && o["action"] != "lens.recognize:core.ocr"));
    }

    #[test]
    fn a_photo_too_large_to_sync_is_offered_boxs_compressor_alone() {
        let dir = tempfile::tempdir().unwrap();
        let locations = Locations::under(dir.path());
        let settings = LinkSettings::from_request(None);
        let mut registry = arcade_link::Registry::load(&locations);
        assert!(compress_offer(&registry, &settings).is_none());
        let mut compress = ranked(COMPRESS, "Compress image", 70);
        compress.preset = Some("web-200kb".into());
        let mut boxed = card(
            ids::BOX,
            vec![compress, ranked("box:arcade.image.web", "Web export", 90)],
        );
        arcade_link::manifest::write_manifest(&locations, &boxed).unwrap();
        registry.refresh();
        let offer = compress_offer(&registry, &settings).unwrap();
        assert_eq!(
            (offer["action"].as_str(), offer["title"].as_str()),
            (Some(COMPRESS), Some("Compress"))
        );
        assert_eq!(offer["import"], true);
        let off = LinkSettings::from_request(Some(&json!({"disabled_peers": [ids::BOX]})));
        assert!(compress_offer(&registry, &off).is_none());
        boxed.actions[0] = boxed.actions[0]
            .clone()
            .unavailable("FFmpeg isn't installed");
        arcade_link::manifest::write_manifest(&locations, &boxed).unwrap();
        registry.refresh();
        assert!(compress_offer(&registry, &settings).is_none());
    }

    fn shelf(enabled: bool, available: bool) -> Manifest {
        let mut shelf = Manifest::new(
            ids::SHELF,
            "0.1.0",
            &std::env::current_exe().unwrap().to_string_lossy(),
        );
        shelf.settings.link_enabled = enabled;
        let mut add = Action::new("shelf.add", "Add to Shelf", "add").accepts(&[
            "file/*",
            "file/*[]",
            "folder/reference",
            "text/plain",
            "text/url",
            "text/rich",
        ]);
        if !available {
            add = add.unavailable("busy");
        }
        shelf.actions = vec![
            add,
            Action::new("shelf.show", "Show Shelf", "show").interactive(true),
        ];
        shelf
    }

    #[test]
    fn tools_install_is_not_a_clip_action() {
        let dir = tempfile::tempdir().unwrap();
        let locations = Locations::under(dir.path());
        let mut tools = Manifest::new(
            ids::TOOLS,
            "0.3.5",
            &std::env::current_exe().unwrap().to_string_lossy(),
        );
        tools.actions = vec![
            Action::new("tools.install", "Install an Arcade app", "install")
                .accepts(&["text/plain"])
                .interactive(true),
        ];
        arcade_link::manifest::write_manifest(&locations, &tools).unwrap();
        let registry = arcade_link::Registry::load(&locations);
        assert!(registry.get(ids::TOOLS).is_some());
        let settings = LinkSettings::from_request(None);
        for kind in ["text", "url", "rich_text", "image", "file", "files"] {
            assert!(
                offers(&locations, &registry, &settings, kind)
                    .iter()
                    .all(|o| o["peer"] != ids::TOOLS),
                "{kind}"
            );
        }
    }

    #[test]
    fn shelf_offers_every_clip_kind_and_hides_when_off() {
        let dir = tempfile::tempdir().unwrap();
        let locations = Locations::under(dir.path());
        let settings = LinkSettings::from_request(None);
        let mut registry = arcade_link::Registry::load(&locations);
        let kinds = ["text", "url", "rich_text", "image", "file", "files"];
        let shelf_offers = |registry: &arcade_link::Registry, settings: &LinkSettings, kind| {
            offers(&locations, registry, settings, kind)
                .into_iter()
                .filter(|o| o["peer"] == ids::SHELF)
                .collect::<Vec<_>>()
        };
        for kind in kinds {
            assert!(shelf_offers(&registry, &settings, kind).is_empty());
        }
        arcade_link::manifest::write_manifest(&locations, &shelf(true, true)).unwrap();
        registry.refresh();
        for kind in kinds {
            let offers = shelf_offers(&registry, &settings, kind);
            assert_eq!(offers.len(), 1, "{kind}");
            assert_eq!(offers[0]["action"], "shelf.add");
            assert_eq!(offers[0]["title"], "Add to Shelf");
            assert_eq!(offers[0]["shortcut"], "H");
            assert_eq!(offers[0]["import"], false);
        }
        let off = LinkSettings::from_request(Some(&json!({"disabled_peers": [ids::SHELF]})));
        assert!(shelf_offers(&registry, &off, "text").is_empty());
        arcade_link::manifest::write_manifest(&locations, &shelf(true, false)).unwrap();
        registry.refresh();
        assert!(shelf_offers(&registry, &settings, "image").is_empty());
        arcade_link::manifest::write_manifest(&locations, &shelf(false, true)).unwrap();
        registry.refresh();
        assert!(shelf_offers(&registry, &settings, "file").is_empty());
    }

    #[test]
    fn shelf_accepts_the_content_built_for_each_clip() {
        let dir = tempfile::tempdir().unwrap();
        let locations = Locations::under(dir.path());
        let accepts = shelf(true, true).actions[0].accepts.clone();
        let h = Handoff::create(&locations, ids::CLIPBOARD).unwrap();
        let rep = |mime: &str, bytes: &[u8], name: Option<&str>| json!({"mime_type": mime, "data_base64": STANDARD.encode(bytes), "name": name});
        let text = link::payload_content(
            &json!({"kind": "text", "text": "hello", "representations": []}),
            &h,
        )
        .unwrap();
        assert_eq!(
            (text.kind.as_str(), text.text.as_deref()),
            ("text/plain", Some("hello"))
        );
        let url = link::payload_content(
            &json!({"kind": "url", "text": "https://a.b", "representations": []}),
            &h,
        )
        .unwrap();
        assert_eq!(url.kind, "text/url");
        let rich = link::payload_content(
            &json!({"kind": "rich_text", "text": "hi", "representations": [
                rep("text/plain", b"hi", None), rep("text/html", b"<b>hi</b>", None)]}),
            &h,
        )
        .unwrap();
        assert_eq!(
            (rich.kind.as_str(), rich.html.as_deref()),
            ("text/rich", Some("<b>hi</b>"))
        );
        let image = link::payload_content(
            &json!({"kind": "image", "text": "", "representations": [
                rep("image/png", b"\x89PNG\r\n\x1a\n", None)]}),
            &h,
        )
        .unwrap();
        assert_eq!(image.kind, "file/image");
        let file = link::payload_content(
            &json!({"kind": "file", "text": "", "representations": [
                rep("application/octet-stream", b"a", Some("notes.txt"))]}),
            &h,
        )
        .unwrap();
        let files = link::payload_content(
            &json!({"kind": "files", "text": "", "representations": [
                rep("application/octet-stream", b"a", Some("a.pdf")),
                rep("application/octet-stream", b"b", Some("b.zip"))]}),
            &h,
        )
        .unwrap();
        assert_eq!(files.paths.len(), 2);
        for content in [&text, &url, &rich, &image, &file, &files] {
            assert!(
                arcade_link::content::accepts_content(&accepts, content),
                "{}",
                content.kind
            );
        }
        // History holds bytes, not paths: Shelf receives Clipboard-owned
        // handoff files under the Link handoff root and copies them.
        for content in [&image, &file, &files] {
            assert_eq!(content.owner.as_deref(), Some(ids::CLIPBOARD));
            for path in content.all_paths() {
                assert!(std::path::Path::new(path).starts_with(&locations.handoff));
            }
        }
        assert_eq!(
            std::path::Path::new(file.path.as_deref().unwrap()).file_name(),
            Some(std::ffi::OsStr::new("notes.txt"))
        );
    }
}
