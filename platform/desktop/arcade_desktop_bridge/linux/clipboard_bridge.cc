#include "clipboard_bridge.h"

#include <gtk/gtk.h>

#include <algorithm>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr std::size_t kMaximumClipboardBytes = 32 * 1024 * 1024;
constexpr std::size_t kMaximumFiles = 256;

struct Format {
  std::string mime;
  std::vector<uint8_t> bytes;
};

void Respond(FlMethodCall* call, FlValue* value) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}

void Fail(FlMethodCall* call, const char* message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new("clipboard_unavailable", message, nullptr));
  fl_method_call_respond(call, response, nullptr);
}

bool Wayland() {
  const char* name = g_getenv("WAYLAND_DISPLAY");
  return name != nullptr && *name != '\0';
}

bool Supported(const std::string& mime) {
  return mime == "text/plain" || mime == "text/html" || mime == "text/rtf" ||
         mime == "image/png" || mime == "image/jpeg" || mime == "text/uri-list";
}

bool SensitiveType(const std::string& mime) {
  return mime == "x-kde-passwordManagerHint" ||
         mime == "application/x-keepassxc-clipboard" ||
         mime == "application/x-kde-passwordmanagerhint";
}

FlValue* Snapshot(const std::vector<Format>& formats, bool sensitive) {
  FlValue* result = fl_value_new_map();
  FlValue* values = fl_value_new_list();
  FlValue* files = fl_value_new_list();
  for (const auto& format : formats) {
    if (format.mime == "text/uri-list") {
      const std::string text(format.bytes.begin(), format.bytes.end());
      gchar** uris = g_uri_list_extract_uris(text.c_str());
      for (std::size_t index = 0; uris != nullptr && uris[index] != nullptr && index < kMaximumFiles; ++index) {
        GError* error = nullptr;
        gchar* hostname = nullptr;
        gchar* path = g_filename_from_uri(uris[index], &hostname, &error);
        if (path != nullptr && (hostname == nullptr || *hostname == '\0' || g_ascii_strcasecmp(hostname, "localhost") == 0)) {
          fl_value_append_take(files, fl_value_new_string(path));
        }
        g_free(path);
        g_free(hostname);
        g_clear_error(&error);
      }
      g_strfreev(uris);
      // Local paths are imported as file bytes by the caller, never broadcast
      // as machine-specific URI representations.
      continue;
    }
    FlValue* value = fl_value_new_map();
    fl_value_set_string_take(value, "mimeType", fl_value_new_string(format.mime.c_str()));
    fl_value_set_string_take(value, "bytes", fl_value_new_uint8_list(format.bytes.data(), format.bytes.size()));
    fl_value_append_take(values, value);
  }
  fl_value_set_string_take(result, "formats", values);
  fl_value_set_string_take(result, "files", files);
  fl_value_set_string_take(result, "sensitive", fl_value_new_bool(sensitive));
  return result;
}

struct ProcessRead {
  GSubprocess* process = nullptr;
  GCancellable* cancellable = nullptr;
  guint timer = 0;
  std::size_t maximum = 0;
  bool failed = false;
  std::vector<uint8_t> output;
  std::function<void(bool, std::vector<uint8_t>)> completion;
};

void CompleteRead(ProcessRead* read, bool success) {
  if (read->timer != 0) g_source_remove(read->timer);
  auto completion = std::move(read->completion);
  auto output = std::move(read->output);
  g_clear_object(&read->process);
  g_clear_object(&read->cancellable);
  delete read;
  completion(success, std::move(output));
}

void ProcessExited(GObject* object, GAsyncResult* result, gpointer data) {
  auto* read = static_cast<ProcessRead*>(data);
  GError* error = nullptr;
  const bool waited = g_subprocess_wait_finish(G_SUBPROCESS(object), result, &error);
  const bool success = waited && !read->failed && g_subprocess_get_successful(read->process);
  g_clear_error(&error);
  CompleteRead(read, success);
}

void ReadNext(ProcessRead* read);

