#include "windows_support.h"

#include <gdiplus.h>
#include <objidl.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace {

using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
constexpr std::size_t kMaximumBytes = 32 * 1024 * 1024;
constexpr UINT kTrayMessage = WM_APP + 73;
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"ArcadeClipboard";

const Value* Lookup(const Map& map, const char* key) {
  auto found = map.find(Value(key));
  return found == map.end() ? nullptr : &found->second;
}

std::wstring Wide(const std::string& value) {
  if (value.empty() || value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (length == 0) return {};
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length);
  return result;
}

std::string Utf8(const wchar_t* value, std::size_t length) {
  if (length == 0 || length > static_cast<std::size_t>(std::numeric_limits<int>::max())) return {};
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, static_cast<int>(length), nullptr, 0, nullptr, nullptr);
  if (count == 0) return {};
  std::string result(count, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, static_cast<int>(length), result.data(), count, nullptr, nullptr);
  return result;
}

std::vector<uint8_t> ClipboardBytes(UINT format) {
  HANDLE handle = GetClipboardData(format);
  if (handle == nullptr) return {};
  const SIZE_T length = GlobalSize(handle);
  if (length == 0 || length > kMaximumBytes) return {};
  const auto* contents = static_cast<const uint8_t*>(GlobalLock(handle));
  if (contents == nullptr) return {};
  std::vector<uint8_t> bytes(contents, contents + length);
  GlobalUnlock(handle);
  return bytes;
}

bool Store(UINT format, const std::vector<uint8_t>& bytes) {
  if (bytes.empty() || bytes.size() > kMaximumBytes) return false;
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (memory == nullptr) return false;
  void* target = GlobalLock(memory);
  if (target == nullptr) { GlobalFree(memory); return false; }
  std::memcpy(target, bytes.data(), bytes.size());
  GlobalUnlock(memory);
  if (SetClipboardData(format, memory) == nullptr) { GlobalFree(memory); return false; }
  return true;
}

std::size_t HtmlOffset(const std::string& html, const char* key) {
  const std::size_t position = html.find(key);
  if (position == std::string::npos || position > 4096) return std::string::npos;
  std::size_t offset = position + std::strlen(key);
  while (offset < html.size() && html[offset] == ' ') ++offset;
  std::size_t value = 0;
  std::size_t count = 0;
  while (offset < html.size() && html[offset] >= '0' && html[offset] <= '9' && count++ < 12) {
    if (value > kMaximumBytes / 10) return std::string::npos;
    value = value * 10 + static_cast<std::size_t>(html[offset++] - '0');
  }
  return count == 0 || value > html.size() ? std::string::npos : value;
}

std::vector<uint8_t> HtmlFragment(const std::vector<uint8_t>& raw) {
  const std::string html(raw.begin(), raw.end());
  const auto start = HtmlOffset(html, "StartFragment:");
  const auto end = HtmlOffset(html, "EndFragment:");
  if (start == std::string::npos || end == std::string::npos || start >= end) return {};
  return std::vector<uint8_t>(raw.begin() + start, raw.begin() + end);
}

std::vector<uint8_t> HtmlClipboard(const std::vector<uint8_t>& fragment) {
  const std::string header = "Version:1.0\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n";
  const std::string prefix = "<html><body><!--StartFragment-->";
  const std::string suffix = "<!--EndFragment--></body></html>";
  const auto html_start = header.size();
  const auto fragment_start = html_start + prefix.size();
  const auto fragment_end = fragment_start + fragment.size();
  const auto html_end = fragment_end + suffix.size();
  if (html_end + 1 > kMaximumBytes) return {};
  char offsets[256] = {};
  std::snprintf(offsets, sizeof(offsets), "Version:1.0\r\nStartHTML:%010llu\r\nEndHTML:%010llu\r\nStartFragment:%010llu\r\nEndFragment:%010llu\r\n",
      static_cast<unsigned long long>(html_start), static_cast<unsigned long long>(html_end),
      static_cast<unsigned long long>(fragment_start), static_cast<unsigned long long>(fragment_end));
  std::string html = std::string(offsets) + prefix + std::string(fragment.begin(), fragment.end()) + suffix;
  std::vector<uint8_t> bytes(html.begin(), html.end());
  bytes.push_back(0);
  return bytes;
}

