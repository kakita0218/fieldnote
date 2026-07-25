class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.updatedAt,
    this.pageCount = 0,
    this.photoCount = 0,
    this.pinCount = 0,
  });

  final String id;
  final String name;
  final DateTime updatedAt;
  final int pageCount;
  final int photoCount;
  final int pinCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'updatedAt': updatedAt.toIso8601String(),
        'pageCount': pageCount,
        'photoCount': photoCount,
        'pinCount': pinCount,
      };

  factory ProjectSummary.fromJson(Map<String, dynamic> json) {
    return ProjectSummary(
      id: json['id'] as String,
      name: json['name'] as String? ?? '名称未設定',
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      pageCount: (json['pageCount'] as num?)?.toInt() ?? 0,
      photoCount: (json['photoCount'] as num?)?.toInt() ?? 0,
      pinCount: (json['pinCount'] as num?)?.toInt() ?? 0,
    );
  }
}
