import 'package:flutter/material.dart';

class FieldNoteLogo extends StatelessWidget {
  const FieldNoteLogo({
    super.key,
    this.markSize = 82,
    this.fontSize = 48,
  });

  final double markSize;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: markSize,
      child: Image.asset(
        'assets/images/fieldnote_logo_reference.png',
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}
