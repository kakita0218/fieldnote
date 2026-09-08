import 'package:fieldnote/models/project_pdf_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PDFごとの名前・フォルダ・ページ位置を保存して復元できる', () {
    const ProjectPdfDocument original = ProjectPdfDocument(
      id: '02_立面図',
      name: '立面図.pdf',
      folderName: '02_立面図',
      pageCount: 8,
      currentPage: 4,
    );

    final ProjectPdfDocument restored =
        ProjectPdfDocument.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.name, original.name);
    expect(restored.folderName, original.folderName);
    expect(restored.pageCount, 8);
    expect(restored.currentPage, 4);
  });
}
