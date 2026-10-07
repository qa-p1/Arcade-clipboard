#include "lifecycle_bridge.h"

#include <gtk/gtk.h>
#include <unistd.h>

#include <string>

struct LinuxLifecycle {
  FlMethodChannel* channel = nullptr;
  GtkWidget* view = nullptr;
  GtkWidget* window = nullptr;
  GDBusConnection* bus = nullptr;
  GDBusNodeInfo* item_info = nullptr;
  GDBusNodeInfo* menu_info = nullptr;
  guint item_registration = 0;
  guint menu_registration = 0;
  guint watcher = 0;
  gulong map_handler = 0;
  gulong close_handler = 0;
  bool background = false;
};

namespace {

constexpr const char* kWatcher = "org.kde.StatusNotifierWatcher";
constexpr const char* kItemXml = R"XML(
<node><interface name="org.kde.StatusNotifierItem">
 <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
 <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
 <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
 <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
 <property name="Category" type="s" access="read"/>
 <property name="Id" type="s" access="read"/>
 <property name="Title" type="s" access="read"/>
 <property name="Status" type="s" access="read"/>
 <property name="IconName" type="s" access="read"/>
 <property name="IconPixmap" type="a(iiay)" access="read"/>
 <property name="OverlayIconName" type="s" access="read"/>
 <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
 <property name="AttentionIconName" type="s" access="read"/>
 <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
 <property name="AttentionMovieName" type="s" access="read"/>
 <property name="ItemIsMenu" type="b" access="read"/>
 <property name="Menu" type="o" access="read"/>
 <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
 <signal name="NewStatus"><arg type="s"/></signal>
 <signal name="NewIcon"/><signal name="NewTitle"/><signal name="NewToolTip"/>
</interface></node>)XML";

constexpr const char* kMenuXml = R"XML(
<node><interface name="com.canonical.dbusmenu">
 <method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
 <method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
 <method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
 <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
 <method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
 <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
 <method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
 <property name="Version" type="u" access="read"/>
 <property name="TextDirection" type="s" access="read"/>
 <property name="Status" type="s" access="read"/>
 <property name="IconThemePath" type="as" access="read"/>
</interface></node>)XML";

void Respond(FlMethodCall* call, FlValue* value = nullptr) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}

void Fail(FlMethodCall* call, const std::string& message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new("desktop_lifecycle_unavailable", message.c_str(), nullptr));
  fl_method_call_respond(call, response, nullptr);
}

void Invoke(LinuxLifecycle* state, const char* action) {
  fl_method_channel_invoke_method(state->channel, action, nullptr, nullptr, nullptr, nullptr);
}

gboolean WindowClose(GtkWidget* window, GdkEvent*, gpointer data) {
  auto* state = static_cast<LinuxLifecycle*>(data);
  if (!state->background) return FALSE;
  gtk_widget_hide(window);
  return TRUE;
}

void ConnectWindow(LinuxLifecycle* state) {
  if (state->view == nullptr || state->window != nullptr) return;
  GtkWidget* window = gtk_widget_get_toplevel(state->view);
  if (!GTK_IS_WINDOW(window)) return;
  state->window = window;
  g_object_add_weak_pointer(G_OBJECT(window), reinterpret_cast<gpointer*>(&state->window));
  state->close_handler = g_signal_connect(window, "delete-event", G_CALLBACK(WindowClose), state);
}

void ViewMapped(GtkWidget*, gpointer data) { ConnectWindow(static_cast<LinuxLifecycle*>(data)); }

// The tray menu every Arcade app has: open, settings, restart and, below a
// separator, quit. Item ids are 1..kMenuItems; id 4 is the separator.
constexpr gint kMenuItems = 5;
constexpr const char* kMenuLabels[] = {"", "Open Clipboard", "Open Settings", "Restart Arcade Clipboard", "",
                                       "Quit Arcade Clipboard"};
constexpr const char* kMenuActions[] = {nullptr, "showMainWindow", "showSettings", "restartRequested", nullptr,
                                        "quitRequested"};

