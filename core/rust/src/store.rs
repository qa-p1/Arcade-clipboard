use crate::model::{
    DEFAULT_MAX_ITEMS, DEFAULT_RETENTION_HOURS, HistoryItem, MAX_TEXT_BYTES, PeerRecord, WireItem,
};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, Payload},
};
use rand::{RngCore, rngs::OsRng};
use rusqlite::{Connection, OptionalExtension, params};
use std::{
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

const SCHEMA_VERSION: i64 = 3;
const AAD_VERSION: i64 = 3;
const MAX_RETAINED_ITEMS: usize = 10_000;
const MAX_SYNC_SEEN: i64 = 100_000;
const MAX_DELETED_TOMBSTONES: i64 = 100_000;
const MAX_REVOCATION_TOMBSTONES: i64 = 10_000;
const MAX_SOURCE_NAME_BYTES: usize = 128;
const MAX_ITEM_LIFETIME_MS: i64 = 30 * 24 * 60 * 60 * 1000;
const MAX_FUTURE_CLOCK_SKEW_MS: i64 = 5 * 60 * 1000;
const MAX_TOMBSTONE_AGE_MS: i64 = 31 * 24 * 60 * 60 * 1000;
const HASH_PRIVACY_SCRUB_MARKER: &str = "hash_privacy_scrub_pending_v3";

pub struct Store {
    conn: Connection,
    key: [u8; 32],
}

impl Store {
    pub fn open(path: &Path, key: [u8; 32]) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("Could not create data folder: {e}"))?;
        }
        let mut conn = Connection::open(path)
            .map_err(|e| format!("Could not open local history database: {e}"))?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(db_error)?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(db_error)?;
        conn.pragma_update(None, "secure_delete", "ON")
            .map_err(db_error)?;
        let schema_version: i64 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .map_err(db_error)?;
        if schema_version > SCHEMA_VERSION {
            return Err("Local history database was created by a newer app version".into());
        }
        if schema_version == 0 && table_exists(&conn, "items")? {
            if column_exists(&conn, "items", "aad_version")? {
                migrate_hashes_v2_to_v3(&mut conn, &key)?;
            } else {
                migrate_aad_v1_to_v2(&mut conn, &key)?;
                migrate_hashes_v2_to_v3(&mut conn, &key)?;
            }
        } else if schema_version == 0 {
            let tx = conn.transaction().map_err(db_error)?;
            create_schema_v3(&tx)?;
            tx.pragma_update(None, "user_version", SCHEMA_VERSION)
                .map_err(db_error)?;
            tx.commit().map_err(db_error)?;
        } else if schema_version == 1 {
            migrate_aad_v1_to_v2(&mut conn, &key)?;
            migrate_hashes_v2_to_v3(&mut conn, &key)?;
        } else if schema_version == 2 {
            migrate_hashes_v2_to_v3(&mut conn, &key)?;
        }
        if conn
            .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .map_err(db_error)?
            != SCHEMA_VERSION
        {
            return Err("Local history database schema version is invalid".into());
        }
        if hash_privacy_scrub_pending(&conn)? {
            compact_after_hash_migration(&conn)?;
            conn.execute("DELETE FROM meta WHERE key=?1", [HASH_PRIVACY_SCRUB_MARKER])
                .map_err(db_error)?;
        }
        ensure_support_schema(&conn)?;
        let mut store = Self { conn, key };
        store.expire()?;
        Ok(store)
    }

    pub fn meta(&self, key: &str) -> Result<Option<String>, String> {
        self.conn
            .query_row("SELECT value FROM meta WHERE key=?1", [key], |r| r.get(0))
            .optional()
            .map_err(db_error)
    }

    pub fn set_meta(&self, key: &str, value: &str) -> Result<(), String> {
        self.conn.execute("INSERT INTO meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key, value]).map_err(db_error)?;
        Ok(())
    }

    pub fn setting<T: std::str::FromStr>(&self, key: &str, fallback: T) -> T {
        self.conn
            .query_row("SELECT value FROM settings WHERE key=?1", [key], |r| {
                r.get::<_, String>(0)
            })
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(fallback)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<(), String> {
        self.conn.execute("INSERT INTO settings(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key, value]).map_err(db_error)?;
        Ok(())
    }

    pub fn capture(&mut self, item: &WireItem, max_items: usize) -> Result<bool, String> {
        self.expire()?;
        validate_wire_item(item)?;
        if self.was_deleted(&item.id)? {
            return Ok(false);
        }
        let content_tag = keyed_content_tag(&self.key, &item.content_hash);
        let seen_tag: Option<String> = self
            .conn
            .query_row(
                "SELECT content_tag FROM sync_seen WHERE item_id=?1",
                [&item.id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?;
        if let Some(tag) = seen_tag {
            if tag != content_tag {
                return Err("An item ID was replayed with different content".into());
            }
            return Ok(false);
        }
        let existing: Option<String> = self
            .conn
            .query_row(
                "SELECT content_tag FROM items WHERE id=?1",
                [&item.id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?;
        if let Some(tag) = existing {
            if tag != content_tag {
                return Err("An item ID was reused with different content".into());
            }
            return Ok(false);
        }
        let cipher = XChaCha20Poly1305::new((&self.key).into());
        let mut nonce = [0u8; 24];
        OsRng.fill_bytes(&mut nonce);
        let aad = item_aad(item, &content_tag);
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: item.text.as_bytes(),
                    aad: &aad,
                },
            )
            .map_err(|_| "Could not encrypt clipboard content for local storage".to_string())?;
        let seen_count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM sync_seen", [], |r| r.get(0))
            .map_err(db_error)?;
        if seen_count >= MAX_SYNC_SEEN {
            return Err(
                "This profile reached its replay-protection capacity; refusing new clipboard items"
                    .into(),
            );
        }
        let tx = self.conn.transaction().map_err(db_error)?;
        tx.execute(
            "INSERT INTO items(id,origin_device,protocol_version,sender_sequence,source_name,created_at,expires_at,kind,content_tag,nonce,ciphertext,pinned,aad_version)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,0,?12)",
            params![item.id,item.origin_device,item.protocol_version,item.sender_sequence,item.source_name,item.created_at,item.expires_at,item.kind,content_tag,nonce.as_slice(),ciphertext,AAD_VERSION],
        ).map_err(db_error)?;
        tx.execute(
            "INSERT INTO sync_seen(item_id,content_tag,received_at) VALUES(?1,?2,?3)",
            params![item.id, content_tag, now_ms()],
        )
        .map_err(db_error)?;
        tx.commit().map_err(db_error)?;
        self.prune(max_items)?;
        Ok(true)
    }

    pub fn item(&self, id: &str) -> Result<Option<WireItem>, String> {
        let row = self.conn.query_row(
            "SELECT protocol_version,sender_sequence,id,origin_device,source_name,created_at,expires_at,kind,content_tag,nonce,ciphertext,aad_version FROM items WHERE id=?1",
            [id], |r| Ok((r.get::<_, u16>(0)?,r.get::<_, u64>(1)?,r.get::<_, String>(2)?,r.get::<_, String>(3)?,r.get::<_, String>(4)?,r.get::<_, i64>(5)?,r.get::<_, i64>(6)?,r.get::<_, String>(7)?,r.get::<_, String>(8)?,r.get::<_, Vec<u8>>(9)?,r.get::<_, Vec<u8>>(10)?,r.get::<_, i64>(11)?))
        ).optional().map_err(db_error)?;
        row.map(
            |(
                protocol_version,
                sender_sequence,
                id,
                origin_device,
                source_name,
                created_at,
                expires_at,
                kind,
                content_tag,
                nonce,
                ciphertext,
                aad_version,
            )| {
                let cipher = XChaCha20Poly1305::new((&self.key).into());
                let nonce = checked_nonce(&nonce)?;
                let aad = item_aad_for_row(
                    aad_version,
                    protocol_version,
                    sender_sequence,
                    &id,
                    &origin_device,
                    &source_name,
                    created_at,
                    expires_at,
                    &kind,
                    &content_tag,
                )?;
                let bytes = cipher
                    .decrypt(
                        nonce,
                        Payload {
                            msg: &ciphertext,
                            aad: &aad,
                        },
                    )
                    .map_err(|_| {
                        "Clipboard history failed local authentication; the item was not returned"
                            .to_string()
                    })?;
                let text = String::from_utf8(bytes)
                    .map_err(|_| "Stored clipboard content is not valid UTF-8".to_string())?;
                verify_local_content_tag(&self.key, &content_tag, &text)?;
                let content_hash = blake3::hash(text.as_bytes()).to_hex().to_string();
                Ok(WireItem {
                    protocol_version,
                    id,
                    origin_device,
                    sender_sequence,
                    source_name,
                    created_at,
                    expires_at,
                    text,
                    kind,
                    content_hash,
                })
            },
        )
        .transpose()
    }

    pub fn active_items(&mut self, limit: usize) -> Result<Vec<WireItem>, String> {
        self.expire()?;
        let mut stmt = self
            .conn
            .prepare("SELECT id FROM items ORDER BY created_at ASC LIMIT ?1")
            .map_err(db_error)?;
        let ids = stmt
            .query_map([limit.clamp(1, MAX_RETAINED_ITEMS) as i64], |r| {
                r.get::<_, String>(0)
            })
            .map_err(db_error)?;
        let mut out = Vec::new();
        for id in ids {
            if let Some(item) = self.item(&id.map_err(db_error)?)? {
                out.push(item);
            }
        }
        Ok(out)
    }

    pub fn next_sequence(&self) -> Result<u64, String> {
        let current: u64 = self
            .meta("local_sequence")?
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        if current >= i64::MAX as u64 {
            return Err("Clipboard origin sequence is exhausted".into());
        }
        let next = current + 1;
        self.set_meta("local_sequence", &next.to_string())?;
        Ok(next)
    }

    pub fn history(
        &mut self,
        query: Option<&str>,
        limit: usize,
    ) -> Result<Vec<HistoryItem>, String> {
        self.expire()?;
        let mut statement = self.conn.prepare("SELECT protocol_version,sender_sequence,id,origin_device,source_name,created_at,expires_at,kind,content_tag,nonce,ciphertext,pinned,aad_version FROM items ORDER BY pinned DESC, created_at DESC, id DESC LIMIT ?1").map_err(db_error)?;
        let scan_limit = MAX_RETAINED_ITEMS as i64;
        let rows = statement
            .query_map([scan_limit], |r| {
                Ok((
                    r.get::<_, u16>(0)?,
                    r.get::<_, u64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, String>(7)?,
                    r.get::<_, String>(8)?,
                    r.get::<_, Vec<u8>>(9)?,
                    r.get::<_, Vec<u8>>(10)?,
                    r.get::<_, i64>(11)?,
                    r.get::<_, i64>(12)?,
                ))
            })
            .map_err(db_error)?;
        let needle = query.unwrap_or_default().trim().to_lowercase();
        let cipher = XChaCha20Poly1305::new((&self.key).into());
        let mut out = Vec::new();
        for row in rows {
            let (
                protocol_version,
                sender_sequence,
                id,
                origin_device,
                source_name,
                created_at,
                expires_at,
                kind,
                content_tag,
                nonce,
                ciphertext,
                pinned,
                aad_version,
            ) = row.map_err(db_error)?;
            let nonce = checked_nonce(&nonce)?;
            let aad = item_aad_for_row(
                aad_version,
                protocol_version,
                sender_sequence,
                &id,
                &origin_device,
                &source_name,
                created_at,
                expires_at,
                &kind,
                &content_tag,
            )?;
            let text = cipher
                .decrypt(
                    nonce,
                    Payload {
                        msg: &ciphertext,
                        aad: &aad,
                    },
                )
                .map_err(|_| "Clipboard history failed local authentication".to_string())?;
            let text = String::from_utf8(text)
                .map_err(|_| "Stored clipboard content is not valid UTF-8".to_string())?;
            verify_local_content_tag(&self.key, &content_tag, &text)?;
            if !needle.is_empty()
                && !text.to_lowercase().contains(&needle)
                && !source_name.to_lowercase().contains(&needle)
                && !kind.to_lowercase().contains(&needle)
            {
                continue;
            }
            out.push(HistoryItem {
                id,
                origin_device,
                source_name,
                created_at,
                expires_at,
                text,
                kind,
                pinned: pinned != 0,
            });
            if out.len() >= limit.clamp(1, 1000) {
                break;
            }
        }
        Ok(out)
    }

    pub fn set_pinned(&self, id: &str, pinned: bool) -> Result<bool, String> {
        if pinned {
            let count: i64 = self
                .conn
                .query_row("SELECT COUNT(*) FROM items WHERE pinned=1", [], |r| {
                    r.get(0)
                })
                .map_err(db_error)?;
            let already: bool = self
                .conn
                .query_row("SELECT pinned FROM items WHERE id=?1", [id], |r| {
                    r.get::<_, i64>(0)
                })
                .optional()
                .map_err(db_error)?
                .unwrap_or(0)
                != 0;
            if count >= 100 && !already {
                return Err("You can pin up to 100 clips".into());
            }
        }
        let changed = self
            .conn
            .execute(
                "UPDATE items SET pinned=?2 WHERE id=?1",
                params![id, pinned as i32],
            )
            .map_err(db_error)?;
        Ok(changed > 0)
    }

    pub fn delete_item(&self, id: &str) -> Result<bool, String> {
        if uuid::Uuid::parse_str(id).is_err() {
            return Err("Clipboard item ID must be a valid UUID".into());
        }
        let already_deleted = self.was_deleted(id)?;
        if !already_deleted {
            let count: i64 = self
                .conn
                .query_row("SELECT COUNT(*) FROM deleted_items", [], |r| r.get(0))
                .map_err(db_error)?;
            if count >= MAX_DELETED_TOMBSTONES {
                return Err(
                    "This profile reached its deletion-tombstone capacity; refusing new deletions"
                        .into(),
                );
            }
            self.conn
                .execute(
                    "INSERT INTO deleted_items(id,deleted_at) VALUES(?1,?2)",
                    params![id, now_ms()],
                )
                .map_err(db_error)?;
        }
        let count = self
            .conn
            .execute("DELETE FROM items WHERE id=?1", [id])
            .map_err(db_error)?;
        Ok(count > 0)
    }

    pub fn deleted_ids(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT id FROM deleted_items ORDER BY deleted_at,id")
            .map_err(db_error)?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(db_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(db_error)
    }

    pub fn was_deleted(&self, id: &str) -> Result<bool, String> {
        self.conn
            .query_row("SELECT 1 FROM deleted_items WHERE id=?1", [id], |_| Ok(()))
            .optional()
            .map(|v| v.is_some())
            .map_err(db_error)
    }

    pub fn devices(&self) -> Result<Vec<PeerRecord>, String> {
        let mut stmt = self.conn.prepare("SELECT device_id,device_name,static_public,endpoint,certificate,COALESCE(last_seen,0),revoked_at,owner FROM devices ORDER BY owner DESC,device_name COLLATE NOCASE").map_err(db_error)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Vec<u8>>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, Option<i64>>(6)?,
                    r.get::<_, i64>(7)?,
                ))
            })
            .map_err(db_error)?;
        let mut devices = Vec::new();
        for row in rows {
            let (
                device_id,
                device_name,
                static_public,
                endpoint,
                certificate,
                last_seen,
                revoked_at,
                owner,
            ) = row.map_err(db_error)?;
            devices.push(PeerRecord {
                device_id,
                device_name,
                static_public,
                endpoint,
                certificate: serde_json::from_str(&certificate)
                    .map_err(|e| format!("Stored device certificate is invalid: {e}"))?,
                last_seen,
                revoked: revoked_at.is_some(),
                owner: owner != 0,
            });
        }
        Ok(devices)
    }

    pub fn add_device(&self, peer: &PeerRecord) -> Result<(), String> {
        if uuid::Uuid::parse_str(&peer.device_id).is_err() {
            return Err("Device ID must be a valid UUID".into());
        }
        if peer.revoked {
            return Err("A revoked device cannot be added again".into());
        }
        let tx = self.conn.unchecked_transaction().map_err(db_error)?;
        let revoked: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM revocations WHERE device_id=?1) OR EXISTS(SELECT 1 FROM devices WHERE device_id=?1 AND revoked_at IS NOT NULL)",
            [&peer.device_id], |r| r.get(0),
        ).map_err(db_error)?;
        if revoked {
            return Err("A revoked device cannot be added again".into());
        }
        tx.execute("INSERT INTO devices(device_id,device_name,static_public,endpoint,certificate,owner,last_seen,revoked_at) VALUES(?1,?2,?3,?4,?5,?6,?7,NULL) ON CONFLICT(device_id) DO UPDATE SET device_name=excluded.device_name,static_public=excluded.static_public,endpoint=excluded.endpoint,certificate=excluded.certificate,last_seen=excluded.last_seen WHERE devices.revoked_at IS NULL",
            params![peer.device_id,peer.device_name,peer.static_public,peer.endpoint,serde_json::to_string(&peer.certificate).map_err(|e|e.to_string())?,peer.owner as i32,peer.last_seen]).map_err(db_error)?;
        tx.commit().map_err(db_error)?;
        Ok(())
    }

    pub fn mark_seen(&self, device_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE devices SET last_seen=?2 WHERE device_id=?1",
                params![device_id, now_ms()],
            )
            .map_err(db_error)?;
        Ok(())
    }

    pub fn revoke(
        &self,
        device_id: &str,
        at: i64,
        epoch: u64,
        signature: &str,
    ) -> Result<bool, String> {
        if uuid::Uuid::parse_str(device_id).is_err() {
            return Err("Device ID must be a valid UUID".into());
        }
        let epoch_i64 =
            i64::try_from(epoch).map_err(|_| "Revocation epoch is out of range".to_string())?;
        if signature.len() > 4096 {
            return Err("Revocation signature is too large".into());
        }
        let tx = self.conn.unchecked_transaction().map_err(db_error)?;
        let existing: Option<(i64, String)> = tx
            .query_row(
                "SELECT epoch,signature FROM revocations WHERE device_id=?1",
                [device_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(db_error)?;
        match existing {
            Some((old_epoch, _)) if epoch_i64 < old_epoch => {
                return Err("Revocation epoch is older than the stored revocation".into());
            }
            Some((old_epoch, old_signature))
                if epoch_i64 == old_epoch && old_signature != signature =>
            {
                return Err("Conflicting revocations use the same epoch".into());
            }
            Some((old_epoch, _)) if epoch_i64 == old_epoch => {}
            Some(_) => {
                tx.execute(
                    "UPDATE revocations SET revoked_at=?2,epoch=?3,signature=?4 WHERE device_id=?1",
                    params![device_id, at, epoch_i64, signature],
                )
                .map_err(db_error)?;
            }
            None => {
                let count: i64 = tx
                    .query_row("SELECT COUNT(*) FROM revocations", [], |r| r.get(0))
                    .map_err(db_error)?;
                if count >= MAX_REVOCATION_TOMBSTONES {
                    return Err("This profile reached its revocation-tombstone capacity; refusing new revocations".into());
                }
                tx.execute("INSERT INTO revocations(device_id,revoked_at,epoch,signature) VALUES(?1,?2,?3,?4)", params![device_id,at,epoch_i64,signature]).map_err(db_error)?;
            }
        }
        let changed = tx.execute("UPDATE devices SET revoked_at=COALESCE(revoked_at,?2) WHERE device_id=?1 AND owner=0 AND revoked_at IS NULL", params![device_id,at]).map_err(db_error)?;
        tx.commit().map_err(db_error)?;
        Ok(changed > 0)
    }

    pub fn revocations(&self) -> Result<Vec<(String, i64, u64, String)>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT device_id,revoked_at,epoch,signature FROM revocations")
            .map_err(db_error)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? as u64, r.get(3)?))
            })
            .map_err(db_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(db_error)
    }

    pub fn expire(&mut self) -> Result<(), String> {
        self.expire_expired()?;
        self.prune_count(self.setting("max_items", DEFAULT_MAX_ITEMS))?;
        Ok(())
    }

    fn prune(&mut self, max_items: usize) -> Result<(), String> {
        self.expire_expired()?;
        self.prune_count(max_items)
    }

    fn expire_expired(&self) -> Result<(), String> {
        let retention: u32 = self.setting("retention_hours", DEFAULT_RETENTION_HOURS);
        let now = now_ms();
        let cutoff = now.saturating_sub(i64::from(retention.max(1)) * 60 * 60 * 1000);
        self.conn
            .execute(
                "DELETE FROM items WHERE expires_at<=?1 OR (created_at<?2 AND pinned=0)",
                params![now, cutoff],
            )
            .map_err(db_error)?;
        let tombstone_cutoff = now.saturating_sub(MAX_TOMBSTONE_AGE_MS);
        self.conn
            .execute(
                "DELETE FROM deleted_items WHERE deleted_at<?1",
                [tombstone_cutoff],
            )
            .map_err(db_error)?;
        self.conn
            .execute(
                "DELETE FROM sync_seen WHERE received_at<?1 AND item_id NOT IN (SELECT id FROM items)",
                [tombstone_cutoff],
            )
            .map_err(db_error)?;
        Ok(())
    }

    fn prune_count(&self, max_items: usize) -> Result<(), String> {
        let max_items = max_items.clamp(1, MAX_RETAINED_ITEMS) as i64;
        self.conn.execute("DELETE FROM items WHERE id IN (SELECT id FROM items ORDER BY pinned DESC,created_at DESC,id DESC LIMIT -1 OFFSET ?1)", [max_items]).map_err(db_error)?;
        Ok(())
    }
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

