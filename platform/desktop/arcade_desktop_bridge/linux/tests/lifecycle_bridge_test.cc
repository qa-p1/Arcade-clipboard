#include "../lifecycle_bridge.cc"

#include <cassert>

namespace {

struct WatcherProbe {
  guint registrations = 0;
};

struct ItemProbe {
  GDBusMethodInvocation* invocation;
  WatcherProbe* watcher;
};

void CheckAutostart() {
  assert(g_strcmp0(g_getenv("ARCADE_E2E_INNER"), "1") == 0);
  const gchar* root = g_getenv("ARCADE_E2E_ROOT");
  assert(root != nullptr);
  const std::string image = std::string(root) + "/Clipboard test.AppImage";
  assert(g_file_set_contents(image.c_str(), "appimage", -1, nullptr));
  const gchar* old_appimage = g_getenv("APPIMAGE");
  const std::string previous_appimage = old_appimage == nullptr ? "" : old_appimage;
  g_setenv("APPIMAGE", image.c_str(), TRUE);
  assert(AutostartExecutable() == image);
  const std::string path = AutostartPath();
  assert(path.rfind(std::string(g_getenv("ARCADE_HOME")) + "/", 0) == 0);
  assert(!PersistentPath(image) && InstallPathAllowed(image));
  assert(!InstallPathAllowed("/tmp/other-session/Clipboard.AppImage"));
  std::string error;
  assert(SetAutostart(true, &error));
  assert(LaunchAtLoginEnabled());
  g_autoptr(GKeyFile) entry = g_key_file_new();
  assert(g_key_file_load_from_file(entry, path.c_str(), G_KEY_FILE_NONE, nullptr));
  gchar* command = g_key_file_get_string(entry, "Desktop Entry", "Exec", nullptr);
  assert(command != nullptr && command == DesktopExecQuote(image));
  g_free(command);
  assert(SetAutostart(false, &error));
  assert(!LaunchAtLoginEnabled() && !g_file_test(path.c_str(), G_FILE_TEST_EXISTS));

  // The shared Link installer owns its entry with X-Arcade-Id, not our old marker.
  const char* shared = "[Desktop Entry]\nType=Application\nX-Arcade-Id=arcade.clipboard\nExec=/opt/Clipboard --background\n";
  assert(g_file_set_contents(path.c_str(), shared, -1, nullptr));
  assert(LaunchAtLoginEnabled());
  assert(SetAutostart(true, &error));
  assert(SetAutostart(false, &error));
  const char* legacy = "[Desktop Entry]\nX-ArcadeClipboard-Managed=true\n";
  assert(g_file_set_contents(path.c_str(), legacy, -1, nullptr));
  assert(LaunchAtLoginEnabled() && SetAutostart(false, &error));
  const char* foreign = "[Desktop Entry]\nX-Arcade-Id=arcade.other\nX-ArcadeClipboard-Managed=true\n";
  assert(g_file_set_contents(path.c_str(), foreign, -1, nullptr));
  assert(!LaunchAtLoginEnabled());
  assert(!SetAutostart(true, &error) && !SetAutostart(false, &error));
  gchar* contents = nullptr;
  assert(g_file_get_contents(path.c_str(), &contents, nullptr, nullptr));
  assert(g_strcmp0(contents, foreign) == 0);
  g_free(contents);
  assert(unlink(path.c_str()) == 0);
  g_setenv("APPIMAGE", "/tmp/other-session/Clipboard.AppImage", TRUE);
  assert(!SetAutostart(true, &error));
  if (previous_appimage.empty()) g_unsetenv("APPIMAGE");
  else g_setenv("APPIMAGE", previous_appimage.c_str(), TRUE);
  unlink(image.c_str());
}

void ItemRead(GObject* source, GAsyncResult* result, gpointer data) {
  auto* probe = static_cast<ItemProbe*>(data);
  GError* error = nullptr;
  GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  assert(reply != nullptr && error == nullptr);
  GVariant* value = nullptr;
  g_variant_get(reply, "(v)", &value);
  assert(g_strcmp0(g_variant_get_string(value, nullptr), "arcade-clipboard") == 0);
  g_variant_unref(value);
  g_variant_unref(reply);
  ++probe->watcher->registrations;
  g_dbus_method_invocation_return_value(probe->invocation, nullptr);
  g_object_unref(probe->invocation);
  delete probe;
}

void RegisterProbe(GDBusConnection* bus, const gchar*, const gchar*, const gchar*, const gchar*,
    GVariant* arguments, GDBusMethodInvocation* invocation, gpointer data) {
  const gchar* service = nullptr;
  g_variant_get(arguments, "(&s)", &service);
  auto* probe = new ItemProbe{G_DBUS_METHOD_INVOCATION(g_object_ref(invocation)),
                              static_cast<WatcherProbe*>(data)};
  // Real watchers can inspect the item before acknowledging registration.
  // Both objects use this main context: a synchronous OpenTray deadlocks.
  g_dbus_connection_call(bus, service, "/StatusNotifierItem", "org.freedesktop.DBus.Properties",
      "Get", g_variant_new("(ss)", "org.kde.StatusNotifierItem", "Id"), G_VARIANT_TYPE("(v)"),
      G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, ItemRead, probe);
}

void CheckTrayRegistration() {
  // This regression must never register with the user's real tray watcher.
  assert(g_strcmp0(g_getenv("ARCADE_E2E_INNER"), "1") == 0);
  std::string error;
  assert(!TrayHostAvailable(&error));
  assert(!error.empty());

  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  assert(bus != nullptr);
  GDBusNodeInfo* watcher_info = g_dbus_node_info_new_for_xml(
      "<node><interface name='org.kde.StatusNotifierWatcher'>"
      "<method name='RegisterStatusNotifierItem'><arg type='s' direction='in'/></method>"
      "</interface></node>", nullptr);
  WatcherProbe probe;
  static const GDBusInterfaceVTable vtable = {RegisterProbe, nullptr, nullptr, {nullptr}};
  guint registration = g_dbus_connection_register_object(bus, "/StatusNotifierWatcher",
      watcher_info->interfaces[0], &vtable, &probe, nullptr, nullptr);
  assert(registration != 0);
  GVariant* reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "RequestName", g_variant_new("(su)", kWatcher, 0U),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
  assert(reply != nullptr);
  g_variant_unref(reply);
  assert(TrayHostAvailable(&error));

  LinuxLifecycle state;
  state.background = true;
  for (guint cycle = 1; cycle <= 3; ++cycle) {
    assert(OpenTray(&state, &error));
    const gint64 deadline = g_get_monotonic_time() + G_TIME_SPAN_SECOND;
    while (probe.registrations < cycle && g_get_monotonic_time() < deadline) {
      while (g_main_context_iteration(nullptr, FALSE)) {}
      g_usleep(1000);
    }
    assert(probe.registrations == cycle);
    GDBusConnection* item_bus = G_DBUS_CONNECTION(g_object_ref(state.bus));
    CloseTray(&state);
    assert(state.bus == nullptr && state.watcher == 0);
    assert(g_dbus_connection_is_closed(item_bus));
    g_object_unref(item_bus);
    while (g_main_context_iteration(nullptr, FALSE)) {}
  }
  g_dbus_node_info_unref(state.item_info);
  g_dbus_node_info_unref(state.menu_info);
  g_dbus_connection_unregister_object(bus, registration);
  reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "ReleaseName", g_variant_new("(s)", kWatcher),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
  assert(reply != nullptr);
  g_variant_unref(reply);
  g_dbus_node_info_unref(watcher_info);
  g_object_unref(bus);
}

// Started at login before the desktop's tray: the icon must appear once the
// watcher does, not never (the item used to be refused without a host).
void CheckLateTrayHost() {
  assert(g_strcmp0(g_getenv("ARCADE_E2E_INNER"), "1") == 0);
  std::string error;
  assert(!TrayHostAvailable(&error));
  LinuxLifecycle state;
  state.background = true;
  assert(OpenTray(&state, &error));
  WaitForTrayHost(&state);
  for (int i = 0; i < 50; ++i) {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_usleep(1000);
  }
  assert(!state.host_present && state.host_timeout != 0);

  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  GDBusNodeInfo* watcher_info = g_dbus_node_info_new_for_xml(
      "<node><interface name='org.kde.StatusNotifierWatcher'>"
      "<method name='RegisterStatusNotifierItem'><arg type='s' direction='in'/></method>"
      "</interface></node>", nullptr);
  WatcherProbe probe;
  static const GDBusInterfaceVTable vtable = {RegisterProbe, nullptr, nullptr, {nullptr}};
  guint registration = g_dbus_connection_register_object(bus, "/StatusNotifierWatcher",
      watcher_info->interfaces[0], &vtable, &probe, nullptr, nullptr);
  GVariant* reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "RequestName", g_variant_new("(su)", kWatcher, 0U),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
  assert(reply != nullptr);
  g_variant_unref(reply);
  const gint64 deadline = g_get_monotonic_time() + 2 * G_TIME_SPAN_SECOND;
  while (probe.registrations == 0 && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_usleep(1000);
  }
  assert(probe.registrations == 1);
  assert(state.host_present && state.host_timeout == 0);
  CloseTray(&state);
  g_dbus_node_info_unref(state.item_info);
  g_dbus_node_info_unref(state.menu_info);
  g_dbus_connection_unregister_object(bus, registration);
  reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "ReleaseName", g_variant_new("(s)", kWatcher),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
  g_variant_unref(reply);
  g_dbus_node_info_unref(watcher_info);
  g_object_unref(bus);
}

}  // namespace

