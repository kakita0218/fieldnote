import 'package:flutter/material.dart';

class BlueprintBackground extends StatelessWidget {
  const BlueprintBackground({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const CustomPaint(
          painter: BlueprintBackgroundPainter(),
        ),
        Positioned(
          top: 0,
          right: 0,
          width: MediaQuery.sizeOf(context).width * 0.72,
          height: MediaQuery.sizeOf(context).height * 0.58,
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.82,
              child: Image.asset(
                'assets/images/home_building_wireframe.png',
                fit: BoxFit.contain,
                alignment: Alignment.topRight,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class BlueprintBackgroundPainter extends CustomPainter {
  const BlueprintBackgroundPainter();

  static const Color _minorLine = Color(0x1028B8FF);
  static const Color _majorLine = Color(0x1D28B8FF);

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;

    final Paint backgroundPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0xFF061A35),
          Color(0xFF031126),
          Color(0xFF010817),
        ],
        stops: <double>[0, 0.58, 1],
      ).createShader(rect);
    canvas.drawRect(rect, backgroundPaint);

    final Paint glowPaint = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          const Color(0xFF1288E8).withValues(alpha: 0.14),
          const Color(0xFF0A4C92).withValues(alpha: 0.05),
          Colors.transparent,
        ],
        stops: const <double>[0, 0.52, 1],
      ).createShader(
        Rect.fromCircle(
          center: Offset(size.width * 0.72, size.height * 0.34),
          radius: size.width * 0.46,
        ),
      );
    canvas.drawRect(rect, glowPaint);

    const double spacing = 40;
    final Paint minorPaint = Paint()
      ..color = _minorLine
      ..strokeWidth = 0.55;
    final Paint majorPaint = Paint()
      ..color = _majorLine
      ..strokeWidth = 0.8;

    int column = 0;
    for (double x = 0; x <= size.width; x += spacing) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        column % 4 == 0 ? majorPaint : minorPaint,
      );
      column++;
    }

    int row = 0;
    for (double y = 0; y <= size.height; y += spacing) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        row % 4 == 0 ? majorPaint : minorPaint,
      );
      row++;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
