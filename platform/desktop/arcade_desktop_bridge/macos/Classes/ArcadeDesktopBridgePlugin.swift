import Cocoa
import CoreGraphics
import FlutterMacOS
import ServiceManagement

public class ArcadeDesktopBridgePlugin: NSObject, FlutterPlugin {
  private var targetProcessIdentifier: pid_t?
  private var targetApplication: NSRunningApplication?
  private var channel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private var clipboardTimer: Timer?
  private var clipboardRevision = NSPasteboard.general.changeCount
  private let maximumClipboardBytes = 32 * 1024 * 1024

  deinit {
    clipboardTimer?.invalidate()
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "arcade_clipboard/desktop_bridge",
      binaryMessenger: registrar.messenger)
    let instance = ArcadeDesktopBridgePlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "clipboardRevision":
      result(NSPasteboard.general.changeCount)
    case "setClipboardCaptureEnabled":
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      clipboardTimer?.invalidate()
      clipboardTimer = nil
      clipboardRevision = NSPasteboard.general.changeCount
      if enabled {
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
          guard let self else { return }
          let revision = NSPasteboard.general.changeCount
          guard revision != self.clipboardRevision else { return }
          self.clipboardRevision = revision
          self.channel?.invokeMethod("clipboardChanged", arguments: nil)
        }
      }
      result(nil)
    case "readClipboard":
      result(readClipboard())
    case "writeClipboard":
      writeClipboard(call.arguments, result: result)
    case "setBackgroundEnabled":
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      setBackgroundEnabled(enabled)
      result(nil)
    case "setLaunchAtLogin":
      guard #available(macOS 13.0, *) else {
        result(FlutterError(code: "login_unavailable", message: "Launch at login requires macOS 13 or newer.", details: nil))
        return
      }
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      do {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        result(nil)
      } catch {
        result(FlutterError(code: "login_unavailable", message: "Launch at login could not be updated. Check System Settings → General → Login Items.", details: nil))
      }
    case "launchAtLoginEnabled":
      if #available(macOS 13.0, *) { result(SMAppService.mainApp.status == .enabled) }
      else { result(false) }
    case "capabilities":
      let permitted = CGPreflightPostEventAccess()
      result([
        "paste": permitted,
        "focusRestore": true,
        "detail": permitted
          ? "macOS native paste is available."
          : "Allow Arcade Clipboard in System Settings → Privacy & Security → Accessibility to paste automatically. Copy fallback is available."
      ])
    case "requestPasteAccess":
      // Request access only; this method never emits a keystroke. The caller
      // re-reads capabilities after the user responds in System Settings.
      _ = CGRequestPostEventAccess()
      result(CGPreflightPostEventAccess())
    case "rememberTarget":
      targetApplication = NSWorkspace.shared.frontmostApplication
      targetProcessIdentifier = targetApplication?.processIdentifier
      result(nil)
    case "restoreTargetFocus":
      guard activateTarget() else {
        result(FlutterError(
          code: "target_unavailable",
          message: "The previously focused app is no longer available.",
          details: nil))
        return
      }
      result(nil)
    case "pasteKey":
      guard CGPreflightPostEventAccess() else {
        result(FlutterError(
          code: "accessibility_required",
          message: "Allow Arcade Clipboard in System Settings → Privacy & Security → Accessibility, then return to the app and choose the clip again.",
          details: nil))
        return
      }
      guard activateTarget() else {
        result(FlutterError(
          code: "target_unavailable",
          message: "The previously focused app is no longer available.",
          details: nil))
        return
      }
      let expectedProcessIdentifier = targetProcessIdentifier
      let expectedApplication = targetApplication
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        guard let expectedProcessIdentifier,
              let expectedApplication,
              !expectedApplication.isTerminated,
              expectedApplication.processIdentifier == expectedProcessIdentifier,
              let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              Self.isSameProcess(expectedApplication, frontmostApplication),
              !frontmostApplication.isTerminated else {
          result(FlutterError(
            code: "focus_denied",
            message: "The previously focused app could not be confirmed, so paste was cancelled.",
            details: nil))
          return
        }
        guard Self.postPasteShortcut() else {
          result(FlutterError(
            code: "paste_failed",
            message: "macOS could not send the paste shortcut. Copy is still available.",
            details: nil))
          return
        }
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func readClipboard() -> [String: Any] {
    let pasteboard = NSPasteboard.general
    let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    if pasteboard.types?.contains(concealed) == true {
      return ["formats": [], "files": [], "sensitive": true]
    }
    let revision = pasteboard.changeCount
    var formats: [[String: Any]] = []
    var total = 0
    let types: [(NSPasteboard.PasteboardType, String)] = [
      (.string, "text/plain"), (.html, "text/html"), (.rtf, "text/rtf"), (.png, "image/png")
    ]
    for (type, mime) in types {
      let data = type == .string
        ? pasteboard.string(forType: type)?.data(using: .utf8)
        : pasteboard.data(forType: type)
      guard let data, !data.isEmpty, data.count <= maximumClipboardBytes - total else { continue }
      total += data.count
      formats.append(["mimeType": mime, "bytes": FlutterStandardTypedData(bytes: data)])
    }
    if !formats.contains(where: { ($0["mimeType"] as? String)?.hasPrefix("image/") == true }),
       let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")),
       jpeg.count <= maximumClipboardBytes - total {
      total += jpeg.count
      formats.append(["mimeType": "image/jpeg", "bytes": FlutterStandardTypedData(bytes: jpeg)])
    }
    if !formats.contains(where: { ($0["mimeType"] as? String)?.hasPrefix("image/") == true }),
       let data = pasteboard.data(forType: .tiff), data.count <= maximumClipboardBytes,
       let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
       bitmap.pixelsWide <= 16384, bitmap.pixelsHigh <= 16384,
       bitmap.pixelsWide <= 16_777_216 / bitmap.pixelsHigh,
       let png = bitmap.representation(using: .png, properties: [:]),
       png.count <= maximumClipboardBytes - total {
      formats.append(["mimeType": "image/png", "bytes": FlutterStandardTypedData(bytes: png)])
    }
    let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [
      .urlReadingFileURLsOnly: true
    ]) as? [URL] ?? []).prefix(256).filter { $0.isFileURL }.map(\.path)
    // Never combine representations from two different clipboard owners.
    guard revision == pasteboard.changeCount else {
      return ["formats": [], "files": [], "sensitive": false]
    }
    return ["formats": formats, "files": files, "sensitive": false]
  }

  private func writeClipboard(_ arguments: Any?, result: FlutterResult) {
    guard let arguments = arguments as? [String: Any] else {
      result(FlutterError(code: "clipboard_unavailable", message: "Clipboard formats are missing.", details: nil))
      return
    }
    let item = NSPasteboardItem()
    var total = 0
    var count = 0
    let types: [String: NSPasteboard.PasteboardType] = [
      "text/plain": .string, "text/html": .html, "text/rtf": .rtf,
      "image/png": .png, "image/jpeg": NSPasteboard.PasteboardType("public.jpeg")
    ]
    for format in (arguments["formats"] as? [[String: Any]] ?? []).prefix(8) {
      guard let mime = format["mimeType"] as? String, let type = types[mime],
            let bytes = format["bytes"] as? FlutterStandardTypedData,
            !bytes.data.isEmpty, bytes.data.count <= maximumClipboardBytes - total else { continue }
      if mime == "text/plain" {
        guard let text = String(data: bytes.data, encoding: .utf8) else { continue }
        item.setString(text, forType: type)
      } else { item.setData(bytes.data, forType: type) }
      total += bytes.data.count
      count += 1
    }
    let files = (arguments["files"] as? [String] ?? []).prefix(256)
      .filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
      .map { NSURL(fileURLWithPath: $0) }
    var objects: [NSPasteboardWriting] = files
    if count > 0 { objects.insert(item, at: 0) }
    guard !objects.isEmpty else {
      result(FlutterError(code: "clipboard_unavailable", message: "This item has no supported clipboard representation.", details: nil))
      return
    }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.writeObjects(objects) else {
      result(FlutterError(code: "clipboard_unavailable", message: "macOS did not accept this clipboard item.", details: nil))
      return
    }
    result(nil)
  }

  private func setBackgroundEnabled(_ enabled: Bool) {
    if !enabled {
      if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
      statusItem = nil
      return
    }
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      if #available(macOS 11.0, *) { button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Arcade Clipboard") }
      else { button.title = "AC" }
      button.toolTip = "Arcade Clipboard"
    }
    let menu = NSMenu()
    // The tray menu every Arcade app has.
    let open = NSMenuItem(title: "Open Clipboard", action: #selector(openMainWindow), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    let settings = NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)
    let restart = NSMenuItem(title: "Restart Arcade Clipboard", action: #selector(restartApplication), keyEquivalent: "")
    restart.target = self
    menu.addItem(restart)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit Arcade Clipboard", action: #selector(quitApplication), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
  }

  @objc private func openMainWindow() { channel?.invokeMethod("showMainWindow", arguments: nil) }
  @objc private func openSettings() { channel?.invokeMethod("showSettings", arguments: nil) }
  @objc private func restartApplication() { channel?.invokeMethod("restartRequested", arguments: nil) }
  @objc private func quitApplication() { channel?.invokeMethod("quitRequested", arguments: nil) }

  private func activateTarget() -> Bool {
    guard let processIdentifier = targetProcessIdentifier,
          let application = targetApplication,
          application.processIdentifier == processIdentifier,
          !application.isTerminated else {
      return false
    }
    return application.activate(options: [.activateIgnoringOtherApps])
  }

  private static func isSameProcess(
    _ expected: NSRunningApplication,
    _ actual: NSRunningApplication
  ) -> Bool {
    guard expected.processIdentifier == actual.processIdentifier else { return false }
    if let expectedLaunchDate = expected.launchDate,
       let actualLaunchDate = actual.launchDate {
      return expectedLaunchDate == actualLaunchDate
    }
    return expected.bundleURL == actual.bundleURL
  }

  private static func postPasteShortcut() -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
          let pasteDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
          let pasteUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
          let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
      return false
    }
    commandDown.flags = .maskCommand
    pasteDown.flags = .maskCommand
    pasteUp.flags = .maskCommand
    commandUp.flags = []
    commandDown.post(tap: .cghidEventTap)
    pasteDown.post(tap: .cghidEventTap)
    pasteUp.post(tap: .cghidEventTap)
    commandUp.post(tap: .cghidEventTap)
    return true
  }
}
