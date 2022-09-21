import 'dart:io';

import 'package:collection/collection.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:rush_cli/src/resolver/artifact.dart';
import 'package:rush_cli/src/resolver/pom.dart';
import 'package:rush_cli/src/services/logger.dart';
import 'package:rush_cli/src/utils/file_extension.dart';

class _ArtifactMetadata {
  late final String groupId;
  late final String artifactId;
  late final String version;
  late final String classifier;

  _ArtifactMetadata(String coordinate) {
    final parts = coordinate.split(':');
    if (parts.length > 4 || parts.length < 3) {
      throw Exception(
          'Invalid artifact coordinate format: $coordinate\nExpected format: <groupId>:<artifactId>:<version> or <groupId>:<artifactId>:<version>:<classifier>');
    }
    groupId = parts[0];
    artifactId = parts[1];
    version = parts[2];
    if (parts.length == 4) {
      classifier = parts[3];
    } else {
      classifier = '';
    }
  }

  String _basePath() =>
      p.joinAll([...groupId.split('.'), artifactId, version]).replaceAll(
          '\\', '/');

  String pomPath() =>
      p.join(_basePath(), '$artifactId-$version.pom').replaceAll('\\', '/');

  String artifactPath(String packaging) => p
      .join(_basePath(),
          '$artifactId-$version${classifier.isNotEmpty ? '-$classifier' : ''}.$packaging')
      .replaceAll('\\', '/');

  String sourceJarPath() => p
      .join(_basePath(), '$artifactId-$version-sources.jar')
      .replaceAll('\\', '/');
}

class ArtifactResolver {
  final defaultRepos = <String>{
    'https://dl.google.com/dl/android/maven2',
    'https://repo.maven.apache.org/maven2',
    // JCenter is deprecated but one of the AI2 provided dep, org.webrtc.google-webrtc.1.0.23995,
    // is hosted there, so, we add it.
    'https://jcenter.bintray.com',
  };
  final _lgr = GetIt.I<Logger>();

  late final String cacheDir;

  ArtifactResolver({String? cacheDir, required Iterable<String> repos}) {
    if (cacheDir != null) {
      this.cacheDir = cacheDir;
    } else if (Platform.isWindows) {
      this.cacheDir =
          p.join(Platform.environment['UserProfile']!, '.m2').asDir(true).path;
    } else {
      this.cacheDir =
          p.join(Platform.environment['HOME']!, '.m2').asDir(true).path;
    }
    defaultRepos.addAll(repos);
  }

  Future<File> _fetchFile(String relativePath) async {
    final file = p.join(cacheDir, relativePath).asFile();
    if (file.existsSync()) return file;

    _lgr.dbg('${file.path} does not exist, downloading...');
    await file.create(recursive: true);

    for (final repo in defaultRepos) {
      final uri = Uri.parse('$repo/$relativePath');
      try {
        final response = await http.get(uri);
        // TODO: Handle other response codes when implementing logging.
        if (response.statusCode == 200) {
          await file.writeAsBytes(response.bodyBytes, flush: true);
          return file;
        }
        continue;
      } catch (e) {
        _lgr.dbg(e.toString());
      }
    }

    await file.delete();
    throw Exception('Unable to fetch $relativePath');
  }

