use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_TEXT_BYTES: usize = 32 * 1024;
pub const MAX_FRAME_BYTES: usize = 65_535; // Noise ciphertext limit, including authentication tag.
pub const DEFAULT_RETENTION_HOURS: u32 = 24;
pub const DEFAULT_MAX_ITEMS: usize = 500;
pub const INVITE_TTL_SECONDS: u64 = 120;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryItem {
    pub id: String,
    pub origin_device: String,
    pub source_name: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub text: String,
    pub preview: String,
    pub kind: String,
    pub pinned: bool,
    pub size: usize,
    pub representations: Vec<crate::payload::RepresentationInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub device_id: String,
    pub device_name: String,
    pub platform: String,
    pub state: String,
    pub last_seen: Option<i64>,
    pub is_owner: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingPairingInfo {
    pub session_id: String,
    pub peer_name: String,
    pub verification_code: String,
    pub expires_at: i64,
    pub direction: String,
    pub state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Status {
    pub initialized: bool,
    pub mesh_id: Option<String>,
    pub device_id: String,
    pub device_name: String,
    pub paused: bool,
    pub connection: String,
    pub transport: String,
    pub diagnostic: String,
    pub pending_pairings: Vec<PendingPairingInfo>,
    pub retention_hours: u32,
    pub revision: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InviteV1 {
    pub version: u16,
    pub mesh_id: String,
    pub session_id: String,
    pub expires_at: i64,
    pub host_address: String,
    pub host_port: u16,
    pub host_device_id: String,
    pub host_device_name: String,
    pub host_static_public: String,
    pub owner_signing_public: String,
    pub pairing_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WireMessage {
    Hello {
        version: u16,
        mesh_id: String,
        device_id: String,
        device_name: String,
        static_public: String,
        #[serde(default)]
        item_signing_public: String,
        #[serde(default)]
        platform: String,
        #[serde(default)]
        capabilities: Vec<String>,
        endpoint: String,
    },
    PairDecision {
        accepted: bool,
    },
    PairCommit {
        mesh_id: String,
        owner_signing_public: String,
        owner_device_id: String,
        member_certificate: SignedMemberCertificate,
        membership: Vec<SignedMemberCertificate>,
    },
    ClipboardItem {
        item: WireItem,
    },
    ClipboardChunk {
        id: String,
        offset: usize,
        total: usize,
        data: String,
    },
    DeleteItem {
        id: String,
    },
    PinUpdate {
        state: SignedPinState,
    },
    MembershipSnapshot {
        certificates: Vec<SignedMemberCertificate>,
        revocations: Vec<SignedRevocation>,
    },
    Ping {
        sent_at: i64,
    },
    Pong {
        sent_at: i64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireItem {
    pub protocol_version: u16,
    pub id: String,
    pub origin_device: String,
    pub sender_sequence: u64,
    pub source_name: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub text: String,
    pub kind: String,
    pub content_hash: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub origin_signature: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub representations: Vec<crate::payload::Representation>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemberCertificate {
    pub version: u16,
    pub mesh_id: String,
    pub device_id: String,
    pub device_name: String,
    pub static_public: String,
    pub issued_at: i64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub item_signing_public: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub platform: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedMemberCertificate {
    pub certificate: MemberCertificate,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Revocation {
    pub version: u16,
    pub mesh_id: String,
    pub device_id: String,
    pub revoked_at: i64,
    pub epoch: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedRevocation {
    pub revocation: Revocation,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedPinState {
    pub version: u16,
    pub mesh_id: String,
    pub id: String,
    pub pinned: bool,
    pub actor_device: String,
    pub revision: u64,
    pub changed_at: i64,
    pub signature: String,
}

#[derive(Debug, Clone)]
pub struct PeerRecord {
    pub device_id: String,
    pub device_name: String,
    pub static_public: Vec<u8>,
    pub endpoint: String,
    pub certificate: SignedMemberCertificate,
    pub last_seen: i64,
    pub revoked: bool,
    pub owner: bool,
}