GVariant* MenuProperties(gint id) {
  GVariantBuilder properties;
  g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
  if (id == 0) {
    g_variant_builder_add(&properties, "{sv}", "children-display", g_variant_new_string("submenu"));
  } else if (id == 4) {
    g_variant_builder_add(&properties, "{sv}", "type", g_variant_new_string("separator"));
  } else if (id > 0 && id <= kMenuItems) {
    g_variant_builder_add(&properties, "{sv}", "label", g_variant_new_string(kMenuLabels[id]));
    g_variant_builder_add(&properties, "{sv}", "enabled", g_variant_new_boolean(TRUE));
    g_variant_builder_add(&properties, "{sv}", "visible", g_variant_new_boolean(TRUE));
  }
  return g_variant_builder_end(&properties);
}

GVariant* MenuLayout(gint id) {
  GVariantBuilder children;
  g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
  if (id == 0) {
    for (gint child = 1; child <= kMenuItems; ++child) g_variant_builder_add(&children, "v", MenuLayout(child));
  }
  return g_variant_new("(i@a{sv}@av)", id, MenuProperties(id), g_variant_builder_end(&children));
}

void MenuEvent(LinuxLifecycle* state, gint id, const gchar* event) {
  if (g_strcmp0(event, "clicked") != 0 || id < 1 || id > kMenuItems || kMenuActions[id] == nullptr) return;
  Invoke(state, kMenuActions[id]);
}

void ItemMethod(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar* method,
    GVariant*, GDBusMethodInvocation* invocation, gpointer data) {
  auto* state = static_cast<LinuxLifecycle*>(data);
  // A click opens Settings, as in every Arcade app; hosts that can't draw
  // the menu ask for it with ContextMenu, so that opens the window.
  if (g_strcmp0(method, "Activate") == 0) {
    Invoke(state, "showSettings");
  } else if (g_strcmp0(method, "SecondaryActivate") == 0 || g_strcmp0(method, "ContextMenu") == 0) {
    Invoke(state, "showMainWindow");
  }
  g_dbus_method_invocation_return_value(invocation, nullptr);
}

GVariant* EmptyPixmaps() { return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), nullptr, 0); }

GVariant* ItemProperty(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar* name,
    GError**, gpointer data) {
  auto* state = static_cast<LinuxLifecycle*>(data);
  if (g_strcmp0(name, "Category") == 0) return g_variant_new_string("ApplicationStatus");
  if (g_strcmp0(name, "Id") == 0) return g_variant_new_string("arcade-clipboard");
  if (g_strcmp0(name, "Title") == 0) return g_variant_new_string("Arcade Clipboard");
  if (g_strcmp0(name, "Status") == 0) return g_variant_new_string(state->background ? "Active" : "Passive");
  if (g_strcmp0(name, "IconName") == 0) return g_variant_new_string("edit-paste");
  if (g_strcmp0(name, "Menu") == 0) return g_variant_new_object_path("/Menu");
  if (g_strcmp0(name, "ItemIsMenu") == 0) return g_variant_new_boolean(FALSE);
  if (g_strcmp0(name, "ToolTip") == 0) return g_variant_new("(s@a(iiay)ss)", "edit-paste", EmptyPixmaps(), "Arcade Clipboard", "Shared clipboard");
  if (g_str_has_suffix(name, "Pixmap")) return EmptyPixmaps();
  return g_variant_new_string("");
}

