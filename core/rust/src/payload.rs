//! Bounded clipboard representations shared by storage and encrypted transport.
use crate::model::{WireItem, MAX_TEXT_BYTES};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};

pub const MAX_PAYLOAD_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_ITEM_JSON_BYTES: usize = MAX_PAYLOAD_BYTES * 4 / 3 + 256 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Representation {
    pub mime_type: String,
    pub data_base64: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepresentationInfo {
    pub mime_type: String,
    pub size: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct StoredPayload {
    #[serde(default)]
    pub origin_signature: String,
    pub text: String,
    pub representations: Vec<Representation>,
}

pub fn representation_info(
    representations: &[Representation],
) -> Result<Vec<RepresentationInfo>, String> {
    representations
        .iter()
        .map(|r| {
            Ok(RepresentationInfo {
                mime_type: r.mime_type.clone(),
                size: STANDARD
                    .decode(&r.data_base64)
                    .map_err(|_| "Clipboard representation contains invalid base64".to_string())?
                    .len(),
                name: r.name.clone(),
            })
        })
        .collect()
}

pub fn content_hash(text: &str, representations: &[Representation]) -> String {
    if representations.is_empty() {
        return blake3::hash(text.as_bytes()).to_hex().to_string();
    }
    // Length-prefixed fields keep representations and filenames authenticated.
    let mut digest = blake3::Hasher::new();
    digest.update(b"arcade-clipboard:representations:v1");
    for value in std::iter::once(text).chain(representations.iter().flat_map(|r| {
        [
            r.mime_type.as_str(),
            r.name.as_deref().unwrap_or_default(),
            r.data_base64.as_str(),
        ]
    })) {
        digest.update(&(value.len() as u64).to_be_bytes());
        digest.update(value.as_bytes());
    }
    digest.finalize().to_hex().to_string()
}

pub fn validate_payload(
    text: &str,
    kind: &str,
    representations: &[Representation],
) -> Result<(), String> {
    if text.len() > MAX_TEXT_BYTES {
        return Err("Clipboard text exceeds the 32 KiB limit".into());
    }
    if !matches!(
        kind,
        "text" | "url" | "rich_text" | "image" | "file" | "files"
    ) {
        return Err("Unsupported clipboard item type".into());
    }
    if representations.len() > 32 {
        return Err("A clip can contain at most 32 representations".into());
    }
    let mut total = text.len();
    for representation in representations {
        let mime = &representation.mime_type;
        if mime.len() > 128
            || !mime.contains('/')
            || !mime
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"/.-+_".contains(&c))
        {
            return Err("Clipboard representation has an invalid content type".into());
        }
        if let Some(name) = &representation.name {
            if name.is_empty()
                || name.len() > 255
                || name.contains(['/', '\\', '\0'])
                || name == "."
                || name == ".."
            {
                return Err(
                    "A shared file must have a plain filename of 255 bytes or fewer".into(),
                );
            }
        }
        if representation.data_base64.len() > MAX_PAYLOAD_BYTES * 4 / 3 + 4 {
            return Err("Clipboard payload exceeds the 16 MiB limit".into());
        }
        let bytes = STANDARD
            .decode(&representation.data_base64)
            .map_err(|_| "Clipboard representation contains invalid base64".to_string())?;
        total = total.saturating_add(bytes.len());
        if total > MAX_PAYLOAD_BYTES {
            return Err("Clipboard payload exceeds the 16 MiB limit".into());
        }
        if matches!(mime.as_str(), "image/png" | "image/jpeg") {
            validate_image_dimensions(mime, &bytes)?;
        }
        if mime.starts_with("text/") && std::str::from_utf8(&bytes).is_err() {
            return Err("Text representation is not valid UTF-8".into());
        }
    }
    if text.trim().is_empty() && representations.is_empty() {
        return Err("Clipboard item is empty".into());
    }
    if kind == "image"
        && !representations
            .iter()
            .any(|r| matches!(r.mime_type.as_str(), "image/png" | "image/jpeg"))
    {
        return Err("Image clips require PNG or JPEG data".into());
    }
    if matches!(kind, "file" | "files") && !representations.iter().any(|r| r.name.is_some()) {
        return Err("File clips require named file data".into());
    }
    Ok(())
}

fn validate_image_dimensions(mime: &str, bytes: &[u8]) -> Result<(), String> {
    let dimensions = if mime == "image/png" {
        if bytes.len() < 33
            || !bytes.starts_with(b"\x89PNG\r\n\x1a\n")
            || &bytes[12..16] != b"IHDR"
            || bytes[8..12] != 13u32.to_be_bytes()
        {
            return Err("PNG clipboard data is invalid".into());
        }
        (
            u32::from_be_bytes(
                bytes[16..20]
                    .try_into()
                    .map_err(|_| "Invalid PNG dimensions")?,
            ),
            u32::from_be_bytes(
                bytes[20..24]
                    .try_into()
                    .map_err(|_| "Invalid PNG dimensions")?,
            ),
        )
    } else {
        if !bytes.starts_with(&[0xff, 0xd8, 0xff]) {
            return Err("JPEG clipboard data is invalid".into());
        }
        let mut offset = 2usize;
        let mut dimensions = None;
        while offset < bytes.len() {
            if bytes[offset] != 0xff {
                return Err("JPEG clipboard data is invalid".into());
            }
            while offset < bytes.len() && bytes[offset] == 0xff {
                offset += 1;
            }
            let marker = *bytes
                .get(offset)
                .ok_or_else(|| "JPEG clipboard data is incomplete".to_string())?;
            offset += 1;
            if matches!(marker, 0xd9 | 0xda) {
                break;
            }
            if marker == 0x01 || (0xd0..=0xd8).contains(&marker) {
                continue;
            }
            let length_bytes = bytes
                .get(offset..offset + 2)
                .ok_or_else(|| "JPEG clipboard data is incomplete".to_string())?;
            let length = u16::from_be_bytes([length_bytes[0], length_bytes[1]]) as usize;
            if length < 2 || offset.saturating_add(length) > bytes.len() {
                return Err("JPEG clipboard segment is invalid".into());
            }
            if (0xc0..=0xcf).contains(&marker) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
                if length < 8 {
                    return Err("JPEG clipboard dimensions are invalid".into());
                }
                dimensions = Some((
                    u16::from_be_bytes([bytes[offset + 5], bytes[offset + 6]]) as u32,
                    u16::from_be_bytes([bytes[offset + 3], bytes[offset + 4]]) as u32,
                ));
                break;
            }
            offset += length;
        }
        dimensions.ok_or_else(|| "JPEG clipboard dimensions are missing".to_string())?
    };
    if dimensions.0 == 0
        || dimensions.1 == 0
        || dimensions.0 > 16_384
        || dimensions.1 > 16_384
        || u64::from(dimensions.0) * u64::from(dimensions.1) > 64_000_000
    {
        return Err("Clipboard image exceeds the 16,384-pixel or 64-megapixel limit".into());
    }
    Ok(())
}

