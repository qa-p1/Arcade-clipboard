import Cocoa
import CoreGraphics
import FlutterMacOS

public class ArcadeDesktopBridgePlugin: NSObject, FlutterPlugin {
  private var targetProcessIdentifier: pid_t?
  private var targetApplication: NSRunningApplication?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "arcade_clipboard/desktop_bridge",
      binaryMessenger: registrar.messenger)
    let instance = ArcadeDesktopBridgePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
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
    CGEventPost(tap: .cghidEventTap, event: commandDown)
    CGEventPost(tap: .cghidEventTap, event: pasteDown)
    CGEventPost(tap: .cghidEventTap, event: pasteUp)
    CGEventPost(tap: .cghidEventTap, event: commandUp)
    return true
  }
}
