import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/photo_data.dart';

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({
    super.key,
    required this.pinNumber,
    required this.initialPhotoCount,
    required this.initialPhotos,
    required this.onCaptured,
  });

  final int pinNumber;
  final int initialPhotoCount;
  final List<PhotoData> initialPhotos;

  /// Saves the original JPEG and returns the separately generated thumbnail.
  ///
  /// The camera screen serializes calls to this callback. This lets the next
  /// picture be taken while the previous original/thumbnail is being stored,
  /// without allowing photo numbers to race each other.
  final Future<PhotoData?> Function(Uint8List bytes) onCaptured;

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraThumbnail {
  const _CameraThumbnail({
    required this.id,
    required this.bytes,
    this.isPending = false,
  });

  final String id;
  final Uint8List bytes;
  final bool isPending;

  _CameraThumbnail copyWith({
    Uint8List? bytes,
    bool? isPending,
  }) {
    return _CameraThumbnail(
      id: id,
      bytes: bytes ?? this.bytes,
      isPending: isPending ?? this.isPending,
    );
  }
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  static const Duration _thumbnailMotionDuration = Duration(milliseconds: 420);
  static const double _thumbnailWidth = 112;
  static const double _thumbnailHeight = 78;
  static const double _thumbnailGap = 10;

  CameraController? _controller;
  bool _initializing = true;
  bool _takingPicture = false;
  bool _closing = false;
  bool _allowPop = false;
  bool _changingFlash = false;
  bool _flashAvailable = false;
  String? _error;
  FlashMode _flashMode = FlashMode.off;
  double _zoom = 1;
  double _minZoom = 1;
  double _maxZoom = 1;
  late int _photoCount;
  late List<_CameraThumbnail> _recentPhotos;
  String? _emphasizedThumbnailId;
  Future<void> _saveTail = Future<void>.value();
  Future<void>? _activeCapture;
  Timer? _focusIndicatorTimer;
  Offset? _focusPoint;
  bool _focusIndicatorVisible = false;
  int _focusIndicatorRevision = 0;

  @override
  void initState() {
    super.initState();
    _photoCount = widget.initialPhotoCount;
    _recentPhotos = widget.initialPhotos.reversed
        .take(3)
        .map(
          (photo) => _CameraThumbnail(
            id: photo.id,
            bytes: photo.bytes,
          ),
        )
        .toList(growable: true);
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('no-camera', '利用できるカメラがありません。');
      }

      CameraDescription? firstBackCamera;
      CameraDescription? wideBackCamera;
      for (final camera in cameras) {
        if (camera.lensDirection == CameraLensDirection.back) {
          firstBackCamera ??= camera;
          if (camera.lensType == CameraLensType.wide) {
            wideBackCamera = camera;
            break;
          }
        }
      }
      final CameraDescription selected =
          wideBackCamera ?? firstBackCamera ?? cameras.first;

      final controller = CameraController(
        selected,
        ResolutionPreset.max,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();

      bool flashAvailable = false;
      FlashMode initialFlashMode = FlashMode.off;
      try {
        await controller.setFlashMode(FlashMode.auto);
        flashAvailable = true;
        initialFlashMode = FlashMode.auto;
      } catch (autoError) {
        try {
          await controller.setFlashMode(FlashMode.off);
          flashAvailable = true;
        } catch (offError) {
          // Cameras without flash hardware can still be used normally.
          debugPrint(
            'Flash unavailable for ${selected.lensType}: '
            'AUTO=$autoError, OFF=$offError',
          );
        }
      }

      double minZoom = 1;
      double maxZoom = 1;
      try {
        minZoom = await controller.getMinZoomLevel();
        maxZoom = await controller.getMaxZoomLevel();
      } catch (_) {
        // Some camera backends do not expose a zoom range.
      }

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _minZoom = minZoom;
        _maxZoom = maxZoom < minZoom ? minZoom : maxZoom;
        _zoom = minZoom;
        _flashAvailable = flashAvailable;
        _flashMode = initialFlashMode;
        _initializing = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'カメラを起動できませんでした。\n$error';
        _initializing = false;
      });
    }
  }

  @override
  void dispose() {
    _focusIndicatorTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _requestCapture() async {
    if (_activeCapture != null || _closing) return;

    final Future<void> operation = _takePicture();
    _activeCapture = operation;
    try {
      await operation;
    } finally {
      if (identical(_activeCapture, operation)) {
        _activeCapture = null;
      }
    }
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _takingPicture ||
        _closing) {
      return;
    }

    setState(() => _takingPicture = true);
    try {
      final XFile file = await controller.takePicture();

      // AVCapturePhotoOutput already plays the system shutter sound on iOS.
      // Adding a Flutter click there makes the feedback sound roughly twice as
      // loud. Other platforms keep the explicit click as a fallback.
      if (defaultTargetPlatform != TargetPlatform.iOS) {
        unawaited(SystemSound.play(SystemSoundType.click));
      }
      final Uint8List bytes = await file.readAsBytes();

      final String pendingId =
          'pending-${DateTime.now().microsecondsSinceEpoch}';
      if (mounted) {
        setState(() {
          _photoCount += 1;
          _emphasizedThumbnailId = pendingId;
          _recentPhotos.insert(
            0,
            _CameraThumbnail(
              id: pendingId,
              bytes: bytes,
              isPending: true,
            ),
          );
          if (_recentPhotos.length > 3) {
            _recentPhotos.removeRange(3, _recentPhotos.length);
          }
        });

        // The newest image starts slightly larger, then settles into the
        // left-most slot while older thumbnails slide to the right.
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 36), () {
            if (mounted && _emphasizedThumbnailId == pendingId) {
              setState(() => _emphasizedThumbnailId = null);
            }
          }),
        );
      }

      _queueOriginalSave(pendingId, bytes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('撮影できませんでした：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _takingPicture = false);
    }
  }

  void _queueOriginalSave(String pendingId, Uint8List bytes) {
    _saveTail = _saveTail.then((_) async {
      PhotoData? savedPhoto;
      Object? saveError;
      try {
        savedPhoto = await widget.onCaptured(bytes);
        if (savedPhoto == null) {
          throw StateError('写真の保存結果を取得できませんでした。');
        }
      } catch (error) {
        saveError = error;
      }

      if (!mounted) return;

      final PhotoData? result = savedPhoto;
      setState(() {
        final int index =
            _recentPhotos.indexWhere((photo) => photo.id == pendingId);

        if (result != null) {
          if (index >= 0) {
            _recentPhotos[index] = _recentPhotos[index].copyWith(
              bytes: result.bytes,
              isPending: false,
            );
          }
        } else {
          if (index >= 0) {
            _recentPhotos.removeAt(index);
          }
          _photoCount = (_photoCount - 1).clamp(0, 1 << 30).toInt();
        }
      });

      if (saveError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('写真を保存できませんでした：$saveError')),
        );
      }
    }).catchError((Object error, StackTrace stackTrace) {
      // Keep the serial queue usable after an unexpected storage/UI error.
      if (!mounted) return;
      setState(() {
        final int index =
            _recentPhotos.indexWhere((photo) => photo.id == pendingId);
        if (index >= 0) {
          _recentPhotos.removeAt(index);
        }
        _photoCount = (_photoCount - 1).clamp(0, 1 << 30).toInt();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('写真を保存できませんでした：$error')),
      );
    });
  }

  Future<void> _closeCamera() async {
    if (_closing) return;
    setState(() => _closing = true);

    try {
      await _activeCapture;
      await _saveTail;
    } finally {
      if (mounted) {
        setState(() => _allowPop = true);
        await Future<void>.delayed(Duration.zero);
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    }
  }

  Future<void> _selectFlashMode(FlashMode requestedMode) async {
    final controller = _controller;
    if (controller == null || !_flashAvailable || _closing || _changingFlash) {
      return;
    }

    final FlashMode selectedMode =
        _flashMode == FlashMode.torch ? FlashMode.always : _flashMode;
    if (selectedMode == requestedMode) return;

    setState(() => _changingFlash = true);
    try {
      FlashMode appliedMode = requestedMode;
      if (requestedMode == FlashMode.always) {
        try {
          await controller.setFlashMode(FlashMode.always);
        } catch (_) {
          // A few devices expose the LED only as a continuous torch.
          await controller.setFlashMode(FlashMode.torch);
          appliedMode = FlashMode.torch;
        }
      } else {
        await controller.setFlashMode(requestedMode);
      }

      if (mounted) setState(() => _flashMode = appliedMode);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'この端末ではフラッシュ${_flashLabelFor(requestedMode)}を利用できません。',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _changingFlash = false);
    }
  }

  Future<void> _changeZoom(double delta) async {
    final controller = _controller;
    if (controller == null || _maxZoom <= _minZoom || _closing) return;

    final next = (_zoom + delta).clamp(_minZoom, _maxZoom).toDouble();
    try {
      await controller.setZoomLevel(next);
      if (mounted) setState(() => _zoom = next);
    } catch (_) {
      // Unsupported devices keep the current zoom.
    }
  }

  Future<void> _focusAt(Offset localPosition, Size previewSize) async {
    final controller = _controller;
    if (controller == null ||
        _closing ||
        previewSize.width <= 0 ||
        previewSize.height <= 0) {
      return;
    }

    final Offset point = Offset(
      (localPosition.dx / previewSize.width).clamp(0.0, 1.0),
      (localPosition.dy / previewSize.height).clamp(0.0, 1.0),
    );

    _focusIndicatorTimer?.cancel();
    if (mounted) {
      setState(() {
        _focusPoint = point;
        _focusIndicatorVisible = true;
        _focusIndicatorRevision += 1;
      });
      _focusIndicatorTimer = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _focusIndicatorVisible = false);
      });
    }

    bool adjusted = false;
    if (controller.value.focusPointSupported) {
      try {
        await controller.setFocusPoint(point);
        adjusted = true;
      } catch (_) {
        // Exposure may still support selecting a point.
      }
    }
    if (controller.value.exposurePointSupported) {
      try {
        await controller.setExposurePoint(point);
        adjusted = true;
      } catch (_) {
        // Focus may already have succeeded.
      }
    }

    if (!adjusted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この端末ではタップによるピント調整を利用できません。')),
      );
    }
  }

  Widget _buildCameraPreview(CameraController controller) {
    return Center(
      child: CameraPreview(
        controller,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final Size previewSize = constraints.biggest;
            final Offset? focusPoint = _focusPoint;
            final double maxIndicatorLeft =
                previewSize.width > 60 ? previewSize.width - 60 : 0;
            final double maxIndicatorTop =
                previewSize.height > 60 ? previewSize.height - 60 : 0;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => unawaited(
                _focusAt(details.localPosition, previewSize),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (focusPoint != null)
                    Positioned(
                      left: (focusPoint.dx * previewSize.width - 30)
                          .clamp(0.0, maxIndicatorLeft),
                      top: (focusPoint.dy * previewSize.height - 30)
                          .clamp(0.0, maxIndicatorTop),
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: _focusIndicatorVisible ? 1 : 0,
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey(_focusIndicatorRevision),
                            duration: const Duration(milliseconds: 240),
                            tween: Tween<double>(begin: 1.3, end: 1),
                            builder: (context, scale, child) =>
                                Transform.scale(scale: scale, child: child),
                            child: Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0xFFFFD54F),
                                  width: 2.2,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: Container(
                                  width: 5,
                                  height: 5,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFFFD54F),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _flashLabelFor(FlashMode mode) => switch (mode) {
        FlashMode.auto => 'AUTO',
        FlashMode.always || FlashMode.torch => 'ON',
        _ => 'OFF',
      };

  String get _flashLabel => _flashLabelFor(_flashMode);

  FlashMode get _selectedFlashMenuMode =>
      _flashMode == FlashMode.torch ? FlashMode.always : _flashMode;

  IconData get _flashIcon => switch (_selectedFlashMenuMode) {
        FlashMode.auto => Icons.flash_auto_rounded,
        FlashMode.off => Icons.flash_off_rounded,
        _ => Icons.flash_on_rounded,
      };

  Widget _buildFlashSelector() {
    return PopupMenuButton<FlashMode>(
      enabled: _flashAvailable && !_closing && !_changingFlash,
      tooltip: _flashAvailable ? 'フラッシュ設定' : 'このカメラではフラッシュを利用できません',
      initialValue: _selectedFlashMenuMode,
      onSelected: (mode) => unawaited(_selectFlashMode(mode)),
      itemBuilder: (context) => [
        CheckedPopupMenuItem<FlashMode>(
          value: FlashMode.auto,
          checked: _selectedFlashMenuMode == FlashMode.auto,
          child: const Text('AUTO（自動）'),
        ),
        CheckedPopupMenuItem<FlashMode>(
          value: FlashMode.always,
          checked: _selectedFlashMenuMode == FlashMode.always,
          child: const Text('ON（常時発光）'),
        ),
        CheckedPopupMenuItem<FlashMode>(
          value: FlashMode.off,
          checked: _selectedFlashMenuMode == FlashMode.off,
          child: const Text('OFF'),
        ),
      ],
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: (_changingFlash || !_flashAvailable) ? 0.55 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_flashAvailable ? _flashIcon : Icons.flash_off_rounded),
              const SizedBox(width: 8),
              Text(_flashAvailable ? _flashLabel : 'フラッシュなし'),
              if (_flashAvailable) ...[
                const SizedBox(width: 3),
                const Icon(Icons.arrow_drop_down_rounded),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        _CameraRoundButton(
          tooltip: '図面へ戻る',
          onPressed: _closing ? null : _closeCamera,
          child: _closing
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.arrow_back_rounded, size: 30),
        ),
        const Spacer(),
        if (_flashAvailable) ...[
          _buildFlashSelector(),
          const SizedBox(width: 12),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on_rounded, size: 22),
              const SizedBox(width: 5),
              Text(
                'ピン ${widget.pinNumber}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                color: Colors.white24,
              ),
              const Icon(Icons.photo_camera_rounded, size: 21),
              const SizedBox(width: 6),
              Text(
                '$_photoCount枚',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThumbnailStrip() {
    final double stripWidth = _thumbnailWidth * 3 + _thumbnailGap * 2;

    return SizedBox(
      width: stripWidth,
      height: _thumbnailHeight + 18,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int index = 0; index < _recentPhotos.length; index++)
            AnimatedPositioned(
              key: ValueKey(_recentPhotos[index].id),
              duration: _thumbnailMotionDuration,
              curve: Curves.easeOutCubic,
              left: index * (_thumbnailWidth + _thumbnailGap),
              bottom: 0,
              child: AnimatedScale(
                duration: _thumbnailMotionDuration,
                curve: Curves.easeOutCubic,
                scale: _emphasizedThumbnailId == _recentPhotos[index].id
                    ? 1.14
                    : 1,
                alignment: Alignment.bottomLeft,
                child: _CameraThumbnailCard(
                  bytes: _recentPhotos[index].bytes,
                  isPending: _recentPhotos[index].isPending,
                  width: _thumbnailWidth,
                  height: _thumbnailHeight,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_closeCamera());
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (_initializing) {
                return const Center(child: CircularProgressIndicator());
              }
              if (_error != null || _controller == null) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error ?? 'カメラを起動できませんでした。',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: _closeCamera,
                          child: const Text('戻る'),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return Stack(
                fit: StackFit.expand,
                children: [
                  _buildCameraPreview(_controller!),
                  Positioned(
                    left: 18,
                    top: 16,
                    right: 18,
                    child: _buildTopBar(),
                  ),
                  Positioned(
                    right: 30,
                    top: constraints.maxHeight / 2 - 51,
                    child: Semantics(
                      button: true,
                      label: '撮影',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: (_takingPicture || _closing)
                            ? null
                            : _requestCapture,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 120),
                          opacity: _closing ? 0.45 : 1,
                          child: Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 6),
                              color: Colors.white24,
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black38,
                                  blurRadius: 12,
                                  offset: Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Center(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 110),
                                width: _takingPicture ? 56 : 66,
                                height: _takingPicture ? 56 : 66,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 45,
                    top: constraints.maxHeight / 2 + 60,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (details) {
                        _changeZoom(-details.delta.dy * 0.025);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Text(
                          '${_zoom.toStringAsFixed(1)}×',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 22,
                    bottom: 20,
                    child: _buildThumbnailStrip(),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CameraRoundButton extends StatelessWidget {
  const _CameraRoundButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 52,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _CameraThumbnailCard extends StatelessWidget {
  const _CameraThumbnailCard({
    required this.bytes,
    required this.isPending,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final bool isPending;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isPending ? Colors.white : Colors.white70,
          width: isPending ? 2.4 : 1.5,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              cacheWidth: 360,
            ),
            if (isPending)
              Positioned(
                right: 7,
                top: 7,
                child: Container(
                  width: 16,
                  height: 16,
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const CircularProgressIndicator(
                    strokeWidth: 1.7,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
