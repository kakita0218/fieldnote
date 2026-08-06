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

enum _PhotoTool { select, pen, shape, text }

enum _PhotoAnnotationTransformKind {
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
  double _textBoxWidthRatio = 0.32;
  DrawingBrush _brush = DrawingBrush.fountain;
  DrawingKind _shapeKind = DrawingKind.line;
  bool _eraserEnabled = false;
  DrawingStroke? _movingAnnotationOriginal;
  Offset? _movingAnnotationGrabOffset;
  DrawingStroke? _transformingAnnotationOriginal;
  _PhotoAnnotationTransformKind? _annotationTransformKind;
  int? _annotationTransformPointIndex;
  Offset? _annotationTransformFixedPoint;
  double? _annotationTransformStartAngle;
  List<DrawingStroke>? _annotationGestureBefore;

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
      _activeStroke = null;
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
    if (_tool == _PhotoTool.pen && _eraserEnabled) {
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
    if (_tool == _PhotoTool.pen && _eraserEnabled) {
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
    final double radius = (_eraserWidth / 1120).clamp(0.006, 0.08);
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
            rotationDegrees: stroke.rotationDegrees,
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

  Future<void> _handleCanvasTapUnified(Offset position) async {
    if (_showOriginal) return;
    if (_tool == _PhotoTool.shape && _shapeKind == DrawingKind.polyline) {
      _addPolylinePoint(position);
      return;
    }
    if (_tool == _PhotoTool.select) {
      setState(() => _selectedId = _annotationAt(position)?.id);
      return;
    }
    if (_tool != _PhotoTool.text) return;
    final DrawingStroke? hit = _annotationAt(position);
    if (hit?.kind == DrawingKind.text) {
      setState(() => _selectedId = hit!.id);
      return;
    }
    DrawingStroke? draft;
    for (final DrawingStroke stroke in _strokes) {
      if (stroke.kind == DrawingKind.text && stroke.text.trim().isEmpty) {
        draft = stroke;
        break;
      }
    }
    if (draft != null) {
      final DrawingStroke existingDraft = draft;
      final int index = _strokes.indexOf(existingDraft);
      setState(() {
        _strokes[index] = existingDraft.copyWith(
          points: <DrawingPoint>[DrawingPoint(position: position)],
        );
        _selectedId = existingDraft.id;
      });
      return;
    }
    final List<DrawingStroke> before = _snapshot();
    final DrawingStroke annotation = DrawingStroke(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      pageNumber: 0,
      points: <DrawingPoint>[DrawingPoint(position: position)],
      width: _width,
      color: _color,
      opacity: _opacity,
      kind: DrawingKind.text,
      fontSize: _fontSize,
      textBoxWidthRatio: _textBoxWidthRatio,
    );
    setState(() {
      _strokes.add(annotation);
      _selectedId = annotation.id;
      _pushUndo(before);
    });
  }

  DrawingStroke? _annotationAt(Offset position) {
    for (final DrawingStroke stroke in _strokes.reversed) {
      if (_strokeTouches(stroke, position, 0.025)) return stroke;
    }
    return null;
  }

  void _addPolylinePoint(Offset position) {
    final DrawingStroke? active = _activeStroke;
    if (active?.kind == DrawingKind.polyline) {
      setState(() => active!.points.add(DrawingPoint(position: position)));
      return;
    }
    final List<DrawingStroke> before = _snapshot();
    final DrawingStroke stroke = DrawingStroke(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      pageNumber: 0,
      points: <DrawingPoint>[DrawingPoint(position: position)],
      width: _width,
      color: _color,
      opacity: _opacity,
      brush: DrawingBrush.ballpoint,
      kind: DrawingKind.polyline,
    );
    setState(() {
      _activeStroke = stroke;
      _strokes.add(stroke);
      _selectedId = stroke.id;
      _pushUndo(before);
    });
  }

  void _finishPolyline() {
    if (_activeStroke?.kind != DrawingKind.polyline) return;
    setState(() => _activeStroke = null);
  }

  Future<void> _handleCanvasDoubleTap(Offset position) async {
    final DrawingStroke? hit = _annotationAt(position);
    if (hit?.kind != DrawingKind.text) return;
    setState(() => _selectedId = hit!.id);
    await _editSelectedText();
  }

  Future<void> _editSelectedText() async {
    final DrawingStroke? selected = _selectedStroke;
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
      _deleteSelected();
    } else if (text != selected.text) {
      _updateSelected(text: text);
    }
  }

  void _deleteSelected() {
    final DrawingStroke? selected = _selectedStroke;
    if (selected == null) return;
    final List<DrawingStroke> before = _snapshot();
    setState(() {
      _strokes.removeWhere((DrawingStroke stroke) => stroke.id == selected.id);
      _selectedId = null;
      _pushUndo(before);
    });
  }

  Size get _annotationEditSize => Size(_aspectRatio * 1000, 1000);

  Offset _annotationPixels(Offset normalized) => Offset(
        normalized.dx * _annotationEditSize.width,
        normalized.dy * _annotationEditSize.height,
      );

  Offset _annotationNormalized(Offset pixels) => Offset(
        (pixels.dx / _annotationEditSize.width).clamp(0.0, 1.0),
        (pixels.dy / _annotationEditSize.height).clamp(0.0, 1.0),
      );

  bool _startAnnotationMove(Offset position) {
    if (_tool != _PhotoTool.select && _tool != _PhotoTool.text) return false;
    final DrawingStroke? hit = _annotationAt(position);
    if (hit == null || hit.points.isEmpty) return false;
    _annotationGestureBefore = _snapshot();
    _movingAnnotationOriginal = hit;
    _movingAnnotationGrabOffset = hit.points.first.position - position;
    setState(() => _selectedId = hit.id);
    return true;
  }

  void _updateAnnotationMove(Offset position) {
    final DrawingStroke? original = _movingAnnotationOriginal;
    final Offset? grabOffset = _movingAnnotationGrabOffset;
    if (original == null || grabOffset == null) return;
    final int index =
        _strokes.indexWhere((DrawingStroke item) => item.id == original.id);
    if (index < 0) return;
    final Offset delta = position + grabOffset - original.points.first.position;
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
    final Offset clamped = Offset(
      delta.dx.clamp(-minX, 1 - maxX),
      delta.dy.clamp(-minY, 1 - maxY),
    );
    setState(() {
      _strokes[index] = original.copyWith(
        points: original.points
            .map((DrawingPoint point) => DrawingPoint(
                  position: point.position + clamped,
                  pressure: point.pressure,
                ))
            .toList(growable: false),
      );
    });
  }

  void _finishAnnotationMove(Offset position) {
    _updateAnnotationMove(position);
    _movingAnnotationOriginal = null;
    _movingAnnotationGrabOffset = null;
    final List<DrawingStroke>? before = _annotationGestureBefore;
    _annotationGestureBefore = null;
    if (before != null) setState(() => _pushUndo(before));
  }

  void _cancelAnnotationMove() {
    _movingAnnotationOriginal = null;
    _movingAnnotationGrabOffset = null;
    final List<DrawingStroke>? before = _annotationGestureBefore;
    _annotationGestureBefore = null;
    if (before != null) {
      setState(() {
        _strokes
          ..clear()
          ..addAll(before);
      });
    }
  }

  bool _startAnnotationTransform(Offset position) {
    if (_tool != _PhotoTool.select && _tool != _PhotoTool.text) return false;
    final DrawingStroke? selected = _selectedStroke;
    if (selected == null || selected.points.isEmpty) return false;
    final Offset pointer = _annotationPixels(position);
    final Size size = _annotationEditSize;
    const double hitRadius = 24;
    _PhotoAnnotationTransformKind? kind;
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
      const List<_PhotoAnnotationTransformKind> kinds =
          <_PhotoAnnotationTransformKind>[
        _PhotoAnnotationTransformKind.textTopLeft,
        _PhotoAnnotationTransformKind.textTopRight,
        _PhotoAnnotationTransformKind.textBottomRight,
        _PhotoAnnotationTransformKind.textBottomLeft,
      ];
      for (int i = 0; i < corners.length; i++) {
        if ((pointer - corners[i]).distance <= hitRadius) {
          kind = kinds[i];
          fixedPoint = corners[(i + 2) % 4];
          break;
        }
      }
    } else if (selected.kind == DrawingKind.rectangle &&
        selected.points.length >= 2) {
      final List<Offset> corners = drawingRectangleCorners(selected, size);
      final Offset rotation = drawingRectangleRotationHandle(selected, size);
      if ((pointer - rotation).distance <= hitRadius + 4) {
        kind = _PhotoAnnotationTransformKind.rectangleRotation;
        final Offset center = Offset.lerp(corners[0], corners[2], 0.5)!;
        _annotationTransformStartAngle =
            math.atan2(pointer.dy - center.dy, pointer.dx - center.dx) -
                selected.rotationDegrees * math.pi / 180;
      } else {
        const List<_PhotoAnnotationTransformKind> kinds =
            <_PhotoAnnotationTransformKind>[
          _PhotoAnnotationTransformKind.rectangleTopLeft,
          _PhotoAnnotationTransformKind.rectangleTopRight,
          _PhotoAnnotationTransformKind.rectangleBottomRight,
          _PhotoAnnotationTransformKind.rectangleBottomLeft,
        ];
        for (int i = 0; i < corners.length; i++) {
          if ((pointer - corners[i]).distance <= hitRadius) {
            kind = kinds[i];
            fixedPoint = corners[(i + 2) % 4];
            break;
          }
        }
      }
    } else if (selected.kind == DrawingKind.line ||
        selected.kind == DrawingKind.polyline) {
      for (int i = 0; i < selected.points.length; i++) {
        if ((pointer - _annotationPixels(selected.points[i].position))
                .distance <=
            hitRadius) {
          kind = _PhotoAnnotationTransformKind.point;
          pointIndex = i;
          break;
        }
      }
    }
    if (kind == null) return false;
    _annotationGestureBefore = _snapshot();
    _transformingAnnotationOriginal = selected;
    _annotationTransformKind = kind;
    _annotationTransformPointIndex = pointIndex;
    _annotationTransformFixedPoint = fixedPoint;
    return true;
  }

