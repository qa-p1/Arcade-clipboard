//! Desktop consumers. Discovery and all file/IPC work run on Rust workers.
//! The Dart menus use snapshots; only OS directory notifications refresh them.

use crate::link::{self, LinkSettings};
use crate::Core;
use arcade_link::client::{self, AppState};
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

/// Only the requested Clipboard integrations. Box keeps ownership of presets.
fn item_action(peer: &str, action: &Action) -> Option<(&'static str, bool, &'static str)> {
    match (peer, action.id.as_str()) {
        (ids::TOOLS, "tools.install") => Some(("Get", false, "")),
        (ids::LOOK, "look.preview") => Some(("Quick Look", false, "Q")),
        (ids::LENS, "lens.analyze") => Some(("Analyze with Lens", false, "A")),
        (ids::LENS, "lens.pin") => Some(("Pin", false, "P")),
        (ids::LENS, "lens.recognize") => Some(("Extract text", true, "E")),
        (ids::BOX, "box:arcade.image.convert#png") => Some(("Convert to PNG", true, "N")),
        (ids::BOX, "box:arcade.image.compress#web-200kb") => Some(("Compress", true, "C")),
        (ids::BOX, "box:arcade.text.structured#format-json") => Some(("Format JSON", true, "J")),
        (ids::BOX, "box:arcade.text.clean#clean") => Some(("Clean text", true, "T")),
        _ => None,
    }
}

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

fn offers(registry: &arcade_link::Registry, settings: &LinkSettings, kind: &str) -> Vec<Value> {
    if !settings.enabled {
        return Vec::new();
    }
    let input = Content {
        kind: clip_type(kind).into(),
        ..Default::default()
    };
    let mut values = Vec::new();
    for peer in registry.peers(ids::CLIPBOARD) {
        if !peer.settings.link_enabled || settings.disabled_peers.contains(&peer.id) {
            continue;
        }
        for action in &peer.actions {
            let Some((title, import, shortcut)) = item_action(&peer.id, action) else {
                continue;
            };
            if !action.available
                || !action.on_this_platform()
                || !arcade_link::content::accepts_content(&action.accepts, &input)
            {
                continue;
            }
            // Recognition of text belongs to Lens, but Clipboard's Extract text
            // entry specifically works on a photo, not a text history item.
            if action.id == "lens.recognize" && kind != "image" {
                continue;
            }
            let limit_reason = action
                .max_bytes
                .map(|limit| LinkError::too_large(limit).user_message(&peer.name));
            values.push(
                json!({"peer": peer.id, "action": action.id, "version": action.version,
                "title": title, "import": import, "shortcut": shortcut,
                "available": true, "reason": Value::Null,
                "max_bytes": action.max_bytes, "limit_reason": limit_reason,
                "effects": action.effects, "privacy": action.privacy}),
            );
        }
    }
    values
}

pub(crate) fn all_offers() -> Value {
    let Ok((registry, settings)) = snapshot() else {
        return json!({"offers": {}});
    };
    let by_kind: serde_json::Map<String, Value> =
        ["text", "url", "rich_text", "image", "file", "files"]
            .into_iter()
            .map(|kind| (kind.into(), json!(offers(&registry, &settings, kind))))
            .collect();
    json!({"offers": by_kind})
}

pub(crate) fn peers() -> Value {
    let locations = Locations::discover();
    let Ok((registry, settings)) = snapshot() else {
        return json!({"peers": []});
    };
    let rows: Vec<Value> = ids::APPS.into_iter().filter(|id| *id != ids::CLIPBOARD).map(|id| {
        let (state, version) = match client::app_state(&locations, &registry, id, &me()) {
            AppState::Running { version } => ("Running", version),
            AppState::Installed { version } => ("Installed", version),
            AppState::NotInstalled => ("Not installed", String::new()),
        };
        json!({"id": id, "name": arcade_link::manifest::app_name(id), "state": state,
            "version": version, "enabled": !settings.disabled_peers.iter().any(|p| p == id),
            "link_enabled": registry.get(id).is_none_or(|p| p.settings.link_enabled),
            "pitch": arcade_link::manifest::app_pitch(id), "url": arcade_link::manifest::releases_url(id)})
    }).collect();
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
                "message": e.user_message(if e.reason.as_deref() == Some("private_mode") { "Arcade Clipboard" } else { arcade_link::manifest::app_name(&peer) })}),
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
        let (_, import, _) = item_action(&peer, &action)
            .ok_or_else(|| LinkError::unsupported("not an item action"))?;
        if !action.available {
            return Err(LinkError::unavailable(
                action.reason.clone().unwrap_or_default(),
            ));
        }
        let handoff = Handoff::create(&Locations::discover(), ids::CLIPBOARD)
            .map_err(|e| LinkError::internal(e.to_string()))?;
        let (input, stage_guard) = if install {
            let app = value["options"]["app"].as_str().unwrap_or_default();
            if !ids::APPS.contains(&app) || app == ids::CLIPBOARD {
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
        let result = invoke_bounded(&manifest, &request, id, &cancel, timeout)?;
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
            let clip = tokio::task::spawn_blocking(move || link::clip_for(&output))
                .await
                .map_err(|_| LinkError::internal("couldn't import result"))??;
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

/// Opens only the canonical release page for a known Arcade app.
pub(crate) fn open_releases(app: &str) -> Result<Value, LinkError> {
    if !ids::APPS.contains(&app) || app == ids::CLIPBOARD {
        return Err(LinkError::unsupported("unknown app"));
    }
    let url = arcade_link::manifest::releases_url(app);
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
        assert!(offers(&registry, &settings, "image").is_empty());
        let mut lens = Manifest::new(
            ids::LENS,
            "1.0.0",
            &std::env::current_exe().unwrap().to_string_lossy(),
        );
        lens.actions = vec![
            Action::new("lens.recognize", "OCR", "recognize")
                .accepts(&["file/image", "text/plain"]),
            Action::new("lens.pin", "Pin", "pin")
                .accepts(&["file/image"])
                .unavailable("off"),
        ];
        arcade_link::manifest::write_manifest(&locations, &lens).unwrap();
        registry.refresh();
        let photo = offers(&registry, &settings, "image");
        assert_eq!(photo.len(), 1);
        assert_eq!(photo[0]["title"], "Extract text");
        assert!(offers(&registry, &settings, "text").is_empty());
        assert!(offers(&registry, &settings, "file").is_empty());
        let off = LinkSettings::from_request(Some(&json!({"disabled_peers": [ids::LENS]})));
        assert!(offers(&registry, &off, "image").is_empty());
        let off = LinkSettings::from_request(Some(&json!({"enabled": false})));
        assert!(offers(&registry, &off, "image").is_empty());
        lens.settings.link_enabled = false;
        arcade_link::manifest::write_manifest(&locations, &lens).unwrap();
        registry.refresh();
        assert!(offers(&registry, &settings, "image").is_empty());
    }
}
