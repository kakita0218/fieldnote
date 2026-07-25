import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/project_summary.dart';

/// Stores the user-visible project as ordinary files in the app's Documents
/// directory. On iOS this directory is exposed as "On My iPad/FieldNote".
///
/// The unannotated PDF used by the editor stays in Application Support. The
/// visible PDF is regenerated from it so FieldNote annotations never reduce
/// the quality of the source pages.
class ProjectFileStore {
  static const int _schemaVersion = 1;
  static const String _manifestSuffix = '_案件情報.json';
  static const String _photosDirectoryName = '写真';

  static final Map<String, Directory> _projectDirectories =
      <String, Directory>{};

  static bool get isAuthoritative => true;

  static Future<Directory> _documentsDirectory() =>
      getApplicationDocumentsDirectory();

  static Future<Directory> _sourceDirectory() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory directory = Directory(
      '${support.path}${Platform.pathSeparator}FieldNote'
      '${Platform.pathSeparator}SourcePdfs',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static String _safeName(String value, {String fallback = '名称未設定'}) {
    String result = value
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (result.isEmpty) result = fallback;
    return result;
  }

  static String _manifestName(String projectName) =>
      '${_safeName(projectName)}$_manifestSuffix';

  static String _pdfName(String projectName) => '${_safeName(projectName)}.pdf';

  static String _threeDigits(int value) => value.toString().padLeft(3, '0');

  static Future<File?> _manifestFile(Directory directory) async {
    File? backup;
    await for (final FileSystemEntity entity
        in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith(_manifestSuffix)) {
        return entity;
      }
      if (entity is File && entity.path.endsWith('$_manifestSuffix.bak')) {
        backup = entity;
      }
    }
    if (backup != null) {
      final File target = File(
        backup.path.substring(0, backup.path.length - '.bak'.length),
      );
      await _recoverAtomicFile(target);
      if (await target.exists()) return target;
    }
    return null;
  }

  static Future<void> _recoverAtomicFile(File target) async {
    final File backup = File('${target.path}.bak');
    if (!await target.exists() && await backup.exists()) {
      await backup.rename(target.path);
    } else if (await target.exists() && await backup.exists()) {
      await backup.delete();
    }
  }

  static Future<void> _writeBytesAtomically(
    File target,
    Uint8List bytes,
  ) async {
    await target.parent.create(recursive: true);
    await _recoverAtomicFile(target);
    final String nonce = DateTime.now().microsecondsSinceEpoch.toString();
    final File temporary = File('${target.path}.tmp-$nonce');
    final File backup = File('${target.path}.bak');
    await temporary.writeAsBytes(bytes, flush: true);

    if (await target.exists()) {
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
    }

    try {
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<void> _writeJsonAtomically(
    File target,
    Map<String, dynamic> value,
  ) =>
      _writeBytesAtomically(
        target,
        Uint8List.fromList(
          utf8.encode(
            const JsonEncoder.withIndent('  ').convert(value),
          ),
        ),
      );

  static Future<Map<String, dynamic>?> _readManifest(
    Directory directory,
  ) async {
    final File? manifest = await _manifestFile(directory);
    if (manifest == null) return null;
    await _recoverAtomicFile(manifest);
    try {
      final dynamic decoded = jsonDecode(await manifest.readAsString());
      if (decoded is Map) {
        return decoded.map<String, dynamic>(
          (dynamic key, dynamic value) =>
              MapEntry<String, dynamic>(key.toString(), value),
        );
      }
    } catch (_) {
      final File backup = File('${manifest.path}.bak');
      if (await backup.exists()) {
        try {
          final dynamic decoded = jsonDecode(await backup.readAsString());
          if (decoded is Map) {
            return decoded.map<String, dynamic>(
              (dynamic key, dynamic value) =>
                  MapEntry<String, dynamic>(key.toString(), value),
            );
          }
        } catch (_) {}
      }
    }
    return null;
  }

  static Future<Directory?> _findProjectDirectory(String projectId) async {
    final Directory? cached = _projectDirectories[projectId];
    if (cached != null && await cached.exists()) return cached;

    final Directory root = await _documentsDirectory();
    if (!await root.exists()) return null;
    await for (final FileSystemEntity entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final Map<String, dynamic>? manifest = await _readManifest(entity);
      if (manifest?['projectId']?.toString() == projectId) {
        _projectDirectories[projectId] = entity;
        return entity;
      }
    }
    return null;
  }

  static Future<Directory> _createProjectDirectory({
    required String projectId,
    required String projectName,
  }) async {
    final Directory? existing = await _findProjectDirectory(projectId);
    if (existing != null) return existing;

    final Directory root = await _documentsDirectory();
    await root.create(recursive: true);
    final String baseName = _safeName(projectName);
    String candidate = baseName;
    int suffix = 2;
    Directory directory = Directory(
      '${root.path}${Platform.pathSeparator}$candidate',
    );
    while (await directory.exists()) {
      candidate = '${baseName}_$suffix';
      suffix++;
      directory = Directory(
        '${root.path}${Platform.pathSeparator}$candidate',
      );
    }
    await directory.create(recursive: true);
    _projectDirectories[projectId] = directory;
    return directory;
  }

  static Future<File> _sourcePdfFile(String projectId) async {
    final Directory directory = await _sourceDirectory();
    final File source = File(
      '${directory.path}${Platform.pathSeparator}'
      '${_safeName(projectId, fallback: 'project')}.pdf',
    );
    await _recoverAtomicFile(source);
    return source;
  }

  static Future<File?> _outputPdfFile(String projectId) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory == null) return null;
    final Map<String, dynamic>? manifest = await _readManifest(directory);
    final String name = manifest?['projectName']?.toString() ??
        directory.uri.pathSegments
            .where((String segment) => segment.isNotEmpty)
            .last;
    final File output = File(
      '${directory.path}${Platform.pathSeparator}${_pdfName(name)}',
    );
    await _recoverAtomicFile(output);
    return output;
  }