void MenuMethod(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar* method,
    GVariant* arguments, GDBusMethodInvocation* invocation, gpointer data) {
  auto* state = static_cast<LinuxLifecycle*>(data);
  if (g_strcmp0(method, "GetLayout") == 0) {
    gint id = 0;
    g_variant_get_child(arguments, 0, "i", &id);
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(u@(ia{sv}av))", 1U, MenuLayout(id)));
  } else if (g_strcmp0(method, "GetGroupProperties") == 0) {
    GVariantBuilder groups;
    g_variant_builder_init(&groups, G_VARIANT_TYPE("a(ia{sv})"));
    for (gint id = 0; id <= kMenuItems; ++id) g_variant_builder_add(&groups, "(i@a{sv})", id, MenuProperties(id));
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&groups)));
  } else if (g_strcmp0(method, "GetProperty") == 0) {
    gint id = 0;
    const gchar* name = nullptr;
    g_variant_get(arguments, "(i&s)", &id, &name);
    GVariant* properties = MenuProperties(id);
    GVariant* value = g_variant_lookup_value(properties, name, nullptr);
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", value == nullptr ? g_variant_new_string("") : value));
    if (value != nullptr) g_variant_unref(value);
    g_variant_ref_sink(properties);
    g_variant_unref(properties);
  } else if (g_strcmp0(method, "Event") == 0) {
    gint id = 0;
    const gchar* event = nullptr;
    g_variant_get_child(arguments, 0, "i", &id);
    g_variant_get_child(arguments, 1, "&s", &event);
    MenuEvent(state, id, event);
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else if (g_strcmp0(method, "EventGroup") == 0) {
    GVariant* events = g_variant_get_child_value(arguments, 0);
    for (gsize index = 0; index < g_variant_n_children(events); ++index) {
      GVariant* event = g_variant_get_child_value(events, index);
      gint id = 0;
      const gchar* action = nullptr;
      g_variant_get_child(event, 0, "i", &id);
      g_variant_get_child(event, 1, "&s", &action);
      MenuEvent(state, id, action);
      g_variant_unref(event);
    }
    g_variant_unref(events);
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0)));
  } else if (g_strcmp0(method, "AboutToShow") == 0) {
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", FALSE));
  } else if (g_strcmp0(method, "AboutToShowGroup") == 0) {
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai@ai)",
        g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0),
        g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0)));
  } else {
    g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown menu method.");
  }
}

GVariant* MenuProperty(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar* name,
    GError**, gpointer) {
  if (g_strcmp0(name, "Version") == 0) return g_variant_new_uint32(3);
  if (g_strcmp0(name, "IconThemePath") == 0) return g_variant_new_strv(nullptr, 0);
  return g_variant_new_string(g_strcmp0(name, "TextDirection") == 0 ? "ltr" : "normal");
}

void RegisterItem(LinuxLifecycle* state) {
  if (state->bus == nullptr || !state->background) return;
  g_dbus_connection_call(state->bus, kWatcher, "/StatusNotifierWatcher", kWatcher,
      "RegisterStatusNotifierItem", g_variant_new("(s)", g_dbus_connection_get_unique_name(state->bus)),
      nullptr, G_DBUS_CALL_FLAGS_NONE, 1500, nullptr, nullptr, nullptr);
}

void WatcherAppeared(GDBusConnection*, const gchar*, const gchar*, gpointer data) {
  RegisterItem(static_cast<LinuxLifecycle*>(data));
}

void WatcherVanished(GDBusConnection*, const gchar*, gpointer data) {
  auto* state = static_cast<LinuxLifecycle*>(data);
  // A shell restart should never strand an invisible application.
  if (state->background && state->window != nullptr && !gtk_widget_get_visible(state->window)) {
    Invoke(state, "showMainWindow");
  }
}

bool EnableTray(LinuxLifecycle* state, std::string* error) {
  GError* failure = nullptr;
  if (state->bus == nullptr) state->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &failure);
  if (state->bus == nullptr) {
    *error = "The desktop session bus is unavailable. Keep the app window open for sync.";
    g_clear_error(&failure);
    return false;
  }
  GVariant* owner = g_dbus_connection_call_sync(state->bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", kWatcher), G_VARIANT_TYPE("(b)"),
      G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &failure);
  gboolean available = FALSE;
  if (owner != nullptr) {
    g_variant_get(owner, "(b)", &available);
    g_variant_unref(owner);
  }
  g_clear_error(&failure);
  if (!available) {
    *error = "This desktop has no system tray host. Keep the app window open, or enable a StatusNotifier tray extension.";
    return false;
  }
  if (state->item_registration == 0) {
    static const GDBusInterfaceVTable item_vtable = {ItemMethod, ItemProperty, nullptr, {nullptr}};
    static const GDBusInterfaceVTable menu_vtable = {MenuMethod, MenuProperty, nullptr, {nullptr}};
    state->item_info = g_dbus_node_info_new_for_xml(kItemXml, &failure);
    state->menu_info = g_dbus_node_info_new_for_xml(kMenuXml, &failure);
    if (state->item_info == nullptr || state->menu_info == nullptr) {
      *error = "The tray interface could not be created.";
      g_clear_error(&failure);
      return false;
    }
    state->item_registration = g_dbus_connection_register_object(state->bus, "/StatusNotifierItem",
        state->item_info->interfaces[0], &item_vtable, state, nullptr, &failure);
    state->menu_registration = g_dbus_connection_register_object(state->bus, "/Menu",
        state->menu_info->interfaces[0], &menu_vtable, state, nullptr, &failure);
    if (state->item_registration == 0 || state->menu_registration == 0) {
      *error = "The system tray could not be registered.";
      g_clear_error(&failure);
      return false;
    }
    state->watcher = g_bus_watch_name_on_connection(state->bus, kWatcher, G_BUS_NAME_WATCHER_FLAGS_NONE,
        WatcherAppeared, WatcherVanished, state, nullptr);
  }
  GVariant* registered = g_dbus_connection_call_sync(state->bus, kWatcher, "/StatusNotifierWatcher", kWatcher,
      "RegisterStatusNotifierItem", g_variant_new("(s)", g_dbus_connection_get_unique_name(state->bus)),
      nullptr, G_DBUS_CALL_FLAGS_NONE, 1500, nullptr, &failure);
  if (registered == nullptr) {
    *error = "The system tray did not accept the app. Keep the window open for sync.";
    g_clear_error(&failure);
    return false;
  }
  g_variant_unref(registered);
  return true;
}