pub fn encoded_item(item: &WireItem) -> Result<Vec<u8>, String> {
    let bytes =
        serde_json::to_vec(item).map_err(|_| "Could not encode clipboard item".to_string())?;
    if bytes.len() > MAX_ITEM_JSON_BYTES {
        return Err("Encoded clipboard item exceeds the transfer limit".into());
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_and_unsafe_representations_are_rejected() {
        let mut representation = Representation {
            mime_type: "application/octet-stream".into(),
            data_base64: STANDARD.encode(b"example file"),
            name: Some("../private.txt".into()),
        };
        assert!(validate_payload("", "file", &[representation.clone()]).is_err());
        representation.name = Some("report.bin".into());
        representation.data_base64 = "invalid base64!".into();
        assert!(validate_payload("", "file", &[representation.clone()]).is_err());
        representation.data_base64 = STANDARD.encode(b"not a PNG");
        representation.mime_type = "image/png".into();
        assert!(validate_payload("", "image", &[representation]).is_err());
        assert!(validate_payload("", "image", &[]).is_err());
        assert!(validate_payload("", "file", &[]).is_err());
    }

    #[test]
    fn representation_hash_authenticates_format_filename_and_binary_content() {
        let mut representation = Representation {
            mime_type: "application/octet-stream".into(),
            data_base64: STANDARD.encode(b"bytes"),
            name: Some("a.bin".into()),
        };
        let first = content_hash("", &[representation.clone()]);
        representation.name = Some("b.bin".into());
        assert_ne!(first, content_hash("", &[representation.clone()]));
        representation.name = Some("a.bin".into());
        representation.mime_type = "application/pdf".into();
        assert_ne!(first, content_hash("", &[representation.clone()]));
        representation.mime_type = "application/octet-stream".into();
        representation.data_base64 = STANDARD.encode(b"other bytes");
        assert_ne!(first, content_hash("", &[representation]));
    }

    #[test]
    fn combined_payload_size_is_bounded() {
        let representation = Representation {
            mime_type: "application/octet-stream".into(),
            data_base64: STANDARD.encode(vec![1; MAX_PAYLOAD_BYTES / 2 + 1]),
            name: Some("file.bin".into()),
        };
        assert!(
            validate_payload("", "files", &[representation.clone(), representation])
                .unwrap_err()
                .contains("16 MiB")
        );
    }
}
