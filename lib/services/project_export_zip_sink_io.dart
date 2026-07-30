import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_saver/file_saver.dart';
import 'package:path_provider/path_provider.dart';

class ProjectExportZipSink {
  ProjectExportZipSink._(this._file, this.output);

  final File _file;
  final OutputFileStream output;
  bool _closed = false;

  static Future<ProjectExportZipSink> create() async {
    final Directory temporaryDirectory = await getTemporaryDirectory();
    final File file = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      'fieldnote-export-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    return ProjectExportZipSink._(
      file,
      OutputFileStream(file.path),
    );
  }

  Future<void> _closeOutput() async {
    if (_closed) return;
    _closed = true;
    await output.close();
  }

  Future<void> save(String name) async {
    await _closeOutput();
    await FileSaver.instance.saveFile(
      name: name,
      filePath: _file.path,
      fileExtension: 'zip',
      mimeType: MimeType.zip,
    );
  }

  Future<void> dispose() async {
    await _closeOutput();
    if (await _file.exists()) {
      await _file.delete();
    }
  }
}