pub fn validate_wire_item(item: &WireItem) -> Result<(), String> {
    if item.protocol_version != crate::model::PROTOCOL_VERSION {
        return Err("Clipboard item protocol version is not supported".into());
    }
    if item.sender_sequence == 0 {
        return Err("Clipboard item is missing its origin sequence".into());
    }
    if item.sender_sequence > i64::MAX as u64 {
        return Err("Clipboard item origin sequence is out of range".into());
    }
    if uuid::Uuid::parse_str(&item.id).is_err()
        || uuid::Uuid::parse_str(&item.origin_device).is_err()
    {
        return Err("Clipboard item identifiers must be valid UUIDs".into());
    }
    if item.text.as_bytes().len() > MAX_TEXT_BYTES {
        return Err("Clipboard text exceeds the 32 KiB limit".into());
    }
    if item.source_name.as_bytes().len() > MAX_SOURCE_NAME_BYTES {
        return Err("Clipboard source name exceeds the 128-byte limit".into());
    }
    if item.created_at < 0 || item.expires_at < 0 {
        return Err("Clipboard item timestamps cannot be negative".into());
    }
    if item.created_at > now_ms().saturating_add(MAX_FUTURE_CLOCK_SKEW_MS) {
        return Err("Clipboard item creation time is too far in the future".into());
    }
    if item.expires_at <= item.created_at
        || item.expires_at.saturating_sub(item.created_at) > MAX_ITEM_LIFETIME_MS
    {
        return Err("Clipboard item expiry must be within 30 days of its creation time".into());
    }
    if item.expires_at <= now_ms() {
        return Err("Clipboard item has expired".into());
    }
    if item.kind != "text" && item.kind != "url" {
        return Err("Unsupported clipboard item type".into());
    }
    if blake3::hash(item.text.as_bytes()).to_hex().as_str() != item.content_hash {
        return Err("Clipboard content hash did not match".into());
    }
    Ok(())
}

