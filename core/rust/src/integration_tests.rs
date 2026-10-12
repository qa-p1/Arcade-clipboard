//! Real TCP + Noise integration tests. Only OS secret storage is replaced with
//! a test-only in-memory provider; protocol, persistence and runtime are real.
use crate::{core::Core, secret::test_support::MemorySecretStore};
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};

struct Device {
    core: Arc<Core>,
    directory: tempfile::TempDir,
    secrets: Arc<MemorySecretStore>,
}

impl Device {
    async fn new(name: &str) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let secrets = Arc::new(MemorySecretStore::default());
        let core = Arc::new(
            Core::open_with_secret_store(
                directory.path().to_path_buf(),
                name.into(),
                secrets.clone(),
            )
            .unwrap(),
        );
        core.start().await.unwrap();
        Self {
            core,
            directory,
            secrets,
        }
    }

    async fn request(&self, value: Value) -> Value {
        self.core.request(value).await.unwrap()
    }

    async fn restart(self) -> Self {
        let Self {
            core,
            directory,
            secrets,
        } = self;
        core.shutdown().await;
        drop(core);
        let core = Arc::new(
            Core::open_with_secret_store(
                directory.path().to_path_buf(),
                "Ignored restart name".into(),
                secrets.clone(),
            )
            .unwrap(),
        );
        core.start().await.unwrap();
        Self {
            core,
            directory,
            secrets,
        }
    }

    async fn rows(&self) -> Vec<Value> {
        self.request(json!({"op":"history","query":"","limit":1000}))
            .await["items"]
            .as_array()
            .unwrap()
            .clone()
    }
}

