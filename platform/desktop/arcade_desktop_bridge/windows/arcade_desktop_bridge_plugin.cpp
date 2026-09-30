#include "include/arcade_desktop_bridge/arcade_desktop_bridge_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <chrono>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {

class ArcadeDesktopBridgePlugin : public flutter::Plugin {
 public:
  explicit ArcadeDesktopBridgePlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar_->messenger(), "arcade_clipboard/desktop_bridge",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
  }

  ~ArcadeDesktopBridgePlugin() override = default;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "capabilities") {
      flutter::EncodableMap values;
      values[flutter::EncodableValue("paste")] = flutter::EncodableValue(true);
      values[flutter::EncodableValue("focusRestore")] = flutter::EncodableValue(true);
      values[flutter::EncodableValue("detail")] =
          flutter::EncodableValue("Windows native focus restoration and Ctrl+V are available.");
      result->Success(flutter::EncodableValue(values));
      return;
    }
    if (call.method_name() == "rememberTarget") {
      target_ = GetForegroundWindow();
      target_process_id_ = 0;
      target_creation_time_ = {};
      target_identity_valid_ = CaptureTargetIdentity(
          target_, &target_process_id_, &target_creation_time_);
      // Keep the picker available if Windows denies process metadata access.
      // The restore/paste paths then fail closed and leave copy fallback.
      result->Success();
      return;
    }
    if (call.method_name() == "restoreTargetFocus") {
      if (!IsOriginalTarget()) {
        result->Error("target_unavailable", "The previous window could not be verified. Copy the clip and paste manually.");
        return;
      }
      if (!SetForegroundWindow(target_)) {
        result->Error("focus_denied", "Windows did not allow focus to return to the previous app.");
        return;
      }
      result->Success();
      return;
    }
    if (call.method_name() == "pasteKey") {
      if (!IsOriginalTarget()) {
        result->Error("target_unavailable", "The previous window could not be verified. Copy the clip and paste manually.");
        return;
      }
      if (!SetForegroundWindow(target_)) {
        result->Error("focus_denied", "Windows did not allow focus to return to the previous app.");
        return;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(80));
      if (GetForegroundWindow() != target_ || !IsOriginalTarget()) {
        result->Error("focus_denied", "The previous app could not be confirmed, so paste was cancelled.");
        return;
      }
      INPUT inputs[4] = {};
      inputs[0].type = INPUT_KEYBOARD;
      inputs[0].ki.wVk = VK_CONTROL;
      inputs[1].type = INPUT_KEYBOARD;
      inputs[1].ki.wVk = 'V';
      inputs[2].type = INPUT_KEYBOARD;
      inputs[2].ki.wVk = 'V';
      inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
      inputs[3].type = INPUT_KEYBOARD;
      inputs[3].ki.wVk = VK_CONTROL;
      inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
      // Validate the saved HWND, owner PID, and process creation time at the
      // last possible point before injecting. HWND reuse cannot redirect a
      // stale paste to a different process.
      if (GetForegroundWindow() != target_ || !IsOriginalTarget()) {
        result->Error("focus_denied", "The previous app changed before paste, so the keystroke was cancelled.");
        return;
      }
      if (SendInput(4, inputs, sizeof(INPUT)) != 4) {
        INPUT release[2] = {};
        release[0].type = INPUT_KEYBOARD;
        release[0].ki.wVk = 'V';
        release[0].ki.dwFlags = KEYEVENTF_KEYUP;
        release[1].type = INPUT_KEYBOARD;
        release[1].ki.wVk = VK_CONTROL;
        release[1].ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(2, release, sizeof(INPUT));
        result->Error("paste_failed", "Windows could not send the paste shortcut.");
        return;
      }
      result->Success();
      return;
    }
    result->NotImplemented();
  }

  static bool CaptureTargetIdentity(
      HWND window,
      DWORD* process_id,
      FILETIME* creation_time) {
    if (window == nullptr || !IsWindow(window) || process_id == nullptr || creation_time == nullptr) {
      return false;
    }
    DWORD owner_process_id = 0;
    if (GetWindowThreadProcessId(window, &owner_process_id) == 0 || owner_process_id == 0) {
      return false;
    }
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, owner_process_id);
    if (process == nullptr) return false;
    FILETIME process_creation_time = {};
    FILETIME exit_time = {};
    FILETIME kernel_time = {};
    FILETIME user_time = {};
    const BOOL queried = GetProcessTimes(
        process, &process_creation_time, &exit_time, &kernel_time, &user_time);
    CloseHandle(process);
    if (!queried) return false;
    *process_id = owner_process_id;
    *creation_time = process_creation_time;
    return true;
  }

  bool IsOriginalTarget() const {
    if (target_ == nullptr || !target_identity_valid_ || !IsWindow(target_)) return false;
    DWORD owner_process_id = 0;
    if (GetWindowThreadProcessId(target_, &owner_process_id) == 0 ||
        owner_process_id == 0 || owner_process_id != target_process_id_) {
      return false;
    }
    FILETIME creation_time = {};
    DWORD verified_process_id = 0;
    if (!CaptureTargetIdentity(target_, &verified_process_id, &creation_time) ||
        verified_process_id != target_process_id_) {
      return false;
    }
    return creation_time.dwHighDateTime == target_creation_time_.dwHighDateTime &&
           creation_time.dwLowDateTime == target_creation_time_.dwLowDateTime;
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND target_ = nullptr;
  DWORD target_process_id_ = 0;
  FILETIME target_creation_time_ = {};
  bool target_identity_valid_ = false;
};

}  // namespace

void ArcadeDesktopBridgePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  plugin_registrar->AddPlugin(std::make_unique<ArcadeDesktopBridgePlugin>(plugin_registrar));
}
