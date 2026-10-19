#include "my_application.h"

#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

static const char kUsage[] =
    "Usage: arcade-clipboard [OPTION]\n"
    "\n"
    "  --background        Start without showing the window (Launch at login)\n"
    "  --overlay           Open the picker in the running instance, or start the app and open it\n"
    "  --settings          Open Settings in the running instance, or start the app and open it\n"
    "  --quit              Quit the running instance\n"
    "  --version           Print the version\n"
    "  --install [--silent] [--no-launch] [--keep-download] [--channel stable|nightly]\n"
    "                      Install this AppImage\n"
    "  --uninstall [--silent] [--remove-data]\n"
    "                      Remove the installation; data is kept unless --remove-data\n"
    "  --repair            Restore the launcher, command and login entries\n"
    "  --integration-status\n"
    "                      Print the integration as JSON\n"
    "  --arcade-manifest   Print the Arcade Link manifest\n"
    "  -h, --help          Print this help\n";

// Mirrors arcade_link::childenv::release_inherited_handles. The AppImage
// runtime leaves the app two inherited descriptors that aren't close-on-exec:
// a handle on its mount (fd 1023) and the read end of its keep-alive pipe,
// whose holders keep the runtime and mount alive. Every program the app
// started inherited both, so one that outlived the app (the installed copy
// after an install from Downloads) kept the old image mounted. At start
// every descriptor above stdio was inherited; none is meant to be passed on.
static void release_inherited_handles() {
  DIR* fds = opendir("/proc/self/fd");
  if (fds == nullptr) return;
  const int own = dirfd(fds);
  while (const dirent* entry = readdir(fds)) {
    char* end = nullptr;
    const long fd = strtol(entry->d_name, &end, 10);
    if (end == entry->d_name || *end != '\0' || fd <= 2 || fd == own) continue;
    const int flags = fcntl(static_cast<int>(fd), F_GETFD);
    if (flags >= 0 && !(flags & FD_CLOEXEC)) fcntl(static_cast<int>(fd), F_SETFD, flags | FD_CLOEXEC);
  }
  closedir(fds);
}

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
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      fputs(kUsage, stdout);
      return 0;
    }
  }
  release_inherited_handles();
  wait_for_predecessor();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