void ProcessBytes(GObject* object, GAsyncResult* result, gpointer data) {
  auto* read = static_cast<ProcessRead*>(data);
  GError* error = nullptr;
  GBytes* bytes = g_input_stream_read_bytes_finish(G_INPUT_STREAM(object), result, &error);
  gsize length = 0;
  const auto* contents = bytes == nullptr ? nullptr : static_cast<const uint8_t*>(g_bytes_get_data(bytes, &length));
  if (error != nullptr || read->failed || length > read->maximum - read->output.size()) {
    read->failed = true;
    g_subprocess_force_exit(read->process);
  } else if (length != 0) {
    read->output.insert(read->output.end(), contents, contents + length);
  }
  g_clear_error(&error);
  if (bytes != nullptr) g_bytes_unref(bytes);
  if (read->failed || length == 0) {
    g_subprocess_wait_async(read->process, nullptr, ProcessExited, read);
  } else {
    ReadNext(read);
  }
}

void ReadNext(ProcessRead* read) {
  g_input_stream_read_bytes_async(g_subprocess_get_stdout_pipe(read->process), 65536,
      G_PRIORITY_DEFAULT, read->cancellable, ProcessBytes, read);
}

gboolean ReadTimedOut(gpointer data) {
  auto* read = static_cast<ProcessRead*>(data);
  read->timer = 0;
  read->failed = true;
  g_subprocess_force_exit(read->process);
  g_cancellable_cancel(read->cancellable);
  return G_SOURCE_REMOVE;
}

void ReadCommand(const std::vector<std::string>& args, std::size_t maximum,
    std::function<void(bool, std::vector<uint8_t>)> completion) {
  std::vector<const gchar*> values;
  for (const auto& argument : args) values.push_back(argument.c_str());
  values.push_back(nullptr);
  GError* error = nullptr;
  GSubprocess* process = g_subprocess_newv(values.data(),
      static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE), &error);
  if (process == nullptr) {
    g_clear_error(&error);
    completion(false, {});
    return;
  }
  auto* read = new ProcessRead();
  read->process = process;
  read->cancellable = g_cancellable_new();
  read->maximum = maximum;
  read->completion = std::move(completion);
  read->timer = g_timeout_add(2500, ReadTimedOut, read);
  ReadNext(read);
}

struct ReadSnapshot {
  FlMethodCall* call = nullptr;
  std::vector<std::pair<std::string, std::string>> targets;
  std::vector<Format> formats;
  std::size_t index = 0;
  std::size_t total = 0;
  bool sensitive = false;
  ~ReadSnapshot() { g_clear_object(&call); }
};

void ReturnSnapshot(const std::shared_ptr<ReadSnapshot>& read) {
  g_autoptr(FlValue) result = Snapshot(read->formats, read->sensitive);
  Respond(read->call, result);
}

void ReadWaylandNext(const std::shared_ptr<ReadSnapshot>& read) {
  if (read->index == read->targets.size()) {
    ReturnSnapshot(read);
    return;
  }
  const auto target = read->targets[read->index++];
  if (target.second == "image/jpeg" && std::any_of(read->formats.begin(), read->formats.end(), [](const auto& format) {
      return format.mime == "image/png";
  })) {
    ReadWaylandNext(read);
    return;
  }
  ReadCommand({"wl-paste", "--no-newline", "--type", target.first}, kMaximumClipboardBytes - read->total,
      [read, target](bool success, std::vector<uint8_t> bytes) {
        if (success && !bytes.empty()) {
          read->total += bytes.size();
          read->formats.push_back({target.second, std::move(bytes)});
        }
        ReadWaylandNext(read);
      });
}

