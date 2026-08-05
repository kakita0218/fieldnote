import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/drawing_stroke.dart';
import '../models/photo_data.dart';
import '../models/pin_data.dart';
import '../services/project_repository.dart';
import '../widgets/handwriting_layer.dart';
import '../widgets/single_page_pdf_canvas.dart';

enum _PhotoTool { select, pen, shape, text, eraser }

class PhotoEditorScreen extends StatefulWidget {
  const PhotoEditorScreen({
    super.key,
    required this.projectId,
    required this.pinNumber,
    required this.photos,
    required this.initialPhotoId,
    required this.annotations,
    required this.onSaved,
  });

  final String projectId;
  final int pinNumber;
  final List<PhotoData> photos;
  final String initialPhotoId;
  final Map<String, List<DrawingStroke>> annotations;
  final Future<void> Function(
    String photoId,
    List<DrawingStroke> strokes,
    Uint8List? renderedImage,
  ) onSaved;

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  final TransformationController _transformationController =
      TransformationController();
  late int _index;
  final Map<String, List<DrawingStroke>> _annotations =
      <String, List<DrawingStroke>>{};
  final List<List<DrawingStroke>> _undo = <List<DrawingStroke>>[];
  final List<List<DrawingStroke>> _redo = <List<DrawingStroke>>[];

  Uint8List? _originalBytes;
  double _aspectRatio = 1;
  bool _loading = true;
  bool _saving = false;
  bool _showOriginal = false;
  bool _dirty = false;
  String? _error;
  _PhotoTool _tool = _PhotoTool.pen;
  DrawingStroke? _activeStroke;
  List<DrawingStroke>? _gestureBefore;
  String? _selectedId;
  Color _color = const Color(0xFFE53935);
  double _width = 4;
  double _opacity = 1;
  double _eraserWidth = 28;
  double _fontSize = 22;
  DrawingBrush _brush = DrawingBrush.fountain;
  DrawingKind _shapeKind = DrawingKind.line;

  static const List<Color> _colors = <Color>[
    Color(0xFFE53935),
    Color(0xFFF4C20D),
    Color(0xFF1976D2),
    Color(0xFF2EAD62),
    Color(0xFF111111),
    Color(0xFFFFFFFF),
  ];

  PhotoData get _photo => widget.photos[_index];
  List<DrawingStroke> get _strokes =>
      _annotations.putIfAbsent(_photo.id, () => <DrawingStroke>[]);

  @override
  void initState() {
    super.initState();
    _index = widget.photos.indexWhere(
      (PhotoData photo) => photo.id == widget.initialPhotoId,
    );
    if (_index < 0) _index = 0;
    for (final MapEntry<String, List<DrawingStroke>> entry
        in widget.annotations.entries) {
      _annotations[entry.key] = List<DrawingStroke>.of(entry.value);
    }
    _loadCurrent();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bytes);
    final ui.ImageDescriptor descriptor =
        await ui.ImageDescriptor.encoded(buffer);
    final ui.Codec codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  Future<void> _loadCurrent() async {
    setState(() {
      _loading = true;
      _error = null;
      _selectedId = null;
      _undo.clear();
      _redo.clear();
    });
    try {
      final Uint8List? bytes = await ProjectRepository.loadPhotoBytes(
        projectId: widget.projectId,
        photoId: _photo.id,
        pinNumber: widget.pinNumber,
        fileName: _photo.fileName,
      );
      if (bytes == null || bytes.isEmpty) {
        throw StateError('元の写真を読み込めませんでした。');
      }
      final ui.Image image = await _decode(bytes);
      final double ratio = image.width / image.height;
      image.dispose();
      if (!mounted) return;
      setState(() {
        _originalBytes = bytes;
        _aspectRatio = ratio;
        _loading = false;
        _dirty = false;
        _transformationController.value = Matrix4.identity();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  List<DrawingStroke> _snapshot() => List<DrawingStroke>.of(_strokes);

  void _pushUndo(List<DrawingStroke> before) {
    _undo.add(before);
    if (_undo.length > 60) _undo.removeAt(0);
    _redo.clear();
    _dirty = true;
  }

  void _startStroke(Offset position, double pressure) {
    if (_showOriginal) return;
    if (_tool == _PhotoTool.eraser) {
      _gestureBefore ??= _snapshot();
      _eraseAt(position);
      return;
    }
    if (_tool != _PhotoTool.pen && _tool != _PhotoTool.shape) return;
    _gestureBefore = _snapshot();
    final DrawingKind kind =
        _tool == _PhotoTool.pen ? DrawingKind.freehand : _shapeKind;
    final DrawingStroke stroke = DrawingStroke(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      pageNumber: 0,
      points: <DrawingPoint>[
        DrawingPoint(position: position, pressure: pressure),
        if (kind == DrawingKind.line || kind == DrawingKind.rectangle)
          DrawingPoint(position: position, pressure: pressure),
      ],
      width: _width,
      color: _color,
      opacity: _opacity,
      brush: _brush,
      kind: kind,
    );
    setState(() {
      _activeStroke = stroke;
      _strokes.add(stroke);
      _selectedId = stroke.id;
    });
  }

  void _updateStroke(Offset position, double pressure) {
    if (_tool == _PhotoTool.eraser) {
      _eraseAt(position);
      return;
    }
    final DrawingStroke? stroke = _activeStroke;
    if (stroke == null) return;
    if (stroke.kind == DrawingKind.line ||
        stroke.kind == DrawingKind.rectangle) {
      stroke.points[stroke.points.length - 1] =
          DrawingPoint(position: position, pressure: pressure);
    } else {
      final DrawingPoint last = stroke.points.last;
      if ((last.position - position).distance < 0.0008) return;
      stroke.points.add(DrawingPoint(position: position, pressure: pressure));
    }
    setState(() {});
  }

  void _endStroke() {
    final List<DrawingStroke>? before = _gestureBefore;
    _gestureBefore = null;
    _activeStroke = null;
    if (before != null && !_sameStrokeLists(before, _strokes)) {
      setState(() => _pushUndo(before));
    }
  }

  bool _sameStrokeLists(List<DrawingStroke> a, List<DrawingStroke> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i]) && a[i].id != b[i].id) return false;
    }
    return true;
  }

