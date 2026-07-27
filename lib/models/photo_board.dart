enum PhotoBoardTemplate {
  core('core', 'コア', <String>[
    '施工前',
    '鉄筋探査状況',
    'コア採取状況',
    'コア採取',
    '無収縮モルタル充填完了',
    '復旧完了',
  ]),
  chipping('chipping', '斫り', <String>[
    '施工前',
    '鉄筋探査状況',
    '斫り状況',
    '斫り完了',
    '無収縮モルタル充填完了',
    '復旧完了',
  ]),
  asbestos('asbestos', 'アスベスト', <String>[
    '採取前',
    '寸法確認(1)',
    '寸法確認(2)',
    '湿潤状況',
    '採取状況',
    '塗装完了',
  ]);

  const PhotoBoardTemplate(this.id, this.label, this.steps);

  final String id;
  final String label;
  final List<String> steps;

  static PhotoBoardTemplate fromId(String? id) {
    return PhotoBoardTemplate.values.firstWhere(
      (PhotoBoardTemplate value) => value.id == id,
      orElse: () => PhotoBoardTemplate.core,
    );
  }
}

class PhotoBoardConfig {
  const PhotoBoardConfig({
    required this.enabled,
    required this.businessName,
    required this.facilityName,
    required this.shootingLocation,
    required this.template,
    required this.templateSteps,
  });

  final bool enabled;
  final String businessName;
  final String facilityName;
  final String shootingLocation;
  final PhotoBoardTemplate template;
  final Map<PhotoBoardTemplate, int> templateSteps;

  int get stepIndex {
    final int value = templateSteps[template] ?? 0;
    return value.clamp(0, template.steps.length - 1);
  }

  String get stepLabel => template.steps[stepIndex];

  PhotoBoardConfig copyWith({
    bool? enabled,
    String? businessName,
    String? facilityName,
    String? shootingLocation,
    PhotoBoardTemplate? template,
    Map<PhotoBoardTemplate, int>? templateSteps,
  }) {
    return PhotoBoardConfig(
      enabled: enabled ?? this.enabled,
      businessName: businessName ?? this.businessName,
      facilityName: facilityName ?? this.facilityName,
      shootingLocation: shootingLocation ?? this.shootingLocation,
      template: template ?? this.template,
      templateSteps: Map<PhotoBoardTemplate, int>.from(
        templateSteps ?? this.templateSteps,
      ),
    );
  }

  PhotoBoardConfig withSelectedStep(int step) {
    final Map<PhotoBoardTemplate, int> next =
        Map<PhotoBoardTemplate, int>.from(templateSteps);
    next[template] = step.clamp(0, template.steps.length - 1);
    return copyWith(templateSteps: next);
  }
}
