import 'dart:io' show Directory, File;

import 'package:path/path.dart' as p;
import 'package:rush_cli/commands/build/models/rush_lock/rush_lock.dart';
import 'package:rush_cli/commands/build/models/rush_yaml/rush_yaml.dart';
import 'package:rush_cli/services/file_service.dart';
import 'package:rush_cli/utils/dir_utils.dart';
import 'package:rush_cli/version.dart';
import 'package:rush_prompt/rush_prompt.dart';

class Generator {
  final FileService _fs;
  final RushYaml _rushYaml;

  Generator(this._fs, this._rushYaml);

  /// Generates required extension files.
  Future<void> generate(BuildStep step, RushLock? rushLock) async {
    await Future.wait([
      _generateInfoFiles(step),
      _copyAssets(step),
      _copyLicense(),
    ]);
  }

  /// Generates the components info, build, and the properties file.
  Future<void> _generateInfoFiles(BuildStep step) async {
    step.log(LogType.info, 'Attaching component descriptors');

    final filesDirPath = p.join(_fs.buildDir, 'files');
    final rawDir = Directory(p.join(_fs.buildDir, 'raw'));
    await rawDir.create(recursive: true);

    // Copy the components.json file to the raw dir.
    await File(p.join(filesDirPath, 'components.json'))
        .copy(p.join(rawDir.path, 'components.json'));

    // Copy the component_build_infos.json file to the raw dir.
    final rawFilesDir = Directory(p.join(rawDir.path, 'files'));
    await rawFilesDir.create(recursive: true);
    await File(p.join(filesDirPath, 'component_build_infos.json'))
        .copy(p.join(rawFilesDir.path, 'component_build_infos.json'));

    // Write the extension.properties file
    await File(p.join(rawDir.path, 'extension.properties'))
        .writeAsString('type=external\nrush-version=$rushVersion');
  }

  /// Copies extension's assets to the raw directory.
  Future<void> _copyAssets(BuildStep step) async {
    final assets = _rushYaml.assets ?? [];

    if (assets.isNotEmpty) {
      step.log(LogType.info, 'Bundling assets');

      final assetsDir = p.join(_fs.cwd, 'assets');
      final assetsDestDir = Directory(p.join(_fs.buildDir, 'raw', 'assets'));
      await assetsDestDir.create(recursive: true);

      for (final el in assets) {
        final asset = File(p.join(assetsDir, el));

        if (await asset.exists()) {
          await asset.copy(p.join(assetsDestDir.path, el));
        } else {
          step.log(LogType.warn,
              'Unable to find asset "${p.basename(el)}"; skipped.');
        }
      }
    }

    // If the icons are not URLs, the annotation processor copies them to the
    // files/aiwebres dir. Check if that dir exists, if it does, copy the icon
    // files from there.
    final aiwebres = Directory(p.join(_fs.buildDir, 'files', 'aiwebres'));
    if (await aiwebres.exists()) {
      final dest = Directory(p.join(_fs.buildDir, 'raw', 'aiwebres'));
      await dest.create(recursive: true);

      DirUtils.copyDir(aiwebres, dest);
      await aiwebres.delete(recursive: true);
    }
  }

  /// Copies LICENSE file if there's any.
  Future<void> _copyLicense() async {
    // Pattern to match URL
    final urlPattern = RegExp(
        r'https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()!@:%_\+.~#?&\/\/=]*)',
        dotAll: true);

    final File license;
    if (_rushYaml.license != null && !urlPattern.hasMatch(_rushYaml.license!)) {
      license = File(p.join(_fs.cwd, _rushYaml.license));
    } else {
      return;
    }

    final dest = Directory(p.join(_fs.buildDir, 'raw', 'aiwebres'));
    await dest.create(recursive: true);

    if (license.existsSync()) {
      await license.copy(p.join(dest.path, 'LICENSE'));
    }
  }
}
