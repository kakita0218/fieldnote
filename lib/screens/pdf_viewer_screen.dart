import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as pdfx;

import '../models/drawing_stroke.dart';
import 'camera_capture_screen.dart';
import '../models/photo_data.dart';
import '../models/pin_data.dart';
import '../theme/app_colors.dart';
import '../widgets/single_page_pdf_canvas.dart';
import '../widgets/pin_side_panel.dart';
import '../services/photo_storage.dart';
import '../services/project_repository.dart';

enum FieldTool {
  pin,
  pen,
}

const List<Color> _fieldPaletteColors = <Color>[
  Color(0xFF1976D2), // 青
  Color(0xFFE53935), // 赤
  Color(0xFFF4C20D), // 黄
  Color(0xFF2EAD62), // 緑
  Color(0xFF7E57C2), // 紫
  Color(0xFF111111), // 黒
];

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

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  pdfx.PdfDocument? _pdfDocument;
  Uint8List? _pageImageBytes;
  double _pageAspectRatio = 1;
  bool _isRenderingPage = false;
  final TransformationController _transformationController =
      TransformationController();

  String? _pdfPath;
  String? _pdfName;
  Uint8List? _pdfBytes;
  late String _projectName;
  Timer? _saveDebounce;
  Future<void> _saveTail = Future<void>.value();
  bool _saveInProgress = false;
  bool _pinsDirty = false;
  bool _drawingsDirty = false;
  bool _metaDirty = false;
  bool _isRestoring = false;
  String? _errorMessage;

  int _currentPage = 1;
  int _pageCount = 0;
  int _nextPinNumber = 1;

  bool _isPickingFile = false;
  bool _isExporting = false;

  FieldTool? _selectedTool;
  Color _pinColor = _fieldPaletteColors.first;
  Color _penColor = const Color(0xFFE53935);
  double _penWidth = 3.0;
  bool _eraserEnabled = false;

  final List<PinData> _pins = [];
  final List<PinData> _redoPins = [];
  final Map<int, List<DrawingStroke>> _strokesByPage = {};
  final Map<int, List<DrawingStroke>> _redoStrokesByPage = {};
  DrawingStroke? _activeStroke;
  final Map<String, List<PhotoData>> _photosByPinId = {};

  String? _selectedPinId;
  String? _pendingDirectionPinId;
  TextEditingController? _noteController;

  @override
  void initState() {
    super.initState();
    _projectName = widget.projectName;
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
    _noteController?.dispose();
    _pdfDocument?.close();
    _saveDebounce?.cancel();
    _transformationController.dispose();
    super.dispose();
  }

  Future<void> _pickPdf() async {
    if (_isPickingFile) {
      return;
    }

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

      if (!mounted || result == null) {
        return;
      }

      final PlatformFile selectedFile = result.files.single;

      final pdfx.PdfDocument nextDocument;
      final String pdfIdentity;
      Uint8List? selectedBytes = selectedFile.bytes;
      if (selectedBytes == null && selectedFile.path != null) {
        selectedBytes = await XFile(selectedFile.path!).readAsBytes();
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
      pdfIdentity = '${selectedFile.name}-${persistentBytes.length}';

      final pdfx.PdfDocument? previousDocument = _pdfDocument;

      _noteController?.dispose();
      _noteController = null;

      setState(() {
        _pdfDocument = nextDocument;
        _pageImageBytes = null;
        _pdfPath = pdfIdentity;
        _pdfName = selectedFile.name;
        _pdfBytes = persistentBytes;

        _currentPage = 1;
        _pageCount = nextDocument.pagesCount;

        _selectedTool = null;

        _pins.clear();
        _redoPins.clear();
        _photosByPinId.clear();
        _strokesByPage.clear();
        _redoStrokesByPage.clear();
        _activeStroke = null;

        _nextPinNumber = 1;
        _selectedPinId = null;
        _pendingDirectionPinId = null;

        _errorMessage = null;
      });

      await previousDocument?.close();
      await _renderPage(_currentPage);

      // PDF is written once. Later edits never rewrite this binary.
      await ProjectRepository.savePdfOnce(
        projectId: widget.projectId,
        projectName: _projectName,
        pdfName: _pdfName ?? '図面.pdf',
        bytes: persistentBytes,
      );
      _pinsDirty = true;
      _drawingsDirty = true;
      _metaDirty = true;
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
      if (tool == FieldTool.pin) {
        _showPinSettings();
      } else {
        _showPenSettings();
      }
      return;
    }

    setState(() {
      _selectedTool = tool;
    });
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
    );

    setState(() {
      _pins.add(pin);
      _redoPins.clear();

      _nextPinNumber++;
      _selectedPinId = pin.id;
      _pendingDirectionPinId = pin.id;

      _setNoteController(pin.note);
    });
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

    final bool shouldOpenCamera = _pendingDirectionPinId == pin.id;
    final PinData updatedPin = _pins[index].copyWith(
      directionDegrees: directionDegrees,
    );

    setState(() {
      _pins[index] = updatedPin;
      _pendingDirectionPinId = null;
      _selectedPinId = updatedPin.id;
      _redoPins.clear();
    });

    _scheduleSave();

    if (shouldOpenCamera) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _capturePhotosForPin(updatedPin);
        }
      });
    }
  }

  Future<void> _selectPin(PinData pin) async {
    setState(() {
      _selectedPinId = pin.id;
      _pinColor = Color(pin.colorValue);
      _setNoteController(pin.note);
    });

    try {
      final List<Map<String, dynamic>> rows =
          await ProjectRepository.loadPhotosForPin(
        projectId: widget.projectId,
        pinId: pin.id,
      );
      if (!mounted || _selectedPinId != pin.id) return;
      final List<PhotoData> photos = rows
          .map((row) => PhotoData(
                id: row['photoId'].toString(),
                fileName: row['fileName']?.toString() ?? '001.jpg',
                bytes: Uint8List.fromList(row['bytes'] as Uint8List),
              ))
          .toList(growable: false);
      setState(() {
        // Keep only the currently viewed pin's full-resolution images in RAM.
        _photosByPinId.clear();
        _photosByPinId[pin.id] = photos;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _errorMessage = '写真を読み込めませんでした。\n$error');
      }
    }
  }

  void _closePinPanel() {
    _endStroke();
    _saveSelectedPinNote();

    setState(() {
      _selectedPinId = null;
      _pendingDirectionPinId = null;
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

    setState(() {
      _photosByPinId.remove(selectedId);
      _pins.removeAt(index);
      _redoPins.clear();

      _renumberPins();

      _selectedPinId = null;
      if (_pendingDirectionPinId == selectedId) {
        _pendingDirectionPinId = null;
      }
    });

    _noteController?.dispose();
    _noteController = null;
    await ProjectRepository.deletePhotosForPin(
      projectId: widget.projectId,
      pinId: selectedId,
    );
    _scheduleSave(pins: true, drawings: false, meta: true);
  }

  void _startStroke(Offset normalizedPosition, double pressure) {
    if (_selectedTool != FieldTool.pen) return;
    if (_eraserEnabled) {
      _eraseAt(normalizedPosition);
      return;
    }

    final DrawingStroke stroke = DrawingStroke(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      pageNumber: _currentPage,
      width: _penWidth,
      color: _penColor,
      points: <DrawingPoint>[
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
      pageStrokes.add(stroke);
      _redoStrokesByPage[_currentPage]?.clear();
    });
  }

  void _updateStroke(Offset normalizedPosition, double pressure) {
    if (_eraserEnabled) {
      _eraseAt(normalizedPosition);
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
    if (_activeStroke == null) {
      return;
    }
    setState(() {
      _activeStroke = null;
    });
    _scheduleSave(pins: false, drawings: true, meta: true);
  }

  List<DrawingStroke> get _currentPageStrokes {
    return List<DrawingStroke>.unmodifiable(
      _strokesByPage[_currentPage] ?? const <DrawingStroke>[],
    );
  }

  bool get _canUndoCurrentTool {
    if (_selectedTool == null) return false;
    if (_selectedTool == FieldTool.pen) {
      return (_strokesByPage[_currentPage]?.isNotEmpty ?? false);
    }
    return _pins.isNotEmpty;
  }

  bool get _canRedoCurrentTool {
    if (_selectedTool == null) return false;
    if (_selectedTool == FieldTool.pen) {
      return (_redoStrokesByPage[_currentPage]?.isNotEmpty ?? false);
    }
    return _redoPins.isNotEmpty;
  }

  void _undo() {
    if (_selectedTool == FieldTool.pen) {
      final List<DrawingStroke>? pageStrokes = _strokesByPage[_currentPage];
      if (pageStrokes == null || pageStrokes.isEmpty) {
        return;
      }
      setState(() {
        final DrawingStroke removed = pageStrokes.removeLast();
        _redoStrokesByPage
            .putIfAbsent(_currentPage, () => <DrawingStroke>[])
            .add(removed);
        _activeStroke = null;
      });
      _scheduleSave();
      return;
    }

    if (_pins.isEmpty) {
      return;
    }

    final PinData removedPin = _pins.last;

    setState(() {
      _pins.removeLast();
      _redoPins.add(removedPin);

      if (_pendingDirectionPinId == removedPin.id) {
        _pendingDirectionPinId = null;
      }

      if (_selectedPinId == removedPin.id) {
        _selectedPinId = null;
        _noteController?.dispose();
        _noteController = null;
      }

      _renumberPins();
    });
    _scheduleSave();
  }

  void _redo() {
    if (_selectedTool == FieldTool.pen) {
      final List<DrawingStroke>? redo = _redoStrokesByPage[_currentPage];
      if (redo == null || redo.isEmpty) {
        return;
      }
      setState(() {
        final DrawingStroke restored = redo.removeLast();
        _strokesByPage
            .putIfAbsent(_currentPage, () => <DrawingStroke>[])
            .add(restored);
      });
      _scheduleSave();
      return;
    }

    if (_redoPins.isEmpty) {
      return;
    }

    final PinData restoredPin = _redoPins.removeLast();

    setState(() {
      _pins.add(
        restoredPin.copyWith(
          number: _nextPinNumber,
        ),
      );

      _nextPinNumber++;
    });
    _scheduleSave();
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
    await _ensurePhotosLoadedForPin(pin);
    if (!mounted) return;

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
          onCaptured: (bytes) => _saveCapturedPhoto(currentPin, bytes),
        ),
      ),
    );
  }

  Future<void> _ensurePhotosLoadedForPin(PinData pin) async {
    final List<PhotoData>? cached = _photosByPinId[pin.id];
    if (pin.photoCount == 0) {
      _photosByPinId.clear();
      _photosByPinId[pin.id] = <PhotoData>[];
      return;
    }
    if (cached != null && cached.length >= pin.photoCount) {
      return;
    }

    try {
      final List<Map<String, dynamic>> rows =
          await ProjectRepository.loadPhotosForPin(
        projectId: widget.projectId,
        pinId: pin.id,
      );
      if (!mounted) return;
      final List<PhotoData> photos = rows
          .map(
            (row) => PhotoData(
              id: row['photoId'].toString(),
              fileName: row['fileName']?.toString() ?? '001.jpg',
              bytes: Uint8List.fromList(row['bytes'] as Uint8List),
            ),
          )
          .toList(growable: true);
      setState(() {
        _photosByPinId.clear();
        _photosByPinId[pin.id] = photos;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('直前の写真を読み込めませんでした：$error')),
        );
      }
    }
  }

  Future<Uint8List> _makePhotoThumbnail(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 360,
    );
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ByteData? data =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      return data?.buffer.asUint8List() ?? Uint8List.fromList(bytes);
    } finally {
      codec.dispose();
    }
  }

  Future<PhotoData?> _saveCapturedPhoto(PinData pin, Uint8List bytes) async {
    final int pinIndex = _pins.indexWhere((item) => item.id == pin.id);
    if (pinIndex < 0) return null;

    final List<PhotoData> existing = List<PhotoData>.from(
      _photosByPinId[pin.id] ?? const <PhotoData>[],
    );
    final PinData currentPin = _pins[pinIndex];
    final int photoNumber = currentPin.photoCount + 1;
    final String fileName = '${photoNumber.toString().padLeft(3, '0')}.jpg';
    final String? savedPath = await savePinPhoto(
      pinNumber: pin.number,
      photoNumber: photoNumber,
      bytes: bytes,
    );
    final String photoId =
        '${pin.id}-$photoNumber-${DateTime.now().microsecondsSinceEpoch}';
    final Uint8List thumbnailBytes = await _makePhotoThumbnail(bytes);
    await ProjectRepository.savePhoto(
      projectId: widget.projectId,
      pinId: pin.id,
      photoId: photoId,
      fileName: fileName,
      bytes: bytes,
      thumbnailBytes: thumbnailBytes,
    );
    final PhotoData savedPhoto = PhotoData(
      id: photoId,
      fileName: fileName,
      bytes: thumbnailBytes,
      savedPath: savedPath,
    );
    existing.add(savedPhoto);

    if (!mounted) return null;
    final int latestPinIndex = _pins.indexWhere((item) => item.id == pin.id);
    if (latestPinIndex < 0) return null;
    setState(() {
      _selectedPinId = pin.id;
      _photosByPinId.clear();
      _photosByPinId[pin.id] = existing;
      final int nextCount = math.max(
        _pins[latestPinIndex].photoCount + 1,
        existing.length,
      );
      _pins[latestPinIndex] =
          _pins[latestPinIndex].copyWith(photoCount: nextCount);
      _redoPins.clear();
      _setNoteController(_pins[latestPinIndex].note);
    });
    _scheduleSave(pins: true, drawings: false, meta: true);
    return savedPhoto;
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
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          photos[index].bytes,
                          fit: BoxFit.cover,
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

  Future<void> _renderPage(int pageNumber) async {
    final pdfx.PdfDocument? document = _pdfDocument;
    if (document == null ||
        pageNumber < 1 ||
        pageNumber > document.pagesCount) {
      return;
    }

    setState(() {
      _isRenderingPage = true;
      _errorMessage = null;
    });

    pdfx.PdfPage? page;
    try {
      page = await document.getPage(pageNumber);
      final double aspectRatio = page.width / page.height;
      const double renderScale = 2.0;
      final pdfx.PdfPageImage? image = await page.render(
        width: page.width * renderScale,
        height: page.height * renderScale,
        format: pdfx.PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );

      if (!mounted || image == null) {
        return;
      }

      _transformationController.value = Matrix4.identity();
      setState(() {
        _pageImageBytes = image.bytes;
        _pageAspectRatio = aspectRatio;
        _isRenderingPage = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isRenderingPage = false;
        _errorMessage = 'PDFページを表示できませんでした。\n$error';
      });
    } finally {
      await page?.close();
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
    _noteController?.dispose();
    _noteController = null;

    setState(() {
      _currentPage = pageNumber;
      _selectedPinId = null;
      _pendingDirectionPinId = null;
    });

    _scheduleSave();
    await _renderPage(pageNumber);
  }

  String _threeDigits(int value) => value.toString().padLeft(3, '0');

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
    final Color pinColor = Color(pin.colorValue);
    final bool lightColor = pinColor.computeLuminance() > 0.62;
    final Color edgeColor = lightColor ? const Color(0xFF3B3420) : Colors.white;
    final Color textColor = lightColor ? const Color(0xFF10151C) : Colors.white;
    final double radius = 12 * exportScale;
    final double angle = pin.directionDegrees * math.pi / 180;
    final Offset forward = Offset(math.sin(angle), -math.cos(angle));
    final Offset side = Offset(math.cos(angle), math.sin(angle));
    final Offset arrowCenter = center + forward * (radius + 5 * exportScale);
    final double arrowLength = 7 * exportScale;
    final double arrowHalfWidth = 4 * exportScale;
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

    canvas.drawPath(
      arrow,
      Paint()
        ..color = edgeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4 * exportScale
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
        ..strokeWidth = 1.8 * exportScale,
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

      for (final DrawingStroke stroke
          in _strokesByPage[pageNumber] ?? const <DrawingStroke>[]) {
        if (stroke.points.length < 2) continue;
        final Paint paint = Paint()
          ..color = stroke.color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = stroke.width * exportScale;
        final Path path = Path();
        final DrawingPoint first = stroke.points.first;
        path.moveTo(first.position.dx * width, first.position.dy * height);
        for (final DrawingPoint point in stroke.points.skip(1)) {
          path.lineTo(point.position.dx * width, point.position.dy * height);
        }
        canvas.drawPath(path, paint);
      }

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
    _endStroke();
    _saveSelectedPinNote();
    setState(() {
      _isExporting = true;
      _errorMessage = null;
    });

    try {
      final Uint8List pdfBytes = await _buildAnnotatedPdf();
      final Archive archive = Archive();
      archive.addFile(
        ArchiveFile.bytes('現調図面.pdf', pdfBytes),
      );

      final List<PinData> sortedPins = List<PinData>.from(_pins)
        ..sort((a, b) => a.number.compareTo(b.number));
      for (final PinData pin in sortedPins) {
        final String folder = _threeDigits(pin.number);
        final List<Map<String, dynamic>> storedPhotos =
            await ProjectRepository.loadPhotosForPin(
          projectId: widget.projectId,
          pinId: pin.id,
        );
        final List<PhotoData> photos = storedPhotos
            .map((row) => PhotoData(
                  id: row['photoId'].toString(),
                  fileName: row['fileName']?.toString() ?? '001.jpg',
                  bytes: row['bytes'] as Uint8List,
                ))
            .toList(growable: false);
        if (photos.isEmpty) {
          archive.addFile(ArchiveFile.directory('$folder/'));
          continue;
        }
        for (int index = 0; index < photos.length; index++) {
          final String photoName = _threeDigits(index + 1);
          archive.addFile(
            ArchiveFile.bytes('$folder/$photoName.jpg', photos[index].bytes),
          );
        }
      }

      final Uint8List zipBytes = ZipEncoder().encodeBytes(archive);
      final String baseName = (_pdfName ?? '現調メモ')
          .replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
      await FileSaver.instance.saveFile(
        name: '${baseName}_現調データ',
        bytes: zipBytes,
        fileExtension: 'zip',
        mimeType: MimeType.zip,
      );

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
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
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
    _saveDebounce?.cancel();
    // A short idle delay lets users write multi-stroke characters without a
    // database transaction being started after every single stroke.
    _saveDebounce = Timer(const Duration(milliseconds: 900), () {
      _enqueueSave();
    });
  }

  Future<void> _enqueueSave() {
    _saveTail = _saveTail.then((_) => _saveProjectNow());
    return _saveTail;
  }

  List<Map<String, dynamic>> _serializePins() => _pins
      .map((p) => {
            'id': p.id,
            'number': p.number,
            'pageNumber': p.pageNumber,
            'xRatio': p.xRatio,
            'yRatio': p.yRatio,
            'directionDegrees': p.directionDegrees,
            'photoCount': p.photoCount,
            'note': p.note,
            'colorValue': p.colorValue,
          })
      .toList(growable: false);

  List<Map<String, dynamic>> _serializeStrokes() => _strokesByPage.entries
      .expand((e) => e.value)
      .map((s) => {
            'id': s.id,
            'pageNumber': s.pageNumber,
            'width': s.width,
            'color': s.color.toARGB32(),
            'points': s.points
                .map((p) => {
                      'x': p.position.dx,
                      'y': p.position.dy,
                      'pressure': p.pressure,
                    })
                .toList(growable: false),
          })
      .toList(growable: false);

  Future<void> _saveProjectNow() async {
    if (_isRestoring || _pdfBytes == null) return;

    final bool savePins = _pinsDirty;
    final bool saveDrawings = _drawingsDirty;
    final bool saveMeta = _metaDirty;
    if (!savePins && !saveDrawings && !saveMeta) return;

    // Clear before awaiting. New edits made during the write set the flags again
    // and are handled by the next queued save.
    _pinsDirty = false;
    _drawingsDirty = false;
    _metaDirty = false;

    if (mounted) setState(() => _saveInProgress = true);
    try {
      if (savePins) {
        await ProjectRepository.savePins(
          projectId: widget.projectId,
          pins: _serializePins(),
        );
      }
      if (saveDrawings) {
        await ProjectRepository.saveDrawings(
          projectId: widget.projectId,
          strokes: _serializeStrokes(),
        );
      }
      if (saveMeta) {
        await ProjectRepository.touchProject(
          id: widget.projectId,
          name: _projectName,
          values: <String, dynamic>{
            'pdfName': _pdfName,
            'pageCount': _pageCount,
            'currentPage': _currentPage,
            'nextPinNumber': _nextPinNumber,
            'pinColor': _pinColor.toARGB32(),
            'penColor': _penColor.toARGB32(),
            'penWidth': _penWidth,
          },
        );
      }
      if (mounted) setState(() => _errorMessage = null);
    } catch (error) {
      // Restore dirty flags so a retry does not lose pending edits.
      _pinsDirty = _pinsDirty || savePins;
      _drawingsDirty = _drawingsDirty || saveDrawings;
      _metaDirty = _metaDirty || saveMeta;
      if (mounted) {
        setState(() {
          _errorMessage = '案件の保存に失敗しました。再試行します。\n$error';
        });
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _saveInProgress = false);
    }
  }

  Future<void> _loadSavedProject() async {
    _isRestoring = true;
    try {
      final data = await ProjectRepository.loadProject(widget.projectId);
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
      final restoredPins = (data['pins'] as List? ?? const []).map((v) {
        final m = v as Map<String, dynamic>;
        return PinData(
          id: m['id'] as String,
          number: (m['number'] as num).toInt(),
          pageNumber: (m['pageNumber'] as num).toInt(),
          xRatio: (m['xRatio'] as num).toDouble(),
          yRatio: (m['yRatio'] as num).toDouble(),
          directionDegrees: (m['directionDegrees'] as num?)?.toDouble() ?? 0,
          photoCount: (m['photoCount'] as num?)?.toInt() ?? 0,
          note: m['note'] as String? ?? '',
          colorValue: (m['colorValue'] as num?)?.toInt() ?? 0xFF1976D2,
        );
      }).toList();
      final restoredStrokes = <int, List<DrawingStroke>>{};
      for (final v in (data['strokes'] as List? ?? const [])) {
        final m = v as Map<String, dynamic>;
        final page = (m['pageNumber'] as num).toInt();
        final stroke = DrawingStroke(
          id: m['id'] as String,
          pageNumber: page,
          width: (m['width'] as num?)?.toDouble() ?? 3,
          color: Color((m['color'] as num?)?.toInt() ?? 0xFFE53935),
          points: (m['points'] as List? ?? const []).map((v) {
            final p = v as Map<String, dynamic>;
            return DrawingPoint(
              position: Offset(
                  (p['x'] as num).toDouble(), (p['y'] as num).toDouble()),
              pressure: (p['pressure'] as num?)?.toDouble() ?? 0.5,
            );
          }).toList(),
        );
        restoredStrokes.putIfAbsent(page, () => []).add(stroke);
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
      if (!mounted) return;
      setState(() {
        _pdfDocument = document;
        _pdfBytes = persistentBytes;
        _pdfName = data['pdfName'] as String? ?? '図面.pdf';
        _pdfPath = '${widget.projectId}-${persistentBytes.length}';
        _pageCount = document.pagesCount;
        _pins
          ..clear()
          ..addAll(restoredPins);
        _strokesByPage
          ..clear()
          ..addAll(restoredStrokes);
        _photosByPinId.clear();
        _nextPinNumber =
            (data['nextPinNumber'] as num?)?.toInt() ?? (_pins.length + 1);
        _pinColor = Color((data['pinColor'] as num?)?.toInt() ?? 0xFF1976D2);
        _penColor = Color((data['penColor'] as num?)?.toInt() ?? 0xFFE53935);
        _selectedTool = null;
        _penWidth = (data['penWidth'] as num?)?.toDouble() ?? 3;
        _currentPage =
            ((data['currentPage'] as num?)?.toInt() ?? 1).clamp(1, _pageCount);
      });
      await _renderPage(_currentPage);
      if (widget.exportOnOpen && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _exportProject());
      }
    } catch (error) {
      if (mounted) setState(() => _errorMessage = '案件を開けませんでした。\n$error');
    } finally {
      _isRestoring = false;
    }
  }

  void _eraseAt(Offset position) {
    final strokes = _strokesByPage[_currentPage];
    if (strokes == null || strokes.isEmpty) return;
    final before = strokes.length;
    strokes.removeWhere((stroke) =>
        stroke.points.any((p) => (p.position - position).distance < 0.025));
    if (strokes.length != before) {
      setState(() {});
      _scheduleSave();
    }
  }

  Future<void> _showPinSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (BuildContext sheetContext) => SafeArea(
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
                      Navigator.of(sheetContext).pop();
                    },
                  );
                }).toList(growable: false),
              ),
            ],
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
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'ペン設定',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
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
                    max: 10,
                    divisions: 9,
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
                                  future: _renderThumbnail(pageNumber),
                                  builder: (_, snapshot) => snapshot.hasData
                                      ? Image.memory(snapshot.data!,
                                          fit: BoxFit.contain)
                                      : const Center(
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2)),
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
    _endStroke();
    _saveSelectedPinNote();
    _saveDebounce?.cancel();

    try {
      await _enqueueSave();
    } catch (_) {
      // The screen must never trap the user. Dirty flags remain set and the
      // already committed photos/PDF stay intact. The project can be reopened
      // and saving retried.
    }

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final PinData? selectedPin = _selectedPin;

    return Scaffold(
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
                    else
                      const Icon(Icons.cloud_done_rounded, size: 17),
                    const SizedBox(width: 5),
                    Text(
                      _saveInProgress ? '保存中' : '保存済み',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          if (_pdfDocument != null)
            IconButton(
              tooltip: 'ページ一覧',
              onPressed: _showPageList,
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
                      onPressed: _currentPage > 1
                          ? () => _goToPage(_currentPage - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    SizedBox(
                      width: 72,
                      child: Text(
                        _pageCount > 0 ? '$_currentPage / $_pageCount' : '読込中',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '次のページ',
                      onPressed: _pageCount > 0 && _currentPage < _pageCount
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
      body: SafeArea(
        child: _pdfDocument == null
            ? _buildEmptyState()
            : Stack(
                children: [
                  Positioned.fill(
                    child: _buildDrawingArea(),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(
                      milliseconds: 220,
                    ),
                    curve: Curves.easeOut,
                    top: 0,
                    right: selectedPin == null ? -320 : 0,
                    bottom: 0,
                    width: 320,
                    child: selectedPin == null || _noteController == null
                        ? const SizedBox.shrink()
                        : PinSidePanel(
                            pin: selectedPin,
                            photos: _photosForPin(selectedPin.id),
                            noteController: _noteController!,
                            onClose: _closePinPanel,
                            onDelete: _deleteSelectedPin,
                            onAddPhotos: _addPhotosToSelectedPin,
                            onShowAllPhotos: _showAllPhotosForSelectedPin,
                            onNoteChanged: (_) {
                              _saveSelectedPinNote();
                            },
                          ),
                  ),
                ],
              ),
      ),
      bottomNavigationBar: _pdfDocument == null ? null : _buildBottomToolbar(),
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

    return Stack(
      children: [
        Positioned.fill(
          child: imageBytes == null
              ? const Center(child: CircularProgressIndicator())
              : SinglePagePdfCanvas(
                  key: ValueKey<String>('${_pdfPath!}-$_currentPage'),
                  imageBytes: imageBytes,
                  pageAspectRatio: _pageAspectRatio,
                  transformationController: _transformationController,
                  pins: _currentPagePins,
                  strokes: _currentPageStrokes,
                  pinModeEnabled: _selectedTool == FieldTool.pin,
                  penModeEnabled: _selectedTool == FieldTool.pen,
                  selectedPinId: _selectedPinId,
                  pendingDirectionPinId: _pendingDirectionPinId,
                  onAddPin: _addPin,
                  onPinTap: _selectPin,
                  onDirectionChanged: _changePinDirection,
                  onStrokeStart: _startStroke,
                  onStrokeUpdate: _updateStroke,
                  onStrokeEnd: _endStroke,
                ),
        ),
        if (_isRenderingPage)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x66000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        if (_errorMessage != null)
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
                icon: Icons.location_on_rounded,
                iconColor: _pinColor,
                label: 'ピン',
                selected: _selectedTool == FieldTool.pin,
                onPressed: () => _selectTool(FieldTool.pin),
              ),
              _ToolbarButton(
                icon: _eraserEnabled
                    ? Icons.auto_fix_off_rounded
                    : Icons.edit_rounded,
                iconColor: _eraserEnabled ? Colors.white : _penColor,
                label: _eraserEnabled ? '消しゴム' : 'ペン',
                selected: _selectedTool == FieldTool.pen,
                onPressed: () => _selectTool(FieldTool.pen),
              ),
              _ToolbarButton(
                icon: Icons.undo_rounded,
                label: '戻る',
                selected: false,
                enabled: _canUndoCurrentTool,
                onPressed: _undo,
              ),
              _ToolbarButton(
                icon: Icons.redo_rounded,
                label: 'やり直し',
                selected: false,
                enabled: _canRedoCurrentTool,
                onPressed: _redo,
              ),
              _ToolbarButton(
                icon: Icons.ios_share_rounded,
                label: _isExporting ? '書出中' : '書き出し',
                selected: false,
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
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color resolvedIconColor = iconColor ?? AppColors.textSecondary;
    final bool needsContrastHalo =
        iconColor != null && resolvedIconColor.computeLuminance() < 0.12;

    return SizedBox(
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
                  color: selected
                      ? const Color(0xFF168BFF).withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color:
                        selected ? const Color(0xFF4AA8FF) : Colors.transparent,
                    width: 1.5,
                  ),
                  boxShadow: selected
                      ? <BoxShadow>[
                          BoxShadow(
                            color:
                                const Color(0xFF168BFF).withValues(alpha: 0.44),
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
                  color: selected
                      ? const Color(0xFF79C3FF)
                      : AppColors.textSecondary,
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
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
      label: '色を選択',
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
