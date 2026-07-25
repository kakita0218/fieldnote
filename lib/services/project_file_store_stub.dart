import 'dart:typed_data';

import '../models/project_summary.dart';

class ProjectFileStore {
  static bool get isAuthoritative => false;

  static Future<void> createProject({
    required String projectId,
    required String projectName,
  }) async {}

  static Future<List<ProjectSummary>> listProjects() async =>
      const <ProjectSummary>[];

  static Future<Map<String, dynamic>?> loadProject(String projectId) async =>
      null;

  static Future<void> saveOriginalPdf({
    required String projectId,
    required String projectName,
    required Uint8List bytes,
  }) async {}

  static Future<void> saveSnapshot({
    required String projectId,
    required String projectName,
    required Map<String, dynamic> metadata,
    required List<Map<String, dynamic>> pins,
    required List<Map<String, dynamic>> strokes,
    required List<Map<String, dynamic>> photos,
  }) async {}

  static Future<void> savePhoto({
    required String projectId,
    required String projectName,
    required String pinId,
    required int pinNumber,
    required String photoId,
    required String fileName,
    required Uint8List bytes,
  }) async {}

  static Future<List<Map<String, dynamic>>?> loadPhotoMetadata(
    String projectId,
  ) async =>
      null;

  static Future<List<Map<String, dynamic>>?> loadPhotosForPin({
    required String projectId,
    required String pinId,
  }) async =>
      null;

  static Future<List<Map<String, dynamic>>?> loadAllPhotos(
    String projectId,
  ) async =>
      null;

  static Future<void> deletePhotosForPin({
    required String projectId,
    required String pinId,
  }) async {}

  static Future<void> renameProject(String projectId, String newName) async {}

  static Future<void> deleteProject(String projectId) async {}

  static Future<String?> sourcePdfPath(String projectId) async => null;

  static Future<String?> outputPdfPath(String projectId) async => null;

  static Future<Uint8List?> loadOutputPdf(String projectId) async => null;
}
