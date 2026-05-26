import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

const Map<String, List<String>> instrumentLabels = {
  "PF": ["piano", "pianos"],
  "VN": ["violin", "violins"],
  "VLN2": ["violin", "violins"],
  "VA": ["viola", "violas"],
  "VC": ["cello", "cellos"],
  "DB": ["double bass", "double basses"],
  "FL": ["flute", "flutes"],
  "OB": ["oboe", "oboes"],
  "CL": ["clarinet", "clarinets"],
  "FH": ["French horn", "French horns"],
  "BN": ["bassoon", "bassoons"],
};

final performerTokenRe = RegExp(r"^(.+)\s+(PF|VLN2|VN|VC|VA|DB|FL|OB|CL|FH|BN)\s*$", caseSensitive: false);
const Set<String> violinCodes = {"VN", "VLN2"};
const String violinGroup = "__violin__";

String cleanSpaces(String s) {
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String formatComposerDates(String dates) {
  String s = dates.trim();
  if (RegExp(r'^\d+$').hasMatch(s)) {
    return 'b.$s';
  }
  return s;
}

String composerLookupKey(String name) {
  return cleanSpaces(name).toLowerCase();
}

String formatGroupedPerformersCell(String text) {
  if (text.isEmpty) return "";
  text = text.replaceAll("\\n", "\n").trim();
  if (text.isEmpty) return "";

  List<String> parts = text.split(RegExp(r'[\n,]+'));
  List<String> tokens = parts.map(cleanSpaces).where((p) => p.isNotEmpty).toList();
  if (tokens.isEmpty) return "";

  List<List<String>> parsed = [];
  for (String t in tokens) {
    Match? m = performerTokenRe.firstMatch(t);
    if (m == null) return cleanSpaces(text);
    String name = m.group(1)!.trim();
    String code = m.group(2)!.toUpperCase();
    if (!instrumentLabels.containsKey(code)) {
      return cleanSpaces(text);
    }
    parsed.add([name, code]);
  }

  List<String> order = [];
  Map<String, List<String>> groups = {};
  List<String> vnNames = [];
  List<String> vln2Names = [];

  for (var p in parsed) {
    String name = p[0];
    String code = p[1];
    if (violinCodes.contains(code)) {
      if (!order.contains(violinGroup)) {
        order.add(violinGroup);
      }
      if (code == "VN") {
        vnNames.add(name);
      } else {
        vln2Names.add(name);
      }
    } else {
      if (!groups.containsKey(code)) {
        groups[code] = [];
        order.add(code);
      }
      groups[code]!.add(name);
    }
  }

  List<String> chunks = [];
  for (String gid in order) {
    if (gid == violinGroup) {
      List<String> names = [...vnNames, ...vln2Names];
      String label = names.length == 1 ? instrumentLabels["VN"]![0] : instrumentLabels["VN"]![1];
      chunks.add("${names.join(', ')}, $label");
    } else {
      List<String> names = groups[gid]!;
      String label = names.length == 1 ? instrumentLabels[gid]![0] : instrumentLabels[gid]![1];
      chunks.add("${names.join(', ')}, $label");
    }
  }
  return chunks.join("; ");
}

List<String> splitPerformerBlocks(String cell) {
  if (cell.isEmpty) return [];
  String s = cell.replaceAll("\\n", "\n");
  if (s.contains("|")) {
    return s.split("|").map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }
  return s.trim().isEmpty ? [] : [s.trim()];
}

List<String> normalizePerformersFromInput(dynamic value) {
  List<String> out = [];
  List<String> items = [];
  if (value is List) {
    items = value.map((e) => e.toString()).toList();
  } else {
    items = [value.toString()];
  }

  for (String item in items) {
    for (String block in splitPerformerBlocks(item)) {
      String formatted = formatGroupedPerformersCell(block);
      if (formatted.isNotEmpty) out.add(formatted);
    }
  }
  return out;
}

List<String> splitMovementCell(String cell) {
  String s = cell.replaceAll("\\n", "\n");
  return s.split(RegExp(r'[,|\n]+')).map(cleanSpaces).where((e) => e.isNotEmpty).toList();
}

String getValue(Map<String, dynamic> row, List<String> keys) {
  for (String key in keys) {
    if (row.containsKey(key) && row[key] != null) {
      return row[key].toString().trim();
    }
  }
  return "";
}

bool isCombinedFirstCellRow(String rawComposer, String titleCell) {
  return rawComposer.isNotEmpty &&
      (rawComposer.contains('\n') || rawComposer.contains('\\n')) &&
      cleanSpaces(titleCell).isEmpty;
}

bool isComposerDatesOnlyRow(Map<String, dynamic> row) {
  String titleCell = getValue(row, ["title", "piece", "work"]);
  String rawComposer = getValue(row, ["composer"]);
  String dates = cleanSpaces(getValue(row, ["composer_dates", "dates", "years"]));

  if (cleanSpaces(titleCell).isNotEmpty || dates.isEmpty) return false;
  if (isCombinedFirstCellRow(rawComposer, titleCell)) return false;
  if (rawComposer.contains('\n') || rawComposer.contains('\\n')) return false;
  return cleanSpaces(rawComposer).isNotEmpty;
}

class CombinedCell {
  final String composer;
  final String title;
  final List<String> movements;
  CombinedCell(this.composer, this.title, this.movements);
}

CombinedCell? parseCombinedFirstCell(String value) {
  String s = value.replaceAll('\\n', '\n').trim();
  if (s.isEmpty) return null;
  List<String> lines = s.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (lines.length < 2) return null;
  String composer = cleanSpaces(lines[0]);
  String title = cleanSpaces(lines[1]);
  List<String> movements = lines.length > 2 ? lines.sublist(2).expand((l) => splitMovementCell(l)).toList() : [];
  if (composer.isEmpty || title.isEmpty) return null;
  return CombinedCell(composer, title, movements);
}

class Work {
  final String id;
  String composer;
  String title;
  String composerDates;
  List<String> movements;
  List<String> performers;

  Work({
    String? id,
    required this.composer,
    required this.title,
    this.composerDates = '',
    this.movements = const [],
    this.performers = const [],
  }) : id = id ?? UniqueKey().toString();
}

Future<List<Map<String, dynamic>>> readCsvFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return [];

  final bytes = await file.readAsBytes();
  String contents;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    contents = utf8.decode(bytes.sublist(3), allowMalformed: true);
  } else {
    contents = utf8.decode(bytes, allowMalformed: true);
  }

  // Normalize line endings to \n to avoid CsvToListConverter confusion
  contents = contents.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  final fields = const CsvToListConverter(eol: "\n").convert(contents);
  if (fields.isEmpty) return [];

  List<String> headers = fields.first.map((e) => e.toString().trim().toLowerCase()).toList();
  List<Map<String, dynamic>> rawRows = [];
  for (int i = 1; i < fields.length; i++) {
    Map<String, dynamic> row = {};
    for (int j = 0; j < headers.length; j++) {
      if (j < fields[i].length) {
        row[headers[j]] = fields[i][j];
      }
    }
    rawRows.add(row);
  }
  return rawRows;
}

