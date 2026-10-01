#include "include/arcade_desktop_bridge/arcade_desktop_bridge_plugin.h"
#include "clipboard_bridge.h"
#include "lifecycle_bridge.h"

#include <gtk/gtk.h>

#include <cstdio>
#include <functional>
#include <memory>
#include <string>
#include <utility>

namespace {

struct PluginState {
  gatomicrefcount references;
  FlMethodChannel* channel = nullptr;
  std::string target_window;
  LinuxLifecycle* lifecycle = nullptr;
  GtkClipboard* clipboard = nullptr;
  gulong clipboard_listener = 0;
  gint64 clipboard_revision = 0;
  bool capture_enabled = false;
};

PluginState* RefState(PluginState* state) {
  g_atomic_ref_count_inc(&state->references);
  return state;
}

void UnrefState(PluginState* state) {
  if (g_atomic_ref_count_dec(&state->references)) {
    if (state->clipboard != nullptr && state->clipboard_listener != 0) {
      g_signal_handler_disconnect(state->clipboard, state->clipboard_listener);
    }
    DestroyLinuxLifecycle(state->lifecycle);
    g_clear_object(&state->channel);
    delete state;
  }
}

bool IsSafeWindowId(const std::string& value) {
  if (value.empty()) return false;
  const std::size_t first_digit = value.rfind("0x", 0) == 0 || value.rfind("0X", 0) == 0 ? 2 : 0;
  if (first_digit == value.size()) return false;
  for (std::size_t index = first_digit; index < value.size(); ++index) {
    if (!g_ascii_isdigit(value[index]) &&
        !(first_digit == 2 && g_ascii_isxdigit(value[index]))) return false;
  }
  return true;
}

bool IsWayland() {
  const gchar* display = g_getenv("WAYLAND_DISPLAY");
  const gchar* session_type = g_getenv("XDG_SESSION_TYPE");
  return (display != nullptr && *display != '\0') ||
         (session_type != nullptr && g_ascii_strcasecmp(session_type, "wayland") == 0);
}

bool HasProgram(const char* program) {
  gchar* path = g_find_program_in_path(program);
  const bool found = path != nullptr;
  g_free(path);
  return found;
}

struct CommandState {
  GSubprocess* process = nullptr;
  GCancellable* cancellable = nullptr;
  guint timeout_source = 0;
  bool timed_out = false;
  std::function<void(bool, std::string, std::string)> completion;
};

void FinishCommand(GObject* source_object, GAsyncResult* result, gpointer user_data) {
  auto* command = static_cast<CommandState*>(user_data);
  gchar* stdout_text = nullptr;
  gchar* stderr_text = nullptr;
  GError* process_error = nullptr;
  const bool communicated = g_subprocess_communicate_utf8_finish(
      G_SUBPROCESS(source_object), result, &stdout_text, &stderr_text, &process_error);
  const bool successful = communicated && !command->timed_out && g_subprocess_get_successful(command->process);
  std::string output = stdout_text == nullptr ? "" : stdout_text;
  std::string error;
  if (command->timed_out) {
    error = "The desktop integration command timed out.";
  } else if (!successful) {
    if (stderr_text != nullptr && *stderr_text != '\0') error = stderr_text;
    else if (process_error != nullptr) error = process_error->message;
    else error = "The desktop integration command failed.";
  }
  if (command->timeout_source != 0) g_source_remove(command->timeout_source);
  g_free(stdout_text);
  g_free(stderr_text);
  g_clear_error(&process_error);
  g_object_unref(command->process);
  g_object_unref(command->cancellable);
  auto completion = std::move(command->completion);
  delete command;
  completion(successful, std::move(output), std::move(error));
}

gboolean TimeoutCommand(gpointer user_data) {
  auto* command = static_cast<CommandState*>(user_data);
  command->timed_out = true;
  g_subprocess_force_exit(command->process);
  g_cancellable_cancel(command->cancellable);
  command->timeout_source = 0;
  return G_SOURCE_REMOVE;
}

void RunCommandAsync(
    const gchar* const* arguments,
    std::function<void(bool, std::string, std::string)> completion) {
  GError* process_error = nullptr;
  GSubprocess* process = g_subprocess_newv(
      arguments,
      static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE),
      &process_error);
  if (process == nullptr) {
    const std::string message = process_error == nullptr
        ? "Could not start desktop integration command."
        : process_error->message;
    g_clear_error(&process_error);
    completion(false, "", message);
    return;
  }
  auto* command = new CommandState();
  command->process = process;
  command->cancellable = g_cancellable_new();
  command->completion = std::move(completion);
  command->timeout_source = g_timeout_add(2000, TimeoutCommand, command);
  g_subprocess_communicate_utf8_async(
      process, nullptr, command->cancellable, FinishCommand, command);
}