int main() {
  assert(PersistentPath("/opt/Arcade Clipboard/arcade_clipboard"));
  assert(!PersistentPath("/tmp/arcade_clipboard"));
  assert(!PersistentPath("/run/user/1000/arcade_clipboard"));
  assert(!PersistentPath("/home/test/.cache/arcade_clipboard"));
  assert(DesktopExecQuote("/opt/my app/100%clipboard") == "\"/opt/my app/100%%clipboard\" --background");

  GError* error = nullptr;
  GDBusNodeInfo* item = g_dbus_node_info_new_for_xml(kItemXml, &error);
  assert(item != nullptr && error == nullptr);
  GDBusNodeInfo* menu = g_dbus_node_info_new_for_xml(kMenuXml, &error);
  assert(menu != nullptr && error == nullptr);
  g_dbus_node_info_unref(item);
  g_dbus_node_info_unref(menu);

  LinuxLifecycle lifecycle;
  GVariant* layout = g_variant_ref_sink(MenuLayout(&lifecycle, 0));
  assert(g_variant_is_of_type(layout, G_VARIANT_TYPE("(ia{sv}av)")));
  GVariant* children = g_variant_get_child_value(layout, 2);
  assert(g_variant_n_children(children) == 6);
  g_variant_unref(children);
  // The standard tray order and wording (STANDARD §8).
  const char* expected[] = {"Open Arcade Clipboard", "Settings", nullptr, "Private mode", "Restart Arcade Clipboard",
                            "Quit Arcade Clipboard"};
  for (gint id = 1; id <= 6; ++id) {
    GVariant* properties = g_variant_ref_sink(MenuProperties(&lifecycle, id));
    const gchar* label = nullptr;
    const gchar* type = nullptr;
    if (expected[id - 1] == nullptr) {
      assert(g_variant_lookup(properties, "type", "&s", &type) && g_strcmp0(type, "separator") == 0);
    } else {
      assert(g_variant_lookup(properties, "label", "&s", &label) && g_strcmp0(label, expected[id - 1]) == 0);
    }
    g_variant_unref(properties);
  }
  g_variant_unref(layout);

  // The Private mode item is a checkmark that follows the core's state.
  for (bool on : {false, true}) {
    lifecycle.private_mode = on;
    GVariant* properties = g_variant_ref_sink(MenuProperties(&lifecycle, kPrivateModeItem));
    const gchar* toggle = nullptr;
    gint32 checked = -1;
    assert(g_variant_lookup(properties, "toggle-type", "&s", &toggle) && g_strcmp0(toggle, "checkmark") == 0);
    assert(g_variant_lookup(properties, "toggle-state", "i", &checked) && checked == (on ? 1 : 0));
    g_variant_unref(properties);
  }

  // Exercise the layered desktop-file escaping for literal shell metacharacters.
  GKeyFile* config = g_key_file_new();
  const std::string executable = "/opt/Arcade $copy`name`\\utility";
  const std::string command = DesktopExecQuote(executable);
  g_key_file_set_string(config, "Desktop Entry", "Exec", command.c_str());
  gsize length = 0;
  gchar* serialized = g_key_file_to_data(config, &length, &error);
  assert(serialized != nullptr && error == nullptr);
  assert(g_key_file_load_from_data(config, serialized, length, G_KEY_FILE_NONE, &error));
  gchar* loaded = g_key_file_get_string(config, "Desktop Entry", "Exec", &error);
  assert(error == nullptr && loaded != nullptr && std::string(loaded) == command);
  g_free(loaded);
  g_free(serialized);
  g_key_file_unref(config);
  CheckAutostart();
  CheckTrayRegistration();
  CheckLateTrayHost();
  return 0;
}
