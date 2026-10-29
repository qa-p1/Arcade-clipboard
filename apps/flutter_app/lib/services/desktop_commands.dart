import 'package:arcade_desktop_bridge/arcade_desktop_bridge.dart';

import 'core_api.dart';

bool isHeadlessCommand(List<String> arguments, {required bool isMacOS}) =>
    arguments.any(const {
      '--version',
      '--help',
      '-h',
      '--status',
      '--restart',
      '--arcade-manifest',
      '--quit',
      '--integration-status',
    }.contains) ||
    (isMacOS &&
        arguments.any(const {'--install', '--uninstall', '--repair'}.contains));

/// These commands run before the resident app opens its profile or window.
Future<Map<String, dynamic>> runMacosInstallCommand(
  List<String> arguments, {
  required CoreApi core,
  required ArcadeDesktopBridge bridge,
}) async {
  if (arguments.contains('--install')) {
    String? channel;
    final index = arguments.indexOf('--channel');
    if (index >= 0) {
      if (index + 1 >= arguments.length ||
          !const {'stable', 'nightly'}.contains(arguments[index + 1])) {
        throw const FormatException('--channel must be stable or nightly');
      }
      channel = arguments[index + 1];
    }
    return core.invoke('install_move', {
      'install_cli': true,
      if (channel != null) 'channel': channel,
    });
  }
  if (arguments.contains('--uninstall')) {
    final removeData = arguments.contains('--remove-data');
    if (!arguments.contains('--silent') &&
        !await bridge.confirmUninstall(removeData)) {
      return {'uninstalled': false, 'cancelled': true};
    }
    if (await bridge.launchAtLoginEnabled()) {
      await bridge.setLaunchAtLogin(false);
    }
    return core.invoke('install_uninstall', {'remove_data': removeData});
  }
  if (arguments.contains('--repair')) return core.invoke('install_repair');
  throw const FormatException('Unknown installation command');
}

/// `--help` on Windows and macOS (the Linux runner prints its own copy).
const desktopUsage = '''Usage: arcade-clipboard [OPTION]

  --show              Show the window of the running instance, or start the app
  --hide              Hide the window of the running instance
  --toggle            Show or hide the window
  --overlay           Open the picker in the running instance, or start the app and open it
  --settings          Open Settings in the running instance, or start the app and open it
  --background        Start without showing the window (Launch at login)
  --status            Print one line of JSON: version, whether it runs, Link state
  --restart           Restart the running instance
  --quit              Quit the running instance
  --version           Print the version
  --install, --uninstall [--remove-data], --repair, --integration-status
                      Manage the installation (macOS; Windows uses the installer)
  --arcade-manifest   Print the Arcade Link manifest
  -h, --help          Print this help
''';

/// What a second launch asks the running instance over the Link (Windows,
/// macOS and Linux development profiles; a unique Linux instance forwards
/// natively). Null means nothing to send: a login start (`--background`)
/// never pops a window.
({String method, Map<String, Object?> params})? runningInstanceRequest(
    List<String> arguments) {
  if (arguments.contains('--overlay')) {
    return (method: 'app.menu.invoke', params: {'id': 'cli.overlay'});
  }
  if (arguments.contains('--hide')) {
    return (method: 'app.menu.invoke', params: {'id': 'cli.hide'});
  }
  if (arguments.contains('--toggle')) {
    return (method: 'app.menu.invoke', params: {'id': 'cli.toggle'});
  }
  if (arguments.contains('--settings')) {
    return (method: 'app.settings', params: const {});
  }
  if (arguments.contains('--background')) return null;
  return (method: 'app.activate', params: const {});
}
