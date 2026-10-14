import 'package:arcade_desktop_bridge/arcade_desktop_bridge.dart';

import 'core_api.dart';

bool isHeadlessCommand(List<String> arguments, {required bool isMacOS}) =>
    arguments.any(const {
      '--version',
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
