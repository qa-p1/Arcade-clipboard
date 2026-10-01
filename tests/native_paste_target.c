#include <gtk/gtk.h>

// A real, empty GTK text field for native focus/paste acceptance. Only the
// synthetic test text is written; it never reads any other application.
static const char *output_path;
static void changed(GtkTextBuffer *buffer, gpointer unused) {
  (void)unused;
  GtkTextIter start, end;
  gtk_text_buffer_get_bounds(buffer, &start, &end);
  gchar *text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
  g_file_set_contents(output_path, text, -1, NULL);
  g_free(text);
}
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  output_path = argv[1];
  gtk_init(&argc, &argv);
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), "Arcade paste acceptance");
  gtk_window_set_default_size(GTK_WINDOW(window), 500, 240);
  GtkWidget *view = gtk_text_view_new();
  gtk_container_add(GTK_CONTAINER(window), view);
  g_signal_connect(gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)), "changed",
                   G_CALLBACK(changed), NULL);
  g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
  gtk_widget_show_all(window);
  gtk_widget_grab_focus(view);
  gtk_main();
  return 0;
}