fn item_aad(item: &WireItem, content_tag: &str) -> Vec<u8> {
    item_aad_v3(
        item.protocol_version,
        item.sender_sequence,
        &item.id,
        &item.origin_device,
        &item.source_name,
        item.created_at,
        item.expires_at,
        &item.kind,
        content_tag,
    )
}

fn item_aad_for_row(
    aad_version: i64,
    protocol_version: u16,
    sender_sequence: u64,
    id: &str,
    origin_device: &str,
    source_name: &str,
    created_at: i64,
    expires_at: i64,
    kind: &str,
    content_tag: &str,
) -> Result<Vec<u8>, String> {
    match aad_version {
        AAD_VERSION => Ok(item_aad_v3(
            protocol_version,
            sender_sequence,
            id,
            origin_device,
            source_name,
            created_at,
            expires_at,
            kind,
            content_tag,
        )),
        _ => Err("Stored clipboard authentication metadata version is unsupported".into()),
    }
}

fn legacy_item_aad(
    protocol_version: u16,
    id: &str,
    origin_device: &str,
    source_name: &str,
    created_at: i64,
    expires_at: i64,
    kind: &str,
    content_hash: &str,
) -> Vec<u8> {
    format!(
        "{}:{}:{}:{}:{}:{}:{}:{}",
        protocol_version,
        id,
        origin_device,
        source_name,
        created_at,
        expires_at,
        kind,
        content_hash
    )
    .into_bytes()
}

