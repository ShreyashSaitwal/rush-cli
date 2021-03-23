import 'dart:io';

import 'package:path/path.dart' as p;

/// Generate arguments for the Ant exec.
class AntArgs {
  final String? dataDirPath;
  final String cd;
  final String? org;
  final String version;
  final String? name;
  final bool? shouldJetify;
  final bool? optimize;

  AntArgs(
    this.dataDirPath,
    this.cd,
    this.org,
    this.version,
    this.name,
    this.shouldJetify,
    this.optimize,
  );

  List toList(String task) {
    final args = <String>[];
    final workspaces = p.join(dataDirPath!, 'workspaces');
    final baseDir = p.dirname(p.dirname(Platform.script.path));

    args.add('-buildfile=${p.joinAll([
      ...baseDir.split('/'),
      'tools',
      'apache-ant-1.10.9',
      'build.xml'
    ])}');
    args.add('-DantCon=${p.joinAll([
      ...baseDir.split('/'),
      'tools',
      'ant-contrib',
      'ant-contrib-1.0b3.jar'
    ])}');

    if (task == 'javac') {
      args.add('javac');
      args.add('-Dclasses=${p.join(workspaces, org, 'classes')}');
      args.add('-DextSrc=${p.join(cd, 'src')}');
      args.add('-Droot=$cd');
      args.add('-DextName=$name');
      args.add('-Dorg=$org');
      args.add('-Dversion=$version');
      args.add('-DdevDeps=${p.join(cd, '.rush', 'dev-deps')}');
      args.add('-Ddeps=${p.join(cd, 'deps')}');
      args.add('-Dprocessor=${p.joinAll([
        ...baseDir.split('/'),
        'tools',
        'processor'
      ])}');
    } else if (task == 'process') {
      args.add('jarExt');
      args.add('-Dprocessor=${p.joinAll([
        ...baseDir.split('/'),
        'tools',
        'processor'
      ])}');
      args.add('-Dclasses=${p.join(workspaces, org, 'classes')}');
      args.add('-Draw=${p.join(workspaces, org, 'raw')}');
      args.add('-DrawCls=${p.join(workspaces, org, 'raw-classes')}');
      args.add('-DdevDeps=${p.join(cd, '.rush', 'dev-deps')}');
      args.add('-Ddeps=${p.join(cd, 'deps')}');
      args.add('-Dextension=$org');
      args.add('-Dcd=$cd');
      if (optimize!) {
        final rules = File(p.join(cd, 'src', 'proguard-rules.pro'));
        if (rules.existsSync()) {
          args.add('-Doptimize=1');
          args.add('-DpgPath=${p.joinAll([
            ...baseDir.split('/'),
            'tools',
            'proguard'
          ])}');
          args.add('-DpgRules=${rules.path}');
          args.add('-Dout=${p.join(cd, 'out')}');
        }
      }
      if (shouldJetify!) {
        args.add('-DjetifierBin=${p.joinAll([
          ...baseDir.split('/'),
          'tools',
          'jetifier-standalone',
          'bin'
        ])}');
      } else {
        args.add('-DjetifierBin=0');
      }
    } else if (task == 'dex') {
      args.add('dexExt');
      args.add('-Dextension=$org');
      args.add('-Dd8=${p.joinAll([...baseDir.split('/'), 'tools', 'd8.jar'])}');
      args.add('-Draw=${p.join(workspaces, org, 'raw')}');
      args.add('-DrawCls=${p.join(workspaces, org, 'raw-classes')}');
      if (shouldJetify!) {
        args.add('-DjetifierBin=1');
      } else {
        args.add('-DjetifierBin=0');
      }
    } else if (task == 'assemble') {
      args.add('assemble');
      args.add('-DdevDeps=${p.join(cd, '.rush', 'dev-deps')}');
      args.add('-Dout=${p.join(cd, 'out')}');
      args.add('-Dextension=$org');
      args.add('-Draw=${p.join(workspaces, org, 'raw')}');
    }

    return args;
  }
}
