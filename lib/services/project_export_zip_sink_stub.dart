import 'package:archive/archive.dart';
import 'package:file_saver/file_saver.dart';

class ProjectExportZipSink {
  ProjectExportZipSink._(this.output);

  final OutputMemoryStream output;

  static Future<ProjectExportZipSink> create() async {
    return ProjectExportZipSink._(OutputMemoryStream());
  }

  Future<void> save(String name) async {
    await FileSaver.instance.saveFile(
      name: name,
      bytes: output.getBytes(),
      fileExtension: 'zip',
      mimeType: MimeType.zip,
    );
  }

  Future<void> dispose() async {
    output.clear();
  }
}