fn item_aad_v2(
    protocol_version: u16,
    sender_sequence: u64,
    id: &str,
    origin_device: &str,
    source_name: &str,
    created_at: i64,
    expires_at: i64,
    kind: &str,
    content_hash: &str,
) -> Vec<u8> {
    let mut aad = b"arcade-clipboard/item-aad/v2\0".to_vec();
    append_aad_field(&mut aad, &protocol_version.to_be_bytes());
    append_aad_field(&mut aad, &sender_sequence.to_be_bytes());
    append_aad_field(&mut aad, id.as_bytes());
    append_aad_field(&mut aad, origin_device.as_bytes());
    append_aad_field(&mut aad, source_name.as_bytes());
    append_aad_field(&mut aad, &created_at.to_be_bytes());
    append_aad_field(&mut aad, &expires_at.to_be_bytes());
    append_aad_field(&mut aad, kind.as_bytes());
    append_aad_field(&mut aad, content_hash.as_bytes());
    aad
}

fn item_aad_v3(
    protocol_version: u16,
    sender_sequence: u64,
    id: &str,
    origin_device: &str,
    source_name: &str,
    created_at: i64,
    expires_at: i64,
    kind: &str,
    content_tag: &str,
) -> Vec<u8> {
    let mut aad = b"arcade-clipboard/item-aad/v3\0".to_vec();
    append_aad_field(&mut aad, &protocol_version.to_be_bytes());
    append_aad_field(&mut aad, &sender_sequence.to_be_bytes());
    append_aad_field(&mut aad, id.as_bytes());
    append_aad_field(&mut aad, origin_device.as_bytes());
    append_aad_field(&mut aad, source_name.as_bytes());
    append_aad_field(&mut aad, &created_at.to_be_bytes());
    append_aad_field(&mut aad, &expires_at.to_be_bytes());
    append_aad_field(&mut aad, kind.as_bytes());
    append_aad_field(&mut aad, content_tag.as_bytes());
    aad
}

