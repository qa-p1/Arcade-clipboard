import Foundation
import Darwin

/// App Group handoff only. Rust remains authoritative for mesh history and sync.
/// Files are protected with iOS Data Protection and are visible only to signed app targets.
final class MobileSharedStore {
    struct SharedText: Codable {
        let id: String
        let text: String
        let kind: String
        let sourceName: String
        let createdAt: Int64
    }

    struct KeyboardItem: Codable {
        let id: String
        let sourceName: String
        let createdAt: Int64
        let expiresAt: Int64?
        let text: String
        let pinned: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case sourceName = "source_name"
            case createdAt = "created_at"
            case expiresAt = "expires_at"
            case text
            case pinned
        }
    }

    struct KeyboardSnapshot: Codable {
        let version: Int
        let writtenAt: Int64
        let paused: Bool
        let items: [KeyboardItem]

        enum CodingKeys: String, CodingKey {
            case version
            case writtenAt = "written_at"
            case paused
            case items
        }
    }

    struct KeyboardHistory {
        let paused: Bool
        let items: [KeyboardItem]
        let needsRefresh: Bool
    }

    private let root: URL
    private let inbox: URL
    private let cache: URL
    private let lock: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let readOnly: Bool

    init(groupIdentifier: String = "group.dev.arcade.clipboard", readOnly: Bool = false) throws {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            throw StoreError.unavailable("Shared mobile storage is unavailable. Check the App Group entitlement.")
        }
        root = container.appendingPathComponent("mobile-shared-v1", isDirectory: true)
        inbox = root.appendingPathComponent("inbox", isDirectory: true)
        cache = root.appendingPathComponent("keyboard-cache.json")
        lock = root.appendingPathComponent("inbox.lock")
        self.readOnly = readOnly
        if !readOnly {
            try fileManager.createDirectory(
                at: inbox,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
    }

    func enqueue(text: String, sourceName: String = "This iPhone") throws -> SharedText {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalid("There is no text to add.")
        }
        guard text.lengthOfBytes(using: .utf8) <= Self.maxSharedBytes else {
            throw StoreError.invalid("This text is too large to share. The limit is 32 KB.")
        }
        return try withInboxLock {
            try pruneExpiredInbox()
            let files = try inboxFiles()
            let queuedBytes = try files.reduce(Int64(0)) { total, file in
                guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    throw StoreError.unavailable("Could not safely measure the pending share queue.")
                }
                return total + Int64(size)
            }
            let item = SharedText(
                id: UUID().uuidString.lowercased(),
                text: text,
                kind: Self.isHTTPURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) ? "url" : "text",
                sourceName: String(sourceName.prefix(Self.maxSourceNameCharacters)),
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
            let data = try encoder.encode(item)
            guard data.count <= Self.maxInboxFileBytes else {
                throw StoreError.invalid("This share is too large to save on this iPhone.")
            }
            guard files.count < Self.maxInboxItems,
                  queuedBytes + Int64(data.count) <= Self.maxInboxBytes else {
                throw StoreError.invalid("There are too many shares waiting to sync. Open Arcade Clipboard to finish syncing them.")
            }
            try protectedAtomicWrite(data, to: inbox.appendingPathComponent("\(item.id).json"))
            return item
        }
    }

    /// Returns items without deleting them. Flutter acknowledges only after Rust capture succeeds.
    func drainInbox() throws -> [[String: Any]] {
        try withInboxLock {
            try pruneExpiredInbox()
            let rows = try inboxFiles().compactMap { url -> (Int64, [String: Any])? in
                let data = try boundedData(at: url, maximumBytes: Self.maxInboxFileBytes)
                let item = try decoder.decode(SharedText.self, from: data)
                guard !item.text.isEmpty,
                      item.text.lengthOfBytes(using: .utf8) <= Self.maxSharedBytes,
                      UUID(uuidString: item.id) != nil else { return nil }
                return (item.createdAt, [
                    "id": item.id,
                    "text": item.text,
                    "kind": item.kind,
                    "sourceName": item.sourceName
                ])
            }
            return rows.sorted { $0.0 < $1.0 }.prefix(Self.maxDrainItems).map { $0.1 }
        }
    }

    func acknowledge(ids: [String]) throws {
        try withInboxLock {
            for id in ids {
                guard let uuid = UUID(uuidString: id) else { continue }
                let url = inbox.appendingPathComponent("\(uuid.uuidString.lowercased()).json")
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        }
    }

    func publishKeyboardHistory(items: [[String: Any]], paused: Bool) throws {
        var bounded: [KeyboardItem] = []
        var byteCount = 0
        let writtenAt = Int64(Date().timeIntervalSince1970 * 1000)
        let snapshotExpiry = Self.saturatingAdd(writtenAt, Self.maxCacheAgeMilliseconds)
        if !paused {
            for value in items {
                guard let id = value["id"] as? String,
                      UUID(uuidString: id) != nil,
                      let text = value["text"] as? String,
                      !text.isEmpty else { continue }
                guard let createdAt = (value["created_at"] as? NSNumber)?.int64Value,
                      createdAt > 0 else { continue }
                let bytes = text.lengthOfBytes(using: .utf8)
                let missingExpiry = Self.saturatingAdd(createdAt, Self.maxMissingExpiryAgeMilliseconds)
                let requestedExpiry = (value["expires_at"] as? NSNumber)?.int64Value ?? missingExpiry
                let expiresAt = min(requestedExpiry, snapshotExpiry)
                guard expiresAt > writtenAt,
                      bytes <= Self.maxKeyboardItemBytes,
                      byteCount + bytes <= Self.maxKeyboardBytes else { continue }
                guard bounded.count < Self.maxKeyboardItems else { break }
                byteCount += bytes
                bounded.append(KeyboardItem(
                    id: id,
                    sourceName: String((value["source_name"] as? String ?? "").prefix(80)),
                    createdAt: createdAt,
                    expiresAt: expiresAt,
                    text: text,
                    pinned: value["pinned"] as? Bool ?? false
                ))
            }
        }
        let snapshot = KeyboardSnapshot(
            version: 1,
            writtenAt: writtenAt,
            paused: paused,
            items: bounded
        )
        try protectedAtomicWrite(encoder.encode(snapshot), to: cache)
    }

    func readKeyboardHistory() throws -> KeyboardHistory {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard fileManager.fileExists(atPath: cache.path) else {
            return KeyboardHistory(paused: false, items: [], needsRefresh: true)
        }
        let data: Data
        do {
            data = try boundedData(at: cache, maximumBytes: Self.maxCacheFileBytes)
        } catch {
            if !readOnly { try? fileManager.removeItem(at: cache) }
            return KeyboardHistory(paused: false, items: [], needsRefresh: true)
        }
        let snapshot: KeyboardSnapshot
        do {
            snapshot = try decoder.decode(KeyboardSnapshot.self, from: data)
        } catch {
            if !readOnly { try? fileManager.removeItem(at: cache) }
            return KeyboardHistory(paused: false, items: [], needsRefresh: true)
        }
        guard snapshot.writtenAt > 0,
              now >= snapshot.writtenAt,
              now - snapshot.writtenAt <= Self.maxCacheAgeMilliseconds else {
            if !readOnly { try? fileManager.removeItem(at: cache) }
            return KeyboardHistory(paused: snapshot.paused, items: [], needsRefresh: true)
        }
        let snapshotExpiry = Self.saturatingAdd(snapshot.writtenAt, Self.maxCacheAgeMilliseconds)
        let items = snapshot.items.compactMap { item -> KeyboardItem? in
            guard item.createdAt > 0,
                  !item.text.isEmpty,
                  item.text.lengthOfBytes(using: .utf8) <= Self.maxKeyboardItemBytes else { return nil }
            let missingExpiry = Self.saturatingAdd(item.createdAt, Self.maxMissingExpiryAgeMilliseconds)
            let expiry = min(item.expiresAt ?? missingExpiry, snapshotExpiry)
            guard expiry > now else { return nil }
            return KeyboardItem(
                id: item.id,
                sourceName: item.sourceName,
                createdAt: item.createdAt,
                expiresAt: expiry,
                text: item.text,
                pinned: item.pinned
            )
        }
        return KeyboardHistory(paused: snapshot.paused, items: items, needsRefresh: false)
    }

    private func inboxFiles() throws -> [URL] {
        try fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
    }

    private func pruneExpiredInbox() throws {
        let expiry = Date(timeIntervalSinceNow: -Self.maxInboxAgeSeconds)
        for url in try inboxFiles() {
            let expired: Bool
            if let item = try? decoder.decode(SharedText.self, from: Data(contentsOf: url)) {
                expired = Date(timeIntervalSince1970: Double(item.createdAt) / 1000) < expiry
            } else {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                expired = modified < expiry
            }
            if expired { try? fileManager.removeItem(at: url) }
        }
    }

    private func protectedAtomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func withInboxLock<T>(_ work: () throws -> T) throws -> T {
        let descriptor = open(lock.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw StoreError.unavailable("Could not safely access the pending share queue.")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw StoreError.unavailable("Could not safely access the pending share queue.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try work()
    }

    private static func isHTTPURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else { return false }
        return true
    }

    enum StoreError: LocalizedError {
        case unavailable(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .invalid(let message): return message
            }
        }
    }

    private static let maxSharedBytes = 32 * 1024
    private static let maxInboxItems = 100
    private static let maxInboxBytes: Int64 = 4 * 1024 * 1024
    private static let maxDrainItems = 50
    private static let maxInboxAgeSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let maxKeyboardItems = 30
    private static let maxKeyboardItemBytes = 32 * 1024
    private static let maxKeyboardBytes = 2 * 1024 * 1024
    private static let maxCacheAgeMilliseconds: Int64 = 7 * 24 * 60 * 60 * 1000
}
