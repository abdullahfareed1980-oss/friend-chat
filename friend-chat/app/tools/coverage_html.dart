import 'dart:convert';
import 'dart:io';

/// ---------------------------------------------------------------------------
/// lcov.info -> browsable HTML coverage report.
///
/// Deliberately dependency-free: `genhtml` would mean installing lcov on the
/// runner and on every dev machine, and the report only needs to answer "which
/// lines did the tests touch". Everything this reads is the `SF:` / `DA:`
/// records `flutter test --coverage` already writes.
///
///   dart run tools/coverage_html.dart [lcov] [outDir] [sourceRoot]
///
/// Defaults: coverage/lcov.info, coverage/html, current directory.
/// ---------------------------------------------------------------------------

const _defaultLcov = 'coverage/lcov.info';
const _defaultOut = 'coverage/html';
/// Element mode: escapes &, <, > but not quotes or slashes, so paths read
/// normally in the generated source as well as on screen.
const _htmlEscape = HtmlEscape(HtmlEscapeMode.element);

void main(List<String> args) {
  final result = buildReport(
    lcovPath: args.isNotEmpty ? args[0] : _defaultLcov,
    outDir: args.length > 1 ? args[1] : _defaultOut,
    sourceRoot: args.length > 2 ? args[2] : '.',
  );
  if (result.message.isNotEmpty) {
    (result.ok ? stdout : stderr).writeln(result.message);
  }
  exitCode = result.exitCode;
}

/// Outcome of one run, so the work can be tested without spawning `dart`.
class CoverageReport {
  const CoverageReport({
    required this.exitCode,
    required this.message,
    this.percentage = 0,
    this.hit = 0,
    this.found = 0,
    this.files = const [],
    this.skipped = const [],
  });

  final int exitCode;
  final String message;
  final double percentage;
  final int hit;
  final int found;

  /// Rendered files, worst coverage first.
  final List<String> files;

  /// Files listed in lcov whose source could not be read.
  final List<String> skipped;

  bool get ok => exitCode == 0;
}

/// Reads [lcovPath], writes the report into [outDir] and resolves sources
/// against [sourceRoot]. Never exits: the caller decides what to do with
/// [CoverageReport.exitCode].
CoverageReport buildReport({
  required String lcovPath,
  required String outDir,
  required String sourceRoot,
}) {
  final warnings = <String>[];

  final lcovFile = File(lcovPath);
  if (!lcovFile.existsSync()) {
    return CoverageReport(
      exitCode: 1,
      message: 'coverage_html: no such file: $lcovPath\n'
          'run `flutter test --coverage` first.',
    );
  }

  final files = parseLcov(lcovFile.readAsStringSync());
  if (files.isEmpty) {
    return CoverageReport(
      exitCode: 1,
      message: 'coverage_html: $lcovPath has no SF:/DA: records',
    );
  }

  final root = Directory(sourceRoot);
  var totalFound = 0;
  var totalHit = 0;
  final rendered = <_Report>[];
  final skipped = <String>[];

  for (final file in files) {
    final relative = relativeSourcePath(file.path, root.path);
    if (file.found == 0) {
      // lcov sometimes lists a file with no DA lines; it would add a 0% row
      // that says nothing about the code.
      skipped.add(relative);
      warnings.add('coverage_html: skipping $relative (no instrumented lines)');
      continue;
    }
    final source = File('${root.path}/$relative');
    if (!source.existsSync()) {
      skipped.add(relative);
      warnings.add('coverage_html: skipping $relative (source not found)');
      continue;
    }
    final lines = const LineSplitter().convert(source.readAsStringSync());
    rendered.add(_Report(relative: relative, hits: file.hits, source: lines));
    totalFound += file.found;
    totalHit += file.hit;
  }

  if (rendered.isEmpty) {
    return CoverageReport(
      exitCode: 1,
      message: [
        ...warnings,
        'coverage_html: none of the ${files.length} files had readable sources',
      ].join('\n'),
      skipped: skipped,
    );
  }

  rendered.sort((a, b) => a.percentage.compareTo(b.percentage));
  final overall = totalFound == 0 ? 0.0 : 100 * totalHit / totalFound;

  final out = Directory(outDir)..createSync(recursive: true);
  File('${out.path}/style.css').writeAsStringSync(_css);
  File('${out.path}/index.html').writeAsStringSync(
    _indexHtml(rendered, overall, totalHit, totalFound),
  );
  for (final report in rendered) {
    final target = File('${out.path}/${report.relative}.html');
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(_fileHtml(report, overall));
  }

  return CoverageReport(
    exitCode: 0,
    message: [
      ...warnings,
      'coverage_html: ${overall.toStringAsFixed(1)}% of $totalFound lines '
          '($totalHit hit) across ${rendered.length} files -> ${out.path}/index.html',
    ].join('\n'),
    percentage: overall,
    hit: totalHit,
    found: totalFound,
    files: [for (final report in rendered) report.relative],
    skipped: skipped,
  );
}

