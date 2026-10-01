import Flutter
import Foundation
import UIKit
import UniformTypeIdentifiers
import Darwin

/// Call once from the host AppDelegate after the Flutter engine is available.
enum MobileMethodChannel {
    private static let name = "arcade_clipboard/mobile"
    private static let queue = DispatchQueue(label: "dev.arcade.clipboard.mobile-shared-store", qos: .userInitiated)

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
        let discovery = MobileBonjourDiscovery(channel: channel)
        channel.setMethodCallHandler { call, result in
            if call.method == "configureDiscovery" {
                discovery.configure(call.arguments as? [String: Any] ?? [:])
                result(nil)
                return
            }
            if call.method == "stopDiscovery" {
                discovery.stop()
                result(nil)
                return
            }
            if call.method == "primeLocalNetwork" {
                discovery.primeLocalNetworkPermission()
                result(nil)
                return
            }
            if call.method == "openKeyboardSettings" {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return result(nil) }
                UIApplication.shared.open(url)
                result(nil)
                return
            }
            if call.method == "writeClipboard" {
                guard let args = call.arguments as? [String: Any], let formats = args["formats"] as? [[String: Any]] else {
                    return result(FlutterError(code: "clipboard_write", message: "Missing clipboard content.", details: nil))
                }
                var item: [String: Any] = [:]
                var total = 0
                for format in formats {
                    guard let mime = format["mimeType"] as? String, let bytes = format["bytes"] as? FlutterStandardTypedData else { continue }
                    total += bytes.data.count
                    guard total <= 16 * 1024 * 1024 else { return result(FlutterError(code: "clipboard_write", message: "This item exceeds 16 MB.", details: nil)) }
                    switch mime {
                    case "text/plain", "text/uri-list": item[UTType.utf8PlainText.identifier] = String(data: bytes.data, encoding: .utf8)
                    case "text/html": item[UTType.html.identifier] = bytes.data
                    case "text/rtf": item[UTType.rtf.identifier] = bytes.data
                    case "image/png": item[UTType.png.identifier] = bytes.data
                    case "image/jpeg": item[UTType.jpeg.identifier] = bytes.data
                    default: break
                    }
                }
                guard !item.isEmpty else { return result(FlutterError(code: "clipboard_write", message: "Save or share this item to use it.", details: nil)) }
                UIPasteboard.general.setItems([item], options: [.localOnly: true])
                result(nil)
                return
            }
            if call.method == "exportFile" {
                guard let args = call.arguments as? [String: Any], let bytes = args["bytes"] as? FlutterStandardTypedData,
                      bytes.data.count <= 16 * 1024 * 1024 else {
                    return result(FlutterError(code: "file_share", message: "The file is missing or exceeds 16 MB.", details: nil))
                }
                do {
                    let name = URL(fileURLWithPath: args["name"] as? String ?? "clip").lastPathComponent
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent(name.isEmpty ? "clip" : name)
                    try bytes.data.write(to: file, options: [.atomic, .completeFileProtection])
                    let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
                          let window = scene.windows.first(where: { $0.isKeyWindow }), var presenter = window.rootViewController else {
                        throw MobileSharedStore.StoreError.unavailable("Could not open the share sheet.")
                    }
                    while let presented = presenter.presentedViewController { presenter = presented }
                    share.popoverPresentationController?.sourceView = presenter.view
                    share.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                    share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: directory) }
                    presenter.present(share, animated: true)
                    result(nil)
                } catch {
                    result(FlutterError(code: "file_share", message: error.localizedDescription, details: nil))
                }
                return
            }
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

// Use system Bonjour rather than raw multicast sockets on iOS.
private final class MobileBonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let channel: FlutterMethodChannel
    private var browser: NetServiceBrowser?
    private var announcement: NetService?
    private var primer: NetServiceBrowser?
    private var resolving: [String: NetService] = [:]
    private var mesh = ""
    private var device = ""
    init(channel: FlutterMethodChannel) { self.channel = channel }

    func configure(_ configuration: [String: Any]) {
        stop()
        guard let mesh = configuration["mesh_id"] as? String, !mesh.isEmpty,
              let device = configuration["device_id"] as? String, !device.isEmpty,
              let identity = configuration["public"] as? String, !identity.isEmpty,
              mesh.utf8.count <= 128, device.utf8.count <= 63, identity.utf8.count <= 128,
              let port = configuration["port"] as? NSNumber, port.intValue > 0,
              port.intValue <= 65535 else { return }
        self.mesh = mesh
        self.device = device
        let service = NetService(domain: "local.", type: "_arcade-clip._tcp.", name: device, port: port.int32Value)
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "mesh": Data(mesh.utf8), "device": Data(device.utf8), "identity": Data(identity.utf8)
        ]))
        service.delegate = self
        service.publish()
        announcement = service
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_arcade-clip._tcp.", inDomain: "local.")
        self.browser = browser
    }

    /// iOS asks for Local Network access on first use and refuses connections
    /// until the user answers. Browsing briefly while the user scans a pairing
    /// code shows that prompt before the first pairing connection.
    func primeLocalNetworkPermission() {
        guard self.browser == nil, self.primer == nil else { return }
        let searching = NetServiceBrowser()
        searching.searchForServices(ofType: "_arcade-clip._tcp.", inDomain: "local.")
        self.primer = searching
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.primer?.stop()
            self?.primer = nil
        }
    }

    func stop() {
        browser?.delegate = nil
        announcement?.delegate = nil
        browser?.stop()
        announcement?.stop()
        for service in resolving.values { service.delegate = nil; service.stop() }
        resolving.removeAll()
        browser = nil
        announcement = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser, service.name != device, resolving[service.name] == nil, resolving.count < 128 else { return }
        resolving[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        resolving.removeValue(forKey: service.name)?.stop()
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        guard resolving[service.name] === service, service.port > 0, service.port <= 65535 else { return }
        defer { resolving.removeValue(forKey: service.name) }
        guard let data = service.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: data)
        func field(_ key: String) -> String? {
            guard let bytes = txt[key], bytes.count <= 128 else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
        guard field("mesh") == mesh, let peer = field("device"), peer != device,
              let identity = field("identity") else { return }
        let addresses = (service.addresses ?? []).prefix(16).compactMap { data -> String? in
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr>.size else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == sa_family_t(AF_INET) || address.pointee.sa_family == sa_family_t(AF_INET6) else { return nil }
                let requiredSize = address.pointee.sa_family == sa_family_t(AF_INET)
                    ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
                guard raw.count >= requiredSize, raw.count <= MemoryLayout<sockaddr_storage>.size else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                let ip = String(cString: host)
                if address.pointee.sa_family == sa_family_t(AF_INET6) {
                    // Link-local IPv6 needs an interface scope, which socket
                    // address strings cannot carry to the core; IPv4 or a
                    // routable IPv6 address is always advertised alongside.
                    let scope = base.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_scope_id
                    guard scope == 0, !ip.contains("%"), !ip.lowercased().hasPrefix("fe80") else { return nil }
                    return "[\(ip)]:\(service.port)"
                }
                return "\(ip):\(service.port)"
            }
        }
        if !addresses.isEmpty {
            channel.invokeMethod("peerDiscovered", arguments: [
                "device_id": peer, "public": identity, "addresses": addresses
            ])
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        if resolving[sender.name] === sender { resolving.removeValue(forKey: sender.name) }
    }
}