  double _distanceToSegmentSquared(Offset p, Offset a, Offset b) {
    final Offset segment = b - a;
    final double length = segment.distanceSquared;
    if (length <= 1e-12) return (p - a).distanceSquared;
    final double t =
        (((p - a).dx * segment.dx + (p - a).dy * segment.dy) / length)
            .clamp(0.0, 1.0);
    return (p - (a + segment * t)).distanceSquared;
  }

  bool _strokeTouches(DrawingStroke stroke, Offset point, double radius) {
    if (stroke.points.isEmpty) return false;
    if (stroke.kind == DrawingKind.text ||
        stroke.kind == DrawingKind.rectangle) {
      final Rect bounds = drawingStrokeBounds(
        stroke,
        Size(_aspectRatio * 1000, 1000),
      );
      final Offset scaled =
          Offset(point.dx * _aspectRatio * 1000, point.dy * 1000);
      return bounds.inflate(radius * 1000).contains(scaled);
    }
    if (stroke.points.length == 1) {
      return (stroke.points.first.position - point).distance <= radius;
    }
    final double limit = radius * radius;
    for (int i = 1; i < stroke.points.length; i++) {
      if (_distanceToSegmentSquared(
            point,
            stroke.points[i - 1].position,
            stroke.points[i].position,
          ) <=
          limit) {
        return true;
      }
    }
    return false;
  }

  void _eraseAt(Offset position) {
    final double radius = (_eraserWidth / 1400).clamp(0.004, 0.06);
    bool changed = false;
    final List<DrawingStroke> next = <DrawingStroke>[];
    for (final DrawingStroke stroke in _strokes) {
      if (!_strokeTouches(stroke, position, radius)) {
        next.add(stroke);
        continue;
      }
      changed = true;
      if (stroke.kind != DrawingKind.freehand &&
          stroke.kind != DrawingKind.polyline) {
        continue;
      }
      final List<List<DrawingPoint>> runs = <List<DrawingPoint>>[];
      List<DrawingPoint> run = <DrawingPoint>[];
      for (final DrawingPoint sample in stroke.points) {
        if ((sample.position - position).distance > radius) {
          run.add(sample);
        } else if (run.isNotEmpty) {
          runs.add(run);
          run = <DrawingPoint>[];
        }
      }
      if (run.isNotEmpty) runs.add(run);
      for (int index = 0; index < runs.length; index++) {
        if (runs[index].isEmpty) continue;
        next.add(
          DrawingStroke(
            id: '${stroke.id}-erase-$index-${DateTime.now().microsecondsSinceEpoch}',
            pageNumber: stroke.pageNumber,
            points: runs[index],
            width: stroke.width,
            color: stroke.color,
            opacity: stroke.opacity,
            kind: stroke.kind,
            brush: stroke.brush,
            text: stroke.text,
            fontSize: stroke.fontSize,
            textBoxWidthRatio: stroke.textBoxWidthRatio,
          ),
        );
      }
    }
    if (changed) {
      setState(() {
        _strokes
          ..clear()
          ..addAll(next);
        if (!_strokes.any((DrawingStroke item) => item.id == _selectedId)) {
          _selectedId = null;
        }
      });
    }
  }

