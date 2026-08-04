import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/project_summary.dart';
import 'project_file_store.dart';

/// Large-project storage for FieldNote.
///
/// Heavy binary objects are stored separately so adding one photo never rewrites
/// the PDF or every previously captured photo.
class ProjectRepository {
  static const String _metaBoxName = 'fieldnote_meta_v5';
  static const String _pdfBoxName = 'fieldnote_pdf_v5';
  static const String _pinsBoxName = 'fieldnote_pins_v5';
  static const String _drawingsBoxName = 'fieldnote_drawings_v5';
  static const String _photoMetaBoxName = 'fieldnote_photo_meta_v5';
  static const String _photoBytesBoxName = 'fieldnote_photo_bytes_v5';
  static const String _thumbnailBoxName = 'fieldnote_thumbnails_v5';
  static const String _editedPhotoBoxName = 'fieldnote_edited_photos_v1';
  static const String _trashBoxName = 'fieldnote_project_trash_v1';
  static final Uint8List _unavailablePhotoPreviewBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  // Read-only migration source used by v4.
  static const String _legacyBoxName = 'fieldnote_projects_v2';
  static const String _legacyIndexKey = '__project_index__';
  static final Set<String> _deletionsInProgress = <String>{};

  static Future<Box<dynamic>> _metaBox() => Hive.openBox<dynamic>(_metaBoxName);
  static Future<Box<dynamic>> _pdfBox() => Hive.openBox<dynamic>(_pdfBoxName);
  static Future<Box<dynamic>> _pinsBox() => Hive.openBox<dynamic>(_pinsBoxName);
  static Future<Box<dynamic>> _drawingsBox() =>
      Hive.openBox<dynamic>(_drawingsBoxName);
  static Future<Box<dynamic>> _photoMetaBox() =>
      Hive.openBox<dynamic>(_photoMetaBoxName);
  static Future<Box<dynamic>> _photoBytesBox() =>
      Hive.openBox<dynamic>(_photoBytesBoxName);
  static Future<Box<dynamic>> _thumbnailBox() =>
      Hive.openBox<dynamic>(_thumbnailBoxName);
  static Future<Box<dynamic>> _editedPhotoBox() =>
      Hive.openBox<dynamic>(_editedPhotoBoxName);
  static Future<Box<dynamic>> _trashBox() =>
      Hive.openBox<dynamic>(_trashBoxName);

