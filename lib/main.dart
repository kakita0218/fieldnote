import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'models/project_summary.dart';
import 'painters/blueprint_background.dart';
import 'screens/pdf_viewer_screen.dart';
import 'services/project_repository.dart';
import 'theme/app_colors.dart';
import 'widgets/logo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await Hive.initFlutter();
  runApp(const FieldNoteApp());
}

class FieldNoteApp extends StatelessWidget {
  const FieldNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FieldNote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.dark,
        ),
        textTheme: Theme.of(context).textTheme.apply(
              bodyColor: AppColors.textPrimary,
              displayColor: AppColors.textPrimary,
            ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ProjectSummary> _projects = const <ProjectSummary>[];
  bool _loading = true;
  bool _showAllProjects = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final List<ProjectSummary> projects =
        await ProjectRepository.listProjects();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _loading = false;
      if (_projects.length <= 4) _showAllProjects = false;
    });
  }

  Future<String?> _askName({String initial = ''}) async {
    final TextEditingController controller =
        TextEditingController(text: initial);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xFF07182D),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.border),
        ),
        title: Text(initial.isEmpty ? '新規プロジェクト' : '案件名を変更'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '案件名',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (String value) =>
              Navigator.pop(context, value.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('決定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _newProject() async {
    final String? name = await _askName();
    if (name == null || !mounted) return;
    final String id = DateTime.now().microsecondsSinceEpoch.toString();
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PdfViewerScreen(
          projectId: id,
          projectName: name,
          isNewProject: true,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _open(
    ProjectSummary project, {
    bool exportOnOpen = false,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PdfViewerScreen(
          projectId: project.id,
          projectName: project.name,
          exportOnOpen: exportOnOpen,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _rename(ProjectSummary project) async {
    final String? name = await _askName(initial: project.name);
    if (name == null) return;
    await ProjectRepository.renameProject(project.id, name);
    await _reload();
  }

  Future<void> _delete(ProjectSummary project) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xFF07182D),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.border),
        ),
        title: const Text('案件を削除'),
        content: Text(
          '「${project.name}」を削除しますか？\n'
          '書き出していない写真やメモも削除されます。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ProjectRepository.deleteProject(project.id);
      await _reload();
    }
  }

  List<ProjectSummary> get _visibleProjects {
    if (_showAllProjects || _projects.length <= 4) return _projects;
    return _projects.take(4).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: BlueprintBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              if (constraints.maxHeight > constraints.maxWidth) {
                return const _LandscapeOnlyNotice();
              }

              final double topAreaHeight =
                  (constraints.maxHeight * 0.46).clamp(350.0, 455.0).toDouble();

              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(42, 18, 42, 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        SizedBox(
                          height: topAreaHeight,
                          child: Stack(
                            children: <Widget>[
                              const Positioned(
                                left: 0,
                                top: 16,
                                child: FieldNoteLogo(
                                  markSize: 92,
                                  fontSize: 48,
                                ),
                              ),
                              Positioned(
                                left: 0,
                                top: 128,
                                width: 236,
                                height: 220,
                                child: _NewProjectCard(onTap: _newProject),
                              ),
                            ],
                          ),
                        ),
                        _buildRecentHeader(),
                        const SizedBox(height: 10),
                        Expanded(child: _buildProjectList()),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildRecentHeader() {
    return Row(
      children: <Widget>[
        const Icon(
          Icons.schedule_rounded,
          color: AppColors.accent,
          size: 21,
        ),
        const SizedBox(width: 9),
        const Expanded(
          child: Text(
            '最近のプロジェクト',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ),
        if (_projects.length > 4)
          TextButton(
            onPressed: () {
              setState(() => _showAllProjects = !_showAllProjects);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(_showAllProjects ? '閉じる' : 'すべて表示'),
                const SizedBox(width: 2),
                Icon(
                  _showAllProjects
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.chevron_right_rounded,
                  size: 20,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildProjectList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_projects.isEmpty) {
      return const _EmptyProjectPanel();
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: _visibleProjects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final ProjectSummary project = _visibleProjects[index];
        return _ProjectCard(
          project: project,
          accent: _projectAccent(index),
          icon: _projectIcon(index),
          onOpen: () => _open(project),
          onExport: () => _open(project, exportOnOpen: true),
          onRename: () => _rename(project),
          onDelete: () => _delete(project),
        );
      },
    );
  }

  Color _projectAccent(int index) {
    const List<Color> colors = <Color>[
      AppColors.accent,
      Color(0xFF39E6A0),
      Color(0xFFB065FF),
      Color(0xFFFFB21E),
    ];
    return colors[index % colors.length];
  }

  IconData _projectIcon(int index) {
    const List<IconData> icons = <IconData>[
      Icons.apartment_rounded,
      Icons.account_balance_rounded,
      Icons.school_rounded,
      Icons.local_hospital_rounded,
    ];
    return icons[index % icons.length];
  }
}

class _LandscapeOnlyNotice extends StatelessWidget {
  const _LandscapeOnlyNotice();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.screen_rotation_rounded,
            color: AppColors.accent,
            size: 58,
          ),
          SizedBox(height: 18),
          Text(
            'iPadを横向きにしてください',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _NewProjectCard extends StatelessWidget {
  const _NewProjectCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.18),
            blurRadius: 34,
            spreadRadius: 2,
          ),
          const BoxShadow(
            color: Color(0x66000000),
            blurRadius: 24,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: const Color(0xFF5696C5),
                width: 1.05,
              ),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  Color(0xE119466D),
                  Color(0xF0061930),
                  Color(0xFA031024),
                ],
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 17),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: CustomPaint(
                          painter: _NewProjectMarkPainter(),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '新規プロジェクト',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                  SizedBox(height: 5),
                  Text(
                    'NEW PROJECT',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.accent,
    required this.icon,
    required this.onOpen,
    required this.onExport,
    required this.onRename,
    required this.onDelete,
  });

  final ProjectSummary project;
  final Color accent;
  final IconData icon;
  final VoidCallback onOpen;
  final VoidCallback onExport;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 78,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onOpen,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF3A6B94)),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  Color(0xE60A2844),
                  Color(0xF006172B),
                ],
              ),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x42000000),
                  blurRadius: 10,
                  offset: Offset(0, 5),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(17, 10, 6, 10),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 48,
                    child: Icon(icon, color: accent, size: 33),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '最終更新: ${_formatDate(project.updatedAt)}',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        _ProjectStat(
                          icon: Icons.description_outlined,
                          label: project.pageCount > 0
                              ? '図面 ${project.pageCount}枚'
                              : '図面',
                        ),
                        const SizedBox(width: 26),
                        _ProjectStat(
                          icon: Icons.photo_outlined,
                          label: '写真 ${project.photoCount}枚',
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '案件メニュー',
                    color: const Color(0xFF0A1D34),
                    icon: const Icon(
                      Icons.more_vert_rounded,
                      size: 21,
                      color: AppColors.textSecondary,
                    ),
                    onSelected: (String value) {
                      if (value == 'export') onExport();
                      if (value == 'rename') onRename();
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (_) => const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'export',
                        child: Text('PDFを書き出す'),
                      ),
                      PopupMenuItem<String>(
                        value: 'rename',
                        child: Text('名前を変更'),
                      ),
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: Text('削除'),
                      ),
                    ],
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFFD2E0ED),
                    size: 27,
                  ),
                  const SizedBox(width: 3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}.${two(date.month)}.${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }
}

