import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Clipboard's settings. On the desktop they are `settings.json` in Link's
/// config folder (`~/.config/arcade/clipboard/`, STANDARD §10); on phones,
/// and until [useFile] is called (tests), they stay in SharedPreferences.
/// What [useArcadeFolders] found: the data folder, and the older folders it
/// moved or had to leave in place (for the log).
typedef ArcadeFolders = ({
  Directory data,
  List<String> moved,
  List<String> kept
});

/// On the desktop, moves the folders an older version used into Link's
/// (`app_dirs` asks the core, which copies, verifies, then removes) and keeps
/// settings in `settings.json` in the new config folder. [override] is
/// `ARCADE_DATA_DIR` (development profiles and isolated tests): data and
/// settings both live there and nothing moves. Null on phones.
Future<ArcadeFolders?> useArcadeFolders(
    Future<Map<String, dynamic>?> Function() appDirs,
    {String override = ''}) async {
  if (!(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    return null;
  }
  if (override.isNotEmpty) {
    final data = Directory(override);
    await AppSettings.useFile(File('${data.path}/settings.json'),
        legacy: File('${data.path}/shared_preferences.json'));
    return (data: data, moved: const <String>[], kept: const <String>[]);
  }
  final dirs = await appDirs();
  if (dirs == null) return null;
  final data = Directory(dirs['data'] as String);
  final config = Directory(dirs['config'] as String);
  await AppSettings.useFile(
    File('${config.path}/settings.json'),
    // Linux and Windows kept Flutter's preferences in the data folder that
    // just moved; macOS kept them in the user defaults of the old bundle id.
    legacy:
        Platform.isMacOS ? null : File('${data.path}/shared_preferences.json'),
    legacyValues: Platform.isMacOS ? _macosDefaults : null,
  );
  return (
    data: data,
    moved: [
      for (final m in (dirs['moved'] as List? ?? const []))
        '${m['from']} → ${m['to']}'
    ],
    kept: [
      for (final k in (dirs['kept'] as List? ?? const []))
        '${k['from']}: ${k['reason']}'
    ],
  );
}

/// The preferences Clipboard 0.2 and earlier kept under `dev.arcade.clipboard`.
Future<Map<String, Object?>> _macosDefaults() async {
  final home = Platform.environment['HOME'];
  if (home == null) return const {};
  final plist = File('$home/Library/Preferences/dev.arcade.clipboard.plist');
  if (!await plist.exists()) return const {};
  try {
    final result = await Process.run(
        '/usr/bin/plutil', ['-convert', 'json', '-o', '-', plist.path]);
    final decoded =
        result.exitCode == 0 ? jsonDecode('${result.stdout}') : null;
    return decoded is Map<String, Object?> ? decoded : const {};
  } on Object {
    return const {};
  }
}

abstract class AppSettings {
  static Future<AppSettings>? _instance;

  static Future<AppSettings> instance() =>
      _instance ?? SharedPreferences.getInstance().then(_Preferences.new);

  /// Keeps settings in [file]. The first time, imports what an older
  /// version left in Flutter's preferences ([legacy], a
  /// `shared_preferences.json`, or [legacyValues] on macOS), verifies the new
  /// file and only then removes the old one.
  static Future<AppSettings> useFile(File file,
      {File? legacy, Future<Map<String, Object?>> Function()? legacyValues}) {
    return _instance =
        _JsonFile.open(file, legacy: legacy, legacyValues: legacyValues);
  }

  bool containsKey(String key);
  bool? getBool(String key);
  String? getString(String key);
  List<String>? getStringList(String key);
  Future<void> setBool(String key, bool value);
  Future<void> setString(String key, String value);
  Future<void> setStringList(String key, List<String> value);
}

class _Preferences extends AppSettings {
  _Preferences(this._prefs);

  final SharedPreferences _prefs;

  @override
  bool containsKey(String key) => _prefs.containsKey(key);
  @override
  bool? getBool(String key) => _prefs.getBool(key);
  @override
  String? getString(String key) => _prefs.getString(key);
  @override
  List<String>? getStringList(String key) => _prefs.getStringList(key);
  @override
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);
  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
  @override
  Future<void> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);
}

class _JsonFile extends AppSettings {
  _JsonFile(this._file, this._values);

  final File _file;
  final Map<String, Object?> _values;
  Future<void> _writing = Future.value();

  static Future<AppSettings> open(File file,
      {File? legacy,
      Future<Map<String, Object?>> Function()? legacyValues}) async {
    if (await file.exists()) {
      return _JsonFile(file, await _read(file));
    }
    // Flutter stores keys as "flutter.<key>".
    var imported = <String, Object?>{};
    if (legacy != null && await legacy.exists()) {
      imported = await _read(legacy);
    } else if (legacyValues != null) {
      imported = await legacyValues();
    }
    final values = <String, Object?>{
      for (final MapEntry(:key, :value) in imported.entries)
        if (key.startsWith('flutter.')) key.substring('flutter.'.length): value,
    };
    final settings = _JsonFile(file, values);
    await settings._write();
    final written = await _read(file);
    if (legacy != null &&
        jsonEncode(written) == jsonEncode(values) &&
        await legacy.exists()) {
      await legacy.delete();
    }
    return settings;
  }

  static Future<Map<String, Object?>> _read(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
    } on FormatException {
      // A damaged file starts over rather than stopping the app.
      return <String, Object?>{};
    }
  }

  /// Writes atomically (a temporary file renamed over the old one), one
  /// write at a time.
  Future<void> _write() => _writing = _writing.then((_) async {
        await _file.parent.create(recursive: true);
        final temporary = File('${_file.path}.tmp');
        await temporary.writeAsString(
            const JsonEncoder.withIndent('  ').convert(_values),
            flush: true);
        await temporary.rename(_file.path);
      });

  Future<void> _set(String key, Object value) {
    _values[key] = value;
    return _write();
  }

  @override
  bool containsKey(String key) => _values.containsKey(key);
  @override
  bool? getBool(String key) =>
      _values[key] is bool ? _values[key] as bool : null;
  @override
  String? getString(String key) =>
      _values[key] is String ? _values[key] as String : null;
  @override
  List<String>? getStringList(String key) => _values[key] is List
      ? (_values[key] as List).whereType<String>().toList()
      : null;
  @override
  Future<void> setBool(String key, bool value) => _set(key, value);
  @override
  Future<void> setString(String key, String value) => _set(key, value);
  @override
  Future<void> setStringList(String key, List<String> value) =>
      _set(key, value);
}