std::string AutostartPath() {
  return std::string(g_get_user_config_dir()) + "/autostart/arcade-clipboard.desktop";
}

bool Enabled(FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return false;
  FlValue* enabled = fl_value_lookup_string(args, "enabled");
  return enabled != nullptr && fl_value_get_type(enabled) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(enabled);
}

bool PersistentPath(const std::string& path) {
  return !path.empty() && path.front() == '/' &&
      path.rfind("/tmp/", 0) != 0 && path.rfind("/run/", 0) != 0 &&
      path.rfind("/var/tmp/", 0) != 0 && path.find("/.cache/") == std::string::npos;
}

std::string DesktopExecQuote(const std::string& path) {
  std::string value = "\"";
  for (const char character : path) {
    if (character == '%') value += '%';
    if (character == '\\' || character == '"' || character == '$' || character == '`') value += '\\';
    value += character;
  }
  return value + "\" --background";
}

bool SetAutostart(bool enabled, std::string* error) {
  const std::string path = AutostartPath();
  gchar* previous = nullptr;
  gsize previous_length = 0;
  GError* failure = nullptr;
  const bool exists = g_file_test(path.c_str(), G_FILE_TEST_EXISTS);
  if (exists) {
    if (!g_file_get_contents(path.c_str(), &previous, &previous_length, &failure) ||
        g_strstr_len(previous, static_cast<gssize>(previous_length), "X-ArcadeClipboard-Managed=true") == nullptr) {
      *error = "An existing login entry could not be safely updated. Remove or rename arcade-clipboard.desktop first.";
      g_free(previous);
      g_clear_error(&failure);
      return false;
    }
    if (!g_file_set_contents((path + ".bak").c_str(), previous, static_cast<gssize>(previous_length), &failure)) {
      *error = "The existing login entry could not be backed up.";
      g_free(previous);
      g_clear_error(&failure);
      return false;
    }
  }
  g_free(previous);
  if (!enabled) {
    if (exists && unlink(path.c_str()) != 0) {
      *error = "The login entry could not be removed.";
      return false;
    }
    return true;
  }
  gchar* executable = g_file_read_link("/proc/self/exe", &failure);
  const std::string executable_path = executable == nullptr ? "" : executable;
  g_free(executable);
  g_clear_error(&failure);
  if (!PersistentPath(executable_path) || !PersistentPath(path)) {
    *error = "Launch at login requires the app to be installed in a persistent folder.";
    return false;
  }
  gchar* directory = g_path_get_dirname(path.c_str());
  const bool directory_ok = g_mkdir_with_parents(directory, 0700) == 0;
  g_free(directory);
  if (!directory_ok) {
    *error = "The login folder could not be created.";
    return false;
  }
  GKeyFile* validation = g_key_file_new();
  // GLib escapes the value; the desktop launcher then handles Exec quoting.
  g_key_file_set_string(validation, "Desktop Entry", "Type", "Application");
  g_key_file_set_string(validation, "Desktop Entry", "Name", "Arcade Clipboard");
  g_key_file_set_string(validation, "Desktop Entry", "Comment", "Shared clipboard");
  g_key_file_set_string(validation, "Desktop Entry", "Exec", DesktopExecQuote(executable_path).c_str());
  g_key_file_set_boolean(validation, "Desktop Entry", "Terminal", FALSE);
  g_key_file_set_boolean(validation, "Desktop Entry", "X-GNOME-Autostart-enabled", TRUE);
  g_key_file_set_boolean(validation, "Desktop Entry", "X-ArcadeClipboard-Managed", TRUE);
  gsize length = 0;
  gchar* contents = g_key_file_to_data(validation, &length, &failure);
  const bool valid = contents != nullptr && g_key_file_load_from_data(validation, contents, length, G_KEY_FILE_NONE, &failure);
  g_key_file_unref(validation);
  if (!valid || !g_file_set_contents(path.c_str(), contents, static_cast<gssize>(length), &failure)) {
    *error = "The login entry could not be saved.";
    g_free(contents);
    g_clear_error(&failure);
    return false;
  }
  g_free(contents);
  return true;
}

}  // namespace