  void _updateAnnotationTransform(Offset position) {
    final DrawingStroke? original = _transformingAnnotationOriginal;
    final _PhotoAnnotationTransformKind? kind = _annotationTransformKind;
    if (original == null || kind == null) return;
    final int index =
        _strokes.indexWhere((DrawingStroke item) => item.id == original.id);
    if (index < 0) return;
    final Size size = _annotationEditSize;
    final Offset pointer = _annotationPixels(position);
    DrawingStroke updated = original;
    if (kind == _PhotoAnnotationTransformKind.point) {
      final int pointIndex = _annotationTransformPointIndex ?? -1;
      if (pointIndex < 0 || pointIndex >= original.points.length) return;
      final List<DrawingPoint> points = List<DrawingPoint>.of(original.points);
      points[pointIndex] = DrawingPoint(
        position: position,
        pressure: points[pointIndex].pressure,
      );
      updated = original.copyWith(points: points);
    } else if (kind == _PhotoAnnotationTransformKind.rectangleRotation) {
      final List<Offset> corners = drawingRectangleCorners(original, size);
      final Offset center = Offset.lerp(corners[0], corners[2], 0.5)!;
      updated = original.copyWith(
        rotationDegrees: ((math.atan2(
                      pointer.dy - center.dy,
                      pointer.dx - center.dx,
                    ) -
                    (_annotationTransformStartAngle ?? 0)) *
                180 /
                math.pi) %
            360,
      );
    } else if (kind.name.startsWith('rectangle')) {
      final Offset? fixed = _annotationTransformFixedPoint;
      if (fixed == null) return;
      final double radians = original.rotationDegrees * math.pi / 180;
      final Offset delta = pointer - fixed;
      final double cosine = math.cos(-radians);
      final double sine = math.sin(-radians);
      final Offset local = Offset(
        delta.dx * cosine - delta.dy * sine,
        delta.dx * sine + delta.dy * cosine,
      );
      final double width = math.max(local.dx.abs(), 12);
      final double height = math.max(local.dy.abs(), 12);
      final Offset center = Offset.lerp(fixed, pointer, 0.5)!;
      updated = original.copyWith(points: <DrawingPoint>[
        DrawingPoint(
            position: _annotationNormalized(
          center - Offset(width / 2, height / 2),
        )),
        DrawingPoint(
            position: _annotationNormalized(
          center + Offset(width / 2, height / 2),
        )),
      ]);
    } else {
      final Offset? fixed = _annotationTransformFixedPoint;
      if (fixed == null) return;
      final Rect bounds = drawingStrokeBounds(original, size);
      final Offset dragged = switch (kind) {
        _PhotoAnnotationTransformKind.textTopLeft => bounds.topLeft,
        _PhotoAnnotationTransformKind.textTopRight => bounds.topRight,
        _PhotoAnnotationTransformKind.textBottomRight => bounds.bottomRight,
        _ => bounds.bottomLeft,
      };
      final double distance = (dragged - fixed).distance;
      if (distance <= 0) return;
      final double scale =
          ((pointer - fixed).distance / distance).clamp(0.35, 4.0);
      updated = original.copyWith(
        fontSize: (original.fontSize * scale).clamp(8.0, 128.0),
        textBoxWidthRatio:
            (original.textBoxWidthRatio * scale).clamp(0.12, 0.8),
      );
      final Rect candidateBounds = drawingStrokeBounds(updated, size);
      final Offset targetTopLeft = switch (kind) {
        _PhotoAnnotationTransformKind.textTopLeft =>
          fixed - Offset(candidateBounds.width, candidateBounds.height),
        _PhotoAnnotationTransformKind.textTopRight =>
          Offset(fixed.dx, fixed.dy - candidateBounds.height),
        _PhotoAnnotationTransformKind.textBottomRight => fixed,
        _ => Offset(fixed.dx - candidateBounds.width, fixed.dy),
      };
      final Offset anchor = _annotationPixels(updated.points.first.position) +
          (targetTopLeft - candidateBounds.topLeft);
      updated = updated.copyWith(points: <DrawingPoint>[
        DrawingPoint(
          position: _annotationNormalized(anchor),
          pressure: original.points.first.pressure,
        ),
      ]);
    }
    setState(() => _strokes[index] = updated);
  }

