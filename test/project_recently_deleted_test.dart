import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fieldnote/models/project_summary.dart';
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
  const MethodChannel projectChannel = MethodChannel('jp.fieldnote/project');

  late Directory testRoot;
  late Directory documents;
  late Directory support;
  late Directory recentlyDeleted;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    testRoot = await Directory.systemTemp.createTemp(
      'fieldnote-recently-deleted-',
    );
    documents = Directory('${testRoot.path}${Platform.pathSeparator}Documents');
    support = Directory(
        '${testRoot.path}${Platform.pathSeparator}ApplicationSupport');
    recentlyDeleted =
        Directory('${testRoot.path}${Platform.pathSeparator}RecentlyDeleted');
    await documents.create(recursive: true);
    await support.create(recursive: true);
    await recentlyDeleted.create(recursive: true);
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
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(projectChannel, null);
    await Hive.close();
    if (await testRoot.exists()) {
      await testRoot.delete(recursive: true);
    }
  });

  test('案件フォルダと内部編集データを最近削除へ移し復元できる', () async {
    const String projectId = 'project-recovery-test';
    const String projectName = '復元テスト';
    final Uint8List sourceBytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
    final Uint8List pencilBytes = Uint8List.fromList(<int>[9, 8, 7]);
    final Uint8List pendingBytes = Uint8List.fromList(<int>[6, 5, 4]);
    final Uint8List photoBytes = Uint8List.fromList(<int>[11, 22, 33, 44]);
    final List<Map<String, dynamic>> pins = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'pin-1',
        'number': 1,
        'page': 1,
        'x': 0.25,
        'y': 0.5,
      },
    ];
    final List<Map<String, dynamic>> strokes = <Map<String, dynamic>>[
      <String, dynamic>{
        'page': 1,
        'color': 0xff123456,
        'width': 3.0,
        'points': <Map<String, dynamic>>[
          <String, dynamic>{'x': 10.0, 'y': 20.0},
          <String, dynamic>{'x': 30.0, 'y': 40.0},
        ],
      },
    ];

    await ProjectFileStore.createProject(
      projectId: projectId,
      projectName: projectName,
    );
    await ProjectFileStore.saveOriginalPdf(
      projectId: projectId,
      projectName: projectName,
      bytes: sourceBytes,
    );
    final String sourcePath =
        (await ProjectFileStore.sourcePdfPath(projectId))!;
    await File('$sourcePath.pencilkit').writeAsBytes(pencilBytes, flush: true);
    await File('$sourcePath.pencilkit.pending')
        .writeAsBytes(pendingBytes, flush: true);
    await ProjectFileStore.saveSnapshot(
      projectId: projectId,
      projectName: projectName,
      metadata: <String, dynamic>{
        'pageCount': 2,
        'currentPage': 1,
      },
      pins: pins,
      strokes: strokes,
      photos: const <Map<String, dynamic>>[],
    );
    await ProjectFileStore.savePhoto(
      projectId: projectId,
      projectName: projectName,
      pinId: 'pin-1',
      pinNumber: 1,
      photoId: 'photo-1',
      fileName: '001.jpg',
      bytes: photoBytes,
    );
    final File nestedFile = File(
      '${documents.path}${Platform.pathSeparator}$projectName'
      '${Platform.pathSeparator}添付資料'
      '${Platform.pathSeparator}階層'
      '${Platform.pathSeparator}メモ.txt',
    );
    await nestedFile.parent.create(recursive: true);
    await nestedFile.writeAsString('復元対象の入れ子ファイル', flush: true);

    late Directory trashedProject;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(projectChannel, (MethodCall call) async {
      expect(call.method, 'moveFileItemToTrash');
      final String path =
          (call.arguments as Map<dynamic, dynamic>)['path'] as String;
      final Directory project = Directory(path);
      trashedProject = await project.rename(
        '${recentlyDeleted.path}${Platform.pathSeparator}$projectName',
      );
      return true;
    });

    await ProjectFileStore.deleteProject(projectId);

    expect(
        await Directory(
          '${documents.path}${Platform.pathSeparator}$projectName',
        ).exists(),
        isFalse);
    expect(await File(sourcePath).exists(), isFalse);
    final Directory recovery = Directory(
      '${trashedProject.path}${Platform.pathSeparator}.fieldnote-recovery',
    );
    expect(
      await File(
        '${recovery.path}${Platform.pathSeparator}source.pdf',
      ).readAsBytes(),
      sourceBytes,
    );
    expect(
      await File(
        '${recovery.path}${Platform.pathSeparator}source.pdf.pencilkit',
      ).readAsBytes(),
      pencilBytes,
    );
    expect(
      await File(
        '${recovery.path}${Platform.pathSeparator}'
        'source.pdf.pencilkit.pending',
      ).readAsBytes(),
      pendingBytes,
    );

    final Directory restored = await trashedProject.rename(
      '${documents.path}${Platform.pathSeparator}$projectName',
    );
    final String? restoredSourcePath =
        await ProjectFileStore.sourcePdfPath(projectId);
    expect(restoredSourcePath, sourcePath);
    expect(await File(restoredSourcePath!).readAsBytes(), sourceBytes);
    expect(
      await File('$restoredSourcePath.pencilkit').readAsBytes(),
      pencilBytes,
    );
    expect(
      await File('$restoredSourcePath.pencilkit.pending').readAsBytes(),
      pendingBytes,
    );
    expect(
      await Directory(
        '${restored.path}${Platform.pathSeparator}.fieldnote-recovery',
      ).exists(),
      isFalse,
    );
    expect(
      (await ProjectFileStore.listProjects())
          .map((project) => project.id)
          .contains(projectId),
      isTrue,
    );
    final Map<String, dynamic>? restoredProject =
        await ProjectFileStore.loadProject(projectId);
    expect(restoredProject, isNotNull);
    expect(restoredProject!['pins'], pins);
    expect(restoredProject['strokes'], strokes);
    final List<Map<String, dynamic>>? restoredPhotos =
        await ProjectFileStore.loadPhotosForPin(
      projectId: projectId,
      pinId: 'pin-1',
    );
    expect(restoredPhotos, hasLength(1));
    expect(
      restoredPhotos!.single['bytes'],
      photoBytes,
    );
    expect(
      await File(
        '${restored.path}${Platform.pathSeparator}添付資料'
        '${Platform.pathSeparator}階層'
        '${Platform.pathSeparator}メモ.txt',
      ).readAsString(),
      '復元対象の入れ子ファイル',
    );
  });

  test('最近削除への移動に失敗した場合は案件と元PDFを残す', () async {
    const String projectId = 'project-trash-failure-test';
    const String projectName = '削除失敗テスト';
    final Uint8List sourceBytes = Uint8List.fromList(<int>[3, 1, 4, 1, 5]);

    await ProjectFileStore.createProject(
      projectId: projectId,
      projectName: projectName,
    );
    await ProjectFileStore.saveOriginalPdf(
      projectId: projectId,
      projectName: projectName,
      bytes: sourceBytes,
    );
    final String sourcePath =
        (await ProjectFileStore.sourcePdfPath(projectId))!;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      projectChannel,
      (MethodCall call) async => false,
    );

    await expectLater(
      ProjectFileStore.deleteProject(projectId),
      throwsStateError,
    );

    final Directory project = Directory(
      '${documents.path}${Platform.pathSeparator}$projectName',
    );
    expect(await project.exists(), isTrue);
    expect(await File(sourcePath).readAsBytes(), sourceBytes);
    expect(
      await Directory(
        '${project.path}${Platform.pathSeparator}.fieldnote-recovery',
      ).exists(),
      isFalse,
    );
  });

  test('旧Hive案件をファイルへ移行してから最近削除へ移し完全に復元できる', () async {
    const String projectId = 'legacy-only-project';
    const String projectName = '旧案件復元テスト';
    final Uint8List pdfBytes = Uint8List.fromList(<int>[5, 4, 3, 2, 1]);
    final Uint8List photoBytes = Uint8List.fromList(<int>[90, 80, 70, 60, 50]);
    final List<Map<String, dynamic>> pins = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'legacy-pin',
        'number': 3,
        'page': 2,
        'x': 0.4,
        'y': 0.6,
      },
    ];
    final List<Map<String, dynamic>> strokes = <Map<String, dynamic>>[
      <String, dynamic>{
        'page': 2,
        'color': 0xffabcdef,
        'width': 4.0,
        'points': <Map<String, dynamic>>[
          <String, dynamic>{'x': 1.0, 'y': 2.0},
          <String, dynamic>{'x': 3.0, 'y': 4.0},
        ],
      },
    ];
    final Box<dynamic> legacy =
        await Hive.openBox<dynamic>('fieldnote_projects_v2');
    await legacy.put(
      '__project_index__',
      jsonEncode(
        <Map<String, dynamic>>[
          ProjectSummary(
            id: projectId,
            name: projectName,
            updatedAt: DateTime(2026, 7, 27),
            pageCount: 2,
            photoCount: 1,
            pinCount: 1,
          ).toJson(),
        ],
      ),
    );
    await legacy.put(
      'project_$projectId',
      jsonEncode(
        <String, dynamic>{
          'projectId': projectId,
          'projectName': projectName,
          'pdfBytes': base64Encode(pdfBytes),
          'pageCount': 2,
          'currentPage': 2,
          'nextPinNumber': 4,
          'pins': pins,
          'strokes': strokes,
          'photos': <String, dynamic>{
            'legacy-pin': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'legacy-photo',
                'fileName': 'legacy.jpg',
                'bytes': base64Encode(photoBytes),
              },
            ],
          },
        },
      ),
    );

    expect(
      await documents
          .list(followLinks: false)
          .where((FileSystemEntity entity) => entity is Directory)
          .isEmpty,
      isTrue,
    );
    expect(
      (await ProjectRepository.listProjects()).map((project) => project.id),
      contains(projectId),
    );

    late Directory trashedProject;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(projectChannel, (MethodCall call) async {
      expect(call.method, 'moveFileItemToTrash');
      final String path =
          (call.arguments as Map<dynamic, dynamic>)['path'] as String;
      trashedProject = await Directory(path).rename(
        '${recentlyDeleted.path}${Platform.pathSeparator}$projectName',
      );
      return true;
    });

    await ProjectRepository.deleteProject(projectId);
    expect(await trashedProject.exists(), isTrue);
    expect(
      await documents
          .list(followLinks: false)
          .where((FileSystemEntity entity) => entity is Directory)
          .isEmpty,
      isTrue,
    );

    await trashedProject.rename(
      '${documents.path}${Platform.pathSeparator}$projectName',
    );
    expect(
      (await ProjectRepository.listProjects()).map((project) => project.id),
      contains(projectId),
    );
    final Map<String, dynamic>? restored =
        await ProjectRepository.loadProject(projectId);
    expect(restored, isNotNull);
    expect(restored!['pdfBytes'], pdfBytes);
    expect(restored['pins'], pins);
    expect(restored['strokes'], strokes);
    final List<Map<String, dynamic>> restoredPhotos =
        await ProjectRepository.loadPhotosForPin(
      projectId: projectId,
      pinId: 'legacy-pin',
    );
    expect(restoredPhotos, hasLength(1));
    expect(restoredPhotos.single['photoId'], 'legacy-photo');
    expect(restoredPhotos.single['bytes'], photoBytes);
  });

  test('移動処理中の案件は一覧に再表示せず削除記録を維持する', () async {
    const String projectId = 'blocked-trash-project';
    const String projectName = '移動中テスト';
    final Uint8List sourceBytes =
        Uint8List.fromList(<int>[8, 6, 7, 5, 3, 0, 9]);
    await ProjectRepository.createProject(id: projectId, name: projectName);
    await ProjectRepository.savePdfOnce(
      projectId: projectId,
      projectName: projectName,
      bytes: sourceBytes,
    );

    final Completer<void> channelEntered = Completer<void>();
    final Completer<void> releaseChannel = Completer<void>();
    late Directory trashedProject;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(projectChannel, (MethodCall call) async {
      expect(call.method, 'moveFileItemToTrash');
      if (!channelEntered.isCompleted) channelEntered.complete();
      await releaseChannel.future;
      final String path =
          (call.arguments as Map<dynamic, dynamic>)['path'] as String;
      trashedProject = await Directory(path).rename(
        '${recentlyDeleted.path}${Platform.pathSeparator}$projectName',
      );
      return true;
    });

    final Future<void> deletion = ProjectRepository.deleteProject(projectId);
    await channelEntered.future.timeout(const Duration(seconds: 2));

    late List<ProjectSummary> projectsDuringDeletion;
    late bool tombstonePresent;
    try {
      projectsDuringDeletion = await ProjectRepository.listProjects();
      final Box<dynamic> trash =
          await Hive.openBox<dynamic>('fieldnote_project_trash_v1');
      tombstonePresent = trash.containsKey(projectId);
    } finally {
      if (!releaseChannel.isCompleted) releaseChannel.complete();
    }
    await deletion;

    expect(
      projectsDuringDeletion.map((project) => project.id),
      isNot(contains(projectId)),
    );
    expect(tombstonePresent, isTrue);
    expect(await trashedProject.exists(), isTrue);
    expect(
      (await ProjectRepository.listProjects()).map((project) => project.id),
      isNot(contains(projectId)),
    );
  });

  test('案件一覧の読み込み時に古い復元準備フォルダを削除する', () async {
    const String projectId = 'stale-recovery-staging-project';
    const String projectName = '復元準備掃除テスト';
    await ProjectFileStore.createProject(
      projectId: projectId,
      projectName: projectName,
    );
    final Directory staleStaging = Directory(
      '${documents.path}${Platform.pathSeparator}$projectName'
      '${Platform.pathSeparator}.fieldnote-recovery.tmp-123456',
    );
    await staleStaging.create(recursive: true);
    await File(
      '${staleStaging.path}${Platform.pathSeparator}partial-source.pdf',
    ).writeAsBytes(<int>[1, 2, 3], flush: true);

    expect(await staleStaging.exists(), isTrue);
    expect(
      (await ProjectFileStore.listProjects()).map((project) => project.id),
      contains(projectId),
    );
    expect(await staleStaging.exists(), isFalse);
  });

  test('削除記録は古いキャッシュを隠しFilesからの復元後に解除される', () async {
    const String projectId = 'project-tombstone-test';
    const String projectName = '削除記録テスト';
    final Uint8List sourceBytes = Uint8List.fromList(<int>[2, 7, 1, 8]);

    await ProjectRepository.createProject(id: projectId, name: projectName);
    await ProjectRepository.savePdfOnce(
      projectId: projectId,
      projectName: projectName,
      bytes: sourceBytes,
    );
    final Box<dynamic> legacy =
        await Hive.openBox<dynamic>('fieldnote_projects_v2');
    await legacy.put(
      '__project_index__',
      jsonEncode(
        <Map<String, dynamic>>[
          ProjectSummary(
            id: projectId,
            name: projectName,
            updatedAt: DateTime(2026, 7, 28),
          ).toJson(),
        ],
      ),
    );

    late Directory trashedProject;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(projectChannel, (MethodCall call) async {
      final String path =
          (call.arguments as Map<dynamic, dynamic>)['path'] as String;
      trashedProject = await Directory(path).rename(
        '${recentlyDeleted.path}${Platform.pathSeparator}$projectName',
      );
      return true;
    });

    await ProjectRepository.deleteProject(projectId);
    expect(await ProjectRepository.listProjects(), isEmpty);

    await trashedProject.rename(
      '${documents.path}${Platform.pathSeparator}$projectName',
    );
    final List<ProjectSummary> restored =
        await ProjectRepository.listProjects();
    expect(restored.map((project) => project.id), contains(projectId));
  });
}