LinuxLifecycle* CreateLinuxLifecycle(FlPluginRegistrar* registrar, FlMethodChannel* channel) {
  auto* state = new LinuxLifecycle();
  state->channel = FL_METHOD_CHANNEL(g_object_ref(channel));
  state->view = GTK_WIDGET(fl_plugin_registrar_get_view(registrar));
  if (state->view != nullptr) {
    g_object_add_weak_pointer(G_OBJECT(state->view), reinterpret_cast<gpointer*>(&state->view));
    state->map_handler = g_signal_connect(state->view, "map", G_CALLBACK(ViewMapped), state);
    ConnectWindow(state);
  }
  return state;
}

bool HandleLifecycleMethod(LinuxLifecycle* state, FlMethodCall* call) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "setBackgroundEnabled") == 0) {
    const bool enabled = Enabled(call);
    std::string error;
    if (enabled && !EnableTray(state, &error)) {
      Fail(call, error);
      return true;
    }
    state->background = enabled;
    if (enabled) RegisterItem(state);
    if (state->bus != nullptr && state->item_registration != 0) {
      g_dbus_connection_emit_signal(state->bus, nullptr, "/StatusNotifierItem", "org.kde.StatusNotifierItem",
          "NewStatus", g_variant_new("(s)", enabled ? "Active" : "Passive"), nullptr);
    }
    Respond(call);
    return true;
  }
  if (g_strcmp0(method, "setLaunchAtLogin") == 0) {
    std::string error;
    if (!SetAutostart(Enabled(call), &error)) Fail(call, error);
    else Respond(call);
    return true;
  }
  if (g_strcmp0(method, "launchAtLoginEnabled") == 0) {
    gchar* contents = nullptr;
    const bool loaded = g_file_get_contents(AutostartPath().c_str(), &contents, nullptr, nullptr);
    const bool enabled = loaded && g_strstr_len(contents, -1, "X-ArcadeClipboard-Managed=true") != nullptr;
    g_free(contents);
    g_autoptr(FlValue) value = fl_value_new_bool(enabled);
    Respond(call, value);
    return true;
  }
  return false;
}

void DestroyLinuxLifecycle(LinuxLifecycle* state) {
  if (state == nullptr) return;
  if (state->window != nullptr) {
    if (state->close_handler != 0) g_signal_handler_disconnect(state->window, state->close_handler);
    g_object_remove_weak_pointer(G_OBJECT(state->window), reinterpret_cast<gpointer*>(&state->window));
  }
  if (state->view != nullptr) {
    if (state->map_handler != 0) g_signal_handler_disconnect(state->view, state->map_handler);
    g_object_remove_weak_pointer(G_OBJECT(state->view), reinterpret_cast<gpointer*>(&state->view));
  }
  if (state->watcher != 0) g_bus_unwatch_name(state->watcher);
  if (state->bus != nullptr && state->item_registration != 0) g_dbus_connection_unregister_object(state->bus, state->item_registration);
  if (state->bus != nullptr && state->menu_registration != 0) g_dbus_connection_unregister_object(state->bus, state->menu_registration);
  if (state->item_info != nullptr) g_dbus_node_info_unref(state->item_info);
  if (state->menu_info != nullptr) g_dbus_node_info_unref(state->menu_info);
  g_clear_object(&state->bus);
  g_clear_object(&state->channel);
  delete state;
}
