class ProjectPdfDocument {
  const ProjectPdfDocument({
    required this.id,
    required this.name,
    required this.folderName,
    required this.pageCount,
    this.currentPage = 1,
  });

  final String id;
  final String name;
  final String folderName;
  final int pageCount;
  final int currentPage;

  ProjectPdfDocument copyWith({
    String? name,
    String? folderName,
    int? pageCount,
    int? currentPage,
  }) {
    return ProjectPdfDocument(
      id: id,
      name: name ?? this.name,
      folderName: folderName ?? this.folderName,
      pageCount: pageCount ?? this.pageCount,
      currentPage: currentPage ?? this.currentPage,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'folderName': folderName,
        'pageCount': pageCount,
        'currentPage': currentPage,
      };

  factory ProjectPdfDocument.fromJson(Map<String, dynamic> json) {
    final String id = json['id']?.toString() ?? 'main';
    final String name = json['name']?.toString() ?? '図面.pdf';
    return ProjectPdfDocument(
      id: id,
      name: name,
      folderName: json['folderName']?.toString() ?? name,
      pageCount: (json['pageCount'] as num?)?.toInt() ?? 0,
      currentPage: (json['currentPage'] as num?)?.toInt() ?? 1,
    );
  }
}
