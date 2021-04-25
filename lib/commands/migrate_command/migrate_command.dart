import 'dart:io';

import 'package:dart_console/dart_console.dart';
import 'package:path/path.dart' as p;
import 'package:args/command_runner.dart';
import 'package:rush_cli/helpers/copy.dart';
import 'package:rush_cli/helpers/utils.dart';
import 'package:rush_cli/helpers/casing.dart';
import 'package:rush_cli/java/javac.dart';
import 'package:rush_cli/templates/dot_gitignore.dart';
import 'package:rush_cli/templates/iml_template.dart';
import 'package:rush_cli/templates/libs_xml.dart';
import 'package:rush_cli/templates/misc_xml.dart';
import 'package:rush_cli/templates/modules_xml.dart';
import 'package:rush_cli/templates/readme_template.dart';
import 'package:rush_cli/templates/rules_pro.dart';
import 'package:rush_prompt/rush_prompt.dart';

class MigrateCommand extends Command {
  final String _cd;
  final String _dataDir;

  MigrateCommand(this._cd, this._dataDir);

  @override
  String get description =>
      'Introspects and migrates the extension-template project in CWD to Rush.';

  @override
  String get name => 'migrate';

  @override
  void printUsage() {
    PrintArt();

    Console()
      ..setForegroundColor(ConsoleColor.cyan)
      ..write(' migrate: ')
      ..setForegroundColor(ConsoleColor.brightWhite)
      ..writeLine(description)
      ..writeLine()
      ..writeLine(' Usage: ')
      ..setForegroundColor(ConsoleColor.brightBlue)
      ..write('   rush ')
      ..setForegroundColor(ConsoleColor.cyan)
      ..write('migrate ')
      ..resetColorAttributes();
  }

  @override
  Future<void> run() async {
    final dir = Directory(p.join(_dataDir, 'cache'))..createSync();
    final outputDir = Directory(dir.path).createTempSync();

    final compStep = BuildStep('Introspecting the Java files')..init();

    final javac = Javac(_cd, _dataDir);
    await javac.compile(
      CompileType.migrate,
      compStep,
      output: outputDir,
      onDone: () {
        final genFiles = {
          'rushYml': <File>[],
          'manifest': <File>[],
        };
        for (final file in outputDir.listSync()) {
          if (file is File) {
            final fileName = p.basenameWithoutExtension(file.path);
            if (fileName.startsWith('rush-')) {
              genFiles['rushYml']?.add(file);
            } else if (fileName.startsWith('manifest-')) {
              genFiles['manifest']?.add(file);
            }
          }
        }

        if (genFiles.entries.any((el) => el.value.isEmpty)) {
          compStep
            ..logErr('No extension found')
            ..finishNotOk('Failed');

          exit(1);
        } else if (genFiles.entries.any((el) => el.value.length > 1)) {
          final extensionNames = genFiles['rushYml']?.map(
              (e) => p.basenameWithoutExtension(e.path).split('rush-').last);

          compStep.logErr('More than two extensions found');
          extensionNames?.forEach((el) {
            compStep.logErr(' ' * 2 + '- ' + el, addPrefix: false);
          });
          compStep
            ..logErr(
                'Currently, Rush doesn\'t supports multiple extensions inside one project.',
                addPrefix: false,
                addSpace: true)
            ..finishNotOk('Failed');

          exit(1);
        }

        final extName = p
            .basenameWithoutExtension(genFiles['rushYml']!.first.path)
            .split('rush-')
            .last;
        final package = Utils.getPackage(extName, p.join(_cd, 'src'));
        final projectDir =
            Directory(p.join(p.dirname(_cd), Casing.kebabCase(extName)))
              ..createSync(recursive: true);

        final rushYmlDest = p.join(projectDir.path, 'rush.yml');
        genFiles['rushYml']!.first.copySync(rushYmlDest);

        final srcDir = Directory(p.join(projectDir.path, 'src'))..createSync();
        genFiles['manifest']!
            .first
            .copySync(p.join(srcDir.path, 'AndroidManifest.xml'));

        outputDir.deleteSync(recursive: true);

        final finalStep = BuildStep('Finalizing the migration')..init();

        _copySrcFiles(package, projectDir.path, finalStep);
        _copyAssets(package, projectDir.path, finalStep);
        _copyDeps(projectDir.path, finalStep);
        _genNecessaryFiles(extName);

        finalStep.finishOk('Done');

        _printFooter(projectDir.path, Casing.kebabCase(extName), extName);
      },
      onError: () {
        Logger.log('Build failed',
            color: ConsoleColor.brightWhite,
            prefix: '\n• ',
            prefixFG: ConsoleColor.brightRed);
        exit(1);
      },
    );
  }

  /// Copies all the src files.
  /// This doesn't perform any checks, just copies everything except the assets and
  /// aiwebres directory.
  void _copySrcFiles(String package, String projectDirPath, BuildStep step) {
    final baseDir = Directory(p.joinAll([_cd, 'src', ...package.split('.')]));
    final dest =
        Directory(p.joinAll([projectDirPath, 'src', ...package.split('.')]))
          ..createSync(recursive: true);

    Copy.copyDir(baseDir, dest, ignore: [
      Directory(p.join(baseDir.path, 'assets')),
      Directory(p.join(baseDir.path, 'aiwebres')),
    ]);
    step.log('Copied source files', ConsoleColor.cyan,
        prefix: 'OK',
        prefBG: ConsoleColor.brightGreen,
        prefFG: ConsoleColor.black);
  }

