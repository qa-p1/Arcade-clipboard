import Flutter
import Foundation

/// Call once from the host AppDelegate after the Flutter engine is available.
enum MobileMethodChannel {
    private static let name = "arcade_clipboard/mobile"
    private static let queue = DispatchQueue(label: "dev.arcade.clipboard.mobile-shared-store", qos: .userInitiated)

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            queue.async {
                do {
                    let store = try MobileSharedStore()
                    let value: Any?
                    switch call.method {
                    case "drainSharedInbox":
                        value = try store.drainInbox()
                    case "ackSharedInbox":
                        guard let arguments = call.arguments as? [String: Any],
                              let ids = arguments["ids"] as? [String] else {
                            throw MobileSharedStore.StoreError.invalid("Missing shared item IDs.")
                        }
                        try store.acknowledge(ids: ids)
                        value = nil
                    case "publishKeyboardHistory":
                        guard let arguments = call.arguments as? [String: Any] else {
                            throw MobileSharedStore.StoreError.invalid("Missing keyboard history.")
                        }
                        let items = arguments["items"] as? [[String: Any]] ?? []
                        try store.publishKeyboardHistory(items: items, paused: arguments["paused"] as? Bool ?? false)
                        value = nil
                    default:
                        throw MobileSharedStore.StoreError.invalid("Unsupported mobile storage operation.")
                    }
                    DispatchQueue.main.async { result(value) }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    DispatchQueue.main.async {
                        result(FlutterError(code: "mobile_shared_store", message: message, details: nil))
                    }
                }
            }
        }
    }
}
