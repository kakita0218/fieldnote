import 'package:flutter/material.dart';

import '../models/photo_data.dart';
import '../models/pin_data.dart';
import '../theme/app_colors.dart';

class PinSidePanel extends StatelessWidget {
  const PinSidePanel({
    super.key,
    required this.pin,
    required this.photos,
    required this.noteController,
    required this.onClose,
    required this.onDelete,
    required this.onNoteChanged,
    required this.onAddPhotos,
    required this.onShowAllPhotos,
    required this.directionEditing,
    required this.onChangeDirection,
  });

  final PinData pin;
  final List<PhotoData> photos;
  final TextEditingController noteController;
  final VoidCallback onClose;
  final VoidCallback onDelete;
  final ValueChanged<String> onNoteChanged;
  final VoidCallback onAddPhotos;
  final VoidCallback onShowAllPhotos;
  final bool directionEditing;
  final VoidCallback onChangeDirection;

  @override
  Widget build(BuildContext context) {
    final String pinNumber = pin.number.toString();
    final List<PhotoData> visiblePhotos = photos.take(6).toList();

    return Material(
      color: AppColors.panel,
      elevation: 14,
      child: Column(
        children: [
          Container(
            height: 58,
            padding: const EdgeInsets.only(
              left: 18,
              right: 6,
            ),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AppColors.border,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'ピン $pinNumber',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onClose,
                  tooltip: '閉じる',
                  icon: const Icon(
                    Icons.close_rounded,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: onChangeDirection,
                    icon: Icon(
                      directionEditing
                          ? Icons.close_rounded
                          : Icons.navigation_rounded,
                    ),
                    label: Text(
                      directionEditing ? '方向変更をキャンセル' : 'ピンの方向を変更',
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                  ),
                  if (directionEditing) ...[
                    const SizedBox(height: 8),
                    const Text(
                      '図面上の、矢印を向けたい場所をタップしてください。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.accent,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '写真（${photos.length}）',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: onAddPhotos,
                        icon: const Icon(
                          Icons.add_rounded,
                          size: 20,
                        ),
                        label: const Text('追加'),
                      ),
                    ],
                  ),
                  if (visiblePhotos.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: visiblePhotos.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 1,
                      ),
                      itemBuilder: (context, index) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            visiblePhotos[index].bytes,
                            fit: BoxFit.cover,
                          ),
                        );
                      },
                    ),
                    if (photos.length > 6) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: onShowAllPhotos,
                          child: const Text(
                            'すべての写真を見る →',
                          ),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 26),
                  const Text(
                    'メモ',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: noteController,
                    minLines: 5,
                    maxLines: 10,
                    onChanged: onNoteChanged,
                    decoration: const InputDecoration(
                      hintText: 'メモを入力',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 28),
                  OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                    ),
                    label: const Text('ピンを削除'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
