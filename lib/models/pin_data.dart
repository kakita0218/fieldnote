class PinData {
  const PinData({
    required this.id,
    required this.number,
    required this.pageNumber,
    required this.xRatio,
    required this.yRatio,
    this.directionDegrees = 0,
    this.photoCount = 0,
    this.note = '',
    this.colorValue = 0xFF1976D2,
    this.boardEnabled = false,
    this.boardTemplateId = 'core',
    this.boardShootingLocation = '',
    this.boardCoreStep = 0,
    this.boardChippingStep = 0,
    this.boardAsbestosStep = 0,
    this.boardPositionId = 'bottomLeft',
  });

  final String id;
  final int number;
  final int pageNumber;
  final double xRatio;
  final double yRatio;
  final double directionDegrees;
  final int photoCount;
  final String note;
  final bool boardEnabled;
  final String boardTemplateId;
  final String boardShootingLocation;
  final int boardCoreStep;
  final int boardChippingStep;
  final int boardAsbestosStep;
  final String boardPositionId;

  /// ARGB value of the pin color. Kept as an int so the model stays
  /// independent from Flutter UI classes and remains easy to serialize.
  final int colorValue;

  PinData copyWith({
    String? id,
    int? number,
    int? pageNumber,
    double? xRatio,
    double? yRatio,
    double? directionDegrees,
    int? photoCount,
    String? note,
    int? colorValue,
    bool? boardEnabled,
    String? boardTemplateId,
    String? boardShootingLocation,
    int? boardCoreStep,
    int? boardChippingStep,
    int? boardAsbestosStep,
    String? boardPositionId,
  }) {
    return PinData(
      id: id ?? this.id,
      number: number ?? this.number,
      pageNumber: pageNumber ?? this.pageNumber,
      xRatio: xRatio ?? this.xRatio,
      yRatio: yRatio ?? this.yRatio,
      directionDegrees: directionDegrees ?? this.directionDegrees,
      photoCount: photoCount ?? this.photoCount,
      note: note ?? this.note,
      colorValue: colorValue ?? this.colorValue,
      boardEnabled: boardEnabled ?? this.boardEnabled,
      boardTemplateId: boardTemplateId ?? this.boardTemplateId,
      boardShootingLocation:
          boardShootingLocation ?? this.boardShootingLocation,
      boardCoreStep: boardCoreStep ?? this.boardCoreStep,
      boardChippingStep: boardChippingStep ?? this.boardChippingStep,
      boardAsbestosStep: boardAsbestosStep ?? this.boardAsbestosStep,
      boardPositionId: boardPositionId ?? this.boardPositionId,
    );
  }
}