/* ------------------------------------------------------------------------- */
/* lcov parsing                                                              */
/* ------------------------------------------------------------------------- */

/// One `SF:` record: file path plus per-line hit counts.
class LcovFile {
  LcovFile(this.path);
  final String path;
  final Map<int, int> hits = {};

  int get found => hits.length;
  int get hit => hits.values.where((h) => h > 0).length;
}

List<LcovFile> parseLcov(String text) {
  final out = <LcovFile>[];
  LcovFile? current;

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('SF:')) {
      current = LcovFile(line.substring(3));
    } else if (line.startsWith('DA:')) {
      final parts = line.substring(3).split(',');
      final number = parts.isNotEmpty ? int.tryParse(parts[0]) : null;
      final count = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (current != null && number != null && count != null) {
        current.hits[number] = (current.hits[number] ?? 0) + count;
      }
    } else if (line == 'end_of_record') {
      if (current != null) out.add(current);
      current = null;
    }
  }
  if (current != null) out.add(current);
  return out;
}

/// Trims the source root off absolute SF paths and any leading `./`.
String relativeSourcePath(String sfPath, String rootPath) {
  var path = sfPath.replaceAll('\\', '/');
  final root = rootPath.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  if (path.startsWith('$root/')) return path.substring(root.length + 1);
  if (path.startsWith('./')) path = path.substring(2);
  return path;
}

class _Report {
  _Report({required this.relative, required this.hits, required this.source});

  final String relative;
  final Map<int, int> hits;
  final List<String> source;

  int get found => hits.length;
  int get hit => hits.values.where((h) => h > 0).length;
  double get percentage => found == 0 ? 0 : 100 * hit / found;
}

/* ------------------------------------------------------------------------- */
/* HTML                                                                      */
/* ------------------------------------------------------------------------- */

String _bar(double percentage) {
  final tone = percentage >= 80
      ? 'good'
      : percentage >= 50
          ? 'fair'
          : 'poor';
  return '<span class="bar"><span class="fill $tone" style="width:${percentage.clamp(0, 100).toStringAsFixed(1)}%"></span></span>';
}

