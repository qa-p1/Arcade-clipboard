//! DNS-SD supplies candidate LAN addresses. Authenticated Noise and the signed
//! membership certificate decide whether an address is a trusted device.
use crate::Core;
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::Arc,
};

const SERVICE_TYPE: &str = "_arcade-clip._tcp.local.";

pub async fn start(
    core: &Arc<Core>,
    mesh_id: &str,
    device_id: &str,
    public: &str,
    port: u16,
) -> Result<(), String> {
    let daemon =
        ServiceDaemon::new().map_err(|_| "Local device discovery could not start".to_string())?;
    let properties = HashMap::from([
        ("mesh".to_string(), mesh_id.to_string()),
        ("device".to_string(), device_id.to_string()),
        ("identity".to_string(), public.to_string()),
    ]);
    let info = ServiceInfo::new(
        SERVICE_TYPE,
        device_id,
        &format!("arcade-{device_id}.local."),
        "",
        port,
        properties,
    )
    .map_err(|_| "Local device announcement could not be created".to_string())?
    .enable_addr_auto();
    daemon
        .register(info)
        .map_err(|_| "Local device announcement could not start".to_string())?;
    let events = daemon
        .browse(SERVICE_TYPE)
        .map_err(|_| "Local device browsing could not start".to_string())?;
    core.install_discovery(daemon);
    let target = core.clone();
    let mut shutdown = core.shutdown_receiver();
    let mesh_id = mesh_id.to_string();
    let device_id = device_id.to_string();
    core.track_discovery(tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = shutdown.changed() => break,
                event = events.recv_async() => {
                    let Ok(event) = event else { break; };
                    if let ServiceEvent::ServiceResolved(info) = event {
                        if info.get_property_val_str("mesh") != Some(mesh_id.as_str()) { continue; }
                        let Some(peer_id) = info.get_property_val_str("device") else { continue; };
                        if peer_id == device_id { continue; }
                        let Some(public) = info.get_property_val_str("identity") else { continue; };
                        let addresses = info.get_addresses_v4().iter().map(|ip| SocketAddr::new(IpAddr::V4(*ip), info.get_port())).collect::<Vec<_>>();
                        target.discovery_candidates(peer_id, public, addresses).await;
                    }
                }
            }
        }
    }));
    Ok(())
}