void AddTargets(const std::shared_ptr<ReadSnapshot>& read, const std::vector<std::string>& names) {
  for (const auto& name : names) {
    if (SensitiveType(name)) read->sensitive = true;
  }
  if (read->sensitive) return;
  // Prefer explicitly encoded UTF-8 and PNG. Duplicate text/image targets
  // are alternative encodings of one representation, not separate clips.
  const std::vector<std::pair<std::string, std::string>> candidates = {
      {"text/plain;charset=utf-8", "text/plain"}, {"UTF8_STRING", "text/plain"},
      {"text/plain", "text/plain"}, {"text/html", "text/html"}, {"text/rtf", "text/rtf"},
      {"image/png", "image/png"}, {"image/jpeg", "image/jpeg"}, {"text/uri-list", "text/uri-list"}};
  for (const auto& candidate : candidates) {
    if (std::find(names.begin(), names.end(), candidate.first) == names.end()) continue;
    if (std::any_of(read->targets.begin(), read->targets.end(), [&](const auto& existing) {
      return existing.second == candidate.second;
    })) continue;
    read->targets.push_back(candidate);
  }
}

void ReadGtkNext(const std::shared_ptr<ReadSnapshot>& read);

void GtkContents(GtkClipboard*, GtkSelectionData* selection, gpointer data) {
  std::unique_ptr<std::shared_ptr<ReadSnapshot>> owned(static_cast<std::shared_ptr<ReadSnapshot>*>(data));
  auto read = *owned;
  const gint length = gtk_selection_data_get_length(selection);
  const auto* bytes = gtk_selection_data_get_data(selection);
  if (length > 0 && bytes != nullptr && static_cast<std::size_t>(length) <= kMaximumClipboardBytes - read->total) {
    read->formats.push_back({read->targets[read->index - 1].second, std::vector<uint8_t>(bytes, bytes + length)});
    read->total += static_cast<std::size_t>(length);
  }
  ReadGtkNext(read);
}

void ReadGtkNext(const std::shared_ptr<ReadSnapshot>& read) {
  if (read->index == read->targets.size()) {
    ReturnSnapshot(read);
    return;
  }
  const auto target = read->targets[read->index++];
  if (target.second == "image/jpeg" && std::any_of(read->formats.begin(), read->formats.end(), [](const auto& format) {
      return format.mime == "image/png";
  })) {
    ReadGtkNext(read);
    return;
  }
  gtk_clipboard_request_contents(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD),
      gdk_atom_intern(target.first.c_str(), FALSE), GtkContents,
      new std::shared_ptr<ReadSnapshot>(read));
}

void GtkTargets(GtkClipboard*, GdkAtom* atoms, gint count, gpointer data) {
  std::unique_ptr<std::shared_ptr<ReadSnapshot>> owned(static_cast<std::shared_ptr<ReadSnapshot>*>(data));
  auto read = *owned;
  std::vector<std::string> names;
  for (gint index = 0; index < count && index < 256; ++index) {
    gchar* name = gdk_atom_name(atoms[index]);
    if (name != nullptr) names.emplace_back(name);
    g_free(name);
  }
  AddTargets(read, names);
  ReadGtkNext(read);
}

struct ClipboardOwner {
  std::vector<Format> formats;
};

void ProvideClipboard(GtkClipboard*, GtkSelectionData* selection, guint info, gpointer data) {
  auto* owner = static_cast<ClipboardOwner*>(data);
  if (info >= owner->formats.size()) return;
  const auto& format = owner->formats[info];
  gtk_selection_data_set(selection, gtk_selection_data_get_target(selection), 8,
      format.bytes.data(), static_cast<gint>(format.bytes.size()));
}

void ClearClipboard(GtkClipboard*, gpointer data) { delete static_cast<ClipboardOwner*>(data); }