std::vector<uint8_t> DibToPng(const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) return {};
  BITMAPINFOHEADER header = {};
  std::memcpy(&header, dib.data(), sizeof(header));
  if (header.biSize < sizeof(header) || header.biSize > dib.size() || header.biWidth <= 0 ||
      header.biHeight == 0 || header.biHeight == std::numeric_limits<LONG>::min() || header.biPlanes != 1 ||
      (header.biBitCount != 8 && header.biBitCount != 16 && header.biBitCount != 24 && header.biBitCount != 32) ||
      (header.biCompression != BI_RGB && header.biCompression != BI_BITFIELDS)) return {};
  const auto width = static_cast<std::size_t>(header.biWidth);
  const auto height = static_cast<std::size_t>(header.biHeight < 0 ? -header.biHeight : header.biHeight);
  if (width > 16384 || height > 16384 || width > 16 * 1024 * 1024 / height) return {};
  const std::size_t palette = header.biClrUsed != 0 ? header.biClrUsed : (header.biBitCount == 8 ? 256 : 0);
  if (palette > 256) return {};
  const std::size_t masks = header.biSize == sizeof(BITMAPINFOHEADER) && header.biCompression == BI_BITFIELDS ? 12 : 0;
  const std::size_t pixels = header.biSize + masks + palette * sizeof(RGBQUAD);
  const std::size_t stride = ((width * header.biBitCount + 31) / 32) * 4;
  if (pixels > dib.size() || height > (dib.size() - pixels) / stride) return {};
  Gdiplus::Bitmap bitmap(reinterpret_cast<const BITMAPINFO*>(dib.data()), const_cast<uint8_t*>(dib.data() + pixels));
  if (bitmap.GetLastStatus() != Gdiplus::Ok) return {};
  IStream* stream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return {};
  const CLSID png_encoder = {0x557cf406, 0x1a04, 0x11d3, {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
  std::vector<uint8_t> bytes;
  if (bitmap.Save(stream, &png_encoder, nullptr) == Gdiplus::Ok) {
    STATSTG stats = {};
    if (SUCCEEDED(stream->Stat(&stats, STATFLAG_NONAME)) && stats.cbSize.QuadPart > 0 && stats.cbSize.QuadPart <= kMaximumBytes) {
      bytes.resize(static_cast<std::size_t>(stats.cbSize.QuadPart));
      LARGE_INTEGER start = {};
      ULONG read = 0;
      if (FAILED(stream->Seek(start, STREAM_SEEK_SET, nullptr)) || FAILED(stream->Read(bytes.data(), static_cast<ULONG>(bytes.size()), &read)) || read != bytes.size()) bytes.clear();
    }
  }
  stream->Release();
  return bytes;
}

std::vector<uint8_t> ImageToDib(const std::vector<uint8_t>& bytes) {
  if (bytes.empty() || bytes.size() > kMaximumBytes) return {};
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (memory == nullptr) return {};
  void* contents = GlobalLock(memory);
  if (contents == nullptr) { GlobalFree(memory); return {}; }
  std::memcpy(contents, bytes.data(), bytes.size());
  GlobalUnlock(memory);
  IStream* stream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(memory, TRUE, &stream))) { GlobalFree(memory); return {}; }
  std::vector<uint8_t> dib;
  {
    Gdiplus::Bitmap bitmap(stream, FALSE);
    const UINT width = bitmap.GetWidth();
    const UINT height = bitmap.GetHeight();
    if (bitmap.GetLastStatus() == Gdiplus::Ok && width > 0 && height > 0 && width <= 16384 && height <= 16384 &&
        static_cast<std::size_t>(width) <= (kMaximumBytes - sizeof(BITMAPV5HEADER)) / 4 / height) {
      Gdiplus::BitmapData pixels = {};
      Gdiplus::Rect rectangle(0, 0, static_cast<INT>(width), static_cast<INT>(height));
      if (bitmap.LockBits(&rectangle, Gdiplus::ImageLockModeRead, PixelFormat32bppARGB, &pixels) == Gdiplus::Ok) {
        const std::size_t stride = static_cast<std::size_t>(width) * 4;
        dib.resize(sizeof(BITMAPV5HEADER) + stride * height);
        BITMAPV5HEADER header = {};
        header.bV5Size = sizeof(header);
        header.bV5Width = static_cast<LONG>(width);
        header.bV5Height = -static_cast<LONG>(height);
        header.bV5Planes = 1;
        header.bV5BitCount = 32;
        header.bV5Compression = BI_BITFIELDS;
        header.bV5SizeImage = static_cast<DWORD>(stride * height);
        header.bV5RedMask = 0x00ff0000;
        header.bV5GreenMask = 0x0000ff00;
        header.bV5BlueMask = 0x000000ff;
        header.bV5AlphaMask = 0xff000000;
        header.bV5CSType = LCS_sRGB;
        std::memcpy(dib.data(), &header, sizeof(header));
        for (UINT row = 0; row < height; ++row) {
          std::memcpy(dib.data() + sizeof(header) + row * stride,
              static_cast<uint8_t*>(pixels.Scan0) + static_cast<std::ptrdiff_t>(row) * pixels.Stride, stride);
        }
        bitmap.UnlockBits(&pixels);
      }
    }
  }
  stream->Release();
  return dib;
}