  /// For details on how this (roughly) works:
  /// https://maven.apache.org/guides/introduction/introduction-to-the-pom.html#project-interpolation-and-variables
  Version _resolveCoordVersion(
    String coordinate,
    Pom dependentPom,
    Iterable<Pom> dependentPomsParentPoms,
  ) {
    final metadata = _ArtifactMetadata(coordinate);

    var version = metadata.version == 'null' ? null : metadata.version;
    final exception = Exception(
        'Couldn\'t resolve dependency ($coordinate) of artifact ${dependentPom.coordinate}');

    // If the version is defined in a range, pick the upper endpoint if it is
    // upper bounded otherwise pick the lower endpoint for now.
    if (version != null && Version.rangeRegex.hasMatch(version)) {
      final range = Version.from(version).range;
      if (!range!.upperBounded) {
        return Version.from(range.lower!.toString(), originalVersion: version);
      }
      return Version.from(range.upper!.toString(), originalVersion: version);
    }

    // If the version is null, then it should be stored in the [pom] or [parentPom]
    // as a implicit value or as variable.
    version ??= dependentPom.dependencyManagement
        // First, check for this dependency in the same POM's dependencyManagement section.
        .firstWhere(
      (el) =>
          el.artifactId == metadata.artifactId &&
          el.groupId == metadata.groupId,
      // If not found, check in the all parent POM's dependencyManagement section.
      orElse: () {
        if (dependentPomsParentPoms.isEmpty) {
          throw exception;
        }
        return dependentPomsParentPoms
            .map((el) => el.dependencyManagement)
            .flattened
            .firstWhere(
          (el) {
            return el.groupId == metadata.groupId &&
                (el.artifactId == metadata.artifactId ||
                    el.artifactId == '${metadata.artifactId}-bom');
          },
          // If still not found, throw an exception.
          orElse: () {
            throw exception;
          },
        );
      },
    ).version!;

    // The below implementation of varible interpolation isn't (probably?) the
    // most correct way to do this, but (I think) should work most of the times.
    // Quote from Maven documentation:
    // "One factor to note is that these variables are processed after inheritance
    //  [...]. This means that if a parent project uses a variable, then its
    //  definition in the child, not the parent, will be the one eventually used."
    // So, maybe, FIXME?

    // If the version is a variable, it will be defined as ${variable}. This variable
    // could be a property or a POM field (we only handle project.version field).
    if (version.startsWith('\${')) {
      final variable = version.substring(2, version.length - 1);

      // TODO: Extract this and the similar groupId interpolation stuff in
      // [resolveArtifact] method to a separate method.
      final projectField = ['project.version', 'pom.version', '.version'];
      if (projectField.contains(variable)) {
        return Version.from(dependentPom.version!);
      }

      // When the variable is a POM property.
      final properties = dependentPom.properties;
      for (final el in dependentPomsParentPoms) {
        properties.addAll(el.properties);
      }

      if (properties.containsKey(variable)) {
        return Version.from(properties[variable]!.toString());
      } else {
        throw exception;
      }
    }

    // Version is likely a normal version literal.
    return Version.from(version);
  }

  Future<Iterable<Pom>> _resolvePomAndParents(String? coordinate) async {
    if (coordinate == null) {
      return const [];
    }

    final metadata = _ArtifactMetadata(coordinate);
    final pomFile = await _fetchFile(metadata.pomPath());
    final pom = Pom.fromXml(pomFile.readAsStringSync());

    pom.groupId ??= metadata.groupId;
    pom.version ??= metadata.version;

    final parentPoms = await _resolvePomAndParents(pom.parent?.coordinate);

    final imports = List.of(pom.dependencyManagement
        .whereNot((el) => el.coordinate.contains('+'))
        .where((el) => el.scope == Scope.import.name));
    await Future.wait(imports.map((i) async {
      i.version =
          _resolveCoordVersion(i.coordinate, pom, parentPoms).toString();
      final impPoms = await _resolvePomAndParents(i.coordinate);
      final impDeps = impPoms.map((e) => e.dependencyManagement).flattened;
      pom.dependencyManagement
        ..remove(i)
        ..addAll(impDeps);
    }));

    return [pom, ...parentPoms];
  }

