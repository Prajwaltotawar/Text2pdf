import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const fontFallbacks = ['NotoDevanagari', 'NotoTelugu'];

class PdfSettings {
  final double font, line, margin;
  final bool letter, hq;
  const PdfSettings({
    this.font = 11,
    this.line = 1.4,
    this.margin = 40,
    this.letter = false,
    this.hq = false,
  });

  PdfSettings copyWith({
    double? font,
    double? line,
    double? margin,
    bool? letter,
    bool? hq,
  }) =>
      PdfSettings(
        font: font ?? this.font,
        line: line ?? this.line,
        margin: margin ?? this.margin,
        letter: letter ?? this.letter,
        hq: hq ?? this.hq,
      );
}

/// Returns (pdfBytes, pageCount), or null if cancelled.
Future<(Uint8List, int)?> buildPdf(
  String raw,
  PdfSettings s, {
  String prefix = '',
  void Function(String)? status,
  bool Function()? cancelled,
}) async {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\t', '    ');
  final base = s.letter ? PdfPageFormat.letter : PdfPageFormat.a4;
  final format = PdfPageFormat(base.width, base.height, marginAll: 0);
  final pageW = format.width, pageH = format.height;
  final scale = s.hq ? 2.0 : 1.5;
  final margin = s.margin;
  final contentW = pageW - 2 * margin, contentH = pageH - 2 * margin;
  final style = TextStyle(
    fontFamily: 'NotoSans',
    fontFamilyFallback: fontFallbacks,
    fontSize: s.font,
    height: s.line,
    color: Colors.black,
  );

  // Find page breaks by laying out the whole text once
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: contentW);

  final startYs = <double>[0];
  var pageTop = 0.0;
  for (final l in tp.computeLineMetrics()) {
    final top = l.baseline - l.ascent;
    final bottom = l.baseline + l.descent;
    if (bottom - pageTop > contentH && top > pageTop) {
      startYs.add(top);
      pageTop = top;
    }
  }
  final offsets = <int>[
    for (final y in startYs)
      y == 0 ? 0 : tp.getPositionForOffset(Offset(1, y + 1)).offset
  ];
  tp.dispose();

  final pdf = pw.Document();
  final total = offsets.length;

  for (var i = 0; i < total; i++) {
    if (cancelled != null && cancelled()) return null;
    final a = offsets[i];
    final b = i + 1 < total ? offsets[i + 1] : text.length;
    if (b <= a) continue;
    final chunk = text.substring(a, b).trimRight();

    final p = TextPainter(
      text: TextSpan(text: chunk, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: contentW);

    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.scale(scale);
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, pageW, pageH),
        ui.Paint()..color = Colors.white);
    p.paint(canvas, Offset(margin, margin));
    p.dispose();

    final fp = TextPainter(
      text: TextSpan(
          text: '$prefix${i + 1} / $total',
          style: const TextStyle(
              fontFamily: 'NotoSans', fontSize: 9, color: Colors.grey)),
      textDirection: TextDirection.ltr,
    )..layout();
    fp.paint(canvas, Offset((pageW - fp.width) / 2, pageH - margin / 2 - 6));
    fp.dispose();

    final img = await rec
        .endRecording()
        .toImage((pageW * scale).toInt(), (pageH * scale).toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    final bytes = data!.buffer.asUint8List();

    pdf.addPage(pw.Page(
      pageFormat: format,
      build: (_) => pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.fill),
    ));

    status?.call('Page ${i + 1} of $total');
    await Future.delayed(Duration.zero); // keep UI responsive
  }

  status?.call('Building PDF...');
  await Future.delayed(Duration.zero);
  final out = await pdf.save();
  return (out, total);
}