  Future<void> _canvasTap(Offset position) async {
    if (_showOriginal) return;
    if (_tool == _PhotoTool.text) {
      final TextEditingController controller = TextEditingController();
      final String? text = await showDialog<String>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('テキストを入力'),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
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
      if (text == null || text.isEmpty || !mounted) return;
      final List<DrawingStroke> before = _snapshot();
      final DrawingStroke annotation = DrawingStroke(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        pageNumber: 0,
        points: <DrawingPoint>[DrawingPoint(position: position)],
        width: _width,
        color: _color,
        opacity: _opacity,
        kind: DrawingKind.text,
        text: text,
        fontSize: _fontSize,
      );
      setState(() {
        _strokes.add(annotation);
        _selectedId = annotation.id;
        _pushUndo(before);
      });
      return;
    }
    if (_tool == _PhotoTool.select) {
      String? selected;
      double best = double.infinity;
      for (final DrawingStroke stroke in _strokes.reversed) {
        if (_strokeTouches(stroke, position, 0.025)) {
          final Offset anchor = stroke.points.first.position;
          final double distance = (anchor - position).distanceSquared;
          if (distance < best) {
            best = distance;
            selected = stroke.id;
          }
        }
      }
      setState(() => _selectedId = selected);
    }
  }

  void _undoAction() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add(_snapshot());
      final List<DrawingStroke> previous = _undo.removeLast();
      _strokes
        ..clear()
        ..addAll(previous);
      _selectedId = null;
      _dirty = true;
    });
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add(_snapshot());
      final List<DrawingStroke> next = _redo.removeLast();
      _strokes
        ..clear()
        ..addAll(next);
      _selectedId = null;
      _dirty = true;
    });
  }

  Future<Uint8List?> _renderEdited() async {
    final Uint8List? bytes = _originalBytes;
    if (bytes == null || _strokes.isEmpty) return null;
    ui.Image? original;
    ui.Image? output;
    try {
      original = await _decode(bytes);
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      canvas.drawImage(original, Offset.zero, Paint());
      paintDrawingStrokes(
        canvas,
        Size(original.width.toDouble(), original.height.toDouble()),
        _strokes,
        widthScale: math.max(original.width, original.height) / 1500,
      );
      output = await recorder.endRecording().toImage(
            original.width,
            original.height,
          );
      final ByteData? data =
          await output.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      output?.dispose();
      original?.dispose();
    }
  }

  Future<void> _saveCurrent() async {
    if (!_dirty || _saving) return;
    setState(() => _saving = true);
    try {
      final Uint8List? rendered = await _renderEdited();
      await widget.onSaved(
        _photo.id,
        List<DrawingStroke>.unmodifiable(_strokes),
        rendered,
      );
      if (!mounted) return;
      setState(() => _dirty = false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _movePhoto(int delta) async {
    final int next = _index + delta;
    if (next < 0 || next >= widget.photos.length || _saving) return;
    try {
      await _saveCurrent();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('写真の書き込みを保存できませんでした。\n$error')),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _index = next);
    await _loadCurrent();
  }

  Future<void> _finish() async {
    try {
      await _saveCurrent();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('写真の書き込みを保存できませんでした。\n$error')),
      );
    }
  }

  DrawingStroke? get _selectedStroke {
    final String? id = _selectedId;
    if (id == null) return null;
    for (final DrawingStroke stroke in _strokes) {
      if (stroke.id == id) return stroke;
    }
    return null;
  }

  void _updateSelected({
    Color? color,
    double? width,
    double? opacity,
  }) {
    final DrawingStroke? selected = _selectedStroke;
    if (selected == null) return;
    final int index = _strokes.indexOf(selected);
    final List<DrawingStroke> before = _snapshot();
    setState(() {
      _strokes[index] = selected.copyWith(
        color: color,
        width: width,
        opacity: opacity,
      );
      _pushUndo(before);
    });
  }

  Future<void> _showSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B213A),
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter updateSheet) {
          final DrawingStroke? selected = _selectedStroke;
          final double shownWidth = selected?.width ??
              (_tool == _PhotoTool.eraser ? _eraserWidth : _width);
          final double shownOpacity = selected?.opacity ?? _opacity;
          final Color shownColor = selected?.color ?? _color;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _tool == _PhotoTool.select ? '選択した注釈' : 'ツール設定',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (_tool == _PhotoTool.pen) ...<Widget>[
                    const SizedBox(height: 16),
                    SegmentedButton<DrawingBrush>(
                      segments: const <ButtonSegment<DrawingBrush>>[
                        ButtonSegment(
                            value: DrawingBrush.ballpoint,
                            label: Text('ボールペン')),
                        ButtonSegment(
                            value: DrawingBrush.fountain, label: Text('万年筆')),
                        ButtonSegment(
                            value: DrawingBrush.marker, label: Text('マーカー')),
                        ButtonSegment(
                            value: DrawingBrush.highlighter, label: Text('蛍光')),
                      ],
                      selected: <DrawingBrush>{_brush},
                      onSelectionChanged: (Set<DrawingBrush> values) {
                        setState(() => _brush = values.first);
                        updateSheet(() {});
                      },
                    ),
                  ],
                  if (_tool == _PhotoTool.shape) ...<Widget>[
                    const SizedBox(height: 16),
                    SegmentedButton<DrawingKind>(
                      segments: const <ButtonSegment<DrawingKind>>[
                        ButtonSegment(
                            value: DrawingKind.line, label: Text('直線')),
                        ButtonSegment(
                            value: DrawingKind.polyline, label: Text('連続線')),
                        ButtonSegment(
                            value: DrawingKind.rectangle, label: Text('矩形')),
                      ],
                      selected: <DrawingKind>{_shapeKind},
                      onSelectionChanged: (Set<DrawingKind> values) {
                        setState(() => _shapeKind = values.first);
                        updateSheet(() {});
                      },
                    ),
                  ],
                  if (_tool != _PhotoTool.eraser) ...<Widget>[
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      children: _colors.map((Color color) {
                        return InkWell(
                          onTap: () {
                            if (selected != null) {
                              _updateSelected(color: color);
                            } else {
                              setState(() => _color = color);
                            }
                            updateSheet(() {});
                          },
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: shownColor.toARGB32() == color.toARGB32()
                                    ? const Color(0xFF42A5F5)
                                    : Colors.white54,
                                width: 3,
                              ),
                            ),
                          ),
                        );
                      }).toList(growable: false),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    _tool == _PhotoTool.eraser
                        ? '消しゴムの太さ ${shownWidth.toStringAsFixed(0)}'
                        : '太さ ${shownWidth.toStringAsFixed(0)}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  Slider(
                    value: shownWidth.clamp(
                        1, _tool == _PhotoTool.eraser ? 80 : 24),
                    min: _tool == _PhotoTool.eraser ? 6 : 1,
                    max: _tool == _PhotoTool.eraser ? 80 : 24,
                    onChanged: (double value) {
                      if (_tool == _PhotoTool.eraser) {
                        setState(() => _eraserWidth = value);
                      } else if (selected != null) {
                        _updateSelected(width: value);
                      } else {
                        setState(() => _width = value);
                      }
                      updateSheet(() {});
                    },
                  ),
                  if (_tool != _PhotoTool.eraser) ...<Widget>[
                    Text(
                      '透過率 ${(shownOpacity * 100).round()}%',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Slider(
                      value: shownOpacity.clamp(0.1, 1),
                      min: 0.1,
                      max: 1,
                      divisions: 18,
                      onChanged: (double value) {
                        if (selected != null) {
                          _updateSelected(opacity: value);
                        } else {
                          setState(() => _opacity = value);
                        }
                        updateSheet(() {});
                      },
                    ),
                  ],
                  if (_tool == _PhotoTool.text) ...<Widget>[
                    Text(
                      '文字サイズ ${_fontSize.round()}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Slider(
                      value: _fontSize,
                      min: 12,
                      max: 64,
                      onChanged: (double value) {
                        setState(() => _fontSize = value);
                        updateSheet(() {});
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

  void _selectTool(_PhotoTool tool) {
    if (_tool == tool) {
      _showSettings();
      return;
    }
    setState(() {
      _tool = tool;
      if (tool != _PhotoTool.select) _selectedId = null;
    });
  }

  Widget _toolButton(
    _PhotoTool tool,
    IconData icon,
    String label,
  ) {
    final bool selected = _tool == tool;
    return Expanded(
      child: InkWell(
        onTap: _showOriginal ? null : () => _selectTool(tool),
        child: Container(
          color: selected ? const Color(0xFF087BF0) : Colors.transparent,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, color: _showOriginal ? Colors.white30 : Colors.white),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: _showOriginal ? Colors.white30 : Colors.white,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? imageBytes = _originalBytes;
    return PopScope<void>(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _finish();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: const Color(0xFF071D35),
          foregroundColor: Colors.white,
          title: Text('ピン${widget.pinNumber}の写真'),
          leading: IconButton(
            onPressed: _saving ? null : _finish,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          actions: <Widget>[
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: true, label: Text('原本')),
                ButtonSegment<bool>(value: false, label: Text('書き込み済み')),
              ],
              selected: <bool>{_showOriginal},
              onSelectionChanged: (Set<bool> value) {
                setState(() => _showOriginal = value.first);
              },
            ),
            IconButton(
              onPressed: _index > 0 ? () => _movePhoto(-1) : null,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Text('${_index + 1} / ${widget.photos.length}'),
            IconButton(
              onPressed: _index + 1 < widget.photos.length
                  ? () => _movePhoto(1)
                  : null,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.white),
                    ),
                  )
                : imageBytes == null
                    ? const SizedBox.shrink()
                    : SinglePagePdfCanvas(
                        imageBytes: imageBytes,
                        pageAspectRatio: _aspectRatio,
                        transformationController: _transformationController,
                        pins: const <PinData>[],
                        strokes: _showOriginal
                            ? const <DrawingStroke>[]
                            : List<DrawingStroke>.unmodifiable(_strokes),
                        pinModeEnabled: false,
                        penModeEnabled: !_showOriginal &&
                            (_tool == _PhotoTool.pen ||
                                _tool == _PhotoTool.shape ||
                                _tool == _PhotoTool.eraser),
                        selectionModeEnabled:
                            !_showOriginal && _tool == _PhotoTool.select,
                        textModeEnabled:
                            !_showOriginal && _tool == _PhotoTool.text,
                        eraserEnabled:
                            !_showOriginal && _tool == _PhotoTool.eraser,
                        eraserRadiusNormalized:
                            (_eraserWidth / 1400).clamp(0.004, 0.06),
                        selectedStrokeId: _showOriginal ? null : _selectedId,
                        selectedPinId: null,
                        pendingDirectionPinId: null,
                        onAddPin: (_) {},
                        onPinTap: (_) {},
                        onDirectionChanged: (_, __) {},
                        onPinMoveStart: (_) {},
                        onPinMoveUpdate: (_, __) {},
                        onPinMoveEnd: (_, __) {},
                        onPinMoveCancel: (_) {},
                        onStrokeStart: _startStroke,
                        onStrokeUpdate: _updateStroke,
                        onStrokeEnd: _endStroke,
                        onCanvasTap: _canvasTap,
                      ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Container(
            height: 82,
            color: const Color(0xFF071D35),
            child: Row(
              children: <Widget>[
                _toolButton(_PhotoTool.select, Icons.select_all_rounded, '選択'),
                _toolButton(_PhotoTool.pen, Icons.edit_rounded, 'ペン'),
                _toolButton(_PhotoTool.shape, Icons.category_outlined, '図形'),
                _toolButton(_PhotoTool.text, Icons.text_fields_rounded, 'テキスト'),
                _toolButton(
                    _PhotoTool.eraser, Icons.auto_fix_off_rounded, '消しゴム'),
                Expanded(
                  child: IconButton(
                    onPressed:
                        _showOriginal || _undo.isEmpty ? null : _undoAction,
                    tooltip: '戻る',
                    icon: const Icon(Icons.undo_rounded),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    onPressed:
                        _showOriginal || _redo.isEmpty ? null : _redoAction,
                    tooltip: 'やり直し',
                    icon: const Icon(Icons.redo_rounded),
                  ),
                ),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _finish,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: const Text('完了'),
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