Future<List<Work>> readWorksCsv(String path) async {
  final rawRows = await readCsvFile(path);
  if (rawRows.isEmpty) throw Exception("CSV appears to be empty.");

  Map<String, String> composerDatesLookup = {};

  for (var row in rawRows) {
    if (isComposerDatesOnlyRow(row)) {
      String c = cleanSpaces(getValue(row, ["composer"]));
      String d = cleanSpaces(getValue(row, ["composer_dates", "dates", "years"]));
      if (c.isNotEmpty && d.isNotEmpty) {
        composerDatesLookup[composerLookupKey(c)] = d;
      }
    }
  }

  List<Work> works = [];
  for (int i = 0; i < rawRows.length; i++) {
    var row = rawRows[i];
    if (isComposerDatesOnlyRow(row)) continue;

    String rawFirst = getValue(row, ["composer", "work", "piece"]);
    String titleCell = getValue(row, ["title", "piece", "work"]);

    CombinedCell? combined;
    if (isCombinedFirstCellRow(rawFirst, titleCell)) {
      combined = parseCombinedFirstCell(rawFirst);
    }

    String composer;
    String title;
    List<String> movementsFromFirst = [];

    if (combined != null) {
      composer = combined.composer;
      title = combined.title;
      movementsFromFirst = combined.movements;
    } else {
      composer = cleanSpaces(getValue(row, ["composer"]));
      title = cleanSpaces(titleCell);
    }

    String composerDates = cleanSpaces(getValue(row, ["composer_dates", "dates", "years"]));
    if (composerDates.isEmpty && composer.isNotEmpty) {
      composerDates = composerDatesLookup[composerLookupKey(composer)] ?? "";
    }
    composerDates = formatComposerDates(composerDates);

    List<String> movements = splitMovementCell(getValue(row, ["movements", "movement"]));
    if (movementsFromFirst.isNotEmpty) {
      movements = [...movementsFromFirst, ...movements];
    }

    List<String> performers = normalizePerformersFromInput(getValue(row, ["performers", "players", "people"]));

    if (composer.isEmpty && title.isEmpty) continue;
    if (composer.isEmpty || title.isEmpty) {
      throw Exception("CSV line ${i + 2}: missing required composer/title. Got composer='$composer', title='$title'.");
    }

    works.add(Work(
      composer: composer,
      title: title,
      composerDates: composerDates,
      movements: movements,
      performers: performers,
    ));
  }
  return works;
}