void AppendFormat(List* formats, const char* mime, std::vector<uint8_t> bytes) {
  if (bytes.empty()) return;
  Map value;
  value[Value("mimeType")] = Value(mime);
  value[Value("bytes")] = Value(std::move(bytes));
  formats->push_back(Value(std::move(value)));
}

Value ReadClipboard(HWND window) {
  List formats;
  List files;
  bool sensitive = false;
  std::vector<uint8_t> image;
  std::vector<uint8_t> dib;
  if (OpenClipboard(window)) {
    sensitive = IsClipboardFormatAvailable(RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing")) != FALSE;
    const auto history = ClipboardBytes(RegisterClipboardFormatW(L"CanIncludeInClipboardHistory"));
    if (history.size() >= sizeof(DWORD)) {
      DWORD allowed = 1;
      std::memcpy(&allowed, history.data(), sizeof(allowed));
      sensitive = sensitive || allowed == 0;
    }
    if (!sensitive) {
      auto text = ClipboardBytes(CF_UNICODETEXT);
      if (text.size() >= sizeof(wchar_t)) {
        const auto* wide = reinterpret_cast<const wchar_t*>(text.data());
        const std::size_t limit = text.size() / sizeof(wchar_t);
        std::size_t length = 0;
        while (length < limit && wide[length] != L'\0') ++length;
        const std::string utf8 = Utf8(wide, length);
        AppendFormat(&formats, "text/plain", std::vector<uint8_t>(utf8.begin(), utf8.end()));
      }
      AppendFormat(&formats, "text/html", HtmlFragment(ClipboardBytes(RegisterClipboardFormatW(L"HTML Format"))));
      auto rtf = ClipboardBytes(RegisterClipboardFormatW(L"Rich Text Format"));
      while (!rtf.empty() && rtf.back() == 0) rtf.pop_back();
      AppendFormat(&formats, "text/rtf", std::move(rtf));
      image = ClipboardBytes(RegisterClipboardFormatW(L"PNG"));
      if (image.empty()) {
        dib = ClipboardBytes(CF_DIBV5);
        if (dib.empty()) dib = ClipboardBytes(CF_DIB);
      }
      HDROP drop = static_cast<HDROP>(GetClipboardData(CF_HDROP));
      if (drop != nullptr) {
        const UINT count = (std::min)(DragQueryFileW(drop, 0xffffffff, nullptr, 0), 256U);
        for (UINT index = 0; index < count; ++index) {
          const UINT length = DragQueryFileW(drop, index, nullptr, 0);
          if (length == 0 || length > 32767) continue;
          std::wstring path(length + 1, L'\0');
          if (DragQueryFileW(drop, index, path.data(), length + 1) == length) files.push_back(Value(Utf8(path.data(), length)));
        }
      }
    }
    CloseClipboard();
  }
  if (image.empty() && !dib.empty()) image = DibToPng(dib);
  AppendFormat(&formats, "image/png", std::move(image));
  Map snapshot;
  snapshot[Value("formats")] = Value(std::move(formats));
  snapshot[Value("files")] = Value(std::move(files));
  snapshot[Value("sensitive")] = Value(sensitive);
  return Value(std::move(snapshot));
}

bool WriteClipboard(HWND window, const Map& arguments) {
  std::vector<std::pair<UINT, std::vector<uint8_t>>> prepared;
  std::size_t total = 0;
  const Value* formats_value = Lookup(arguments, "formats");
  const auto* formats = formats_value == nullptr ? nullptr : std::get_if<List>(formats_value);
  if (formats != nullptr && formats->size() <= 8) {
    for (const auto& value : *formats) {
      const auto* format = std::get_if<Map>(&value);
      if (format == nullptr) continue;
      const Value* mime_value = Lookup(*format, "mimeType");
      const Value* bytes_value = Lookup(*format, "bytes");
      const auto* mime = mime_value == nullptr ? nullptr : std::get_if<std::string>(mime_value);
      const auto* bytes = bytes_value == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(bytes_value);
      if (mime == nullptr || bytes == nullptr || bytes->empty() || bytes->size() > kMaximumBytes - total) continue;
      total += bytes->size();
      if (*mime == "text/plain") {
        const auto wide = Wide(std::string(bytes->begin(), bytes->end()));
        if (wide.empty()) continue;
        std::vector<uint8_t> encoded((wide.size() + 1) * sizeof(wchar_t), 0);
        std::memcpy(encoded.data(), wide.data(), wide.size() * sizeof(wchar_t));
        prepared.emplace_back(CF_UNICODETEXT, std::move(encoded));
      } else if (*mime == "text/html") {
        prepared.emplace_back(RegisterClipboardFormatW(L"HTML Format"), HtmlClipboard(*bytes));
      } else if (*mime == "text/rtf") {
        auto encoded = *bytes;
        encoded.push_back(0);
        prepared.emplace_back(RegisterClipboardFormatW(L"Rich Text Format"), std::move(encoded));
      } else if (*mime == "image/png" || *mime == "image/jpeg") {
        if (*mime == "image/png") prepared.emplace_back(RegisterClipboardFormatW(L"PNG"), *bytes);
        auto dib = ImageToDib(*bytes);
        if (!dib.empty()) prepared.emplace_back(CF_DIBV5, std::move(dib));
      }
    }
  }
  const Value* files_value = Lookup(arguments, "files");
  const auto* files = files_value == nullptr ? nullptr : std::get_if<List>(files_value);
  if (files != nullptr && files->size() <= 256) {
    std::wstring paths;
    for (const auto& file : *files) {
      const auto* path = std::get_if<std::string>(&file);
      if (path == nullptr) continue;
      const auto wide = Wide(*path);
      const DWORD attributes = GetFileAttributesW(wide.c_str());
      if (wide.empty() || wide.size() > 32767 || attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
      paths += wide;
      paths.push_back(L'\0');
    }
    if (!paths.empty()) {
      paths.push_back(L'\0');
      DROPFILES header = {};
      header.pFiles = sizeof(header);
      header.fWide = TRUE;
      std::vector<uint8_t> bytes(sizeof(header) + paths.size() * sizeof(wchar_t));
      std::memcpy(bytes.data(), &header, sizeof(header));
      std::memcpy(bytes.data() + sizeof(header), paths.data(), paths.size() * sizeof(wchar_t));
      prepared.emplace_back(CF_HDROP, std::move(bytes));
    }
  }
  if (prepared.empty() || !OpenClipboard(window)) return false;
  bool success = EmptyClipboard() != FALSE;
  if (success) {
    bool stored = false;
    for (const auto& representation : prepared) stored = Store(representation.first, representation.second) || stored;
    success = stored;
  }
  CloseClipboard();
  return success;
}

bool StartupEnabled() {
  DWORD length = 0;
  return RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ, nullptr, nullptr, &length) == ERROR_SUCCESS && length > sizeof(wchar_t);
}

bool SetStartup(bool enabled) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  LSTATUS status;
  if (!enabled) {
    status = RegDeleteValueW(key, kRunValue);
    if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  } else {
    std::wstring executable(32768, L'\0');
    const DWORD length = GetModuleFileNameW(nullptr, executable.data(), static_cast<DWORD>(executable.size()));
    executable.resize(length);
    std::wstring temporary(32768, L'\0');
    const DWORD temporary_length = GetTempPathW(static_cast<DWORD>(temporary.size()), temporary.data());
    temporary.resize(temporary_length);
    if (length == 0 || length >= 32768 || (!temporary.empty() && executable.size() >= temporary.size() &&
        _wcsnicmp(executable.c_str(), temporary.c_str(), temporary.size()) == 0)) { RegCloseKey(key); return false; }
    const std::wstring command = L"\"" + executable + L"\" --background";
    status = RegSetValueExW(key, kRunValue, 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  }
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

}  // namespace

WindowsSupport::WindowsSupport(flutter::PluginRegistrarWindows* registrar,
    flutter::MethodChannel<Value>* channel) : registrar_(registrar), channel_(channel) {
  window_ = registrar_->GetView() == nullptr ? nullptr : GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
  Gdiplus::GdiplusStartupInput options;
  Gdiplus::GdiplusStartup(&graphics_token_, &options, nullptr);
  delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate([this](HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    return WindowProc(window, message, wparam, lparam);
  });
  if (window_ != nullptr) AddClipboardFormatListener(window_);
}

WindowsSupport::~WindowsSupport() {
  if (window_ != nullptr) RemoveClipboardFormatListener(window_);
  SetBackground(false);
  if (delegate_id_ >= 0) registrar_->UnregisterTopLevelWindowProcDelegate(delegate_id_);
  if (graphics_token_ != 0) Gdiplus::GdiplusShutdown(graphics_token_);
}

bool WindowsSupport::SetBackground(bool enabled) {
  if (enabled == background_) return true;
  if (!enabled) {
    Shell_NotifyIconW(NIM_DELETE, &tray_);
    background_ = false;
    return true;
  }
  if (window_ == nullptr || !IsWindow(window_)) return false;
  tray_ = {};
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = window_;
  tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = reinterpret_cast<HICON>(SendMessageW(window_, WM_GETICON, ICON_SMALL, 0));
  if (tray_.hIcon == nullptr) tray_.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  wcscpy_s(tray_.szTip, L"Arcade Clipboard");
  if (!Shell_NotifyIconW(NIM_ADD, &tray_)) return false;
  tray_.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &tray_);
  background_ = true;
  return true;
}

