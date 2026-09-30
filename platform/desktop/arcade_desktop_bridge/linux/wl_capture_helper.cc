#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdlib.h>

#include <poll.h>
#include <signal.h>
#include <strings.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

namespace {

constexpr std::size_t kMaximumTextBytes = 32 * 1024;
constexpr int kReadTimeoutMilliseconds = 2000;

bool IsPlainTextMimeType(const char* mime_type) {
  if (mime_type == nullptr) return false;
  return strcasecmp(mime_type, "text/plain") == 0 ||
         strcasecmp(mime_type, "text/plain;charset=utf-8") == 0 ||
         strcasecmp(mime_type, "text/plain; charset=utf-8") == 0 ||
         strcasecmp(mime_type, "UTF8_STRING") == 0;
}

bool WriteAll(int fd, const std::uint8_t* bytes, std::size_t length) {
  std::size_t offset = 0;
  while (offset < length) {
    const ssize_t written = write(fd, bytes + offset, length - offset);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return false;
    offset += static_cast<std::size_t>(written);
  }
  return true;
}

int WorkerMain() {
  // wl-paste sets these for each --watch action. Only the explicitly safe
  // state and plain-text offers are eligible for a read.
  const char* state = getenv("CLIPBOARD_STATE");
  if (state == nullptr || std::strcmp(state, "data") != 0) return 0;
  if (!IsPlainTextMimeType(getenv("CLIPBOARD_TYPE"))) return 0;

  std::uint8_t text[kMaximumTextBytes + 1];
  std::size_t length = 0;
  timespec start{};
  if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) return 0;
  while (length < sizeof(text)) {
    timespec now{};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    const long elapsed_milliseconds =
        (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000;
    const long remaining_milliseconds = kReadTimeoutMilliseconds - elapsed_milliseconds;
    if (remaining_milliseconds <= 0) return 0;

    pollfd input{};
    input.fd = STDIN_FILENO;
    input.events = POLLIN | POLLHUP;
    const int ready = poll(&input, 1, static_cast<int>(remaining_milliseconds));
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0 || (input.revents & (POLLERR | POLLNVAL)) != 0) return 0;

    const ssize_t received = read(STDIN_FILENO, text + length, sizeof(text) - length);
    if (received < 0 && errno == EINTR) continue;
    if (received < 0) return 0;
    if (received == 0) break;
    length += static_cast<std::size_t>(received);
  }

  // One extra byte distinguishes an exactly-at-limit payload from a larger
  // clipboard without allocating or forwarding an unbounded value.
  if (length == 0 || length > kMaximumTextBytes) return 0;

  const std::uint8_t frame_length[] = {
      static_cast<std::uint8_t>((length >> 24) & 0xff),
      static_cast<std::uint8_t>((length >> 16) & 0xff),
      static_cast<std::uint8_t>((length >> 8) & 0xff),
      static_cast<std::uint8_t>(length & 0xff),
  };
  if (!WriteAll(STDOUT_FILENO, frame_length, sizeof(frame_length))) return 0;
  WriteAll(STDOUT_FILENO, text, length);
  return 0;
}

bool ParsePositivePid(const char* value, pid_t* pid) {
  if (value == nullptr || *value == '\0') return false;
  long parsed = 0;
  for (const char* character = value; *character != '\0'; ++character) {
    if (*character < '0' || *character > '9') return false;
    const int digit = *character - '0';
    if (parsed > (static_cast<long>(0x7fffffff) - digit) / 10) return false;
    parsed = parsed * 10 + digit;
  }
  if (parsed <= 0) return false;
  *pid = static_cast<pid_t>(parsed);
  return true;
}

int WatcherMain(const char* wl_paste, const char* helper_path) {
  if (wl_paste == nullptr || helper_path == nullptr) return 2;

  // Make the watcher and every --watch child a private process group so the
  // Flutter adapter can stop the entire tree on disable or shutdown.
  if (setsid() < 0 && !(errno == EPERM && getpgrp() == getpid())) return 2;
  char* const arguments[] = {
      const_cast<char*>(wl_paste),
      const_cast<char*>("--watch"),
      const_cast<char*>(helper_path),
      const_cast<char*>("--worker"),
      nullptr,
  };
  execv(wl_paste, arguments);
  return 127;
}

int SignalGroupMain(const char* signal_text, const char* pid_text) {
  pid_t pid = 0;
  if (!ParsePositivePid(pid_text, &pid)) return 2;

  int signal_number = 0;
  if (signal_text != nullptr && std::strcmp(signal_text, "term") == 0) {
    signal_number = SIGTERM;
  } else if (signal_text != nullptr && std::strcmp(signal_text, "kill") == 0) {
    signal_number = SIGKILL;
  } else {
    return 2;
  }

  if (kill(-pid, signal_number) == 0 || errno == ESRCH) return 0;
  return 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 2 && std::strcmp(argv[1], "--worker") == 0) return WorkerMain();
  if (argc == 4 && std::strcmp(argv[1], "--watcher") == 0) {
    return WatcherMain(argv[2], argv[3]);
  }
  if (argc == 4 && std::strcmp(argv[1], "--signal-group") == 0) {
    return SignalGroupMain(argv[2], argv[3]);
  }
  return 2;
}
