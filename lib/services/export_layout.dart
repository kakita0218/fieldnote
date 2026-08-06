import '../models/drawing_stroke.dart';
import '../models/pin_data.dart';

List<PinData> pinsInExportOrder(Iterable<PinData> pins) {
  return List<PinData>.of(pins)
    ..sort((PinData first, PinData second) {
      final int pageOrder = first.pageNumber.compareTo(second.pageNumber);
      return pageOrder != 0 ? pageOrder : first.number.compareTo(second.number);
    });
}

Map<String, int> buildExportPinNumbers(Iterable<PinData> pins) {
  final List<PinData> sorted = pinsInExportOrder(pins);
  return <String, int>{
    for (int index = 0; index < sorted.length; index++)
      sorted[index].id: index + 1,
  };
}

Set<int> buildAnnotatedPageNumbers({
  required Iterable<PinData> pins,
  required Map<int, List<DrawingStroke>> strokesByPage,
}) {
  final Set<int> pages = <int>{for (final PinData pin in pins) pin.pageNumber};
  for (final MapEntry<int, List<DrawingStroke>> entry
      in strokesByPage.entries) {
    if (entry.value.any(
      (DrawingStroke stroke) =>
          stroke.kind != DrawingKind.text || stroke.text.trim().isNotEmpty,
    )) {
      pages.add(entry.key);
    }
  }
  return pages;
}