std::optional<LRESULT> WindowsSupport::WindowProc(HWND window, UINT message, WPARAM, LPARAM lparam) {
  if (window != window_) return std::nullopt;
  if (message == WM_CLIPBOARDUPDATE) {
    if (capture_enabled_) channel_->InvokeMethod("clipboardChanged", nullptr);
    return std::nullopt;
  }
  static const UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  if (message == taskbar_created && background_) {
    background_ = false;
    if (!SetBackground(true)) channel_->InvokeMethod("showMainWindow", nullptr);
    return std::nullopt;
  }
  if (message == WM_CLOSE && background_) { ShowWindow(window, SW_HIDE); return 0; }
  if (message != kTrayMessage) return std::nullopt;
  const UINT event = LOWORD(lparam);
  if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONUP || event == WM_LBUTTONDBLCLK) {
    // A click opens Settings, as in every Arcade app.
    channel_->InvokeMethod("showSettings", nullptr);
  } else if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) {
    POINT point = {};
    GetCursorPos(&point);
    HMENU menu = CreatePopupMenu();
    // The tray menu every Arcade app has.
    AppendMenuW(menu, MF_STRING, 1, L"Open Clipboard");
    AppendMenuW(menu, MF_STRING, 3, L"Open Settings");
    AppendMenuW(menu, MF_STRING, 4, L"Restart Arcade Clipboard");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 2, L"Quit Arcade Clipboard");
    SetForegroundWindow(window);
    const UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, point.x, point.y, 0, window, nullptr);
    DestroyMenu(menu);
    if (selected == 1) channel_->InvokeMethod("showMainWindow", nullptr);
    if (selected == 2) channel_->InvokeMethod("quitRequested", nullptr);
    if (selected == 3) channel_->InvokeMethod("showSettings", nullptr);
    if (selected == 4) channel_->InvokeMethod("restartRequested", nullptr);
    PostMessageW(window, WM_NULL, 0, 0);
  }
  return 0;
}

