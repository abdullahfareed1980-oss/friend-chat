import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tools/coverage_html.dart';

/// Tests for the coverage report generator. It is a CLI, but everything below
/// the `main()` wrapper is a plain function, so it is exercised in-process:
/// lcov parsing, path handling, the failure exits, and the HTML it writes.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cov-html-test-');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File writeFile(String relative, String content) {
    final file = File('${tmp.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  String writeLcov(String content) => writeFile('lcov.info', content).path;

  group('parseLcov', () {
    test('reads SF/DA records and totals covered vs instrumented lines', () {
      final files = parseLcov('''
SF:lib/a.dart
DA:1,3
DA:2,0
DA:3,1
LF:3
LH:2
end_of_record
SF:lib/b.dart
DA:10,0
LF:1
LH:0
end_of_record
''');

      expect(files, hasLength(2));
      expect(files[0].path, 'lib/a.dart');
      expect(files[0].found, 3);
      expect(files[0].hit, 2);
      expect(files[0].hits[2], 0);
      expect(files[1].path, 'lib/b.dart');
      expect(files[1].hit, 0);
      expect(files[1].found, 1);
    });

    test('sums repeated DA records for the same line', () {
      final files = parseLcov('SF:lib/x.dart\nDA:7,2\nDA:7,5\nend_of_record\n');

      expect(files.single.hits[7], 7);
      expect(files.single.hit, 1);
      expect(files.single.found, 1);
    });

    test('ignores malformed records instead of throwing', () {
      final files = parseLcov('''
TN:
SF:lib/x.dart
DA:notanumber,1
DA:5,alsonotanumber
DA:9,4
FNDA:2,crazy
BRDA:1,0,0,1
end_of_record
DA:12,9
''');

      expect(files, hasLength(1));
      expect(files.single.hits.keys, [9]);
      expect(files.single.hit, 1);
    });

    test('tolerates CRLF line endings and blank lines', () {
      final files = parseLcov('SF:lib/x.dart\r\n\r\nDA:1,1\r\nDA:2,0\r\nend_of_record\r\n');

      expect(files.single.found, 2);
      expect(files.single.hit, 1);
    });

    test('returns nothing when there are no records', () {
      expect(parseLcov(''), isEmpty);
      expect(parseLcov('TN:\nrandom junk\n'), isEmpty);
    });
  });

  group('relativeSourcePath', () {
    test('keeps a package-relative path', () {
      expect(relativeSourcePath('lib/data/x.dart', '/repo/app'), 'lib/data/x.dart');
    });

    test('strips a leading ./', () {
      expect(relativeSourcePath('./lib/x.dart', '/repo/app'), 'lib/x.dart');
    });

    test('strips the absolute source root', () {
      expect(relativeSourcePath('/repo/app/lib/data/x.dart', '/repo/app'), 'lib/data/x.dart');
    });

    test('strips a root that ends with a slash', () {
      expect(relativeSourcePath('/repo/app/lib/x.dart', '/repo/app/'), 'lib/x.dart');
    });

    test('normalises Windows separators', () {
      expect(relativeSourcePath(r'C:\repo\app\lib\x.dart', r'C:\repo\app'), 'lib/x.dart');
    });

    test('leaves a path outside the root alone, so it is skipped later', () {
      expect(relativeSourcePath('/somewhere/else/x.dart', '/repo/app'), '/somewhere/else/x.dart');
    });
  });

  group('buildReport — failures', () {
    test('missing lcov is an error with a hint', () {
      final result = buildReport(
        lcovPath: '${tmp.path}/nope.info',
        outDir: '${tmp.path}/out',
        sourceRoot: tmp.path,
      );

      expect(result.exitCode, 1);
      expect(result.ok, isFalse);
      expect(result.message, contains('no such file'));
      expect(result.message, contains('flutter test --coverage'));
      expect(Directory('${tmp.path}/out').existsSync(), isFalse);
    });

    test('an lcov with no records is an error, not an empty report', () {
      final result = buildReport(
        lcovPath: writeLcov('TN:\n'),
        outDir: '${tmp.path}/out',
        sourceRoot: tmp.path,
      );

      expect(result.exitCode, 1);
      expect(result.message, contains('no SF:/DA: records'));
    });

    test('a file with no instrumented lines is skipped, not rendered at 0%', () {
      writeFile('lib/plain.dart', 'a\n');
      final lcov = writeLcov('''
SF:lib/plain.dart
end_of_record
SF:lib/counted.dart
DA:1,1
end_of_record
''');
      writeFile('lib/counted.dart', 'x\n');

      final result = buildReport(lcovPath: lcov, outDir: '${tmp.path}/out', sourceRoot: tmp.path);

      expect(result.ok, isTrue);
      expect(result.files, ['lib/counted.dart']);
      expect(result.skipped, ['lib/plain.dart']);
      expect(result.message, contains('skipping lib/plain.dart (no instrumented lines)'));
      expect(File('${tmp.path}/out/lib/plain.dart.html').existsSync(), isFalse);
    });

    test('when no listed source exists it fails and writes nothing', () {
      final result = buildReport(
        lcovPath: writeLcov('SF:lib/gone.dart\nDA:1,1\nend_of_record\n'),
        outDir: '${tmp.path}/out',
        sourceRoot: tmp.path,
      );

      expect(result.exitCode, 1);
      expect(result.skipped, ['lib/gone.dart']);
      expect(result.message, contains('none of the 1 files had readable sources'));
      expect(Directory('${tmp.path}/out').existsSync(), isFalse,
          reason: 'a failed run should not leave an empty report directory');
    });
  });

  group('buildReport — output', () {
    test('writes index, css and one page per file, worst coverage first', () {
      writeFile('lib/low.dart', 'a\nb\nc\nd\n');
      writeFile('lib/high.dart', 'x\ny\n');
      final lcov = writeLcov('''
SF:lib/low.dart
DA:1,1
DA:2,0
DA:3,0
DA:4,0
end_of_record
SF:lib/high.dart
DA:1,5
DA:2,7
end_of_record
''');

      final result = buildReport(
        lcovPath: lcov,
        outDir: '${tmp.path}/out',
        sourceRoot: tmp.path,
      );

      expect(result.ok, isTrue);
      expect(result.hit, 3);
      expect(result.found, 6);
      expect(result.percentage, closeTo(50.0, 0.001));
      expect(result.files, ['lib/low.dart', 'lib/high.dart']);
      expect(result.message, contains('50.0% of 6 lines'));

      expect(File('${tmp.path}/out/index.html').existsSync(), isTrue);
      expect(File('${tmp.path}/out/style.css').existsSync(), isTrue);
      expect(File('${tmp.path}/out/lib/low.dart.html').existsSync(), isTrue);
      expect(File('${tmp.path}/out/lib/high.dart.html').existsSync(), isTrue);

      final index = File('${tmp.path}/out/index.html').readAsStringSync();
      expect(index, contains('25.0%'));
      expect(index, contains('100.0%'));
      expect(index, contains('href="lib/low.dart.html"'));
    });

    test('a missing source is skipped, but the rest still renders', () {
      writeFile('lib/keep.dart', 'one\ntwo\n');
      final lcov = writeLcov('''
SF:lib/keep.dart
DA:1,1
DA:2,0
end_of_record
SF:lib/gone.dart
DA:1,1
end_of_record
''');

      final result = buildReport(
        lcovPath: lcov,
        outDir: '${tmp.path}/out',
        sourceRoot: tmp.path,
      );

      expect(result.ok, isTrue);
      expect(result.skipped, ['lib/gone.dart']);
      expect(result.found, 2, reason: 'the skipped file must not inflate the total');
      expect(result.message, contains('skipping lib/gone.dart'));
      expect(File('${tmp.path}/out/lib/keep.dart.html').existsSync(), isTrue);
      expect(File('${tmp.path}/out/lib/gone.dart.html').existsSync(), isFalse);
    });

    test('marks hit, missed and non-instrumented lines with their counts', () {
      writeFile('lib/mixed.dart', 'line one\nline two\nline three\n');
      final lcov = writeLcov('SF:lib/mixed.dart\nDA:2,4\nDA:3,0\nend_of_record\n');

      buildReport(lcovPath: lcov, outDir: '${tmp.path}/out', sourceRoot: tmp.path);
      final page = File('${tmp.path}/out/lib/mixed.dart.html').readAsStringSync();

      expect(RegExp('<tr class="neutral"><td class="num">1</td>').hasMatch(page), isTrue);
      expect(page, contains('<tr class="hit"><td class="num">2</td><td class="count">4</td>'));
      expect(page, contains('<tr class="miss"><td class="num">3</td><td class="count">0</td>'));
      expect(page, contains('line two'));
    });

    test('escapes source and file names but not slashes', () {
      writeFile('lib/weird&name.dart', 'final s = "<script>alert(1)</script> & co";\n');
      final lcov = writeLcov('SF:lib/weird&name.dart\nDA:1,1\nend_of_record\n');

      buildReport(lcovPath: lcov, outDir: '${tmp.path}/out', sourceRoot: tmp.path);
      final page = File('${tmp.path}/out/lib/weird&name.dart.html').readAsStringSync();
      final index = File('${tmp.path}/out/index.html').readAsStringSync();

      expect(page, isNot(contains('<script>alert')));
      expect(page, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
      expect(page, contains('&amp; co'));
      // Element-mode escaping leaves paths readable.
      expect(index, contains('lib/weird&amp;name.dart'));
      expect(index, isNot(contains('&#47;')));
    });

    test('links back to the root with the right depth for nested files', () {
      writeFile('lib/x.dart', 'a\n');
      writeFile('lib/data/y.dart', 'b\n');
      final lcov = writeLcov('''
SF:lib/x.dart
DA:1,1
end_of_record
SF:lib/data/y.dart
DA:1,1
end_of_record
''');

      buildReport(lcovPath: lcov, outDir: '${tmp.path}/out', sourceRoot: tmp.path);

      final shallow = File('${tmp.path}/out/lib/x.dart.html').readAsStringSync();
      final deep = File('${tmp.path}/out/lib/data/y.dart.html').readAsStringSync();

      expect(shallow, contains('href="../style.css"'));
      expect(shallow, contains('href="../index.html"'));
      expect(deep, contains('href="../../style.css"'));
      expect(deep, contains('href="../../index.html"'));

      // The implied targets really exist.
      expect(File('${tmp.path}/out/lib/../style.css').existsSync(), isTrue);
      expect(File('${tmp.path}/out/lib/data/../../style.css').existsSync(), isTrue);
      expect(File('${tmp.path}/out/lib/data/../../index.html').existsSync(), isTrue);
    });

    test('rounds the percentage to one decimal', () {
      writeFile('lib/third.dart', 'a\nb\nc\n');
      final lcov = writeLcov('SF:lib/third.dart\nDA:1,1\nDA:2,0\nDA:3,0\nend_of_record\n');

      final result = buildReport(lcovPath: lcov, outDir: '${tmp.path}/out', sourceRoot: tmp.path);

      expect(result.percentage.toStringAsFixed(1), '33.3');
      expect(File('${tmp.path}/out/index.html').readAsStringSync(), contains('33.3%'));
    });

    test('an empty source file still produces a page', () {
      writeFile('lib/empty.dart', '');
      final lcov = writeLcov('SF:lib/empty.dart\nDA:1,0\nend_of_record\n');

      final result = buildReport(lcovPath: lcov, outDir: '${tmp.path}/out', sourceRoot: tmp.path);

      expect(result.ok, isTrue);
      expect(result.found, 1);
      expect(result.hit, 0);
      expect(File('${tmp.path}/out/lib/empty.dart.html').existsSync(), isTrue);
    });
  });
}