  /// Resolve the [coordinate] artifact along with its dependencies.
  /// This is how the resolution works:
  /// 1. We fetch the POM of the artifact.
  /// 2. We resolve the artifact's parent if it has one.
  /// 3. If the version or group ID in the artifact's POM is null, we inherit
  ///     it from the parent. If the parent is also null, it's an error.
  /// 4. It is a common practice in Maven world to define dependencies in the
  ///     the artifact's or its parent's POM's dependencyManagement section,
  ///     and then only define their groupId and artifactId in the dependencies
  ///     section. We then need to resolve (in Maven's lingo, "interpolate")
  ///     these dependencies' versions from there.
  /// 4.1 It is also possible that the version is a variable. This variable could
  ///     be:
  ///     - defined in the artifact's or its parent's POM's properties section,
  ///     - a POM field reference (prefixed with 'project.', 'pom.' or '.'),
  ///     - or a special variable ('project.baseDir', 'project.baseUri', or
  ///       'maven.build.timestamp').
  ///     However, we don't handle special variables.
  /// 5. After the versions of the dependencies are resolved, we resolve them
  ///     and their dependencies (and so on) recursively.
  /// 6. Finally, we wrap this nicely in an [Artifact] and return.
  Future<List<Artifact>> resolveArtifact(
    String coordinate,
    Scope scope, [
    Version? version,
  ]) async {
    final metadata = _ArtifactMetadata(coordinate);
    final poms = await _resolvePomAndParents(coordinate);
    final pom = poms.first;
    final parentPoms = poms.skip(1);

    // Resolve the transitive parents.
    if (pom.parent != null) {
      pom.version ??= parentPoms.first.version;
      pom.groupId ??= parentPoms.first.groupId;
      _lgr.dbg(
          '${pom.coordinate} pom.version: ${pom.version}; pom.groupId: ${pom.groupId}');
    }

    if (pom.version == null || pom.groupId == null) {
      throw Exception(
          'Artifact ${pom.coordinate} doesn\'t have a valid POM file (missing groupId and/or version)');
    }

    final deps = pom.dependencies
        // Older gradle versions allowed use of `+` in the version spec. Maven
        // doesn't support this, and Gradle also probably dropped support for it,
        // but there are still some projects, including one of the build lib's
        // transitive dependency, that use this. Ideally, we should handle this,
        // but for now, we just ignore these dependencies.
        // Related issue: https://github.com/gradle/gradle/issues/1232
        .whereNot((dep) => dep.coordinate.contains('+'))
        .whereNot((dep) => dep.optional ?? false)
        .where((dep) {
      if (scope == Scope.compile) {
        return dep.scope == Scope.compile.name;
      } else if (scope == Scope.runtime) {
        return dep.scope == Scope.runtime.name ||
            dep.scope == Scope.compile.name;
      }
      return false;
    });
    _lgr.dbg(
        '$coordinate: Total ${pom.dependencies.length} deps defined; ${deps.length} selected');

    final result = <Artifact>[];
    for (final dep in deps) {
      final projectField = ['project.groupId', 'pom.groupId', '.groupId'];
      if (projectField
          .contains(dep.groupId.substring(2, dep.groupId.length - 1))) {
        dep.groupId = pom.groupId!;
      }

      final resolvedVersion =
          _resolveCoordVersion(dep.coordinate, pom, parentPoms);
      final versionChanged =
          resolvedVersion.toString() != resolvedVersion.originalVersionSpec;
      if (versionChanged) {
        _lgr.dbg('Changed version: ${dep.version} -> $resolvedVersion');
      }

      dep.version = resolvedVersion.toString();
      result.addAll(await resolveArtifact(
          dep.coordinate,
          dep.scope.toScope(),
          // Only pass the version object if the original version spec is different
          // than the spec used to resolved the artifact. This can happen in only
          // one case and that is when the original spec was a version range.
          versionChanged ? resolvedVersion : null));
    }

    if (version != null) {
      final newCoordinate =
          [...coordinate.split(':').take(2), version.toString()].join(':');
      _lgr.dbg('Changed coord: $coordinate -> $newCoordinate');
      coordinate = newCoordinate;
    }

    _lgr.info('Resolved $coordinate and its dependencies');
    return result
      ..insert(
        0,
        Artifact(
          coordinate: coordinate,
          scope: scope,
          artifactFile: p.join(cacheDir, metadata.artifactPath(pom.packaging)),
          sourceJar: p.join(cacheDir, metadata.sourceJarPath()),
          dependencies: deps.map((el) => el.coordinate).toList(growable: true),
          isAar: pom.packaging == 'aar',
        ),
      );
  }

  Future<void> downloadArtifact(Artifact artifact) async {
    final metadata = _ArtifactMetadata(artifact.coordinate);
    await _fetchFile(metadata.artifactPath(artifact.isAar ? 'aar' : 'jar'));
  }

  Future<void> downloadSourceJar(Artifact artifact) async {
    final metadata = _ArtifactMetadata(artifact.coordinate);
    try {
      await _fetchFile(metadata.sourceJarPath());
    } catch (_) {
      _lgr.warn('Could not resolve source JAR for ${artifact.coordinate}');
    }
  }
}