  void _finishAnnotationTransform(Offset position) {
    _updateAnnotationTransform(position);
    _clearTransformState();
    final List<DrawingStroke>? before = _annotationGestureBefore;
    _annotationGestureBefore = null;
    if (before != null) setState(() => _pushUndo(before));
  }

  void _cancelAnnotationTransform() {
    _clearTransformState();
    final List<DrawingStroke>? before = _annotationGestureBefore;
    _annotationGestureBefore = null;
    if (before != null) {
      setState(() {
        _strokes
          ..clear()
          ..addAll(before);
      });
    }
  }

  void _clearTransformState() {
    _transformingAnnotationOriginal = null;
    _annotationTransformKind = null;
    _annotationTransformPointIndex = null;
    _annotationTransformFixedPoint = null;
    _annotationTransformStartAngle = null;
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
    _discardEmptyTextDrafts();
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
    double? fontSize,
    double? textBoxWidthRatio,
    String? text,
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
        fontSize: fontSize,
        textBoxWidthRatio: textBoxWidthRatio,
        text: text,
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
          final double shownWidth = selected?.kind == DrawingKind.text
              ? selected!.fontSize
              : selected?.width ??
                  (_tool == _PhotoTool.pen && _eraserEnabled
                      ? _eraserWidth
                      : _width);
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
                        setState(() {
                          _brush = values.first;
                          _eraserEnabled = false;
                        });
                        updateSheet(() {});
                      },
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          setState(() => _eraserEnabled = !_eraserEnabled);
                          updateSheet(() {});
                        },
                        icon: const Icon(Icons.auto_fix_off_rounded),
                        label: Text(
                          _eraserEnabled ? '消しゴム：ON' : '消しゴム',
                        ),
                      ),
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
                  if (!_eraserEnabled) ...<Widget>[
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      children: _colors.map((Color color) {
                        return InkWell(
                          onTap: () {
                            if (selected != null) {
                              _updateSelected(color: color);
                            } else {
                              setState(() {
                                _color = color;
                                _eraserEnabled = false;
                              });
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
                    _eraserEnabled
                        ? '消しゴムの太さ ${shownWidth.toStringAsFixed(0)}'
                        : selected?.kind == DrawingKind.text
                            ? '文字サイズ ${shownWidth.toStringAsFixed(0)}'
                            : '太さ ${shownWidth.toStringAsFixed(0)}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  Slider(
                    value: shownWidth.clamp(
                      selected?.kind == DrawingKind.text ? 12 : 1,
                      selected?.kind == DrawingKind.text
                          ? 64
                          : _eraserEnabled
                              ? 80
                              : 24,
                    ),
                    min: selected?.kind == DrawingKind.text
                        ? 12
                        : _eraserEnabled
                            ? 6
                            : 1,
                    max: selected?.kind == DrawingKind.text
                        ? 64
                        : _eraserEnabled
                            ? 80
                            : 24,
                    onChanged: (double value) {
                      if (_eraserEnabled) {
                        setState(() => _eraserWidth = value);
                      } else if (selected?.kind == DrawingKind.text) {
                        _updateSelected(fontSize: value);
                      } else if (selected != null) {
                        _updateSelected(width: value);
                      } else {
                        setState(() => _width = value);
                      }
                      updateSheet(() {});
                    },
                  ),
                  if (!_eraserEnabled) ...<Widget>[
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
                  if (_tool == _PhotoTool.text ||
                      selected?.kind == DrawingKind.text) ...<Widget>[
                    if (selected?.kind != DrawingKind.text) ...<Widget>[
                      Text(
                        '文字サイズ ${_fontSize.round()}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      Slider(
                        value: _fontSize.clamp(12, 64),
                        min: 12,
                        max: 64,
                        onChanged: (double value) {
                          setState(() => _fontSize = value);
                          updateSheet(() {});
                        },
                      ),
                    ],
                    Text(
                      'テキスト枠の横幅 '
                      '${((selected?.textBoxWidthRatio ?? _textBoxWidthRatio) * 100).round()}%',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Slider(
                      value: (selected?.textBoxWidthRatio ?? _textBoxWidthRatio)
                          .clamp(0.12, 0.8),
                      min: 0.12,
                      max: 0.8,
                      divisions: 17,
                      onChanged: (double value) {
                        if (selected?.kind == DrawingKind.text) {
                          _updateSelected(textBoxWidthRatio: value);
                        } else {
                          setState(() => _textBoxWidthRatio = value);
                        }
                        updateSheet(() {});
                      },
                    ),
                    if (selected?.kind == DrawingKind.text)
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _editSelectedText();
                        },
                        icon: const Icon(Icons.keyboard_rounded),
                        label: Text(
                          selected!.text.isEmpty ? '文字入力を開始' : '文字を再編集',
                        ),
                      ),
                  ],
                  if (_tool == _PhotoTool.select &&
                      selected != null) ...<Widget>[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _deleteSelected();
                      },
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('選択した注釈を削除'),
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
    _finishPolyline();
    setState(() {
      if (tool != _PhotoTool.text) _discardEmptyTextDrafts();
      _tool = tool;
      if (tool != _PhotoTool.pen) _eraserEnabled = false;
      if (tool != _PhotoTool.select && tool != _PhotoTool.text) {
        _selectedId = null;
      }
    });
  }

  void _discardEmptyTextDrafts() {
    final String? selectedId = _selectedId;
    _strokes.removeWhere(
      (DrawingStroke stroke) =>
          stroke.kind == DrawingKind.text && stroke.text.trim().isEmpty,
    );
    if (selectedId != null &&
        !_strokes.any((DrawingStroke stroke) => stroke.id == selectedId)) {
      _selectedId = null;
    }
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
                                (_tool == _PhotoTool.shape &&
                                    _shapeKind != DrawingKind.polyline)),
                        selectionModeEnabled:
                            !_showOriginal && _tool == _PhotoTool.select,
                        textModeEnabled:
                            !_showOriginal && _tool == _PhotoTool.text,
                        polylineModeEnabled: !_showOriginal &&
                            _tool == _PhotoTool.shape &&
                            _shapeKind == DrawingKind.polyline,
                        eraserEnabled: !_showOriginal &&
                            _tool == _PhotoTool.pen &&
                            _eraserEnabled,
                        eraserRadiusNormalized:
                            (_eraserWidth / 1120).clamp(0.006, 0.08),
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
                        onCanvasTap: _handleCanvasTapUnified,
                        onCanvasDoubleTap: _handleCanvasDoubleTap,
                        onAnnotationMoveStart: _startAnnotationMove,
                        onAnnotationMoveUpdate: _updateAnnotationMove,
                        onAnnotationMoveEnd: _finishAnnotationMove,
                        onAnnotationMoveCancel: _cancelAnnotationMove,
                        onAnnotationTransformStart: _startAnnotationTransform,
                        onAnnotationTransformUpdate: _updateAnnotationTransform,
                        onAnnotationTransformEnd: _finishAnnotationTransform,
                        onAnnotationTransformCancel: _cancelAnnotationTransform,
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
                if (_tool == _PhotoTool.shape &&
                    _shapeKind == DrawingKind.polyline &&
                    _activeStroke?.kind == DrawingKind.polyline)
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _finishPolyline,
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('完了'),
                    ),
                  ),
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
