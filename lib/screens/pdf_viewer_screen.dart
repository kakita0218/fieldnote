import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as pdfx;

import '../models/drawing_stroke.dart';
import 'camera_capture_screen.dart';
import '../models/photo_board.dart';
import '../models/photo_data.dart';
import '../models/pin_data.dart';
import '../models/project_pdf_document.dart';
import '../theme/app_colors.dart';
import '../widgets/handwriting_layer.dart';
import '../widgets/single_page_pdf_canvas.dart';
import '../widgets/pin_side_panel.dart';
import '../widgets/touch_interactive_viewer.dart';
import '../services/native_project_service.dart';
import '../services/drawing_serialization.dart';
import '../services/export_layout.dart';
import '../services/project_export_zip_sink.dart';
import '../services/project_repository.dart';
import 'photo_editor_screen.dart';

enum FieldTool {
  select,
  pin,
  pen,
  eraser,
  shape,
  text,
}

const List<Color> _fieldPaletteColors = <Color>[
  Color(0xFF1976D2), // 青
  Color(0xFFE53935), // 赤
  Color(0xFFF4C20D), // 黄
  Color(0xFF2EAD62), // 緑
  Color(0xFF7E57C2), // 紫
  Color(0xFF111111), // 黒
];

String _fieldColorName(Color color) {
  return switch (color.toARGB32()) {
    0xFF1976D2 => '青',
    0xFFE53935 => '赤',
    0xFFF4C20D => '黄',
    0xFF2EAD62 => '緑',
    0xFF7E57C2 => '紫',
    0xFF111111 => '黒',
    _ => 'カスタム色',
  };
}

class _IndexedDrawingStroke {
  const _IndexedDrawingStroke({
    required this.stroke,
    required this.index,
  });

  final DrawingStroke stroke;
  final int index;
}

class _PickedPdfDocument {
  const _PickedPdfDocument({required this.document, required this.bytes});

  final ProjectPdfDocument document;
  final Uint8List bytes;
}

class _DrawingEdit {
  const _DrawingEdit({
    required this.removedStrokes,
    required this.addedStrokes,
  });

  final List<_IndexedDrawingStroke> removedStrokes;
  final List<_IndexedDrawingStroke> addedStrokes;
}

enum _PinEditKind {
  add,
  delete,
  move,
  direction,
}

enum _AnnotationTransformKind {
  textTopLeft,
  textTopRight,
  textBottomRight,
  textBottomLeft,
  rectangleTopLeft,
  rectangleTopRight,
  rectangleBottomRight,
  rectangleBottomLeft,
  rectangleRotation,
  point,
}

enum _ExportPageMode { allPages, annotatedPages }

enum _ExportContent { pins, drawings, both }

class _PinEdit {
  const _PinEdit({
    required this.kind,
    required this.pinId,
    required this.index,
    this.before,
    this.after,
  });

  final _PinEditKind kind;
  final String pinId;
  final int index;
  final PinData? before;
  final PinData? after;

  _PinEdit copyWith({
    PinData? before,
    PinData? after,
  }) {
    return _PinEdit(
      kind: kind,
      pinId: pinId,
      index: index,
      before: before ?? this.before,
      after: after ?? this.after,
    );
  }
}

