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
        var representations: [Representation]? = nil
    }

    struct Representation: Codable {
        let mime_type: String
        let data_base64: String
        let name: String?
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
        return try enqueue(representations: [], text: text, sourceName: sourceName)
    }

    func enqueue(representations: [Representation], text: String = "", sourceName: String = "This iPhone") throws -> SharedText {
        guard !readOnly else { throw StoreError.unavailable("The keyboard can only read shared history.") }
        guard !representations.isEmpty || !text.isEmpty else { throw StoreError.invalid("There is no content to add.") }
        guard text.utf8.count <= Self.maxSharedBytes else { throw StoreError.invalid("This text exceeds 32 KB.") }
        guard representations.count <= 32 else { throw StoreError.invalid("Share up to 32 files at a time.") }
        var total = text.utf8.count
        for representation in representations {
            guard Self.validMimeType(representation.mime_type) else { throw StoreError.invalid("This share has an invalid content type.") }
            if let name = representation.name {
                guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != "..",
                      !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
                    throw StoreError.invalid("The shared file has an invalid name.")
                }
            }
            guard representation.data_base64.utf8.count <= Self.maxInboxFileBytes,
                  let data = Data(base64Encoded: representation.data_base64) else { throw StoreError.invalid("This share has invalid data.") }
            if representation.mime_type.hasPrefix("text/"), String(data: data, encoding: .utf8) == nil {
                throw StoreError.invalid("This share has invalid text data.")
            }
            if representation.mime_type == "image/png", !data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
                throw StoreError.invalid("The shared PNG image could not be read.")
            }
            if representation.mime_type == "image/jpeg", !data.starts(with: [0xff, 0xd8, 0xff]) {
                throw StoreError.invalid("The shared JPEG image could not be read.")
            }
            total += data.count
            guard total <= 16 * 1024 * 1024 else { throw StoreError.invalid("This share exceeds 16 MB.") }
        }
        guard total <= 16 * 1024 * 1024 else { throw StoreError.invalid("This share exceeds 16 MB.") }
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
                kind: Self.contentKind(text: text, representations: representations),
                sourceName: String(sourceName.prefix(Self.maxSourceNameCharacters)),
                createdAt: Int64(Date().timeIntervalSince1970 * 1000),
                representations: representations.isEmpty ? nil : representations
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
                guard let data = try? boundedData(at: url, maximumBytes: Self.maxInboxFileBytes),
                      let item = try? decoder.decode(SharedText.self, from: data) else {
                    // One interrupted or damaged handoff must not block later shares.
                    try? fileManager.removeItem(at: url)
                    return nil
                }
                guard (!item.text.isEmpty || item.representations?.isEmpty == false),
                      item.text.lengthOfBytes(using: .utf8) <= Self.maxSharedBytes,
                      UUID(uuidString: item.id) != nil else { return nil }
                var row: [String: Any] = [
                    "id": item.id,
                    "text": item.text,
                    "kind": item.kind,
                    "sourceName": item.sourceName
                ]
                if let representations = item.representations {
                    row["representations"] = representations.map { representation -> [String: Any] in
                        var value: [String: Any] = ["mime_type": representation.mime_type, "data_base64": representation.data_base64]
                        if let name = representation.name { value["name"] = name }
                        return value
                    }
                }
                return (item.createdAt, row)
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
        guard !readOnly else { throw StoreError.unavailable("The keyboard can only read shared history.") }
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
        guard snapshot.version == 1, snapshot.items.count <= Self.maxKeyboardItems else {
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
                  UUID(uuidString: item.id) != nil,
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
            if let item = try? decoder.decode(SharedText.self, from: boundedData(at: url, maximumBytes: Self.maxInboxFileBytes)) {
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

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes else { throw StoreError.invalid("Shared content exceeds the storage limit.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw StoreError.invalid("Shared content exceeds the storage limit.") }
        return data
    }

    private func withInboxLock<T>(_ work: () throws -> T) throws -> T {
        guard !readOnly else { throw StoreError.unavailable("The keyboard can only read shared history.") }
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

    private static func validMimeType(_ mime: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/.-+_")
        return mime.utf8.count <= 128 && mime.contains("/") &&
            mime.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func contentKind(text: String, representations: [Representation]) -> String {
        let files = representations.filter { $0.name != nil }
        if !files.isEmpty { return files.count > 1 ? "files" : "file" }
        if representations.contains(where: { ["image/png", "image/jpeg"].contains($0.mime_type) }) { return "image" }
        if representations.contains(where: { ["text/html", "text/rtf"].contains($0.mime_type) }) { return "rich_text" }
        return isHTTPURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) ? "url" : "text"
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
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
    private static let maxInboxBytes: Int64 = 64 * 1024 * 1024
    private static let maxInboxFileBytes = 24 * 1024 * 1024
    private static let maxCacheFileBytes = 2 * 1024 * 1024 + 64 * 1024
    private static let maxSourceNameCharacters = 80
    private static let maxDrainItems = 50
    private static let maxInboxAgeSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let maxKeyboardItems = 30
    private static let maxKeyboardItemBytes = 32 * 1024
    private static let maxKeyboardBytes = 2 * 1024 * 1024
    private static let maxCacheAgeMilliseconds: Int64 = 7 * 24 * 60 * 60 * 1000
    private static let maxMissingExpiryAgeMilliseconds: Int64 = 7 * 24 * 60 * 60 * 1000
}