void ReturnError(FlMethodCall* call, const gchar* code, const std::string& message) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new(code, message.c_str(), nullptr));
  fl_method_call_respond(call, response, nullptr);
}

void ReturnSuccess(FlMethodCall* call) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  fl_method_call_respond(call, response, nullptr);
}

void ReturnErrorAndUnref(FlMethodCall* call, const gchar* code, const std::string& message) {
  ReturnError(call, code, message);
  g_object_unref(call);
}

void ReturnSuccessAndUnref(FlMethodCall* call) {
  ReturnSuccess(call);
  g_object_unref(call);
}

void FocusTargetAsync(
    const std::string& target,
    std::function<void(bool, std::string)> completion) {
  const gchar* focus_arguments[] = {"xdotool", "windowactivate", "--sync", target.c_str(), nullptr};
  RunCommandAsync(focus_arguments, [target, completion = std::move(completion)](
      bool focused, std::string, std::string error) mutable {
    if (!focused) {
      completion(false, error);
      return;
    }
    const gchar* verify_arguments[] = {"xdotool", "getwindowfocus", nullptr};
    RunCommandAsync(verify_arguments, [target, completion = std::move(completion)](
        bool verified, std::string output, std::string verify_error) mutable {
      while (!output.empty() && g_ascii_isspace(output.back())) output.pop_back();
      if (!verified || output != target) {
        const std::string message = !verify_error.empty()
            ? verify_error
            : "The previously focused window could not be confirmed; paste was cancelled.";
        completion(false, message);
        return;
      }
      completion(true, "");
    });
  });
}

void PasteIfStillFocusedAsync(
    const std::string& target,
    std::function<void(bool, std::string)> completion) {
  // Recheck at the injection boundary as well as after activation. Each
  // subprocess is independently bounded, so a broken X11 utility cannot hang
  // the method channel indefinitely.
  const gchar* verify_arguments[] = {"xdotool", "getwindowfocus", nullptr};
  RunCommandAsync(verify_arguments, [target, completion = std::move(completion)](
      bool verified, std::string output, std::string verify_error) mutable {
    while (!output.empty() && g_ascii_isspace(output.back())) output.pop_back();
    if (!verified || output != target) {
      const std::string message = !verify_error.empty()
          ? verify_error
          : "The previously focused window changed before paste; paste was cancelled.";
      completion(false, message);
      return;
    }
    const gchar* paste_arguments[] = {
        "xdotool", "key", "--clearmodifiers", "ctrl+v", nullptr};
    RunCommandAsync(paste_arguments, [completion = std::move(completion)](
        bool pasted, std::string, std::string paste_error) mutable {
      completion(pasted, std::move(paste_error));
    });
  });
}

