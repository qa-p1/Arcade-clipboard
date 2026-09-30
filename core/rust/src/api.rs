use crate::Core;
use serde_json::Value;
use std::{
    path::PathBuf,
    sync::{Arc, OnceLock},
};
use tokio::sync::Mutex;

const MAX_REQUEST_BYTES: usize = 256 * 1024;

static CORE: OnceLock<Mutex<Option<Arc<Core>>>> = OnceLock::new();

fn core_slot() -> &'static Mutex<Option<Arc<Core>>> {
    CORE.get_or_init(|| Mutex::new(None))
}

/// The narrow JSON boundary used by Flutter. Core access is cloned while the
/// singleton lock is held; no network or storage operation awaits under it.
pub async fn call(request: String) -> Result<String, String> {
    if request.len() > MAX_REQUEST_BYTES {
        return Err("Core request exceeds the 256 KiB limit".into());
    }
    let value: Value = serde_json::from_str(&request).map_err(|_| "Core request is not valid JSON".to_string())?;
    let op = value.get("op").and_then(Value::as_str).ok_or_else(|| "Request is missing its operation".to_string())?;
    let response = match op {
        "initialize" => initialize(value).await?,
        "shutdown" => {
            let current = { core_slot().lock().await.take() };
            if let Some(core) = current { core.shutdown().await; }
            serde_json::json!({"shutdown":true})
        }
        _ => {
            let core = { core_slot().lock().await.clone() }
                .ok_or_else(|| "Clipboard core is not initialized".to_string())?;
            core.request(value).await?
        }
    };
    serde_json::to_string(&response).map_err(|_| "Could not encode core response".into())
}

async fn initialize(request: Value) -> Result<Value, String> {
    let data_dir = request.get("data_dir").and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "Initialization requires a data folder".to_string())?;
    let device_name = request.get("device_name").and_then(Value::as_str)
        .ok_or_else(|| "Initialization requires a device name".to_string())?;
    let previous = { core_slot().lock().await.take() };
    if let Some(previous) = previous { previous.shutdown().await; }
    let data_dir = PathBuf::from(data_dir);
    let device_name = device_name.to_string();
    let core = tokio::task::spawn_blocking(move || Core::open(data_dir, device_name))
        .await.map_err(|_| "Could not initialize the local clipboard core".to_string())??;
    let core = Arc::new(core);
    core.start().await?;
    let status = serde_json::to_value(core.status().await?)
        .map_err(|_| "Could not encode device status".to_string())?;
    let displaced = { core_slot().lock().await.replace(core) };
    if let Some(displaced) = displaced { displaced.shutdown().await; }
    Ok(status)
}