  static Future<List<ProjectSummary>> listProjects() async {
    final Directory root = await _documentsDirectory();
    if (!await root.exists()) return const <ProjectSummary>[];

    final List<ProjectSummary> projects = <ProjectSummary>[];
    await for (final FileSystemEntity entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final Map<String, dynamic>? manifest = await _readManifest(entity);
      if (manifest == null) continue;
      final String id = manifest['projectId']?.toString() ?? '';
      if (id.isEmpty) continue;
      _projectDirectories[id] = entity;
      projects.add(
        ProjectSummary(
          id: id,
          name: manifest['projectName']?.toString() ?? '名称未設定',
          updatedAt:
              DateTime.tryParse(manifest['updatedAt']?.toString() ?? '') ??
                  DateTime.fromMillisecondsSinceEpoch(0),
          pageCount: (manifest['pageCount'] as num?)?.toInt() ?? 0,
          photoCount: (manifest['photos'] as List?)?.length ?? 0,
          pinCount: (manifest['pins'] as List?)?.length ?? 0,
        ),
      );
    }
    projects.sort(
      (ProjectSummary a, ProjectSummary b) =>
          b.updatedAt.compareTo(a.updatedAt),
    );
    return projects;
  }

  static Future<void> createProject({
    required String projectId,
    required String projectName,
  }) async {
    final Directory directory = await _createProjectDirectory(
      projectId: projectId,
      projectName: projectName,
    );
    final File? existingManifest = await _manifestFile(directory);
    if (existingManifest != null) return;
    await _writeJsonAtomically(
      File(
        '${directory.path}${Platform.pathSeparator}'
        '${_manifestName(projectName)}',
      ),
      <String, dynamic>{
        'schemaVersion': _schemaVersion,
        'projectId': projectId,
        'projectName': projectName,
        'pdfName': _pdfName(projectName),
        'updatedAt': DateTime.now().toIso8601String(),
        'pageCount': 0,
        'pins': <dynamic>[],
        'strokes': <dynamic>[],
        'photos': <dynamic>[],
      },
    );
  }