void HandleMethodCall(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  auto* state = static_cast<PluginState*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "clipboardRevision") == 0) {
    g_autoptr(FlValue) value = fl_value_new_int(state->clipboard_revision);
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  if (g_strcmp0(method, "setClipboardCaptureEnabled") == 0) {
    FlValue* arguments = fl_method_call_get_args(call);
    FlValue* enabled = arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP
        ? nullptr : fl_value_lookup_string(arguments, "enabled");
    state->capture_enabled = enabled != nullptr && fl_value_get_type(enabled) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(enabled);
    ReturnSuccess(call);
    return;
  }
  if (HandleClipboardMethod(call) || HandleLifecycleMethod(state->lifecycle, call)) return;
  if (g_strcmp0(method, "capabilities") == 0) {
    const bool wayland = IsWayland();
    const bool x11 = !wayland && g_getenv("DISPLAY") != nullptr;
    const bool paste = x11 && HasProgram("xdotool");
    FlValue* values = fl_value_new_map();
    fl_value_set_string_take(values, "paste", fl_value_new_bool(paste));
    fl_value_set_string_take(values, "focusRestore", fl_value_new_bool(paste));
    const gchar* detail = wayland
        ? "Generic Wayland does not allow app-level focus or key injection. Hyprland has a supported direct integration; other compositors use copy fallback."
        : (x11 && paste
            ? "X11 focus restoration and paste are available through xdotool."
            : (x11
                ? "Install xdotool to enable X11 focus restoration and automatic paste. Copy fallback is available."
                : "No supported X11 display was detected. Copy fallback is available."));
    fl_value_set_string_take(values, "detail", fl_value_new_string(detail));
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(values));
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  if (g_strcmp0(method, "rememberTarget") == 0) {
    if (IsWayland()) {
      // Hyprland targets are handled through its authenticated per-session IPC in Dart.
      ReturnSuccess(call);
      return;
    }
    if (!HasProgram("xdotool")) {
      ReturnError(call, "xdotool_required", "Install xdotool to use automatic paste on X11.");
      return;
    }
    const gchar* arguments[] = {"xdotool", "getwindowfocus", nullptr};
    auto* retained_call = FL_METHOD_CALL(g_object_ref(call));
    auto* retained_state = RefState(state);
    RunCommandAsync(arguments, [retained_call, retained_state](
        bool success, std::string output, std::string error) {
      while (!output.empty() && g_ascii_isspace(output.back())) output.pop_back();
      if (!success) {
        ReturnErrorAndUnref(retained_call, "focus_unavailable", error);
      } else if (!IsSafeWindowId(output)) {
        ReturnErrorAndUnref(
            retained_call, "focus_unavailable",
            "The previously focused X11 window could not be identified.");
      } else {
        retained_state->target_window = output;
        ReturnSuccessAndUnref(retained_call);
      }
      UnrefState(retained_state);
    });
    return;
  }
  if (g_strcmp0(method, "restoreTargetFocus") == 0 || g_strcmp0(method, "pasteKey") == 0) {
    if (IsWayland()) {
      ReturnError(call, "unsupported_wayland", "Use the compositor-supported Hyprland action or copy fallback.");
      return;
    }
    if (!IsSafeWindowId(state->target_window)) {
      ReturnError(call, "target_unavailable", "The previously focused X11 window is no longer available.");
      return;
    }
    if (!HasProgram("xdotool")) {
      ReturnError(call, "xdotool_required", "Install xdotool to use automatic paste on X11.");
      return;
    }
    const std::string target = state->target_window;
    auto* retained_call = FL_METHOD_CALL(g_object_ref(call));
    const bool should_paste = g_strcmp0(method, "pasteKey") == 0;
    FocusTargetAsync(target, [retained_call, should_paste, target](bool focused, std::string error) {
      if (!focused) {
        ReturnErrorAndUnref(retained_call, "focus_denied", error);
        return;
      }
      if (!should_paste) {
        ReturnSuccessAndUnref(retained_call);
        return;
      }
      PasteIfStillFocusedAsync(target, [retained_call](bool pasted, std::string paste_error) {
        if (!pasted) ReturnErrorAndUnref(retained_call, "paste_failed", paste_error);
        else ReturnSuccessAndUnref(retained_call);
      });
    });
    return;
  }
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(call, response, nullptr);
}

void DestroyPlugin(gpointer user_data) {
  auto* state = static_cast<PluginState*>(user_data);
  UnrefState(state);
}

void ClipboardChanged(GtkClipboard*, GdkEventOwnerChange*, gpointer user_data) {
  auto* state = static_cast<PluginState*>(user_data);
  ++state->clipboard_revision;
  if (!state->capture_enabled) return;
  fl_method_channel_invoke_method(state->channel, "clipboardChanged", nullptr, nullptr, nullptr, nullptr);
}

}  // namespace

void arcade_desktop_bridge_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto* state = new PluginState();
  g_atomic_ref_count_init(&state->references);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  state->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "arcade_clipboard/desktop_bridge",
      FL_METHOD_CODEC(codec));
  state->lifecycle = CreateLinuxLifecycle(registrar, state->channel);
  state->clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  state->clipboard_listener = g_signal_connect(state->clipboard, "owner-change", G_CALLBACK(ClipboardChanged), state);
  fl_method_channel_set_method_call_handler(
      state->channel, HandleMethodCall, state, DestroyPlugin);
}