String _indexHtml(List<_Report> reports, double overall, int hit, int found) {
  final rows = StringBuffer();
  for (final report in reports) {
    final href = Uri.encodeFull('${report.relative}.html');
    rows.writeln(
      '<tr><td class="path"><a href="$href">${_htmlEscape.convert(report.relative)}</a></td>'
      '<td class="pct">${report.percentage.toStringAsFixed(1)}%</td>'
      '<td class="bar-cell">${_bar(report.percentage)}</td>'
      '<td class="nums">${report.hit}/${report.found}</td></tr>',
    );
  }

  return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Friend Chat app coverage</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<main>
  <h1>Friend Chat app coverage</h1>
  <p class="lede">
    <strong>${overall.toStringAsFixed(1)}%</strong> of $found instrumented lines
    ($hit hit) across ${reports.length} files.
    Generated from <code>lcov.info</code> by <code>flutter test --coverage</code>.
  </p>
  <p class="note">
    Only files a test actually loads appear here &mdash; screens and platform
    services that no test imports are absent, not 0%.
  </p>
  <table class="summary">
    <thead><tr><th>File</th><th>Lines</th><th colspan="2">Coverage</th></tr></thead>
    <tbody>
$rows    </tbody>
  </table>
</main>
</body>
</html>
''';
}

String _fileHtml(_Report report, double overall) {
  final rows = StringBuffer();
  final lastLine = report.source.length;
  // The page sits in the same directory tree as the source file, so walking
  // back to the report root is one level per directory, not per path segment.
  final up = '../' * (report.relative.split('/').length - 1);

  for (var number = 1; number <= lastLine; number++) {
    final source = _htmlEscape.convert(report.source[number - 1]);
    final hits = report.hits[number];
    final (kind, count) = hits == null
        ? ('neutral', '')
        : hits > 0
            ? ('hit', '$hits')
            : ('miss', '0');
    rows.writeln(
      '<tr class="$kind"><td class="num">$number</td>'
      '<td class="count">$count</td><td class="src"><pre>$source</pre></td></tr>',
    );
  }

  return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_htmlEscape.convert(report.relative)} — coverage</title>
<link rel="stylesheet" href="${up}style.css">
</head>
<body>
<main class="wide">
  <p class="crumbs"><a href="${up}index.html">&larr; all files</a></p>
  <h1>${_htmlEscape.convert(report.relative)}</h1>
  <p class="lede">
    <strong>${report.percentage.toStringAsFixed(1)}%</strong> of ${report.found}
    instrumented lines (${report.hit} hit). Project total:
    ${overall.toStringAsFixed(1)}%.
  </p>
  <table class="source">
    <tbody>
$rows    </tbody>
  </table>
</main>
</body>
</html>
''';
}

const _css = '''
:root {
  --base: #0b0b14;
  --panel: #15151f;
  --ink: #e8e8f2;
  --dim: #9a9ab0;
  --indigo: #6366f1;
  --mint: #34d399;
  --amber: #f59e0b;
  --rose: #f43f5e;
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 2rem 1rem; background: var(--base); color: var(--ink);
  font: 15px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
}
main { max-width: 62rem; margin: 0 auto; }
main.wide { max-width: 78rem; }
h1 { font-size: 1.5rem; margin: 0 0 .5rem; letter-spacing: -.01em; }
a { color: var(--indigo); text-decoration: none; }
a:hover { text-decoration: underline; }
.lede { color: var(--dim); margin: 0 0 .25rem; }
.lede strong { color: var(--mint); font-size: 1.15rem; }
.note { color: var(--dim); font-size: .85rem; margin: .25rem 0 1.5rem; }
code { background: var(--panel); padding: .1rem .3rem; border-radius: 4px; }
.crumbs { margin: 0 0 .75rem; font-size: .85rem; }
table { width: 100%; border-collapse: collapse; background: var(--panel); border-radius: 10px; overflow: hidden; }
th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid #23233a; }
th { font-size: .75rem; text-transform: uppercase; letter-spacing: .06em; color: var(--dim); }
tbody tr:last-child td { border-bottom: none; }
.path { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85rem; }
.pct { width: 5rem; color: var(--dim); }
.nums { width: 7rem; color: var(--dim); font-variant-numeric: tabular-nums; text-align: right; }
.bar-cell { width: 10rem; }
.bar { display: block; height: 6px; background: #23233a; border-radius: 999px; overflow: hidden; }
.fill { display: block; height: 100%; }
.fill.good { background: var(--mint); }
.fill.fair { background: var(--amber); }
.fill.poor { background: var(--rose); }
table.source td { padding: 0 .5rem; border: none; vertical-align: top; }
table.source tr { border-bottom: none; }
.num { width: 3.5rem; text-align: right; color: #5c5c78; font: 12px/1.6 ui-monospace, Menlo, monospace; user-select: none; }
.count { width: 3rem; text-align: right; color: #5c5c78; font: 12px/1.6 ui-monospace, Menlo, monospace; user-select: none; }
.src pre { margin: 0; font: 12px/1.6 ui-monospace, Menlo, monospace; white-space: pre-wrap; word-break: break-word; }
tr.hit { background: rgba(52, 211, 153, .07); }
tr.hit .count { color: var(--mint); }
tr.miss { background: rgba(244, 63, 94, .10); }
tr.miss .count { color: var(--rose); }
tr.neutral { opacity: .55; }
''';
