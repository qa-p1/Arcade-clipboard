#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  gboolean start_hidden;
  FlMethodChannel* instance_channel;
};

// A second launch forwards to the running instance through these actions:
// `clipboard` shows the main window, `clipboard --overlay` opens the picker.
static void forward_instance_action(GSimpleAction* action, GVariant*, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->instance_channel == nullptr) return;
  fl_method_channel_invoke_method(self->instance_channel, g_action_get_name(G_ACTION(action)),
                                  nullptr, nullptr, nullptr, nullptr);
}

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  GtkWidget* window = gtk_widget_get_toplevel(GTK_WIDGET(view));
  // Login starts stay in the tray. The window is realized (so the engine has
  // a rendering surface) but never mapped until the user opens it.
  if (self->start_hidden) {
    gtk_widget_realize(window);
    return;
  }
  gtk_widget_show(window);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->instance_channel != nullptr) {
    // Already running (e.g. D-Bus activation from a launcher): show it.
    fl_method_channel_invoke_method(self->instance_channel, "show", nullptr,
                                    nullptr, nullptr, nullptr);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
  // Tiling Wayland compositors draw their own borders and close windows by
  // keybinding; a client-side title bar only wastes space there.
  const gboolean tiling_compositor =
      g_getenv("HYPRLAND_INSTANCE_SIGNATURE") != nullptr ||
      g_getenv("SWAYSOCK") != nullptr || g_getenv("NIRI_SOCKET") != nullptr;
  if (tiling_compositor) use_header_bar = FALSE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Arcade Clipboard");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Arcade Clipboard");
    if (tiling_compositor) gtk_window_set_decorated(window, FALSE);
  }

  gtk_window_set_default_size(window, 1040, 740);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->instance_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "arcade_clipboard/instance", FL_METHOD_CODEC(codec));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);
  for (gchar** argument = self->dart_entrypoint_arguments; *argument != nullptr; ++argument) {
    if (g_strcmp0(*argument, "--background") == 0) self->start_hidden = TRUE;
  }

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  if (g_application_get_is_remote(application)) {
    gboolean overlay = FALSE;
    for (gchar** argument = self->dart_entrypoint_arguments; *argument != nullptr; ++argument) {
      if (g_strcmp0(*argument, "--overlay") == 0) overlay = TRUE;
    }
    // Login autostart must not pop the window of an already running app.
    if (!self->start_hidden || overlay) {
      g_action_group_activate_action(G_ACTION_GROUP(application),
                                     overlay ? "overlay" : "show", nullptr);
      GDBusConnection* bus = g_application_get_dbus_connection(application);
      if (bus != nullptr) g_dbus_connection_flush_sync(bus, nullptr, nullptr);
    }
    *exit_status = 0;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  static const GActionEntry actions[] = {
      {"show", forward_instance_action, nullptr, nullptr, nullptr, {0}},
      {"overlay", forward_instance_action, nullptr, nullptr, nullptr, {0}},
  };
  g_action_map_add_action_entries(G_ACTION_MAP(application), actions,
                                  G_N_ELEMENTS(actions), application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->instance_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // One instance per user. Development profiles (ARCADE_DATA_DIR) may run
  // side by side, e.g. to pair two local clients.
  const gchar* data_dir = g_getenv("ARCADE_DATA_DIR");
  const GApplicationFlags flags = data_dir != nullptr && *data_dir != '\0'
                                      ? G_APPLICATION_NON_UNIQUE
                                      : G_APPLICATION_DEFAULT_FLAGS;
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