fn keyed_content_tag(key: &[u8; 32], wire_content_hash: &str) -> String {
    let mut input = b"arcade-clipboard/local-content-tag/v1\0".to_vec();
    input.extend_from_slice(wire_content_hash.as_bytes());
    blake3::keyed_hash(key, &input).to_hex().to_string()
}

fn verify_local_content_tag(key: &[u8; 32], content_tag: &str, text: &str) -> Result<(), String> {
    let wire_hash = blake3::hash(text.as_bytes()).to_hex().to_string();
    if keyed_content_tag(key, &wire_hash) != content_tag {
        return Err("Clipboard history failed local content verification".into());
    }
    Ok(())
}

fn append_aad_field(aad: &mut Vec<u8>, field: &[u8]) {
    aad.extend_from_slice(&(field.len() as u64).to_be_bytes());
    aad.extend_from_slice(field);
}

fn checked_nonce(nonce: &[u8]) -> Result<&XNonce, String> {
    if nonce.len() != 24 {
        return Err("Stored clipboard encryption nonce is malformed".into());
    }
    Ok(XNonce::from_slice(nonce))
}

fn migrate_aad_v1_to_v2(conn: &mut Connection, key: &[u8; 32]) -> Result<(), String> {
    let tx = conn.transaction().map_err(db_error)?;
    tx.execute_batch("ALTER TABLE items ADD COLUMN aad_version INTEGER NOT NULL DEFAULT 1;")
        .map_err(db_error)?;
    let records = {
        let mut stmt = tx.prepare("SELECT protocol_version,sender_sequence,id,origin_device,source_name,created_at,expires_at,kind,content_hash,nonce,ciphertext FROM items").map_err(db_error)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, u16>(0)?,
                    r.get::<_, u64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, String>(7)?,
                    r.get::<_, String>(8)?,
                    r.get::<_, Vec<u8>>(9)?,
                    r.get::<_, Vec<u8>>(10)?,
                ))
            })
            .map_err(db_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?
    };
    let cipher = XChaCha20Poly1305::new(key.into());
    for (
        protocol_version,
        sender_sequence,
        id,
        origin_device,
        source_name,
        created_at,
        expires_at,
        kind,
        content_hash,
        nonce,
        ciphertext,
    ) in records
    {
        let nonce_value = checked_nonce(&nonce)?;
        let old_aad = legacy_item_aad(
            protocol_version,
            &id,
            &origin_device,
            &source_name,
            created_at,
            expires_at,
            &kind,
            &content_hash,
        );
        let plaintext = cipher
            .decrypt(
                nonce_value,
                Payload {
                    msg: &ciphertext,
                    aad: &old_aad,
                },
            )
            .map_err(|_| {
                "Local history database failed authentication during migration".to_string()
            })?;
        let mut new_nonce = [0u8; 24];
        OsRng.fill_bytes(&mut new_nonce);
        if blake3::hash(&plaintext).to_hex().as_str() != content_hash {
            return Err("Local history content hash failed validation during migration".into());
        }
        let new_aad = item_aad_v2(
            protocol_version,
            sender_sequence,
            &id,
            &origin_device,
            &source_name,
            created_at,
            expires_at,
            &kind,
            &content_hash,
        );
        let new_ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&new_nonce),
                Payload {
                    msg: &plaintext,
                    aad: &new_aad,
                },
            )
            .map_err(|_| "Could not re-encrypt local history during migration".to_string())?;
        tx.execute(
            "UPDATE items SET nonce=?2,ciphertext=?3,aad_version=2 WHERE id=?1",
            params![id, new_nonce.as_slice(), new_ciphertext],
        )
        .map_err(db_error)?;
    }
    tx.pragma_update(None, "user_version", 2)
        .map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(())
}

fn migrate_hashes_v2_to_v3(conn: &mut Connection, key: &[u8; 32]) -> Result<(), String> {
    let tx = conn.transaction().map_err(db_error)?;
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS sync_seen (
            item_id TEXT PRIMARY KEY NOT NULL,
            content_hash TEXT NOT NULL,
            received_at INTEGER NOT NULL
        );",
    )
    .map_err(db_error)?;
    let rows = {
        let mut stmt = tx.prepare("SELECT protocol_version,sender_sequence,id,origin_device,source_name,created_at,expires_at,kind,content_hash,nonce,ciphertext FROM items ORDER BY id").map_err(db_error)?;
        let mapped = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, u16>(0)?,
                    r.get::<_, u64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, String>(7)?,
                    r.get::<_, String>(8)?,
                    r.get::<_, Vec<u8>>(9)?,
                    r.get::<_, Vec<u8>>(10)?,
                ))
            })
            .map_err(db_error)?;
        mapped.collect::<Result<Vec<_>, _>>().map_err(db_error)?
    };
    let seen_hashes = {
        let mut stmt = tx
            .prepare("SELECT item_id,content_hash FROM sync_seen ORDER BY item_id")
            .map_err(db_error)?;
        let mapped = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
            .map_err(db_error)?;
        mapped.collect::<Result<Vec<_>, _>>().map_err(db_error)?
    };
    let cipher = XChaCha20Poly1305::new(key.into());
    for (
        protocol_version,
        sender_sequence,
        id,
        origin_device,
        source_name,
        created_at,
        expires_at,
        kind,
        wire_hash,
        nonce,
        ciphertext,
    ) in rows
    {
        let nonce_value = checked_nonce(&nonce)?;
        let old_aad = item_aad_v2(
            protocol_version,
            sender_sequence,
            &id,
            &origin_device,
            &source_name,
            created_at,
            expires_at,
            &kind,
            &wire_hash,
        );
        let plaintext = cipher
            .decrypt(
                nonce_value,
                Payload {
                    msg: &ciphertext,
                    aad: &old_aad,
                },
            )
            .map_err(|_| {
                "Local history database failed authentication during hash privacy migration"
                    .to_string()
            })?;
        let plaintext_hash = blake3::hash(&plaintext).to_hex().to_string();
        if plaintext_hash != wire_hash {
            return Err("Local history content hash failed validation during migration".into());
        }
        let content_tag = keyed_content_tag(key, &wire_hash);
        let mut new_nonce = [0u8; 24];
        OsRng.fill_bytes(&mut new_nonce);
        let new_aad = item_aad_v3(
            protocol_version,
            sender_sequence,
            &id,
            &origin_device,
            &source_name,
            created_at,
            expires_at,
            &kind,
            &content_tag,
        );
        let new_ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&new_nonce),
                Payload {
                    msg: &plaintext,
                    aad: &new_aad,
                },
            )
            .map_err(|_| {
                "Could not re-encrypt local history during hash privacy migration".to_string()
            })?;
        tx.execute(
            "UPDATE items SET content_hash=?2,nonce=?3,ciphertext=?4,aad_version=3 WHERE id=?1",
            params![id, content_tag, new_nonce.as_slice(), new_ciphertext],
        )
        .map_err(db_error)?;
    }
    for (item_id, wire_hash) in seen_hashes {
        let content_tag = keyed_content_tag(key, &wire_hash);
        tx.execute(
            "UPDATE sync_seen SET content_hash=?2 WHERE item_id=?1",
            params![item_id, content_tag],
        )
        .map_err(db_error)?;
    }
    tx.execute_batch(
        "ALTER TABLE items RENAME COLUMN content_hash TO content_tag;
                      ALTER TABLE sync_seen RENAME COLUMN content_hash TO content_tag;",
    )
    .map_err(db_error)?;
    tx.execute(
        "INSERT OR REPLACE INTO meta(key,value) VALUES(?1,'pending')",
        [HASH_PRIVACY_SCRUB_MARKER],
    )
    .map_err(db_error)?;
    tx.pragma_update(None, "user_version", SCHEMA_VERSION)
        .map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(())
}