async fn wait_until<F, Fut>(label: &str, mut predicate: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    tokio::time::timeout(Duration::from_secs(12), async {
        while !predicate().await {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("Timed out: {label}"));
}

async fn begin_pair(owner: &Device, member: &Device) -> (String, String) {
    let invitation = owner.request(json!({"op":"create_invite"})).await;
    let invite = invitation["invite"].as_str().unwrap().to_owned();
    member
        .request(json!({"op":"join","invite":invite,"device_name":"Member"}))
        .await;
    wait_until("both pairing prompts", || async {
        !owner
            .core
            .status()
            .await
            .unwrap()
            .pending_pairings
            .is_empty()
            && !member
                .core
                .status()
                .await
                .unwrap()
                .pending_pairings
                .is_empty()
    })
    .await;
    let a = owner
        .core
        .status()
        .await
        .unwrap()
        .pending_pairings
        .remove(0);
    let b = member
        .core
        .status()
        .await
        .unwrap()
        .pending_pairings
        .remove(0);
    assert_eq!(a.verification_code, b.verification_code);
    assert_eq!(a.session_id, b.session_id);
    (invite, a.session_id)
}

async fn pair(owner: &Device, member: &Device) -> String {
    let (invite, session) = begin_pair(owner, member).await;
    owner
        .request(json!({"op":"confirm_pairing","session_id":session,"accept":true}))
        .await;
    assert!(
        member.core.status().await.unwrap().mesh_id.is_none(),
        "Unilateral consent established trust"
    );
    member
        .request(json!({"op":"confirm_pairing","session_id":session,"accept":true}))
        .await;
    wait_until("paired and connected", || async {
        let a = owner.core.status().await.unwrap();
        let b = member.core.status().await.unwrap();
        b.mesh_id.is_some() && a.connection == "online" && b.connection == "online"
    })
    .await;
    invite
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pairing_exact_text_deduplication_and_consumed_invitation() {
    let a = Device::new("Desktop A").await;
    let b = Device::new("Desktop B").await;
    a.request(json!({"op":"create_mesh","device_name":"Desktop A"}))
        .await;
    let invite = pair(&a, &b).await;
    let id = uuid::Uuid::new_v4().to_string();
    let text = "  Synthetic ✓ हिन्दी\nsecond line\t  ";
    a.request(json!({"op":"capture","id":id,"text":text})).await;
    wait_until("remote text", || async { b.rows().await.len() == 1 }).await;
    let row = &b.rows().await[0];
    assert_eq!(row["text"], text);
    assert_eq!(row["id"], id);
    assert_eq!(
        row["origin_device"],
        a.core.status().await.unwrap().device_id
    );
    a.request(json!({"op":"capture","id":id,"text":text})).await;
    assert_eq!(a.rows().await.len(), 1);
    assert_eq!(b.rows().await.len(), 1);
    let c = Device::new("Untrusted").await;
    assert!(c
        .core
        .request(json!({"op":"join","invite":invite,"device_name":"Untrusted"}))
        .await
        .is_err());
    assert!(c.core.status().await.unwrap().mesh_id.is_none());
    c.core.shutdown().await;
    b.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn offline_catchup_exceeds_channel_capacity_and_deleted_items_do_not_return() {
    let a = Device::new("Desktop A").await;
    let mut b = Device::new("Desktop B").await;
    a.request(json!({"op":"create_mesh","device_name":"Desktop A"}))
        .await;
    pair(&a, &b).await;
    let deleted_id = uuid::Uuid::new_v4().to_string();
    a.request(json!({"op":"capture","id":deleted_id,"text":"Delete this synthetic clip"}))
        .await;
    wait_until("initial sync", || async { b.rows().await.len() == 1 }).await;
    b.core.shutdown().await;
    a.request(json!({"op":"delete","id":deleted_id})).await;
    for i in 0..80 {
        a.request(json!({"op":"capture","text":format!("Offline synthetic clip {i}")}))
            .await;
    }
    b = b.restart().await;
    wait_until("all 80 offline items", || async {
        b.rows().await.len() == 80
    })
    .await;
    assert!(!b.rows().await.iter().any(|row| row["id"] == deleted_id));
    b = b.restart().await;
    wait_until("reconnect", || async {
        b.core.status().await.unwrap().connection == "online"
    })
    .await;
    assert_eq!(b.rows().await.len(), 80);
    assert_eq!(a.rows().await.len(), 80);
    b.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn revocation_closes_live_session_and_rejects_reconnect() {
    let a = Device::new("Authority").await;
    let mut b = Device::new("Removed device").await;
    let c = Device::new("Retained device").await;
    a.request(json!({"op":"create_mesh","device_name":"Authority"}))
        .await;
    pair(&a, &b).await;
    pair(&a, &c).await;
    let revoked = b.core.status().await.unwrap().device_id;
    a.request(json!({"op":"revoke","device_id":revoked})).await;
    wait_until("revoked socket closed", || async {
        b.core.status().await.unwrap().connection != "online"
    })
    .await;
    c.request(json!({"op":"capture","text":"Created after revocation"}))
        .await;
    wait_until("remaining trusted path", || async {
        a.rows().await.len() == 1
    })
    .await;
    assert!(b.rows().await.is_empty());
    b = b.restart().await;
    a.request(json!({"op":"capture","text":"Created after revoked restart"}))
        .await;
    wait_until("remaining device receives", || async {
        c.rows().await.len() == 2
    })
    .await;
    assert_ne!(b.core.status().await.unwrap().connection, "online");
    assert!(b.rows().await.is_empty());
    b.core.shutdown().await;
    c.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rejection_establishes_no_trust_and_settings_survive_restart() {
    let mut a = Device::new("Authority").await;
    let b = Device::new("Joining device").await;
    a.request(json!({"op":"create_mesh","device_name":"Authority"}))
        .await;
    let (_, session) = begin_pair(&a, &b).await;
    b.request(json!({"op":"confirm_pairing","session_id":session,"accept":false}))
        .await;
    wait_until("rejected prompt removed", || async {
        a.core.status().await.unwrap().pending_pairings.is_empty()
    })
    .await;
    assert!(b.core.status().await.unwrap().mesh_id.is_none());
    a.request(json!({"op":"settings","values":{"paused":true,"retention_hours":168}}))
        .await;
    a = a.restart().await;
    let status = a.core.status().await.unwrap();
    assert!(status.paused);
    assert_eq!(status.retention_hours, 168);
    let _ = a
        .core
        .request(json!({"op":"capture","text":"Must not be captured"}))
        .await;
    assert!(a.rows().await.is_empty());
    b.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rich_payload_streams_and_survives_authenticated_local_storage() {
    use base64::{engine::general_purpose::STANDARD, Engine};
    let a = Device::new("Desktop A").await;
    let mut b = Device::new("Desktop B").await;
    a.request(json!({"op":"create_mesh","device_name":"Desktop A"}))
        .await;
    pair(&a, &b).await;
    let bytes = (0..512 * 1024).map(|i| (i % 251) as u8).collect::<Vec<_>>();
    let id = a.request(json!({"op":"capture","text":"report.bin","kind":"file","representations":[{"mime_type":"application/octet-stream","name":"report.bin","data_base64":STANDARD.encode(&bytes)}]})).await["id"].as_str().unwrap().to_string();
    wait_until("streamed binary file", || async {
        b.rows().await.len() == 1
    })
    .await;
    let fetched = b.request(json!({"op":"payload","id":id})).await;
    assert_eq!(
        STANDARD
            .decode(
                fetched["representations"][0]["data_base64"]
                    .as_str()
                    .unwrap()
            )
            .unwrap(),
        bytes
    );
    assert_eq!(b.rows().await[0]["representations"][0]["size"], bytes.len());
    b = b.restart().await;
    assert_eq!(
        b.request(json!({"op":"payload","id":id})).await["representations"],
        fetched["representations"]
    );
    let database = std::fs::read(b.directory.path().join("history.sqlite")).unwrap();
    assert!(!database.windows(128).any(|window| window == &bytes[..128]));
    b.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 6)]
async fn members_discover_each_other_and_synchronize_when_creator_is_offline() {
    let a = Device::new("Creator").await;
    let b = Device::new("Laptop").await;
    let c = Device::new("Tablet").await;
    a.request(json!({"op":"create_mesh","device_name":"Creator"}))
        .await;
    pair(&a, &b).await;
    pair(&a, &c).await;
    let b_id = b.core.status().await.unwrap().device_id;
    let c_id = c.core.status().await.unwrap().device_id;
    wait_until("members discover signed membership and connect", || async {
        b.core
            .devices()
            .await
            .unwrap()
            .iter()
            .any(|d| d.device_id == c_id && d.state == "online")
            && c.core
                .devices()
                .await
                .unwrap()
                .iter()
                .any(|d| d.device_id == b_id && d.state == "online")
    })
    .await;
    a.core.shutdown().await;
    b.request(json!({"op":"capture","text":"Available with the mesh creator offline"}))
        .await;
    wait_until("member to member sync", || async {
        c.rows().await.len() == 1
    })
    .await;
    assert_eq!(c.rows().await[0]["origin_device"], b_id);
    assert!(a.rows().await.is_empty());
    c.core.shutdown().await;
    b.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn encrypted_relay_pairing_offline_queue_and_reconnection() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_address = listener.local_addr().unwrap();
    let relay = tokio::spawn(async move {
        arcade_relay::serve(listener, arcade_relay::RelayState::new())
            .await
            .unwrap();
    });
    let a = Device::new("Creator").await;
    let b = Device::new("Remote").await;
    a.request(json!({"op":"create_mesh","device_name":"Creator"}))
        .await;
    a.request(json!({"op":"settings","values":{"relay_url":format!("ws://{relay_address}")}}))
        .await;
    let invitation = a.request(json!({"op":"create_invite"})).await;
    let mut invite: Value = serde_json::from_str(invitation["invite"].as_str().unwrap()).unwrap();
    // A guaranteed unreachable endpoint exercises relay pairing rather than LAN.
    invite["host_address"] = json!("127.0.0.1");
    invite["host_port"] = json!(1);
    b.request(json!({"op":"join","invite":invite.to_string(),"device_name":"Remote"}))
        .await;
    wait_until("relay pairing confirmations", || async {
        !a.core.status().await.unwrap().pending_pairings.is_empty()
    })
    .await;
    let a_info = a.core.status().await.unwrap().pending_pairings.remove(0);
    let b_info = b.core.status().await.unwrap().pending_pairings.remove(0);
    assert_eq!(a_info.verification_code, b_info.verification_code);
    a.request(json!({"op":"confirm_pairing","session_id":a_info.session_id,"accept":true}))
        .await;
    b.request(json!({"op":"confirm_pairing","session_id":b_info.session_id,"accept":true}))
        .await;
    wait_until("paired through relay", || async {
        b.core.status().await.unwrap().mesh_id.is_some()
            && b.core.status().await.unwrap().connection == "online"
    })
    .await;
    a.request(json!({"op":"capture","text":"Encrypted through relay"}))
        .await;
    wait_until("relay item", || async { b.rows().await.len() == 1 }).await;
    b.core.shutdown().await;
    a.request(json!({"op":"capture","text":"Encrypted offline catch-up"}))
        .await;
    let b = b.restart().await;
    wait_until("offline relay catchup", || async {
        b.rows().await.len() == 2
    })
    .await;
    b.core.shutdown().await;
    a.core.shutdown().await;
    relay.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lan_loss_switches_to_relay_and_sync_continues_without_duplicates() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let relay = tokio::spawn(async move {
        arcade_relay::serve(listener, arcade_relay::RelayState::new())
            .await
            .unwrap();
    });
    let a = Device::new("Desktop").await;
    let b = Device::new("Laptop").await;
    a.request(json!({"op":"create_mesh","device_name":"Desktop"}))
        .await;
    a.request(json!({"op":"settings","values":{"relay_url":format!("ws://{address}")}}))
        .await;
    pair(&a, &b).await;
    a.request(json!({"op":"capture","text":"Before LAN connection loss"}))
        .await;
    wait_until("LAN synchronization", || async {
        b.rows().await.len() == 1
    })
    .await;
    // Cut direct sockets and prevent direct reconnection. Relay bytes, Noise,
    // trust, storage and both runtimes are real.
    a.core.test_force_relay();
    b.core.test_force_relay();
    a.request(json!({"op":"capture","text":"During relay reconnect"}))
        .await;
    wait_until("relay takeover and catchup", || async {
        b.rows().await.len() == 2 && a.core.status().await.unwrap().connection == "online"
    })
    .await;
    b.request(json!({"op":"capture","text":"Reverse direction after relay takeover"}))
        .await;
    wait_until("relay reverse direction", || async {
        a.rows().await.len() == 3
    })
    .await;
    assert_eq!(b.rows().await.len(), 3);
    b.core.shutdown().await;
    a.core.shutdown().await;
    relay.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 6)]
async fn signed_provenance_allows_offline_origin_catchup_from_another_member() {
    let a = Device::new("Origin").await;
    let b = Device::new("Holder").await;
    let c = Device::new("Offline recipient").await;
    a.request(json!({"op":"create_mesh","device_name":"Origin"}))
        .await;
    pair(&a, &b).await;
    pair(&a, &c).await;
    let b_id = b.core.status().await.unwrap().device_id;
    wait_until("full mesh", || async {
        c.core
            .devices()
            .await
            .unwrap()
            .iter()
            .any(|d| d.device_id == b_id && d.state == "online")
    })
    .await;
    c.core.shutdown().await;
    a.request(json!({"op":"capture","text":"Retained by another signed mesh member"}))
        .await;
    wait_until("holder received", || async { b.rows().await.len() == 1 }).await;
    let origin = a.core.status().await.unwrap().device_id;
    a.core.shutdown().await;
    let c = c.restart().await;
    wait_until("forwarded catchup with origin offline", || async {
        c.rows().await.len() == 1
    })
    .await;
    assert_eq!(c.rows().await[0]["origin_device"], origin);
    c.core.shutdown().await;
    b.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn signed_pins_sync_and_offline_conflicts_converge() {
    let mut a = Device::new("Desktop").await;
    let mut b = Device::new("Laptop").await;
    a.request(json!({"op":"create_mesh","device_name":"Desktop"}))
        .await;
    pair(&a, &b).await;
    let id = a
        .request(json!({"op":"capture","text":"Pinned across my devices"}))
        .await["id"]
        .as_str()
        .unwrap()
        .to_string();
    wait_until("initial item", || async { b.rows().await.len() == 1 }).await;
    a.request(json!({"op":"pin","id":id,"pinned":true})).await;
    wait_until("remote pin", || async {
        b.rows().await[0]["pinned"] == true
    })
    .await;
    b.core.shutdown().await;
    a.request(json!({"op":"pin","id":id,"pinned":false})).await;
    b = b.restart().await;
    wait_until("offline unpin catchup", || async {
        b.rows().await[0]["pinned"] == false
    })
    .await;

    // Both devices keep their real encrypted database while disconnected.
    a.core.test_force_relay();
    b.core.test_force_relay();
    a.request(json!({"op":"pin","id":id,"pinned":true})).await;
    a.request(json!({"op":"pin","id":id,"pinned":false})).await;
    b.request(json!({"op":"pin","id":id,"pinned":true})).await;
    a = a.restart().await;
    b = b.restart().await;
    wait_until("offline pin conflicts converge", || async {
        a.core.status().await.unwrap().connection == "online"
            && b.core.status().await.unwrap().connection == "online"
            && a.rows().await[0]["pinned"] == false
            && b.rows().await[0]["pinned"] == false
    })
    .await;
    b.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn recopying_existing_content_moves_it_to_the_top_on_every_device() {
    let a = Device::new("Desktop A").await;
    let b = Device::new("Desktop B").await;
    a.request(json!({"op":"create_mesh","device_name":"Desktop A"}))
        .await;
    pair(&a, &b).await;
    let first = a.request(json!({"op":"capture","text":"repeated"})).await["id"].clone();
    a.request(json!({"op":"capture","text":"later"})).await;
    // Copying the newest clip again is a no-op.
    let again = a.request(json!({"op":"capture","text":"later"})).await;
    assert_eq!(a.rows().await.len(), 2);
    assert_eq!(a.rows().await[0]["id"], again["id"]);
    wait_until("both clips on B", || async { b.rows().await.len() == 2 }).await;
    // Copying an older clip again moves it to the top, everywhere.
    let moved = a.request(json!({"op":"capture","text":"repeated"})).await["id"].clone();
    assert_ne!(moved, first);
    let rows = a.rows().await;
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["text"], "repeated");
    wait_until("moved clip replaced on B", || async {
        let rows = b.rows().await;
        rows.len() == 2 && rows[0]["id"] == moved && rows.iter().all(|row| row["id"] != first)
    })
    .await;
    // A remote clip copied back on the receiving device does not duplicate.
    b.request(json!({"op":"capture","text":"repeated"})).await;
    assert_eq!(b.rows().await.len(), 2);
    b.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn both_devices_redial_after_restart_and_keep_one_connection() {
    let a = Device::new("Desktop A").await;
    let b = Device::new("Desktop B").await;
    a.request(json!({"op":"create_mesh","device_name":"Desktop A"}))
        .await;
    pair(&a, &b).await;
    let a = a.restart().await;
    let b = b.restart().await;
    wait_until("reconnected", || async {
        a.core.status().await.unwrap().connection == "online"
            && b.core.status().await.unwrap().connection == "online"
    })
    .await;
    // Simultaneous dials settle on a single stable session.
    tokio::time::sleep(Duration::from_secs(4)).await;
    assert_eq!(a.core.status().await.unwrap().connection, "online");
    b.request(json!({"op":"capture","text":"after both restarted"}))
        .await;
    wait_until("sync after restart", || async {
        a.rows()
            .await
            .iter()
            .any(|row| row["text"] == "after both restarted")
    })
    .await;
    b.core.shutdown().await;
    a.core.shutdown().await;
}
