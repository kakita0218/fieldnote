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
import '../theme/app_colors.dart';
import '../widgets/handwriting_layer.dart';
import '../widgets/single_page_pdf_canvas.dart';
import '../widgets/pin_side_panel.dart';
import '../services/native_project_service.dart';
import '../services/drawing_serialization.dart';
import '../services/project_export_zip_sink.dart';
import '../services/project_repository.dart';
import 'photo_editor_screen.dart';

enum FieldTool {
  select,
  pin,
  pen,
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
  move,
  direction,
}

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
  });

  final String projectId;
  final String projectName;
  final bool isNewProject;
  final bool exportOnOpen;

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

  bool _isPickingFile = false;
  int _pickOperationSequence = 0;
  bool _isExporting = false;

  FieldTool? _selectedTool;
  Color _pinColor = _fieldPaletteColors.first;
  double _pinOpacity = 1;
  Color _penColor = const Color(0xFFE53935);
  double _penWidth = 3.0;
  double _penOpacity = 1;
  DrawingBrush _penBrush = DrawingBrush.fountain;
  DrawingKind _shapeKind = DrawingKind.line;
  double _eraserWidth = 28;
  double _textFontSize = 22;
  double _textBoxWidthRatio = 0.45;
  bool _eraserEnabled = false;
  late String _boardBusinessName;
  String _boardFacilityName = '';

  final List<PinData> _pins = [];
  final List<_PinEdit> _undoPinEdits = <_PinEdit>[];
  final List<_PinEdit> _redoPinEdits = <_PinEdit>[];
  final Set<String> _pendingPhotoCleanupPinIds = <String>{};
  final Map<int, List<DrawingStroke>> _strokesByPage = {};
  final Map<String, List<DrawingStroke>> _photoAnnotationsById =
      <String, List<DrawingStroke>>{};
  final Map<int, List<_DrawingEdit>> _undoDrawingEditsByPage = {};
  final Map<int, List<_DrawingEdit>> _redoDrawingEditsByPage = {};
  DrawingStroke? _activeStroke;
  int? _activeStrokeIndex;
  DrawingStroke? _movingTextOriginal;
  Offset? _movingTextGrabOffset;
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
  bool _suppressPinPanel = false;
  String? _pendingDirectionPinId;
  String? _captureAfterDirectionPinId;
  TextEditingController? _noteController;

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

  Future<void> _pickPdf() async {
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
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        allowMultiple: false,
        withData: kIsWeb,
      );

      if (!operationIsActive() || result == null) {
        return;
      }

      final PlatformFile selectedFile = result.files.single;

      final pdfx.PdfDocument nextDocument;
      final String pdfIdentity;
      Uint8List? selectedBytes = selectedFile.bytes;
      if (selectedBytes == null && selectedFile.path != null) {
        selectedBytes = await XFile(selectedFile.path!).readAsBytes();
        if (!operationIsActive()) return;
      }
      if (selectedBytes == null || selectedBytes.isEmpty) {
        setState(() {
          _errorMessage = '選択したPDFのデータを読み込めませんでした。';
        });
        return;
      }
      // pdfxのWeb実装ではopenDataに渡したUint8Listのバッファが
      // PDF表示側へ移され、元のリストが空になる場合がある。
      // 保存用と表示用を別のバッファにして、保存用PDFを保持する。
      final Uint8List persistentBytes = Uint8List.fromList(selectedBytes);
      nextDocument = await pdfx.PdfDocument.openData(
        Uint8List.fromList(persistentBytes),
      );
      if (!operationIsActive()) {
        await nextDocument.close();
        return;
      }
      pdfIdentity = '${selectedFile.name}-${persistentBytes.length}';

      final pdfx.PdfDocument? previousDocument = _pdfDocument;

      _noteController?.dispose();
      _noteController = null;

      setState(() {
        _pdfDocument = nextDocument;
        _pageImageBytes = null;
        _thumbnailFutures.clear();
        _pdfPath = pdfIdentity;
        _pdfBytes = persistentBytes;

        _currentPage = 1;
        _pageCount = nextDocument.pagesCount;

        _selectedTool = null;

        _pins.clear();
        _undoPinEdits.clear();
        _redoPinEdits.clear();
        _pendingPhotoCleanupPinIds.clear();
        _photosByPinId.clear();
        _photoStorageVerifiedPinIds.clear();
        _photoStorageNeedsRescanPinIds.clear();
        _photoSavesInProgressByPinId.clear();
        _strokesByPage.clear();
        _photoAnnotationsById.clear();
        _undoDrawingEditsByPage.clear();
        _redoDrawingEditsByPage.clear();
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

        _nextPinNumber = 1;
        _selectedPinId = null;
        _selectedAnnotationId = null;
        _suppressPinPanel = false;
        _pendingDirectionPinId = null;
        _captureAfterDirectionPinId = null;

        _errorMessage = null;
      });

      await previousDocument?.close();
      await _renderPage(_currentPage);
      if (!operationIsActive()) return;

      // PDF is written once. Later edits never rewrite this binary.
      await ProjectRepository.savePdfOnce(
        projectId: widget.projectId,
        projectName: _projectName,
        bytes: persistentBytes,
      );
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
    _endStroke();

    if (_selectedTool == tool) {
      switch (tool) {
        case FieldTool.pin:
          _showPinSettings();
        case FieldTool.pen:
          _showPenSettings();
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
      if (tool != FieldTool.select) _selectedAnnotationId = null;
      if (tool != FieldTool.pen) _eraserEnabled = false;
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
  }

  bool _samePinPosition(PinData first, PinData second) {
    return first.xRatio == second.xRatio && first.yRatio == second.yRatio;
  }

  void _addPin(Offset normalizedPosition) {
    if (_selectedTool != FieldTool.pin) {
      return;
    }

    final PinData pin = PinData(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      number: _nextPinNumber,
      pageNumber: _currentPage,
      xRatio: normalizedPosition.dx,
      yRatio: normalizedPosition.dy,
      colorValue: _pinColor.toARGB32(),
      opacity: _pinOpacity,
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
    );
    final bool directionChanged =
        currentPin.directionDegrees != updatedPin.directionDegrees;
    final PinData? gestureOriginal = _directionPinOriginal;

    setState(() {
      _pins[index] = updatedPin;
      _pendingDirectionPinId = null;
      _captureAfterDirectionPinId = null;
      _selectedPinId = updatedPin.id;
      _pinColor = Color(updatedPin.colorValue);
      _pinOpacity = updatedPin.opacity;
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

  Future<void> _captureThenOpenPinDetails(PinData pin) async {
    final int beforeCount = pin.photoCount;
    await _capturePhotosForPin(pin);
    if (!mounted) return;
    final int index = _pins.indexWhere((PinData item) => item.id == pin.id);
    if (index < 0) return;
    final PinData latest = _pins[index];
    if (latest.photoCount > beforeCount) {
      setState(() {
        _suppressPinPanel = false;
        _selectedPinId = latest.id;
        _pinColor = Color(latest.colorValue);
        _pinOpacity = latest.opacity;
        _setNoteController(latest.note);
      });
      _transformationController.value = Matrix4.identity();
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
    if (original.directionDegrees == current.directionDegrees) return;
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
    setState(() {
      if (_pendingDirectionPinId != pin.id) {
        _pendingDirectionPinId = null;
        _captureAfterDirectionPinId = null;
      }
      _selectedPinId = pin.id;
      _suppressPinPanel = false;
      _pinColor = Color(pin.colorValue);
      _pinOpacity = pin.opacity;
      _setNoteController(pin.note);
    });
    _transformationController.value = Matrix4.identity();

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

    setState(() {
      _selectedPinId = null;
      _suppressPinPanel = false;
      _pendingDirectionPinId = null;
      _captureAfterDirectionPinId = null;
    });

    _noteController?.dispose();
    _noteController = null;
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
    final Set<String> photoIds =
        (_photosByPinId[selectedId] ?? const <PhotoData>[])
            .map((PhotoData photo) => photo.id)
            .toSet();

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
      _photosByPinId.remove(selectedId);
      for (final String photoId in photoIds) {
        _photoAnnotationsById.remove(photoId);
      }
      _photoAnnotationsById.removeWhere(
        (String photoId, List<DrawingStroke> _) =>
            photoId.startsWith('$selectedId-'),
      );
      _photoStorageVerifiedPinIds.remove(selectedId);
      _photoStorageNeedsRescanPinIds.remove(selectedId);
      _photoSavesInProgressByPinId.remove(selectedId);
      _discardPinRedoHistory();
      _undoPinEdits.removeWhere((_PinEdit edit) => edit.pinId == selectedId);
      _redoPinEdits.removeWhere((_PinEdit edit) => edit.pinId == selectedId);
      _pins.removeAt(latestIndex);
      _pendingPhotoCleanupPinIds.add(selectedId);

      _renumberPins();

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
    _pinsDirty = true;
    _metaDirty = true;
    _pdfDirty = true;
    try {
      // _saveProjectNow first commits the pin-free snapshot together with the
      // cleanup marker, then removes photos idempotently, and finally clears
      // the marker in a second snapshot. A termination at any point therefore
      // cannot resurrect a pin whose photos have already been deleted.
      await _enqueueSave();
    } catch (_) {
      // The marker and dirty flags remain in memory and automatic retry is
      // scheduled by _saveProjectNow.
    }
  }

  void _startStroke(Offset normalizedPosition, double pressure) {
    if (_selectedTool != FieldTool.pen && _selectedTool != FieldTool.shape) {
      return;
    }
    if (_selectedTool == FieldTool.pen && _eraserEnabled) {
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
    if (_selectedTool == FieldTool.pen && _eraserEnabled) {
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
    return _undoPinEdits.isNotEmpty;
  }

  bool get _canRedoCurrentTool {
    if (_selectedTool == null) return false;
    if (_drawingToolSelected) {
      return (_redoDrawingEditsByPage[_currentPage]?.isNotEmpty ?? false);
    }
    return _redoPinEdits.isNotEmpty;
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
        ),
      _PinEditKind.add => value,
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

    if (_undoPinEdits.isEmpty) {
      return;
    }

    _PinEdit edit = _undoPinEdits.removeLast();

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
          _renumberPins();
        }
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

    if (_redoPinEdits.isEmpty) {
      return;
    }

    final _PinEdit edit = _redoPinEdits.removeLast();

    setState(() {
      if (edit.kind == _PinEditKind.add && edit.after != null) {
        final int insertionIndex = edit.index.clamp(0, _pins.length);
        _pins.insert(insertionIndex, edit.after!);
        _renumberPins();
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

  void _renumberPins() {
    for (int index = 0; index < _pins.length; index++) {
      _pins[index] = _pins[index].copyWith(
        number: index + 1,
      );
    }

    _nextPinNumber = _pins.length + 1;
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
              _openPhotoEditor(currentPin, photos[index]);
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
          pinNumber: pin.number,
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
          pinNumber: pin.number,
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
                          _openPhotoEditor(pin, photo);
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
          pinNumber: pin.number,
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
                  pinNumber: pin.number,
                  photoId: photoId,
                ),
              );
            } else {
              await _enqueueStorageOperation<void>(
                () => ProjectRepository.saveEditedPhoto(
                  projectId: widget.projectId,
                  pinNumber: pin.number,
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
                  photoId: photoId,
                  pinNumber: pin.number,
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
          (pin) => pin.pageNumber == _currentPage,
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

  String _threeDigits(int value) => value.toString().padLeft(3, '0');

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
    final double radius = 12 * exportScale;
    final double angle = pin.directionDegrees * math.pi / 180;
    final Offset forward = Offset(math.sin(angle), -math.cos(angle));
    final Offset side = Offset(math.cos(angle), math.sin(angle));
    final Offset arrowCenter = center + forward * (radius + 5 * exportScale);
    final double arrowLength = 6 * exportScale;
    final double arrowHalfWidth = 3.5 * exportScale;
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
        radius + 3.5 * exportScale,
        Paint()
          ..color = const Color(0xFF49B7FF).withValues(alpha: pinOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 * exportScale,
      );
    }
    canvas.drawPath(
      arrow,
      Paint()
        ..color = edgeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6 * exportScale
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(arrow, Paint()..color = pinColor);
    canvas.drawCircle(center, radius, Paint()..color = pinColor);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = edgeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * exportScale,
    );

    final String label = pin.number.toString();
    final double baseFontSize = 11 * exportScale;
    final double fontSize =
        label.length >= 3 ? baseFontSize - 2 * exportScale : baseFontSize;
    final ui.ParagraphBuilder paragraphBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: TextAlign.center,
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
      ),
    )..pushStyle(ui.TextStyle(color: textColor));
    paragraphBuilder.addText(label);
    final ui.Paragraph paragraph = paragraphBuilder.build()
      ..layout(ui.ParagraphConstraints(width: radius * 2));
    canvas.drawParagraph(
      paragraph,
      Offset(center.dx - radius, center.dy - paragraph.height / 2),
    );
  }

  Future<Uint8List> _buildAnnotatedPageImage(int pageNumber) async {
    final pdfx.PdfDocument? document = _pdfDocument;
    if (document == null) {
      throw StateError('PDFが開かれていません。');
    }

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

      paintDrawingStrokes(
        canvas,
        Size(width, height),
        _strokesByPage[pageNumber] ?? const <DrawingStroke>[],
        widthScale: exportScale,
      );

      final List<PinData> pagePins = _pins
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

  Future<Uint8List> _buildAnnotatedPdf() async {
    final pw.Document outputPdf = pw.Document();
    for (int pageNumber = 1; pageNumber <= _pageCount; pageNumber++) {
      final Uint8List pagePng = await _buildAnnotatedPageImage(pageNumber);
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

  Future<void> _exportProject() async {
    if (_pdfDocument == null || _isExporting) return;
    ProjectExportZipSink? zipSink;
    _endStroke();
    _saveSelectedPinNote();
    setState(() {
      _isExporting = true;
      _errorMessage = null;
    });

    try {
      _saveDebounce?.cancel();
      await _enqueueSave();
      final String baseName = _safeProjectFileName();
      // Write entries incrementally. The previous Archive-based implementation
      // retained every full-resolution photo and then allocated the ZIP beside
      // them. PDF and JPEG data are already compressed, so storing them avoids
      // a second large temporary deflate buffer for each entry.
      zipSink = await ProjectExportZipSink.create();
      final ZipEncoder zipEncoder = ZipEncoder()..startEncode(zipSink.output);
      {
        final Uint8List pdfBytes;
        if (NativeProjectService.isAvailable) {
          final Uint8List? output =
              await ProjectRepository.loadOutputPdf(widget.projectId);
          if (output == null || output.isEmpty) {
            throw StateError('書き出し用PDFが見つかりません。');
          }
          pdfBytes = output;
        } else {
          pdfBytes = await _buildAnnotatedPdf();
        }
        zipEncoder.add(
          ArchiveFile.noCompress('$baseName.pdf', pdfBytes.length, pdfBytes),
          autoClose: true,
        );
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
      final List<PinData> sortedPins = List<PinData>.from(_pins)
        ..sort((a, b) => a.number.compareTo(b.number));
      final Map<String, PinData> pinsById = <String, PinData>{
        for (final PinData pin in sortedPins) pin.id: pin,
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
          final String folder = '写真/${_threeDigits(pin.number)}/';
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
              pinNumber: pin.number,
              photoId: photoId,
            );
            if (edited != null && edited.isNotEmpty) {
              zipEncoder.add(
                ArchiveFile.noCompress(
                  '$folder${number}_書き込み済み.png',
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
          zipEncoder.add(
            ArchiveFile.directory('写真/${_threeDigits(pin.number)}/'),
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
        'number': pin.number,
        'pageNumber': pin.pageNumber,
        'xRatio': pin.xRatio,
        'yRatio': pin.yRatio,
        'directionDegrees': pin.directionDegrees,
        'photoCount': pin.photoCount,
        'note': pin.note,
        'colorValue': pin.colorValue,
        'opacity': pin.opacity,
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

  List<Map<String, dynamic>> _serializePinRedoHistory() => _redoPinEdits
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
      number: (map['number'] as num?)?.toInt() ?? 1,
      pageNumber: (map['pageNumber'] as num?)?.toInt() ?? 1,
      xRatio: (map['xRatio'] as num?)?.toDouble() ?? 0,
      yRatio: (map['yRatio'] as num?)?.toDouble() ?? 0,
      directionDegrees: (map['directionDegrees'] as num?)?.toDouble() ?? 0,
      photoCount: (map['photoCount'] as num?)?.toInt() ?? 0,
      note: map['note']?.toString() ?? '',
      colorValue: (map['colorValue'] as num?)?.toInt() ?? 0xFF1976D2,
      opacity: ((map['opacity'] as num?)?.toDouble() ?? 1).clamp(0.1, 1),
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

  List<Map<String, dynamic>> _serializeStrokes() => _strokesByPage.entries
      .expand((MapEntry<int, List<DrawingStroke>> entry) => entry.value)
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

  Map<String, dynamic> _projectMetadata() => <String, dynamic>{
        'pdfName': '$_projectName.pdf',
        'pageCount': _pageCount,
        'currentPage': _currentPage,
        'nextPinNumber': _nextPinNumber,
        'pinColor': _pinColor.toARGB32(),
        'penColor': _penColor.toARGB32(),
        'penWidth': _penWidth,
        'pinOpacity': _pinOpacity,
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
        'pinRedoHistory': _serializePinRedoHistory(),
        'pendingPhotoCleanupPinIds':
            _pendingPhotoCleanupPinIds.toList(growable: false),
      };

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
        final String? sourcePath =
            await ProjectRepository.sourcePdfPath(widget.projectId);
        final String? outputPath =
            await ProjectRepository.outputPdfPath(widget.projectId);
        if (sourcePath == null || outputPath == null) {
          throw StateError('PDFの保存先が見つかりません。');
        }
        await NativeProjectService.writeAnnotatedPdf(
          sourcePath: sourcePath,
          outputPath: outputPath,
          pins: pins,
          strokes: strokes,
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
      final String? sourcePath =
          await ProjectRepository.sourcePdfPath(widget.projectId);
      if (!mounted) return;
      if (sourcePath != null) {
        try {
          await NativeProjectService.synchronizePencilDrawings(sourcePath);
        } catch (error) {
          pencilRecoveryError = error;
        }
      }
      if (!mounted) return;
      final data = await ProjectRepository.loadProject(widget.projectId);
      if (!mounted) return;
      if (data == null) {
        if (mounted) setState(() => _errorMessage = '案件データが見つかりません。');
        return;
      }
      final dynamic storedPdf = data['pdfBytes'];
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
      final Set<String> restoredCleanupPinIds =
          (data['pendingPhotoCleanupPinIds'] as List? ?? const <dynamic>[])
              .map((dynamic value) => value.toString())
              .where((String id) => id.isNotEmpty)
              .toSet();
      final restoredStrokes = <int, List<DrawingStroke>>{};
      for (final v in (data['strokes'] as List? ?? const [])) {
        final DrawingStroke? stroke = deserializeDrawingStroke(
          v,
          defaultPageNumber: 1,
        );
        if (stroke == null) continue;
        final int page = stroke.pageNumber;
        restoredStrokes.putIfAbsent(page, () => []).add(stroke);
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
      if (!mounted) return;
      setState(() {
        _projectName = data['projectName']?.toString() ?? widget.projectName;
        _pdfDocument = document;
        _thumbnailFutures.clear();
        _pdfBytes = persistentBytes;
        _pdfPath = '${widget.projectId}-${persistentBytes.length}';
        _pageCount = document.pagesCount;
        _pins
          ..clear()
          ..addAll(restoredPins);
        _undoPinEdits.clear();
        _redoPinEdits
          ..clear()
          ..addAll(restoredRedoPinEdits);
        final Set<String> recoverablePinIds = <String>{
          ...restoredPins.map((PinData pin) => pin.id),
          ...restoredRedoPinEdits
              .where((_PinEdit edit) => edit.kind == _PinEditKind.add)
              .map((_PinEdit edit) => edit.pinId),
        };
        _pendingPhotoCleanupPinIds
          ..clear()
          ..addAll(
            restoredCleanupPinIds
                .where((String id) => !recoverablePinIds.contains(id)),
          );
        _strokesByPage
          ..clear()
          ..addAll(restoredStrokes);
        _photoAnnotationsById
          ..clear()
          ..addAll(restoredPhotoAnnotations);
        _undoDrawingEditsByPage.clear();
        _redoDrawingEditsByPage.clear();
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
        _nextPinNumber =
            (data['nextPinNumber'] as num?)?.toInt() ?? (_pins.length + 1);
        _pinColor = Color((data['pinColor'] as num?)?.toInt() ?? 0xFF1976D2);
        _pinOpacity =
            ((data['pinOpacity'] as num?)?.toDouble() ?? 1).clamp(0.1, 1);
        _penColor = Color((data['penColor'] as num?)?.toInt() ?? 0xFFE53935);
        _boardBusinessName =
            data['boardBusinessName']?.toString() ?? _projectName;
        _boardFacilityName = data['boardFacilityName']?.toString() ?? '';
        _selectedTool = null;
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
        _currentPage =
            ((data['currentPage'] as num?)?.toInt() ?? 1).clamp(1, _pageCount);
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
      setState(() => _selectedAnnotationId = selected?.id);
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

  Future<void> _handleCanvasDoubleTap(Offset position) async {
    final DrawingStroke? hit = _annotationAt(position);
    if (hit?.kind != DrawingKind.text) return;
    setState(() => _selectedAnnotationId = hit!.id);
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
    if (hit == null || hit.kind != DrawingKind.text || hit.points.isEmpty) {
      return false;
    }
    _movingTextOriginal = hit;
    _movingTextGrabOffset = hit.points.first.position - position;
    setState(() => _selectedAnnotationId = hit.id);
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
    final Offset clamped = Offset(
      next.dx.clamp(0.0, 1.0),
      next.dy.clamp(0.0, 1.0),
    );
    setState(() {
      strokes[index] = strokes[index].copyWith(
        points: <DrawingPoint>[
          DrawingPoint(
            position: clamped,
            pressure: strokes[index].points.first.pressure,
          ),
        ],
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
    if (current.points.first.position == original.points.first.position) return;
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
    final DrawingStroke? selected = _selectedAnnotation;
    final List<DrawingStroke>? strokes = _strokesByPage[_currentPage];
    final int index = strokes?.indexWhere(
          (DrawingStroke stroke) => stroke.id == selected?.id,
        ) ??
        -1;
    if (selected == null || strokes == null || index < 0) return;
    setState(() {
      strokes.removeAt(index);
      _selectedAnnotationId = null;
      _undoDrawingEditsByPage
          .putIfAbsent(_currentPage, () => <_DrawingEdit>[])
          .add(
            _DrawingEdit(
              removedStrokes: <_IndexedDrawingStroke>[
                _IndexedDrawingStroke(stroke: selected, index: index),
              ],
              addedStrokes: const <_IndexedDrawingStroke>[],
            ),
          );
      _redoDrawingEditsByPage[_currentPage]?.clear();
    });
    _scheduleSave(pins: false, drawings: true, meta: true);
  }

  Future<void> _showSelectionSettings() async {
    if (_selectedAnnotation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('変更する線・図形・テキストを選択してください。')),
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
                        _eraserEnabled = false;
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
                        selected: _penColor.toARGB32() == color.toARGB32() &&
                            !_eraserEnabled,
                        onTap: () {
                          setState(() {
                            _penColor = color;
                            _eraserEnabled = false;
                          });
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
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() => _eraserEnabled = !_eraserEnabled);
                        setSheetState(() {});
                      },
                      icon: const Icon(Icons.auto_fix_off_rounded),
                      label: Text(
                        _eraserEnabled ? '消しゴム：ON' : '消しゴム',
                      ),
                    ),
                  ),
                  if (_eraserEnabled) ...<Widget>[
                    const SizedBox(height: 12),
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
          title: Text(
            _projectName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
            ),
          ),
          actions: [
            if (_pdfDocument != null)
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
            if (_pdfDocument != null)
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
            const SizedBox(width: 6),
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
                            selectedPin != null && !_suppressPinPanel ? 320 : 0,
                        child: _buildDrawingArea(),
                      ),
                      AnimatedPositioned(
                        duration: const Duration(
                          milliseconds: 220,
                        ),
                        curve: Curves.easeOut,
                        top: 0,
                        right:
                            selectedPin == null || _suppressPinPanel ? -320 : 0,
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
    final DrawingStroke? selectedText =
        _selectedAnnotation?.kind == DrawingKind.text
            ? _selectedAnnotation
            : null;

    return Stack(
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
                      _selectedTool == FieldTool.shape,
                  selectionModeEnabled: _selectedTool == FieldTool.select,
                  textModeEnabled: _selectedTool == FieldTool.text,
                  eraserEnabled:
                      _selectedTool == FieldTool.pen && _eraserEnabled,
                  eraserRadiusNormalized:
                      (_eraserWidth / 1120).clamp(0.006, 0.08),
                  selectedStrokeId: _selectedAnnotationId,
                  selectedPinId: _selectedPinId,
                  pendingDirectionPinId: _pendingDirectionPinId,
                  onAddPin: _addPin,
                  onPinTap: _selectPin,
                  onDirectionChanged: _changePinDirection,
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
            selectedText != null &&
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
                        'ドラッグで移動',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _editSelectedText,
                      icon: const Icon(Icons.keyboard_rounded, size: 19),
                      label: Text(
                        selectedText.text.isEmpty ? '文字入力' : '再編集',
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
                      '図面上の、矢印を向けたい場所をタップ',
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
    return Material(
      color: AppColors.panel,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 78,
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
                icon: _eraserEnabled
                    ? Icons.auto_fix_off_rounded
                    : Icons.edit_rounded,
                iconColor: _eraserEnabled ? Colors.white : _penColor,
                label: _eraserEnabled ? '消しゴム' : 'ペン',
                selected: _selectedTool == FieldTool.pen,
                enabled: pageInteractionAvailable,
                onPressed: () => _selectTool(FieldTool.pen),
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
                enabled: pageInteractionAvailable && _canUndoCurrentTool,
                onPressed: _undo,
              ),
              _ToolbarButton(
                icon: Icons.redo_rounded,
                label: 'やり直し',
                selected: null,
                enabled: pageInteractionAvailable && _canRedoCurrentTool,
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