  static Future<Map<String, dynamic>?> loadProject(String projectId) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory == null) return null;
    final Map<String, dynamic>? manifest = await _readManifest(directory);
    if (manifest == null) return null;

    final File source = await _sourcePdfFile(projectId);
    final File? output = await _outputPdfFile(projectId);
    final File? readablePdf = await source.exists()
        ? source
        : output != null && await output.exists()
            ? output
            : null;
    if (readablePdf == null) return null;

    return <String, dynamic>{
      ...manifest,
      'pdfBytes': Uint8List.fromList(await readablePdf.readAsBytes()),
      'photoMeta': await _photoMetadataFromManifest(
        directory,
        manifest,
      ),
    };
  }

  static Future<void> saveOriginalPdf({
    required String projectId,
    required String projectName,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) throw StateError('PDFデータが空です。');
    final Directory directory = await _createProjectDirectory(
      projectId: projectId,
      projectName: projectName,
    );
    final File source = await _sourcePdfFile(projectId);
    final File output = File(
      '${directory.path}${Platform.pathSeparator}${_pdfName(projectName)}',
    );
    for (final String suffix in <String>[
      '.pencilkit',
      '.pencilkit.pending',
    ]) {
      final File sidecar = File('${source.path}$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }
    await _writeBytesAtomically(source, bytes);
    await _writeBytesAtomically(output, bytes);

    final File? existingManifest = await _manifestFile(directory);
    final Map<String, dynamic> manifest =
        await _readManifest(directory) ?? <String, dynamic>{};
    manifest
      ..['schemaVersion'] = _schemaVersion
      ..['projectId'] = projectId
      ..['projectName'] = projectName
      ..['pdfName'] = _pdfName(projectName)
      ..['updatedAt'] = DateTime.now().toIso8601String()
      ..putIfAbsent('pins', () => <dynamic>[])
      ..putIfAbsent('strokes', () => <dynamic>[])
      ..putIfAbsent('photos', () => <dynamic>[]);
    final File target = existingManifest ??
        File(
          '${directory.path}${Platform.pathSeparator}'
          '${_manifestName(projectName)}',
        );
    await _writeJsonAtomically(target, manifest);
  }

  static Future<void> _reconcilePhotoDirectories({
    required Directory directory,
    required Map<String, dynamic> oldManifest,
    required List<Map<String, dynamic>> newPins,
  }) async {
    final Directory photos = Directory(
      '${directory.path}${Platform.pathSeparator}$_photosDirectoryName',
    );
    if (!await photos.exists()) return;

    final Map<String, int> oldNumbers = <String, int>{
      for (final dynamic raw
          in oldManifest['pins'] as List? ?? const <dynamic>[])
        if (raw is Map && raw['id'] != null && raw['number'] is num)
          raw['id'].toString(): (raw['number'] as num).toInt(),
    };
    final Map<String, int> newNumbers = <String, int>{
      for (final Map<String, dynamic> pin in newPins)
        if (pin['id'] != null && pin['number'] is num)
          pin['id'].toString(): (pin['number'] as num).toInt(),
    };

    final Map<String, Directory> staged = <String, Directory>{};
    for (final MapEntry<String, int> entry in oldNumbers.entries) {
      final int? newNumber = newNumbers[entry.key];
      if (newNumber == null || newNumber == entry.value) continue;
      final Directory current = Directory(
        '${photos.path}${Platform.pathSeparator}${_threeDigits(entry.value)}',
      );
      final Directory temporary = Directory(
        '${photos.path}${Platform.pathSeparator}.moving-${entry.key}',
      );
      if (await temporary.exists()) {
        // A previous save was interrupted after staging this folder.
        staged[entry.key] = temporary;
        continue;
      }
      if (!await current.exists()) continue;
      staged[entry.key] = await current.rename(temporary.path);
    }

    for (final MapEntry<String, Directory> entry in staged.entries) {
      final int? number = newNumbers[entry.key];
      if (number == null) {
        await entry.value.delete(recursive: true);
        continue;
      }
      final Directory destination = Directory(
        '${photos.path}${Platform.pathSeparator}${_threeDigits(number)}',
      );
      if (await destination.exists()) {
        await destination.delete(recursive: true);
      }
      await entry.value.rename(destination.path);
    }
  }

  static Future<void> saveSnapshot({
    required String projectId,
    required String projectName,
    required Map<String, dynamic> metadata,
    required List<Map<String, dynamic>> pins,
    required List<Map<String, dynamic>> strokes,
    required List<Map<String, dynamic>> photos,
  }) async {
    final Directory directory = await _createProjectDirectory(
      projectId: projectId,
      projectName: projectName,
    );
    final Map<String, dynamic> oldManifest =
        await _readManifest(directory) ?? <String, dynamic>{};
    await _reconcilePhotoDirectories(
      directory: directory,
      oldManifest: oldManifest,
      newPins: pins,
    );

    final Map<String, dynamic> manifest = <String, dynamic>{
      ...oldManifest,
      ...metadata,
      'schemaVersion': _schemaVersion,
      'projectId': projectId,
      'projectName': projectName,
      'pdfName': _pdfName(projectName),
      'updatedAt': DateTime.now().toIso8601String(),
      'pins': pins,
      'strokes': strokes,
      'photos': photos,
    };
    final File? oldFile = await _manifestFile(directory);
    final File target = File(
      '${directory.path}${Platform.pathSeparator}${_manifestName(projectName)}',
    );
    await _writeJsonAtomically(target, manifest);
    if (oldFile != null &&
        oldFile.path != target.path &&
        await oldFile.exists()) {
      await oldFile.delete();
    }
  }

  static Future<void> savePhoto({
    required String projectId,
    required String projectName,
    required String pinId,
    required int pinNumber,
    required String photoId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final Directory directory = await _createProjectDirectory(
      projectId: projectId,
      projectName: projectName,
    );
    final Directory photos = Directory(
      '${directory.path}${Platform.pathSeparator}$_photosDirectoryName'
      '${Platform.pathSeparator}${_threeDigits(pinNumber)}',
    );
    await photos.create(recursive: true);
    final File photo = File(
      '${photos.path}${Platform.pathSeparator}${_safeName(fileName)}',
    );
    await _writeBytesAtomically(photo, bytes);

    final Map<String, dynamic> manifest =
        await _readManifest(directory) ?? <String, dynamic>{};
    final List<dynamic> records =
        List<dynamic>.from(manifest['photos'] as List? ?? const <dynamic>[]);
    records.removeWhere(
      (dynamic value) => value is Map && value['photoId'] == photoId,
    );
    records.add(<String, dynamic>{
      'projectId': projectId,
      'pinId': pinId,
      'pinNumber': pinNumber,
      'photoId': photoId,
      'fileName': fileName,
      'createdAt': DateTime.now().toIso8601String(),
      'byteLength': bytes.length,
    });
    manifest
      ..putIfAbsent('schemaVersion', () => _schemaVersion)
      ..putIfAbsent('projectId', () => projectId)
      ..putIfAbsent('projectName', () => projectName)
      ..putIfAbsent('pdfName', () => _pdfName(projectName))
      ..putIfAbsent('pins', () => <dynamic>[])
      ..putIfAbsent('strokes', () => <dynamic>[])
      ..['photos'] = records
      ..['updatedAt'] = DateTime.now().toIso8601String();
    final File target = await _manifestFile(directory) ??
        File(
          '${directory.path}${Platform.pathSeparator}'
          '${_manifestName(projectName)}',
        );
    await _writeJsonAtomically(target, manifest);
  }

  static Future<List<Map<String, dynamic>>> _photoMetadataFromManifest(
    Directory directory,
    Map<String, dynamic> manifest,
  ) async {
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    final Map<String, Map<String, dynamic>> byFile =
        <String, Map<String, dynamic>>{};
    for (final dynamic raw
        in manifest['photos'] as List? ?? const <dynamic>[]) {
      if (raw is! Map) continue;
      final Map<String, dynamic> record = raw.map<String, dynamic>(
        (dynamic key, dynamic value) =>
            MapEntry<String, dynamic>(key.toString(), value),
      );
      final int? number = (record['pinNumber'] as num?)?.toInt();
      final String fileName = record['fileName']?.toString() ?? '';
      if (number != null && fileName.isNotEmpty) {
        byFile['${_threeDigits(number)}/$fileName'] = record;
      }
    }

    final Map<int, String> pinIds = <int, String>{
      for (final dynamic raw in manifest['pins'] as List? ?? const <dynamic>[])
        if (raw is Map && raw['number'] is num && raw['id'] != null)
          (raw['number'] as num).toInt(): raw['id'].toString(),
    };
    final Directory photos = Directory(
      '${directory.path}${Platform.pathSeparator}$_photosDirectoryName',
    );
    if (!await photos.exists()) return result;

    await for (final FileSystemEntity folder
        in photos.list(followLinks: false)) {
      if (folder is! Directory) continue;
      final String folderName =
          folder.uri.pathSegments.where((String e) => e.isNotEmpty).last;
      final int? pinNumber = int.tryParse(folderName);
      if (pinNumber == null) continue;
      final Set<String> seenPhotoPaths = <String>{};
      await for (final FileSystemEntity entity
          in folder.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        File photo = entity;
        final String lowerPath = photo.path.toLowerCase();
        if (lowerPath.endsWith('.jpg.bak')) {
          photo = File(
            photo.path.substring(0, photo.path.length - '.bak'.length),
          );
          await _recoverAtomicFile(photo);
        }
        if (!photo.path.toLowerCase().endsWith('.jpg') ||
            !await photo.exists() ||
            !seenPhotoPaths.add(photo.path)) {
          continue;
        }
        final String fileName =
            photo.uri.pathSegments.where((String e) => e.isNotEmpty).last;
        final String key = '$folderName/$fileName';
        final Map<String, dynamic> stored = byFile[key] ??
            <String, dynamic>{
              'projectId': manifest['projectId'],
              'pinId': pinIds[pinNumber] ?? '',
              'pinNumber': pinNumber,
              'photoId': '${pinIds[pinNumber] ?? pinNumber}::$fileName',
              'fileName': fileName,
              'createdAt': (await photo.stat()).modified.toIso8601String(),
            };
        result.add(stored);
      }
    }
    result.sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) =>
          (a['createdAt']?.toString() ?? '')
              .compareTo(b['createdAt']?.toString() ?? ''),
    );
    return result;
  }

  static Future<List<Map<String, dynamic>>?> loadPhotoMetadata(
    String projectId,
  ) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory == null) return null;
    final Map<String, dynamic>? manifest = await _readManifest(directory);
    if (manifest == null) return null;
    return _photoMetadataFromManifest(directory, manifest);
  }

  static Future<List<Map<String, dynamic>>?> loadPhotosForPin({
    required String projectId,
    required String pinId,
  }) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory == null) return null;
    final Map<String, dynamic>? manifest = await _readManifest(directory);
    if (manifest == null) return null;
    final List<Map<String, dynamic>> metadata =
        await _photoMetadataFromManifest(directory, manifest);
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> record in metadata) {
      if (record['pinId']?.toString() != pinId) continue;
      final int? pinNumber = (record['pinNumber'] as num?)?.toInt();
      if (pinNumber == null) continue;
      final File file = File(
        '${directory.path}${Platform.pathSeparator}$_photosDirectoryName'
        '${Platform.pathSeparator}${_threeDigits(pinNumber)}'
        '${Platform.pathSeparator}${record['fileName']}',
      );
      if (!await file.exists()) continue;
      result.add(<String, dynamic>{
        ...record,
        'bytes': Uint8List.fromList(await file.readAsBytes()),
      });
    }
    return result;
  }

  static Future<List<Map<String, dynamic>>?> loadAllPhotos(
    String projectId,
  ) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory == null) return null;
    final Map<String, dynamic>? manifest = await _readManifest(directory);
    if (manifest == null) return null;
    final List<Map<String, dynamic>> metadata =
        await _photoMetadataFromManifest(directory, manifest);
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> record in metadata) {
      final int? pinNumber = (record['pinNumber'] as num?)?.toInt();
      if (pinNumber == null) continue;
      final File file = File(
        '${directory.path}${Platform.pathSeparator}$_photosDirectoryName'
        '${Platform.pathSeparator}${_threeDigits(pinNumber)}'
        '${Platform.pathSeparator}${record['fileName']}',
      );
      if (await file.exists()) {
        result.add(<String, dynamic>{
          ...record,
          'bytes': Uint8List.fromList(await file.readAsBytes()),
        });
      }
    }
    return result;
  }

  static Future<void> deletePhotosForPin({
    required String projectId,
    required String pinId,
  }) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory == null) return;
    final Map<String, dynamic>? manifest = await _readManifest(directory);
    if (manifest == null) return;
    final Map<String, dynamic>? pin =
        (manifest['pins'] as List? ?? const <dynamic>[])
            .whereType<Map>()
            .map(
              (Map<dynamic, dynamic> value) => value.map<String, dynamic>(
                (dynamic key, dynamic value) =>
                    MapEntry<String, dynamic>(key.toString(), value),
              ),
            )
            .cast<Map<String, dynamic>?>()
            .firstWhere(
              (Map<String, dynamic>? value) =>
                  value?['id']?.toString() == pinId,
              orElse: () => null,
            );
    final int? number = (pin?['number'] as num?)?.toInt();
    if (number != null) {
      final Directory photos = Directory(
        '${directory.path}${Platform.pathSeparator}$_photosDirectoryName'
        '${Platform.pathSeparator}${_threeDigits(number)}',
      );
      if (await photos.exists()) await photos.delete(recursive: true);
    }
    final List<dynamic> records =
        List<dynamic>.from(manifest['photos'] as List? ?? const <dynamic>[])
          ..removeWhere(
            (dynamic value) => value is Map && value['pinId'] == pinId,
          );
    manifest
      ..['photos'] = records
      ..['updatedAt'] = DateTime.now().toIso8601String();
    final File? target = await _manifestFile(directory);
    if (target != null) await _writeJsonAtomically(target, manifest);
  }

  static Future<void> renameProject(
    String projectId,
    String newName,
  ) async {
    final Directory? oldDirectory = await _findProjectDirectory(projectId);
    if (oldDirectory == null) return;
    final Map<String, dynamic>? manifest = await _readManifest(oldDirectory);
    if (manifest == null) return;
    final String oldName = manifest['projectName']?.toString() ?? '';
    final File? oldManifest = await _manifestFile(oldDirectory);
    final File oldPdf = File(
      '${oldDirectory.path}${Platform.pathSeparator}${_pdfName(oldName)}',
    );

    final Directory root = await _documentsDirectory();
    final String base = _safeName(newName);
    String candidate = base;
    int suffix = 2;
    Directory destination = Directory(
      '${root.path}${Platform.pathSeparator}$candidate',
    );
    while (
        destination.path != oldDirectory.path && await destination.exists()) {
      candidate = '${base}_$suffix';
      suffix++;
      destination = Directory(
        '${root.path}${Platform.pathSeparator}$candidate',
      );
    }

    manifest
      ..['projectName'] = newName
      ..['pdfName'] = _pdfName(newName)
      ..['updatedAt'] = DateTime.now().toIso8601String();
    final File newManifest = File(
      '${oldDirectory.path}${Platform.pathSeparator}${_manifestName(newName)}',
    );
    await _writeJsonAtomically(newManifest, manifest);
    if (oldManifest != null &&
        oldManifest.path != newManifest.path &&
        await oldManifest.exists()) {
      await oldManifest.delete();
    }
    final File newPdf = File(
      '${oldDirectory.path}${Platform.pathSeparator}${_pdfName(newName)}',
    );
    if (oldPdf.path != newPdf.path && await oldPdf.exists()) {
      if (await newPdf.exists()) await newPdf.delete();
      await oldPdf.rename(newPdf.path);
    }
    final Directory renamed = destination.path == oldDirectory.path
        ? oldDirectory
        : await oldDirectory.rename(destination.path);
    _projectDirectories[projectId] = renamed;
  }

  static Future<void> deleteProject(String projectId) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
    final File source = await _sourcePdfFile(projectId);
    if (await source.exists()) await source.delete();
    for (final String suffix in <String>[
      '.pencilkit',
      '.pencilkit.pending',
    ]) {
      final File sidecar = File('${source.path}$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }
    _projectDirectories.remove(projectId);
  }

  static Future<String?> sourcePdfPath(String projectId) async {
    final File source = await _sourcePdfFile(projectId);
    return await source.exists() ? source.path : null;
  }

  static Future<String?> outputPdfPath(String projectId) async {
    final File? output = await _outputPdfFile(projectId);
    return output?.path;
  }

  static Future<Uint8List?> loadOutputPdf(String projectId) async {
    final File? output = await _outputPdfFile(projectId);
    if (output == null || !await output.exists()) return null;
    return Uint8List.fromList(await output.readAsBytes());
  }
}
