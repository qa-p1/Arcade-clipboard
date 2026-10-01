#ifndef ARCADE_WINDOWS_SUPPORT_H_
#define ARCADE_WINDOWS_SUPPORT_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <optional>

class WindowsSupport {
 public:
  WindowsSupport(flutter::PluginRegistrarWindows* registrar,
      flutter::MethodChannel<flutter::EncodableValue>* channel);
  ~WindowsSupport();
  bool Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);

 private:
  std::optional<LRESULT> WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  bool SetBackground(bool enabled);
  flutter::PluginRegistrarWindows* registrar_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  int delegate_id_ = -1;
  HWND window_ = nullptr;
  bool background_ = false;
  bool capture_enabled_ = false;
  NOTIFYICONDATAW tray_ = {};
  ULONG_PTR graphics_token_ = 0;
};

#endif
