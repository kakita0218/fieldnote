import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/project_summary.dart';
import 'native_project_service.dart';

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
  static const String _recoveryDirectoryName = '.fieldnote-recovery';
  static const String _recoverySourcePdfName = 'source.pdf';
  static const String _migrationDirectoryPrefix = '.fieldnote-migration-';
  static const String _migrationBackupPrefix = '.fieldnote-migration-backup-';
  static const String _movingPhotoDirectoryPrefix = '.moving-';
  static const List<String> _pencilKitSuffixes = <String>[
    '.pencilkit',
    '.pencilkit.pending',
  ];

  static final Map<String, Directory> _projectDirectories =
      <String, Directory>{};
  static final Set<String> _stagingRecoveryProjectIds = <String>{};

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

  static String _migrationProjectToken(String projectId) =>
      base64Url.encode(utf8.encode(projectId)).replaceAll('=', '');

  static String _entityName(FileSystemEntity entity) => entity.uri.pathSegments
      .where((String segment) => segment.isNotEmpty)
      .last;

  static bool _isInternalProjectDirectory(Directory directory) {
    final String name = _entityName(directory);
    return name.startsWith(_migrationDirectoryPrefix) ||
        name.startsWith(_migrationBackupPrefix);
  }

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

  static Future<void> _copyFileAtomically(File source, File target) async {
    await target.parent.create(recursive: true);
    await _recoverAtomicFile(target);
    final String nonce = DateTime.now().microsecondsSinceEpoch.toString();
    final File temporary = File('${target.path}.tmp-$nonce');
    final File backup = File('${target.path}.bak');

    try {
      await source.copy(temporary.path);
      if (await target.exists()) {
        if (await backup.exists()) await backup.delete();
        await target.rename(backup.path);
      }
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

  static Future<String> _availablePhotoFileName(
    Directory directory,
    String requestedName,
  ) async {
    final String safeRequested = _safeName(
      requestedName,
      fallback: '001.jpg',
    );
    final RegExp numberedJpeg = RegExp(r'^(\d+)\.jpg$', caseSensitive: false);
    final Set<String> existingNames = <String>{};
    int maximumNumber = 0;
    if (await directory.exists()) {
      await for (final FileSystemEntity entity
          in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        String name = _entityName(entity);
        if (name.toLowerCase().endsWith('.jpg.bak')) {
          final File target = File(
            entity.path.substring(0, entity.path.length - '.bak'.length),
          );
          await _recoverAtomicFile(target);
          if (!await target.exists()) continue;
          name = _entityName(target);
        }
        existingNames.add(name.toLowerCase());
        final RegExpMatch? match = numberedJpeg.firstMatch(name);
        final int? number = int.tryParse(match?.group(1) ?? '');
        if (number != null && number > maximumNumber) maximumNumber = number;
      }
    }

    final RegExpMatch? requestedMatch = numberedJpeg.firstMatch(safeRequested);
    if (requestedMatch != null) {
      final String digits = requestedMatch.group(1)!;
      final int requestedNumber = int.parse(digits);
      int candidateNumber =
          requestedNumber > maximumNumber ? requestedNumber : maximumNumber + 1;
      final int width = digits.length < 3 ? 3 : digits.length;
      String candidate =
          '${candidateNumber.toString().padLeft(width, '0')}.jpg';
      while (existingNames.contains(candidate.toLowerCase())) {
        candidateNumber++;
        candidate = '${candidateNumber.toString().padLeft(width, '0')}.jpg';
      }
      return candidate;
    }

    if (!existingNames.contains(safeRequested.toLowerCase())) {
      return safeRequested;
    }
    final int dot = safeRequested.lastIndexOf('.');
    final String stem =
        dot > 0 ? safeRequested.substring(0, dot) : safeRequested;
    final String extension = dot > 0 ? safeRequested.substring(dot) : '';
    int suffix = 2;
    String candidate = '${stem}_$suffix$extension';
    while (existingNames.contains(candidate.toLowerCase())) {
      suffix++;
      candidate = '${stem}_$suffix$extension';
    }
    return candidate;
  }

  static Future<void> _mergePhotoDirectoryWithoutOverwrite({
    required Directory source,
    required Directory destination,
  }) async {
    await destination.create(recursive: true);
    final List<FileSystemEntity> entries =
        await source.list(followLinks: false).toList();
    for (final FileSystemEntity entity in entries) {
      if (entity is File) {
        final String originalName = _entityName(entity);
        if (originalName.contains('.tmp-')) continue;
        final String targetName = await _availablePhotoFileName(
          destination,
          originalName,
        );
        await entity.rename(
          '${destination.path}${Platform.pathSeparator}$targetName',
        );
      }
    }
    if (await source.exists()) await source.delete(recursive: true);
  }

  static Future<void> _recoverStagedPhotoDirectories({
    required Directory projectDirectory,
    required Map<String, dynamic> manifest,
  }) async {
    final Directory photos = Directory(
      '${projectDirectory.path}${Platform.pathSeparator}'
      '$_photosDirectoryName',
    );
    if (!await photos.exists()) return;
    final Map<String, int> pinNumbers = <String, int>{
      for (final dynamic raw in manifest['pins'] as List? ?? const <dynamic>[])
        if (raw is Map && raw['id'] != null && raw['number'] is num)
          raw['id'].toString(): (raw['number'] as num).toInt(),
    };
    await for (final FileSystemEntity entity
        in photos.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final String name = _entityName(entity);
      if (!name.startsWith(_movingPhotoDirectoryPrefix)) continue;
      final String pinId = name.substring(_movingPhotoDirectoryPrefix.length);
      final int? pinNumber = pinNumbers[pinId];
      // A removed pin may still be redoable in the current editor session.
      // Keep its staged folder until a manifest containing that pin returns.
      if (pinNumber == null) continue;
      final Directory destination = Directory(
        '${photos.path}${Platform.pathSeparator}${_threeDigits(pinNumber)}',
      );
      if (await destination.exists()) {
        await _mergePhotoDirectoryWithoutOverwrite(
          source: entity,
          destination: destination,
        );
      } else {
        await entity.rename(destination.path);
      }
    }
  }

  static Future<void> _cleanupMigrationArtifacts(
    Directory root,
    String projectId,
  ) async {
    if (!await root.exists()) return;
    final String token = _migrationProjectToken(projectId);
    final List<String> prefixes = <String>[
      '$_migrationDirectoryPrefix$token-',
      '$_migrationBackupPrefix$token-',
    ];
    await for (final FileSystemEntity entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final String name = _entityName(entity);
      if (!prefixes.any(name.startsWith)) continue;
      try {
        await entity.delete(recursive: true);
      } catch (_) {
        // A later completed migration can retry stale artifact cleanup.
      }
    }
  }

  static Future<Directory?> _findProjectDirectory(String projectId) async {
    final Directory? cached = _projectDirectories[projectId];
    if (cached != null && await cached.exists()) {
      try {
        final Map<String, dynamic>? manifest = await _readManifest(cached);
        if (manifest?['projectId']?.toString() == projectId) {
          await _recoverStagedPhotoDirectories(
            projectDirectory: cached,
            manifest: manifest!,
          );
          await _cleanupStaleRecoveryStaging(
            projectId: projectId,
            projectDirectory: cached,
          );
          return cached;
        }
      } catch (_) {
        // Fall through to a fresh root scan after a concurrent Files change.
      }
      _projectDirectories.remove(projectId);
    }

    final Directory root = await _documentsDirectory();
    if (!await root.exists()) return null;
    await for (final FileSystemEntity entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (_isInternalProjectDirectory(entity)) continue;
      try {
        final Map<String, dynamic>? manifest = await _readManifest(entity);
        if (manifest?['projectId']?.toString() != projectId) continue;
        await _recoverStagedPhotoDirectories(
          projectDirectory: entity,
          manifest: manifest!,
        );
        _projectDirectories[projectId] = entity;
        await _cleanupStaleRecoveryStaging(
          projectId: projectId,
          projectDirectory: entity,
        );
        return entity;
      } catch (_) {
        // A Files operation may transiently move one directory during a scan.
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

  static Directory _recoveryDirectory(Directory projectDirectory) => Directory(
        '${projectDirectory.path}${Platform.pathSeparator}'
        '$_recoveryDirectoryName',
      );

  static Future<void> _cleanupStaleRecoveryStaging({
    required String projectId,
    required Directory projectDirectory,
  }) async {
    if (_stagingRecoveryProjectIds.contains(projectId) ||
        !await projectDirectory.exists()) {
      return;
    }
    await for (final FileSystemEntity entity
        in projectDirectory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final String name = entity.uri.pathSegments
          .where((String segment) => segment.isNotEmpty)
          .last;
      if (!name.startsWith('$_recoveryDirectoryName.tmp-')) continue;
      try {
        await entity.delete(recursive: true);
      } catch (_) {
        // A later scan can retry after a transient Files operation finishes.
      }
    }
  }

  static Future<Directory?> _stageRecoveryFiles({
    required String projectId,
    required Directory projectDirectory,
  }) async {
    final File source = await _sourcePdfFile(projectId);
    if (!await source.exists()) return null;
    if (!_stagingRecoveryProjectIds.add(projectId)) {
      throw StateError('案件を「最近削除した項目」へ移動中です。');
    }

    final Directory recovery = _recoveryDirectory(projectDirectory);
    final Directory staging = Directory(
      '${projectDirectory.path}${Platform.pathSeparator}'
      '$_recoveryDirectoryName.tmp-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await staging.create(recursive: true);
      await source.copy(
        '${staging.path}${Platform.pathSeparator}$_recoverySourcePdfName',
      );
      for (final String suffix in _pencilKitSuffixes) {
        final File sidecar = File('${source.path}$suffix');
        if (await sidecar.exists()) {
          await sidecar.copy(
            '${staging.path}${Platform.pathSeparator}'
            '$_recoverySourcePdfName$suffix',
          );
        }
      }
      if (await recovery.exists()) {
        await recovery.delete(recursive: true);
      }
      return await staging.rename(recovery.path);
    } catch (_) {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    } finally {
      _stagingRecoveryProjectIds.remove(projectId);
    }
  }

  static Future<void> _restoreRecoveryFiles({
    required String projectId,
    required Directory projectDirectory,
  }) async {
    final Directory recovery = _recoveryDirectory(projectDirectory);
    if (!await recovery.exists()) return;

    final File recoveredSource = File(
      '${recovery.path}${Platform.pathSeparator}$_recoverySourcePdfName',
    );
    final File source = await _sourcePdfFile(projectId);
    if (await recoveredSource.exists() && !await source.exists()) {
      await _copyFileAtomically(recoveredSource, source);
    }
    if (!await source.exists()) {
      throw StateError('復元用の元PDFを確認できませんでした。');
    }
    for (final String suffix in _pencilKitSuffixes) {
      final File recoveredSidecar = File(
        '${recovery.path}${Platform.pathSeparator}'
        '$_recoverySourcePdfName$suffix',
      );
      final File sidecar = File('${source.path}$suffix');
      if (await recoveredSidecar.exists() && !await sidecar.exists()) {
        await _copyFileAtomically(recoveredSidecar, sidecar);
      }
    }
    await recovery.delete(recursive: true);
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
    final Map<String, Directory> discovered = <String, Directory>{};
    final Set<String> completedMigrations = <String>{};
    await for (final FileSystemEntity entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (_isInternalProjectDirectory(entity)) continue;
      try {
        final Map<String, dynamic>? manifest = await _readManifest(entity);
        if (manifest == null) continue;
        final String id = manifest['projectId']?.toString() ?? '';
        if (id.isEmpty || discovered.containsKey(id)) continue;
        await _recoverStagedPhotoDirectories(
          projectDirectory: entity,
          manifest: manifest,
        );
        await _cleanupStaleRecoveryStaging(
          projectId: id,
          projectDirectory: entity,
        );
        if (manifest['fileMigrationComplete'] == true) {
          completedMigrations.add(id);
        }
        discovered[id] = entity;
        projects.add(
          ProjectSummary(
            id: id,
            name: manifest['projectName']?.toString() ?? '名称未設定',
            updatedAt:
                DateTime.tryParse(manifest['updatedAt']?.toString() ?? '') ??
                    DateTime.fromMillisecondsSinceEpoch(0),
            pageCount: manifest['pageCount'] is num
                ? (manifest['pageCount'] as num).toInt()
                : 0,
            photoCount: manifest['photos'] is List
                ? (manifest['photos'] as List).length
                : 0,
            pinCount: manifest['pins'] is List
                ? (manifest['pins'] as List).length
                : 0,
          ),
        );
      } catch (_) {
        // One damaged or concurrently moved folder must not hide other cases.
      }
    }
    _projectDirectories
      ..clear()
      ..addAll(discovered);
    for (final String id in completedMigrations) {
      await _cleanupMigrationArtifacts(root, id);
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

    try {
      await _restoreRecoveryFiles(
        projectId: projectId,
        projectDirectory: directory,
      );
    } catch (_) {
      // The visible PDF can still open even if an internal recovery copy fails.
    }
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
    for (final String suffix in _pencilKitSuffixes) {
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

  static Future<void> importProjectAtomically({
    required String projectId,
    required String projectName,
    required Uint8List pdfBytes,
    required Map<String, dynamic> metadata,
    required List<Map<String, dynamic>> pins,
    required List<Map<String, dynamic>> strokes,
    required List<Map<String, dynamic>> photos,
  }) async {
    if (pdfBytes.isEmpty) throw StateError('PDFデータが空です。');
    final Directory root = await _documentsDirectory();
    await root.create(recursive: true);
    final Directory? existing = await _findProjectDirectory(projectId);
    final String nonce = DateTime.now().microsecondsSinceEpoch.toString();
    final Directory staging = Directory(
      '${root.path}${Platform.pathSeparator}'
      '$_migrationDirectoryPrefix${_migrationProjectToken(projectId)}-$nonce',
    );
    await staging.create(recursive: true);

    try {
      await _writeBytesAtomically(
        File(
          '${staging.path}${Platform.pathSeparator}${_pdfName(projectName)}',
        ),
        pdfBytes,
      );
      final Map<String, int> pinNumbers = <String, int>{
        for (final Map<String, dynamic> pin in pins)
          if (pin['id'] != null && pin['number'] is num)
            pin['id'].toString(): (pin['number'] as num).toInt(),
      };
      final List<Map<String, dynamic>> photoRecords = <Map<String, dynamic>>[];
      for (final Map<String, dynamic> rawPhoto in photos) {
        final dynamic rawBytes = rawPhoto['bytes'];
        final Uint8List? bytes = rawBytes is Uint8List
            ? rawBytes
            : rawBytes is List<int>
                ? Uint8List.fromList(rawBytes)
                : null;
        if (bytes == null || bytes.isEmpty) continue;
        final String pinId = rawPhoto['pinId']?.toString() ?? '';
        final int? pinNumber = pinNumbers[pinId] ??
            (rawPhoto['pinNumber'] is num
                ? (rawPhoto['pinNumber'] as num).toInt()
                : null);
        if (pinNumber == null) continue;
        final Directory photoDirectory = Directory(
          '${staging.path}${Platform.pathSeparator}$_photosDirectoryName'
          '${Platform.pathSeparator}${_threeDigits(pinNumber)}',
        );
        await photoDirectory.create(recursive: true);
        final String storedFileName = await _availablePhotoFileName(
          photoDirectory,
          rawPhoto['fileName']?.toString() ?? '001.jpg',
        );
        await _writeBytesAtomically(
          File(
            '${photoDirectory.path}${Platform.pathSeparator}$storedFileName',
          ),
          bytes,
        );
        photoRecords.add(<String, dynamic>{
          'projectId': projectId,
          'pinId': pinId,
          'pinNumber': pinNumber,
          'photoId': rawPhoto['photoId']?.toString() ??
              '$pinId-$storedFileName-$nonce',
          'fileName': storedFileName,
          'createdAt': rawPhoto['createdAt']?.toString() ??
              DateTime.now().toIso8601String(),
          'byteLength': bytes.length,
        });
      }

      final Map<String, dynamic> manifest = <String, dynamic>{
        ...metadata,
        'schemaVersion': _schemaVersion,
        'projectId': projectId,
        'projectName': projectName,
        'pdfName': _pdfName(projectName),
        'updatedAt': DateTime.now().toIso8601String(),
        'pins': pins,
        'strokes': strokes,
        'photos': photoRecords,
        'fileMigrationComplete': true,
      };
      await _writeJsonAtomically(
        File(
          '${staging.path}${Platform.pathSeparator}'
          '${_manifestName(projectName)}',
        ),
        manifest,
      );

      // Keep the hidden editor source recoverable before publishing a complete
      // manifest. A stopped migration therefore leaves either the old project
      // or no visible project, and the Hive source can safely retry.
      await _writeBytesAtomically(await _sourcePdfFile(projectId), pdfBytes);

      Directory destination;
      Directory? backup;
      if (existing != null && await existing.exists()) {
        backup = Directory(
          '${root.path}${Platform.pathSeparator}'
          '$_migrationBackupPrefix'
          '${_migrationProjectToken(projectId)}-$nonce',
        );
        await existing.rename(backup.path);
        try {
          destination = await staging.rename(existing.path);
        } catch (_) {
          if (!await existing.exists() && await backup.exists()) {
            await backup.rename(existing.path);
          }
          rethrow;
        }
      } else {
        final String baseName = _safeName(projectName);
        String candidate = baseName;
        int suffix = 2;
        destination = Directory(
          '${root.path}${Platform.pathSeparator}$candidate',
        );
        while (await destination.exists()) {
          candidate = '${baseName}_$suffix';
          suffix++;
          destination = Directory(
            '${root.path}${Platform.pathSeparator}$candidate',
          );
        }
        destination = await staging.rename(destination.path);
      }
      _projectDirectories[projectId] = destination;
      if (backup != null && await backup.exists()) {
        try {
          await backup.delete(recursive: true);
        } catch (_) {
          // The published project is complete; stale hidden backup cleanup is
          // best effort and is retried after a later migration.
        }
      }
      await _cleanupMigrationArtifacts(root, projectId);
    } catch (_) {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    }
  }

  static Future<Map<String, Directory>> _stagePhotoDirectoryMoves({
    required Directory directory,
    required Map<String, dynamic> oldManifest,
    required List<Map<String, dynamic>> newPins,
  }) async {
    final Directory photos = Directory(
      '${directory.path}${Platform.pathSeparator}$_photosDirectoryName',
    );
    if (!await photos.exists()) return <String, Directory>{};

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
      if (newNumber == entry.value) continue;
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
    return staged;
  }

  static Future<void> _finalizePhotoDirectoryMoves({
    required Directory directory,
    required Map<String, Directory> staged,
    required List<Map<String, dynamic>> newPins,
  }) async {
    final Directory photos = Directory(
      '${directory.path}${Platform.pathSeparator}$_photosDirectoryName',
    );
    final Map<String, int> newNumbers = <String, int>{
      for (final Map<String, dynamic> pin in newPins)
        if (pin['id'] != null && pin['number'] is num)
          pin['id'].toString(): (pin['number'] as num).toInt(),
    };
    for (final MapEntry<String, Directory> entry in staged.entries) {
      final int? number = newNumbers[entry.key];
      if (number == null) {
        // Preserve data belonging to a temporarily undone pin.
        continue;
      }
      final Directory destination = Directory(
        '${photos.path}${Platform.pathSeparator}${_threeDigits(number)}',
      );
      if (await destination.exists()) {
        await _mergePhotoDirectoryWithoutOverwrite(
          source: entry.value,
          destination: destination,
        );
      } else {
        await entry.value.rename(destination.path);
      }
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
    await _recoverStagedPhotoDirectories(
      projectDirectory: directory,
      manifest: oldManifest,
    );
    final Map<String, Directory> staged = await _stagePhotoDirectoryMoves(
      directory: directory,
      oldManifest: oldManifest,
      newPins: pins,
    );
    final Map<String, int> newPinNumbers = <String, int>{
      for (final Map<String, dynamic> pin in pins)
        if (pin['id'] != null && pin['number'] is num)
          pin['id'].toString(): (pin['number'] as num).toInt(),
    };
    final List<Map<String, dynamic>> reconciledPhotos = photos.map(
      (Map<String, dynamic> photo) {
        final String pinId = photo['pinId']?.toString() ?? '';
        final int? newNumber = newPinNumbers[pinId];
        return <String, dynamic>{
          ...photo,
          if (newNumber != null) 'pinNumber': newNumber,
        };
      },
    ).toList(growable: false);

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
      'photos': reconciledPhotos,
    };
    final File? oldFile = await _manifestFile(directory);
    final File target = File(
      '${directory.path}${Platform.pathSeparator}${_manifestName(projectName)}',
    );
    try {
      // Commit the new pin mapping before finalizing staged photo directories.
      // Recovery can then use whichever manifest survived a process stop to
      // roll the folders forward or back to a consistent numbering scheme.
      await _writeJsonAtomically(target, manifest);
    } catch (_) {
      await _recoverStagedPhotoDirectories(
        projectDirectory: directory,
        manifest: oldManifest,
      );
      rethrow;
    }
    await _finalizePhotoDirectoryMoves(
      directory: directory,
      staged: staged,
      newPins: pins,
    );
    // This also recovers a photo folder retained by a previous Undo when that
    // pin is restored from persisted Redo history.
    await _recoverStagedPhotoDirectories(
      projectDirectory: directory,
      manifest: manifest,
    );
    if (oldFile != null &&
        oldFile.path != target.path &&
        await oldFile.exists()) {
      await oldFile.delete();
    }
  }

  static Future<String> savePhoto({
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
    final String storedFileName = await _availablePhotoFileName(
      photos,
      fileName,
    );
    final File photo = File(
      '${photos.path}${Platform.pathSeparator}$storedFileName',
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
      'fileName': storedFileName,
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
    return storedFileName;
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

  static Future<Uint8List?> loadPhotoBytes({
    required String projectId,
    required String photoId,
    required int pinNumber,
    required String fileName,
  }) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory == null) return null;
    if (pinNumber < 1 ||
        fileName.isEmpty ||
        fileName.contains('/') ||
        fileName.contains(r'\')) {
      return null;
    }
    final File file = File(
      '${directory.path}${Platform.pathSeparator}$_photosDirectoryName'
      '${Platform.pathSeparator}${_threeDigits(pinNumber)}'
      '${Platform.pathSeparator}$fileName',
    );
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// Visits full-resolution photos one at a time after resolving the project
  /// directory once. The callback must finish before the next JPEG is read, so
  /// callers can stream an arbitrarily large project without retaining every
  /// photo in memory.
  static Future<bool> visitPhotoBytes({
    required String projectId,
    required List<Map<String, dynamic>> photos,
    required Future<void> Function(
      int index,
      Map<String, dynamic> photo,
      Uint8List bytes,
    ) visitor,
  }) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory == null) return false;

    for (int index = 0; index < photos.length; index++) {
      final Map<String, dynamic> photo = photos[index];
      final int? pinNumber = (photo['pinNumber'] as num?)?.toInt();
      final String fileName = photo['fileName']?.toString() ?? '';
      if (pinNumber == null ||
          pinNumber < 1 ||
          fileName.isEmpty ||
          fileName.contains('/') ||
          fileName.contains(r'\')) {
        continue;
      }
      final File file = File(
        '${directory.path}${Platform.pathSeparator}$_photosDirectoryName'
        '${Platform.pathSeparator}${_threeDigits(pinNumber)}'
        '${Platform.pathSeparator}$fileName',
      );
      if (!await file.exists()) continue;
      await visitor(index, photo, await file.readAsBytes());
    }
    return true;
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
        'bytes': await file.readAsBytes(),
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
          'bytes': await file.readAsBytes(),
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
    final Directory photosRoot = Directory(
      '${directory.path}${Platform.pathSeparator}$_photosDirectoryName',
    );
    if (await photosRoot.exists()) {
      await for (final FileSystemEntity entity
          in photosRoot.list(followLinks: false)) {
        if (entity is! Directory) continue;
        // Compare an enumerated direct child instead of interpolating pinId
        // into a path, so a damaged user-visible manifest cannot traverse out
        // of the photo root.
        if (_entityName(entity) == '$_movingPhotoDirectoryPrefix$pinId') {
          await entity.delete(recursive: true);
        }
      }
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
    if (NativeProjectService.isAvailable &&
        (directory == null || !await directory.exists())) {
      throw StateError(
        '案件フォルダが見つからないため、「最近削除した項目」へ移動できませんでした。',
      );
    }
    if (directory != null && await directory.exists()) {
      if (NativeProjectService.isAvailable) {
        await _restoreRecoveryFiles(
          projectId: projectId,
          projectDirectory: directory,
        );
        final Directory? recovery = await _stageRecoveryFiles(
          projectId: projectId,
          projectDirectory: directory,
        );
        try {
          await NativeProjectService.moveFileItemToTrash(directory.path);
        } catch (_) {
          if (recovery != null && await recovery.exists()) {
            await recovery.delete(recursive: true);
          }
          rethrow;
        }
      } else {
        await directory.delete(recursive: true);
      }
    }
    final File source = await _sourcePdfFile(projectId);
    try {
      if (await source.exists()) await source.delete();
      for (final String suffix in _pencilKitSuffixes) {
        final File sidecar = File('${source.path}$suffix');
        if (await sidecar.exists()) await sidecar.delete();
      }
    } catch (_) {
      // The user-visible folder is already safely in Recently Deleted.
    }
    _projectDirectories.remove(projectId);
  }

  static Future<String?> sourcePdfPath(String projectId) async {
    final Directory? directory = await _findProjectDirectory(projectId);
    if (directory != null) {
      try {
        await _restoreRecoveryFiles(
          projectId: projectId,
          projectDirectory: directory,
        );
      } catch (_) {
        // Keep the recovery bundle in place so opening can be retried later.
      }
    }
    final File source = await _sourcePdfFile(projectId);
    return await source.exists() ? source.path : null;
  }

  static Future<bool> hasProject(String projectId) async =>
      await _findProjectDirectory(projectId) != null;

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
