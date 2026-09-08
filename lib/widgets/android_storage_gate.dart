import 'package:flutter/material.dart';

import '../services/android_external_storage_service.dart';
import '../theme/app_colors.dart';

class AndroidStorageGate extends StatefulWidget {
  const AndroidStorageGate({super.key, required this.child});

  final Widget child;

  @override
  State<AndroidStorageGate> createState() => _AndroidStorageGateState();
}

class _AndroidStorageGateState extends State<AndroidStorageGate> {
  bool _loading = true;
  bool _selecting = false;
  bool _hasAccess = false;

  @override
  void initState() {
    super.initState();
    _checkAccess();
  }

  Future<void> _checkAccess() async {
    final bool access = await AndroidExternalStorageService.hasAccess();
    if (!mounted) return;
    setState(() {
      _hasAccess = access;
      _loading = false;
    });
  }

  Future<void> _selectDirectory() async {
    if (_selecting) return;
    setState(() => _selecting = true);
    final bool selected = await AndroidExternalStorageService.selectDirectory();
    if (!mounted) return;
    setState(() => _selecting = false);
    if (selected) await _checkAccess();
  }

  @override
  Widget build(BuildContext context) {
    if (!AndroidExternalStorageService.isAvailable || _hasAccess) {
      return widget.child;
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                color: AppColors.panel,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.create_new_folder_rounded,
                        color: AppColors.accent,
                        size: 64,
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'FieldNoteの保存先を選択',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '選択した場所にFieldNoteフォルダを作成し、'
                        'PDFと写真を案件・ピンごとに整理します。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed:
                            _loading || _selecting ? null : _selectDirectory,
                        icon: _loading || _selecting
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.folder_open_rounded),
                        label: Text(
                          _selecting ? '選択中…' : '保存先を選択',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