  /// Copies extension assets and icon.
  void _copyAssets(String package, String projectDirPath, BuildStep step) {
    final baseDir =
        Directory(p.joinAll([_cd, 'src', ...package.split('.'), 'assets']));

    final assetsDir = Directory(p.join(baseDir.path, 'assets'));
    final assetsDest = Directory(p.join(projectDirPath, 'assets'))
      ..createSync();

    if (assetsDir.existsSync() && assetsDir.listSync().isNotEmpty) {
      Copy.copyDir(assetsDir, assetsDest);
    }

    final aiwebres = Directory(p.join(baseDir.path, 'aiwebres'));
    if (aiwebres.existsSync() && aiwebres.listSync().isNotEmpty) {
      Copy.copyDir(aiwebres, assetsDest);
    }
    step.log('Copied assets', ConsoleColor.cyan,
        prefix: 'OK',
        prefBG: ConsoleColor.brightGreen,
        prefFG: ConsoleColor.black);
  }

  /// Copies all necessary deps.
  void _copyDeps(String projectDir, BuildStep step) {
    final devDeps = Directory(p.join(_dataDir, 'dev-deps'));
    final devDepsDest = Directory(p.join(projectDir, '.rush', 'dev-deps'))
      ..createSync(recursive: true);
    Copy.copyDir(devDeps, devDepsDest);

    final deps = Directory(p.join(_cd, 'lib', 'deps'));
    final depsDest = Directory(p.join(projectDir, 'deps'))..createSync();
    if (deps.existsSync() && deps.listSync().isNotEmpty) {
      Copy.copyDir(deps, depsDest);
    } else {
      _writeFile(p.join(depsDest.path, '.placeholder'),
          'This directory stores your extension\'s depenedencies.');
    }
    step.log('Copied dependencies', ConsoleColor.cyan,
        prefix: 'OK',
        prefBG: ConsoleColor.brightGreen,
        prefFG: ConsoleColor.black);
  }

  /// Generates files like readme, proguard-rules.pro, etc.
  void _genNecessaryFiles(String extName) {
    final kebabCasedName = Casing.kebabCase(extName);
    final projectDir = p.join(p.dirname(_cd), kebabCasedName);

    _writeFile(p.join(projectDir, 'src', 'proguard-rules.pro'), getPgRules());
    _writeFile(p.join(projectDir, 'README.md'), getReadme(extName));
    _writeFile(p.join(projectDir, '.gitignore'), getDotGitignore());

    // IntelliJ IDEA files
    _writeFile(p.join(projectDir, '.idea', 'misc.xml'), getMiscXml());
    _writeFile(
        p.join(projectDir, '.idea', 'libraries', 'dev-deps.xml'), getLibsXml());
    _writeFile(p.join(projectDir, '.idea', 'modules.xml'),
        getModulesXml(kebabCasedName));
    _writeFile(p.join(projectDir, '$kebabCasedName.iml'), getIml());
  }

  /// Creates a file in [path] and writes [content] inside it.
  void _writeFile(String path, String content) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// Prints the footer.
  void _printFooter(String projectDir, String kebabCasedName, String extName) {
    Console()
      ..writeLine()
      ..setForegroundColor(ConsoleColor.green)
      ..write('• ')
      ..setForegroundColor(ConsoleColor.brightGreen)
      ..write('Success! ')
      ..setForegroundColor(ConsoleColor.brightWhite)
      ..writeLine(
          'Migrated the extension-template project in the current directory to Rush.')
      ..write('  Generated Rush project can be found here: ')
      ..setForegroundColor(ConsoleColor.cyan)
      ..writeLine(projectDir)
      ..writeLine()
      ..setForegroundColor(ConsoleColor.brightWhite)
      ..write('Next up, \n' + ' ' * 2 + '-')
      ..setForegroundColor(ConsoleColor.yellow)
      ..write(' cd ')
      ..setForegroundColor(ConsoleColor.brightWhite)
      ..write('into ')
      ..setForegroundColor(ConsoleColor.brightBlue)
      ..write('../' + kebabCasedName + '/')
      ..setForegroundColor(ConsoleColor.brightWhite)
      ..writeLine(',')
      ..write('remove all the unsupported annotations (like, @DesignerComponent, @UsesPermissions, etc) from ')
      ..setForegroundColor(ConsoleColor.brightBlue)
      ..write(extName + '.java')
      ..setForegroundColor(ConsoleColor.brightWhite)
      ..writeLine(', and')
      ..write(' ' * 2 + '- run ')
      ..setForegroundColor(ConsoleColor.brightBlue)
      ..write('rush build ')
      ..setForegroundColor(ConsoleColor.brightWhite)
      ..writeLine('to compile your extension.')
      ..resetColorAttributes();
  }
}
