#include "my_application.h"

#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

static const char kUsage[] =
    "Usage: arcade-clipboard [OPTION]\n"
    "\n"
    "  --show              Show the window of the running instance, or start the app\n"
    "  --hide              Hide the window of the running instance\n"
    "  --toggle            Show or hide the window\n"
    "  --background        Start without showing the window (Launch at login)\n"
    "  --overlay           Open the picker in the running instance, or start the app and open it\n"
    "  --settings          Open Settings in the running instance, or start the app and open it\n"
    "  --status            Print one line of JSON: version, whether it runs, Link state\n"
    "  --restart           Restart the running instance\n"
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

static bool in_appimage_mount(const char* target) {
  const char* appdir = getenv("APPDIR");
  if (appdir != nullptr && *appdir != '\0') {
    size_t length = strlen(appdir);
    while (length > 1 && appdir[length - 1] == '/') --length;
    if (strncmp(target, appdir, length) == 0 && (target[length] == '\0' || target[length] == '/')) return true;
  }
  return strstr(target, "/.mount_") != nullptr;
}

// Mirrors arcade_link::childenv::release_mount_handles. The AppImage runtime
// gives the app an open handle on its mount (fd 1023) that isn't
// close-on-exec; every program the app started inherited it, and one that
// outlived the app (the installed copy after an install from Downloads)
// kept the old mount and runtime alive.
static void release_mount_handles() {
  DIR* fds = opendir("/proc/self/fd");
  if (fds == nullptr) return;
  const int own = dirfd(fds);
  while (const dirent* entry = readdir(fds)) {
    char* end = nullptr;
    const long fd = strtol(entry->d_name, &end, 10);
    if (end == entry->d_name || *end != '\0' || fd <= 2 || fd == own) continue;
    char link[64];
    char target[4096];
    snprintf(link, sizeof link, "/proc/self/fd/%ld", fd);
    const ssize_t length = readlink(link, target, sizeof target - 1);
    if (length <= 0) continue;
    target[length] = '\0';
    if (!in_appimage_mount(target)) continue;
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

// Loads the bundled Rust core for the commands answered before GTK and the
// engine start (CB-5, CB2): it sits in lib/ beside this executable, in the
// bundle and in the AppImage. Null when it can't be loaded; the engine path
// then answers as before.
static void* load_core() {
  char directory[4096];
  const ssize_t length = readlink("/proc/self/exe", directory, sizeof directory - 1);
  if (length <= 0) return nullptr;
  directory[length] = '\0';
  char* slash = strrchr(directory, '/');
  if (slash == nullptr) return nullptr;
  *slash = '\0';
  g_autofree gchar* path = g_build_filename(directory, "lib", "libarcade_core.so", nullptr);
  // Never dlclose()d: the core keeps thread-local state until exit.
  return dlopen(path, RTLD_NOW | RTLD_LOCAL);
}

// --status answers from the bundled Rust core. Returns the exit code, or -1
// when the core can't be loaded and the engine path answers instead.
static int print_status_from_core() {
  void* core = load_core();
  if (core == nullptr) return -1;
  using StatusLine = char* (*)();
  using FreeString = void (*)(char*);
  auto status_line = reinterpret_cast<StatusLine>(dlsym(core, "arcade_clipboard_status_line"));
  auto free_string = reinterpret_cast<FreeString>(dlsym(core, "arcade_clipboard_free_string"));
  if (status_line == nullptr || free_string == nullptr) return -1;
  char* line = status_line();
  if (line == nullptr) return -1;
  const bool written = fputs(line, stdout) >= 0 && fputc('\n', stdout) != EOF && fflush(stdout) == 0;
  free_string(line);
  return written ? 0 : 1;
}

// --arcade-manifest prints the manifest from the bundled Rust core, so it
// needs no display (Link conformance CLI-4). Returns the exit code, or -1
// when the core has no answer and the engine path answers instead.
static int print_manifest_from_core() {
  void* core = load_core();
  if (core == nullptr) return -1;
  using ManifestJson = char* (*)();
  using FreeString = void (*)(char*);
  auto manifest_json = reinterpret_cast<ManifestJson>(dlsym(core, "arcade_clipboard_manifest_json"));
  auto free_string = reinterpret_cast<FreeString>(dlsym(core, "arcade_clipboard_free_string"));
  if (manifest_json == nullptr || free_string == nullptr) return -1;
  char* text = manifest_json();
  if (text == nullptr) return -1;
  const bool written = fputs(text, stdout) >= 0 && fputc('\n', stdout) != EOF && fflush(stdout) == 0;
  free_string(text);
  return written ? 0 : 1;
}

// --restart asks the running instance over the Arcade Link, from the same
// core. Returns the exit code, or -1 when the core can't answer and the
// engine path does, as before. The message is the one Dart printed.
static int restart_from_core() {
  void* core = load_core();
  if (core == nullptr) return -1;
  using RestartRunning = int (*)();
  auto restart_running = reinterpret_cast<RestartRunning>(dlsym(core, "arcade_clipboard_restart_running"));
  if (restart_running == nullptr) return -1;
  const int answered = restart_running();
  if (answered < 0) return -1;
  if (answered == 0) return 0;
  fputs("Arcade Clipboard: Bad state: Arcade Clipboard isn't running.\n", stderr);
  return 1;
}

int main(int argc, char** argv) {
  // Answered here, before GTK and the engine print their warnings (CB-5).
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    fputs("Arcade Clipboard " ARCADE_CLIPBOARD_VERSION "\n", stdout);
    return 0;
  }
  if (argc == 2 && strcmp(argv[1], "--status") == 0) {
    const int answered = print_status_from_core();
    if (answered >= 0) return answered;
  }
  if (argc == 2 && strcmp(argv[1], "--arcade-manifest") == 0) {
    const int answered = print_manifest_from_core();
    if (answered >= 0) return answered;
  }
  if (argc == 2 && strcmp(argv[1], "--restart") == 0) {
    const int answered = restart_from_core();
    if (answered >= 0) return answered;
  }
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      fputs(kUsage, stdout);
      return 0;
    }
  }
  release_mount_handles();
  wait_for_predecessor();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