bool WriteClipboard(FlMethodCall* call) {
  FlValue* arguments = fl_method_call_get_args(call);
  if (arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    Fail(call, "Clipboard formats are missing.");
    return true;
  }
  auto owner = std::make_unique<ClipboardOwner>();
  std::size_t total = 0;
  FlValue* formats = fl_value_lookup_string(arguments, "formats");
  if (formats != nullptr && fl_value_get_type(formats) == FL_VALUE_TYPE_LIST && fl_value_get_length(formats) <= 8) {
    for (std::size_t index = 0; index < fl_value_get_length(formats); ++index) {
      FlValue* value = fl_value_get_list_value(formats, index);
      if (fl_value_get_type(value) != FL_VALUE_TYPE_MAP) continue;
      FlValue* mime = fl_value_lookup_string(value, "mimeType");
      FlValue* bytes = fl_value_lookup_string(value, "bytes");
      if (mime == nullptr || bytes == nullptr || fl_value_get_type(mime) != FL_VALUE_TYPE_STRING ||
          fl_value_get_type(bytes) != FL_VALUE_TYPE_UINT8_LIST) continue;
      const std::string type = fl_value_get_string(mime);
      const std::size_t length = fl_value_get_length(bytes);
      if (!Supported(type) || length == 0 || length > kMaximumClipboardBytes - total) continue;
      const auto* contents = fl_value_get_uint8_list(bytes);
      owner->formats.push_back({type, std::vector<uint8_t>(contents, contents + length)});
      total += length;
    }
  }
  FlValue* files = fl_value_lookup_string(arguments, "files");
  if (files != nullptr && fl_value_get_type(files) == FL_VALUE_TYPE_LIST && fl_value_get_length(files) <= kMaximumFiles) {
    std::string uris;
    for (std::size_t index = 0; index < fl_value_get_length(files); ++index) {
      FlValue* value = fl_value_get_list_value(files, index);
      if (fl_value_get_type(value) != FL_VALUE_TYPE_STRING) continue;
      const gchar* path = fl_value_get_string(value);
      if (!g_path_is_absolute(path) || !g_file_test(path, G_FILE_TEST_IS_REGULAR)) continue;
      gchar* uri = g_filename_to_uri(path, nullptr, nullptr);
      if (uri != nullptr) uris += std::string(uri) + "\r\n";
      g_free(uri);
    }
    if (!uris.empty()) owner->formats.push_back({"text/uri-list", std::vector<uint8_t>(uris.begin(), uris.end())});
  }
  if (owner->formats.empty()) {
    Fail(call, "This clipboard item has no supported representation.");
    return true;
  }
  std::vector<GtkTargetEntry> targets;
  for (std::size_t index = 0; index < owner->formats.size(); ++index) {
    auto& format = owner->formats[index];
    targets.push_back({const_cast<gchar*>(format.mime.c_str()), 0, static_cast<guint>(index)});
    if (format.mime == "text/plain") {
      targets.push_back({const_cast<gchar*>("UTF8_STRING"), 0, static_cast<guint>(index)});
      targets.push_back({const_cast<gchar*>("text/plain;charset=utf-8"), 0, static_cast<guint>(index)});
    }
  }
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  if (!gtk_clipboard_set_with_data(clipboard, targets.data(), static_cast<guint>(targets.size()),
      ProvideClipboard, ClearClipboard, owner.get())) {
    Fail(call, "The desktop did not accept this clipboard item.");
    return true;
  }
  owner.release();
  gtk_clipboard_set_can_store(clipboard, nullptr, 0);
  Respond(call, nullptr);
  return true;
}

}  // namespace

bool HandleClipboardMethod(FlMethodCall* call) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "writeClipboard") == 0) return WriteClipboard(call);
  if (g_strcmp0(method, "readClipboard") != 0) return false;
  auto read = std::make_shared<ReadSnapshot>();
  read->call = FL_METHOD_CALL(g_object_ref(call));
  if (Wayland()) {
    ReadCommand({"wl-paste", "--list-types"}, 16384, [read](bool success, std::vector<uint8_t> bytes) {
      if (!success) {
        // A cleared clipboard has no selection and wl-paste returns nonzero.
        ReturnSnapshot(read);
        return;
      }
      const std::string text(bytes.begin(), bytes.end());
      gchar** lines = g_strsplit(text.c_str(), "\n", 257);
      std::vector<std::string> names;
      for (std::size_t index = 0; lines[index] != nullptr && index < 256; ++index) names.emplace_back(lines[index]);
      g_strfreev(lines);
      AddTargets(read, names);
      ReadWaylandNext(read);
    });
  } else {
    gtk_clipboard_request_targets(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD), GtkTargets,
        new std::shared_ptr<ReadSnapshot>(read));
  }
  return true;
}