class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.projectId,
    required this.projectName,
    this.isNewProject = false,
    this.exportOnOpen = false,
    this.simplifiedMobile = false,
  });

  final String projectId;
  final String projectName;
  final bool isNewProject;
  final bool exportOnOpen;
  final bool simplifiedMobile;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen>
    with WidgetsBindingObserver {
  static final Uint8List _unavailablePhotoPreviewBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  pdfx.PdfDocument? _pdfDocument;
  Uint8List? _pageImageBytes;
  double _pageAspectRatio = 1;
  bool _isRenderingPage = false;
  int _renderRequestSequence = 0;
  int? _failedRenderPage;
  final Map<int, Future<Uint8List?>> _thumbnailFutures =
      <int, Future<Uint8List?>>{};
  final TransformationController _transformationController =
      TransformationController();
  final GlobalKey _drawingAreaKey = GlobalKey();
  int _viewportRestoreGeneration = 0;

  String? _pdfPath;
  Uint8List? _pdfBytes;
  late String _projectName;
  Timer? _saveDebounce;
  Timer? _saveRetryTimer;
  Future<void> _saveTail = Future<void>.value();
  bool _saveInProgress = false;
  bool _isLeaving = false;
  bool _allowPop = false;
  int _saveRetryAttempt = 0;
  String? _saveErrorMessage;
  bool _pinsDirty = false;
  bool _drawingsDirty = false;
  bool _metaDirty = false;
  bool _pdfDirty = false;
  bool _isRestoring = false;
  String? _errorMessage;

  int _currentPage = 1;
  int _pageCount = 0;
  int _nextPinNumber = 1;
  final List<ProjectPdfDocument> _documents = <ProjectPdfDocument>[];
  String? _currentDocumentId;

  bool _isPickingFile = false;
  int _pickOperationSequence = 0;
  bool _isExporting = false;

  FieldTool? _selectedTool;
  Color _pinColor = _fieldPaletteColors.first;
  double _pinOpacity = 1;
  double _pinSizeScale = 1;
  Color _penColor = const Color(0xFFE53935);
  double _penWidth = 3.0;
  double _penOpacity = 1;
  DrawingBrush _penBrush = DrawingBrush.fountain;
  DrawingKind _shapeKind = DrawingKind.line;
  double _eraserWidth = 28;
  double _textFontSize = 22;
  double _textBoxWidthRatio = 0.45;
  late String _boardBusinessName;
  String _boardFacilityName = '';

  final List<PinData> _pins = [];
  final List<_PinEdit> _undoPinEdits = <_PinEdit>[];
  final List<_PinEdit> _redoPinEdits = <_PinEdit>[];
  final Set<String> _pendingPhotoCleanupPinIds = <String>{};
  final Map<String, Map<int, List<DrawingStroke>>> _strokesByDocumentPage =
      <String, Map<int, List<DrawingStroke>>>{};
  final Map<String, List<DrawingStroke>> _photoAnnotationsById =
      <String, List<DrawingStroke>>{};
  final Map<String, Map<int, List<_DrawingEdit>>>
      _undoDrawingEditsByDocumentPage =
      <String, Map<int, List<_DrawingEdit>>>{};
  final Map<String, Map<int, List<_DrawingEdit>>>
      _redoDrawingEditsByDocumentPage =
      <String, Map<int, List<_DrawingEdit>>>{};
  DrawingStroke? _activeStroke;
  int? _activeStrokeIndex;
  DrawingStroke? _movingTextOriginal;
  Offset? _movingTextGrabOffset;
  DrawingStroke? _transformingAnnotationOriginal;
  _AnnotationTransformKind? _annotationTransformKind;
  int? _annotationTransformPointIndex;
  Offset? _annotationTransformFixedPoint;
  double? _annotationTransformStartAngle;
  int? _activeEraserPage;
  Offset? _lastEraserPosition;
  List<DrawingStroke>? _activeEraserBeforeStrokes;
  Map<String, String>? _activeEraserSourceIds;
  Set<String>? _activeEraserTouchedSourceIds;
  String? _activeEraserEditId;
  double? _activeEraserAspectRatio;
  Map<String, Rect>? _activeEraserBoundsCache;
  Map<String, List<DrawingPoint>>? _activeEraserSamplesCache;
  int _eraserFragmentSequence = 0;
  final Map<String, List<PhotoData>> _photosByPinId = {};
  final Set<String> _photoStorageVerifiedPinIds = <String>{};
  final Set<String> _photoStorageNeedsRescanPinIds = <String>{};
  final Map<String, int> _photoSavesInProgressByPinId = <String, int>{};
  int _photoLoadGeneration = 0;
  PinData? _movingPinOriginal;
  PinData? _directionPinOriginal;

  String? _selectedPinId;
  String? _selectedAnnotationId;
  Set<String> _selectedAnnotationIds = <String>{};
  Offset? _selectionDragStart;
  Rect? _selectionRect;
  bool _suppressPinPanel = false;
  String? _pendingDirectionPinId;
  String? _captureAfterDirectionPinId;
  TextEditingController? _noteController;

  String get _activeDocumentId => _currentDocumentId ?? 'main';

  ProjectPdfDocument? get _activeDocument {
    for (final ProjectPdfDocument document in _documents) {
      if (document.id == _activeDocumentId) return document;
    }
    return _documents.isEmpty ? null : _documents.first;
  }

  Map<int, List<DrawingStroke>> get _strokesByPage =>
      _strokesByDocumentPage.putIfAbsent(
        _activeDocumentId,
        () => <int, List<DrawingStroke>>{},
      );

  Map<int, List<_DrawingEdit>> get _undoDrawingEditsByPage =>
      _undoDrawingEditsByDocumentPage.putIfAbsent(
        _activeDocumentId,
        () => <int, List<_DrawingEdit>>{},
      );

  Map<int, List<_DrawingEdit>> get _redoDrawingEditsByPage =>
      _redoDrawingEditsByDocumentPage.putIfAbsent(
        _activeDocumentId,
        () => <int, List<_DrawingEdit>>{},
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _projectName = widget.projectName;
    _boardBusinessName = widget.projectName;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.isNewProject) {
        await _pickPdf();
      } else {
        await _loadSavedProject();
      }
    });
  }

  @override
  void dispose() {
    _pickOperationSequence++;
    WidgetsBinding.instance.removeObserver(this);
    _noteController?.dispose();
    _pdfDocument?.close();
    _saveDebounce?.cancel();
    _saveRetryTimer?.cancel();
    _transformationController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    _endStroke();
    _saveSelectedPinNote();
    _discardEmptyTextDrafts(_currentPage);
    _saveDebounce?.cancel();
    _enqueueSaveInBackground();
  }

  String _documentStem(String fileName) {
    final int extension = fileName.toLowerCase().lastIndexOf('.pdf');
    final String stem =
        extension > 0 ? fileName.substring(0, extension) : fileName;
    final String sanitized = stem
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return sanitized.isEmpty ? '図面' : sanitized;
  }

  String _documentFolderName(String fileName, int order) =>
      '${order.toString().padLeft(2, '0')}_${_documentStem(fileName)}';

  void _rememberCurrentDocumentPage() {
    final int index = _documents.indexWhere(
      (ProjectPdfDocument document) => document.id == _currentDocumentId,
    );
    if (index >= 0) {
      _documents[index] = _documents[index].copyWith(currentPage: _currentPage);
    }
  }

  Future<void> _pickPdf({bool append = false}) async {
    if (_isPickingFile) {
      return;
    }

    final int operationSequence = ++_pickOperationSequence;
    bool operationIsActive() =>
        mounted && operationSequence == _pickOperationSequence;

    setState(() {
      _isPickingFile = true;
      _errorMessage = null;
    });

    try {
      if (append) {
        _saveSelectedPinNote();
        _rememberCurrentDocumentPage();
        _saveDebounce?.cancel();
        await _enqueueSave();
        if (!operationIsActive()) return;
      }
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        allowMultiple: true,
        withData: kIsWeb,
      );

      if (!operationIsActive() || result == null) {
        return;
      }

      final List<_PickedPdfDocument> picked = <_PickedPdfDocument>[];
      for (int index = 0; index < result.files.length; index++) {
        final PlatformFile selectedFile = result.files[index];
        Uint8List? selectedBytes = selectedFile.bytes;
        if (selectedBytes == null && selectedFile.path != null) {
          selectedBytes = await XFile(selectedFile.path!).readAsBytes();
        }
        if (!operationIsActive()) return;
        if (selectedBytes == null || selectedBytes.isEmpty) continue;
        final Uint8List persistentBytes = Uint8List.fromList(selectedBytes);
        final pdfx.PdfDocument inspected = await pdfx.PdfDocument.openData(
          Uint8List.fromList(persistentBytes),
        );
        final int pagesCount = inspected.pagesCount;
        await inspected.close();
        final int order = _documents.length + picked.length + 1;
        final String folderName = _documentFolderName(selectedFile.name, order);
        final String documentId = folderName;
        picked.add(
          _PickedPdfDocument(
            document: ProjectPdfDocument(
              id: documentId,
              name: selectedFile.name,
              folderName: folderName,
              pageCount: pagesCount,
            ),
            bytes: persistentBytes,
          ),
        );
      }
      if (picked.isEmpty) {
        setState(() => _errorMessage = '選択したPDFのデータを読み込めませんでした。');
        return;
      }
      for (final _PickedPdfDocument item in picked) {
        await ProjectRepository.savePdfDocument(
          projectId: widget.projectId,
          projectName: _projectName,
          documentId: item.document.id,
          documentName: item.document.name,
          folderName: item.document.folderName,
          pageCount: item.document.pageCount,
          bytes: item.bytes,
        );
        if (!operationIsActive()) return;
      }
      final _PickedPdfDocument selected = picked.first;
      final pdfx.PdfDocument nextDocument = await pdfx.PdfDocument.openData(
        Uint8List.fromList(selected.bytes),
      );
      if (!operationIsActive()) {
        await nextDocument.close();
        return;
      }

      final pdfx.PdfDocument? previousDocument = _pdfDocument;

      _noteController?.dispose();
      _noteController = null;

      setState(() {
        if (!append) {
          _documents.clear();
        }
        _documents.addAll(
          picked.map((_PickedPdfDocument item) => item.document),
        );
        _currentDocumentId = selected.document.id;
        _pdfDocument = nextDocument;
        _pageImageBytes = null;
        _thumbnailFutures.clear();
        _pdfPath = '${selected.document.id}-${selected.bytes.length}';
        _pdfBytes = selected.bytes;

        _currentPage = 1;
        _pageCount = nextDocument.pagesCount;

        _selectedTool = widget.simplifiedMobile ? FieldTool.pin : null;

        if (!append) {
          _pins.clear();
          _undoPinEdits.clear();
          _redoPinEdits.clear();
          _pendingPhotoCleanupPinIds.clear();
          _photosByPinId.clear();
          _photoStorageVerifiedPinIds.clear();
          _photoStorageNeedsRescanPinIds.clear();
          _photoSavesInProgressByPinId.clear();
          _strokesByDocumentPage.clear();
          _photoAnnotationsById.clear();
          _undoDrawingEditsByDocumentPage.clear();
          _redoDrawingEditsByDocumentPage.clear();
        }
        _activeStroke = null;
        _activeStrokeIndex = null;
        _activeEraserPage = null;
        _lastEraserPosition = null;
        _activeEraserBeforeStrokes = null;
        _activeEraserSourceIds = null;
        _activeEraserTouchedSourceIds = null;
        _activeEraserEditId = null;
        _activeEraserAspectRatio = null;
        _activeEraserBoundsCache = null;
        _activeEraserSamplesCache = null;

        _refreshNextPinNumber();
        _selectedPinId = null;
        _selectedAnnotationId = null;
        _selectedAnnotationIds = <String>{};
        _selectionDragStart = null;
        _selectionRect = null;
        _suppressPinPanel = false;
        _pendingDirectionPinId = null;
        _captureAfterDirectionPinId = null;

        _errorMessage = null;
      });

      await previousDocument?.close();
      await _renderPage(_currentPage);
      if (!operationIsActive()) return;

      _pinsDirty = true;
      _drawingsDirty = true;
      _metaDirty = true;
      _pdfDirty = true;
      await _saveProjectNow();
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = 'PDFを開けませんでした。\n$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPickingFile = false;
        });
      }
    }
  }

  void _selectTool(FieldTool tool) {
    if (widget.simplifiedMobile && tool != FieldTool.pin) return;
    _endStroke();

    if (_selectedTool == tool) {
      switch (tool) {
        case FieldTool.pin:
          _showPinSettings();
        case FieldTool.pen:
          _showPenSettings();
        case FieldTool.eraser:
          _showEraserSettings();
        case FieldTool.shape:
          _showShapeSettings();
        case FieldTool.text:
          _showTextSettings();
        case FieldTool.select:
          _showSelectionSettings();
      }
      return;
    }

    bool removedDraft = false;
    setState(() {
      if (tool != FieldTool.text) {
        removedDraft = _discardEmptyTextDrafts(_currentPage);
      }
      _selectedTool = tool;
      if (tool != FieldTool.select) {
        _selectedAnnotationId = null;
        _selectedAnnotationIds = <String>{};
        _selectionRect = null;
      }
      if (tool != FieldTool.pin) {
        _pendingDirectionPinId = null;
        _captureAfterDirectionPinId = null;
      }
    });
    _scheduleSave(
      pins: false,
      drawings: removedDraft,
      meta: true,
    );
  }

  bool _discardEmptyTextDrafts(int pageNumber) {
    final List<DrawingStroke>? strokes = _strokesByPage[pageNumber];
    if (strokes == null) return false;
    final Set<String> draftIds = strokes
        .where(
          (DrawingStroke stroke) =>
              stroke.kind == DrawingKind.text && stroke.text.trim().isEmpty,
        )
        .map((DrawingStroke stroke) => stroke.id)
        .toSet();
    if (draftIds.isEmpty) return false;
    strokes.removeWhere((DrawingStroke stroke) => draftIds.contains(stroke.id));
    bool referencesDraft(_DrawingEdit edit) => <_IndexedDrawingStroke>[
          ...edit.removedStrokes,
          ...edit.addedStrokes,
        ].any(
          (_IndexedDrawingStroke item) => draftIds.contains(item.stroke.id),
        );
    _undoDrawingEditsByPage[pageNumber]?.removeWhere(referencesDraft);
    _redoDrawingEditsByPage[pageNumber]?.removeWhere(referencesDraft);
    if (draftIds.contains(_selectedAnnotationId)) {
      _selectedAnnotationId = null;
    }
    _selectedAnnotationIds.removeAll(draftIds);
    return true;
  }

  void _discardPinRedoHistory() {
    if (_redoPinEdits.isEmpty) return;
    for (final _PinEdit edit in _redoPinEdits) {
      if (edit.kind == _PinEditKind.add &&
          !_pins.any((PinData pin) => pin.id == edit.pinId)) {
        _pendingPhotoCleanupPinIds.add(edit.pinId);
        _photosByPinId.remove(edit.pinId);
        _photoStorageVerifiedPinIds.remove(edit.pinId);
        _photoStorageNeedsRescanPinIds.remove(edit.pinId);
        _photoSavesInProgressByPinId.remove(edit.pinId);
      }
    }
    _redoPinEdits.clear();
  }

  void _recordPinEdit(_PinEdit edit) {
    _discardPinRedoHistory();
    _undoPinEdits.add(edit);
    if (_undoPinEdits.length > 60) {
      final _PinEdit discarded = _undoPinEdits.removeAt(0);
      if (discarded.kind == _PinEditKind.delete &&
          !_pins.any((PinData pin) => pin.id == discarded.pinId)) {
        _queueDeletedPinCleanup(discarded.pinId);
      }
    }
  }

  void _queueDeletedPinCleanup(String pinId) {
    final Set<String> photoIds =
        (_photosByPinId.remove(pinId) ?? const <PhotoData>[])
            .map((PhotoData photo) => photo.id)
            .toSet();
    for (final String photoId in photoIds) {
      _photoAnnotationsById.remove(photoId);
    }
    _photoAnnotationsById.removeWhere(
      (String photoId, List<DrawingStroke> _) =>
          photoId.startsWith('$pinId-') || photoId.startsWith('$pinId::'),
    );
    _photoStorageVerifiedPinIds.remove(pinId);
    _photoStorageNeedsRescanPinIds.remove(pinId);
    _photoSavesInProgressByPinId.remove(pinId);
    _pendingPhotoCleanupPinIds.add(pinId);
  }

  bool _samePinPosition(PinData first, PinData second) {
    return first.xRatio == second.xRatio && first.yRatio == second.yRatio;
  }

  String? _pinEditDocumentId(_PinEdit edit) {
    final String? stored = edit.after?.documentId ?? edit.before?.documentId;
    if (stored != null) return stored;
    for (final PinData pin in _pins) {
      if (pin.id == edit.pinId) return pin.documentId;
    }
    return null;
  }

  int _lastPinEditIndexForDocument(List<_PinEdit> edits) {
    for (int index = edits.length - 1; index >= 0; index--) {
      if (_pinEditDocumentId(edits[index]) == _activeDocumentId) return index;
    }
    return -1;
  }

  void _addPin(Offset normalizedPosition) {
    if (_selectedTool != FieldTool.pin) {
      return;
    }

    final PinData pin = PinData(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      documentId: _activeDocumentId,
      number: _nextPinNumber,
      pageNumber: _currentPage,
      xRatio: normalizedPosition.dx,
      yRatio: normalizedPosition.dy,
      colorValue: _pinColor.toARGB32(),
      opacity: _pinOpacity,
      sizeScale: _pinSizeScale,
    );

    setState(() {
      _pins.add(pin);
      _recordPinEdit(
        _PinEdit(
          kind: _PinEditKind.add,
          pinId: pin.id,
          index: _pins.length - 1,
          after: pin,
        ),
      );

      _nextPinNumber++;
      _selectedPinId = pin.id;
      _suppressPinPanel = true;
      _pendingDirectionPinId = pin.id;
      _captureAfterDirectionPinId = pin.id;

      _setNoteController(pin.note);
    });
    _transformationController.value = Matrix4.identity();
    _scheduleSave();
  }

  void _changePinDirection(
    PinData pin,
    double directionDegrees,
  ) {
    final int index = _pins.indexWhere(
      (item) => item.id == pin.id,
    );

    if (index < 0) {
      return;
    }

    final bool shouldOpenCamera = _captureAfterDirectionPinId == pin.id;
    final PinData currentPin = _pins[index];
    final PinData updatedPin = currentPin.copyWith(
      directionDegrees: directionDegrees,
      showsDirection: true,
    );
    final bool directionChanged =
        currentPin.directionDegrees != updatedPin.directionDegrees ||
            currentPin.showsDirection != updatedPin.showsDirection;
    final PinData? gestureOriginal = _directionPinOriginal;

    setState(() {
      _pins[index] = updatedPin;
      _pendingDirectionPinId = null;
      _captureAfterDirectionPinId = null;
      _selectedPinId = updatedPin.id;
      _pinColor = Color(updatedPin.colorValue);
      _pinOpacity = updatedPin.opacity;
      _pinSizeScale = updatedPin.sizeScale;
      _setNoteController(updatedPin.note);
      if (directionChanged &&
          (gestureOriginal == null || gestureOriginal.id != updatedPin.id)) {
        _recordPinEdit(
          _PinEdit(
            kind: _PinEditKind.direction,
            pinId: updatedPin.id,
            index: index,
            before: currentPin,
            after: updatedPin,
          ),
        );
      }
    });

    _scheduleSave();

    if (shouldOpenCamera) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _captureThenOpenPinDetails(updatedPin);
        }
      });
    }
  }

  void _clearPinDirection(PinData pin) {
    final int index = _pins.indexWhere((PinData item) => item.id == pin.id);
    if (index < 0) return;
    final bool shouldOpenCamera = _captureAfterDirectionPinId == pin.id;
    final PinData currentPin = _pins[index];
    final PinData updatedPin = currentPin.copyWith(showsDirection: false);
    setState(() {
      _pins[index] = updatedPin;
      _pendingDirectionPinId = null;
      _captureAfterDirectionPinId = null;
      _selectedPinId = updatedPin.id;
      _pinColor = Color(updatedPin.colorValue);
      _pinOpacity = updatedPin.opacity;
      _pinSizeScale = updatedPin.sizeScale;
      _setNoteController(updatedPin.note);
      _recordPinEdit(
        _PinEdit(
          kind: _PinEditKind.direction,
          pinId: updatedPin.id,
          index: index,
          before: currentPin,
          after: updatedPin,
        ),
      );
    });
    _scheduleSave();
    if (shouldOpenCamera) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _captureThenOpenPinDetails(updatedPin);
      });
    }
  }

  Future<void> _captureThenOpenPinDetails(PinData pin) async {
    final int beforeCount = pin.photoCount;
    await _capturePhotosForPin(pin);
    if (!mounted) return;
    final int index = _pins.indexWhere((PinData item) => item.id == pin.id);
    if (index < 0) return;
    final PinData latest = _pins[index];
    if (latest.photoCount > beforeCount) {
      final PdfVisibleRange? visibleRange = _captureCurrentPdfVisibleRange();
      setState(() {
        _suppressPinPanel = false;
        _selectedPinId = latest.id;
        _pinColor = Color(latest.colorValue);
        _pinOpacity = latest.opacity;
        _pinSizeScale = latest.sizeScale;
        _setNoteController(latest.note);
      });
      _restoreVisibleRangeAfterPanelResize(visibleRange);
      unawaited(_ensurePhotosLoadedForPin(latest));
    } else {
      setState(() {
        _suppressPinPanel = false;
        _selectedPinId = null;
      });
      _noteController?.dispose();
      _noteController = null;
    }
  }

  void _startPinDirectionChange(PinData pin) {
    if (_selectedTool != FieldTool.pin) return;
    final int index = _pins.indexWhere((PinData item) => item.id == pin.id);
    if (index < 0) return;
    _directionPinOriginal = _pins[index];
  }

  void _finishPinDirectionChange(PinData pin) {
    final PinData? original = _directionPinOriginal;
    _directionPinOriginal = null;
    if (original == null || original.id != pin.id) return;
    final int index = _pins.indexWhere((PinData item) => item.id == pin.id);
    if (index < 0) return;
    final PinData current = _pins[index];
    if (original.directionDegrees == current.directionDegrees &&
        original.showsDirection == current.showsDirection) {
      return;
    }
    setState(() {
      _recordPinEdit(
        _PinEdit(
          kind: _PinEditKind.direction,
          pinId: current.id,
          index: index,
          before: original,
          after: current,
        ),
      );
    });
    _scheduleSave(pins: true, drawings: false, meta: true);
  }

  void _cancelPinDirectionChange(PinData pin) {
    final PinData? original = _directionPinOriginal;
    _directionPinOriginal = null;
    if (original == null || original.id != pin.id) return;
    final int index = _pins.indexWhere((PinData item) => item.id == pin.id);
    if (index < 0) return;
    setState(() => _pins[index] = original);
  }

  void _toggleSelectedPinDirectionEditing() {
    final String? selectedId = _selectedPinId;
    if (selectedId == null) return;

    setState(() {
      if (_pendingDirectionPinId == selectedId) {
        _pendingDirectionPinId = null;
        _captureAfterDirectionPinId = null;
      } else {
        _selectedTool = FieldTool.pin;
        _pendingDirectionPinId = selectedId;
        _captureAfterDirectionPinId = null;
      }
    });
    _scheduleSave(pins: false, drawings: false, meta: true);
  }

  void _startPinMove(PinData pin) {
    final int index = _pins.indexWhere((PinData item) => item.id == pin.id);
    if (index < 0) return;
    final PinData current = _pins[index];

    setState(() {
      _movingPinOriginal = current;
      _selectedPinId = current.id;
      _suppressPinPanel = false;
      _pinColor = Color(current.colorValue);
      _pinOpacity = current.opacity;
      _pinSizeScale = current.sizeScale;
      _setNoteController(current.note);
    });
    unawaited(
      _ensurePhotosLoadedForPin(current).then<void>((bool _) {}),
    );
  }

  void _updatePinPosition(PinData pin, Offset normalizedPosition) {
    final int index = _pins.indexWhere((PinData item) => item.id == pin.id);
    if (index < 0) return;
    setState(() {
      _pins[index] = _pins[index].copyWith(
        xRatio: normalizedPosition.dx.clamp(0.0, 1.0),
        yRatio: normalizedPosition.dy.clamp(0.0, 1.0),
      );
    });
  }

  void _finishPinMove(PinData pin, Offset normalizedPosition) {
    _updatePinPosition(pin, normalizedPosition);
    final PinData? original = _movingPinOriginal;
    _movingPinOriginal = null;
    final int index = _pins.indexWhere((PinData item) => item.id == pin.id);
    bool changed = false;
    if (original != null && index >= 0) {
      final PinData current = _pins[index];
      if (!_samePinPosition(original, current)) {
        changed = true;
        setState(() {
          _recordPinEdit(
            _PinEdit(
              kind: _PinEditKind.move,
              pinId: current.id,
              index: index,
              before: original,
              after: current,
            ),
          );
        });
      }
    }
    if (changed) {
      _scheduleSave(pins: true, drawings: false, meta: true);
    }
  }

  void _cancelPinMove(PinData pin) {
    final PinData? original = _movingPinOriginal;
    _movingPinOriginal = null;
    if (original == null || original.id != pin.id) return;
    final int index =
        _pins.indexWhere((PinData item) => item.id == original.id);
    if (index < 0) return;
    setState(() => _pins[index] = original);
  }

  Future<void> _selectPin(PinData pin) async {
    final int loadGeneration = ++_photoLoadGeneration;
    final bool panelWasClosed = _selectedPin == null || _suppressPinPanel;
    final PdfVisibleRange? visibleRange =
        panelWasClosed ? _captureCurrentPdfVisibleRange() : null;
    setState(() {
      if (_pendingDirectionPinId != pin.id) {
        _pendingDirectionPinId = null;
        _captureAfterDirectionPinId = null;
      }
      _selectedPinId = pin.id;
      _suppressPinPanel = false;
      _pinColor = Color(pin.colorValue);
      _pinOpacity = pin.opacity;
      _pinSizeScale = pin.sizeScale;
      _setNoteController(pin.note);
    });
    if (panelWasClosed) {
      _restoreVisibleRangeAfterPanelResize(visibleRange);
    }

    try {
      final List<Map<String, dynamic>> rows =
          await ProjectRepository.loadPhotoPreviewsForPin(
        projectId: widget.projectId,
        pinId: pin.id,
        thumbnailBuilder: _makePhotoThumbnail,
      );
      if (!mounted ||
          loadGeneration != _photoLoadGeneration ||
          _selectedPinId != pin.id) {
        return;
      }
      final List<PhotoData> photos = rows
          .map((row) => PhotoData(
                id: row['photoId'].toString(),
                fileName: row['fileName']?.toString() ?? '001.jpg',
                bytes: row['bytes'] as Uint8List,
              ))
          .toList(growable: false);
      await _replaceWithEditedPreviews(pin, photos);
      bool countChanged = false;
      setState(() {
        // Keep only lightweight previews for the currently viewed pin in RAM.
        _photosByPinId.clear();
        _photosByPinId[pin.id] = photos;
        _photoStorageVerifiedPinIds.add(pin.id);
        _photoStorageNeedsRescanPinIds.remove(pin.id);
        final int pinIndex =
            _pins.indexWhere((PinData item) => item.id == pin.id);
        if (pinIndex >= 0 && _pins[pinIndex].photoCount != photos.length) {
          final bool saveInProgress =
              (_photoSavesInProgressByPinId[pin.id] ?? 0) > 0;
          final int reconciledCount = saveInProgress
              ? math.max(_pins[pinIndex].photoCount, photos.length)
              : photos.length;
          if (_pins[pinIndex].photoCount != reconciledCount) {
            _pins[pinIndex] =
                _pins[pinIndex].copyWith(photoCount: reconciledCount);
            countChanged = true;
          }
        }
      });
      if (countChanged) {
        _scheduleSave(pins: true, drawings: false, meta: true);
      }
    } catch (error) {
      if (mounted &&
          loadGeneration == _photoLoadGeneration &&
          _selectedPinId == pin.id) {
        setState(() => _errorMessage = '写真を読み込めませんでした。\n$error');
      }
    }
  }

  void _closePinPanel() {
    _endStroke();
    _saveSelectedPinNote();
    final PdfVisibleRange? visibleRange = _captureCurrentPdfVisibleRange();

    setState(() {
      _selectedPinId = null;
      _suppressPinPanel = false;
      _pendingDirectionPinId = null;
      _captureAfterDirectionPinId = null;
    });

    _noteController?.dispose();
    _noteController = null;
    _restoreVisibleRangeAfterPanelResize(visibleRange);
  }

  PdfVisibleRange? _captureCurrentPdfVisibleRange() {
    final BuildContext? drawingContext = _drawingAreaKey.currentContext;
    final RenderObject? renderObject = drawingContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final Size viewportSize = renderObject.size;
    final Rect contentRect = fittedPdfContentRect(
      viewportSize: viewportSize,
      pageAspectRatio: _pageAspectRatio,
    );
    return capturePdfVisibleRange(
      matrix: _transformationController.value,
      viewportSize: viewportSize,
      contentRect: contentRect,
    );
  }

  void _restoreVisibleRangeAfterPanelResize(PdfVisibleRange? visibleRange) {
    if (visibleRange == null) return;
    final int generation = ++_viewportRestoreGeneration;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 240), () {
      if (!mounted || generation != _viewportRestoreGeneration) return;
      final BuildContext? drawingContext = _drawingAreaKey.currentContext;
      final RenderObject? renderObject = drawingContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return;
      final Size viewportSize = renderObject.size;
      final Rect contentRect = fittedPdfContentRect(
        viewportSize: viewportSize,
        pageAspectRatio: _pageAspectRatio,
      );
      _transformationController.value = restorePdfVisibleRange(
        visibleRange: visibleRange,
        viewportSize: viewportSize,
        contentRect: contentRect,
      );
    }));
  }

  void _setNoteController(String note) {
    _noteController?.dispose();
    _noteController = TextEditingController(text: note);
  }

  void _saveSelectedPinNote() {
    final String? selectedId = _selectedPinId;
    final TextEditingController? controller = _noteController;

    if (selectedId == null || controller == null) {
      return;
    }

    final int index = _pins.indexWhere(
      (pin) => pin.id == selectedId,
    );

    if (index < 0) {
      return;
    }

    if (_pins[index].note == controller.text) {
      return;
    }
    _discardPinRedoHistory();
    _pins[index] = _pins[index].copyWith(
      note: controller.text,
    );
    _scheduleSave();
  }

  void _updateSelectedPinName(String value) {
    final String? selectedId = _selectedPinId;
    if (selectedId == null) return;
    final int index = _pins.indexWhere((PinData pin) => pin.id == selectedId);
    if (index < 0 || _pins[index].name == value) return;
    _discardPinRedoHistory();
    setState(() => _pins[index] = _pins[index].copyWith(name: value));
    _scheduleSave(pins: true, drawings: false, meta: true);
  }

  Future<void> _deleteSelectedPin() async {
    final String? selectedId = _selectedPinId;

    if (selectedId == null) {
      return;
    }

    final int index = _pins.indexWhere(
      (pin) => pin.id == selectedId,
    );

    if (index < 0) {
      return;
    }
    final PinData selectedPin = _pins[index];
    final int photoCount = math.max(
      selectedPin.photoCount,
      (_photosByPinId[selectedId] ?? const <PhotoData>[]).length,
    );
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('ピン${selectedPin.number}を削除しますか？'),
        content: Text(
          photoCount > 0
              ? 'このピンには写真が$photoCount枚あります。\n'
                  'ピンを削除すると、写真と写真への書き込みも削除されます。'
              : 'このピンを削除します。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Finish any older snapshot before changing pin numbers. The deletion
    // itself is then committed through the durable cleanup transaction below.
    _saveSelectedPinNote();
    _saveDebounce?.cancel();
    try {
      await _enqueueSave();
    } catch (_) {
      // _saveProjectNow keeps the dirty flags and exposes the retry state. Do
      // not remove the pin until the older state has been committed.
      return;
    }
    if (!mounted) return;
    final int latestIndex = _pins.indexWhere((pin) => pin.id == selectedId);
    if (latestIndex < 0) return;

    setState(() {
      final PinData removedPin = _pins.removeAt(latestIndex);
      _recordPinEdit(
        _PinEdit(
          kind: _PinEditKind.delete,
          pinId: removedPin.id,
          index: latestIndex,
          before: removedPin,
        ),
      );
      _refreshNextPinNumber();

      _selectedPinId = null;
      if (_pendingDirectionPinId == selectedId) {
        _pendingDirectionPinId = null;
      }
      if (_captureAfterDirectionPinId == selectedId) {
        _captureAfterDirectionPinId = null;
      }
    });

    _noteController?.dispose();
    _noteController = null;
    _scheduleSave(pins: true, drawings: false, meta: true);
    try {
      await _enqueueSave();
    } catch (_) {
      // Dirty flags and the retry timer keep the reversible deletion pending.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('ピン${selectedPin.number}を削除しました'),
          action: SnackBarAction(
            label: '取り消す',
            onPressed: () => _undoPinDeletion(selectedId),
          ),
        ),
      );
  }

  void _undoPinDeletion(String pinId) {
    final int index = _lastPinEditIndexForDocument(_undoPinEdits);
    if (index < 0) return;
    final _PinEdit edit = _undoPinEdits[index];
    if (edit.kind != _PinEditKind.delete || edit.pinId != pinId) return;
    _undo();
  }

  void _startStroke(Offset normalizedPosition, double pressure) {
    if (_selectedTool != FieldTool.pen &&
        _selectedTool != FieldTool.eraser &&
        _selectedTool != FieldTool.shape) {
      return;
    }
    if (_selectedTool == FieldTool.eraser) {
      _activeEraserPage = _currentPage;
      _lastEraserPosition = null;
      final List<DrawingStroke> strokes =
          _strokesByPage[_currentPage] ?? const <DrawingStroke>[];
      _activeEraserBeforeStrokes = List<DrawingStroke>.of(strokes);
      _activeEraserSourceIds = <String, String>{
        for (final DrawingStroke stroke in strokes) stroke.id: stroke.id,
      };
      _activeEraserTouchedSourceIds = <String>{};
      _activeEraserEditId = DateTime.now().microsecondsSinceEpoch.toString();
      _activeEraserAspectRatio = _pageAspectRatio;
      _activeEraserBoundsCache = <String, Rect>{};
      _activeEraserSamplesCache = <String, List<DrawingPoint>>{};
      _eraserFragmentSequence = 0;
      _eraseAt(normalizedPosition);
      return;
    }

    final DrawingKind kind =
        _selectedTool == FieldTool.shape ? _shapeKind : DrawingKind.freehand;
    final DrawingStroke stroke = DrawingStroke(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      documentId: _activeDocumentId,
      pageNumber: _currentPage,
      width: _penWidth,
      color: _penColor,
      opacity: _penOpacity,
      kind: kind,
      brush: _penBrush,
      points: <DrawingPoint>[
        DrawingPoint(
          position: normalizedPosition,
          pressure: pressure,
        ),
        if (kind == DrawingKind.line || kind == DrawingKind.rectangle)
          DrawingPoint(
            position: normalizedPosition,
            pressure: pressure,
          ),
      ],
    );

    setState(() {
      _activeStroke = stroke;
      final List<DrawingStroke> pageStrokes =
          _strokesByPage.putIfAbsent(_currentPage, () => <DrawingStroke>[]);
      _activeStrokeIndex = pageStrokes.length;
      pageStrokes.add(stroke);
      _redoDrawingEditsByPage[_currentPage]?.clear();
    });
  }

  void _updateStroke(Offset normalizedPosition, double pressure) {
    if (_selectedTool == FieldTool.eraser) {
      if (_activeEraserPage != null) {
        _eraseAt(normalizedPosition);
      }
      return;
    }
    final DrawingStroke? active = _activeStroke;
    if (active == null || active.pageNumber != _currentPage) {
      return;
    }

    final List<DrawingStroke>? pageStrokes = _strokesByPage[_currentPage];
    if (pageStrokes == null || pageStrokes.isEmpty) {
      return;
    }

    if (active.kind == DrawingKind.line ||
        active.kind == DrawingKind.rectangle) {
      active.points[active.points.length - 1] = DrawingPoint(
        position: normalizedPosition,
        pressure: pressure,
      );
      setState(() {});
      return;
    }

    final DrawingPoint lastPoint = active.points.last;
    if ((lastPoint.position - normalizedPosition).distance < 0.0008) {
      return;
    }

    // Append in place. Copying every previous point on every pointer event made
    // long or multi-stroke handwriting progressively slower (O(n²)).
    active.points.add(DrawingPoint(
      position: normalizedPosition,
      pressure: pressure,
    ));
    setState(() {});
  }

  void _endStroke() {
    final int? eraserPage = _activeEraserPage;
    if (eraserPage != null) {
      final List<DrawingStroke> before =
          _activeEraserBeforeStrokes ?? const <DrawingStroke>[];
      final Map<String, String> sourceIds =
          _activeEraserSourceIds ?? const <String, String>{};
      final Set<String> touchedSourceIds =
          _activeEraserTouchedSourceIds ?? const <String>{};
      final List<DrawingStroke> after =
          _strokesByPage[eraserPage] ?? const <DrawingStroke>[];
      final List<_IndexedDrawingStroke> removedStrokes =
          <_IndexedDrawingStroke>[
        for (int index = 0; index < before.length; index++)
          if (touchedSourceIds.contains(before[index].id))
            _IndexedDrawingStroke(stroke: before[index], index: index),
      ];
      final List<_IndexedDrawingStroke> addedStrokes = <_IndexedDrawingStroke>[
        for (int index = 0; index < after.length; index++)
          if (touchedSourceIds.contains(sourceIds[after[index].id]))
            _IndexedDrawingStroke(stroke: after[index], index: index),
      ];
      final bool changed = removedStrokes.isNotEmpty;
      if (changed) {
        setState(() {
          _undoDrawingEditsByPage
              .putIfAbsent(eraserPage, () => <_DrawingEdit>[])
              .add(
                _DrawingEdit(
                  removedStrokes:
                      List<_IndexedDrawingStroke>.unmodifiable(removedStrokes),
                  addedStrokes:
                      List<_IndexedDrawingStroke>.unmodifiable(addedStrokes),
                ),
              );
        });
      }
      _activeEraserPage = null;
      _lastEraserPosition = null;
      _activeEraserBeforeStrokes = null;
      _activeEraserSourceIds = null;
      _activeEraserTouchedSourceIds = null;
      _activeEraserEditId = null;
      _activeEraserAspectRatio = null;
      _activeEraserBoundsCache = null;
      _activeEraserSamplesCache = null;
      if (changed) {
        _scheduleSave(pins: false, drawings: true, meta: true);
      }
      return;
    }

    final DrawingStroke? completedStroke = _activeStroke;
    if (completedStroke == null) return;
    final int strokePage = completedStroke.pageNumber;
    final int strokeIndex = _activeStrokeIndex ??
        (_strokesByPage[strokePage]?.indexOf(completedStroke) ?? 0);
    if (completedStroke.kind == DrawingKind.polyline &&
        completedStroke.points.length < 2) {
      setState(() {
        _strokesByPage[strokePage]?.removeWhere(
          (DrawingStroke stroke) => stroke.id == completedStroke.id,
        );
        _activeStroke = null;
        _activeStrokeIndex = null;
      });
      return;
    }
    setState(() {
      _activeStroke = null;
      _activeStrokeIndex = null;
      _undoDrawingEditsByPage
          .putIfAbsent(strokePage, () => <_DrawingEdit>[])
          .add(
            _DrawingEdit(
              removedStrokes: const <_IndexedDrawingStroke>[],
              addedStrokes: <_IndexedDrawingStroke>[
                _IndexedDrawingStroke(
                  stroke: completedStroke,
                  index: strokeIndex,
                ),
              ],
            ),
          );
    });
    _scheduleSave(pins: false, drawings: true, meta: true);
  }

  List<DrawingStroke> get _currentPageStrokes {
    return List<DrawingStroke>.unmodifiable(
      _strokesByPage[_currentPage] ?? const <DrawingStroke>[],
    );
  }

  bool get _drawingToolSelected =>
      _selectedTool != null && _selectedTool != FieldTool.pin;

  void _applyDrawingEdit(
    int pageNumber,
    _DrawingEdit edit, {
    required bool undo,
  }) {
    final List<_IndexedDrawingStroke> strokesToRemove =
        undo ? edit.addedStrokes : edit.removedStrokes;
    final List<_IndexedDrawingStroke> strokesToRestore =
        undo ? edit.removedStrokes : edit.addedStrokes;
    final Set<String> strokeIds =
        strokesToRemove.map((indexedStroke) => indexedStroke.stroke.id).toSet();
    _strokesByPage[pageNumber]?.removeWhere(
      (DrawingStroke stroke) => strokeIds.contains(stroke.id),
    );

    final List<DrawingStroke> pageStrokes =
        _strokesByPage.putIfAbsent(pageNumber, () => <DrawingStroke>[]);
    final List<_IndexedDrawingStroke> ordered =
        List<_IndexedDrawingStroke>.of(strokesToRestore)
          ..sort((a, b) => a.index.compareTo(b.index));
    for (final _IndexedDrawingStroke indexedStroke in ordered) {
      if (pageStrokes.any(
        (DrawingStroke stroke) => stroke.id == indexedStroke.stroke.id,
      )) {
        continue;
      }
      final int insertionIndex = math.min(
        math.max(indexedStroke.index, 0),
        pageStrokes.length,
      );
      pageStrokes.insert(insertionIndex, indexedStroke.stroke);
    }
  }

  bool get _canUndoCurrentTool {
    if (_selectedTool == null) return false;
    if (_drawingToolSelected) {
      return (_undoDrawingEditsByPage[_currentPage]?.isNotEmpty ?? false) ||
          (_strokesByPage[_currentPage]?.isNotEmpty ?? false);
    }
    return _lastPinEditIndexForDocument(_undoPinEdits) >= 0;
  }

  bool get _canRedoCurrentTool {
    if (_selectedTool == null) return false;
    if (_drawingToolSelected) {
      return (_redoDrawingEditsByPage[_currentPage]?.isNotEmpty ?? false);
    }
    return _lastPinEditIndexForDocument(_redoPinEdits) >= 0;
  }

  PinData _applyPinEditValue(
    PinData current,
    _PinEdit edit, {
    required bool redo,
  }) {
    final PinData? value = redo ? edit.after : edit.before;
    if (value == null) return current;
    return switch (edit.kind) {
      _PinEditKind.move => current.copyWith(
          xRatio: value.xRatio,
          yRatio: value.yRatio,
        ),
      _PinEditKind.direction => current.copyWith(
          directionDegrees: value.directionDegrees,
          showsDirection: value.showsDirection,
        ),
      _PinEditKind.add || _PinEditKind.delete => value,
    };
  }

  void _undo() {
    if (_drawingToolSelected) {
      _endStroke();
      final List<DrawingStroke>? pageStrokes = _strokesByPage[_currentPage];
      final List<_DrawingEdit> undo =
          _undoDrawingEditsByPage[_currentPage] ?? <_DrawingEdit>[];
      _DrawingEdit? edit;

      setState(() {
        if (undo.isNotEmpty) {
          edit = undo.removeLast();
          _applyDrawingEdit(_currentPage, edit!, undo: true);
        } else if (pageStrokes != null && pageStrokes.isNotEmpty) {
          final int index = pageStrokes.length - 1;
          final DrawingStroke removed = pageStrokes.removeLast();
          edit = _DrawingEdit(
            removedStrokes: const <_IndexedDrawingStroke>[],
            addedStrokes: <_IndexedDrawingStroke>[
              _IndexedDrawingStroke(stroke: removed, index: index),
            ],
          );
        }
        if (edit != null) {
          _redoDrawingEditsByPage
              .putIfAbsent(_currentPage, () => <_DrawingEdit>[])
              .add(edit!);
        }
        _activeStroke = null;
        _activeStrokeIndex = null;
      });
      if (edit != null) {
        _scheduleSave();
      }
      return;
    }

    final int undoIndex = _lastPinEditIndexForDocument(_undoPinEdits);
    if (undoIndex < 0) {
      return;
    }

    _PinEdit edit = _undoPinEdits.removeAt(undoIndex);

    setState(() {
      if (edit.kind == _PinEditKind.add) {
        final int index =
            _pins.indexWhere((PinData pin) => pin.id == edit.pinId);
        if (index >= 0) {
          final PinData removedPin = _pins.removeAt(index);
          edit = edit.copyWith(after: removedPin);
          if (_pendingDirectionPinId == removedPin.id) {
            _pendingDirectionPinId = null;
          }
          if (_captureAfterDirectionPinId == removedPin.id) {
            _captureAfterDirectionPinId = null;
          }
          if (_selectedPinId == removedPin.id) {
            _selectedPinId = null;
            _noteController?.dispose();
            _noteController = null;
          }
          _refreshNextPinNumber();
        }
      } else if (edit.kind == _PinEditKind.delete && edit.before != null) {
        final int insertionIndex = edit.index.clamp(0, _pins.length);
        _pins.insert(insertionIndex, edit.before!);
        _pendingPhotoCleanupPinIds.remove(edit.pinId);
        _refreshNextPinNumber();
      } else {
        final int index =
            _pins.indexWhere((PinData pin) => pin.id == edit.pinId);
        if (index >= 0) {
          _pins[index] = _applyPinEditValue(
            _pins[index],
            edit,
            redo: false,
          );
        }
      }
      _redoPinEdits.add(edit);
    });
    _scheduleSave(pins: true, drawings: false, meta: true);
  }

  void _redo() {
    if (_drawingToolSelected) {
      _endStroke();
      final List<_DrawingEdit>? redo = _redoDrawingEditsByPage[_currentPage];
      if (redo == null || redo.isEmpty) {
        return;
      }
      setState(() {
        final _DrawingEdit edit = redo.removeLast();
        _applyDrawingEdit(_currentPage, edit, undo: false);
        _undoDrawingEditsByPage
            .putIfAbsent(_currentPage, () => <_DrawingEdit>[])
            .add(edit);
      });
      _scheduleSave();
      return;
    }

    final int redoIndex = _lastPinEditIndexForDocument(_redoPinEdits);
    if (redoIndex < 0) {
      return;
    }

    final _PinEdit edit = _redoPinEdits.removeAt(redoIndex);

    setState(() {
      if (edit.kind == _PinEditKind.add && edit.after != null) {
        final int insertionIndex = edit.index.clamp(0, _pins.length);
        _pins.insert(insertionIndex, edit.after!);
        _refreshNextPinNumber();
      } else if (edit.kind == _PinEditKind.delete) {
        _pins.removeWhere((PinData pin) => pin.id == edit.pinId);
        _refreshNextPinNumber();
      } else {
        final int index =
            _pins.indexWhere((PinData pin) => pin.id == edit.pinId);
        if (index >= 0) {
          _pins[index] = _applyPinEditValue(
            _pins[index],
            edit,
            redo: true,
          );
        }
      }
      _undoPinEdits.add(edit);
    });
    _scheduleSave(pins: true, drawings: false, meta: true);
  }

  void _refreshNextPinNumber() {
    _nextPinNumber = nextPinNumberForDocument(_pins, _activeDocumentId);
  }

  List<PhotoData> _photosForPin(String pinId) {
    return List<PhotoData>.unmodifiable(
      _photosByPinId[pinId] ?? const <PhotoData>[],
    );
  }

  Future<void> _addPhotosToSelectedPin() async {
    final PinData? pin = _selectedPin;
    if (pin == null) {
      return;
    }

    await _capturePhotosForPin(pin);
  }

  Future<void> _capturePhotosForPin(PinData pin) async {
    final bool photosReady = await _ensurePhotosLoadedForPin(pin);
    if (!photosReady || !mounted || _selectedPinId != pin.id) return;

    final int currentIndex = _pins.indexWhere((item) => item.id == pin.id);
    if (currentIndex < 0) return;
    final PinData currentPin = _pins[currentIndex];

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => CameraCaptureScreen(
          simplifiedMobile: widget.simplifiedMobile,
          pinNumber: currentPin.number,
          initialPhotoCount: currentPin.photoCount,
          initialPhotos: _photosForPin(currentPin.id),
          initialBoardConfig: _photoBoardConfigFor(currentPin),
          onBoardConfigChanged: (PhotoBoardConfig config) {
            _updatePhotoBoardConfig(currentPin.id, config);
          },
          onCaptured: (bytes) => _saveCapturedPhoto(currentPin, bytes),
          onPhotoTap: (String photoId) {
            final List<PhotoData> photos = _photosForPin(currentPin.id);
            final int index = photos.indexWhere(
              (PhotoData photo) => photo.id == photoId,
            );
            if (index >= 0) {
              if (widget.simplifiedMobile) {
                _openPhotoReadOnly(currentPin, photos[index]);
              } else {
                _openPhotoEditor(currentPin, photos[index]);
              }
            }
          },
        ),
      ),
    );
    if (!mounted) return;
    final int latestPinIndex =
        _pins.indexWhere((PinData item) => item.id == pin.id);
    if (latestPinIndex >= 0) {
      await _ensurePhotosLoadedForPin(_pins[latestPinIndex]);
    }
  }

  PhotoBoardConfig _photoBoardConfigFor(PinData pin) {
    return PhotoBoardConfig(
      enabled: pin.boardEnabled,
      businessName: _boardBusinessName,
      facilityName: _boardFacilityName,
      shootingLocation: pin.boardShootingLocation,
      template: PhotoBoardTemplate.fromId(pin.boardTemplateId),
      templateSteps: <PhotoBoardTemplate, int>{
        PhotoBoardTemplate.core: pin.boardCoreStep,
        PhotoBoardTemplate.chipping: pin.boardChippingStep,
        PhotoBoardTemplate.asbestos: pin.boardAsbestosStep,
      },
      position: PhotoBoardPosition.fromId(pin.boardPositionId),
    );
  }

  void _updatePhotoBoardConfig(String pinId, PhotoBoardConfig config) {
    final int pinIndex = _pins.indexWhere((PinData pin) => pin.id == pinId);
    if (pinIndex < 0 || !mounted) return;

    setState(() {
      _discardPinRedoHistory();
      _boardBusinessName = config.businessName;
      _boardFacilityName = config.facilityName;
      _pins[pinIndex] = _pins[pinIndex].copyWith(
        boardEnabled: config.enabled,
        boardTemplateId: config.template.id,
        boardShootingLocation: config.shootingLocation,
        boardCoreStep:
            config.templateSteps[PhotoBoardTemplate.core]?.clamp(0, 5) ?? 0,
        boardChippingStep:
            config.templateSteps[PhotoBoardTemplate.chipping]?.clamp(0, 5) ?? 0,
        boardAsbestosStep:
            config.templateSteps[PhotoBoardTemplate.asbestos]?.clamp(0, 5) ?? 0,
        boardPositionId: config.position.id,
      );
    });
    _scheduleSave(pins: true, drawings: false, meta: true);
  }

  Future<bool> _ensurePhotosLoadedForPin(PinData pin) async {
    final int loadGeneration = ++_photoLoadGeneration;
    final List<PhotoData>? cached = _photosByPinId[pin.id];
    if (!_photoStorageNeedsRescanPinIds.contains(pin.id) &&
        _photoStorageVerifiedPinIds.contains(pin.id) &&
        cached != null &&
        cached.length >= pin.photoCount) {
      return mounted &&
          loadGeneration == _photoLoadGeneration &&
          _selectedPinId == pin.id;
    }

    try {
      final List<Map<String, dynamic>> rows =
          await ProjectRepository.loadPhotoPreviewsForPin(
        projectId: widget.projectId,
        pinId: pin.id,
        thumbnailBuilder: _makePhotoThumbnail,
      );
      if (!mounted ||
          loadGeneration != _photoLoadGeneration ||
          _selectedPinId != pin.id) {
        return false;
      }
      final List<PhotoData> photos = rows
          .map(
            (row) => PhotoData(
              id: row['photoId'].toString(),
              fileName: row['fileName']?.toString() ?? '001.jpg',
              bytes: row['bytes'] as Uint8List,
            ),
          )
          .toList(growable: true);
      await _replaceWithEditedPreviews(pin, photos);
      bool countChanged = false;
      setState(() {
        _photosByPinId.clear();
        _photosByPinId[pin.id] = photos;
        _photoStorageVerifiedPinIds.add(pin.id);
        _photoStorageNeedsRescanPinIds.remove(pin.id);
        final int pinIndex =
            _pins.indexWhere((PinData item) => item.id == pin.id);
        if (pinIndex >= 0 && _pins[pinIndex].photoCount != photos.length) {
          final bool saveInProgress =
              (_photoSavesInProgressByPinId[pin.id] ?? 0) > 0;
          final int reconciledCount = saveInProgress
              ? math.max(_pins[pinIndex].photoCount, photos.length)
              : photos.length;
          if (_pins[pinIndex].photoCount != reconciledCount) {
            _pins[pinIndex] =
                _pins[pinIndex].copyWith(photoCount: reconciledCount);
            countChanged = true;
          }
        }
      });
      if (countChanged) {
        _scheduleSave(pins: true, drawings: false, meta: true);
      }
      return true;
    } catch (error) {
      if (mounted &&
          loadGeneration == _photoLoadGeneration &&
          _selectedPinId == pin.id) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('直前の写真を読み込めませんでした：$error')),
        );
      }
      return false;
    }
  }

  Future<Uint8List> _makePhotoThumbnail(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 360,
    );
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      try {
        final ByteData? data =
            await frame.image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return _unavailablePhotoPreviewBytes;
        return data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<void> _replaceWithEditedPreviews(
    PinData pin,
    List<PhotoData> photos,
  ) async {
    for (int index = 0; index < photos.length; index++) {
      final PhotoData photo = photos[index];
      if (!(_photoAnnotationsById[photo.id]?.isNotEmpty ?? false)) continue;
      try {
        final Uint8List? edited = await ProjectRepository.loadEditedPhotoBytes(
          projectId: widget.projectId,
          documentId: pin.documentId,
          pinNumber: pin.number,
          pinName: pin.name,
          photoId: photo.id,
        );
        if (edited == null || edited.isEmpty) continue;
        final Uint8List preview = await _makePhotoThumbnail(edited);
        photos[index] = PhotoData(
          id: photo.id,
          fileName: photo.fileName,
          bytes: preview,
          savedPath: photo.savedPath,
        );
      } catch (_) {
        // The vector annotation remains authoritative and can be rendered
        // again when the photo editor is opened.
      }
    }
  }

  Future<PhotoData?> _saveCapturedPhoto(PinData pin, Uint8List bytes) async {
    int pinIndex = _pins.indexWhere((item) => item.id == pin.id);
    if (pinIndex < 0) return null;
    if (_photoStorageNeedsRescanPinIds.contains(pin.id)) {
      final bool photosReady = await _ensurePhotosLoadedForPin(_pins[pinIndex]);
      if (!photosReady || !mounted) return null;
      pinIndex = _pins.indexWhere((PinData item) => item.id == pin.id);
      if (pinIndex < 0) return null;
    }
    _photoSavesInProgressByPinId[pin.id] =
        (_photoSavesInProgressByPinId[pin.id] ?? 0) + 1;
    int? backgroundTask;

    try {
      backgroundTask = await NativeProjectService.beginBackgroundSave('写真を保存');
      final List<PhotoData> existing = List<PhotoData>.from(
        _photosByPinId[pin.id] ?? const <PhotoData>[],
      );
      final PinData currentPin = _pins[pinIndex];
      final int photoNumber = currentPin.photoCount + 1;
      final String fileName = '${photoNumber.toString().padLeft(3, '0')}.jpg';
      final String photoId =
          '${pin.id}-$photoNumber-${DateTime.now().microsecondsSinceEpoch}';
      final Uint8List thumbnailBytes = await _makePhotoThumbnail(bytes);
      final String storedFileName = await _enqueueStorageOperation<String>(
        () => ProjectRepository.savePhoto(
          projectId: widget.projectId,
          projectName: _projectName,
          pinId: pin.id,
          documentId: pin.documentId,
          pinNumber: pin.number,
          pinName: pin.name,
          photoId: photoId,
          fileName: fileName,
          bytes: bytes,
          thumbnailBytes: thumbnailBytes,
        ),
      );
      final PhotoData savedPhoto = PhotoData(
        id: photoId,
        fileName: storedFileName,
        bytes: thumbnailBytes,
      );
      existing.add(savedPhoto);

      if (!mounted) return null;
      final int latestPinIndex = _pins.indexWhere((item) => item.id == pin.id);
      if (latestPinIndex < 0) return null;
      setState(() {
        _selectedPinId = pin.id;
        _photosByPinId.clear();
        _photosByPinId[pin.id] = existing;
        if (!_photoStorageNeedsRescanPinIds.contains(pin.id)) {
          _photoStorageVerifiedPinIds.add(pin.id);
        }
        final int nextCount = math.max(
          _pins[latestPinIndex].photoCount + 1,
          existing.length,
        );
        _pins[latestPinIndex] =
            _pins[latestPinIndex].copyWith(photoCount: nextCount);
        _discardPinRedoHistory();
        _setNoteController(_pins[latestPinIndex].note);
      });
      _scheduleSave(pins: true, drawings: false, meta: true);
      return savedPhoto;
    } catch (_) {
      // savePhoto writes the JPEG before updating its manifest. On a manifest
      // failure, force the next camera exit/entry to scan the folder so the
      // committed JPEG is recovered and counted.
      _photoStorageVerifiedPinIds.remove(pin.id);
      _photoStorageNeedsRescanPinIds.add(pin.id);
      rethrow;
    } finally {
      final int remaining = (_photoSavesInProgressByPinId[pin.id] ?? 1) - 1;
      if (remaining > 0) {
        _photoSavesInProgressByPinId[pin.id] = remaining;
      } else {
        _photoSavesInProgressByPinId.remove(pin.id);
      }
      await NativeProjectService.endBackgroundSave(backgroundTask);
    }
  }

  void _showAllPhotosForSelectedPin() {
    final PinData? pin = _selectedPin;
    if (pin == null) {
      return;
    }

    final List<PhotoData> photos = _photosForPin(pin.id);
    if (photos.isEmpty) {
      return;
    }

    showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 900,
              maxHeight: 700,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    left: 20,
                    right: 8,
                    top: 8,
                    bottom: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'ピン ${pin.number}の写真（${photos.length}）',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: photos.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1.2,
                    ),
                    itemBuilder: (context, index) {
                      final PhotoData photo = photos[index];
                      return InkWell(
                        onTap: () {
                          Navigator.of(context).pop();
                          if (widget.simplifiedMobile) {
                            _openPhotoReadOnly(pin, photo);
                          } else {
                            _openPhotoEditor(pin, photo);
                          }
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            fit: StackFit.expand,
                            children: <Widget>[
                              Image.memory(photo.bytes, fit: BoxFit.cover),
                              const Positioned(
                                right: 8,
                                bottom: 8,
                                child: Icon(
                                  Icons.fullscreen_rounded,
                                  color: Colors.white,
                                  shadows: <Shadow>[
                                    Shadow(color: Colors.black, blurRadius: 5),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openPhotoEditor(PinData pin, PhotoData photo) async {
    final List<PhotoData> photos = _photosForPin(pin.id);
    if (photos.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PhotoEditorScreen(
          projectId: widget.projectId,
          documentId: pin.documentId,
          pinNumber: pin.number,
          pinName: pin.name,
          photos: photos,
          initialPhotoId: photo.id,
          annotations: <String, List<DrawingStroke>>{
            for (final PhotoData item in photos)
              item.id: List<DrawingStroke>.of(
                _photoAnnotationsById[item.id] ?? const <DrawingStroke>[],
              ),
          },
          onSaved: (
            String photoId,
            List<DrawingStroke> strokes,
            Uint8List? renderedImage,
          ) async {
            if (renderedImage == null || strokes.isEmpty) {
              await _enqueueStorageOperation<void>(
                () => ProjectRepository.deleteEditedPhoto(
                  projectId: widget.projectId,
                  documentId: pin.documentId,
                  pinNumber: pin.number,
                  pinName: pin.name,
                  photoId: photoId,
                ),
              );
            } else {
              await _enqueueStorageOperation<void>(
                () => ProjectRepository.saveEditedPhoto(
                  projectId: widget.projectId,
                  documentId: pin.documentId,
                  pinNumber: pin.number,
                  pinName: pin.name,
                  photoId: photoId,
                  bytes: renderedImage,
                ),
              );
            }
            if (!mounted) return;
            Uint8List? preview;
            if (renderedImage != null && renderedImage.isNotEmpty) {
              preview = await _makePhotoThumbnail(renderedImage);
            } else {
              PhotoData? originalPhoto;
              for (final PhotoData candidate in photos) {
                if (candidate.id == photoId) {
                  originalPhoto = candidate;
                  break;
                }
              }
              if (originalPhoto != null) {
                final Uint8List? originalBytes =
                    await ProjectRepository.loadPhotoBytes(
                  projectId: widget.projectId,
                  documentId: pin.documentId,
                  photoId: photoId,
                  pinNumber: pin.number,
                  pinName: pin.name,
                  fileName: originalPhoto.fileName,
                );
                if (originalBytes != null && originalBytes.isNotEmpty) {
                  preview = await _makePhotoThumbnail(originalBytes);
                }
              }
            }
            if (!mounted) return;
            setState(() {
              if (strokes.isEmpty) {
                _photoAnnotationsById.remove(photoId);
              } else {
                _photoAnnotationsById[photoId] =
                    List<DrawingStroke>.of(strokes);
              }
              if (preview != null) {
                final List<PhotoData>? cached = _photosByPinId[pin.id];
                final int index = cached?.indexWhere(
                      (PhotoData item) => item.id == photoId,
                    ) ??
                    -1;
                if (cached != null && index >= 0) {
                  final PhotoData current = cached[index];
                  cached[index] = PhotoData(
                    id: current.id,
                    fileName: current.fileName,
                    bytes: preview,
                    savedPath: current.savedPath,
                  );
                }
              }
            });
            _scheduleSave(pins: false, drawings: false, meta: true);
          },
        ),
      ),
    );
  }

  Future<void> _openPhotoReadOnly(PinData pin, PhotoData photo) async {
    final Uint8List? bytes = await ProjectRepository.loadPhotoBytes(
      projectId: widget.projectId,
      documentId: pin.documentId,
      photoId: photo.id,
      pinNumber: pin.number,
      pinName: pin.name,
      fileName: photo.fileName,
    );
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('写真を読み込めませんでした。')),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Text('ピン ${pin.number} ${pin.name}'.trim()),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 8,
              child: Image.memory(bytes),
            ),
          ),
        ),
      ),
    );
  }

  PinData? get _selectedPin {
    final String? selectedId = _selectedPinId;

    if (selectedId == null) {
      return null;
    }

    for (final PinData pin in _pins) {
      if (pin.id == selectedId) {
        return pin;
      }
    }

    return null;
  }

  List<PinData> get _currentPagePins {
    return _pins
        .where(
          (pin) =>
              pin.documentId == _activeDocumentId &&
              pin.pageNumber == _currentPage,
        )
        .toList();
  }

  Future<bool> _renderPage(
    int pageNumber, {
    bool commitPage = false,
  }) async {
    final pdfx.PdfDocument? document = _pdfDocument;
    if (document == null ||
        pageNumber < 1 ||
        pageNumber > document.pagesCount) {
      return false;
    }

    final int requestSequence = ++_renderRequestSequence;
    setState(() {
      _isRenderingPage = true;
      _pageImageBytes = null;
      _failedRenderPage = null;
      _errorMessage = null;
    });

    pdfx.PdfPage? page;
    try {
      page = await document.getPage(pageNumber);
      const double renderScale = 2.0;
      final pdfx.PdfPageImage? image = await page.render(
        width: page.width * renderScale,
        height: page.height * renderScale,
        format: pdfx.PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );

      if (image == null) {
        throw StateError('$pageNumberページ目の画像データが空です。');
      }
      if (!mounted || requestSequence != _renderRequestSequence) {
        return false;
      }
      final ui.Image decodedPageImage = await _decodeUiImage(image.bytes);
      final double aspectRatio;
      try {
        aspectRatio = decodedPageImage.width / decodedPageImage.height;
      } finally {
        decodedPageImage.dispose();
      }
      if (!mounted || requestSequence != _renderRequestSequence) {
        return false;
      }

      _transformationController.value = Matrix4.identity();
      setState(() {
        if (commitPage) {
          _currentPage = pageNumber;
        }
        _pageImageBytes = image.bytes;
        _pageAspectRatio = aspectRatio;
        _isRenderingPage = false;
        _failedRenderPage = null;
      });
      return true;
    } catch (error) {
      if (!mounted || requestSequence != _renderRequestSequence) {
        return false;
      }
      setState(() {
        _pageImageBytes = null;
        _isRenderingPage = false;
        _failedRenderPage = pageNumber;
        _errorMessage = 'PDFページを表示できませんでした。\n$error';
      });
      return false;
    } finally {
      await page?.close();
      if (mounted &&
          requestSequence == _renderRequestSequence &&
          _isRenderingPage) {
        setState(() => _isRenderingPage = false);
      }
    }
  }

  Future<void> _goToPage(int pageNumber) async {
    if (_pdfDocument == null ||
        pageNumber < 1 ||
        pageNumber > _pageCount ||
        pageNumber == _currentPage ||
        _isRenderingPage) {
      return;
    }

    _endStroke();
    _saveSelectedPinNote();
    final bool removedTextDraft = _discardEmptyTextDrafts(_currentPage);
    _noteController?.dispose();
    _noteController = null;

    setState(() {
      _selectedPinId = null;
      _pendingDirectionPinId = null;
      _captureAfterDirectionPinId = null;
    });

    final bool rendered = await _renderPage(pageNumber, commitPage: true);
    if (rendered) {
      _scheduleSave(
        pins: false,
        drawings: removedTextDraft,
        meta: true,
      );
    }
  }

  Future<void> _retryFailedPageRender() async {
    final int? pageNumber = _failedRenderPage;
    if (pageNumber == null || _isRenderingPage) return;
    final bool commitPage = pageNumber != _currentPage;
    final bool rendered = await _renderPage(
      pageNumber,
      commitPage: commitPage,
    );
    if (rendered && commitPage) {
      _scheduleSave(pins: false, drawings: false, meta: true);
    }
  }

  Future<void> _switchDocument(String documentId) async {
    if (documentId == _activeDocumentId ||
        _isRenderingPage ||
        _isPickingFile ||
        _isLeaving) {
      return;
    }
    ProjectPdfDocument? target;
    for (final ProjectPdfDocument document in _documents) {
      if (document.id == documentId) {
        target = document;
        break;
      }
    }
    if (target == null) return;
    _endStroke();
    _saveSelectedPinNote();
    _rememberCurrentDocumentPage();
    _saveDebounce?.cancel();
    await _enqueueSave();
    if (!mounted) return;
    final Uint8List? bytes = await ProjectRepository.loadPdfDocument(
      projectId: widget.projectId,
      documentId: target.id,
    );
    if (bytes == null || bytes.isEmpty) {
      setState(() => _errorMessage = '${target!.name}を読み込めませんでした。');
      return;
    }
    final String? sourcePath = await ProjectRepository.sourcePdfPath(
      widget.projectId,
      documentId: target.id,
    );
    if (sourcePath != null) {
      try {
        await NativeProjectService.synchronizePencilDrawings(sourcePath);
      } catch (_) {
        // The app's own stroke data remains authoritative. A damaged native
        // sidecar must not prevent switching to another PDF.
      }
    }
    final pdfx.PdfDocument nextDocument = await pdfx.PdfDocument.openData(
      Uint8List.fromList(bytes),
    );
    if (!mounted) {
      await nextDocument.close();
      return;
    }
    final pdfx.PdfDocument? previous = _pdfDocument;
    setState(() {
      _currentDocumentId = target!.id;
      _pdfDocument = nextDocument;
      _pdfBytes = Uint8List.fromList(bytes);
      _pdfPath = '${target.id}-${bytes.length}';
      _pageCount = nextDocument.pagesCount;
      _currentPage = target.currentPage.clamp(1, nextDocument.pagesCount);
      _pageImageBytes = null;
      _thumbnailFutures.clear();
      _selectedPinId = null;
      _selectedAnnotationId = null;
      _pendingDirectionPinId = null;
      _captureAfterDirectionPinId = null;
      _refreshNextPinNumber();
      _metaDirty = true;
    });
    _noteController?.dispose();
    _noteController = null;
    await previous?.close();
    await _renderPage(_currentPage);
    _scheduleSave(pins: false, drawings: false, meta: true);
  }

  String _threeDigits(int value) => value.toString().padLeft(3, '0');

  String _pinPhotoFolderName(int number, String name) {
    final String safeName = name
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return safeName.isEmpty
        ? _threeDigits(number)
        : '${_threeDigits(number)} $safeName';
  }

  bool _isPng(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;

  String _safeProjectFileName() {
    final String sanitized = _projectName
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return sanitized.isEmpty ? '名称未設定' : sanitized;
  }

  Future<ui.Image> _decodeUiImage(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  void _paintMinimalExportPin(
    Canvas canvas,
    PinData pin,
    Offset center,
    double exportScale,
  ) {
    final Color basePinColor = Color(pin.colorValue);
    final double pinOpacity = pin.opacity.clamp(0.1, 1);
    final Color pinColor = basePinColor.withValues(
      alpha: (basePinColor.a * pinOpacity).clamp(0.0, 1.0),
    );
    final bool lightColor = pinColor.computeLuminance() > 0.62;
    final Color edgeColor = lightColor
        ? const Color(0xFF3B3420).withValues(alpha: pinOpacity)
        : Colors.white.withValues(alpha: 0.96 * pinOpacity);
    final Color textColor =
        (lightColor ? const Color(0xFF10151C) : Colors.white)
            .withValues(alpha: pinOpacity);
    final double pinScale = pin.sizeScale.clamp(1 / 3, 1);
    final double radius = 12 * exportScale * pinScale;
    final double angle = pin.directionDegrees * math.pi / 180;
    final Offset forward = Offset(math.sin(angle), -math.cos(angle));
    final Offset side = Offset(math.cos(angle), math.sin(angle));
    final Offset arrowCenter =
        center + forward * (radius + 5 * exportScale * pinScale);
    final double arrowLength = 6 * exportScale * pinScale;
    final double arrowHalfWidth = 3.5 * exportScale * pinScale;
    final Offset tip = arrowCenter + forward * (arrowLength / 2);
    final Offset baseCenter = arrowCenter - forward * (arrowLength / 2);
    final Path arrow = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(
        baseCenter.dx + side.dx * arrowHalfWidth,
        baseCenter.dy + side.dy * arrowHalfWidth,
      )
      ..lineTo(
        baseCenter.dx - side.dx * arrowHalfWidth,
        baseCenter.dy - side.dy * arrowHalfWidth,
      )
      ..close();

    if (pin.photoCount > 0) {
      canvas.drawCircle(
        center,
        radius + 3.5 * exportScale * pinScale,
        Paint()
          ..color = const Color(0xFF49B7FF).withValues(alpha: pinOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, 2.2 * exportScale * pinScale),
      );
    }
    if (pin.showsDirection) {
      canvas.drawPath(
        arrow,
        Paint()
          ..color = edgeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, 2.6 * exportScale * pinScale)
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(arrow, Paint()..color = pinColor);
    }
    canvas.drawCircle(center, radius, Paint()..color = pinColor);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = edgeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, 1.6 * exportScale * pinScale),
    );

    final String label = pin.number.toString();
    final double baseFontSize = 11 * exportScale * pinScale;
    final double fontSize = math.max(
        4 * exportScale,
        label.length >= 3
            ? baseFontSize - 2 * exportScale * pinScale
            : baseFontSize);
    final TextPainter textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: radius * 2);
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  Future<Uint8List> _buildAnnotatedPageImage(
    int pageNumber, {
    required pdfx.PdfDocument document,
    required Map<int, List<DrawingStroke>> strokesByPage,
    required List<PinData> pins,
    required bool includeDrawings,
  }) async {
    pdfx.PdfPage? page;
    ui.Image? background;
    ui.Image? output;
    try {
      page = await document.getPage(pageNumber);
      const double exportScale = 2.0;
      final pdfx.PdfPageImage? rendered = await page.render(
        width: page.width * exportScale,
        height: page.height * exportScale,
        format: pdfx.PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      if (rendered == null) {
        throw StateError('$pageNumberページ目を画像化できませんでした。');
      }

      background = await _decodeUiImage(rendered.bytes);
      final double width = background.width.toDouble();
      final double height = background.height.toDouble();
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      canvas.drawImage(background, Offset.zero, Paint());

      if (includeDrawings) {
        paintDrawingStrokes(
          canvas,
          Size(width, height),
          strokesByPage[pageNumber] ?? const <DrawingStroke>[],
          widthScale: exportScale,
        );
      }

      final List<PinData> pagePins = pins
          .where((pin) => pin.pageNumber == pageNumber)
          .toList(growable: false);
      for (final PinData pin in pagePins) {
        final Offset center = Offset(
          pin.xRatio * width,
          pin.yRatio * height,
        );
        _paintMinimalExportPin(canvas, pin, center, exportScale);
      }

      output = await recorder.endRecording().toImage(
            background.width,
            background.height,
          );
      final ByteData? pngData =
          await output.toByteData(format: ui.ImageByteFormat.png);
      if (pngData == null) {
        throw StateError('$pageNumberページ目の出力画像を作成できませんでした。');
      }
      return pngData.buffer.asUint8List();
    } finally {
      output?.dispose();
      background?.dispose();
      await page?.close();
    }
  }

  Future<Uint8List> _buildAnnotatedPdf({
    required pdfx.PdfDocument document,
    required Map<int, List<DrawingStroke>> strokesByPage,
    required List<int> pageNumbers,
    required List<PinData> pins,
    required bool includeDrawings,
  }) async {
    final pw.Document outputPdf = pw.Document();
    for (final int pageNumber in pageNumbers) {
      final Uint8List pagePng = await _buildAnnotatedPageImage(
        pageNumber,
        document: document,
        strokesByPage: strokesByPage,
        pins: pins,
        includeDrawings: includeDrawings,
      );
      final ui.Image decoded = await _decodeUiImage(pagePng);
      final double aspectRatio = decoded.width / decoded.height;
      decoded.dispose();
      const double pdfWidth = 595.28;
      final double pdfHeight = pdfWidth / aspectRatio;
      final pw.MemoryImage pageImage = pw.MemoryImage(pagePng);
      outputPdf.addPage(
        pw.Page(
          pageFormat: pdf.PdfPageFormat(pdfWidth, pdfHeight, marginAll: 0),
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(pageImage, fit: pw.BoxFit.fill),
        ),
      );
    }
    return outputPdf.save();
  }

  Set<int> _annotatedPagesForContents(
    Set<_ExportContent> contents, {
    required String documentId,
  }) {
    final bool includePins = contents.contains(_ExportContent.pins) ||
        contents.contains(_ExportContent.both);
    final bool includeDrawings = contents.contains(_ExportContent.drawings) ||
        contents.contains(_ExportContent.both);
    return buildAnnotatedPageNumbers(
      pins: includePins
          ? _pins.where((PinData pin) => pin.documentId == documentId)
          : const <PinData>[],
      strokesByPage: includeDrawings
          ? _strokesByDocumentPage[documentId] ??
              const <int, List<DrawingStroke>>{}
          : const <int, List<DrawingStroke>>{},
    );
  }

  String _exportContentLabel(_ExportContent content) => switch (content) {
        _ExportContent.pins => 'ピンのみ',
        _ExportContent.drawings => '書き込みのみ',
        _ExportContent.both => 'ピンと書き込み',
      };

  Future<Set<_ExportContent>?> _chooseExportContents() async {
    final Set<_ExportContent> selected = <_ExportContent>{_ExportContent.both};
    return showDialog<Set<_ExportContent>>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          return AlertDialog(
            title: const Text('書き出す内容'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: _ExportContent.values.map((_ExportContent content) {
                final bool available = switch (content) {
                  _ExportContent.pins => _pins.isNotEmpty,
                  _ExportContent.drawings => _strokesByDocumentPage.values.any(
                      (Map<int, List<DrawingStroke>> pages) => pages.values
                          .any((List<DrawingStroke> value) => value.isNotEmpty),
                    ),
                  _ExportContent.both => _pins.isNotEmpty ||
                      _strokesByDocumentPage.values.any(
                        (Map<int, List<DrawingStroke>> pages) =>
                            pages.values.any(
                          (List<DrawingStroke> value) => value.isNotEmpty,
                        ),
                      ),
                };
                return CheckboxListTile(
                  value: selected.contains(content),
                  enabled: available,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(_exportContentLabel(content)),
                  onChanged: (bool? checked) {
                    setDialogState(() {
                      if (checked == true) {
                        selected.add(content);
                      } else {
                        selected.remove(content);
                      }
                    });
                  },
                );
              }).toList(growable: false),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(
                          dialogContext,
                          Set<_ExportContent>.of(selected),
                        ),
                child: const Text('次へ'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<_ExportPageMode?> _chooseExportPageMode(
    Set<_ExportContent> contents,
  ) {
    final int annotatedCount = _documents.fold<int>(
      0,
      (int total, ProjectPdfDocument document) =>
          total +
          _annotatedPagesForContents(contents, documentId: document.id).length,
    );
    final int totalPageCount = _documents.fold<int>(
      0,
      (int total, ProjectPdfDocument document) => total + document.pageCount,
    );
    return showDialog<_ExportPageMode>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('PDFに書き出すページ'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _ExportPageMode.allPages),
            child: ListTile(
              leading: const Icon(Icons.library_books_rounded),
              title: const Text('すべてのページ'),
              subtitle: Text('$totalPageCountページを書き出します'),
            ),
          ),
          SimpleDialogOption(
            onPressed: annotatedCount == 0
                ? null
                : () => Navigator.pop(
                      context,
                      _ExportPageMode.annotatedPages,
                    ),
            child: ListTile(
              enabled: annotatedCount > 0,
              leading: const Icon(Icons.filter_alt_rounded),
              title: const Text('書き込みのあるページのみ'),
              subtitle: Text(
                annotatedCount == 0
                    ? '対象ページがありません'
                    : '$annotatedCount / $totalPageCountページを書き出します',
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 10, 24, 6),
            child: Text(
              'ピン番号と写真フォルダ番号は、ページ順に自動整理されます。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportProject() async {
    if (_pdfDocument == null || _isExporting) return;
    ProjectExportZipSink? zipSink;
    _endStroke();
    final Set<_ExportContent>? contents = await _chooseExportContents();
    if (contents == null || contents.isEmpty || !mounted) return;
    final _ExportPageMode? pageMode = await _chooseExportPageMode(contents);
    if (pageMode == null || !mounted) return;
    _saveSelectedPinNote();
    setState(() {
      _isExporting = true;
      _errorMessage = null;
    });

    try {
      _saveDebounce?.cancel();
      await _enqueueSave();
      final String baseName = _safeProjectFileName();
      final List<PinData> sortedPins = _documents
          .expand(
            (ProjectPdfDocument document) => pinsInExportOrder(
              _pins.where(
                (PinData pin) => pin.documentId == document.id,
              ),
            ),
          )
          .toList(growable: false);
      final Map<String, int> exportNumbers = <String, int>{};
      for (final ProjectPdfDocument document in _documents) {
        exportNumbers.addAll(
          buildExportPinNumbers(
            sortedPins.where(
              (PinData pin) => pin.documentId == document.id,
            ),
          ),
        );
      }
      final List<PinData> exportPins = sortedPins
          .map(
            (PinData pin) => pin.copyWith(number: exportNumbers[pin.id]),
          )
          .toList(growable: false);
      // Write entries incrementally. The previous Archive-based implementation
      // retained every full-resolution photo and then allocated the ZIP beside
      // them. PDF and JPEG data are already compressed, so storing them avoids
      // a second large temporary deflate buffer for each entry.
      zipSink = await ProjectExportZipSink.create();
      final ZipEncoder zipEncoder = ZipEncoder()..startEncode(zipSink.output);
      final List<Map<String, dynamic>> serializedStrokes = _serializeStrokes();
      for (final ProjectPdfDocument document in _documents) {
        final List<int> documentPageNumbers = pageMode ==
                _ExportPageMode.allPages
            ? <int>[for (int page = 1; page <= document.pageCount; page++) page]
            : (_annotatedPagesForContents(
                contents,
                documentId: document.id,
              ).toList()
              ..sort());
        if (documentPageNumbers.isEmpty) continue;
        final List<PinData> documentPins = exportPins
            .where((PinData pin) => pin.documentId == document.id)
            .toList(growable: false);
        final List<Map<String, dynamic>> documentStrokes = serializedStrokes
            .where(
              (Map<String, dynamic> stroke) =>
                  stroke['documentId']?.toString() == document.id,
            )
            .toList(growable: false);
        pdfx.PdfDocument? fallbackDocument;
        if (!NativeProjectService.isAvailable) {
          final Uint8List? sourceBytes =
              await ProjectRepository.loadPdfDocument(
            projectId: widget.projectId,
            documentId: document.id,
          );
          if (sourceBytes == null || sourceBytes.isEmpty) {
            throw StateError('${document.name}を読み込めませんでした。');
          }
          fallbackDocument = await pdfx.PdfDocument.openData(
            Uint8List.fromList(sourceBytes),
          );
        }
        try {
          for (final _ExportContent content
              in _ExportContent.values.where(contents.contains)) {
            final List<int> pageNumbers = pageMode == _ExportPageMode.allPages
                ? documentPageNumbers
                : (_annotatedPagesForContents(
                    <_ExportContent>{content},
                    documentId: document.id,
                  ).toList()
                  ..sort());
            if (pageNumbers.isEmpty) continue;
            final bool includePins = content != _ExportContent.drawings;
            final bool includeDrawings = content != _ExportContent.pins;
            final List<PinData> contentPins =
                includePins ? documentPins : const <PinData>[];
            final List<Map<String, dynamic>> contentStrokes = includeDrawings
                ? documentStrokes
                : const <Map<String, dynamic>>[];
            final Uint8List pdfBytes;
            if (NativeProjectService.isAvailable) {
              final String? sourcePath = await ProjectRepository.sourcePdfPath(
                widget.projectId,
                documentId: document.id,
              );
              if (sourcePath == null) {
                throw StateError('書き出し用PDFが見つかりません。');
              }
              pdfBytes = await NativeProjectService.buildExportPdf(
                sourcePath: sourcePath,
                pins: contentPins.map(_serializePin).toList(growable: false),
                strokes: contentStrokes,
                pageNumbers: pageNumbers,
              );
            } else {
              pdfBytes = await _buildAnnotatedPdf(
                document: fallbackDocument!,
                strokesByPage: _strokesByDocumentPage[document.id] ??
                    const <int, List<DrawingStroke>>{},
                pageNumbers: pageNumbers,
                pins: contentPins,
                includeDrawings: includeDrawings,
              );
            }
            final String pdfName;
            if (_documents.length == 1 &&
                contents.length == 1 &&
                content == _ExportContent.both) {
              pdfName = '$baseName.pdf';
            } else {
              final String suffix =
                  contents.length == 1 && content == _ExportContent.both
                      ? ''
                      : '_${_exportContentLabel(content)}';
              pdfName = '${document.folderName}$suffix.pdf';
            }
            zipEncoder.add(
              ArchiveFile.noCompress(pdfName, pdfBytes.length, pdfBytes),
              autoClose: true,
            );
          }
        } finally {
          await fallbackDocument?.close();
        }
      }

      final List<Map<String, dynamic>> photoMetadata =
          await ProjectRepository.loadPhotoMetadata(widget.projectId);
      final Map<String, List<Map<String, dynamic>>> photoMetadataByPin =
          <String, List<Map<String, dynamic>>>{};
      for (final Map<String, dynamic> record in photoMetadata) {
        final String pinId = record['pinId']?.toString() ?? '';
        if (pinId.isEmpty) continue;
        photoMetadataByPin
            .putIfAbsent(pinId, () => <Map<String, dynamic>>[])
            .add(record);
      }
      final Map<String, PinData> pinsById = <String, PinData>{
        for (final PinData pin in sortedPins) pin.id: pin,
      };
      final Map<String, ProjectPdfDocument> documentsById =
          <String, ProjectPdfDocument>{
        for (final ProjectPdfDocument document in _documents)
          document.id: document,
      };
      final List<Map<String, dynamic>> exportPhotos = <Map<String, dynamic>>[];
      for (final PinData pin in sortedPins) {
        final List<Map<String, dynamic>> storedPhotos =
            photoMetadataByPin[pin.id] ?? const <Map<String, dynamic>>[];
        for (final Map<String, dynamic> storedPhoto in storedPhotos) {
          final String photoId = storedPhoto['photoId']?.toString() ?? '';
          final int? storedPinNumber =
              (storedPhoto['pinNumber'] as num?)?.toInt();
          final String storedFileName =
              storedPhoto['fileName']?.toString() ?? '';
          if (photoId.isEmpty ||
              storedPinNumber == null ||
              storedFileName.isEmpty) {
            continue;
          }
          exportPhotos.add(storedPhoto);
        }
      }

      final Map<String, int> exportedPhotoCounts = <String, int>{};
      await ProjectRepository.visitPhotoBytes(
        projectId: widget.projectId,
        photos: exportPhotos,
        visitor: (
          int _,
          Map<String, dynamic> storedPhoto,
          Uint8List photoBytes,
        ) async {
          final String pinId = storedPhoto['pinId']?.toString() ?? '';
          final PinData? pin = pinsById[pinId];
          if (pin == null || photoBytes.isEmpty) return;
          final int photoCount = (exportedPhotoCounts[pinId] ?? 0) + 1;
          exportedPhotoCounts[pinId] = photoCount;
          final String photoId = storedPhoto['photoId']?.toString() ?? '';
          final bool hasAnnotations =
              _photoAnnotationsById[photoId]?.isNotEmpty ?? false;
          final int exportNumber = exportNumbers[pin.id] ?? pin.number;
          final String documentFolder =
              documentsById[pin.documentId]?.folderName ?? '01_図面';
          final String folder =
              '写真/$documentFolder/${_pinPhotoFolderName(exportNumber, pin.name)}/';
          final String number = _threeDigits(photoCount);
          if (hasAnnotations) {
            zipEncoder.add(
              ArchiveFile.noCompress(
                '$folder${number}_原本.jpg',
                photoBytes.length,
                photoBytes,
              ),
              autoClose: true,
            );
            final Uint8List? edited =
                await ProjectRepository.loadEditedPhotoBytes(
              projectId: widget.projectId,
              documentId: pin.documentId,
              pinNumber: pin.number,
              pinName: pin.name,
              photoId: photoId,
            );
            if (edited != null && edited.isNotEmpty) {
              final String editedExtension = _isPng(edited) ? 'png' : 'jpg';
              zipEncoder.add(
                ArchiveFile.noCompress(
                  '$folder${number}_書き込み済み.$editedExtension',
                  edited.length,
                  edited,
                ),
                autoClose: true,
              );
            }
          } else {
            zipEncoder.add(
              ArchiveFile.noCompress(
                '$folder$number.jpg',
                photoBytes.length,
                photoBytes,
              ),
              autoClose: true,
            );
          }
        },
      );
      for (final PinData pin in sortedPins) {
        if ((exportedPhotoCounts[pin.id] ?? 0) == 0) {
          final String documentFolder =
              documentsById[pin.documentId]?.folderName ?? '01_図面';
          zipEncoder.add(
            ArchiveFile.directory(
              '写真/$documentFolder/'
              '${_pinPhotoFolderName(exportNumbers[pin.id] ?? pin.number, pin.name)}/',
            ),
            autoClose: true,
          );
        }
      }

      zipEncoder.endEncode();
      await zipSink.save(baseName);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDFと写真フォルダをZIPで書き出しました。')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '書き出しに失敗しました。\n$error';
      });
    } finally {
      try {
        await zipSink?.dispose();
      } catch (error) {
        if (mounted && _errorMessage == null) {
          setState(() {
            _errorMessage = '書き出し用の一時ファイルを削除できませんでした。\n$error';
          });
        }
      } finally {
        if (mounted) {
          setState(() {
            _isExporting = false;
          });
        }
      }
    }
  }

  Future<void> _exportPinsOnlyMobile() async {
    if (_pdfDocument == null || _isExporting) return;
    if (_pins.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('書き出すピンがありません。')),
      );
      return;
    }
    final Set<_ExportContent> contents = <_ExportContent>{_ExportContent.pins};
    final _ExportPageMode? pageMode = await _chooseExportPageMode(contents);
    if (pageMode == null || !mounted) return;
    _saveSelectedPinNote();
    setState(() {
      _isExporting = true;
      _errorMessage = null;
    });
    int exportedCount = 0;
    try {
      _saveDebounce?.cancel();
      await _enqueueSave();
      final List<PinData> orderedPins = _documents
          .expand(
            (ProjectPdfDocument document) => pinsInExportOrder(
              _pins.where(
                (PinData pin) => pin.documentId == document.id,
              ),
            ),
          )
          .toList(growable: false);
      final Map<String, int> exportNumbers = <String, int>{};
      for (final ProjectPdfDocument document in _documents) {
        exportNumbers.addAll(
          buildExportPinNumbers(
            orderedPins.where(
              (PinData pin) => pin.documentId == document.id,
            ),
          ),
        );
      }
      final List<PinData> exportPins = orderedPins
          .map(
            (PinData pin) => pin.copyWith(number: exportNumbers[pin.id]),
          )
          .toList(growable: false);

      for (final ProjectPdfDocument document in _documents) {
        final List<PinData> documentPins = exportPins
            .where((PinData pin) => pin.documentId == document.id)
            .toList(growable: false);
        if (documentPins.isEmpty) continue;
        final List<int> pageNumbers = pageMode == _ExportPageMode.allPages
            ? <int>[
                for (int page = 1; page <= document.pageCount; page++) page,
              ]
            : (_annotatedPagesForContents(
                contents,
                documentId: document.id,
              ).toList()
              ..sort());
        if (pageNumbers.isEmpty) continue;

        final Uint8List exportedPdf;
        if (NativeProjectService.isAvailable) {
          final String? sourcePath = await ProjectRepository.sourcePdfPath(
            widget.projectId,
            documentId: document.id,
          );
          if (sourcePath == null) {
            throw StateError('${document.name}の元PDFが見つかりません。');
          }
          exportedPdf = await NativeProjectService.buildExportPdf(
            sourcePath: sourcePath,
            pins: documentPins.map(_serializePin).toList(growable: false),
            strokes: const <Map<String, dynamic>>[],
            pageNumbers: pageNumbers,
          );
        } else {
          final Uint8List? sourceBytes =
              await ProjectRepository.loadPdfDocument(
            projectId: widget.projectId,
            documentId: document.id,
          );
          if (sourceBytes == null || sourceBytes.isEmpty) {
            throw StateError('${document.name}の元PDFが見つかりません。');
          }
          final pdfx.PdfDocument sourceDocument =
              await pdfx.PdfDocument.openData(sourceBytes);
          try {
            exportedPdf = await _buildAnnotatedPdf(
              document: sourceDocument,
              strokesByPage: const <int, List<DrawingStroke>>{},
              pageNumbers: pageNumbers,
              pins: documentPins,
              includeDrawings: false,
            );
          } finally {
            await sourceDocument.close();
          }
        }
        await ProjectRepository.saveMobileExportPdf(
          projectId: widget.projectId,
          fileName: '${document.folderName}_ピン付き.pdf',
          bytes: exportedPdf,
        );
        exportedCount++;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            exportedCount == 0
                ? '書き出し対象のPDFがありません。'
                : 'ピン付きPDFを$exportedCount件書き出しました。',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ピン付きPDFを書き出せませんでした。\n$error')),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  void _scheduleSave({
    bool pins = true,
    bool drawings = true,
    bool meta = true,
  }) {
    if (_isRestoring || _pdfBytes == null) return;
    _pinsDirty = _pinsDirty || pins;
    _drawingsDirty = _drawingsDirty || drawings;
    _metaDirty = _metaDirty || meta;
    _pdfDirty = _pdfDirty || pins || drawings;
    _saveDebounce?.cancel();
    if (mounted) {
      setState(() {});
    }
    // A short idle delay lets users write multi-stroke characters without a
    // database transaction being started after every single stroke.
    _saveDebounce = Timer(const Duration(milliseconds: 900), () {
      _saveDebounce = null;
      if (mounted) {
        setState(() {});
      }
      _enqueueSaveInBackground();
    });
  }

  bool get _hasPendingSave {
    return _pinsDirty ||
        _drawingsDirty ||
        _metaDirty ||
        _pdfDirty ||
        _pendingPhotoCleanupPinIds.isNotEmpty ||
        (_saveDebounce?.isActive ?? false);
  }

  void _scheduleAutomaticSaveRetry() {
    if (!mounted || (_saveRetryTimer?.isActive ?? false)) return;
    final int seconds = math.min(2 << _saveRetryAttempt.clamp(0, 3), 16);
    _saveRetryAttempt++;
    _saveRetryTimer = Timer(Duration(seconds: seconds), () {
      _saveRetryTimer = null;
      if (!mounted) return;
      setState(() {});
      _enqueueSaveInBackground();
    });
  }

  void _enqueueSaveInBackground() {
    unawaited(
      _enqueueSave().catchError((Object _, StackTrace __) {
        // _saveProjectNow already restores dirty flags and shows the error.
      }),
    );
  }

  Future<void> _enqueueSave() {
    _saveTail =
        _saveTail.catchError((Object _) {}).then((_) => _saveProjectNow());
    return _saveTail;
  }

  Future<T> _enqueueStorageOperation<T>(
    Future<T> Function() operation,
  ) {
    final Future<T> result =
        _saveTail.catchError((Object _) {}).then((_) => operation());
    _saveTail = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Map<String, dynamic> _serializePin(PinData pin) => <String, dynamic>{
        'id': pin.id,
        'documentId': pin.documentId,
        'number': pin.number,
        'pageNumber': pin.pageNumber,
        'xRatio': pin.xRatio,
        'yRatio': pin.yRatio,
        'directionDegrees': pin.directionDegrees,
        'photoCount': pin.photoCount,
        'name': pin.name,
        'note': pin.note,
        'colorValue': pin.colorValue,
        'opacity': pin.opacity,
        'sizeScale': pin.sizeScale,
        'showsDirection': pin.showsDirection,
        'boardEnabled': pin.boardEnabled,
        'boardTemplateId': pin.boardTemplateId,
        'boardShootingLocation': pin.boardShootingLocation,
        'boardCoreStep': pin.boardCoreStep,
        'boardChippingStep': pin.boardChippingStep,
        'boardAsbestosStep': pin.boardAsbestosStep,
        'boardPositionId': pin.boardPositionId,
      };

  List<Map<String, dynamic>> _serializePins() =>
      _pins.map(_serializePin).toList(growable: false);

  List<Map<String, dynamic>> _serializePinHistory(Iterable<_PinEdit> edits) =>
      edits
          .map(
            (_PinEdit edit) => <String, dynamic>{
              'kind': edit.kind.name,
              'pinId': edit.pinId,
              'index': edit.index,
              if (edit.before != null) 'before': _serializePin(edit.before!),
              if (edit.after != null) 'after': _serializePin(edit.after!),
            },
          )
          .toList(growable: false);

  PinData? _deserializePin(dynamic raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> map =
        raw.map((dynamic key, dynamic value) => MapEntry('$key', value));
    final String id = map['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return PinData(
      id: id,
      documentId: map['documentId']?.toString() ?? 'main',
      number: (map['number'] as num?)?.toInt() ?? 1,
      pageNumber: (map['pageNumber'] as num?)?.toInt() ?? 1,
      xRatio: (map['xRatio'] as num?)?.toDouble() ?? 0,
      yRatio: (map['yRatio'] as num?)?.toDouble() ?? 0,
      directionDegrees: (map['directionDegrees'] as num?)?.toDouble() ?? 0,
      photoCount: (map['photoCount'] as num?)?.toInt() ?? 0,
      name: map['name']?.toString() ?? '',
      note: map['note']?.toString() ?? '',
      colorValue: (map['colorValue'] as num?)?.toInt() ?? 0xFF1976D2,
      opacity: ((map['opacity'] as num?)?.toDouble() ?? 1).clamp(0.1, 1),
      sizeScale: ((map['sizeScale'] as num?)?.toDouble() ?? 1).clamp(1 / 3, 1),
      showsDirection: map['showsDirection'] != false,
      boardEnabled: map['boardEnabled'] == true,
      boardTemplateId: map['boardTemplateId']?.toString() ?? 'core',
      boardShootingLocation: map['boardShootingLocation']?.toString() ?? '',
      boardCoreStep: ((map['boardCoreStep'] as num?)?.toInt() ?? 0).clamp(0, 5),
      boardChippingStep:
          ((map['boardChippingStep'] as num?)?.toInt() ?? 0).clamp(0, 5),
      boardAsbestosStep:
          ((map['boardAsbestosStep'] as num?)?.toInt() ?? 0).clamp(0, 5),
      boardPositionId: map['boardPositionId']?.toString() ?? 'bottomLeft',
    );
  }

  List<_PinEdit> _deserializePinRedoHistory(dynamic raw) {
    if (raw is! List) return <_PinEdit>[];
    final List<_PinEdit> edits = <_PinEdit>[];
    for (final dynamic item in raw) {
      if (item is! Map) continue;
      final Map<String, dynamic> map =
          item.map((dynamic key, dynamic value) => MapEntry('$key', value));
      final int kindIndex = _PinEditKind.values.indexWhere(
        (_PinEditKind kind) => kind.name == map['kind']?.toString(),
      );
      final String pinId = map['pinId']?.toString() ?? '';
      if (kindIndex < 0 || pinId.isEmpty) continue;
      edits.add(
        _PinEdit(
          kind: _PinEditKind.values[kindIndex],
          pinId: pinId,
          index: (map['index'] as num?)?.toInt() ?? 0,
          before: _deserializePin(map['before']),
          after: _deserializePin(map['after']),
        ),
      );
    }
    return edits;
  }

  List<Map<String, dynamic>> _serializeStrokes() => _strokesByDocumentPage
      .values
      .expand((Map<int, List<DrawingStroke>> pages) => pages.values)
      .expand((List<DrawingStroke> strokes) => strokes)
      .where(
        (DrawingStroke stroke) =>
            stroke.kind != DrawingKind.text || stroke.text.trim().isNotEmpty,
      )
      .map(serializeDrawingStroke)
      .toList(growable: false);

  Map<String, dynamic> _serializePhotoAnnotations() => <String, dynamic>{
        for (final MapEntry<String, List<DrawingStroke>> entry
            in _photoAnnotationsById.entries)
          if (entry.value.any(
            (DrawingStroke stroke) =>
                stroke.kind != DrawingKind.text ||
                stroke.text.trim().isNotEmpty,
          ))
            entry.key: entry.value
                .where(
                  (DrawingStroke stroke) =>
                      stroke.kind != DrawingKind.text ||
                      stroke.text.trim().isNotEmpty,
                )
                .map(serializeDrawingStroke)
                .toList(growable: false),
      };

  Map<String, dynamic> _projectMetadata() {
    final List<ProjectPdfDocument> documents = _documents.map(
      (ProjectPdfDocument document) {
        return document.id == _activeDocumentId
            ? document.copyWith(currentPage: _currentPage)
            : document;
      },
    ).toList(growable: false);
    return <String, dynamic>{
      'pdfName': '$_projectName.pdf',
      'pageCount': documents.fold<int>(
        0,
        (int total, ProjectPdfDocument document) => total + document.pageCount,
      ),
      'currentPage': _currentPage,
      'nextPinNumber': _nextPinNumber,
      'documents': documents
          .map((ProjectPdfDocument document) => document.toJson())
          .toList(growable: false),
      'activeDocumentId': _activeDocumentId,
      'pinColor': _pinColor.toARGB32(),
      'penColor': _penColor.toARGB32(),
      'penWidth': _penWidth,
      'pinOpacity': _pinOpacity,
      'pinSizeScale': _pinSizeScale,
      'penOpacity': _penOpacity,
      'penBrush': _penBrush.name,
      'shapeKind': _shapeKind.name,
      'eraserWidth': _eraserWidth,
      'textFontSize': _textFontSize,
      'textBoxWidthRatio': _textBoxWidthRatio,
      'photoAnnotations': _serializePhotoAnnotations(),
      'boardBusinessName': _boardBusinessName,
      'boardFacilityName': _boardFacilityName,
      'pendingDirectionPinId': _pendingDirectionPinId,
      'captureAfterDirectionPinId': _captureAfterDirectionPinId,
      'pinUndoHistory': _serializePinHistory(_undoPinEdits),
      'pinRedoHistory': _serializePinHistory(_redoPinEdits),
      'pendingPhotoCleanupPinIds':
          _pendingPhotoCleanupPinIds.toList(growable: false),
    };
  }

  Future<void> _saveProjectNow() async {
    if (_isRestoring || _pdfBytes == null) return;

    final bool savePins = _pinsDirty;
    final bool saveDrawings = _drawingsDirty;
    final bool saveMeta = _metaDirty;
    final bool savePdf = _pdfDirty;
    final Set<String> cleanupPinIds =
        Set<String>.of(_pendingPhotoCleanupPinIds);
    if (!savePins &&
        !saveDrawings &&
        !saveMeta &&
        !savePdf &&
        cleanupPinIds.isEmpty) {
      return;
    }

    // Clear before awaiting. New edits made during the write set the flags again
    // and are handled by the next queued save.
    _pinsDirty = false;
    _drawingsDirty = false;
    _metaDirty = false;
    _pdfDirty = false;

    if (mounted) {
      setState(() => _saveInProgress = true);
    }
    int? backgroundTask;
    try {
      backgroundTask = await NativeProjectService.beginBackgroundSave('案件を保存');
      final List<Map<String, dynamic>> pins = _serializePins();
      final List<Map<String, dynamic>> strokes = _serializeStrokes();
      if (savePins ||
          saveDrawings ||
          saveMeta ||
          savePdf ||
          cleanupPinIds.isNotEmpty) {
        await ProjectRepository.saveProjectSnapshot(
          projectId: widget.projectId,
          projectName: _projectName,
          metadata: _projectMetadata(),
          pins: pins,
          strokes: strokes,
        );
      }
      if (savePdf && NativeProjectService.isAvailable) {
        final String? sourcePath = await ProjectRepository.sourcePdfPath(
          widget.projectId,
          documentId: _activeDocumentId,
        );
        final String? outputPath = await ProjectRepository.outputPdfPath(
          widget.projectId,
          documentId: _activeDocumentId,
        );
        if (sourcePath == null || outputPath == null) {
          throw StateError('PDFの保存先が見つかりません。');
        }
        await NativeProjectService.writeAnnotatedPdf(
          sourcePath: sourcePath,
          outputPath: outputPath,
          pins: pins
              .where(
                (Map<String, dynamic> pin) =>
                    pin['documentId']?.toString() == _activeDocumentId,
              )
              .toList(growable: false),
          strokes: strokes
              .where(
                (Map<String, dynamic> stroke) =>
                    stroke['documentId']?.toString() == _activeDocumentId,
              )
              .toList(growable: false),
        );
      }
      for (final String pinId in cleanupPinIds) {
        await ProjectRepository.deletePhotosForPin(
          projectId: widget.projectId,
          pinId: pinId,
        );
      }
      if (cleanupPinIds.isNotEmpty) {
        // Clear the durable cleanup marker only after every photo folder was
        // removed. If the app is terminated between these two snapshots, the
        // next launch safely retries the idempotent cleanup.
        final Set<String> remainingCleanupPinIds =
            Set<String>.of(_pendingPhotoCleanupPinIds)
              ..removeAll(cleanupPinIds);
        await ProjectRepository.saveProjectSnapshot(
          projectId: widget.projectId,
          projectName: _projectName,
          metadata: <String, dynamic>{
            ..._projectMetadata(),
            'pendingPhotoCleanupPinIds':
                remainingCleanupPinIds.toList(growable: false),
          },
          pins: _serializePins(),
          strokes: _serializeStrokes(),
        );
        _pendingPhotoCleanupPinIds.removeAll(cleanupPinIds);
      }
      _saveRetryTimer?.cancel();
      _saveRetryTimer = null;
      _saveRetryAttempt = 0;
      if (mounted) {
        setState(() => _saveErrorMessage = null);
      }
    } catch (error) {
      // Restore dirty flags so a retry does not lose pending edits.
      _pinsDirty = _pinsDirty || savePins;
      _drawingsDirty = _drawingsDirty || saveDrawings;
      _metaDirty = _metaDirty || saveMeta;
      _pdfDirty = _pdfDirty || savePdf;
      if (mounted) {
        setState(() {
          _saveErrorMessage = '案件の保存に失敗しました。\n$error';
        });
        _scheduleAutomaticSaveRetry();
      }
      rethrow;
    } finally {
      await NativeProjectService.endBackgroundSave(backgroundTask);
      if (mounted) {
        setState(() => _saveInProgress = false);
      }
    }
  }

  Future<void> _loadSavedProject() async {
    _isRestoring = true;
    Object? pencilRecoveryError;
    try {
      final data = await ProjectRepository.loadProject(widget.projectId);
      if (!mounted) return;
      if (data == null) {
        if (mounted) setState(() => _errorMessage = '案件データが見つかりません。');
        return;
      }
      final List<ProjectPdfDocument> restoredDocuments =
          (data['documents'] as List? ?? const <dynamic>[])
              .whereType<Map>()
              .map(
                (Map<dynamic, dynamic> raw) => ProjectPdfDocument.fromJson(
                  raw.map<String, dynamic>(
                    (dynamic key, dynamic value) =>
                        MapEntry<String, dynamic>(key.toString(), value),
                  ),
                ),
              )
              .toList(growable: true);
      if (restoredDocuments.isEmpty) {
        restoredDocuments.add(
          ProjectPdfDocument(
            id: 'main',
            name: data['pdfName']?.toString() ?? '${widget.projectName}.pdf',
            folderName:
                '01_${_documentStem(data['pdfName']?.toString() ?? widget.projectName)}',
            pageCount: (data['pageCount'] as num?)?.toInt() ?? 0,
            currentPage: (data['currentPage'] as num?)?.toInt() ?? 1,
          ),
        );
      }
      final String requestedDocumentId =
          data['activeDocumentId']?.toString() ?? restoredDocuments.first.id;
      final ProjectPdfDocument activeDocument = restoredDocuments.firstWhere(
        (ProjectPdfDocument document) => document.id == requestedDocumentId,
        orElse: () => restoredDocuments.first,
      );
      final String? sourcePath = await ProjectRepository.sourcePdfPath(
        widget.projectId,
        documentId: activeDocument.id,
      );
      if (!mounted) return;
      if (sourcePath != null) {
        try {
          await NativeProjectService.synchronizePencilDrawings(sourcePath);
        } catch (error) {
          pencilRecoveryError = error;
        }
      }
      if (!mounted) return;
      final dynamic storedPdf = await ProjectRepository.loadPdfDocument(
            projectId: widget.projectId,
            documentId: activeDocument.id,
          ) ??
          data['pdfBytes'];
      final Uint8List persistentBytes = storedPdf is Uint8List
          ? Uint8List.fromList(storedPdf)
          : storedPdf is List<int>
              ? Uint8List.fromList(storedPdf)
              : storedPdf is String
                  ? base64Decode(storedPdf)
                  : Uint8List(0);
      if (persistentBytes.isEmpty) {
        throw StateError('保存されたPDFデータが空です。');
      }
      // 再読込時も、表示用と再保存用のバッファを分ける。
      final document = await pdfx.PdfDocument.openData(
        Uint8List.fromList(persistentBytes),
      );
      if (!mounted) {
        await document.close();
        return;
      }
      final List<PinData> restoredPins = (data['pins'] as List? ?? const [])
          .map(_deserializePin)
          .whereType<PinData>()
          .toList(growable: true);
      final List<_PinEdit> restoredRedoPinEdits =
          _deserializePinRedoHistory(data['pinRedoHistory']);
      final List<_PinEdit> restoredUndoPinEdits =
          _deserializePinRedoHistory(data['pinUndoHistory']);
      final Set<String> restoredCleanupPinIds =
          (data['pendingPhotoCleanupPinIds'] as List? ?? const <dynamic>[])
              .map((dynamic value) => value.toString())
              .where((String id) => id.isNotEmpty)
              .toSet();
      final restoredStrokes = <String, Map<int, List<DrawingStroke>>>{};
      for (final v in (data['strokes'] as List? ?? const [])) {
        final DrawingStroke? stroke = deserializeDrawingStroke(
          v,
          defaultPageNumber: 1,
        );
        if (stroke == null) continue;
        restoredStrokes
            .putIfAbsent(
              stroke.documentId,
              () => <int, List<DrawingStroke>>{},
            )
            .putIfAbsent(stroke.pageNumber, () => <DrawingStroke>[])
            .add(stroke);
      }
      final Map<String, List<DrawingStroke>> restoredPhotoAnnotations =
          <String, List<DrawingStroke>>{};
      final dynamic rawPhotoAnnotations = data['photoAnnotations'];
      if (rawPhotoAnnotations is Map) {
        for (final MapEntry<dynamic, dynamic> entry
            in rawPhotoAnnotations.entries) {
          final String photoId = entry.key.toString();
          if (photoId.isEmpty || entry.value is! List) continue;
          final List<DrawingStroke> annotations = <DrawingStroke>[];
          for (final dynamic rawStroke in entry.value as List) {
            final DrawingStroke? stroke = deserializeDrawingStroke(rawStroke);
            if (stroke != null) annotations.add(stroke);
          }
          if (annotations.isNotEmpty) {
            restoredPhotoAnnotations[photoId] = annotations;
          }
        }
      }
      // Photo binaries are intentionally not loaded here. Only metadata is used
      // to repair counts; bytes are loaded when a pin is opened.
      final Map<String, int> photoCounts = <String, int>{};
      for (final dynamic raw in (data['photoMeta'] as List? ?? const [])) {
        final Map<String, dynamic> meta = Map<String, dynamic>.from(raw as Map);
        final String pinId = meta['pinId']?.toString() ?? '';
        if (pinId.isNotEmpty) {
          photoCounts[pinId] = (photoCounts[pinId] ?? 0) + 1;
        }
      }
      for (int i = 0; i < restoredPins.length; i++) {
        restoredPins[i] = restoredPins[i].copyWith(
          photoCount:
              photoCounts[restoredPins[i].id] ?? restoredPins[i].photoCount,
        );
      }
      for (int i = 0; i < restoredRedoPinEdits.length; i++) {
        final _PinEdit edit = restoredRedoPinEdits[i];
        final PinData? after = edit.after;
        if (edit.kind == _PinEditKind.add && after != null) {
          restoredRedoPinEdits[i] = edit.copyWith(
            after: after.copyWith(
              photoCount: photoCounts[after.id] ?? after.photoCount,
            ),
          );
        }
      }
      final Set<String> restoredActivePinIds =
          restoredPins.map((PinData pin) => pin.id).toSet();
      restoredRedoPinEdits.removeWhere((_PinEdit edit) {
        if (edit.kind == _PinEditKind.add) {
          final bool invalid =
              edit.after == null || restoredActivePinIds.contains(edit.pinId);
          if (invalid && !restoredActivePinIds.contains(edit.pinId)) {
            restoredCleanupPinIds.add(edit.pinId);
          }
          return invalid;
        }
        return !restoredActivePinIds.contains(edit.pinId);
      });
      restoredUndoPinEdits.removeWhere((_PinEdit edit) {
        if (edit.kind == _PinEditKind.delete) {
          return edit.before == null ||
              restoredActivePinIds.contains(edit.pinId);
        }
        return !restoredActivePinIds.contains(edit.pinId);
      });
      if (!mounted) return;
      setState(() {
        _projectName = data['projectName']?.toString() ?? widget.projectName;
        _documents
          ..clear()
          ..addAll(restoredDocuments);
        _currentDocumentId = activeDocument.id;
        _pdfDocument = document;
        _thumbnailFutures.clear();
        _pdfBytes = persistentBytes;
        _pdfPath = '${activeDocument.id}-${persistentBytes.length}';
        _pageCount = document.pagesCount;
        _pins
          ..clear()
          ..addAll(restoredPins);
        _undoPinEdits
          ..clear()
          ..addAll(restoredUndoPinEdits);
        _redoPinEdits
          ..clear()
          ..addAll(restoredRedoPinEdits);
        final Set<String> recoverablePinIds = <String>{
          ...restoredPins.map((PinData pin) => pin.id),
          ...restoredRedoPinEdits
              .where((_PinEdit edit) => edit.kind == _PinEditKind.add)
              .map((_PinEdit edit) => edit.pinId),
          ...restoredUndoPinEdits
              .where((_PinEdit edit) => edit.kind == _PinEditKind.delete)
              .map((_PinEdit edit) => edit.pinId),
        };
        _pendingPhotoCleanupPinIds
          ..clear()
          ..addAll(
            restoredCleanupPinIds
                .where((String id) => !recoverablePinIds.contains(id)),
          );
        _strokesByDocumentPage
          ..clear()
          ..addAll(restoredStrokes);
        _photoAnnotationsById
          ..clear()
          ..addAll(restoredPhotoAnnotations);
        _undoDrawingEditsByDocumentPage.clear();
        _redoDrawingEditsByDocumentPage.clear();
        _activeStroke = null;
        _activeStrokeIndex = null;
        _activeEraserPage = null;
        _lastEraserPosition = null;
        _activeEraserBeforeStrokes = null;
        _activeEraserSourceIds = null;
        _activeEraserTouchedSourceIds = null;
        _activeEraserEditId = null;
        _activeEraserAspectRatio = null;
        _activeEraserBoundsCache = null;
        _activeEraserSamplesCache = null;
        _photosByPinId.clear();
        _photoStorageVerifiedPinIds.clear();
        _photoStorageNeedsRescanPinIds.clear();
        _photoSavesInProgressByPinId.clear();
        _refreshNextPinNumber();
        _pinColor = Color((data['pinColor'] as num?)?.toInt() ?? 0xFF1976D2);
        _pinOpacity =
            ((data['pinOpacity'] as num?)?.toDouble() ?? 1).clamp(0.1, 1);
        _pinSizeScale =
            ((data['pinSizeScale'] as num?)?.toDouble() ?? 1).clamp(1 / 3, 1);
        _penColor = Color((data['penColor'] as num?)?.toInt() ?? 0xFFE53935);
        _boardBusinessName =
            data['boardBusinessName']?.toString() ?? _projectName;
        _boardFacilityName = data['boardFacilityName']?.toString() ?? '';
        _selectedTool = widget.simplifiedMobile ? FieldTool.pin : null;
        _penWidth = (data['penWidth'] as num?)?.toDouble() ?? 3;
        _penOpacity =
            ((data['penOpacity'] as num?)?.toDouble() ?? 1).clamp(0.1, 1);
        _penBrush = DrawingBrush.fromName(data['penBrush']?.toString());
        _shapeKind = DrawingKind.fromName(data['shapeKind']?.toString());
        if (_shapeKind != DrawingKind.line &&
            _shapeKind != DrawingKind.polyline &&
            _shapeKind != DrawingKind.rectangle) {
          _shapeKind = DrawingKind.line;
        }
        _eraserWidth =
            ((data['eraserWidth'] as num?)?.toDouble() ?? 28).clamp(6, 80);
        _textFontSize =
            ((data['textFontSize'] as num?)?.toDouble() ?? 22).clamp(12, 64);
        _textBoxWidthRatio =
            ((data['textBoxWidthRatio'] as num?)?.toDouble() ?? 0.45)
                .clamp(0.12, 0.8);
        _currentPage = activeDocument.currentPage.clamp(1, _pageCount);
        final String? pendingId = data['pendingDirectionPinId']?.toString();
        _pendingDirectionPinId =
            restoredPins.any((PinData pin) => pin.id == pendingId)
                ? pendingId
                : null;
        final String? captureAfterId =
            data['captureAfterDirectionPinId']?.toString();
        _captureAfterDirectionPinId =
            restoredPins.any((PinData pin) => pin.id == captureAfterId)
                ? captureAfterId
                : null;
        if (_pendingDirectionPinId != null) {
          _selectedTool = FieldTool.pin;
        }
      });
      await _renderPage(_currentPage);
      if (pencilRecoveryError != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '自動保存した手書きの復元に失敗しました。'
              'PDF本体は開いています。\n$pencilRecoveryError',
            ),
          ),
        );
      }
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _metaDirty = true;
          _pdfDirty = NativeProjectService.isAvailable;
          if (widget.exportOnOpen) {
            unawaited(_exportProject());
          } else {
            _enqueueSaveInBackground();
          }
        });
      }
    } catch (error) {
      if (mounted) setState(() => _errorMessage = '案件を開けませんでした。\n$error');
    } finally {
      _isRestoring = false;
    }
  }

  double get _eraserAspectRatio {
    return math.max(_activeEraserAspectRatio ?? _pageAspectRatio, 0.0001);
  }

  double get _eraserRadiusInPageSpace {
    final double normalized = (_eraserWidth / 1120).clamp(0.006, 0.08);
    return normalized * math.min(_eraserAspectRatio, 1);
  }

  Offset _toEraserPageSpace(Offset position) {
    return Offset(position.dx * _eraserAspectRatio, position.dy);
  }

  void _eraseAt(Offset position) {
    final int? pageNumber = _activeEraserPage;
    if (pageNumber == null) return;

    final Offset? previousPosition = _lastEraserPosition;
    if (previousPosition != null &&
        (_toEraserPageSpace(position) - _toEraserPageSpace(previousPosition))
                .distance <
            _eraserRadiusInPageSpace / 5) {
      return;
    }
    final Offset pathStart = previousPosition ?? position;
    _lastEraserPosition = position;

    final List<DrawingStroke>? strokes = _strokesByPage[pageNumber];
    if (strokes == null || strokes.isEmpty) return;

    final Map<String, String>? sourceIds = _activeEraserSourceIds;
    final Set<String>? touchedSourceIds = _activeEraserTouchedSourceIds;
    if (sourceIds == null || touchedSourceIds == null) return;

    bool changed = false;
    final List<DrawingStroke> updatedStrokes = <DrawingStroke>[];
    for (final DrawingStroke stroke in strokes) {
      final String sourceId = sourceIds[stroke.id] ?? stroke.id;
      final List<DrawingStroke>? fragments = _splitStrokeOutsideEraser(
        stroke,
        pathStart,
        position,
        sourceId,
      );
      if (fragments == null) {
        updatedStrokes.add(stroke);
        continue;
      }

      changed = true;
      sourceIds.remove(stroke.id);
      touchedSourceIds.add(sourceId);
      for (final DrawingStroke fragment in fragments) {
        sourceIds[fragment.id] = sourceId;
        updatedStrokes.add(fragment);
      }
    }
    if (!changed) return;

    setState(() {
      strokes
        ..clear()
        ..addAll(updatedStrokes);
      _redoDrawingEditsByPage[pageNumber]?.clear();
    });
  }

  List<DrawingStroke>? _splitStrokeOutsideEraser(
    DrawingStroke stroke,
    Offset pathStart,
    Offset pathEnd,
    String sourceId,
  ) {
    if (stroke.points.isEmpty) return null;
    if (!_eraserBoundsOverlapStroke(stroke, pathStart, pathEnd)) return null;
    if (stroke.kind == DrawingKind.text ||
        stroke.kind == DrawingKind.rectangle ||
        stroke.kind == DrawingKind.line) {
      return const <DrawingStroke>[];
    }
    final List<DrawingPoint> sampledPoints =
        _activeEraserSamplesCache?.putIfAbsent(
              stroke.id,
              () => _densifyDrawingPoints(stroke.points),
            ) ??
            _densifyDrawingPoints(stroke.points);
    final double radiusSquared =
        _eraserRadiusInPageSpace * _eraserRadiusInPageSpace;
    bool erasedAnyPoint = false;
    final List<List<DrawingPoint>> outsideRuns = <List<DrawingPoint>>[];
    List<DrawingPoint> currentRun = <DrawingPoint>[];

    for (final DrawingPoint point in sampledPoints) {
      final bool erased = _pointToSegmentDistanceSquared(
            _toEraserPageSpace(point.position),
            _toEraserPageSpace(pathStart),
            _toEraserPageSpace(pathEnd),
          ) <=
          radiusSquared;
      if (erased) {
        erasedAnyPoint = true;
        if (currentRun.isNotEmpty) {
          outsideRuns.add(currentRun);
          currentRun = <DrawingPoint>[];
        }
      } else {
        currentRun.add(point);
      }
    }
    if (!erasedAnyPoint) return null;
    if (currentRun.isNotEmpty) {
      outsideRuns.add(currentRun);
    }

    final List<DrawingStroke> fragments = outsideRuns
        .map(
          (List<DrawingPoint> points) => DrawingStroke(
            id: '$sourceId-erase-${_activeEraserEditId ?? 'edit'}'
                '-${_eraserFragmentSequence++}',
            documentId: stroke.documentId,
            pageNumber: stroke.pageNumber,
            points: points,
            width: stroke.width,
            color: stroke.color,
            opacity: stroke.opacity,
            kind: stroke.kind,
            brush: stroke.brush,
            text: stroke.text,
            fontSize: stroke.fontSize,
            textBoxWidthRatio: stroke.textBoxWidthRatio,
            rotationDegrees: stroke.rotationDegrees,
          ),
        )
        .toList(growable: false);
    _activeEraserSamplesCache?.remove(stroke.id);
    _activeEraserBoundsCache?.remove(stroke.id);
    for (final DrawingStroke fragment in fragments) {
      _activeEraserSamplesCache?[fragment.id] = fragment.points;
      _activeEraserBoundsCache?[fragment.id] = _drawingStrokeBounds(fragment);
    }
    return fragments;
  }

  Rect _drawingStrokeBounds(DrawingStroke stroke) {
    double strokeMinX = stroke.points.first.position.dx;
    double strokeMaxX = strokeMinX;
    double strokeMinY = stroke.points.first.position.dy;
    double strokeMaxY = strokeMinY;
    for (int index = 1; index < stroke.points.length; index++) {
      final Offset position = stroke.points[index].position;
      strokeMinX = math.min(strokeMinX, position.dx);
      strokeMaxX = math.max(strokeMaxX, position.dx);
      strokeMinY = math.min(strokeMinY, position.dy);
      strokeMaxY = math.max(strokeMaxY, position.dy);
    }
    return Rect.fromLTRB(strokeMinX, strokeMinY, strokeMaxX, strokeMaxY);
  }

  bool _eraserBoundsOverlapStroke(
    DrawingStroke stroke,
    Offset pathStart,
    Offset pathEnd,
  ) {
    final Rect strokeBounds = _activeEraserBoundsCache?.putIfAbsent(
          stroke.id,
          () => _drawingStrokeBounds(stroke),
        ) ??
        _drawingStrokeBounds(stroke);
    final double radiusY = _eraserRadiusInPageSpace;
    final double radiusX = radiusY / _eraserAspectRatio;
    final Rect eraserBounds = Rect.fromLTRB(
      math.min(pathStart.dx, pathEnd.dx) - radiusX,
      math.min(pathStart.dy, pathEnd.dy) - radiusY,
      math.max(pathStart.dx, pathEnd.dx) + radiusX,
      math.max(pathStart.dy, pathEnd.dy) + radiusY,
    );
    return strokeBounds.right >= eraserBounds.left &&
        strokeBounds.left <= eraserBounds.right &&
        strokeBounds.bottom >= eraserBounds.top &&
        strokeBounds.top <= eraserBounds.bottom;
  }

  List<DrawingPoint> _densifyDrawingPoints(List<DrawingPoint> points) {
    if (points.length < 2) {
      return List<DrawingPoint>.of(points);
    }

    final List<DrawingPoint> sampled = <DrawingPoint>[points.first];
    for (int index = 1; index < points.length; index++) {
      final DrawingPoint start = points[index - 1];
      final DrawingPoint end = points[index];
      final double distance = (_toEraserPageSpace(end.position) -
              _toEraserPageSpace(start.position))
          .distance;
      final int steps = math.max(
        1,
        (distance / (_eraserRadiusInPageSpace / 3)).ceil(),
      );
      for (int step = 1; step <= steps; step++) {
        final double t = step / steps;
        sampled.add(
          DrawingPoint(
            position: Offset.lerp(start.position, end.position, t)!,
            pressure: start.pressure + (end.pressure - start.pressure) * t,
          ),
        );
      }
    }
    return sampled;
  }

  double _pointToSegmentDistanceSquared(
    Offset point,
    Offset segmentStart,
    Offset segmentEnd,
  ) {
    final Offset segment = segmentEnd - segmentStart;
    final double segmentLengthSquared =
        segment.dx * segment.dx + segment.dy * segment.dy;
    if (segmentLengthSquared <= 1e-12) {
      return (point - segmentStart).distanceSquared;
    }

    final Offset fromStart = point - segmentStart;
    final double projection =
        (fromStart.dx * segment.dx + fromStart.dy * segment.dy) /
            segmentLengthSquared;
    final double clampedProjection = projection.clamp(0.0, 1.0);
    final Offset closestPoint = segmentStart + segment * clampedProjection;
    return (point - closestPoint).distanceSquared;
  }

  bool _sameDrawingPoints(
    List<DrawingPoint> first,
    List<DrawingPoint> second,
  ) {
    if (first.length != second.length) return false;
    for (int index = 0; index < first.length; index++) {
      if (first[index].position != second[index].position ||
          first[index].pressure != second[index].pressure) {
        return false;
      }
    }
    return true;
  }

  bool _sameDrawingStroke(DrawingStroke first, DrawingStroke second) {
    return _sameDrawingPoints(first.points, second.points) &&
        first.fontSize == second.fontSize &&
        first.textBoxWidthRatio == second.textBoxWidthRatio &&
        first.rotationDegrees == second.rotationDegrees;
  }

  Size get _annotationEditSize => Size(_pageAspectRatio * 1000, 1000);

  Offset _annotationPixelPosition(Offset normalized) => Offset(
        normalized.dx * _annotationEditSize.width,
        normalized.dy * _annotationEditSize.height,
      );

  Offset _annotationNormalizedPosition(Offset pixels) => Offset(
        (pixels.dx / _annotationEditSize.width).clamp(0.0, 1.0),
        (pixels.dy / _annotationEditSize.height).clamp(0.0, 1.0),
      );

  bool _startAnnotationTransform(Offset position) {
    if (_selectedTool != FieldTool.select && _selectedTool != FieldTool.text) {
      return false;
    }
    final DrawingStroke? selected = _selectedAnnotation;
    if (selected == null || selected.points.isEmpty) return false;
    final Size size = _annotationEditSize;
    final Offset pointer = _annotationPixelPosition(position);
    const double hitRadius = 24;
    _AnnotationTransformKind? kind;
    int? pointIndex;
    Offset? fixedPoint;

    if (selected.kind == DrawingKind.text) {
      final Rect bounds = drawingStrokeBounds(selected, size);
      final List<Offset> corners = <Offset>[
        bounds.topLeft,
        bounds.topRight,
        bounds.bottomRight,
        bounds.bottomLeft,
      ];
      const List<_AnnotationTransformKind> kinds = <_AnnotationTransformKind>[
        _AnnotationTransformKind.textTopLeft,
        _AnnotationTransformKind.textTopRight,
        _AnnotationTransformKind.textBottomRight,
        _AnnotationTransformKind.textBottomLeft,
      ];
      for (int index = 0; index < corners.length; index++) {
        if ((pointer - corners[index]).distance <= hitRadius) {
          kind = kinds[index];
          fixedPoint = corners[(index + 2) % 4];
          break;
        }
      }
    } else if (selected.kind == DrawingKind.rectangle &&
        selected.points.length >= 2) {
      final List<Offset> corners = drawingRectangleCorners(selected, size);
      final Offset rotationHandle =
          drawingRectangleRotationHandle(selected, size);
      if ((pointer - rotationHandle).distance <= hitRadius + 4) {
        kind = _AnnotationTransformKind.rectangleRotation;
        final Offset center = Offset.lerp(corners[0], corners[2], 0.5)!;
        _annotationTransformStartAngle =
            math.atan2(pointer.dy - center.dy, pointer.dx - center.dx) -
                selected.rotationDegrees * math.pi / 180;
      } else {
        const List<_AnnotationTransformKind> kinds = <_AnnotationTransformKind>[
          _AnnotationTransformKind.rectangleTopLeft,
          _AnnotationTransformKind.rectangleTopRight,
          _AnnotationTransformKind.rectangleBottomRight,
          _AnnotationTransformKind.rectangleBottomLeft,
        ];
        for (int index = 0; index < corners.length; index++) {
          if ((pointer - corners[index]).distance <= hitRadius) {
            kind = kinds[index];
            fixedPoint = corners[(index + 2) % 4];
            break;
          }
        }
      }
    } else if (selected.kind == DrawingKind.line ||
        selected.kind == DrawingKind.polyline) {
      for (int index = 0; index < selected.points.length; index++) {
        final Offset handle =
            _annotationPixelPosition(selected.points[index].position);
        if ((pointer - handle).distance <= hitRadius) {
          kind = _AnnotationTransformKind.point;
          pointIndex = index;
          break;
        }
      }
    }

    if (kind == null) return false;
    _transformingAnnotationOriginal = selected;
    _annotationTransformKind = kind;
    _annotationTransformPointIndex = pointIndex;
    _annotationTransformFixedPoint = fixedPoint;
    return true;
  }

  void _updateAnnotationTransform(Offset position) {
    final DrawingStroke? original = _transformingAnnotationOriginal;
    final _AnnotationTransformKind? kind = _annotationTransformKind;
    if (original == null || kind == null) return;
    final List<DrawingStroke>? strokes = _strokesByPage[original.pageNumber];
    final int index = strokes?.indexWhere(
          (DrawingStroke stroke) => stroke.id == original.id,
        ) ??
        -1;
    if (strokes == null || index < 0) return;
    final Size size = _annotationEditSize;
    final Offset pointer = _annotationPixelPosition(position);
    DrawingStroke updated = strokes[index];

    if (kind == _AnnotationTransformKind.point) {
      final int pointIndex = _annotationTransformPointIndex ?? -1;
      if (pointIndex < 0 || pointIndex >= original.points.length) return;
      final List<DrawingPoint> points = List<DrawingPoint>.of(original.points);
      points[pointIndex] = DrawingPoint(
        position: position,
        pressure: points[pointIndex].pressure,
      );
      updated = original.copyWith(points: points);
    } else if (kind == _AnnotationTransformKind.rectangleRotation) {
      final List<Offset> corners = drawingRectangleCorners(original, size);
      final Offset center = Offset.lerp(corners[0], corners[2], 0.5)!;
      final double pointerAngle =
          math.atan2(pointer.dy - center.dy, pointer.dx - center.dx);
      final double startAngle = _annotationTransformStartAngle ?? 0;
      updated = original.copyWith(
        rotationDegrees: ((pointerAngle - startAngle) * 180 / math.pi) % 360,
      );
    } else if (kind.name.startsWith('rectangle')) {
      final Offset? fixed = _annotationTransformFixedPoint;
      if (fixed == null) return;
      final double radians = original.rotationDegrees * math.pi / 180;
      final Offset worldDelta = pointer - fixed;
      final double cosine = math.cos(-radians);
      final double sine = math.sin(-radians);
      final Offset localDelta = Offset(
        worldDelta.dx * cosine - worldDelta.dy * sine,
        worldDelta.dx * sine + worldDelta.dy * cosine,
      );
      final double width = math.max(localDelta.dx.abs(), 12);
      final double height = math.max(localDelta.dy.abs(), 12);
      final Offset center = Offset.lerp(fixed, pointer, 0.5)!;
      updated = original.copyWith(
        points: <DrawingPoint>[
          DrawingPoint(
            position: _annotationNormalizedPosition(
              center - Offset(width / 2, height / 2),
            ),
            pressure: original.points.first.pressure,
          ),
          DrawingPoint(
            position: _annotationNormalizedPosition(
              center + Offset(width / 2, height / 2),
            ),
            pressure: original.points.last.pressure,
          ),
        ],
      );
    } else {
      final Offset? fixed = _annotationTransformFixedPoint;
      if (fixed == null) return;
      final Rect originalBounds = drawingStrokeBounds(original, size);
      final Offset originalDragged = switch (kind) {
        _AnnotationTransformKind.textTopLeft => originalBounds.topLeft,
        _AnnotationTransformKind.textTopRight => originalBounds.topRight,
        _AnnotationTransformKind.textBottomRight => originalBounds.bottomRight,
        _ => originalBounds.bottomLeft,
      };
      final double originalDistance = (originalDragged - fixed).distance;
      if (originalDistance <= 0) return;
      final double scale =
          ((pointer - fixed).distance / originalDistance).clamp(0.35, 4.0);
      updated = original.copyWith(
        fontSize: (original.fontSize * scale).clamp(8.0, 128.0),
        textBoxWidthRatio:
            (original.textBoxWidthRatio * scale).clamp(0.12, 0.8),
      );
      final Rect candidateBounds = drawingStrokeBounds(updated, size);
      final Offset targetTopLeft = switch (kind) {
        _AnnotationTransformKind.textTopLeft =>
          fixed - Offset(candidateBounds.width, candidateBounds.height),
        _AnnotationTransformKind.textTopRight =>
          Offset(fixed.dx, fixed.dy - candidateBounds.height),
        _AnnotationTransformKind.textBottomRight => fixed,
        _ => Offset(fixed.dx - candidateBounds.width, fixed.dy),
      };
      final Offset anchorPixels =
          _annotationPixelPosition(updated.points.first.position) +
              (targetTopLeft - candidateBounds.topLeft);
      updated = updated.copyWith(
        points: <DrawingPoint>[
          DrawingPoint(
            position: _annotationNormalizedPosition(anchorPixels),
            pressure: original.points.first.pressure,
          ),
        ],
      );
    }
    setState(() => strokes[index] = updated);
  }

  void _finishAnnotationTransform(Offset position) {
    _updateAnnotationTransform(position);
    final DrawingStroke? original = _transformingAnnotationOriginal;
    _transformingAnnotationOriginal = null;
    _annotationTransformKind = null;
    _annotationTransformPointIndex = null;
    _annotationTransformFixedPoint = null;
    _annotationTransformStartAngle = null;
    if (original == null) return;
    final List<DrawingStroke>? strokes = _strokesByPage[original.pageNumber];
    final int index = strokes?.indexWhere(
          (DrawingStroke stroke) => stroke.id == original.id,
        ) ??
        -1;
    if (strokes == null || index < 0) return;
    final DrawingStroke current = strokes[index];
    if (_sameDrawingStroke(original, current)) return;
    setState(() {
      _undoDrawingEditsByPage
          .putIfAbsent(original.pageNumber, () => <_DrawingEdit>[])
          .add(
            _DrawingEdit(
              removedStrokes: <_IndexedDrawingStroke>[
                _IndexedDrawingStroke(stroke: original, index: index),
              ],
              addedStrokes: <_IndexedDrawingStroke>[
                _IndexedDrawingStroke(stroke: current, index: index),
              ],
            ),
          );
      _redoDrawingEditsByPage[original.pageNumber]?.clear();
    });
    _scheduleSave(pins: false, drawings: true, meta: true);
  }

  void _cancelAnnotationTransform() {
    final DrawingStroke? original = _transformingAnnotationOriginal;
    _transformingAnnotationOriginal = null;
    _annotationTransformKind = null;
    _annotationTransformPointIndex = null;
    _annotationTransformFixedPoint = null;
    _annotationTransformStartAngle = null;
    if (original == null) return;
    final List<DrawingStroke>? strokes = _strokesByPage[original.pageNumber];
    final int index = strokes?.indexWhere(
          (DrawingStroke stroke) => stroke.id == original.id,
        ) ??
        -1;
    if (strokes != null && index >= 0) {
      setState(() => strokes[index] = original);
    }
  }

  DrawingStroke? _annotationAt(Offset position) {
    final List<DrawingStroke> strokes =
        _strokesByPage[_currentPage] ?? const <DrawingStroke>[];
    for (final DrawingStroke stroke in strokes.reversed) {
      if (stroke.points.isEmpty) continue;
      if (stroke.kind == DrawingKind.text ||
          stroke.kind == DrawingKind.rectangle) {
        final Size hitTestSize = Size(_pageAspectRatio * 1000, 1000);
        final Rect bounds = drawingStrokeBounds(
          stroke,
          hitTestSize,
        ).inflate(12);
        if (bounds.contains(Offset(
          position.dx * hitTestSize.width,
          position.dy * hitTestSize.height,
        ))) {
          return stroke;
        }
        continue;
      }
      if (stroke.points.length == 1 &&
          (stroke.points.first.position - position).distance <= 0.025) {
        return stroke;
      }
      for (int index = 1; index < stroke.points.length; index++) {
        if (_pointToSegmentDistanceSquared(
              position,
              stroke.points[index - 1].position,
              stroke.points[index].position,
            ) <=
            0.000625) {
          return stroke;
        }
      }
    }
    return null;
  }

  Future<void> _handleCanvasTap(Offset position) async {
    if (_selectedTool == FieldTool.select) {
      final DrawingStroke? selected = _annotationAt(position);
      setState(() {
        _selectedAnnotationId = selected?.id;
        _selectedAnnotationIds =
            selected == null ? <String>{} : <String>{selected.id};
      });
      return;
    }
    if (_selectedTool == FieldTool.shape &&
        _shapeKind == DrawingKind.polyline) {
      _addPolylinePoint(position);
      return;
    }
    if (_selectedTool != FieldTool.text) return;
    final DrawingStroke? hit = _annotationAt(position);
    if (hit?.kind == DrawingKind.text) {
      setState(() => _selectedAnnotationId = hit!.id);
      return;
    }

    final List<DrawingStroke> pageStrokes =
        _strokesByPage.putIfAbsent(_currentPage, () => <DrawingStroke>[]);
    final int draftIndex = pageStrokes.indexWhere(
      (DrawingStroke stroke) =>
          stroke.kind == DrawingKind.text && stroke.text.trim().isEmpty,
    );
    if (draftIndex >= 0) {
      final DrawingStroke draft = pageStrokes[draftIndex];
      setState(() {
        pageStrokes[draftIndex] = draft.copyWith(
          points: <DrawingPoint>[DrawingPoint(position: position)],
        );
        _selectedAnnotationId = draft.id;
      });
      return;
    }

    final DrawingStroke annotation = DrawingStroke(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      documentId: _activeDocumentId,
      pageNumber: _currentPage,
      points: <DrawingPoint>[DrawingPoint(position: position)],
      width: _penWidth,
      color: _penColor,
      opacity: _penOpacity,
      kind: DrawingKind.text,
      fontSize: _textFontSize,
      textBoxWidthRatio: _textBoxWidthRatio,
    );
    setState(() {
      final int index = pageStrokes.length;
      pageStrokes.add(annotation);
      _selectedAnnotationId = annotation.id;
      _undoDrawingEditsByPage
          .putIfAbsent(_currentPage, () => <_DrawingEdit>[])
          .add(
            _DrawingEdit(
              removedStrokes: const <_IndexedDrawingStroke>[],
              addedStrokes: <_IndexedDrawingStroke>[
                _IndexedDrawingStroke(stroke: annotation, index: index),
              ],
            ),
          );
      _redoDrawingEditsByPage[_currentPage]?.clear();
    });
  }

  void _addPolylinePoint(Offset position) {
    final DrawingStroke? active = _activeStroke;
    if (active != null &&
        active.kind == DrawingKind.polyline &&
        active.pageNumber == _currentPage) {
      setState(() => active.points.add(DrawingPoint(position: position)));
      return;
    }
    final DrawingStroke stroke = DrawingStroke(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      documentId: _activeDocumentId,
      pageNumber: _currentPage,
      width: _penWidth,
      color: _penColor,
      opacity: _penOpacity,
      kind: DrawingKind.polyline,
      brush: DrawingBrush.ballpoint,
      points: <DrawingPoint>[DrawingPoint(position: position)],
    );
    setState(() {
      final List<DrawingStroke> pageStrokes =
          _strokesByPage.putIfAbsent(_currentPage, () => <DrawingStroke>[]);
      _activeStroke = stroke;
      _activeStrokeIndex = pageStrokes.length;
      pageStrokes.add(stroke);
      _redoDrawingEditsByPage[_currentPage]?.clear();
    });
  }

  void _removeLastPolylinePoint() {
    final DrawingStroke? active = _activeStroke;
    if (active == null || active.kind != DrawingKind.polyline) return;
    if (active.points.length <= 1) {
      _cancelPolyline();
      return;
    }
    setState(() => active.points.removeLast());
  }

  void _cancelPolyline() {
    final DrawingStroke? active = _activeStroke;
    if (active == null || active.kind != DrawingKind.polyline) return;
    setState(() {
      _strokesByPage[active.pageNumber]
          ?.removeWhere((DrawingStroke stroke) => stroke.id == active.id);
      _activeStroke = null;
      _activeStrokeIndex = null;
    });
  }

  Future<void> _handleCanvasDoubleTap(Offset position) async {
    final DrawingStroke? hit = _annotationAt(position);
    if (hit?.kind != DrawingKind.text) return;
    setState(() {
      _selectedAnnotationId = hit!.id;
      _selectedAnnotationIds = <String>{hit.id};
    });
    await _editSelectedText();
  }

  Future<void> _editSelectedText() async {
    final DrawingStroke? selected = _selectedAnnotation;
    if (selected == null || selected.kind != DrawingKind.text) return;
    final TextEditingController controller =
        TextEditingController(text: selected.text);
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('テキストを入力'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 7,
          stylusHandwritingEnabled: true,
          decoration: const InputDecoration(
            hintText: 'キーボードまたはApple Pencilで入力',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('配置'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || !mounted) return;
    if (text.isEmpty) {
      _deleteSelectedAnnotation();
      return;
    }
    if (text == selected.text) return;
    _changeSelectedAnnotation(text: text);
  }

  bool _startTextAnnotationMove(Offset position) {
    if (_selectedTool != FieldTool.text && _selectedTool != FieldTool.select) {
      return false;
    }
    final DrawingStroke? hit = _annotationAt(position);
    if (hit == null || hit.points.isEmpty) {
      return false;
    }
    _movingTextOriginal = hit;
    _movingTextGrabOffset = hit.points.first.position - position;
    setState(() {
      _selectedAnnotationId = hit.id;
      _selectedAnnotationIds = <String>{hit.id};
    });
    return true;
  }

  void _updateTextAnnotationMove(Offset position) {
    final DrawingStroke? original = _movingTextOriginal;
    final Offset? grabOffset = _movingTextGrabOffset;
    if (original == null || grabOffset == null) return;
    final List<DrawingStroke>? strokes = _strokesByPage[original.pageNumber];
    final int index = strokes?.indexWhere(
          (DrawingStroke stroke) => stroke.id == original.id,
        ) ??
        -1;
    if (strokes == null || index < 0) return;
    final Offset next = position + grabOffset;
    final Offset delta = next - original.points.first.position;
    final double minX = original.points
        .map((DrawingPoint point) => point.position.dx)
        .reduce(math.min);
    final double maxX = original.points
        .map((DrawingPoint point) => point.position.dx)
        .reduce(math.max);
    final double minY = original.points
        .map((DrawingPoint point) => point.position.dy)
        .reduce(math.min);
    final double maxY = original.points
        .map((DrawingPoint point) => point.position.dy)
        .reduce(math.max);
    final Offset clampedDelta = Offset(
      delta.dx.clamp(-minX, 1 - maxX),
      delta.dy.clamp(-minY, 1 - maxY),
    );
    setState(() {
      strokes[index] = strokes[index].copyWith(
        points: original.points
            .map(
              (DrawingPoint point) => DrawingPoint(
                position: point.position + clampedDelta,
                pressure: point.pressure,
              ),
            )
            .toList(growable: false),
      );
    });
  }

  void _finishTextAnnotationMove(Offset position) {
    _updateTextAnnotationMove(position);
    final DrawingStroke? original = _movingTextOriginal;
    _movingTextOriginal = null;
    _movingTextGrabOffset = null;
    if (original == null) return;
    final List<DrawingStroke>? strokes = _strokesByPage[original.pageNumber];
    final int index = strokes?.indexWhere(
          (DrawingStroke stroke) => stroke.id == original.id,
        ) ??
        -1;
    if (strokes == null || index < 0) return;
    final DrawingStroke current = strokes[index];
    if (_sameDrawingPoints(current.points, original.points)) return;
    setState(() {
      _undoDrawingEditsByPage
          .putIfAbsent(original.pageNumber, () => <_DrawingEdit>[])
          .add(
            _DrawingEdit(
              removedStrokes: <_IndexedDrawingStroke>[
                _IndexedDrawingStroke(stroke: original, index: index),
              ],
              addedStrokes: <_IndexedDrawingStroke>[
                _IndexedDrawingStroke(stroke: current, index: index),
              ],
            ),
          );
      _redoDrawingEditsByPage[original.pageNumber]?.clear();
    });
    _scheduleSave(pins: false, drawings: true, meta: true);
  }

  void _cancelTextAnnotationMove() {
    final DrawingStroke? original = _movingTextOriginal;
    _movingTextOriginal = null;
    _movingTextGrabOffset = null;
    if (original == null) return;
    final List<DrawingStroke>? strokes = _strokesByPage[original.pageNumber];
    final int index = strokes?.indexWhere(
          (DrawingStroke stroke) => stroke.id == original.id,
        ) ??
        -1;
    if (strokes != null && index >= 0) {
      setState(() => strokes[index] = original);
    }
  }

  DrawingStroke? get _selectedAnnotation {
    final String? id = _selectedAnnotationId;
    if (id == null) return null;
    for (final DrawingStroke stroke
        in _strokesByPage[_currentPage] ?? const <DrawingStroke>[]) {
      if (stroke.id == id) return stroke;
    }
    return null;
  }

  Rect _rectFromNormalizedPoints(Offset first, Offset second) => Rect.fromLTRB(
        math.min(first.dx, second.dx),
        math.min(first.dy, second.dy),
        math.max(first.dx, second.dx),
        math.max(first.dy, second.dy),
      );

  void _startSelectionDrag(Offset position) {
    if (_selectedTool != FieldTool.select) return;
    setState(() {
      _selectionDragStart = position;
      _selectionRect = Rect.fromPoints(position, position);
      _selectedAnnotationId = null;
      _selectedAnnotationIds = <String>{};
    });
  }

  void _updateSelectionDrag(Offset position) {
    final Offset? start = _selectionDragStart;
    if (start == null) return;
    setState(() => _selectionRect = _rectFromNormalizedPoints(start, position));
  }

  void _finishSelectionDrag(Offset position) {
    final Offset? start = _selectionDragStart;
    if (start == null) return;
    final Rect normalized = _rectFromNormalizedPoints(start, position);
    final Size pageSize = Size(_pageAspectRatio * 1000, 1000);
    final Rect pixelRect = Rect.fromLTRB(
      normalized.left * pageSize.width,
      normalized.top * pageSize.height,
      normalized.right * pageSize.width,
      normalized.bottom * pageSize.height,
    );
    final Set<String> selected = pixelRect.width < 3 || pixelRect.height < 3
        ? <String>{}
        : (_strokesByPage[_currentPage] ?? const <DrawingStroke>[])
            .where(
              (DrawingStroke stroke) =>
                  stroke.points.isNotEmpty &&
                  drawingStrokeBounds(stroke, pageSize).overlaps(pixelRect),
            )
            .map((DrawingStroke stroke) => stroke.id)
            .toSet();
    setState(() {
      _selectionDragStart = null;
      _selectionRect = null;
      _selectedAnnotationIds = selected;
      _selectedAnnotationId = selected.length == 1 ? selected.first : null;
    });
  }

  void _cancelSelectionDrag() {
    if (_selectionDragStart == null && _selectionRect == null) return;
    setState(() {
      _selectionDragStart = null;
      _selectionRect = null;
    });
  }

  void _changeSelectedAnnotation({
    Color? color,
    double? width,
    double? opacity,
    double? fontSize,
    String? text,
    double? textBoxWidthRatio,
  }) {
    final DrawingStroke? selected = _selectedAnnotation;
    if (selected == null) return;
    final List<DrawingStroke>? strokes = _strokesByPage[_currentPage];
    final int index = strokes?.indexWhere(
          (DrawingStroke stroke) => stroke.id == selected.id,
        ) ??
        -1;
    if (strokes == null || index < 0) return;
    final DrawingStroke updated = selected.copyWith(
      color: color,
      width: width,
      opacity: opacity,
      fontSize: fontSize,
      text: text,
      textBoxWidthRatio: textBoxWidthRatio,
    );
    setState(() {
      strokes[index] = updated;
      _undoDrawingEditsByPage
          .putIfAbsent(_currentPage, () => <_DrawingEdit>[])
          .add(
            _DrawingEdit(
              removedStrokes: <_IndexedDrawingStroke>[
                _IndexedDrawingStroke(stroke: selected, index: index),
              ],
              addedStrokes: <_IndexedDrawingStroke>[
                _IndexedDrawingStroke(stroke: updated, index: index),
              ],
            ),
          );
      _redoDrawingEditsByPage[_currentPage]?.clear();
    });
    _scheduleSave(pins: false, drawings: true, meta: true);
  }

  void _deleteSelectedAnnotation() {
    final List<DrawingStroke>? strokes = _strokesByPage[_currentPage];
    final Set<String> ids = _selectedAnnotationIds.isNotEmpty
        ? _selectedAnnotationIds
        : <String>{if (_selectedAnnotationId != null) _selectedAnnotationId!};
    if (strokes == null || ids.isEmpty) return;
    final List<_IndexedDrawingStroke> removed = <_IndexedDrawingStroke>[
      for (int index = 0; index < strokes.length; index++)
        if (ids.contains(strokes[index].id))
          _IndexedDrawingStroke(stroke: strokes[index], index: index),
    ];
    if (removed.isEmpty) return;
    setState(() {
      strokes.removeWhere((DrawingStroke stroke) => ids.contains(stroke.id));
      _selectedAnnotationId = null;
      _selectedAnnotationIds = <String>{};
      _undoDrawingEditsByPage
          .putIfAbsent(_currentPage, () => <_DrawingEdit>[])
          .add(
            _DrawingEdit(
              removedStrokes: removed,
              addedStrokes: const <_IndexedDrawingStroke>[],
            ),
          );
      _redoDrawingEditsByPage[_currentPage]?.clear();
    });
    _scheduleSave(pins: false, drawings: true, meta: true);
  }

  Future<void> _showSelectionSettings() async {
    if (_selectedAnnotationIds.isEmpty && _selectedAnnotation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('変更する線・図形・テキストを選択してください。')),
      );
      return;
    }
    if (_selectedAnnotationIds.length > 1) {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.panel,
        builder: (BuildContext context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '${_selectedAnnotationIds.length}件を選択中',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _deleteSelectedAnnotation();
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('選択した注釈を削除'),
                ),
              ],
            ),
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter updateSheet) {
          final DrawingStroke? selected = _selectedAnnotation;
          if (selected == null) return const SizedBox.shrink();
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '選択した注釈',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 14,
                    children: _fieldPaletteColors.map((Color color) {
                      return _PaletteColorButton(
                        color: color,
                        selected: selected.color.toARGB32() == color.toARGB32(),
                        onTap: () {
                          _changeSelectedAnnotation(color: color);
                          updateSheet(() {});
                        },
                      );
                    }).toList(growable: false),
                  ),
                  const SizedBox(height: 14),
                  Text(selected.kind == DrawingKind.text
                      ? '文字サイズ ${selected.fontSize.round()}'
                      : '太さ ${selected.width.toStringAsFixed(0)}'),
                  Slider(
                    value: (selected.kind == DrawingKind.text
                            ? selected.fontSize
                            : selected.width)
                        .clamp(
                      selected.kind == DrawingKind.text ? 12 : 1,
                      selected.kind == DrawingKind.text ? 64 : 24,
                    ),
                    min: selected.kind == DrawingKind.text ? 12 : 1,
                    max: selected.kind == DrawingKind.text ? 64 : 24,
                    onChanged: (double value) {
                      if (selected.kind == DrawingKind.text) {
                        _changeSelectedAnnotation(fontSize: value);
                      } else {
                        _changeSelectedAnnotation(width: value);
                      }
                      updateSheet(() {});
                    },
                  ),
                  if (selected.kind == DrawingKind.text) ...<Widget>[
                    Text(
                      'テキスト枠の横幅 '
                      '${(selected.textBoxWidthRatio * 100).round()}%',
                    ),
                    Slider(
                      value: selected.textBoxWidthRatio.clamp(0.12, 0.8),
                      min: 0.12,
                      max: 0.8,
                      divisions: 17,
                      onChanged: (double value) {
                        _changeSelectedAnnotation(textBoxWidthRatio: value);
                        updateSheet(() {});
                      },
                    ),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _editSelectedText();
                      },
                      icon: const Icon(Icons.keyboard_rounded),
                      label: Text(
                        selected.text.isEmpty ? '文字入力を開始' : '文字を再編集',
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Text('透過率 ${(selected.opacity * 100).round()}%'),
                  Slider(
                    value: selected.opacity.clamp(0.1, 1),
                    min: 0.1,
                    max: 1,
                    divisions: 18,
                    onChanged: (double value) {
                      _changeSelectedAnnotation(opacity: value);
                      updateSheet(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _deleteSelectedAnnotation();
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('選択した注釈を削除'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showShapeSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter updateSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '図形設定',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 16),
                SegmentedButton<DrawingKind>(
                  segments: const <ButtonSegment<DrawingKind>>[
                    ButtonSegment(value: DrawingKind.line, label: Text('直線')),
                    ButtonSegment(
                        value: DrawingKind.polyline, label: Text('連続線')),
                    ButtonSegment(
                        value: DrawingKind.rectangle, label: Text('矩形')),
                  ],
                  selected: <DrawingKind>{_shapeKind},
                  onSelectionChanged: (Set<DrawingKind> values) {
                    if (values.first != _shapeKind) _endStroke();
                    setState(() => _shapeKind = values.first);
                    updateSheet(() {});
                    _scheduleSave(pins: false, drawings: false, meta: true);
                  },
                ),
                const SizedBox(height: 16),
                Text('太さ ${_penWidth.toStringAsFixed(0)}'),
                Slider(
                  value: _penWidth.clamp(1, 24),
                  min: 1,
                  max: 24,
                  onChanged: (double value) {
                    setState(() => _penWidth = value);
                    updateSheet(() {});
                    _scheduleSave(pins: false, drawings: false, meta: true);
                  },
                ),
                Text('透過率 ${(_penOpacity * 100).round()}%'),
                Slider(
                  value: _penOpacity.clamp(0.1, 1),
                  min: 0.1,
                  max: 1,
                  divisions: 18,
                  onChanged: (double value) {
                    setState(() => _penOpacity = value);
                    updateSheet(() {});
                    _scheduleSave(pins: false, drawings: false, meta: true);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTextSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter updateSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'テキスト設定',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 16),
                Text('文字サイズ ${_textFontSize.round()}'),
                Slider(
                  value: _textFontSize.clamp(12, 64),
                  min: 12,
                  max: 64,
                  onChanged: (double value) {
                    setState(() => _textFontSize = value);
                    updateSheet(() {});
                    _scheduleSave(pins: false, drawings: false, meta: true);
                  },
                ),
                Text(
                  'テキスト枠の横幅 ${(_textBoxWidthRatio * 100).round()}%',
                ),
                Slider(
                  value: _textBoxWidthRatio.clamp(0.12, 0.8),
                  min: 0.12,
                  max: 0.8,
                  divisions: 17,
                  onChanged: (double value) {
                    setState(() => _textBoxWidthRatio = value);
                    updateSheet(() {});
                    _scheduleSave(pins: false, drawings: false, meta: true);
                  },
                ),
                Text('透過率 ${(_penOpacity * 100).round()}%'),
                Slider(
                  value: _penOpacity.clamp(0.1, 1),
                  min: 0.1,
                  max: 1,
                  divisions: 18,
                  onChanged: (double value) {
                    setState(() => _penOpacity = value);
                    updateSheet(() {});
                    _scheduleSave(pins: false, drawings: false, meta: true);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showPinSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'ピンの色',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  _selectedPinId == null
                      ? '次に配置するピンの色を選択'
                      : '選択中のピンと、次に配置するピンの色を変更',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: _fieldPaletteColors.map((Color color) {
                    return _PaletteColorButton(
                      color: color,
                      selected: _pinColor.toARGB32() == color.toARGB32(),
                      onTap: () {
                        bool changedSelectedPin = false;
                        setState(() {
                          _pinColor = color;
                          final String? selectedId = _selectedPinId;
                          if (selectedId != null) {
                            final int index = _pins.indexWhere(
                              (PinData pin) => pin.id == selectedId,
                            );
                            if (index >= 0) {
                              _discardPinRedoHistory();
                              _pins[index] = _pins[index].copyWith(
                                colorValue: color.toARGB32(),
                              );
                              changedSelectedPin = true;
                            }
                          }
                        });
                        _scheduleSave(
                          pins: changedSelectedPin,
                          drawings: false,
                          meta: true,
                        );
                        setSheetState(() {});
                      },
                    );
                  }).toList(growable: false),
                ),
                const SizedBox(height: 18),
                Text('透過率 ${(_pinOpacity * 100).round()}%'),
                Slider(
                  value: _pinOpacity.clamp(0.1, 1),
                  min: 0.1,
                  max: 1,
                  divisions: 18,
                  onChanged: (double value) {
                    bool changedSelectedPin = false;
                    setState(() {
                      _pinOpacity = value;
                      final String? selectedId = _selectedPinId;
                      final int index = _pins.indexWhere(
                        (PinData pin) => pin.id == selectedId,
                      );
                      if (index >= 0) {
                        _discardPinRedoHistory();
                        _pins[index] = _pins[index].copyWith(opacity: value);
                        changedSelectedPin = true;
                      }
                    });
                    setSheetState(() {});
                    _scheduleSave(
                      pins: changedSelectedPin,
                      drawings: false,
                      meta: true,
                    );
                  },
                ),
                Text('ピンサイズ ${(_pinSizeScale * 100).round()}%'),
                Slider(
                  value: _pinSizeScale.clamp(1 / 3, 1),
                  min: 1 / 3,
                  max: 1,
                  divisions: 20,
                  onChanged: (double value) {
                    bool changedSelectedPin = false;
                    setState(() {
                      _pinSizeScale = value;
                      final String? selectedId = _selectedPinId;
                      final int index = _pins.indexWhere(
                        (PinData pin) => pin.id == selectedId,
                      );
                      if (index >= 0) {
                        _discardPinRedoHistory();
                        _pins[index] = _pins[index].copyWith(sizeScale: value);
                        changedSelectedPin = true;
                      }
                    });
                    setSheetState(() {});
                    _scheduleSave(
                      pins: changedSelectedPin,
                      drawings: false,
                      meta: true,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showPenSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'ペン設定',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<DrawingBrush>(
                    segments: const <ButtonSegment<DrawingBrush>>[
                      ButtonSegment(
                        value: DrawingBrush.ballpoint,
                        label: Text('ボールペン'),
                      ),
                      ButtonSegment(
                        value: DrawingBrush.fountain,
                        label: Text('万年筆'),
                      ),
                      ButtonSegment(
                        value: DrawingBrush.marker,
                        label: Text('マーカー'),
                      ),
                      ButtonSegment(
                        value: DrawingBrush.highlighter,
                        label: Text('蛍光'),
                      ),
                    ],
                    selected: <DrawingBrush>{_penBrush},
                    onSelectionChanged: (Set<DrawingBrush> values) {
                      setState(() {
                        _penBrush = values.first;
                        if (_penBrush == DrawingBrush.highlighter &&
                            _penOpacity > 0.55) {
                          _penOpacity = 0.35;
                        }
                      });
                      setSheetState(() {});
                      _scheduleSave(
                        pins: false,
                        drawings: false,
                        meta: true,
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: _fieldPaletteColors.map((Color color) {
                      return _PaletteColorButton(
                        color: color,
                        selected: _penColor.toARGB32() == color.toARGB32(),
                        onTap: () {
                          setState(() => _penColor = color);
                          setSheetState(() {});
                          _scheduleSave(
                            pins: false,
                            drawings: false,
                            meta: true,
                          );
                        },
                      );
                    }).toList(growable: false),
                  ),
                  const SizedBox(height: 18),
                  Text('太さ ${_penWidth.toStringAsFixed(0)}'),
                  Slider(
                    value: _penWidth,
                    min: 1,
                    max: 24,
                    divisions: 23,
                    onChanged: (double value) {
                      setState(() => _penWidth = value);
                      setSheetState(() {});
                      _scheduleSave(
                        pins: false,
                        drawings: false,
                        meta: true,
                      );
                    },
                  ),
                  Text('透過率 ${(_penOpacity * 100).round()}%'),
                  Slider(
                    value: _penOpacity.clamp(0.1, 1),
                    min: 0.1,
                    max: 1,
                    divisions: 18,
                    onChanged: (double value) {
                      setState(() => _penOpacity = value);
                      setSheetState(() {});
                      _scheduleSave(
                        pins: false,
                        drawings: false,
                        meta: true,
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showEraserSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '消しゴム設定',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 18),
                  Text('消しゴムの太さ ${_eraserWidth.round()}'),
                  Slider(
                    value: _eraserWidth,
                    min: 6,
                    max: 80,
                    divisions: 37,
                    onChanged: (double value) {
                      setState(() => _eraserWidth = value);
                      setSheetState(() {});
                      _scheduleSave(
                        pins: false,
                        drawings: false,
                        meta: true,
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<Uint8List?> _renderThumbnail(int pageNumber) async {
    final document = _pdfDocument;
    if (document == null) return null;
    pdfx.PdfPage? page;
    try {
      page = await document.getPage(pageNumber);
      final image = await page.render(
        width: 220,
        height: 220 / (page.width / page.height),
        format: pdfx.PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      return image?.bytes;
    } finally {
      await page?.close();
    }
  }

  Future<Uint8List?> _thumbnailForPage(int pageNumber) {
    return _thumbnailFutures.putIfAbsent(
      pageNumber,
      () => _renderThumbnail(pageNumber),
    );
  }

  void _showPageList() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('ページ一覧',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: _pageCount,
                  itemBuilder: (_, index) {
                    final pageNumber = index + 1;
                    final selected = pageNumber == _currentPage;
                    return InkWell(
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _goToPage(pageNumber);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: selected
                                  ? AppColors.accent
                                  : AppColors.border,
                              width: selected ? 3 : 1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(7)),
                                child: FutureBuilder<Uint8List?>(
                                  future: _thumbnailForPage(pageNumber),
                                  builder: (_, snapshot) {
                                    if (snapshot.hasData) {
                                      return Image.memory(
                                        snapshot.data!,
                                        fit: BoxFit.contain,
                                      );
                                    }
                                    if (snapshot.hasError ||
                                        snapshot.connectionState ==
                                            ConnectionState.done) {
                                      return const Center(
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                          semanticLabel: 'サムネイルを表示できません',
                                        ),
                                      );
                                    }
                                    return const Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text('$pageNumberページ',
                                  style: TextStyle(
                                      fontWeight: selected
                                          ? FontWeight.w800
                                          : FontWeight.w500)),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _returnHome() async {
    if (_isLeaving) return;
    setState(() => _isLeaving = true);
    _endStroke();
    _saveSelectedPinNote();
    final bool hadPinRedo = _redoPinEdits.isNotEmpty;
    _discardPinRedoHistory();
    if (hadPinRedo) {
      _metaDirty = true;
    }
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _saveRetryTimer?.cancel();
    _saveRetryTimer = null;

    try {
      do {
        await _enqueueSave();
      } while (_hasPendingSave);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLeaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('保存できなかったため画面を閉じませんでした。再試行してください。'),
          action: SnackBarAction(
            label: '再試行',
            onPressed: _returnHome,
          ),
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final PinData? selectedPin = _selectedPin;
    final bool mobile = widget.simplifiedMobile;
    final ProjectPdfDocument? activeDocument = _activeDocument;

    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (bool didPop, void result) {
        if (!didPop) {
          unawaited(_returnHome());
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF101722),
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'ホームへ戻る',
            onPressed: _returnHome,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          backgroundColor: AppColors.panel,
          foregroundColor: AppColors.textPrimary,
          titleSpacing: 8,
          title: mobile
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      _projectName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (activeDocument != null)
                      Text(
                        activeDocument.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                )
              : Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _projectName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (_documents.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _activeDocumentId,
                            isExpanded: true,
                            items: _documents
                                .map(
                                  (ProjectPdfDocument document) =>
                                      DropdownMenuItem<String>(
                                    value: document.id,
                                    child: Text(
                                      document.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: _isPickingFile
                                ? null
                                : (String? value) {
                                    if (value != null) {
                                      unawaited(_switchDocument(value));
                                    }
                                  },
                          ),
                        ),
                      ),
                  ],
                ),
          actions: [
            if (_pdfDocument != null)
              IconButton(
                tooltip: 'PDFを追加',
                onPressed: _isPickingFile ? null : () => _pickPdf(append: true),
                icon: const Icon(Icons.note_add_rounded),
              ),
            if (mobile && _documents.length > 1)
              PopupMenuButton<String>(
                tooltip: 'PDFを切り替え',
                icon: const Icon(Icons.picture_as_pdf_rounded),
                initialValue: _activeDocumentId,
                onSelected: (String documentId) {
                  unawaited(_switchDocument(documentId));
                },
                itemBuilder: (BuildContext context) => _documents
                    .map(
                      (ProjectPdfDocument document) => PopupMenuItem<String>(
                        value: document.id,
                        child: Text(document.name),
                      ),
                    )
                    .toList(growable: false),
              ),
            if (_pdfDocument != null && !mobile)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_saveInProgress)
                        const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (_saveErrorMessage != null)
                        const Icon(
                          Icons.cloud_off_rounded,
                          size: 17,
                          color: Color(0xFFFF7A7A),
                        )
                      else if (_hasPendingSave)
                        const Icon(Icons.cloud_upload_rounded, size: 17)
                      else
                        const Icon(Icons.cloud_done_rounded, size: 17),
                      const SizedBox(width: 5),
                      Semantics(
                        liveRegion: true,
                        label: _saveInProgress
                            ? '保存中'
                            : _saveErrorMessage != null
                                ? '保存失敗、自動再試行します'
                                : _hasPendingSave
                                    ? '未保存'
                                    : '保存済み',
                        child: Text(
                          _saveInProgress
                              ? '保存中'
                              : _saveErrorMessage != null
                                  ? '保存失敗・再試行'
                                  : _hasPendingSave
                                      ? '未保存'
                                      : '保存済み',
                          style: TextStyle(
                            fontSize: 12,
                            color: _saveErrorMessage != null
                                ? const Color(0xFFFFA0A0)
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_pdfDocument != null)
              IconButton(
                tooltip: 'ページ一覧',
                onPressed: _isRenderingPage ? null : _showPageList,
                icon: const Icon(Icons.grid_view_rounded),
              ),
            if (_pdfDocument != null && !mobile)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121B28),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '前のページ',
                        onPressed: !_isRenderingPage && _currentPage > 1
                            ? () => _goToPage(_currentPage - 1)
                            : null,
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(
                          _pageCount > 0
                              ? '$_currentPage / $_pageCount'
                              : '読込中',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '次のページ',
                        onPressed: !_isRenderingPage &&
                                _pageCount > 0 &&
                                _currentPage < _pageCount
                            ? () => _goToPage(_currentPage + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            if (!mobile) const SizedBox(width: 6),
          ],
        ),
        body: AbsorbPointer(
          absorbing: _isLeaving,
          child: SafeArea(
            child: _pdfDocument == null
                ? _buildEmptyState()
                : Stack(
                    children: [
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        top: 0,
                        left: 0,
                        bottom: 0,
                        right:
                            !mobile && selectedPin != null && !_suppressPinPanel
                                ? 320
                                : 0,
                        child: _buildDrawingArea(),
                      ),
                      if (!mobile)
                        AnimatedPositioned(
                          duration: const Duration(
                            milliseconds: 220,
                          ),
                          curve: Curves.easeOut,
                          top: 0,
                          right: selectedPin == null || _suppressPinPanel
                              ? -320
                              : 0,
                          bottom: 0,
                          width: 320,
                          child: selectedPin == null ||
                                  _suppressPinPanel ||
                                  _noteController == null
                              ? const SizedBox.shrink()
                              : PinSidePanel(
                                  pin: selectedPin,
                                  photos: _photosForPin(selectedPin.id),
                                  noteController: _noteController!,
                                  onClose: _closePinPanel,
                                  onDelete: _deleteSelectedPin,
                                  onNameChanged: _updateSelectedPinName,
                                  onAddPhotos: _addPhotosToSelectedPin,
                                  onShowAllPhotos: _showAllPhotosForSelectedPin,
                                  onPhotoTap: (PhotoData photo) =>
                                      _openPhotoEditor(selectedPin, photo),
                                  directionEditing:
                                      _pendingDirectionPinId == selectedPin.id,
                                  onChangeDirection:
                                      _toggleSelectedPinDirectionEditing,
                                  onNoteChanged: (_) {
                                    _saveSelectedPinNote();
                                  },
                                ),
                        ),
                      if (mobile &&
                          selectedPin != null &&
                          !_suppressPinPanel &&
                          _noteController != null)
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          height: MediaQuery.sizeOf(context).height * 0.52,
                          child: Material(
                            elevation: 20,
                            borderRadius: BorderRadius.circular(16),
                            clipBehavior: Clip.antiAlias,
                            child: PinSidePanel(
                              pin: selectedPin,
                              photos: _photosForPin(selectedPin.id),
                              noteController: _noteController!,
                              onClose: _closePinPanel,
                              onDelete: _deleteSelectedPin,
                              onNameChanged: _updateSelectedPinName,
                              onAddPhotos: _addPhotosToSelectedPin,
                              onShowAllPhotos: _showAllPhotosForSelectedPin,
                              onPhotoTap: (PhotoData photo) =>
                                  _openPhotoReadOnly(selectedPin, photo),
                              directionEditing:
                                  _pendingDirectionPinId == selectedPin.id,
                              onChangeDirection:
                                  _toggleSelectedPinDirectionEditing,
                              onNoteChanged: (_) {
                                _saveSelectedPinNote();
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        bottomNavigationBar: _pdfDocument == null
            ? null
            : IgnorePointer(
                ignoring: _isLeaving,
                child: _buildBottomToolbar(),
              ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: _isPickingFile ? null : _pickPdf,
              icon: _isPickingFile
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(
                      Icons.folder_open_rounded,
                    ),
              label: Text(
                _isPickingFile ? '選択中…' : 'PDFを選択',
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                constraints: const BoxConstraints(maxWidth: 600),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE53935),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDrawingArea() {
    final Uint8List? imageBytes = _pageImageBytes;
    final DrawingStroke? selectedAnnotation = _selectedAnnotation;

    return Stack(
      key: _drawingAreaKey,
      children: [
        Positioned.fill(
          child: imageBytes == null
              ? _failedRenderPage == null
                  ? const Center(child: CircularProgressIndicator())
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Icon(
                              Icons.broken_image_outlined,
                              size: 44,
                              color: AppColors.textSecondary,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '$_failedRenderPageページ目を表示できませんでした。',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _isRenderingPage
                                  ? null
                                  : _retryFailedPageRender,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('再試行'),
                            ),
                          ],
                        ),
                      ),
                    )
              : SinglePagePdfCanvas(
                  key: ValueKey<String>('${_pdfPath!}-$_currentPage'),
                  imageBytes: imageBytes,
                  pageAspectRatio: _pageAspectRatio,
                  transformationController: _transformationController,
                  pins: _currentPagePins,
                  strokes: _currentPageStrokes,
                  pinModeEnabled: _selectedTool == FieldTool.pin,
                  penModeEnabled: _selectedTool == FieldTool.pen ||
                      _selectedTool == FieldTool.eraser ||
                      (_selectedTool == FieldTool.shape &&
                          _shapeKind != DrawingKind.polyline),
                  selectionModeEnabled: _selectedTool == FieldTool.select,
                  textModeEnabled: _selectedTool == FieldTool.text,
                  polylineModeEnabled: _selectedTool == FieldTool.shape &&
                      _shapeKind == DrawingKind.polyline,
                  eraserEnabled: _selectedTool == FieldTool.eraser,
                  eraserRadiusNormalized:
                      (_eraserWidth / 1120).clamp(0.006, 0.08),
                  selectedStrokeId: _selectedAnnotationId,
                  selectedStrokeIds: _selectedAnnotationIds,
                  selectionRect: _selectionRect,
                  selectedPinId: _selectedPinId,
                  pendingDirectionPinId: _pendingDirectionPinId,
                  onAddPin: _addPin,
                  onPinTap: _selectPin,
                  onDirectionChanged: _changePinDirection,
                  onDirectionCleared: _clearPinDirection,
                  onDirectionChangeStart: _startPinDirectionChange,
                  onDirectionChangeEnd: _finishPinDirectionChange,
                  onDirectionChangeCancel: _cancelPinDirectionChange,
                  onPinMoveStart: _startPinMove,
                  onPinMoveUpdate: _updatePinPosition,
                  onPinMoveEnd: _finishPinMove,
                  onPinMoveCancel: _cancelPinMove,
                  onStrokeStart: _startStroke,
                  onStrokeUpdate: _updateStroke,
                  onStrokeEnd: _endStroke,
                  onCanvasTap: _handleCanvasTap,
                  onCanvasDoubleTap: _handleCanvasDoubleTap,
                  onAnnotationMoveStart: _startTextAnnotationMove,
                  onAnnotationMoveUpdate: _updateTextAnnotationMove,
                  onAnnotationMoveEnd: _finishTextAnnotationMove,
                  onAnnotationMoveCancel: _cancelTextAnnotationMove,
                  onAnnotationTransformStart: _startAnnotationTransform,
                  onAnnotationTransformUpdate: _updateAnnotationTransform,
                  onAnnotationTransformEnd: _finishAnnotationTransform,
                  onAnnotationTransformCancel: _cancelAnnotationTransform,
                  onSelectionDragStart: _startSelectionDrag,
                  onSelectionDragUpdate: _updateSelectionDrag,
                  onSelectionDragEnd: _finishSelectionDrag,
                  onSelectionDragCancel: _cancelSelectionDrag,
                ),
        ),
        if (imageBytes != null)
          Positioned(
            right: 16,
            bottom: 16,
            child: Material(
              color: AppColors.panel.withValues(alpha: 0.92),
              shape: const CircleBorder(),
              elevation: 4,
              child: IconButton(
                tooltip: '表示位置と拡大率をリセット',
                onPressed: () {
                  _transformationController.value = Matrix4.identity();
                },
                icon: const Icon(Icons.center_focus_strong_rounded),
              ),
            ),
          ),
        if (imageBytes != null &&
            selectedAnnotation != null &&
            (_selectedTool == FieldTool.text ||
                _selectedTool == FieldTool.select))
          Positioned(
            top: 16,
            right: 16,
            child: Material(
              color: AppColors.panel.withValues(alpha: 0.96),
              elevation: 6,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Text(
                        '長押しで移動',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (selectedAnnotation.kind == DrawingKind.text)
                      TextButton.icon(
                        onPressed: _editSelectedText,
                        icon: const Icon(Icons.keyboard_rounded, size: 19),
                        label: Text(
                          selectedAnnotation.text.isEmpty ? '文字入力' : '文字を修正',
                        ),
                      ),
                    IconButton(
                      tooltip: '色・サイズ・横幅・透過率',
                      onPressed: _showSelectionSettings,
                      icon: const Icon(Icons.tune_rounded),
                    ),
                    IconButton(
                      tooltip: 'テキストを削除',
                      onPressed: _deleteSelectedAnnotation,
                      color: const Color(0xFFFF6B6B),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (imageBytes != null &&
            _selectedTool == FieldTool.shape &&
            _shapeKind == DrawingKind.polyline &&
            _activeStroke?.kind == DrawingKind.polyline)
          Positioned(
            top: 16,
            right: 16,
            child: Material(
              color: AppColors.panel.withValues(alpha: 0.96),
              elevation: 6,
              borderRadius: BorderRadius.circular(24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Padding(
                    padding: EdgeInsets.only(left: 12, right: 4),
                    child: Text('点を順番にタップ'),
                  ),
                  IconButton(
                    tooltip: '最後の点を戻す',
                    onPressed: _removeLastPolylinePoint,
                    icon: const Icon(Icons.undo_rounded),
                  ),
                  TextButton.icon(
                    onPressed:
                        _activeStroke!.points.length >= 2 ? _endStroke : null,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('完了'),
                  ),
                  IconButton(
                    tooltip: 'キャンセル',
                    onPressed: _cancelPolyline,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ),
        if (_selectedTool == FieldTool.pin && _pendingDirectionPinId != null)
          Positioned(
            left: 16,
            top: 16,
            child: IgnorePointer(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xE61B6FA8),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white38),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.touch_app_rounded, size: 20),
                    SizedBox(width: 7),
                    Text(
                      '方向をタップ／ピンを再タップで方向なし',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_selectedTool == FieldTool.pin &&
            _currentPagePins.isNotEmpty &&
            _pendingDirectionPinId == null)
          Positioned(
            left: 16,
            top: 16,
            child: IgnorePointer(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.panel.withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_with_rounded, size: 18),
                    SizedBox(width: 6),
                    Text(
                      '既存のピンは長押しして移動',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_isRenderingPage)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x66000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        if (_errorMessage != null && _failedRenderPage == null)
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 600),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE53935),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBottomToolbar() {
    final bool pageInteractionAvailable =
        _pageImageBytes != null && !_isRenderingPage;
    if (widget.simplifiedMobile) {
      return Material(
        color: AppColors.panel,
        elevation: 12,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 72,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _ToolbarButton(
                    icon: Icons.chevron_left_rounded,
                    label: '前へ',
                    selected: null,
                    enabled: pageInteractionAvailable && _currentPage > 1,
                    onPressed: () => _goToPage(_currentPage - 1),
                  ),
                ),
                Expanded(
                  child: _ToolbarButton(
                    icon: Icons.location_on_rounded,
                    iconColor: _pinColor,
                    label: 'ピン',
                    selected: _selectedTool == FieldTool.pin,
                    enabled: pageInteractionAvailable,
                    onPressed: () => _selectTool(FieldTool.pin),
                  ),
                ),
                Expanded(
                  child: _ToolbarButton(
                    icon: Icons.undo_rounded,
                    label: '戻す',
                    selected: null,
                    enabled: pageInteractionAvailable && _canUndoCurrentTool,
                    onPressed: _undo,
                  ),
                ),
                Expanded(
                  child: _ToolbarButton(
                    icon: Icons.redo_rounded,
                    label: 'やり直す',
                    selected: null,
                    enabled: pageInteractionAvailable && _canRedoCurrentTool,
                    onPressed: _redo,
                  ),
                ),
                Expanded(
                  child: _ToolbarButton(
                    icon: Icons.chevron_right_rounded,
                    label: '次へ',
                    selected: null,
                    enabled: pageInteractionAvailable &&
                        _pageCount > 0 &&
                        _currentPage < _pageCount,
                    onPressed: () => _goToPage(_currentPage + 1),
                  ),
                ),
                Expanded(
                  child: _ToolbarButton(
                    icon: Icons.picture_as_pdf_rounded,
                    label: _isExporting ? '作成中' : 'PDF出力',
                    selected: null,
                    enabled: !_isExporting,
                    onPressed: _exportPinsOnlyMobile,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Material(
      color: AppColors.panel,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 78,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _ToolbarButton(
                        icon: Icons.select_all_rounded,
                        label: '選択',
                        selected: _selectedTool == FieldTool.select,
                        enabled: pageInteractionAvailable,
                        onPressed: () => _selectTool(FieldTool.select),
                      ),
                      _ToolbarButton(
                        icon: Icons.location_on_rounded,
                        iconColor: _pinColor,
                        label: 'ピン',
                        selected: _selectedTool == FieldTool.pin,
                        enabled: pageInteractionAvailable,
                        onPressed: () => _selectTool(FieldTool.pin),
                      ),
                      _ToolbarButton(
                        icon: Icons.edit_rounded,
                        iconColor: _penColor,
                        label: 'ペン',
                        selected: _selectedTool == FieldTool.pen,
                        enabled: pageInteractionAvailable,
                        onPressed: () => _selectTool(FieldTool.pen),
                      ),
                      _ToolbarButton(
                        icon: Icons.auto_fix_off_rounded,
                        label: '消しゴム',
                        selected: _selectedTool == FieldTool.eraser,
                        enabled: pageInteractionAvailable,
                        onPressed: () => _selectTool(FieldTool.eraser),
                      ),
                      _ToolbarButton(
                        icon: Icons.category_outlined,
                        iconColor: _penColor,
                        label: '図形',
                        selected: _selectedTool == FieldTool.shape,
                        enabled: pageInteractionAvailable,
                        onPressed: () => _selectTool(FieldTool.shape),
                      ),
                      _ToolbarButton(
                        icon: Icons.text_fields_rounded,
                        iconColor: _penColor,
                        label: 'テキスト',
                        selected: _selectedTool == FieldTool.text,
                        enabled: pageInteractionAvailable,
                        onPressed: () => _selectTool(FieldTool.text),
                      ),
                      _ToolbarButton(
                        icon: Icons.undo_rounded,
                        label: '戻る',
                        selected: null,
                        enabled:
                            pageInteractionAvailable && _canUndoCurrentTool,
                        onPressed: _undo,
                      ),
                      _ToolbarButton(
                        icon: Icons.redo_rounded,
                        label: 'やり直し',
                        selected: null,
                        enabled:
                            pageInteractionAvailable && _canRedoCurrentTool,
                        onPressed: _redo,
                      ),
                      _ToolbarButton(
                        icon: Icons.ios_share_rounded,
                        label: _isExporting ? '書出中' : '書き出し',
                        selected: null,
                        enabled: !_isExporting,
                        onPressed: _exportProject,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.iconColor,
    this.enabled = true,
  });

  final IconData icon;
  final Color? iconColor;
  final String label;
  final bool? selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color resolvedIconColor = iconColor ?? AppColors.textSecondary;
    final bool needsContrastHalo =
        iconColor != null && resolvedIconColor.computeLuminance() < 0.12;
    final bool isSelected = selected == true;

    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        width: 96,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onPressed : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.38,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 48,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF168BFF).withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFF4AA8FF)
                          : Colors.transparent,
                      width: 1.5,
                    ),
                    boxShadow: isSelected
                        ? <BoxShadow>[
                            BoxShadow(
                              color: const Color(0xFF168BFF)
                                  .withValues(alpha: 0.44),
                              blurRadius: 11,
                              spreadRadius: 1,
                            ),
                          ]
                        : const <BoxShadow>[],
                  ),
                  alignment: Alignment.center,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      if (needsContrastHalo)
                        Icon(
                          icon,
                          color: Colors.white.withValues(alpha: 0.72),
                          size: 28,
                        ),
                      Icon(
                        icon,
                        color: resolvedIconColor,
                        size: 25,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected
                        ? const Color(0xFF79C3FF)
                        : AppColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteColorButton extends StatelessWidget {
  const _PaletteColorButton({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool isDark = color.computeLuminance() < 0.08;
    final bool isYellow = color.computeLuminance() > 0.62;
    final Color passiveBorder = isDark
        ? Colors.white70
        : isYellow
            ? const Color(0xFF6B5A18)
            : Colors.white54;

    return Semantics(
      button: true,
      selected: selected,
      label: '${_fieldColorName(color)}を選択',
      value: selected ? '選択中' : '未選択',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? const Color(0xFF66B5FF) : passiveBorder,
              width: selected ? 3.5 : 2,
            ),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: const Color(0xFF168BFF).withValues(alpha: 0.48),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: selected
              ? Icon(
                  Icons.check_rounded,
                  color: isYellow ? Colors.black : Colors.white,
                  size: 23,
                )
              : null,
        ),
      ),
    );
  }
}
