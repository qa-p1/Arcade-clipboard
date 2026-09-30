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
        let core = Arc::new(Core::open_with_secret_store(
            directory.path().to_path_buf(), name.into(), secrets.clone(),
        ).unwrap());
        core.start().await.unwrap();
        Self { core, directory, secrets }
    }

    async fn request(&self, value: Value) -> Value {
        self.core.request(value).await.unwrap()
    }

    async fn restart(self) -> Self {
        let Self { core, directory, secrets } = self;
        core.shutdown().await;
        drop(core);
        let core = Arc::new(Core::open_with_secret_store(
            directory.path().to_path_buf(), "Ignored restart name".into(), secrets.clone(),
        ).unwrap());
        core.start().await.unwrap();
        Self { core, directory, secrets }
    }

    async fn rows(&self) -> Vec<Value> {
        self.request(json!({"op":"history","query":"","limit":1000})).await["items"]
            .as_array().unwrap().clone()
    }
}

async fn wait_until<F, Fut>(label: &str, mut predicate: F)
where F: FnMut() -> Fut, Fut: std::future::Future<Output=bool> {
    tokio::time::timeout(Duration::from_secs(12), async {
        while !predicate().await { tokio::time::sleep(Duration::from_millis(20)).await; }
    }).await.unwrap_or_else(|_| panic!("Timed out: {label}"));
}

async fn begin_pair(owner: &Device, member: &Device) -> (String, String) {
    let invitation = owner.request(json!({"op":"create_invite"})).await;
    let invite = invitation["invite"].as_str().unwrap().to_owned();
    member.request(json!({"op":"join","invite":invite,"device_name":"Member"})).await;
    wait_until("both pairing prompts", || async {
        !owner.core.status().await.unwrap().pending_pairings.is_empty()
            && !member.core.status().await.unwrap().pending_pairings.is_empty()
    }).await;
    let a = owner.core.status().await.unwrap().pending_pairings.remove(0);
    let b = member.core.status().await.unwrap().pending_pairings.remove(0);
    assert_eq!(a.verification_code, b.verification_code);
    assert_eq!(a.session_id, b.session_id);
    (invite, a.session_id)
}

async fn pair(owner: &Device, member: &Device) -> String {
    let (invite, session) = begin_pair(owner, member).await;
    owner.request(json!({"op":"confirm_pairing","session_id":session,"accept":true})).await;
    assert!(member.core.status().await.unwrap().mesh_id.is_none(), "Unilateral consent established trust");
    member.request(json!({"op":"confirm_pairing","session_id":session,"accept":true})).await;
    wait_until("paired and connected", || async {
        let a = owner.core.status().await.unwrap();
        let b = member.core.status().await.unwrap();
        b.mesh_id.is_some() && a.connection == "online" && b.connection == "online"
    }).await;
    invite
}

#[tokio::test(flavor="multi_thread", worker_threads=4)]
async fn pairing_exact_text_deduplication_and_consumed_invitation() {
    let a = Device::new("Desktop A").await;
    let b = Device::new("Desktop B").await;
    a.request(json!({"op":"create_mesh","device_name":"Desktop A"})).await;
    let invite = pair(&a, &b).await;
    let id = uuid::Uuid::new_v4().to_string();
    let text = "  Synthetic ✓ हिन्दी\nsecond line\t  ";
    a.request(json!({"op":"capture","id":id,"text":text})).await;
    wait_until("remote text", || async { b.rows().await.len()==1 }).await;
    let row = &b.rows().await[0];
    assert_eq!(row["text"], text);
    assert_eq!(row["id"], id);
    assert_eq!(row["origin_device"], a.core.status().await.unwrap().device_id);
    a.request(json!({"op":"capture","id":id,"text":text})).await;
    assert_eq!(a.rows().await.len(), 1);
    assert_eq!(b.rows().await.len(), 1);
    let c = Device::new("Untrusted").await;
    assert!(c.core.request(json!({"op":"join","invite":invite,"device_name":"Untrusted"})).await.is_err());
    assert!(c.core.status().await.unwrap().mesh_id.is_none());
    c.core.shutdown().await;
    b.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor="multi_thread", worker_threads=4)]
