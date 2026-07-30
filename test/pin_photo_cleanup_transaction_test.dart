import 'dart:io';
import 'dart:math' as math;

import 'package:fieldnote/services/project_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel pathProviderChannel =
      MethodChannel('plugins.flutter.io/path_provider');

  late Directory testRoot;
  late Directory documents;
  late Directory support;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    testRoot = await Directory.systemTemp.createTemp('fieldnote-pin-cleanup-');
    documents = Directory(
      '${testRoot.path}${Platform.pathSeparator}Documents',
    );
    support = Directory(
      '${testRoot.path}${Platform.pathSeparator}ApplicationSupport',
    );
    await documents.create(recursive: true);
    await support.create(recursive: true);
    Hive.init('${testRoot.path}${Platform.pathSeparator}Hive');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (MethodCall call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => documents.path,
        'getApplicationSupportDirectory' => support.path,
        _ => null,
      };
    });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    if (await testRoot.exists()) {
      await testRoot.delete(recursive: true);
    }
  });

  test('ピン削除状態と写真削除マーカーを先に保存してから写真を消す', () async {
    const String projectId = 'durable-pin-delete';
    const String projectName = '削除トランザクション';
    const String pinId = 'pin-1';
    const List<Map<String, dynamic>> pin = <Map<String, dynamic>>[
      <String, dynamic>{'id': pinId, 'number': 1, 'pageNumber': 1},
    ];

    await ProjectRepository.createProject(id: projectId, name: projectName);
    await ProjectRepository.savePdfOnce(
      projectId: projectId,
      projectName: projectName,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    await ProjectRepository.saveProjectSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: pin,
      strokes: const <Map<String, dynamic>>[],
    );
    await ProjectRepository.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: pinId,
      pinNumber: 1,
      photoId: 'photo-1',
      fileName: '001.jpg',
      bytes: Uint8List.fromList(<int>[4, 5, 6]),
    );

    // This is the durable checkpoint written before deleting photo bytes.
    await ProjectRepository.saveProjectSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{
        'pendingPhotoCleanupPinIds': <String>[pinId],
      },
      pins: const <Map<String, dynamic>>[],
      strokes: const <Map<String, dynamic>>[],
    );

    final Map<String, dynamic>? interrupted =
        await ProjectRepository.loadProject(projectId);
    expect(interrupted?['pins'], isEmpty);
    expect(interrupted?['pendingPhotoCleanupPinIds'], <String>[pinId]);
    final Directory stagedPhotoDirectory = Directory(
      '${documents.path}${Platform.pathSeparator}$projectName'
      '${Platform.pathSeparator}写真'
      '${Platform.pathSeparator}.moving-$pinId',
    );
    expect(
      await File(
        '${stagedPhotoDirectory.path}${Platform.pathSeparator}001.jpg',
      ).readAsBytes(),
      <int>[4, 5, 6],
    );

    await ProjectRepository.deletePhotosForPin(
      projectId: projectId,
      pinId: pinId,
    );
    await ProjectRepository.saveProjectSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{
        'pendingPhotoCleanupPinIds': <String>[],
      },
      pins: const <Map<String, dynamic>>[],
      strokes: const <Map<String, dynamic>>[],
    );

    final Map<String, dynamic>? completed =
        await ProjectRepository.loadProject(projectId);
    expect(completed?['pins'], isEmpty);
    expect(completed?['pendingPhotoCleanupPinIds'], isEmpty);
    expect(await stagedPhotoDirectory.exists(), isFalse);
    expect(
      await ProjectRepository.loadPhotosForPin(
        projectId: projectId,
        pinId: pinId,
      ),
      isEmpty,
    );
  });

  test('書き出し用写真をIDごとに1件ずつ読み込める', () async {
    const String projectId = 'single-photo-read';
    const String projectName = '写真単体読込';
    await ProjectRepository.createProject(id: projectId, name: projectName);
    await ProjectRepository.savePdfOnce(
      projectId: projectId,
      projectName: projectName,
      bytes: Uint8List.fromList(<int>[1]),
    );
    await ProjectRepository.saveProjectSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'pin-1', 'number': 1, 'pageNumber': 1},
      ],
      strokes: const <Map<String, dynamic>>[],
    );
    await ProjectRepository.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: 'pin-1',
      pinNumber: 1,
      photoId: 'photo-a',
      fileName: '001.jpg',
      bytes: Uint8List.fromList(<int>[10, 11, 12]),
    );
    await ProjectRepository.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: 'pin-1',
      pinNumber: 1,
      photoId: 'photo-b',
      fileName: '002.jpg',
      bytes: Uint8List.fromList(<int>[20, 21, 22]),
    );

    final List<Map<String, dynamic>> metadata =
        await ProjectRepository.loadPhotoMetadata(projectId);
    expect(metadata, hasLength(2));
    expect(
        metadata.every((Map<String, dynamic> row) => !row.containsKey('bytes')),
        isTrue);
    expect(
      await ProjectRepository.loadPhotoBytes(
        projectId: projectId,
        photoId: 'photo-a',
        pinNumber: 1,
        fileName: '001.jpg',
      ),
      Uint8List.fromList(<int>[10, 11, 12]),
    );
    expect(
      await ProjectRepository.loadPhotoBytes(
        projectId: projectId,
        photoId: 'photo-b',
        pinNumber: 1,
        fileName: '002.jpg',
      ),
      Uint8List.fromList(<int>[20, 21, 22]),
    );

    final List<List<int>> visitedBytes = <List<int>>[];
    await ProjectRepository.visitPhotoBytes(
      projectId: projectId,
      photos: <Map<String, dynamic>>[
        ...metadata,
        <String, dynamic>{
          'photoId': 'invalid-path',
          'pinNumber': 1,
          'fileName': '../001.jpg',
        },
      ],
      visitor: (
        int index,
        Map<String, dynamic> photo,
        Uint8List bytes,
      ) async {
        visitedBytes.add(bytes);
      },
    );
    expect(
      visitedBytes,
      <List<int>>[
        <int>[10, 11, 12],
        <int>[20, 21, 22],
      ],
    );
  });

  test('写真プレビューは原寸を1枚ずつ縮小して再利用する', () async {
    const String projectId = 'sequential-photo-previews';
    const String projectName = '写真プレビュー';
    await ProjectRepository.createProject(id: projectId, name: projectName);
    await ProjectRepository.savePdfOnce(
      projectId: projectId,
      projectName: projectName,
      bytes: Uint8List.fromList(<int>[1]),
    );
    await ProjectRepository.saveProjectSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'pin-1', 'number': 1, 'pageNumber': 1},
      ],
      strokes: const <Map<String, dynamic>>[],
    );
    await ProjectRepository.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: 'pin-1',
      pinNumber: 1,
      photoId: 'preview-a',
      fileName: '001.jpg',
      bytes: Uint8List.fromList(<int>[10, 11, 12]),
    );
    await ProjectRepository.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: 'pin-1',
      pinNumber: 1,
      photoId: 'preview-b',
      fileName: '002.jpg',
      bytes: Uint8List.fromList(<int>[20, 21, 22]),
    );

    int activeBuilders = 0;
    int maximumActiveBuilders = 0;
    int builderCalls = 0;
    final List<Map<String, dynamic>> firstLoad =
        await ProjectRepository.loadPhotoPreviewsForPin(
      projectId: projectId,
      pinId: 'pin-1',
      thumbnailBuilder: (Uint8List bytes) async {
        builderCalls++;
        activeBuilders++;
        maximumActiveBuilders = math.max(maximumActiveBuilders, activeBuilders);
        await Future<void>.delayed(Duration.zero);
        activeBuilders--;
        return Uint8List.fromList(<int>[bytes.first]);
      },
    );

    expect(builderCalls, 2);
    expect(maximumActiveBuilders, 1);
    expect(
      firstLoad.map((Map<String, dynamic> row) => row['bytes']).toList(),
      <Uint8List>[
        Uint8List.fromList(<int>[10]),
        Uint8List.fromList(<int>[20]),
      ],
    );

    final List<Map<String, dynamic>> secondLoad =
        await ProjectRepository.loadPhotoPreviewsForPin(
      projectId: projectId,
      pinId: 'pin-1',
      thumbnailBuilder: (Uint8List bytes) {
        throw StateError('cached previews must not be rebuilt');
      },
    );
    expect(
      secondLoad.map((Map<String, dynamic> row) => row['bytes']).toList(),
      <Uint8List>[
        Uint8List.fromList(<int>[10]),
        Uint8List.fromList(<int>[20]),
      ],
    );
  });

  test('縮小できない写真も原寸を保持せず件数を保つ', () async {
    const String projectId = 'unavailable-photo-preview';
    const String projectName = '写真プレビュー失敗';
    await ProjectRepository.createProject(id: projectId, name: projectName);
    await ProjectRepository.savePdfOnce(
      projectId: projectId,
      projectName: projectName,
      bytes: Uint8List.fromList(<int>[1]),
    );
    await ProjectRepository.saveProjectSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'pin-1', 'number': 1, 'pageNumber': 1},
      ],
      strokes: const <Map<String, dynamic>>[],
    );
    final Uint8List fullSizeBytes = Uint8List(4096);
    await ProjectRepository.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: 'pin-1',
      pinNumber: 1,
      photoId: 'broken-preview',
      fileName: '001.jpg',
      bytes: fullSizeBytes,
    );

    final List<Map<String, dynamic>> previews =
        await ProjectRepository.loadPhotoPreviewsForPin(
      projectId: projectId,
      pinId: 'pin-1',
      thumbnailBuilder: (Uint8List bytes) {
        throw StateError('unsupported image');
      },
    );

    expect(previews, hasLength(1));
    expect(previews.single['bytes'], isA<Uint8List>());
    expect((previews.single['bytes'] as Uint8List).length, lessThan(4096));
  });

  test('マニフェスト更新前に残ったJPEGをフォルダ走査で回収する', () async {
    const String projectId = 'orphan-photo-recovery';
    const String projectName = '孤立写真回収';
    await ProjectRepository.createProject(id: projectId, name: projectName);
    await ProjectRepository.savePdfOnce(
      projectId: projectId,
      projectName: projectName,
      bytes: Uint8List.fromList(<int>[1]),
    );
    await ProjectRepository.saveProjectSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'pin-1', 'number': 1, 'pageNumber': 1},
      ],
      strokes: const <Map<String, dynamic>>[],
    );
    final Directory photoDirectory = Directory(
      '${documents.path}${Platform.pathSeparator}$projectName'
      '${Platform.pathSeparator}写真${Platform.pathSeparator}001',
    );
    await photoDirectory.create(recursive: true);
    await File(
      '${photoDirectory.path}${Platform.pathSeparator}001.jpg',
    ).writeAsBytes(<int>[31, 32, 33]);

    final List<Map<String, dynamic>> recovered =
        await ProjectRepository.loadPhotosForPin(
      projectId: projectId,
      pinId: 'pin-1',
    );

    expect(recovered, hasLength(1));
    expect(recovered.single['pinId'], 'pin-1');
    expect(recovered.single['fileName'], '001.jpg');
    expect(recovered.single['bytes'], Uint8List.fromList(<int>[31, 32, 33]));
  });
}