class _ProjectStat extends StatelessWidget {
  const _ProjectStat({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 18, color: const Color(0xFFB9CDE0)),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFE6F0FA),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _EmptyProjectPanel extends StatelessWidget {
  const _EmptyProjectPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 170,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFF315E86)),
        color: const Color(0xB306172B),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.folder_open_rounded,
              color: AppColors.textSecondary,
              size: 42,
            ),
            SizedBox(height: 10),
            Text(
              'まだプロジェクトがありません',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewProjectMarkPainter extends CustomPainter {
  const _NewProjectMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double side = math.min(size.width, size.height);
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = side * 0.31;
    final Rect arcRect = Rect.fromCircle(center: center, radius: radius);

    final Paint glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = side * 0.12
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x6628B8FF)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, side * 0.08);
    canvas.drawArc(
      arcRect,
      -math.pi * 0.76,
      math.pi * 1.52,
      false,
      glowPaint,
    );

    final Paint arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = side * 0.082
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: <Color>[
          Color(0xFF177DFF),
          Color(0xFF68E7FF),
          Color(0xFF28B8FF),
          Color(0xFF177DFF),
        ],
      ).createShader(arcRect);
    canvas.drawArc(
      arcRect,
      -math.pi * 0.76,
      math.pi * 1.52,
      false,
      arcPaint,
    );

    final Paint dashPaint = Paint()
      ..color = const Color(0xFF28B8FF)
      ..strokeWidth = side * 0.035
      ..strokeCap = StrokeCap.round;
    final double dashRadius = radius * 1.24;
    for (int i = 0; i < 3; i++) {
      final double angle = math.pi * (0.28 + i * 0.055);
      final Offset from = center +
          Offset(math.cos(angle), math.sin(angle)) * dashRadius;
      final Offset to = center +
          Offset(math.cos(angle), math.sin(angle)) *
              (dashRadius + side * 0.035);
      canvas.drawLine(from, to, dashPaint);
    }

    final Paint plusPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = side * 0.047
      ..strokeCap = StrokeCap.round;
    final double half = side * 0.105;
    canvas.drawLine(
      center.translate(-half, 0),
      center.translate(half, 0),
      plusPaint,
    );
    canvas.drawLine(
      center.translate(0, -half),
      center.translate(0, half),
      plusPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