  static String _photoKey(String projectId, String photoId) =>
      '$projectId::$photoId';

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return Map<String, dynamic>.from(value);
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{};
  }

  static List<dynamic> _asList(dynamic value) {
    if (value is List) return List<dynamic>.from(value);
    return <dynamic>[];
  }

  static Uint8List? _asBytes(dynamic value) {
    if (value is Uint8List) return Uint8List.fromList(value);
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is List) {
      return Uint8List.fromList(value.map((e) => (e as num).toInt()).toList());
    }
    if (value is String && value.isNotEmpty) {
      try {
        return base64Decode(value);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Future<List<ProjectSummary>> listProjects() async {
    final List<ProjectSummary> fileProjects =
        await ProjectFileStore.listProjects();
    final Box<dynamic> trash = await _trashBox();
    for (final ProjectSummary project in fileProjects) {
      if (trash.containsKey(project.id) &&
          !_deletionsInProgress.contains(project.id)) {
        await trash.delete(project.id);
      }
    }
    final Set<String> trashedProjectIds =
        trash.keys.map((dynamic key) => key.toString()).toSet();
    final Map<String, ProjectSummary> projectsById = <String, ProjectSummary>{
      for (final ProjectSummary project in fileProjects)
        if (!trashedProjectIds.contains(project.id)) project.id: project,
    };
    final Box<dynamic> meta = await _metaBox();
    final Box<dynamic> pdfBox = await _pdfBox();
    final Box<dynamic> pinsBox = await _pinsBox();
    final Box<dynamic> photoMetaBox = await _photoMetaBox();

    final Map<String, int> photoCounts = <String, int>{};
    for (final dynamic key in photoMetaBox.keys) {
      final Map<String, dynamic> record = _asMap(photoMetaBox.get(key));
      final String projectId = record['projectId']?.toString() ?? '';
      if (projectId.isNotEmpty) {
        photoCounts[projectId] = (photoCounts[projectId] ?? 0) + 1;
      }
    }

    for (final dynamic key in meta.keys) {
      final String projectId = key.toString();
      if (trashedProjectIds.contains(projectId)) continue;
      final Map<String, dynamic> record = _asMap(meta.get(key));
      if (record.isEmpty) continue;
      if (ProjectFileStore.isAuthoritative) {
        final Uint8List? migratablePdf = _asBytes(pdfBox.get(projectId));
        if ((migratablePdf == null || migratablePdf.isEmpty) &&
            !await _hasLegacyProject(projectId)) {
          // Ordinary files are authoritative on iPad. Cache-only metadata
          // must not resurrect a folder removed externally through Files.
          continue;
        }
      }
      final DateTime updatedAt =
          DateTime.tryParse(record['updatedAt']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
      final List<dynamic> pins = _asList(pinsBox.get(projectId));
      projectsById.putIfAbsent(
        projectId,
        () => ProjectSummary(
          id: projectId,
          name: record['projectName']?.toString() ?? '名称未設定',
          updatedAt: updatedAt,
          pageCount: (record['pageCount'] as num?)?.toInt() ?? 0,
          photoCount: photoCounts[projectId] ?? 0,
          pinCount: pins.length,
        ),
      );
    }

    // Until a legacy project is opened/migrated, keep it visible on Home.
    try {
      final Box<dynamic> legacy = await Hive.openBox<dynamic>(_legacyBoxName);
      final String? rawIndex = legacy.get(_legacyIndexKey) as String?;
      if (rawIndex != null) {
        final List<dynamic> oldList = jsonDecode(rawIndex) as List<dynamic>;
        for (final dynamic item in oldList) {
          final ProjectSummary old = ProjectSummary.fromJson(_asMap(item));
          if (trashedProjectIds.contains(old.id)) continue;
          if (legacy.get('project_${old.id}') is! String) continue;
          projectsById.putIfAbsent(old.id, () => old);
        }
      }
    } catch (_) {
      // A broken legacy index must not hide valid v5 projects.
    }

    final List<ProjectSummary> projects = projectsById.values.toList();
    projects.sort(
      (ProjectSummary a, ProjectSummary b) =>
          b.updatedAt.compareTo(a.updatedAt),
    );
    return projects;
  }

  static Future<void> touchProject({
    required String id,
    required String name,
    Map<String, dynamic> values = const <String, dynamic>{},
  }) async {
    final Box<dynamic> box = await _metaBox();
    final Map<String, dynamic> current = _asMap(box.get(id));
    current
      ..addAll(values)
      ..['projectId'] = id
      ..['projectName'] = name
      ..['updatedAt'] = DateTime.now().toIso8601String();
    await box.put(id, current);
  }

  static Future<void> createProject({
    required String id,
    required String name,
  }) async {
    await ProjectFileStore.createProject(
      projectId: id,
      projectName: name,
    );
    if (ProjectFileStore.isAuthoritative) {
      try {
        await touchProject(id: id, name: name);
      } catch (_) {
        // The project folder and manifest already exist.
      }
    } else {
      await touchProject(id: id, name: name);
    }
  }

  static Future<void> savePdfOnce({
    required String projectId,
    required String projectName,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) throw StateError('PDFデータが空です。');
    await ProjectFileStore.saveOriginalPdf(
      projectId: projectId,
      projectName: projectName,
      bytes: bytes,
    );
    Future<void> updateCache() async {
      final Box<dynamic> box = await _pdfBox();
      if (ProjectFileStore.isAuthoritative) {
        await box.delete(projectId);
      } else {
        await box.put(projectId, Uint8List.fromList(bytes));
      }
      await touchProject(
        id: projectId,
        name: projectName,
        values: <String, dynamic>{'pdfName': '$projectName.pdf'},
      );
    }

    if (ProjectFileStore.isAuthoritative) {
      try {
        await updateCache();
      } catch (_) {
        // The user-visible project folder is already safely committed.
      }
    } else {
      await updateCache();
    }
  }

  static Future<void> saveProjectSnapshot({
    required String projectId,
    required String projectName,
    required Map<String, dynamic> metadata,
    required List<Map<String, dynamic>> pins,
    required List<Map<String, dynamic>> strokes,
  }) async {
    // The project folder is authoritative on iPad. Loading through the public
    // API preserves photo metadata even when Hive was rebuilt or cleared.
    final List<Map<String, dynamic>> photos =
        await loadPhotoMetadata(projectId);
    await ProjectFileStore.saveSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: metadata,
      pins: pins,
      strokes: strokes,
      photos: photos,
    );
    Future<void> updateCache() async {
      await savePins(projectId: projectId, pins: pins);
      await saveDrawings(projectId: projectId, strokes: strokes);
      await touchProject(
        id: projectId,
        name: projectName,
        values: metadata,
      );
    }

    if (ProjectFileStore.isAuthoritative) {
      try {
        await updateCache();
      } catch (_) {
        // Hive is only an index/cache when ordinary project files are present.
      }
    } else {
      await updateCache();
    }
  }

  static Future<void> savePins({
    required String projectId,
    required List<Map<String, dynamic>> pins,
  }) async {
    await (await _pinsBox()).put(projectId, pins);
  }

  static Future<void> saveDrawings({
    required String projectId,
    required List<Map<String, dynamic>> strokes,
  }) async {
    await (await _drawingsBox()).put(projectId, strokes);
  }

  static Future<String> savePhoto({
    required String projectId,
    required String projectName,
    required String pinId,
    required int pinNumber,
    required String photoId,
    required String fileName,
    required Uint8List bytes,
    Uint8List? thumbnailBytes,
  }) async {
    if (bytes.isEmpty) throw StateError('写真データが空です。');
    final String storedFileName = await ProjectFileStore.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: pinId,
      pinNumber: pinNumber,
      photoId: photoId,
      fileName: fileName,
      bytes: bytes,
    );
    final String key = _photoKey(projectId, photoId);
    Future<void> updateCache() async {
      final Box<dynamic> metaBox = await _photoMetaBox();
      final Box<dynamic> thumbnailBox = await _thumbnailBox();
      if (ProjectFileStore.isAuthoritative) {
        await (await _photoBytesBox()).delete(key);
      } else {
        // Web has no ordinary project folder, so Hive remains the primary store.
        await (await _photoBytesBox()).put(
          key,
          Uint8List.fromList(bytes),
        );
      }
      if (thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
        await thumbnailBox.put(key, Uint8List.fromList(thumbnailBytes));
      }
      await metaBox.put(key, <String, dynamic>{
        'projectId': projectId,
        'pinId': pinId,
        'pinNumber': pinNumber,
        'photoId': photoId,
        'fileName': storedFileName,
        'createdAt': DateTime.now().toIso8601String(),
        'byteLength': bytes.length,
      });
    }

    if (ProjectFileStore.isAuthoritative) {
      try {
        await updateCache();
      } catch (_) {
        // The full-size photo and its manifest record are already committed.
      }
    } else {
      await updateCache();
    }
    return storedFileName;
  }

  static Future<List<Map<String, dynamic>>> loadPhotoMetadata(
      String projectId) async {
    final List<Map<String, dynamic>>? files =
        await ProjectFileStore.loadPhotoMetadata(projectId);
    if (files != null) return files;
    return _loadHivePhotoMetadata(projectId);
  }

  static Future<List<Map<String, dynamic>>> _loadHivePhotoMetadata(
      String projectId) async {
    final Box<dynamic> metaBox = await _photoMetaBox();
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (final dynamic key in metaBox.keys) {
      final Map<String, dynamic> meta = _asMap(metaBox.get(key));
      if (meta['projectId']?.toString() == projectId) result.add(meta);
    }
    result.sort((a, b) => (a['createdAt']?.toString() ?? '')
        .compareTo(b['createdAt']?.toString() ?? ''));
    return result;
  }

  static Future<Uint8List?> loadPhotoBytes({
    required String projectId,
    required String photoId,
    required int pinNumber,
    required String fileName,
  }) async {
    final Uint8List? fileBytes = await ProjectFileStore.loadPhotoBytes(
      projectId: projectId,
      photoId: photoId,
      pinNumber: pinNumber,
      fileName: fileName,
    );
    if (fileBytes != null && fileBytes.isNotEmpty) {
      return fileBytes;
    }
    if (ProjectFileStore.isAuthoritative) return null;
    final String key = _photoKey(projectId, photoId);
    final Uint8List? bytes = _asBytes((await _photoBytesBox()).get(key));
    if (bytes != null && bytes.isNotEmpty) return bytes;
    // Old cache-only projects may only retain a thumbnail. It is preferable to
    // export that recovery image instead of silently omitting the photo.
    return _asBytes((await _thumbnailBox()).get(key));
  }

  static Future<void> saveEditedPhoto({
    required String projectId,
    required int pinNumber,
    required String photoId,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) {
      throw StateError('書き込み済み写真が空です。');
    }
    await ProjectFileStore.saveEditedPhoto(
      projectId: projectId,
      pinNumber: pinNumber,
      photoId: photoId,
      bytes: bytes,
    );
    if (!ProjectFileStore.isAuthoritative) {
      await (await _editedPhotoBox()).put(
        _photoKey(projectId, photoId),
        Uint8List.fromList(bytes),
      );
    }
  }

  static Future<Uint8List?> loadEditedPhotoBytes({
    required String projectId,
    required int pinNumber,
    required String photoId,
  }) async {
    final Uint8List? bytes = await ProjectFileStore.loadEditedPhotoBytes(
      projectId: projectId,
      pinNumber: pinNumber,
      photoId: photoId,
    );
    if (bytes != null && bytes.isNotEmpty) return bytes;
    if (ProjectFileStore.isAuthoritative) return null;
    return _asBytes(
      (await _editedPhotoBox()).get(_photoKey(projectId, photoId)),
    );
  }

  static Future<void> deleteEditedPhoto({
    required String projectId,
    required int pinNumber,
    required String photoId,
  }) async {
    await ProjectFileStore.deleteEditedPhoto(
      projectId: projectId,
      pinNumber: pinNumber,
      photoId: photoId,
    );
    try {
      await (await _editedPhotoBox()).delete(_photoKey(projectId, photoId));
    } catch (_) {
      if (!ProjectFileStore.isAuthoritative) rethrow;
    }
  }

  /// Visits full-resolution photos sequentially without retaining the complete
  /// set in memory. Native storage resolves the project folder once; web falls
  /// back to the Hive boxes that are authoritative there.
  static Future<void> visitPhotoBytes({
    required String projectId,
    required List<Map<String, dynamic>> photos,
    required Future<void> Function(
      int index,
      Map<String, dynamic> photo,
      Uint8List bytes,
    ) visitor,
  }) async {
    final bool handledByFiles = await ProjectFileStore.visitPhotoBytes(
      projectId: projectId,
      photos: photos,
      visitor: visitor,
    );
    if (handledByFiles || ProjectFileStore.isAuthoritative) return;

    final Box<dynamic> bytesBox = await _photoBytesBox();
    final Box<dynamic> thumbnailBox = await _thumbnailBox();
    for (int index = 0; index < photos.length; index++) {
      final Map<String, dynamic> photo = photos[index];
      final String photoId = photo['photoId']?.toString() ?? '';
      if (photoId.isEmpty) continue;
      final String key = _photoKey(projectId, photoId);
      final Uint8List? bytes =
          _asBytes(bytesBox.get(key)) ?? _asBytes(thumbnailBox.get(key));
      if (bytes == null || bytes.isEmpty) continue;
      await visitor(index, photo, bytes);
    }
  }

  /// Loads lightweight previews for one pin. Existing thumbnails are used
  /// directly. Older native photos without a cached thumbnail are read and
  /// reduced one at a time, then cached for subsequent opens.
  static Future<List<Map<String, dynamic>>> loadPhotoPreviewsForPin({
    required String projectId,
    required String pinId,
    required Future<Uint8List> Function(Uint8List bytes) thumbnailBuilder,
  }) async {
    final List<Map<String, dynamic>> photos =
        (await loadPhotoMetadata(projectId))
            .where(
              (Map<String, dynamic> photo) =>
                  photo['pinId']?.toString() == pinId,
            )
            .toList(growable: false);
    if (photos.isEmpty) return <Map<String, dynamic>>[];

    Box<dynamic>? thumbnailBox;
    try {
      thumbnailBox = await _thumbnailBox();
    } catch (_) {
      // Derived previews may be rebuilt from the authoritative JPEGs.
    }

    final List<Uint8List?> previews =
        List<Uint8List?>.filled(photos.length, null);
    final List<int> missingIndexes = <int>[];
    for (int index = 0; index < photos.length; index++) {
      final String photoId = photos[index]['photoId']?.toString() ?? '';
      Uint8List? cached;
      if (photoId.isNotEmpty && thumbnailBox != null) {
        try {
          final dynamic value = thumbnailBox.get(_photoKey(projectId, photoId));
          cached = value is Uint8List ? value : _asBytes(value);
        } catch (_) {
          // Read the original below when this individual cache entry is bad.
        }
      }
      if (cached != null && cached.isNotEmpty) {
        previews[index] = cached;
      } else {
        missingIndexes.add(index);
      }
    }

    if (missingIndexes.isNotEmpty) {
      final List<Map<String, dynamic>> missingPhotos = missingIndexes
          .map((int index) => photos[index])
          .toList(growable: false);
      await visitPhotoBytes(
        projectId: projectId,
        photos: missingPhotos,
        visitor: (
          int missingIndex,
          Map<String, dynamic> photo,
          Uint8List bytes,
        ) async {
          Uint8List preview;
          bool cachePreview = true;
          try {
            preview = await thumbnailBuilder(bytes);
            if (preview.isEmpty) {
              preview = _unavailablePhotoPreviewBytes;
              cachePreview = false;
            }
          } catch (_) {
            // Preserve the photo count without retaining a corrupt full-size
            // JPEG. A later open retries thumbnail generation.
            preview = _unavailablePhotoPreviewBytes;
            cachePreview = false;
          }
          final int index = missingIndexes[missingIndex];
          previews[index] = preview;

          final String photoId = photo['photoId']?.toString() ?? '';
          if (cachePreview && photoId.isNotEmpty && thumbnailBox != null) {
            try {
              await thumbnailBox.put(
                _photoKey(projectId, photoId),
                Uint8List.fromList(preview),
              );
            } catch (_) {
              // The preview is derived data; displaying it does not depend on
              // cache persistence succeeding.
            }
          }
        },
      );
    }

    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (int index = 0; index < photos.length; index++) {
      final Uint8List? preview = previews[index];
      if (preview == null || preview.isEmpty) continue;
      result.add(<String, dynamic>{...photos[index], 'bytes': preview});
    }
    return result;
  }

  static Future<List<Map<String, dynamic>>> loadPhotosForPin({
    required String projectId,
    required String pinId,
  }) async {
    final List<Map<String, dynamic>>? files =
        await ProjectFileStore.loadPhotosForPin(
      projectId: projectId,
      pinId: pinId,
    );
    if (files != null) return files;

    final Box<dynamic> metaBox = await _photoMetaBox();
    final Box<dynamic> bytesBox = await _photoBytesBox();
    final Box<dynamic> thumbnailBox = await _thumbnailBox();
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];

    for (final dynamic key in metaBox.keys) {
      final Map<String, dynamic> meta = _asMap(metaBox.get(key));
      if (meta['projectId']?.toString() != projectId ||
          meta['pinId']?.toString() != pinId) {
        continue;
      }
      final Uint8List? thumbnail = _asBytes(thumbnailBox.get(key));
      final Uint8List? bytes = thumbnail ?? _asBytes(bytesBox.get(key));
      if (bytes == null || bytes.isEmpty) continue;
      result.add(<String, dynamic>{...meta, 'bytes': bytes});
    }
    result.sort((a, b) => (a['createdAt']?.toString() ?? '')
        .compareTo(b['createdAt']?.toString() ?? ''));
    return result;
  }

  static Future<List<Map<String, dynamic>>> loadAllPhotos(
      String projectId) async {
    final List<Map<String, dynamic>>? files =
        await ProjectFileStore.loadAllPhotos(projectId);
    if (files != null) return files;

    final List<Map<String, dynamic>> meta =
        await _loadHivePhotoMetadata(projectId);
    final Box<dynamic> bytesBox = await _photoBytesBox();
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> item in meta) {
      final String photoId = item['photoId'].toString();
      final Uint8List? bytes =
          _asBytes(bytesBox.get(_photoKey(projectId, photoId)));
      if (bytes != null && bytes.isNotEmpty) {
        result.add(<String, dynamic>{...item, 'bytes': bytes});
      }
    }
    return result;
  }

  static Future<bool> _hasLegacyProject(String projectId) async {
    try {
      final Box<dynamic> legacy = await Hive.openBox<dynamic>(_legacyBoxName);
      return legacy.get('project_$projectId') is String;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> _hiveV5ProjectForMigration(
    String projectId,
  ) async {
    final Uint8List? pdf = _asBytes((await _pdfBox()).get(projectId));
    if (pdf == null || pdf.isEmpty) return null;
    final Map<String, dynamic> meta = _asMap((await _metaBox()).get(projectId));
    return <String, dynamic>{
      ...meta,
      'projectId': projectId,
      'projectName': meta['projectName']?.toString() ?? '名称未設定',
      'pdfBytes': pdf,
      'pins': _asList((await _pinsBox()).get(projectId)),
      'strokes': _asList((await _drawingsBox()).get(projectId)),
      'photoMeta': await _loadHivePhotoMetadata(projectId),
    };
  }

  static Future<bool> _isIncompleteHiveV5Migration({
    required Map<String, dynamic> fileProject,
    required Map<String, dynamic> hiveProject,
    required String projectId,
  }) async {
    final int filePins = _asList(fileProject['pins']).length;
    final int hivePins = _asList(hiveProject['pins']).length;
    final int fileStrokes = _asList(fileProject['strokes']).length;
    final int hiveStrokes = _asList(hiveProject['strokes']).length;
    final int filePhotos = _asList(fileProject['photoMeta']).length;
    final int hivePhotos = (await _loadAllHivePhotos(projectId)).length;
    return filePins < hivePins ||
        fileStrokes < hiveStrokes ||
        filePhotos < hivePhotos;
  }

  static Future<void> deletePhotosForPin({
    required String projectId,
    required String pinId,
  }) async {
    await ProjectFileStore.deletePhotosForPin(
      projectId: projectId,
      pinId: pinId,
    );
    Future<void> clearCache() async {
      final Box<dynamic> metaBox = await _photoMetaBox();
      final Box<dynamic> bytesBox = await _photoBytesBox();
      final Box<dynamic> thumbnailBox = await _thumbnailBox();
      final Box<dynamic> editedPhotoBox = await _editedPhotoBox();
      final List<dynamic> keys = <dynamic>[];
      for (final dynamic key in metaBox.keys) {
        final Map<String, dynamic> meta = _asMap(metaBox.get(key));
        if (meta['projectId']?.toString() == projectId &&
            meta['pinId']?.toString() == pinId) {
          keys.add(key);
        }
      }
      await metaBox.deleteAll(keys);
      await bytesBox.deleteAll(keys);
      await thumbnailBox.deleteAll(keys);
      await editedPhotoBox.deleteAll(keys);
    }

    if (ProjectFileStore.isAuthoritative) {
      try {
        await clearCache();
      } catch (_) {
        // The photo folder and manifest records are already removed.
      }
    } else {
      await clearCache();
    }
  }

  static Future<Map<String, dynamic>?> loadProject(String id) async {
    Map<String, dynamic>? fileProject = await ProjectFileStore.loadProject(id);
    if (fileProject != null) {
      if (fileProject['migratedFromV4'] == true) {
        try {
          final Box<dynamic> legacy =
              await Hive.openBox<dynamic>(_legacyBoxName);
          await legacy.delete('project_$id');
        } catch (_) {
          // Completed ordinary files stay authoritative.
        }
      }
      if (fileProject['migratedFromHiveV5'] == true) {
        try {
          await (await _pdfBox()).delete(id);
        } catch (_) {
          // Completed ordinary files stay authoritative.
        }
      }
      final bool interruptedLegacyMigration =
          ProjectFileStore.isAuthoritative &&
              fileProject['migratedFromV4'] != true &&
              await _hasLegacyProject(id);
      if (interruptedLegacyMigration) {
        final Map<String, dynamic>? migrated = await _migrateLegacyProject(id);
        if (migrated != null) {
          fileProject = await ProjectFileStore.loadProject(id);
        }
      } else if (fileProject['migratedFromHiveV5'] != true) {
        final Map<String, dynamic>? hiveProject =
            await _hiveV5ProjectForMigration(id);
        if (hiveProject != null) {
          if (await _isIncompleteHiveV5Migration(
            fileProject: fileProject,
            hiveProject: hiveProject,
            projectId: id,
          )) {
            await _migrateProjectToFiles(id, hiveProject);
            fileProject = await ProjectFileStore.loadProject(id);
          } else {
            // Older complete migrations had no marker. The ordinary files are
            // at least as complete as their Hive source, so retire that source
            // instead of replaying stale cache over newer Files data.
            try {
              await (await _pdfBox()).delete(id);
            } catch (_) {}
          }
        }
      }
      return fileProject;
    }

    final Box<dynamic> metaBox = await _metaBox();
    Map<String, dynamic> meta = _asMap(metaBox.get(id));

    if (meta.isEmpty) {
      final Map<String, dynamic>? migrated = await _migrateLegacyProject(id);
      if (migrated == null) return null;
      final Map<String, dynamic>? migratedFileProject =
          await ProjectFileStore.loadProject(id);
      if (migratedFileProject != null) return migratedFileProject;
      meta = _asMap((await _metaBox()).get(id));
    }

    final Uint8List? pdfBytes = _asBytes((await _pdfBox()).get(id));
    if (pdfBytes == null || pdfBytes.isEmpty) return null;

    final List<dynamic> pins = _asList((await _pinsBox()).get(id));
    final List<dynamic> strokes = _asList((await _drawingsBox()).get(id));
    final List<Map<String, dynamic>> photoMeta =
        await _loadHivePhotoMetadata(id);

    // Only metadata is loaded at startup. Full image bytes are loaded per pin.
    final Map<String, dynamic> project = <String, dynamic>{
      ...meta,
      'pdfBytes': pdfBytes,
      'pins': pins,
      'strokes': strokes,
      'photoMeta': photoMeta,
    };
    await _migrateProjectToFiles(id, project);
    return project;
  }

  static Future<void> _migrateProjectToFiles(
    String projectId,
    Map<String, dynamic> project,
  ) async {
    if (!ProjectFileStore.isAuthoritative) return;
    final Uint8List? pdf = _asBytes(project['pdfBytes']);
    if (pdf == null || pdf.isEmpty) return;
    final String name = project['projectName']?.toString() ?? '名称未設定';
    final List<Map<String, dynamic>> pins =
        _asList(project['pins']).map(_asMap).toList();
    final List<Map<String, dynamic>> strokes =
        _asList(project['strokes']).map(_asMap).toList();
    final List<Map<String, dynamic>> fullPhotos =
        await _loadAllHivePhotos(projectId);
    await ProjectFileStore.importProjectAtomically(
      projectId: projectId,
      projectName: name,
      pdfBytes: pdf,
      metadata: <String, dynamic>{
        for (final String key in <String>[
          'pageCount',
          'currentPage',
          'nextPinNumber',
          'pinColor',
          'penColor',
          'penWidth',
          'boardBusinessName',
          'boardFacilityName',
          'pendingDirectionPinId',
          'captureAfterDirectionPinId',
        ])
          if (project.containsKey(key)) key: project[key],
        'migratedFromHiveV5': true,
      },
      pins: pins,
      strokes: strokes,
      photos: fullPhotos,
    );
    try {
      // The complete file project is now authoritative. Keeping an old Hive
      // PDF would make a later external Files deletion look migratable and
      // could recreate an incomplete project without its photo binaries.
      await (await _pdfBox()).delete(projectId);
    } catch (_) {
      // Cache cleanup is best effort after the atomic file commit.
    }
  }

  static Future<List<Map<String, dynamic>>> _loadAllHivePhotos(
      String projectId) async {
    final List<Map<String, dynamic>> meta =
        await _loadHivePhotoMetadata(projectId);
    final Box<dynamic> bytesBox = await _photoBytesBox();
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> item in meta) {
      final String photoId = item['photoId'].toString();
      final Uint8List? bytes =
          _asBytes(bytesBox.get(_photoKey(projectId, photoId)));
      if (bytes != null && bytes.isNotEmpty) {
        result.add(<String, dynamic>{...item, 'bytes': bytes});
      }
    }
    return result;
  }

  static Future<Map<String, dynamic>?> _migrateLegacyProject(String id) async {
    try {
      final Box<dynamic> legacy = await Hive.openBox<dynamic>(_legacyBoxName);
      final String? raw = legacy.get('project_$id') as String?;
      if (raw == null) return null;
      final Map<String, dynamic> old = jsonDecode(raw) as Map<String, dynamic>;
      final Uint8List? pdf = _asBytes(old['pdfBytes']);
      if (pdf == null || pdf.isEmpty) return null;
      final String name = old['projectName']?.toString() ?? '名称未設定';
      final List<Map<String, dynamic>> legacyPins =
          _asList(old['pins']).map(_asMap).toList();
      final List<Map<String, dynamic>> legacyStrokes =
          _asList(old['strokes']).map(_asMap).toList();
      final Map<String, dynamic> oldPhotos = _asMap(old['photos']);
      final Map<String, int> legacyPinNumbers = <String, int>{
        for (final Map<String, dynamic> pin in legacyPins)
          if (pin['id'] != null && pin['number'] is num)
            pin['id'].toString(): (pin['number'] as num).toInt(),
      };
      final List<Map<String, dynamic>> fullPhotos = <Map<String, dynamic>>[];
      for (final MapEntry<String, dynamic> entry in oldPhotos.entries) {
        for (final dynamic rawPhoto in _asList(entry.value)) {
          final Map<String, dynamic> photo = _asMap(rawPhoto);
          final Uint8List? bytes = _asBytes(photo['bytes']);
          if (bytes == null || bytes.isEmpty) continue;
          fullPhotos.add(<String, dynamic>{
            'projectId': id,
            'pinId': entry.key,
            'pinNumber': legacyPinNumbers[entry.key] ?? 1,
            'photoId': photo['id']?.toString() ??
                '${entry.key}-${DateTime.now().microsecondsSinceEpoch}',
            'fileName': photo['fileName']?.toString() ?? '001.jpg',
            'createdAt': photo['createdAt']?.toString() ??
                DateTime.now().toIso8601String(),
            'bytes': bytes,
          });
        }
      }
      final Map<String, dynamic> migrationMetadata = <String, dynamic>{
        for (final String key in <String>[
          'pageCount',
          'currentPage',
          'nextPinNumber',
          'pinColor',
          'penColor',
          'penWidth',
          'boardBusinessName',
          'boardFacilityName',
        ])
          if (old.containsKey(key)) key: old[key],
        'migratedFromV4': true,
      };
      if (ProjectFileStore.isAuthoritative) {
        await ProjectFileStore.importProjectAtomically(
          projectId: id,
          projectName: name,
          pdfBytes: pdf,
          metadata: migrationMetadata,
          pins: legacyPins,
          strokes: legacyStrokes,
          photos: fullPhotos,
        );
        try {
          await savePins(projectId: id, pins: legacyPins);
          await saveDrawings(projectId: id, strokes: legacyStrokes);
          await touchProject(id: id, name: name, values: migrationMetadata);
        } catch (_) {
          // The complete ordinary-file project has already been published.
        }
        try {
          // Do not let an old legacy payload resurrect stale data after the
          // user removes the authoritative folder through Files.
          await legacy.delete('project_$id');
        } catch (_) {
          // The file project is complete; legacy cleanup can be best effort.
        }
      } else {
        await savePdfOnce(projectId: id, projectName: name, bytes: pdf);
        await savePins(projectId: id, pins: legacyPins);
        await saveDrawings(projectId: id, strokes: legacyStrokes);
        await touchProject(id: id, name: name, values: migrationMetadata);
        for (final Map<String, dynamic> photo in fullPhotos) {
          await savePhoto(
            projectId: id,
            projectName: name,
            pinId: photo['pinId'].toString(),
            pinNumber: (photo['pinNumber'] as num).toInt(),
            photoId: photo['photoId'].toString(),
            fileName: photo['fileName'].toString(),
            bytes: photo['bytes'] as Uint8List,
          );
        }
      }
      final List<Map<String, dynamic>> migratedPhotoMetadata =
          ProjectFileStore.isAuthoritative
              ? fullPhotos
                  .map(
                    (Map<String, dynamic> photo) =>
                        <String, dynamic>{...photo}..remove('bytes'),
                  )
                  .toList(growable: false)
              : await _loadHivePhotoMetadata(id);
      return <String, dynamic>{
        ...old,
        'projectId': id,
        'projectName': name,
        'pdfBytes': pdf,
        'pins': legacyPins,
        'strokes': legacyStrokes,
        'photoMeta': migratedPhotoMetadata,
      };
    } catch (_) {
      return null;
    }
  }

  static Future<void> renameProject(String id, String name) async {
    await ProjectFileStore.renameProject(id, name);
    if (ProjectFileStore.isAuthoritative) {
      try {
        await touchProject(id: id, name: name);
      } catch (_) {
        // The folder and its manifest already contain the new name.
      }
    } else {
      await touchProject(id: id, name: name);
    }
  }

  static Future<void> deleteProject(String id) async {
    if (!_deletionsInProgress.add(id)) {
      throw StateError('この案件は「最近削除した項目」へ移動中です。');
    }
    try {
      if (ProjectFileStore.isAuthoritative &&
          !await ProjectFileStore.hasProject(id)) {
        final Map<String, dynamic>? migrated = await loadProject(id);
        if (migrated == null || !await ProjectFileStore.hasProject(id)) {
          throw StateError(
            '案件ファイルを準備できなかったため、削除せずに処理を中止しました。',
          );
        }
      }

      final Box<dynamic> trash = await _trashBox();
      await trash.put(
        id,
        <String, dynamic>{
          'projectId': id,
          'deletedAt': DateTime.now().toIso8601String(),
        },
      );
      try {
        await ProjectFileStore.deleteProject(id);
      } catch (_) {
        await trash.delete(id);
        rethrow;
      }
      Future<void> clearCache() async {
        await (await _metaBox()).delete(id);
        await (await _pdfBox()).delete(id);
        await (await _pinsBox()).delete(id);
        await (await _drawingsBox()).delete(id);

        final Box<dynamic> photoMeta = await _photoMetaBox();
        final Box<dynamic> photoBytes = await _photoBytesBox();
        final Box<dynamic> thumbnails = await _thumbnailBox();
        final Box<dynamic> editedPhotos = await _editedPhotoBox();
        final List<dynamic> keys = <dynamic>[];
        for (final dynamic key in photoMeta.keys) {
          final Map<String, dynamic> meta = _asMap(photoMeta.get(key));
          if (meta['projectId']?.toString() == id) keys.add(key);
        }
        await photoMeta.deleteAll(keys);
        await photoBytes.deleteAll(keys);
        await thumbnails.deleteAll(keys);
        await editedPhotos.deleteAll(keys);

        // Remove legacy copy only after deletion was requested explicitly.
        try {
          final Box<dynamic> legacy =
              await Hive.openBox<dynamic>(_legacyBoxName);
          await legacy.delete('project_$id');
        } catch (_) {}
      }

      if (ProjectFileStore.isAuthoritative) {
        try {
          await clearCache();
        } catch (_) {
          // The user-visible project folder is already deleted.
        }
      } else {
        await clearCache();
      }
    } finally {
      _deletionsInProgress.remove(id);
    }
  }

  static Future<String?> sourcePdfPath(String projectId) =>
      ProjectFileStore.sourcePdfPath(projectId);

  static Future<String?> outputPdfPath(String projectId) =>
      ProjectFileStore.outputPdfPath(projectId);

  static Future<Uint8List?> loadOutputPdf(String projectId) =>
      ProjectFileStore.loadOutputPdf(projectId);
}