fn create_schema_v3(tx: &rusqlite::Transaction<'_>) -> Result<(), String> {
    tx.execute_batch(
        "CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
         CREATE TABLE items (
            id TEXT PRIMARY KEY NOT NULL,
            origin_device TEXT NOT NULL,
            protocol_version INTEGER NOT NULL DEFAULT 1,
            sender_sequence INTEGER NOT NULL DEFAULT 0,
            source_name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            kind TEXT NOT NULL,
            content_tag TEXT NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            aad_version INTEGER NOT NULL DEFAULT 3
         );
         CREATE INDEX items_created_idx ON items(created_at DESC);
         CREATE TABLE deleted_items (id TEXT PRIMARY KEY NOT NULL, deleted_at INTEGER NOT NULL);
         CREATE TABLE devices (
            device_id TEXT PRIMARY KEY NOT NULL,
            device_name TEXT NOT NULL,
            static_public BLOB NOT NULL,
            endpoint TEXT NOT NULL,
            certificate TEXT NOT NULL,
            owner INTEGER NOT NULL DEFAULT 0,
            revoked_at INTEGER,
            last_seen INTEGER
         );
         CREATE TABLE revocations (
            device_id TEXT PRIMARY KEY NOT NULL,
            revoked_at INTEGER NOT NULL,
            epoch INTEGER NOT NULL,
            signature TEXT NOT NULL
         );
         CREATE TABLE sync_seen (item_id TEXT PRIMARY KEY NOT NULL, content_tag TEXT NOT NULL, received_at INTEGER NOT NULL);
         CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
         INSERT INTO settings(key,value) VALUES ('paused','false'),('retention_hours','24'),('max_items','500');"
    ).map_err(db_error)?;
    Ok(())
}

fn ensure_support_schema(conn: &Connection) -> Result<(), String> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
         CREATE INDEX IF NOT EXISTS items_created_idx ON items(created_at DESC);
         CREATE TABLE IF NOT EXISTS deleted_items (id TEXT PRIMARY KEY NOT NULL, deleted_at INTEGER NOT NULL);
         CREATE TABLE IF NOT EXISTS devices (
            device_id TEXT PRIMARY KEY NOT NULL, device_name TEXT NOT NULL, static_public BLOB NOT NULL,
            endpoint TEXT NOT NULL, certificate TEXT NOT NULL, owner INTEGER NOT NULL DEFAULT 0,
            revoked_at INTEGER, last_seen INTEGER
         );
         CREATE TABLE IF NOT EXISTS revocations (
            device_id TEXT PRIMARY KEY NOT NULL, revoked_at INTEGER NOT NULL, epoch INTEGER NOT NULL, signature TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS sync_seen (item_id TEXT PRIMARY KEY NOT NULL, content_tag TEXT NOT NULL, received_at INTEGER NOT NULL);
         CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
         INSERT OR IGNORE INTO settings(key,value) VALUES ('paused','false'),('retention_hours','24'),('max_items','500');"
    ).map_err(db_error)?;
    Ok(())
}

fn table_exists(conn: &Connection, table: &str) -> Result<bool, String> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
        [table],
        |row| row.get(0),
    )
    .map_err(db_error)
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool, String> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(db_error)?;
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(db_error)?;
    for existing in columns {
        if existing.map_err(db_error)? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

fn compact_after_hash_migration(conn: &Connection) -> Result<(), String> {
    conn.execute_batch("VACUUM;").map_err(db_error)?;
    let mut busy = 0;
    conn.pragma(None, "wal_checkpoint", "TRUNCATE", |row| {
        busy = row.get(0)?;
        Ok(())
    })
    .map_err(db_error)?;
    if busy != 0 {
        return Err(
            "Could not securely finish the local history migration while the database was busy"
                .into(),
        );
    }
    Ok(())
}

fn hash_privacy_scrub_pending(conn: &Connection) -> Result<bool, String> {
    if !table_exists(conn, "meta")? {
        return Ok(false);
    }
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key=?1 AND value='pending')",
        [HASH_PRIVACY_SCRUB_MARKER],
        |row| row.get(0),
    )
    .map_err(db_error)
}

