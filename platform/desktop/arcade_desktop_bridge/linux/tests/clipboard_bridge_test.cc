#include "../clipboard_bridge.cc"

#include <cassert>

int main() {
  auto read = std::make_shared<ReadSnapshot>();
  AddTargets(read, {"UTF8_STRING", "text/plain", "text/html", "image/png", "text/uri-list"});
  assert(read->targets.size() == 4);
  assert(read->targets.front().second == "text/plain");

  auto sensitive = std::make_shared<ReadSnapshot>();
  AddTargets(sensitive, {"text/plain", "x-kde-passwordManagerHint"});
  assert(sensitive->sensitive && sensitive->targets.empty());

  const std::string uris = "file:///home/example/a%20b.txt\r\nhttps://example.com/private\r\nfile://other-host/home/secret\r\n";
  g_autoptr(FlValue) snapshot = Snapshot({{"text/plain", {'h', 'i'}},
      {"text/html", {'<', 'b', '>', 'h', 'i', '<', '/', 'b', '>'}},
      {"text/uri-list", std::vector<uint8_t>(uris.begin(), uris.end())}}, false);
  FlValue* formats = fl_value_lookup_string(snapshot, "formats");
  FlValue* files = fl_value_lookup_string(snapshot, "files");
  assert(fl_value_get_length(formats) == 2);
  assert(fl_value_get_length(files) == 1);
  assert(std::string(fl_value_get_string(fl_value_get_list_value(files, 0))) == "/home/example/a b.txt");

  GMainLoop* loop = g_main_loop_new(nullptr, FALSE);
  bool bounded = false;
  ReadCommand({"python3", "-c", "import sys;sys.stdout.buffer.write(b'x'*131072)"}, 4096,
      [&](bool success, std::vector<uint8_t> output) {
        assert(!success && output.size() <= 4096);
        bounded = true;
        g_main_loop_quit(loop);
      });
  g_main_loop_run(loop);
  assert(bounded);

  bool timed_out = false;
  const gint64 start = g_get_monotonic_time();
  ReadCommand({"python3", "-c", "import time;time.sleep(10)"}, 4096,
      [&](bool success, std::vector<uint8_t>) {
        assert(!success);
        timed_out = true;
        g_main_loop_quit(loop);
      });
  g_main_loop_run(loop);
  assert(timed_out && g_get_monotonic_time() - start < 4000000);
  g_main_loop_unref(loop);
  return 0;
}
