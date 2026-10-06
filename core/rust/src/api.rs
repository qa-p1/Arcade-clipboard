use crate::Core;
use serde_json::Value;
use std::{
    path::PathBuf,
    sync::{Arc, OnceLock},
};
use tokio::sync::{Mutex, RwLock};

const MAX_REQUEST_BYTES: usize = 24 * 1024 * 1024;

static CORE: OnceLock<Mutex<Option<Arc<Core>>>> = OnceLock::new();
static LIFECYCLE: OnceLock<RwLock<()>> = OnceLock::new();
#[cfg(not(any(target_os = "android", target_os = "ios")))]
static LINK_STARTUP: OnceLock<Mutex<Option<tokio::task::JoinHandle<()>>>> = OnceLock::new();

fn core_slot() -> &'static Mutex<Option<Arc<Core>>> {
    CORE.get_or_init(|| Mutex::new(None))
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
async fn stop_link() {
    let startup = LINK_STARTUP
        .get_or_init(|| Mutex::new(None))
        .lock()
        .await
        .take();
    // A blocking startup cannot be aborted once it runs. Join it before
    // stopping, so it cannot install a listener/watcher after shutdown.
    if let Some(startup) = startup {
        let _ = startup.await;
    }
    let _ = tokio::task::spawn_blocking(crate::link::stop).await;
}

/// The narrow JSON boundary used by Flutter. Core access is cloned while the
/// singleton lock is held; no network or storage operation awaits under it.
pub async fn call(request: String) -> Result<String, String> {
    if request.len() > MAX_REQUEST_BYTES {
        return Err("Core request exceeds the 24 MiB limit".into());
    }
    let value: Value =
        serde_json::from_str(&request).map_err(|_| "Core request is not valid JSON".to_string())?;
    let op = value
        .get("op")
        .and_then(Value::as_str)
        .ok_or_else(|| "Request is missing its operation".to_string())?;
    let response = match op {
        "initialize" => {
            let _guard = LIFECYCLE.get_or_init(|| RwLock::new(())).write().await;
            initialize(value).await?
        }
        // Arcade Link operations that need no open profile.
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_manifest" => {
            let settings = crate::link::LinkSettings::from_request(value.get("link"));
            serde_json::to_value(crate::link::manifest(&settings))
                .map_err(|_| "Could not encode the manifest".to_string())?
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_quit_running" => serde_json::json!({"quit": crate::link::quit_running()}),
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_configure" => {
            let settings = crate::link::LinkSettings::from_request(value.get("link"));
            tokio::task::spawn_blocking(move || crate::link::configure(&settings))
                .await
                .map_err(|_| "Could not update Arcade Link".to_string())?;
            crate::link::diagnostics()
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_wait" => crate::link::wait_event().await,
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_diagnostics" => crate::link::diagnostics(),
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_offers" => tokio::task::spawn_blocking(crate::link_consumer::all_offers)
            .await
            .map_err(|_| "Could not read item actions".to_string())?,
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_peers" => tokio::task::spawn_blocking(crate::link_consumer::peers)
            .await
            .map_err(|_| "Could not read connected apps".to_string())?,
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_open_releases" => {
            let app = value["app"].as_str().unwrap_or_default().to_owned();
            tokio::task::spawn_blocking(move || crate::link_consumer::open_releases(&app))
                .await
                .map_err(|_| "Could not open releases".to_string())?
                .map_err(|e| e.user_message("Arcade Clipboard"))?
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_cancel" => serde_json::json!({"cancelled": crate::link_consumer::cancel(
            value["request"].as_u64().ok_or_else(|| "Request is missing request".to_string())?)}),
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_stage_image" => {
            tokio::task::spawn_blocking(move || crate::link_consumer::stage(&value))
                .await
                .map_err(|_| "Could not stage the photo".to_string())?
                .map_err(|e| e.user_message("Arcade Clipboard"))?
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_invoke" => {
            let _guard = LIFECYCLE.get_or_init(|| RwLock::new(())).read().await;
            let core = { core_slot().lock().await.clone() }
                .ok_or_else(|| "Clipboard core is not initialized".to_string())?;
            crate::link_consumer::begin(core, value)
        }
        // The picker's answer to a `clipboard.pick` request: an item, an
        // error when it can't open, or nothing when the user closed it.
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        "link_pick_result" => {
            let request = value
                .get("request")
                .and_then(Value::as_u64)
                .ok_or_else(|| "Request is missing request".to_string())?;
            let item = value.get("item_id").and_then(Value::as_str);
            let error = value.get("error").and_then(Value::as_str);
            let _guard = LIFECYCLE.get_or_init(|| RwLock::new(())).read().await;
            let core = { core_slot().lock().await.clone() }
                .ok_or_else(|| "Clipboard core is not initialized".to_string())?;
            serde_json::json!({"answered": crate::link::finish_pick(&core, request, item, error).await})
        }
        "version" => serde_json::json!({"version": env!("CARGO_PKG_VERSION")}),
        "shutdown" => {
            // Before the lifecycle lock, which waits for pending long-polls:
            // the endpoint must disappear promptly on quit.
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            {
                stop_link().await;
                crate::link::push_event(serde_json::json!({"kind": "closed"}));
            }
            let _guard = LIFECYCLE.get_or_init(|| RwLock::new(())).write().await;
            // An initialize already holding the lifecycle lock may finish
            // between the first stop and acquiring it. Drain that startup too.
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            stop_link().await;
            let current = { core_slot().lock().await.take() };
            if let Some(core) = current {
                core.shutdown().await;
            }
            serde_json::json!({"shutdown":true})
        }
        _ => {
            let _guard = LIFECYCLE.get_or_init(|| RwLock::new(())).read().await;
            let core = { core_slot().lock().await.clone() }
                .ok_or_else(|| "Clipboard core is not initialized".to_string())?;
            core.request(value).await?
        }
    };
    serde_json::to_string(&response).map_err(|_| "Could not encode core response".into())
}

async fn initialize(request: Value) -> Result<Value, String> {
    let data_dir = request
        .get("data_dir")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "Initialization requires a data folder".to_string())?;
    let device_name = request
        .get("device_name")
        .and_then(Value::as_str)
        .ok_or_else(|| "Initialization requires a device name".to_string())?;
    let previous = { core_slot().lock().await.take() };
    if let Some(previous) = previous {
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        stop_link().await;
        previous.shutdown().await;
    }
    let data_dir = PathBuf::from(data_dir);
    let device_name = device_name.to_string();
    let core = tokio::task::spawn_blocking(move || Core::open(data_dir, device_name))
        .await
        .map_err(|_| "Could not initialize the local clipboard core".to_string())??;
    let core = Arc::new(core);
    core.start().await?;
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        let settings = crate::link::LinkSettings::from_request(request.get("link"));
        let link_core = core.clone();
        // Off the startup path: the manifest write and bind run on a blocking task.
        let startup =
            tokio::task::spawn_blocking(move || crate::link::start(&link_core, &settings));
        *LINK_STARTUP.get_or_init(|| Mutex::new(None)).lock().await = Some(startup);
    }
    let status = serde_json::to_value(core.status().await?)
        .map_err(|_| "Could not encode device status".to_string())?;
    let displaced = { core_slot().lock().await.replace(core) };
    if let Some(displaced) = displaced {
        displaced.shutdown().await;
    }
    Ok(status)
}