fn db_error(error: rusqlite::Error) -> String {
    format!("Local history database error: {error}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{MemberCertificate, SignedMemberCertificate};
    use tempfile::tempdir;

    fn sample() -> WireItem {
        sample_text("secret clipboard")
    }

    fn sample_text(text: &str) -> WireItem {
        sample_text_at(text, now_ms())
    }

    fn sample_text_at(text: &str, created_at: i64) -> WireItem {
        let text = text.to_string();
        WireItem {
            protocol_version: 1,
            id: uuid::Uuid::new_v4().to_string(),
            origin_device: uuid::Uuid::new_v4().to_string(),
            sender_sequence: 1,
            source_name: "Desktop".into(),
            created_at,
            expires_at: created_at + 24 * 60 * 60 * 1000,
            kind: "text".into(),
            content_hash: blake3::hash(text.as_bytes()).to_hex().to_string(),
            text,
        }
    }

    #[test]
    fn local_history_is_encrypted_and_searchable() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        let mut store = Store::open(&path, [7; 32]).unwrap();
        let item = sample();
        assert!(store.capture(&item, DEFAULT_MAX_ITEMS).unwrap());
        assert!(!store.capture(&item, DEFAULT_MAX_ITEMS).unwrap());
        let history = store.history(Some("clipboard"), 20).unwrap();
        assert_eq!(history[0].text, "secret clipboard");
        assert_eq!(history[0].expires_at, item.expires_at);
        let local_tag: String = store
            .conn
            .query_row(
                "SELECT content_tag FROM items WHERE id=?1",
                [&item.id],
                |r| r.get(0),
            )
            .unwrap();
        let seen_tag: String = store
            .conn
            .query_row(
                "SELECT content_tag FROM sync_seen WHERE item_id=?1",
                [&item.id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(local_tag, keyed_content_tag(&[7; 32], &item.content_hash));
        assert_eq!(seen_tag, local_tag);
        assert_ne!(local_tag, item.content_hash);
        drop(store);
        let bytes = std::fs::read(path).unwrap();
        assert!(
            !bytes
                .windows(b"secret clipboard".len())
                .any(|w| w == b"secret clipboard")
        );
        assert!(
            !bytes
                .windows(item.content_hash.len())
                .any(|w| w == item.content_hash.as_bytes())
        );
    }

    #[test]
    fn rejects_wrong_hash_and_oversized_text() {
        let mut item = sample();
        item.content_hash = "0".repeat(64);
        assert!(validate_wire_item(&item).is_err());
        item.content_hash = blake3::hash(item.text.as_bytes()).to_hex().to_string();
        item.text = "x".repeat(MAX_TEXT_BYTES + 1);
        assert!(validate_wire_item(&item).is_err());
    }

    #[test]
    fn history_preserves_whitespace_and_filters_before_applying_limit() {
        let dir = tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("history.sqlite"), [4; 32]).unwrap();
        let now = now_ms();
        let older_match = sample_text_at("  a target\nline with spaces  ", now - 10_000);
        let newer_miss = sample_text_at("newest unrelated", now - 1_000);
        store.capture(&older_match, 10).unwrap();
        store.capture(&newer_miss, 10).unwrap();

        let found = store.history(Some("target"), 1).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, older_match.id);
        assert_eq!(found[0].text, "  a target\nline with spaces  ");
        assert_eq!(found[0].expires_at, older_match.expires_at);
    }

    #[test]
    fn history_limit_counts_pinned_items_and_never_exceeds_requested_bound() {
        let dir = tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("history.sqlite"), [5; 32]).unwrap();
        let pinned = sample_text("keep this pinned");
        let newer = sample_text("newer but unpinned");
        assert!(store.capture(&pinned, 1).unwrap());
        assert!(store.set_pinned(&pinned.id, true).unwrap());
        assert!(store.capture(&newer, 1).unwrap());
        let count: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM items", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1);
        let history = store.history(None, 20).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].id, pinned.id);
        assert!(history[0].pinned);
    }

    #[test]
    fn replay_deduplication_survives_pruning_and_deletion() {
        let dir = tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("history.sqlite"), [6; 32]).unwrap();
        let first = sample_text("first item");
        assert!(store.capture(&first, 1).unwrap());
        let mut second = sample_text("second item");
        second.created_at = first.created_at + 1;
        second.expires_at = second.created_at + 24 * 60 * 60 * 1000;
        assert!(store.capture(&second, 1).unwrap());
        assert!(store.item(&first.id).unwrap().is_none());
        assert!(!store.capture(&first, 1).unwrap());

        let mut conflicting = first.clone();
        conflicting.text = "different content".into();
        conflicting.content_hash = blake3::hash(conflicting.text.as_bytes())
            .to_hex()
            .to_string();
        assert!(
            store
                .capture(&conflicting, 1)
                .unwrap_err()
                .contains("replayed with different content")
        );

        assert!(store.delete_item(&second.id).unwrap());
        assert!(!store.capture(&second, 1).unwrap());
        assert!(store.was_deleted(&second.id).unwrap());
    }

    #[test]
    fn authenticated_metadata_and_nonce_are_checked_before_returning_history() {
        let dir = tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("history.sqlite"), [8; 32]).unwrap();
        let item = sample();
        store.capture(&item, 10).unwrap();
        store
            .conn
            .execute(
                "UPDATE items SET source_name='Tampered' WHERE id=?1",
                [&item.id],
            )
            .unwrap();
        assert!(store.item(&item.id).unwrap_err().contains("authentication"));

        let second = sample();
        store.capture(&second, 10).unwrap();
        store
            .conn
            .execute(
                "UPDATE items SET nonce=?2 WHERE id=?1",
                params![second.id, vec![0u8; 23]],
            )
            .unwrap();
        assert!(
            store
                .item(&second.id)
                .unwrap_err()
                .contains("nonce is malformed")
        );
    }

    #[test]
    fn expired_tombstones_are_pruned_but_recent_replay_state_survives() {
        let dir = tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("history.sqlite"), [11; 32]).unwrap();
        let old_id = uuid::Uuid::new_v4().to_string();
        let recent_id = uuid::Uuid::new_v4().to_string();
        let old_at = now_ms() - MAX_TOMBSTONE_AGE_MS - 1;
        let recent_at = now_ms();
        store
            .conn
            .execute(
                "INSERT INTO sync_seen(item_id,content_tag,received_at) VALUES(?1,'old-tag',?2)",
                params![old_id, old_at],
            )
            .unwrap();
        store
            .conn
            .execute(
                "INSERT INTO sync_seen(item_id,content_tag,received_at) VALUES(?1,'recent-tag',?2)",
                params![recent_id, recent_at],
            )
            .unwrap();
        store
            .conn
            .execute(
                "INSERT INTO deleted_items(id,deleted_at) VALUES(?1,?2)",
                params![old_id, old_at],
            )
            .unwrap();
        store
            .conn
            .execute(
                "INSERT INTO deleted_items(id,deleted_at) VALUES(?1,?2)",
                params![recent_id, recent_at],
            )
            .unwrap();

        store.expire().unwrap();
        assert!(!store.was_deleted(&old_id).unwrap());
        assert!(store.was_deleted(&recent_id).unwrap());
        let seen_count: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM sync_seen", [], |row| row.get(0))
            .unwrap();
        assert_eq!(seen_count, 1);
    }

    #[test]
    fn interrupted_hash_scrub_is_retried_on_next_open() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        let key = [12; 32];
        let store = Store::open(&path, key).unwrap();
        store
            .set_meta(HASH_PRIVACY_SCRUB_MARKER, "pending")
            .unwrap();
        drop(store);

        let blocker = Connection::open(&path).unwrap();
        blocker
            .execute_batch("BEGIN; SELECT value FROM meta;")
            .unwrap();
        let first_open = Store::open(&path, key);
        assert!(first_open.is_err());
        assert!(hash_privacy_scrub_pending(&blocker).unwrap());
        blocker.execute_batch("ROLLBACK;").unwrap();
        drop(blocker);

        let store = Store::open(&path, key).unwrap();
        assert!(!hash_privacy_scrub_pending(&store.conn).unwrap());
    }

    #[test]
    fn v1_database_migrates_encryption_and_keyed_replay_tags_atomically() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        let key = [9; 32];
        let item = sample_text("migration keeps exact whitespace  \n");
        let orphan_id = uuid::Uuid::new_v4().to_string();
        let orphan_hash = blake3::hash(b"already pruned").to_hex().to_string();
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE items (
                    id TEXT PRIMARY KEY NOT NULL, origin_device TEXT NOT NULL, protocol_version INTEGER NOT NULL DEFAULT 1,
                    sender_sequence INTEGER NOT NULL DEFAULT 0, source_name TEXT NOT NULL, created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL, kind TEXT NOT NULL, content_hash TEXT NOT NULL, nonce BLOB NOT NULL,
                    ciphertext BLOB NOT NULL, pinned INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE sync_seen (item_id TEXT PRIMARY KEY NOT NULL,content_hash TEXT NOT NULL,received_at INTEGER NOT NULL);
                PRAGMA user_version=1;"
            ).unwrap();
            let cipher = XChaCha20Poly1305::new((&key).into());
            let mut nonce = [0u8; 24];
            OsRng.fill_bytes(&mut nonce);
            let aad = legacy_item_aad(
                item.protocol_version,
                &item.id,
                &item.origin_device,
                &item.source_name,
                item.created_at,
                item.expires_at,
                &item.kind,
                &item.content_hash,
            );
            let ciphertext = cipher
                .encrypt(
                    XNonce::from_slice(&nonce),
                    Payload {
                        msg: item.text.as_bytes(),
                        aad: &aad,
                    },
                )
                .unwrap();
            conn.execute(
                "INSERT INTO items(id,origin_device,protocol_version,sender_sequence,source_name,created_at,expires_at,kind,content_hash,nonce,ciphertext,pinned) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,0)",
                params![item.id,item.origin_device,item.protocol_version,item.sender_sequence,item.source_name,item.created_at,item.expires_at,item.kind,item.content_hash,nonce.as_slice(),ciphertext],
            ).unwrap();
            conn.execute(
                "INSERT INTO sync_seen(item_id,content_hash,received_at) VALUES(?1,?2,?3)",
                params![item.id, item.content_hash, now_ms()],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO sync_seen(item_id,content_hash,received_at) VALUES(?1,?2,?3)",
                params![orphan_id, orphan_hash, now_ms()],
            )
            .unwrap();
        }

        let store = Store::open(&path, key).unwrap();
        assert_eq!(
            store
                .conn
                .pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
                .unwrap(),
            3
        );
        assert_eq!(store.item(&item.id).unwrap().unwrap().text, item.text);
        let item_tag: String = store
            .conn
            .query_row(
                "SELECT content_tag FROM items WHERE id=?1",
                [&item.id],
                |r| r.get(0),
            )
            .unwrap();
        let seen_tag: String = store
            .conn
            .query_row(
                "SELECT content_tag FROM sync_seen WHERE item_id=?1",
                [&item.id],
                |r| r.get(0),
            )
            .unwrap();
        let orphan_tag: String = store
            .conn
            .query_row(
                "SELECT content_tag FROM sync_seen WHERE item_id=?1",
                [orphan_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(item_tag, keyed_content_tag(&key, &item.content_hash));
        assert_eq!(seen_tag, item_tag);
        assert_eq!(orphan_tag, keyed_content_tag(&key, &orphan_hash));
        assert_ne!(item_tag, item.content_hash);
        assert_ne!(orphan_tag, orphan_hash);
        assert!(!hash_privacy_scrub_pending(&store.conn).unwrap());
        for file in [path.clone(), path.with_extension("sqlite-wal")] {
            if let Ok(bytes) = std::fs::read(file) {
                assert!(
                    !bytes
                        .windows(item.content_hash.len())
                        .any(|w| w == item.content_hash.as_bytes())
                );
                assert!(
                    !bytes
                        .windows(orphan_hash.len())
                        .any(|w| w == orphan_hash.as_bytes())
                );
            }
        }
    }

    #[test]
    fn unknown_signed_revocation_is_persisted_and_blocks_later_certificate() {
        let dir = tempdir().unwrap();
        let store = Store::open(&dir.path().join("history.sqlite"), [10; 32]).unwrap();
        let device_id = uuid::Uuid::new_v4().to_string();
        let revoked_at = now_ms();
        assert!(
            !store
                .revoke(&device_id, revoked_at, 1, "signed-revocation")
                .unwrap()
        );
        assert_eq!(
            store.revocations().unwrap(),
            vec![(device_id.clone(), revoked_at, 1, "signed-revocation".into())]
        );
        let peer = PeerRecord {
            device_id: device_id.clone(),
            device_name: "stale device name".into(),
            static_public: vec![1; 32],
            endpoint: String::new(),
            certificate: SignedMemberCertificate {
                certificate: MemberCertificate {
                    version: 1,
                    mesh_id: uuid::Uuid::new_v4().to_string(),
                    device_id,
                    device_name: "stale device name".into(),
                    static_public: "stale-public-key".into(),
                    issued_at: revoked_at - 1000,
                },
                signature: "old-certificate-signature".into(),
            },
            last_seen: 0,
            revoked: false,
            owner: false,
        };
        assert!(
            store
                .add_device(&peer)
                .unwrap_err()
                .contains("revoked device cannot be added")
        );
        assert!(store.devices().unwrap().is_empty());
    }

    #[test]
    fn wire_item_metadata_is_bounded() {
        let mut item = sample();
        item.source_name = "n".repeat(MAX_SOURCE_NAME_BYTES + 1);
        assert!(
            validate_wire_item(&item)
                .unwrap_err()
                .contains("source name")
        );
        item = sample();
        item.sender_sequence = i64::MAX as u64 + 1;
        assert!(validate_wire_item(&item).unwrap_err().contains("sequence"));
        item = sample();
        item.created_at = -1;
        assert!(validate_wire_item(&item).unwrap_err().contains("negative"));
        item = sample();
        item.created_at = now_ms() + MAX_FUTURE_CLOCK_SKEW_MS + 1;
        item.expires_at = item.created_at + 60_000;
        assert!(validate_wire_item(&item).unwrap_err().contains("future"));
        item = sample();
        item.expires_at = item.created_at + MAX_ITEM_LIFETIME_MS + 1;
        assert!(validate_wire_item(&item).unwrap_err().contains("30 days"));
    }

    #[test]
    fn local_sequence_never_exceeds_sqlite_integer_range() {
        let dir = tempdir().unwrap();
        let store = Store::open(&dir.path().join("history.sqlite"), [13; 32]).unwrap();
        store
            .set_meta("local_sequence", &(i64::MAX as u64 - 1).to_string())
            .unwrap();
        assert_eq!(store.next_sequence().unwrap(), i64::MAX as u64);
        assert!(store.next_sequence().unwrap_err().contains("exhausted"));
        assert_eq!(
            store.meta("local_sequence").unwrap().unwrap(),
            i64::MAX.to_string()
        );
    }
}