bool WindowsSupport::Handle(const flutter::MethodCall<Value>& call,
    std::unique_ptr<flutter::MethodResult<Value>>& result) {
  if (call.method_name() == "clipboardRevision") {
    result->Success(Value(static_cast<int64_t>(GetClipboardSequenceNumber())));
    return true;
  }
  if (call.method_name() == "readClipboard") {
    result->Success(ReadClipboard(window_));
    return true;
  }
  const auto* arguments = call.arguments() == nullptr ? nullptr : std::get_if<Map>(call.arguments());
  if (call.method_name() == "writeClipboard") {
    if (arguments == nullptr || !WriteClipboard(window_, *arguments)) result->Error("clipboard_unavailable", "Windows did not accept this clipboard item. Try copying it again.");
    else result->Success();
    return true;
  }
  if (call.method_name() == "launchAtLoginEnabled") {
    result->Success(Value(StartupEnabled()));
    return true;
  }
  if (call.method_name() == "setClipboardCaptureEnabled") {
    const Value* value = arguments == nullptr ? nullptr : Lookup(*arguments, "enabled");
    const auto* boolean = value == nullptr ? nullptr : std::get_if<bool>(value);
    capture_enabled_ = boolean != nullptr && *boolean;
    result->Success();
    return true;
  }
  if (call.method_name() == "setLaunchAtLogin" || call.method_name() == "setBackgroundEnabled") {
    const Value* value = arguments == nullptr ? nullptr : Lookup(*arguments, "enabled");
    const auto* boolean = value == nullptr ? nullptr : std::get_if<bool>(value);
    const bool enabled = boolean != nullptr && *boolean;
    const bool success = call.method_name() == "setLaunchAtLogin" ? SetStartup(enabled) : SetBackground(enabled);
    if (success) result->Success();
    else result->Error("desktop_lifecycle_unavailable", "The desktop setting could not be applied. Install the app in a persistent folder and retry.");
    return true;
  }
  return false;
}
