#include "my_application.h"

// After the tray's Restart the successor carries the old process id; wait
// (up to 5 s) for it to exit, or the single-instance check would just hand
// this launch to the instance that is quitting.
static void wait_for_predecessor() {
  const gchar* old = g_getenv("ARCADE_CLIPBOARD_RESTART_AFTER");
  if (old == nullptr) return;
  g_autofree gchar* proc = g_strdup_printf("/proc/%s", old);
  for (int attempt = 0; attempt < 50 && g_file_test(proc, G_FILE_TEST_EXISTS); ++attempt) {
    g_usleep(100 * 1000);
  }
}

int main(int argc, char** argv) {
  wait_for_predecessor();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
