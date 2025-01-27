import 'package:flutter/material.dart';

class IconPainter extends CustomPainter {
  final Icon icon;

  IconPainter(this.icon);

  @override
  void paint(Canvas canvas, Size size) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    final iconTextSpan = TextSpan(
      text: String.fromCharCode(icon.icon!.codePoint),
      style: TextStyle(
        fontSize: size.width,
        fontFamily: icon.icon!.fontFamily,
        color: icon.color,
      ),
    );

    textPainter.text = iconTextSpan;
    textPainter.layout();

    textPainter.paint(canvas, Offset(0, 0));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
