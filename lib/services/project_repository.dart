import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/project_summary.dart';

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

  // Read-only migration source used by v4.
  static const String _legacyBoxName = 'fieldnote_projects_v2';
  static const String _legacyIndexKey = '__project_index__';

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
    final Box<dynamic> meta = await _metaBox();
    final Box<dynamic> pinsBox = await _pinsBox();
    final Box<dynamic> photoMetaBox = await _photoMetaBox();
    final List<ProjectSummary> projects = <ProjectSummary>[];

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
      final Map<String, dynamic> record = _asMap(meta.get(key));
      if (record.isEmpty) continue;
      final DateTime updatedAt =
          DateTime.tryParse(record['updatedAt']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
      final List<dynamic> pins = _asList(pinsBox.get(projectId));
      projects.add(ProjectSummary(
        id: projectId,
        name: record['projectName']?.toString() ?? '名称未設定',
        updatedAt: updatedAt,
        pageCount: (record['pageCount'] as num?)?.toInt() ?? 0,
        photoCount: photoCounts[projectId] ?? 0,
        pinCount: pins.length,
      ));
    }

    // Until a legacy project is opened/migrated, keep it visible on Home.
    try {
      final Box<dynamic> legacy = await Hive.openBox<dynamic>(_legacyBoxName);
      final String? rawIndex = legacy.get(_legacyIndexKey) as String?;
      if (rawIndex != null) {
        final List<dynamic> oldList = jsonDecode(rawIndex) as List<dynamic>;
        final Set<String> existingIds = projects.map((e) => e.id).toSet();
        for (final dynamic item in oldList) {
          final ProjectSummary old = ProjectSummary.fromJson(_asMap(item));
          if (!existingIds.contains(old.id)) projects.add(old);
        }
      }
    } catch (_) {
      // A broken legacy index must not hide valid v5 projects.
    }

    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
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

  static Future<void> savePdfOnce({
    required String projectId,
    required String projectName,
    required String pdfName,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) throw StateError('PDFデータが空です。');
    final Box<dynamic> box = await _pdfBox();
    await box.put(projectId, Uint8List.fromList(bytes));
    await touchProject(
      id: projectId,
      name: projectName,
      values: <String, dynamic>{'pdfName': pdfName},
    );
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

  static Future<void> savePhoto({
    required String projectId,
    required String pinId,
    required String photoId,
    required String fileName,
    required Uint8List bytes,
    Uint8List? thumbnailBytes,
  }) async {
    if (bytes.isEmpty) throw StateError('写真データが空です。');
    final Box<dynamic> bytesBox = await _photoBytesBox();
    final Box<dynamic> metaBox = await _photoMetaBox();
    final Box<dynamic> thumbnailBox = await _thumbnailBox();
    final String key = _photoKey(projectId, photoId);

    // Binary first, metadata second. A crash cannot leave visible metadata that
    // points to missing image bytes.
    await bytesBox.put(key, Uint8List.fromList(bytes));
    if (thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
      await thumbnailBox.put(key, Uint8List.fromList(thumbnailBytes));
    }
    await metaBox.put(key, <String, dynamic>{
      'projectId': projectId,
      'pinId': pinId,
      'photoId': photoId,
      'fileName': fileName,
      'createdAt': DateTime.now().toIso8601String(),
      'byteLength': bytes.length,
    });
  }

  static Future<List<Map<String, dynamic>>> loadPhotoMetadata(
      String projectId) async {
    final Box<dynamic> metaBox = await _photoMetaBox();
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (final dynamic key in metaBox.keys) {
      final Map<String, dynamic> meta = _asMap(metaBox.get(key));
      if (meta['projectId']?.toString() == projectId) result.add(meta);
    }
    result.sort((a, b) =>
        (a['createdAt']?.toString() ?? '').compareTo(b['createdAt']?.toString() ?? ''));
    return result;
  }

  static Future<List<Map<String, dynamic>>> loadPhotosForPin({
    required String projectId,
    required String pinId,
  }) async {
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
    result.sort((a, b) =>
        (a['createdAt']?.toString() ?? '').compareTo(b['createdAt']?.toString() ?? ''));
    return result;
  }

  static Future<List<Map<String, dynamic>>> loadAllPhotos(
      String projectId) async {
    final List<Map<String, dynamic>> meta =
        await loadPhotoMetadata(projectId);
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

  static Future<void> deletePhotosForPin({
    required String projectId,
    required String pinId,
  }) async {
    final Box<dynamic> metaBox = await _photoMetaBox();
    final Box<dynamic> bytesBox = await _photoBytesBox();
    final Box<dynamic> thumbnailBox = await _thumbnailBox();
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
  }

  static Future<Map<String, dynamic>?> loadProject(String id) async {
    final Box<dynamic> metaBox = await _metaBox();
    Map<String, dynamic> meta = _asMap(metaBox.get(id));

    if (meta.isEmpty) {
      final Map<String, dynamic>? migrated = await _migrateLegacyProject(id);
      if (migrated == null) return null;
      meta = _asMap((await _metaBox()).get(id));
    }

    final Uint8List? pdfBytes = _asBytes((await _pdfBox()).get(id));
    if (pdfBytes == null || pdfBytes.isEmpty) return null;

    final List<dynamic> pins = _asList((await _pinsBox()).get(id));
    final List<dynamic> strokes = _asList((await _drawingsBox()).get(id));
    final List<Map<String, dynamic>> photoMeta = await loadPhotoMetadata(id);

    // Only metadata is loaded at startup. Full image bytes are loaded per pin.
    return <String, dynamic>{
      ...meta,
      'pdfBytes': pdfBytes,
      'pins': pins,
      'strokes': strokes,
      'photoMeta': photoMeta,
    };
  }

  static Future<Map<String, dynamic>?> _migrateLegacyProject(String id) async {
    try {
      final Box<dynamic> legacy = await Hive.openBox<dynamic>(_legacyBoxName);
      final String? raw = legacy.get('project_$id') as String?;
      if (raw == null) return null;
      final Map<String, dynamic> old =
          jsonDecode(raw) as Map<String, dynamic>;
      final Uint8List? pdf = _asBytes(old['pdfBytes']);
      if (pdf == null || pdf.isEmpty) return null;
      final String name = old['projectName']?.toString() ?? '名称未設定';
      await savePdfOnce(
        projectId: id,
        projectName: name,
        pdfName: old['pdfName']?.toString() ?? '図面.pdf',
        bytes: pdf,
      );
      await savePins(
        projectId: id,
        pins: _asList(old['pins']).map(_asMap).toList(),
      );
      await saveDrawings(
        projectId: id,
        strokes: _asList(old['strokes']).map(_asMap).toList(),
      );
      await touchProject(
        id: id,
        name: name,
        values: <String, dynamic>{
          'currentPage': old['currentPage'] ?? 1,
          'nextPinNumber': old['nextPinNumber'] ?? 1,
          'penColor': old['penColor'],
          'penWidth': old['penWidth'],
          'migratedFromV4': true,
        },
      );

      final Map<String, dynamic> oldPhotos = _asMap(old['photos']);
      for (final MapEntry<String, dynamic> entry in oldPhotos.entries) {
        for (final dynamic rawPhoto in _asList(entry.value)) {
          final Map<String, dynamic> photo = _asMap(rawPhoto);
          final Uint8List? bytes = _asBytes(photo['bytes']);
          if (bytes == null || bytes.isEmpty) continue;
          await savePhoto(
            projectId: id,
            pinId: entry.key,
            photoId: photo['id']?.toString() ??
                '${entry.key}-${DateTime.now().microsecondsSinceEpoch}',
            fileName: photo['fileName']?.toString() ?? '001.jpg',
            bytes: bytes,
          );
        }
      }
      return old;
    } catch (_) {
      return null;
    }
  }

  static Future<void> renameProject(String id, String name) async {
    await touchProject(id: id, name: name);
  }

  static Future<void> deleteProject(String id) async {
    await (await _metaBox()).delete(id);
    await (await _pdfBox()).delete(id);
    await (await _pinsBox()).delete(id);
    await (await _drawingsBox()).delete(id);

    final Box<dynamic> photoMeta = await _photoMetaBox();
    final Box<dynamic> photoBytes = await _photoBytesBox();
    final Box<dynamic> thumbnails = await _thumbnailBox();
    final List<dynamic> keys = <dynamic>[];
    for (final dynamic key in photoMeta.keys) {
      final Map<String, dynamic> meta = _asMap(photoMeta.get(key));
      if (meta['projectId']?.toString() == id) keys.add(key);
    }
    await photoMeta.deleteAll(keys);
    await photoBytes.deleteAll(keys);
    await thumbnails.deleteAll(keys);

    // Remove legacy copy only after v5 deletion was requested explicitly.
    try {
      final Box<dynamic> legacy = await Hive.openBox<dynamic>(_legacyBoxName);
      await legacy.delete('project_$id');
    } catch (_) {}
  }
}
