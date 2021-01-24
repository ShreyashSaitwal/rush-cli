import 'dart:io';

import 'package:dart_console/dart_console.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:rush_cli/commands/build_command/ant_args.dart';
import 'package:rush_cli/javac_errors/err_data.dart';

import 'package:rush_cli/mixins/app_data_dir_mixin.dart';
import 'package:rush_cli/mixins/copy_mixin.dart';
import 'package:rush_cli/mixins/get_rush_yaml.dart';
import 'package:rush_prompt/rush_prompt.dart';

class BuildCommand with AppDataMixin, CopyMixin {
  final String _currentDir;
  final String _extType;
  final bool _isProd;

  BuildCommand(this._currentDir, this._extType, this._isProd);

  /// Builds the extension in the current directory
  Future<void> run() async {
    final rushYml = GetRushYaml.data(_currentDir);
    final dataDir = AppDataMixin.dataStorageDir();

    final manifestFile = File(p.join(_currentDir, 'AndroidManifest.xml'));
    if (!manifestFile.existsSync()) {
      ThrowError(
          message:
              'ERR: Unable to find AndroidManifest.xml file in this project.');
    }

    var ymlLastMod = GetRushYaml.file(_currentDir).lastModifiedSync();
    var manifestLastMod = manifestFile.lastModifiedSync();

    var extBox = await Hive.openBox(rushYml['name']);
    if (!extBox.containsKey('version')) {
      await extBox.putAll({
        'version': 1,
      });
    } else if (!extBox.containsKey('rushYmlMod')) {
      await extBox.putAll({
        'rushYmlMod': ymlLastMod,
      });
    } else if (!extBox.containsKey('manifestMod')) {
      await extBox.putAll({
        'manifestMod': manifestLastMod,
      });
    }

    // TODO:
    // Delete the build dir if there are any changes in the
    // rush.yml or Android Manifest file.

    // if (ymlLastMod.isAfter(extBox.get('rushYmlMod')) ||
    //     manifestLastMod.isAfter(extBox.get('manifestMod'))) {
    //   _cleanBuildDir(dataDir);
    // }

    // Increment version number if this is a production build
    if (_isProd) {
      var version = extBox.get('version') + 1;
      await extBox.put('version', version);
    }

    // Args for spawning the Apache Ant process
    final args = AntArgs(dataDir, _currentDir, _extType,
        extBox.get('version').toString(), rushYml['name']);

    final console = Console();
    var count = 0;

    final pathToAntEx = p.join(dataDir, 'tools', 'apache-ant', 'bin', 'ant');
    // Run the Apache Ant executable
    Process.start(pathToAntEx, args.toList(), runInShell: Platform.isWindows)
        .asStream()
        .asBroadcastStream()
        .listen((process) {
      // Listen to the stream of stdout
      process.stdout.asBroadcastStream().listen((data) {
        // data is in decimal form, we need to format it.
        final formatted = _format(data);

        // formatted is a list of output messages.
        // Go through each of them, and it's the start of error, part of error, or
        // something else (simple output).
        for (final out in formatted) {
          final lines = ErrData.getNoOfLines(out);

          // If lines is the not null then it means that out is infact the first
          // line of the error.
          if (lines != null) {
            count = lines - 1;
            console
              ..writeLine()
              ..setBackgroundColor(ConsoleColor.red)
              ..setForegroundColor(ConsoleColor.brightWhite)
              ..write('\tERR')
              ..resetColorAttributes()
              ..setForegroundColor(ConsoleColor.red)
              ..writeErrorLine(' src' + out.split('src')[1]);
          } else if (count > 0) {
            // If count is greater than 0, then it means that out is remaining part
            // of the previously identified error.
            count--;
            console.writeErrorLine('\t' + out);
          } else {
            // If none of the above conditions are true, out is not an error.
            console
              ..resetColorAttributes()
              ..writeLine(out);
          }
        }
      });
    });
  }

  /// Converts the given list of decimal char codes into string list and removes
  /// empty lines from it.
  List<String> _format(List<int> charcodes) {
    final stringified = String.fromCharCodes(charcodes);
    final List res = <String>[];
    stringified.split('\r\n').forEach((el) {
      if ('$el'.trim().isNotEmpty) {
        res.add(el.trimRight().replaceAll('[javac]', ''));
      }
    });
    return res;
  }

  void _cleanBuildDir(String dataDir) {
    var buildDir = Directory(p.join(dataDir, 'workspaces', _extType));
    try {
      buildDir.deleteSync(recursive: true);
    } catch (e) {
      ThrowError(
          message:
              'ERR: Something went wrong while invalidating build caches.');
    }
  }
}