async fn offline_catchup_exceeds_channel_capacity_and_deleted_items_do_not_return() {
    let a = Device::new("Desktop A").await;
    let mut b = Device::new("Desktop B").await;
    a.request(json!({"op":"create_mesh","device_name":"Desktop A"})).await;
    pair(&a, &b).await;
    let deleted_id = uuid::Uuid::new_v4().to_string();
    a.request(json!({"op":"capture","id":deleted_id,"text":"Delete this synthetic clip"})).await;
    wait_until("initial sync", || async { b.rows().await.len()==1 }).await;
    b.core.shutdown().await;
    a.request(json!({"op":"delete","id":deleted_id})).await;
    for i in 0..80 {
        a.request(json!({"op":"capture","text":format!("Offline synthetic clip {i}")})).await;
    }
    b = b.restart().await;
    wait_until("all 80 offline items", || async { b.rows().await.len()==80 }).await;
    assert!(!b.rows().await.iter().any(|row| row["id"]==deleted_id));
    b = b.restart().await;
    wait_until("reconnect", || async { b.core.status().await.unwrap().connection=="online" }).await;
    assert_eq!(b.rows().await.len(),80);
    assert_eq!(a.rows().await.len(),80);
    b.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor="multi_thread", worker_threads=4)]
async fn revocation_closes_live_session_and_rejects_reconnect() {
    let a = Device::new("Authority").await;
    let mut b = Device::new("Removed device").await;
    let c = Device::new("Retained device").await;
    a.request(json!({"op":"create_mesh","device_name":"Authority"})).await;
    pair(&a, &b).await;
    pair(&a, &c).await;
    let revoked = b.core.status().await.unwrap().device_id;
    a.request(json!({"op":"revoke","device_id":revoked})).await;
    wait_until("revoked socket closed", || async { b.core.status().await.unwrap().connection!="online" }).await;
    c.request(json!({"op":"capture","text":"Created after revocation"})).await;
    wait_until("remaining trusted path", || async { a.rows().await.len()==1 }).await;
    assert!(b.rows().await.is_empty());
    b = b.restart().await;
    a.request(json!({"op":"capture","text":"Created after revoked restart"})).await;
    wait_until("remaining device receives", || async { c.rows().await.len()==2 }).await;
    assert_ne!(b.core.status().await.unwrap().connection,"online");
    assert!(b.rows().await.is_empty());
    b.core.shutdown().await;
    c.core.shutdown().await;
    a.core.shutdown().await;
}

#[tokio::test(flavor="multi_thread", worker_threads=4)]
async fn rejection_establishes_no_trust_and_settings_survive_restart() {
    let mut a = Device::new("Authority").await;
    let b = Device::new("Joining device").await;
    a.request(json!({"op":"create_mesh","device_name":"Authority"})).await;
    let (_, session) = begin_pair(&a, &b).await;
    b.request(json!({"op":"confirm_pairing","session_id":session,"accept":false})).await;
    wait_until("rejected prompt removed", || async { a.core.status().await.unwrap().pending_pairings.is_empty() }).await;
    assert!(b.core.status().await.unwrap().mesh_id.is_none());
    a.request(json!({"op":"settings","values":{"paused":true,"retention_hours":168}})).await;
    a = a.restart().await;
    let status = a.core.status().await.unwrap();
    assert!(status.paused);
    assert_eq!(status.retention_hours,168);
    let _ = a.core.request(json!({"op":"capture","text":"Must not be captured"})).await;
    assert!(a.rows().await.is_empty());
    b.core.shutdown().await;
    a.core.shutdown().await;
}
