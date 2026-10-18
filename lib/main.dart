import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dialogs.dart';
import 'pdf_engine.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Text to PDF',
        themeMode: ThemeMode.system,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
        darkTheme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: Colors.blue,
            brightness: Brightness.dark),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  static const int maxChars = 100000; // per PDF / editor
  static const int bigCap = 1000000; // big-file mode total
  final _c = TextEditingController();
  final _focus = FocusNode();
  final _undo = UndoHistoryController();
  SharedPreferences? _prefs;
  Timer? _timer;
  bool _busy = false, _cancel = false;
  String _status = 'Type, paste or load a text file (max 100,000 characters).';
  PdfSettings _s = const PdfSettings();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    _s = PdfSettings(
      font: p.getDouble('font') ?? 11,
      line: p.getDouble('line') ?? 1.4,
      margin: p.getDouble('margin') ?? 40,
      letter: p.getBool('letter') ?? false,
      hq: p.getBool('hq') ?? false,
    );
    final d = p.getString('draft');
    if (d != null && d.isNotEmpty) _c.text = d;
    _c.addListener(_onChange);
    if (mounted) {
      setState(() {
        if (d != null && d.isNotEmpty) _status = 'Draft restored.';
      });
    }
  }

  void _onChange() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1),
        () => _prefs?.setString('draft', _c.text));
  }

  void _setSettings(PdfSettings n) {
    setState(() => _s = n);
    final p = _prefs;
    if (p == null) return;
    p.setDouble('font', n.font);
    p.setDouble('line', n.line);
    p.setDouble('margin', n.margin);
    p.setBool('letter', n.letter);
    p.setBool('hq', n.hq);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    _focus.dispose();
    _undo.dispose();
    super.dispose();
  }

  void _msg(String s) {
    if (mounted) setState(() => _status = s);
  }

  // ---------- Editing tools ----------
  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    final t = d?.text;
    if (t == null || t.isEmpty) return _msg('Clipboard is empty.');
    final sel = _c.selection;
    final text = _c.text;
    final s = sel.isValid ? sel.start : text.length;
    final e = sel.isValid ? sel.end : text.length;
    var out = text.replaceRange(s, e, t);
    if (out.length > maxChars) out = out.substring(0, maxChars);
    final pos = (s + t.length).clamp(0, out.length);
    _c.value = TextEditingValue(
        text: out, selection: TextSelection.collapsed(offset: pos));
    _msg('Pasted.');
  }

  Future<void> _copy() async {
    final sel = _c.selection;
    final hasSel = sel.isValid && !sel.isCollapsed;
    final t = hasSel ? sel.textInside(_c.text) : _c.text;
    if (t.isEmpty) return _msg('Nothing to copy.');
    await Clipboard.setData(ClipboardData(text: t));
    _msg(hasSel ? 'Selected text copied.' : 'All text copied.');
  }

  void _selectAll() {
    _focus.requestFocus();
    _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length);
  }

  void _deleteSelected() {
    final sel = _c.selection;
    if (!sel.isValid || sel.isCollapsed) return _msg('Select some text first.');
    _c.value = TextEditingValue(
      text: _c.text.replaceRange(sel.start, sel.end, ''),
      selection: TextSelection.collapsed(offset: sel.start),
    );
    _msg('Deleted.');
  }

  Future<void> _clear() async {
    if (_c.text.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all text?'),
        content: const Text('You can still press Undo afterwards.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      _c.clear();
      _msg('Cleared.');
    }
  }

  Future<void> _loadFile() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'log', 'md', 'csv'],
    );
    final path = r?.files.single.path;
    if (path == null) return;
    try {
      final text = await File(path)
          .readAsString(encoding: const Utf8Codec(allowMalformed: true));
      setState(() {
        _c.text = text.length > maxChars ? text.substring(0, maxChars) : text;
        _status = text.length > maxChars
            ? 'File had ${text.length} chars. Trimmed to $maxChars. '
                'Use Big file mode (menu) for longer files.'
            : 'Loaded ${text.length} characters.';
      });
    } catch (e) {
      _msg('Could not read file: $e');
    }
  }

  // ---------- Find & replace ----------
  void _findNext(String q, bool cs) {
    if (q.isEmpty) return;
    final text = cs ? _c.text : _c.text.toLowerCase();
    final needle = cs ? q : q.toLowerCase();
    final from = _c.selection.isValid ? _c.selection.end : 0;
    var i = text.indexOf(needle, from < 0 ? 0 : from);
    if (i < 0) i = text.indexOf(needle);
    if (i < 0) return _msg('Not found.');
    _focus.requestFocus();
    _c.selection =
        TextSelection(baseOffset: i, extentOffset: i + needle.length);
    _msg('Found at position $i.');
  }

  void _replaceAll(String q, String rep, bool cs) {
    if (q.isEmpty) return;
    final pattern = RegExp(RegExp.escape(q), caseSensitive: cs);
    final n = pattern.allMatches(_c.text).length;
    if (n == 0) return _msg('Not found.');
    final out = _c.text.replaceAll(pattern, rep);
    if (out.length > maxChars) {
      return _msg('Replace would exceed $maxChars characters.');
    }
    _c.value = TextEditingValue(
        text: out, selection: const TextSelection.collapsed(offset: 0));
    _msg('Replaced $n match${n == 1 ? '' : 'es'}.');
  }

  // ---------- Convert ----------
  Future<void> _convert() async {
    if (_c.text.trim().isEmpty) return _msg('Nothing to convert.');
    setState(() {
      _busy = true;
      _cancel = false;
      _status = 'Preparing...';
    });
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      final res = await buildPdf(_c.text, _s,
          status: _msg, cancelled: () => _cancel);
      if (res == null) return _msg('Cancelled.');
      final (out, pages) = res;

      final dir = await getTemporaryDirectory();
      final name = 'converted_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(out);

      _msg('Done! $pages pages, ${out.length ~/ 1024} KB. Choose where to save.');
      await Share.shareXFiles([XFile(f.path)]);
    } catch (e) {
      _msg('Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- Big file mode ----------
  Future<void> _bigFile() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'log', 'md', 'csv'],
    );
    final path = r?.files.single.path;
    if (path == null) return;

    setState(() {
      _busy = true;
      _cancel = false;
      _status = 'Reading file...';
    });
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      var text = (await File(path)
              .readAsString(encoding: const Utf8Codec(allowMalformed: true)))
          .replaceAll('\r\n', '\n');
      var note = '';
      if (text.length > bigCap) {
        text = text.substring(0, bigCap);
        note = ' (file trimmed to $bigCap characters)';
      }

      final parts = <String>[];
      var s = 0;
      while (s < text.length) {
        var e = s + maxChars;
        if (e >= text.length) {
          e = text.length;
        } else {
          final nl = text.lastIndexOf('\n', e - 1);
          if (nl > s) {
            e = nl + 1;
          } else {
            final u = text.codeUnitAt(e - 1);
            if (u >= 0xD800 && u <= 0xDBFF) e--;
          }
        }
        parts.add(text.substring(s, e));
        s = e;
      }

      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final files = <XFile>[];

      for (var i = 0; i < parts.length; i++) {
        final label = 'Part ${i + 1}/${parts.length}';
        final res = await buildPdf(parts[i], _s,
            prefix: '$label  -  page ',
            status: (m) => _msg('$label: $m'),
            cancelled: () => _cancel);
        if (res == null) return _msg('Cancelled.');
        final n = (i + 1).toString().padLeft(2, '0');
        final f = File('${dir.path}/text_part_${n}_$stamp.pdf');
        await f.writeAsBytes(res.$1);
        files.add(XFile(f.path));
      }

      _msg('Done: ${files.length} PDFs$note. Choose where to save.');
      await Share.shareXFiles(files);
    } catch (e) {
      _msg('Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openFind() =>
      showFindReplace(context, onFind: _findNext, onReplace: _replaceAll);

  // ---------- UI ----------
  Widget _tool(IconData icon, String tip, VoidCallback f) =>
      IconButton(icon: Icon(icon), tooltip: tip, onPressed: _busy ? null : f);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Text to PDF'),
        actions: [
          ValueListenableBuilder<UndoHistoryValue>(
            valueListenable: _undo,
            builder: (_, v, __) => Row(children: [
              IconButton(
                  icon: const Icon(Icons.undo),
                  tooltip: 'Undo',
                  onPressed: v.canUndo ? _undo.undo : null),
              IconButton(
                  icon: const Icon(Icons.redo),
                  tooltip: 'Redo',
                  onPressed: v.canRedo ? _undo.redo : null),
            ]),
          ),
          IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Settings',
              onPressed: _busy
                  ? null
                  : () => showSettingsSheet(context, _s, _setSettings)),
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (v) {
              if (v == 'find') _openFind();
              if (v == 'big') _bigFile();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'find', child: Text('Find & replace')),
              PopupMenuItem(
                  value: 'big', child: Text('Big file mode (split PDFs)')),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                _tool(Icons.content_paste, 'Paste', _paste),
                _tool(Icons.copy, 'Copy (selected or all)', _copy),
                _tool(Icons.select_all, 'Select all', _selectAll),
                _tool(Icons.backspace_outlined, 'Delete selected',
                    _deleteSelected),
                _tool(Icons.find_replace, 'Find & replace', _openFind),
                _tool(Icons.delete_sweep, 'Clear all', _clear),
              ],
            ),
            Expanded(
              child: TextField(
                controller: _c,
                focusNode: _focus,
                undoController: _undo,
                maxLines: null,
                expands: true,
                enableInteractiveSelection: true,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                    fontFamily: 'NotoSans',
                    fontFamilyFallback: fontFallbacks,
                    fontSize: 16),
                inputFormatters: [LengthLimitingTextInputFormatter(maxChars)],
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Type or paste text in any language',
                ),
              ),
            ),
            const SizedBox(height: 6),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _c,
              builder: (_, v, __) => Text(
                '${v.text.length} / $maxChars characters',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 6),
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            if (_busy)
              Row(children: [
                const Expanded(child: LinearProgressIndicator()),
                const SizedBox(width: 12),
                OutlinedButton(
                    onPressed: () => _cancel = true,
                    child: const Text('Cancel')),
              ])
            else
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loadFile,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Load file'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _convert,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Make PDF'),
                  ),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}
// END OF FILE
