import 'package:flutter/material.dart';
import 'pdf_engine.dart';

Future<void> showSettingsSheet(
  BuildContext context,
  PdfSettings initial,
  ValueChanged<PdfSettings> onChanged,
) {
  var s = initial;
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) {
        void upd(PdfSettings n) {
          set(() => s = n);
          onChanged(n);
        }

        Widget slider(String label, double v, double min, double max, int div,
                ValueChanged<double> f) =>
            Row(children: [
              SizedBox(width: 120, child: Text('$label ${v.toStringAsFixed(1)}')),
              Expanded(
                child: Slider(
                    value: v, min: min, max: max, divisions: div, onChanged: f),
              ),
            ]);

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            slider('Font size', s.font, 8, 24, 16,
                (x) => upd(s.copyWith(font: x))),
            slider('Line space', s.line, 1.0, 2.0, 10,
                (x) => upd(s.copyWith(line: x))),
            slider('Margin', s.margin, 30, 60, 6,
                (x) => upd(s.copyWith(margin: x))),
            SwitchListTile(
              title: const Text('US Letter (off = A4)'),
              value: s.letter,
              onChanged: (x) => upd(s.copyWith(letter: x)),
            ),
            SwitchListTile(
              title: const Text('High quality (bigger file)'),
              value: s.hq,
              onChanged: (x) => upd(s.copyWith(hq: x)),
            ),
          ]),
        );
      },
    ),
  );
}

Future<void> showFindReplace(
  BuildContext context, {
  required void Function(String q, bool cs) onFind,
  required void Function(String q, String r, bool cs) onReplace,
}) {
  final f = TextEditingController(), r = TextEditingController();
  var cs = false;
  return showDialog<void>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Find & replace'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: f,
              decoration: const InputDecoration(labelText: 'Find')),
          TextField(
              controller: r,
              decoration: const InputDecoration(labelText: 'Replace with')),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Match case'),
            value: cs,
            onChanged: (v) => set(() => cs = v ?? false),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                onFind(f.text, cs);
              },
              child: const Text('Find next')),
          FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                onReplace(f.text, r.text, cs);
              },
              child: const Text('Replace all')),
        ],
      ),
    ),
  );
}
