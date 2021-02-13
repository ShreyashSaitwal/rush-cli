import 'dart:io' show Directory, File, exit;

import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:dart_casing/dart_casing.dart';
import 'package:dart_console/dart_console.dart';
import 'package:rush_cli/commands/new_command/questions.dart';
import 'package:rush_cli/mixins/app_data_dir_mixin.dart';
import 'package:rush_cli/mixins/copy_mixin.dart';
import 'package:rush_cli/mixins/download_mixin.dart';
import 'package:rush_cli/templates/android_manifest.dart';
import 'package:rush_cli/templates/dot_gitignore.dart';
import 'package:rush_cli/templates/readme.dart';

import 'package:rush_prompt/rush_prompt.dart';
import 'package:rush_cli/templates/rush_yaml_template.dart';
import 'package:rush_cli/templates/extension_template.dart';

class NewCommand with DownloadMixin, AppDataMixin, CopyMixin {
  final String _cd;

  NewCommand(this._cd);

  /// Creates a new extension project in the current directory.
  Future<void> run() async {
    await _checkPackage();

    final answers = RushPrompt(questions: Questions.questions).askAll();
    final name = answers[0][1].toString().trim();
    final orgName = answers[1][1].toString().trim();
    final authorName = answers[2][1].toString().trim();
    final versionName = answers[3][1].toString().trim();

    final isOrgAndNameSame = orgName.split('.').last == Casing.camelCase(name);
    var package;
    if (isOrgAndNameSame) {
      package = orgName;
    } else {
      package = orgName + '.' + Casing.camelCase(name);
    }

    final extPath =
        p.joinAll([_cd, Casing.camelCase(name), 'src', ...package.split('.')]);

    // Creates the required files for the extension.
    try {
      _writeFile(
          p.join(extPath, '${Casing.pascalCase(name)}.java'),
          getExtensionTemp(
            Casing.pascalCase(name),
            package,
          ));

      _writeFile(p.join(_cd, Casing.camelCase(name), 'rush.yml'),
          getRushYaml(name, versionName, authorName));

      _writeFile(
          p.join(_cd, Casing.camelCase(name), '.gitignore'), getDotGitignore());

      _writeFile(
          p.join(_cd, Casing.camelCase(name), 'README.md'), getReadme(name));

      _writeFile(
          p.join(_cd, Casing.camelCase(name), 'src', 'AndroidManifest.xml'),
          getManifestXml(orgName));

      _writeFile(
          p.join(_cd, Casing.camelCase(name), 'deps', '.placeholder'), '');
    } catch (e) {
      ThrowError(message: 'ERR ' + e.toString());
    }

    try {
      Directory(p.join(_cd, Casing.camelCase(name), '.rush', 'dev_deps'))
          .createSync(recursive: true);

      Directory(p.join(_cd, Casing.camelCase(name), 'assets'))
          .createSync(recursive: true);

      Directory(p.join(_cd, Casing.camelCase(name), '.rush'))
          .createSync(recursive: true);
    } catch (e) {
      ThrowError(message: 'ERR ' + e.toString());
    }

    Hive.init(p.join(_cd, Casing.camelCase(name), '.rush'));
    var box = await Hive.openBox('data');
    await box.putAll({
      'version': 1,
      'org': package,
      'rushYmlLastMod': DateTime.now(),
      'srcDirLastMod': DateTime.now(),
    });

    // Dir where all the dev dependencies live in cache form.
    final devDepsDirPath = p.join(AppDataMixin.dataStorageDir(), 'dev-deps');

    // Copy the dev-deps from the cache.
    copyDir(Directory(devDepsDirPath),
        Directory(p.join(_cd, Casing.camelCase(name), '.rush', 'dev_deps')));

    exit(0);
  }

  void _writeFile(String path, String content) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  Future<void> _checkPackage() async {
    // Dir where Rush stores all the data.
    final dataDir = Directory(AppDataMixin.dataStorageDir());

    if (!dataDir.existsSync() || dataDir.listSync().isEmpty) {
      Console().writeLine('''
Rush needs to download some additional files (total download size: 40.81 MB) to function properly.
This is a one-time process, and Rush won\'t ask you to download these files again (unless there is a necessary update in one or more of them).''');

      final continueProcess =
          BoolQuestion(id: 'continue', question: 'Do you want to continue?')
              .ask()[1];

      if (!continueProcess) {
        exit(0);
      }

      try {
        dataDir.createSync(recursive: true);
      } catch (e) {
        ThrowError(message: e);
      }

      await _downloadPackage();
      await _extractPackage();
    }
  }

  /// Downloads the required packages.
  void _downloadPackage() async {
    // HACK#1: Writing new line in the console because the progress bar shifts
    // up when intialized. Can be fixed, but you know, I'm too lazy.
    Console().writeLine();
    final progress = ProgressBar('Downloading packages...');

    const url =
        'https://firebasestorage.googleapis.com/v0/b/rush-cli.appspot.com/o/package.zip?alt=media&token=d7f929e3-8c67-4982-9c45-1ab7e5c1e936';

    await download(progress, url, AppDataMixin.dataStorageDir());
  }

  /// Extracts the package
  void _extractPackage() {
    final packageZip =
        File(p.join(AppDataMixin.dataStorageDir(), 'packages.zip'));

    if (!packageZip.existsSync()) {
      ThrowError(message: 'Unable to extract packages. Aborting...');
    }

    final bytes = packageZip.readAsBytesSync();
    final zip = ZipDecoder().decodeBytes(bytes).files;
    final total = zip.length;

    // See HACK#1
    Console().writeLine();
    final progress = ProgressBar('Extracting packages...');
    progress.totalProgress = total;

    for (var i = 0; i < zip.length; i++) {
      progress.update(i + 1);
      if (zip[i].isFile) {
        final data = zip[i].content;
        try {
          File(p.join(AppDataMixin.dataStorageDir(), zip[i].name))
            ..createSync(recursive: true)
            ..writeAsBytesSync(data);
        } catch (e) {
          ThrowError(message: e);
        }
      }
    }

    packageZip.deleteSync();
  }
}
