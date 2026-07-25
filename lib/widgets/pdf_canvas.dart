import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import '../models/pin_data.dart';
import 'pin_layer.dart';

class PdfCanvas extends StatelessWidget {
  const PdfCanvas({
    super.key,
    required this.controller,
    required this.currentPage,
    required this.pins,
    required this.selectedPinId,
    required this.pendingDirectionPinId,
    required this.pinMode,
    required this.onAddPin,
    required this.onSelectPin,
    required this.onDirectionChanged,
    required this.onDocumentLoaded,
    required this.onPageChanged,
  });

  final PdfControllerPinch controller;
  final int currentPage;
  final List<PinData> pins;
  final String? selectedPinId;
  final String? pendingDirectionPinId;
  final bool pinMode;
  final ValueChanged<Offset> onAddPin;
  final ValueChanged<PinData> onSelectPin;
  final void Function(PinData pin, double directionDegrees)
      onDirectionChanged;
  final void Function(PdfDocument document) onDocumentLoaded;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: PdfViewPinch(
            controller: controller,
            minScale: 1,
            maxScale: 10,
            onDocumentLoaded: onDocumentLoaded,
            onPageChanged: onPageChanged,
          ),
        ),
        Positioned.fill(
          child: PinLayer(
            controller: controller,
            currentPage: currentPage,
            pins: pins.where((e) => e.pageNumber == currentPage).toList(),
            pinModeEnabled: pinMode,
            selectedPinId: selectedPinId,
            pendingDirectionPinId: pendingDirectionPinId,
            onAddPin: onAddPin,
            onPinTap: onSelectPin,
            onDirectionChanged: onDirectionChanged,
          ),
        ),
      ],
    );
  }
}
