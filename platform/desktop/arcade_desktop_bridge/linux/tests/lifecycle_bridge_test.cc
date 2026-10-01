#include "../lifecycle_bridge.cc"

#include <cassert>

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

  GVariant* layout = g_variant_ref_sink(MenuLayout(0));
  assert(g_variant_is_of_type(layout, G_VARIANT_TYPE("(ia{sv}av)")));
  GVariant* children = g_variant_get_child_value(layout, 2);
  assert(g_variant_n_children(children) == 2);
  g_variant_unref(children);
  g_variant_unref(layout);

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
  return 0;
}
