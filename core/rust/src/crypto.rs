use crate::model::{
    MemberCertificate, Revocation, SignedMemberCertificate, SignedRevocation, PROTOCOL_VERSION,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use rand::rngs::OsRng;
use snow::{Builder, HandshakeState};

pub fn encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn decode(value: &str) -> Result<Vec<u8>, String> {
    URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| "Pairing data is malformed".to_string())
}

pub fn generate_owner_signing_key() -> SigningKey {
    SigningKey::generate(&mut OsRng)
}

pub fn sign_member(
    key: &SigningKey,
    certificate: MemberCertificate,
) -> Result<SignedMemberCertificate, String> {
    let bytes = serde_json::to_vec(&certificate)
        .map_err(|e| format!("Could not encode device membership: {e}"))?;
    Ok(SignedMemberCertificate {
        certificate,
        signature: encode(&key.sign(&bytes).to_bytes()),
    })
}

pub fn verify_member(owner_public: &[u8], signed: &SignedMemberCertificate) -> Result<(), String> {
    if signed.certificate.version != PROTOCOL_VERSION {
        return Err("Device membership version is unsupported".into());
    }
    let public: [u8; 32] = owner_public
        .try_into()
        .map_err(|_| "Mesh owner signing key is invalid".to_string())?;
    let key = VerifyingKey::from_bytes(&public)
        .map_err(|_| "Mesh owner signing key is invalid".to_string())?;
    let signature_bytes = decode(&signed.signature)?;
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|_| "Device membership signature is malformed".to_string())?;
    let bytes = serde_json::to_vec(&signed.certificate)
        .map_err(|e| format!("Could not encode device membership: {e}"))?;
    key.verify_strict(&bytes, &signature)
        .map_err(|_| "Device membership could not be verified by this mesh owner".into())
}

pub fn sign_revocation(
    key: &SigningKey,
    revocation: Revocation,
) -> Result<SignedRevocation, String> {
    let bytes = serde_json::to_vec(&revocation)
        .map_err(|e| format!("Could not encode device revocation: {e}"))?;
    Ok(SignedRevocation {
        revocation,
        signature: encode(&key.sign(&bytes).to_bytes()),
    })
}

pub fn verify_revocation(owner_public: &[u8], signed: &SignedRevocation) -> Result<(), String> {
    if signed.revocation.version != PROTOCOL_VERSION {
        return Err("Device revocation version is unsupported".into());
    }
    let public: [u8; 32] = owner_public
        .try_into()
        .map_err(|_| "Mesh owner signing key is invalid".to_string())?;
    let key = VerifyingKey::from_bytes(&public)
        .map_err(|_| "Mesh owner signing key is invalid".to_string())?;
    let signature_bytes = decode(&signed.signature)?;
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|_| "Device revocation signature is malformed".to_string())?;
    let bytes = serde_json::to_vec(&signed.revocation)
        .map_err(|e| format!("Could not encode device revocation: {e}"))?;
    key.verify_strict(&bytes, &signature)
        .map_err(|_| "Device revocation could not be verified by this mesh owner".into())
}

pub fn build_handshake(
    static_private: &[u8; 32],
    pairing_psk: Option<&[u8; 32]>,
    prologue: &[u8],
    initiator: bool,
) -> Result<HandshakeState, String> {
    let pattern = if pairing_psk.is_some() {
        "Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s"
    } else {
        "Noise_XX_25519_ChaChaPoly_BLAKE2s"
    };
    let params = pattern
        .parse()
        .map_err(|e| format!("Invalid Noise protocol parameters: {e}"))?;
    let mut builder = Builder::new(params)
        .local_private_key(static_private)
        .map_err(|e| format!("Could not initialize encrypted device session: {e}"))?
        .prologue(prologue)
        .map_err(|e| format!("Could not bind encrypted session context: {e}"))?;
    if let Some(psk) = pairing_psk {
        builder = builder
            .psk(3, psk)
            .map_err(|e| format!("Could not initialize one-time pairing authorization: {e}"))?;
    }
    if initiator {
        builder
            .build_initiator()
            .map_err(|e| format!("Could not start encrypted device session: {e}"))
    } else {
        builder
            .build_responder()
            .map_err(|e| format!("Could not accept encrypted device session: {e}"))
    }
}

