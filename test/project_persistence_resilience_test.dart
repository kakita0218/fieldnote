import 'dart:convert';
import 'dart:io';

import 'package:fieldnote/services/project_file_store.dart';
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
  late Directory outside;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    testRoot = await Directory.systemTemp.createTemp(
      'fieldnote-persistence-resilience-',
    );
    documents = Directory(
      '${testRoot.path}${Platform.pathSeparator}Documents',
    );
    support = Directory(
      '${testRoot.path}${Platform.pathSeparator}ApplicationSupport',
    );
    outside = Directory(
      '${testRoot.path}${Platform.pathSeparator}OutsideDocuments',
    );
    await documents.create(recursive: true);
    await support.create(recursive: true);
    await outside.create(recursive: true);
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

  test('キャッシュ済みパスが別案件へ差し替わっても案件IDを再検証する', () async {
    await ProjectFileStore.createProject(
      projectId: 'project-a',
      projectName: '案件A',
    );
    await ProjectFileStore.saveOriginalPdf(
      projectId: 'project-a',
      projectName: '案件A',
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    await ProjectFileStore.createProject(
      projectId: 'project-b',
      projectName: '案件B',
    );
    await ProjectFileStore.saveOriginalPdf(
      projectId: 'project-b',
      projectName: '案件B',
      bytes: Uint8List.fromList(<int>[4, 5, 6]),
    );
    await ProjectFileStore.listProjects();

    await Directory(
      '${documents.path}${Platform.pathSeparator}案件A',
    ).rename('${outside.path}${Platform.pathSeparator}案件A');
    await Directory(
      '${documents.path}${Platform.pathSeparator}案件B',
    ).rename('${documents.path}${Platform.pathSeparator}案件A');

    expect(await ProjectFileStore.loadProject('project-a'), isNull);
    final Map<String, dynamic>? projectB =
        await ProjectFileStore.loadProject('project-b');
    expect(projectB?['projectId'], 'project-b');
    expect(projectB?['pdfBytes'], Uint8List.fromList(<int>[4, 5, 6]));
  });

  test('Filesで外部削除した案件を古いHiveメタ情報から再表示しない', () async {
    await ProjectRepository.createProject(
      id: 'externally-removed',
      name: '外部削除',
    );
    await ProjectRepository.savePdfOnce(
      projectId: 'externally-removed',
      projectName: '外部削除',
      bytes: Uint8List.fromList(<int>[7, 8, 9]),
    );
    expect(
      (await ProjectRepository.listProjects()).map((project) => project.id),
      contains('externally-removed'),
    );

    await Directory(
      '${documents.path}${Platform.pathSeparator}外部削除',
    ).rename('${outside.path}${Platform.pathSeparator}外部削除');

    expect(
      (await ProjectRepository.listProjects()).map((project) => project.id),
      isNot(contains('externally-removed')),
    );
  });

  test('既存最大番号より後ろへ保存し写真を上書きしない', () async {
    const String projectId = 'photo-collision';
    const String projectName = '写真衝突';
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
        <String, dynamic>{'id': 'pin-1', 'number': 1},
      ],
      strokes: const <Map<String, dynamic>>[],
    );
    expect(
      await ProjectRepository.savePhoto(
        projectId: projectId,
        projectName: projectName,
        pinId: 'pin-1',
        pinNumber: 1,
        photoId: 'photo-1',
        fileName: '001.jpg',
        bytes: Uint8List.fromList(<int>[1, 1, 1]),
      ),
      '001.jpg',
    );
    expect(
      await ProjectRepository.savePhoto(
        projectId: projectId,
        projectName: projectName,
        pinId: 'pin-1',
        pinNumber: 1,
        photoId: 'photo-3',
        fileName: '003.jpg',
        bytes: Uint8List.fromList(<int>[3, 3, 3]),
      ),
      '003.jpg',
    );
    expect(
      await ProjectRepository.savePhoto(
        projectId: projectId,
        projectName: projectName,
        pinId: 'pin-1',
        pinNumber: 1,
        photoId: 'photo-new',
        fileName: '003.jpg',
        bytes: Uint8List.fromList(<int>[4, 4, 4]),
      ),
      '004.jpg',
    );

    final Directory photos = Directory(
      '${documents.path}${Platform.pathSeparator}$projectName'
      '${Platform.pathSeparator}写真${Platform.pathSeparator}001',
    );
    expect(
      await File('${photos.path}${Platform.pathSeparator}003.jpg')
          .readAsBytes(),
      <int>[3, 3, 3],
    );
    expect(
      await File('${photos.path}${Platform.pathSeparator}004.jpg')
          .readAsBytes(),
      <int>[4, 4, 4],
    );
  });

  test('中断された写真フォルダ移動をmanifestのピン番号へ回収する', () async {
    const String projectId = 'moving-photo-recovery';
    const String projectName = '写真移動復元';
    await ProjectFileStore.createProject(
      projectId: projectId,
      projectName: projectName,
    );
    await ProjectFileStore.saveOriginalPdf(
      projectId: projectId,
      projectName: projectName,
      bytes: Uint8List.fromList(<int>[1, 2]),
    );
    await ProjectFileStore.saveSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'pin-recover', 'number': 2},
      ],
      strokes: const <Map<String, dynamic>>[],
      photos: const <Map<String, dynamic>>[],
    );
    await ProjectFileStore.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: 'pin-recover',
      pinNumber: 2,
      photoId: 'photo-recover',
      fileName: '001.jpg',
      bytes: Uint8List.fromList(<int>[9, 9, 9]),
    );
    final Directory photosRoot = Directory(
      '${documents.path}${Platform.pathSeparator}$projectName'
      '${Platform.pathSeparator}写真',
    );
    await Directory(
      '${photosRoot.path}${Platform.pathSeparator}002',
    ).rename(
      '${photosRoot.path}${Platform.pathSeparator}.moving-pin-recover',
    );

    await ProjectFileStore.listProjects();

    expect(
      await Directory(
        '${photosRoot.path}${Platform.pathSeparator}.moving-pin-recover',
      ).exists(),
      isFalse,
    );
    expect(
      await File(
        '${photosRoot.path}${Platform.pathSeparator}002'
        '${Platform.pathSeparator}001.jpg',
      ).readAsBytes(),
      <int>[9, 9, 9],
    );
  });

  test('Undo中の写真を退避し残存ピンの番号移動とRedo復元を分離する', () async {
    const String projectId = 'undo-photo-staging';
    const String projectName = 'Undo写真退避';
    const List<Map<String, dynamic>> originalPins = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'pin-a', 'number': 1},
      <String, dynamic>{'id': 'pin-b', 'number': 2},
    ];
    await ProjectFileStore.createProject(
      projectId: projectId,
      projectName: projectName,
    );
    await ProjectFileStore.saveOriginalPdf(
      projectId: projectId,
      projectName: projectName,
      bytes: Uint8List.fromList(<int>[1]),
    );
    await ProjectFileStore.saveSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: originalPins,
      strokes: const <Map<String, dynamic>>[],
      photos: const <Map<String, dynamic>>[],
    );
    await ProjectFileStore.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: 'pin-a',
      pinNumber: 1,
      photoId: 'photo-a',
      fileName: '001.jpg',
      bytes: Uint8List.fromList(<int>[1, 1]),
    );
    await ProjectFileStore.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: 'pin-b',
      pinNumber: 2,
      photoId: 'photo-b',
      fileName: '001.jpg',
      bytes: Uint8List.fromList(<int>[2, 2]),
    );
    final List<Map<String, dynamic>> photoMetadata =
        (await ProjectFileStore.loadPhotoMetadata(projectId))!;

    await ProjectFileStore.saveSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'pin-b', 'number': 1},
      ],
      strokes: const <Map<String, dynamic>>[],
      photos: photoMetadata,
    );
    final Directory photosRoot = Directory(
      '${documents.path}${Platform.pathSeparator}$projectName'
      '${Platform.pathSeparator}写真',
    );
    expect(
      await File(
        '${photosRoot.path}${Platform.pathSeparator}001'
        '${Platform.pathSeparator}001.jpg',
      ).readAsBytes(),
      <int>[2, 2],
    );
    expect(
      await File(
        '${photosRoot.path}${Platform.pathSeparator}.moving-pin-a'
        '${Platform.pathSeparator}001.jpg',
      ).readAsBytes(),
      <int>[1, 1],
    );

    await ProjectFileStore.saveSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'pin-b', 'number': 1},
        <String, dynamic>{'id': 'pin-a', 'number': 2},
      ],
      strokes: const <Map<String, dynamic>>[],
      photos: photoMetadata,
    );
    expect(
      await File(
        '${photosRoot.path}${Platform.pathSeparator}002'
        '${Platform.pathSeparator}001.jpg',
      ).readAsBytes(),
      <int>[1, 1],
    );
    expect(
      await Directory(
        '${photosRoot.path}${Platform.pathSeparator}.moving-pin-a',
      ).exists(),
      isFalse,
    );

    final List<Map<String, dynamic>> metadataAfterRedo =
        (await ProjectFileStore.loadPhotoMetadata(projectId))!;
    await ProjectFileStore.saveSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'pin-b', 'number': 1},
      ],
      strokes: const <Map<String, dynamic>>[],
      photos: metadataAfterRedo,
    );
    expect(
      await Directory(
        '${photosRoot.path}${Platform.pathSeparator}.moving-pin-a',
      ).exists(),
      isTrue,
    );
    await ProjectFileStore.deletePhotosForPin(
      projectId: projectId,
      pinId: 'pin-a',
    );
    expect(
      await Directory(
        '${photosRoot.path}${Platform.pathSeparator}.moving-pin-a',
      ).exists(),
      isFalse,
    );
    final Map<String, dynamic>? afterDiscard =
        await ProjectFileStore.loadProject(projectId);
    expect(
      (afterDiscard?['photos'] as List<dynamic>).where(
        (dynamic photo) =>
            photo is Map && photo['pinId']?.toString() == 'pin-a',
      ),
      isEmpty,
    );
  });

  test('中断済みlegacy移行を完全な一時フォルダから再コミットする', () async {
    const String projectId = 'interrupted-legacy';
    const String projectName = '中断移行';
    final Uint8List pdfBytes = Uint8List.fromList(<int>[5, 4, 3, 2]);
    final Uint8List photoBytes = Uint8List.fromList(<int>[8, 7, 6]);
    await ProjectFileStore.createProject(
      projectId: projectId,
      projectName: projectName,
    );
    await ProjectFileStore.saveOriginalPdf(
      projectId: projectId,
      projectName: projectName,
      bytes: pdfBytes,
    );
    final String migrationToken =
        base64Url.encode(utf8.encode(projectId)).replaceAll('=', '');
    final Directory staleStaging = Directory(
      '${documents.path}${Platform.pathSeparator}'
      '.fieldnote-migration-$migrationToken-stale',
    );
    await staleStaging.create(recursive: true);
    await File(
      '${staleStaging.path}${Platform.pathSeparator}partial.tmp',
    ).writeAsBytes(<int>[1]);

    final Box<dynamic> legacy =
        await Hive.openBox<dynamic>('fieldnote_projects_v2');
    await legacy.put(
      'project_$projectId',
      jsonEncode(<String, dynamic>{
        'projectId': projectId,
        'projectName': projectName,
        'pdfBytes': base64Encode(pdfBytes),
        'pageCount': 2,
        'currentPage': 2,
        'nextPinNumber': 2,
        'pins': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'legacy-pin',
            'number': 1,
            'pageNumber': 1,
          },
        ],
        'strokes': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'legacy-stroke',
            'pageNumber': 1,
            'points': <dynamic>[],
          },
        ],
        'photos': <String, dynamic>{
          'legacy-pin': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'legacy-photo',
              'fileName': '001.jpg',
              'bytes': base64Encode(photoBytes),
            },
          ],
        },
      }),
    );

    final Map<String, dynamic>? migrated =
        await ProjectRepository.loadProject(projectId);

    expect(migrated, isNotNull);
    expect(migrated?['migratedFromV4'], isTrue);
    expect(migrated?['pins'], hasLength(1));
    expect(migrated?['strokes'], hasLength(1));
    final List<Map<String, dynamic>> photos =
        await ProjectRepository.loadPhotosForPin(
      projectId: projectId,
      pinId: 'legacy-pin',
    );
    expect(photos, hasLength(1));
    expect(photos.single['bytes'], photoBytes);
    expect(await staleStaging.exists(), isFalse);
    expect(legacy.get('project_$projectId'), isNull);

    await Directory(
      '${documents.path}${Platform.pathSeparator}$projectName',
    ).rename('${outside.path}${Platform.pathSeparator}$projectName');
    expect(
      (await ProjectRepository.listProjects()).map((project) => project.id),
      isNot(contains(projectId)),
    );
  });

  test('中断済みHive v5移行を残存バイナリから再開する', () async {
    const String projectId = 'interrupted-hive-v5';
    const String projectName = 'Hive v5中断移行';
    final Uint8List pdfBytes = Uint8List.fromList(<int>[4, 3, 2, 1]);
    final Uint8List photoBytes = Uint8List.fromList(<int>[6, 7, 8]);
    await (await Hive.openBox<dynamic>('fieldnote_meta_v5')).put(
      projectId,
      <String, dynamic>{
        'projectId': projectId,
        'projectName': projectName,
        'pageCount': 3,
      },
    );
    await (await Hive.openBox<dynamic>('fieldnote_pdf_v5'))
        .put(projectId, pdfBytes);
    await (await Hive.openBox<dynamic>('fieldnote_pins_v5')).put(
      projectId,
      <Map<String, dynamic>>[
        <String, dynamic>{'id': 'v5-pin', 'number': 1},
      ],
    );
    await (await Hive.openBox<dynamic>('fieldnote_drawings_v5')).put(
      projectId,
      <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'v5-stroke',
          'pageNumber': 1,
          'points': <dynamic>[],
        },
      ],
    );
    await (await Hive.openBox<dynamic>('fieldnote_photo_meta_v5')).put(
      '$projectId::v5-photo',
      <String, dynamic>{
        'projectId': projectId,
        'pinId': 'v5-pin',
        'pinNumber': 1,
        'photoId': 'v5-photo',
        'fileName': '001.jpg',
      },
    );
    await (await Hive.openBox<dynamic>('fieldnote_photo_bytes_v5')).put(
      '$projectId::v5-photo',
      photoBytes,
    );

    // This is the visible state left by the old migration after committing
    // only the PDF and its initial empty manifest.
    await ProjectFileStore.createProject(
      projectId: projectId,
      projectName: projectName,
    );
    await ProjectFileStore.saveOriginalPdf(
      projectId: projectId,
      projectName: projectName,
      bytes: pdfBytes,
    );

    final Map<String, dynamic>? migrated =
        await ProjectRepository.loadProject(projectId);

    expect(migrated?['migratedFromHiveV5'], isTrue);
    expect(migrated?['pins'], hasLength(1));
    expect(migrated?['strokes'], hasLength(1));
    final List<Map<String, dynamic>> photos =
        await ProjectRepository.loadPhotosForPin(
      projectId: projectId,
      pinId: 'v5-pin',
    );
    expect(photos, hasLength(1));
    expect(photos.single['bytes'], photoBytes);
    expect(
      (await Hive.openBox<dynamic>('fieldnote_pdf_v5')).containsKey(projectId),
      isFalse,
    );
  });

  test('移行用一時データの作成失敗時は既存案件を置き換えない', () async {
    const String projectId = 'migration-rollback';
    const String projectName = '移行ロールバック';
    final Uint8List originalPdf = Uint8List.fromList(<int>[1, 2, 3]);
    await ProjectFileStore.createProject(
      projectId: projectId,
      projectName: projectName,
    );
    await ProjectFileStore.saveOriginalPdf(
      projectId: projectId,
      projectName: projectName,
      bytes: originalPdf,
    );
    await ProjectFileStore.saveSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: const <String, dynamic>{},
      pins: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'original-pin', 'number': 1},
      ],
      strokes: const <Map<String, dynamic>>[],
      photos: const <Map<String, dynamic>>[],
    );

    await expectLater(
      ProjectFileStore.importProjectAtomically(
        projectId: projectId,
        projectName: projectName,
        pdfBytes: Uint8List.fromList(<int>[9, 9, 9]),
        metadata: <String, dynamic>{'notJson': Object()},
        pins: const <Map<String, dynamic>>[
          <String, dynamic>{'id': 'replacement-pin', 'number': 1},
        ],
        strokes: const <Map<String, dynamic>>[],
        photos: const <Map<String, dynamic>>[],
      ),
      throwsA(anything),
    );

    final Map<String, dynamic>? project =
        await ProjectFileStore.loadProject(projectId);
    expect(project?['pdfBytes'], originalPdf);
    expect(
      (project?['pins'] as List<dynamic>).single['id'],
      'original-pin',
    );
    final List<FileSystemEntity> migrationArtifacts = await documents
        .list(followLinks: false)
        .where(
          (FileSystemEntity entity) =>
              entity is Directory &&
              entity.uri.pathSegments
                  .where((String segment) => segment.isNotEmpty)
                  .last
                  .startsWith('.fieldnote-migration-'),
        )
        .toList();
    expect(migrationArtifacts, isEmpty);
  });
}