Future<void> writeProgramDocx(List<Work> works, String outPath, String heading) async {
  final buffer = StringBuffer();
  buffer.writeln('<html><head><meta charset="utf-8"></head><body style="font-family: Arial, sans-serif;">');

  if (heading.isNotEmpty) {
    buffer.writeln('<h1 style="text-align: center;">$heading</h1><br/>');
  }

  for (int i = 0; i < works.length; i++) {
    var w = works[i];
    buffer.writeln('<table width="100%" style="margin-bottom: 0px; border-collapse: collapse;"><tr>');
    buffer.writeln('<td style="text-align: left;"><b>${w.title}</b></td>');
    buffer.writeln('<td style="text-align: right;"><b>${w.composer}</b></td>');
    buffer.writeln('</tr></table>');

    if (w.composerDates.isNotEmpty) {
      buffer.writeln('<div style="text-align: right;">${w.composerDates}</div>');
    }

    for (var m in w.movements) {
      buffer.writeln('<div style="margin-left: 20px;"><i>$m</i></div>');
    }

    for (var p in w.performers) {
      buffer.writeln('<div style="text-align: center;">$p</div>');
    }
    buffer.writeln('<br/>');
  }

  buffer.writeln('</body></html>');
  final file = File(outPath);
  // Write with a UTF-8 BOM so MS Word recognizes the encoding correctly
  await file.writeAsString('\uFEFF${buffer.toString()}', encoding: utf8);
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Program Creator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      ),
      home: const MyHomePage(title: 'Program → Word'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final csvController = TextEditingController();
  final outController = TextEditingController();
  final headingController = TextEditingController(text: "PROGRAM");

  List<Work>? orderedWorks;

  @override
  void dispose() {
    csvController.dispose();
    outController.dispose();
    headingController.dispose();
    super.dispose();
  }

  void _clearOrderedWorks() {
    setState(() => orderedWorks = null);
  }

  Future<void> _browseCsv() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (result != null) {
      setState(() {
        csvController.text = result.files.single.path!;
        if (outController.text.isEmpty) {
          String path = csvController.text;
          int dotIndex = path.lastIndexOf('.');
          if (dotIndex != -1) {
            outController.text = '${path.substring(0, dotIndex)}_program.doc';
          } else {
            outController.text = '${path}_program.doc';
          }
        }
        _clearOrderedWorks();
      });
    }
  }

  Future<void> _browseOut() async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Word document as',
      fileName: 'program.doc',
      type: FileType.custom,
      allowedExtensions: ['doc'],
    );
    if (outputFile != null) {
      setState(() {
        outController.text = outputFile;
      });
    }
  }

  void _showMessage(String title, String msg) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))
        ],
      ),
    );
  }

  Future<void> _openOrderEditor() async {
    String csvPath = csvController.text.trim();
    if (csvPath.isEmpty) {
      _showMessage("Missing file", "Choose a CSV file first.");
      return;
    }

    List<Work> baseWorks;
    try {
      baseWorks = await readWorksCsv(csvPath);
    } catch (e) {
      _showMessage("Could not read CSV", e.toString());
      return;
    }

    if (baseWorks.isEmpty) {
      _showMessage("No entries", "The CSV has no program works to reorder.");
      return;
    }

    List<Work> initial = orderedWorks ?? baseWorks;

    if (!mounted) return;
    List<Work>? newOrder = await showDialog<List<Work>>(
      context: context,
      builder: (context) {
        return OrderEditorDialog(
          works: initial,
          onReset: () => readWorksCsv(csvPath),
        );
      },
    );

    if (newOrder != null) {
      setState(() => orderedWorks = newOrder);
    }
  }

  Future<void> _exportToWord() async {
    String csvPath = csvController.text.trim();
    String outPath = outController.text.trim();
    String heading = headingController.text.trim();

    if (csvPath.isEmpty) {
      _showMessage("Missing file", "Choose a CSV file.");
      return;
    }
    if (outPath.isEmpty) {
      _showMessage("Missing file", "Choose where to save the Word document.");
      return;
    }

    try {
      List<Work> works = orderedWorks ?? await readWorksCsv(csvPath);
      await writeProgramDocx(works, outPath, heading);
      String note = orderedWorks != null ? " (custom order)" : "";
      _showMessage("Done", "Wrote ${works.length} work(s) to:\n$outPath$note");
    } catch (e) {
      _showMessage("Export failed", e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 130, child: Text('CSV file:')),
                Expanded(child: TextField(controller: csvController, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _browseCsv, child: const Text('Browse...')),
              ]
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 130, child: Text('Save as:')),
                Expanded(child: TextField(controller: outController, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _browseOut, child: const Text('Browse...')),
              ]
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 130, child: Text('Heading:')),
                Expanded(child: TextField(controller: headingController, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                Visibility(
                  visible: false,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: ElevatedButton(onPressed: null, child: const Text('Browse...')),
                ),
              ]
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                ElevatedButton(onPressed: _openOrderEditor, child: const Text('Order program...')),
                const SizedBox(width: 12),
                ElevatedButton(onPressed: _exportToWord, child: const Text('Export to Word')),
              ]
            ),
            const SizedBox(height: 24),
            const Text(
              "In the program CSV, rows with composer + dates and empty title register dates once.\n"
              "Work rows omit composer_dates to use the lookup.\n"
              "Movements/performers: comma, newline, or | as before.",
              style: TextStyle(color: Colors.grey, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class OrderEditorDialog extends StatefulWidget {
  final List<Work> works;
  final Future<List<Work>> Function() onReset;
  const OrderEditorDialog({super.key, required this.works, required this.onReset});

  @override
  State<OrderEditorDialog> createState() => _OrderEditorDialogState();
}

class _OrderEditorDialogState extends State<OrderEditorDialog> {
  late List<Work> _works;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _works = List.from(widget.works);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Program order — drag tiles to reorder'),
      content: Container(
        width: 600,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          child: ReorderableListView(
            scrollController: _scrollController,
            buildDefaultDragHandles: false,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = _works.removeAt(oldIndex);
                _works.insert(newIndex, item);
              });
            },
            children: [
              for (int i = 0; i < _works.length; i++)
                Card(
                  key: ValueKey(_works[i].id),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.all(8.0),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Icon(Icons.drag_indicator),
                        ),
                      ),
                    ),
                    title: Text('${i + 1}. ${_works[i].title}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(_works[i].composer),
                  ),
                )
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              final resetList = await widget.onReset();
              setState(() {
                _works = resetList;
              });
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reset failed: $e')));
              }
            }
          },
          child: const Text('Reset from CSV'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context, _works);
          },
          child: const Text('Apply order'),
        ),
      ],
    );
  }
}