pub fn verification_code(handshake_hash: &[u8]) -> String {
    let digest = blake3::hash(handshake_hash);
    let n = u32::from_le_bytes(digest.as_bytes()[..4].try_into().unwrap_or([0; 4])) % 1_000_000;
    format!("{n:06}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::MemberCertificate;

    #[test]
    fn membership_signature_rejects_tampering() {
        let signing = generate_owner_signing_key();
        let cert = MemberCertificate {
            version: 1,
            mesh_id: "mesh".into(),
            device_id: "device".into(),
            device_name: "Laptop".into(),
            static_public: encode(&[3; 32]),
            issued_at: 1,
            item_signing_public: String::new(),
            platform: String::new(),
            capabilities: Vec::new(),
        };
        let mut signed = sign_member(&signing, cert).unwrap();
        verify_member(&signing.verifying_key().to_bytes(), &signed).unwrap();
        signed.certificate.device_name = "Attacker".into();
        assert!(verify_member(&signing.verifying_key().to_bytes(), &signed).is_err());
    }

    #[test]
    fn pairing_sas_is_stable_for_both_sides() {
        assert_eq!(
            verification_code(b"same transcript"),
            verification_code(b"same transcript")
        );
        assert_ne!(
            verification_code(b"same transcript"),
            verification_code(b"other transcript")
        );
    }
    #[test]
    fn revocation_requires_owner_signature_and_binds_mesh_device_and_epoch() {
        let signing = generate_owner_signing_key();
        let signed = sign_revocation(
            &signing,
            Revocation {
                version: PROTOCOL_VERSION,
                mesh_id: "mesh-a".into(),
                device_id: "device-a".into(),
                revoked_at: 42,
                epoch: 3,
            },
        )
        .unwrap();
        let key = signing.verifying_key().to_bytes();
        verify_revocation(&key, &signed).unwrap();
        let other_key = generate_owner_signing_key().verifying_key().to_bytes();
        assert!(verify_revocation(&other_key, &signed).is_err());
        let mut altered = signed.clone();
        altered.revocation.mesh_id = "mesh-b".into();
        assert!(verify_revocation(&key, &altered).is_err());
        altered = signed.clone();
        altered.revocation.device_id = "device-b".into();
        assert!(verify_revocation(&key, &altered).is_err());
        altered = signed;
        altered.revocation.epoch += 1;
        assert!(verify_revocation(&key, &altered).is_err());
    }

    #[test]
    fn malformed_public_keys_and_signatures_return_errors() {
        let signing = generate_owner_signing_key();
        let mut signed = sign_member(
            &signing,
            MemberCertificate {
                version: 1,
                mesh_id: "m".into(),
                device_id: "d".into(),
                device_name: "n".into(),
                static_public: encode(&[1; 32]),
                issued_at: 1,
                item_signing_public: String::new(),
                platform: String::new(),
                capabilities: Vec::new(),
            },
        )
        .unwrap();
        assert!(verify_member(&[0; 31], &signed).is_err());
        signed.signature = encode(&[0; 63]);
        assert!(verify_member(&signing.verifying_key().to_bytes(), &signed).is_err());
    }
}

/// Dedicated domain-separated Ed25519 identity for provenance signatures.
/// The derivation preserves existing credential-store identity blobs.
pub fn item_signing_key(static_private: &[u8; 32]) -> SigningKey {
    SigningKey::from_bytes(&blake3::derive_key(
        "arcade-clipboard:item-signing:v1",
        static_private,
    ))
}

pub fn sign_item(private: &[u8; 32], item: &mut crate::model::WireItem) -> Result<(), String> {
    item.origin_signature.clear();
    let bytes = serde_json::to_vec(item)
        .map_err(|_| "Could not encode clipboard provenance".to_string())?;
    item.origin_signature = encode(&item_signing_key(private).sign(&bytes).to_bytes());
    Ok(())
}

pub fn verify_item(public: &str, item: &crate::model::WireItem) -> Result<(), String> {
    let key_bytes: [u8; 32] = decode(public)?
        .try_into()
        .map_err(|_| "Clipboard origin signing identity is invalid".to_string())?;
    let key = VerifyingKey::from_bytes(&key_bytes)
        .map_err(|_| "Clipboard origin signing identity is invalid".to_string())?;
    let signature = Signature::from_slice(&decode(&item.origin_signature)?)
        .map_err(|_| "Clipboard origin signature is invalid".to_string())?;
    let mut unsigned = item.clone();
    unsigned.origin_signature.clear();
    let bytes = serde_json::to_vec(&unsigned)
        .map_err(|_| "Could not encode clipboard provenance".to_string())?;
    key.verify_strict(&bytes, &signature)
        .map_err(|_| "Clipboard origin signature could not be verified".into())
}

#[cfg(test)]
mod provenance_tests {
    use super::*;
    #[test]
    fn origin_signatures_reject_plaintext_metadata_and_payload_tampering() {
        let private = [19; 32];
        let public = encode(&item_signing_key(&private).verifying_key().to_bytes());
        let mut item = crate::model::WireItem {
            protocol_version: 1,
            id: uuid::Uuid::new_v4().to_string(),
            origin_device: uuid::Uuid::new_v4().to_string(),
            sender_sequence: 1,
            source_name: "Desktop".into(),
            created_at: 10,
            expires_at: 20,
            text: "Original".into(),
            kind: "text".into(),
            content_hash: crate::payload::content_hash("Original", &[]),
            representations: Vec::new(),
            origin_signature: String::new(),
        };
        sign_item(&private, &mut item).unwrap();
        verify_item(&public, &item).unwrap();
        let mut altered = item.clone();
        altered.text = "Altered".into();
        altered.content_hash = crate::payload::content_hash("Altered", &[]);
        assert!(verify_item(&public, &altered).is_err());
        altered = item.clone();
        altered.expires_at += 1;
        assert!(verify_item(&public, &altered).is_err());
        altered = item.clone();
        altered.id = uuid::Uuid::new_v4().to_string();
        assert!(verify_item(&public, &altered).is_err());
        altered = item.clone();
        altered.origin_device = uuid::Uuid::new_v4().to_string();
        assert!(verify_item(&public, &altered).is_err());
        altered = item.clone();
        altered
            .representations
            .push(crate::payload::Representation {
                mime_type: "text/html".into(),
                data_base64: "SGVsbG8=".into(),
                name: None,
            });
        assert!(verify_item(&public, &altered).is_err());
        let wrong = encode(&item_signing_key(&[20; 32]).verifying_key().to_bytes());
        assert!(verify_item(&wrong, &item).is_err());
    }
}

pub fn sign_pin(
    private: &[u8; 32],
    state: &mut crate::model::SignedPinState,
) -> Result<(), String> {
    state.signature.clear();
    let mut bytes = b"arcade-clipboard:pin-update:v1:".to_vec();
    bytes.extend(serde_json::to_vec(state).map_err(|_| "Could not encode pin update".to_string())?);
    state.signature = encode(&item_signing_key(private).sign(&bytes).to_bytes());
    Ok(())
}

pub fn verify_pin(public: &str, state: &crate::model::SignedPinState) -> Result<(), String> {
    let key_bytes: [u8; 32] = decode(public)?
        .try_into()
        .map_err(|_| "Pin signing identity is invalid".to_string())?;
    let key = VerifyingKey::from_bytes(&key_bytes)
        .map_err(|_| "Pin signing identity is invalid".to_string())?;
    let signature = Signature::from_slice(&decode(&state.signature)?)
        .map_err(|_| "Pin signature is invalid".to_string())?;
    let mut unsigned = state.clone();
    unsigned.signature.clear();
    let mut bytes = b"arcade-clipboard:pin-update:v1:".to_vec();
    bytes.extend(
        serde_json::to_vec(&unsigned).map_err(|_| "Could not encode pin update".to_string())?,
    );
    key.verify_strict(&bytes, &signature)
        .map_err(|_| "Pin update could not be authenticated".into())
}
