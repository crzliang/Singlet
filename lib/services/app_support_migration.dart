import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// One-shot copy from legacy `com.sbg.sbg` Application Support → Singlet.
class AppSupportMigration {
  AppSupportMigration._();

  static const legacyFolderName = 'com.sbg.sbg';
  static const markerName = '.migrated-from-legacy-sbg';

  /// If the new support dir looks unused and the legacy dir exists, copy it.
  static Future<void> migrateIfNeeded() async {
    if (!Platform.isMacOS) return;
    try {
      final neu = await getApplicationSupportDirectory();
      final marker = File('${neu.path}/$markerName');
      if (await marker.exists()) return;

      if (await File('${neu.path}/app-settings.json').exists()) {
        await marker.writeAsString('skipped-existing\n');
        return;
      }

      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return;
      final legacy =
          Directory('$home/Library/Application Support/$legacyFolderName');
      if (!await legacy.exists()) {
        await marker.writeAsString('no-legacy\n');
        return;
      }

      await neu.create(recursive: true);
      await for (final entity in legacy.list(recursive: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.isEmpty || name.startsWith('.')) continue;
        final destPath = '${neu.path}/$name';
        if (entity is Directory) {
          await _copyDir(entity, Directory(destPath));
        } else if (entity is File) {
          await entity.copy(destPath);
        }
      }
      await marker.writeAsString(
        'ok ${DateTime.now().toUtc().toIso8601String()}\n',
      );
    } catch (_) {
      // Best-effort; first launch should not fail because of migration.
    }
  }

  static Future<void> _copyDir(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final entity in src.list(recursive: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.isEmpty) continue;
      final out = '${dest.path}/$name';
      if (entity is Directory) {
        await _copyDir(entity, Directory(out));
      } else if (entity is File) {
        await entity.copy(out);
      }
    }
  }
}
