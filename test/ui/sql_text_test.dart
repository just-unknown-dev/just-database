// The admin UI's text helpers: SQL highlighting, statement splitting,
// completion, parameter values, CSV/JSON export and the hex dump.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/src/ui/admin_selection.dart';
import 'package:just_database/src/ui/admin_utils.dart';
import 'package:just_database/src/ui/dialogs/value_inspector.dart';
import 'package:just_database/src/ui/sql_text.dart';

void main() {
  final colors = SqlColors.of(const ColorScheme.light());

  String textOf(List<TextSpan> spans) => spans.map((s) => s.text).join();

  group('highlightSql', () {
    test('keeps the text and styles keywords, strings, numbers, comments', () {
      const sql =
          "SELECT name, COUNT(*) FROM t -- why\nWHERE x = 'a''b' AND n > 3.5 AND p = :p";
      final spans = highlightSql(sql, colors: colors, tables: {'t'});
      expect(textOf(spans), sql);
      Color? colorOf(String text) =>
          spans.firstWhere((s) => s.text == text).style?.color;
      expect(colorOf('SELECT'), colors.keyword);
      expect(colorOf('COUNT'), colors.function);
      expect(colorOf("'a''b'"), colors.string);
      expect(colorOf('3.5'), colors.number);
      expect(colorOf(':p'), colors.parameter);
      expect(colorOf('t'), colors.table);
      expect(spans.any((s) => s.text!.contains('-- why')), isTrue);
      expect(
        spans.firstWhere((s) => s.text!.contains('-- why')).style?.color,
        colors.comment,
      );
    });

    test('an unterminated string keeps the text and the string style', () {
      const sql = "SELECT 'oops";
      final spans = highlightSql(sql, colors: colors);
      expect(textOf(spans), sql);
      expect(spans.last.style?.color, colors.string);
    });

    test('an unterminated comment is styled as a comment', () {
      const sql = 'SELECT 1 /* not closed';
      final spans = highlightSql(sql, colors: colors);
      expect(textOf(spans), sql);
      expect(spans.last.style?.color, colors.comment);
    });
  });

  group('splitStatements', () {
    String parts(String sql) => splitStatements(
      sql,
    ).map((r) => sql.substring(r.start, r.end)).join(' | ');

    test('splits at semicolons outside strings and comments', () {
      expect(
        parts("SELECT ';'; -- a;b\nINSERT INTO t VALUES (1);;  "),
        "SELECT ';' | INSERT INTO t VALUES (1)",
      );
    });

    test('keeps a trigger body together', () {
      const sql =
          'CREATE TRIGGER tr AFTER INSERT ON t BEGIN '
          'UPDATE t SET n = CASE WHEN n > 1 THEN 1 ELSE 0 END; '
          'DELETE FROM log; END; SELECT 1';
      final ranges = splitStatements(sql);
      expect(ranges, hasLength(2));
      expect(
        sql.substring(ranges.first.start, ranges.first.end),
        endsWith('END'),
      );
      expect(sql.substring(ranges.last.start, ranges.last.end), 'SELECT 1');
    });

    test('BEGIN as a statement is just a statement', () {
      expect(
        parts('BEGIN; INSERT INTO t VALUES (1); COMMIT'),
        'BEGIN | INSERT INTO t VALUES (1) | COMMIT',
      );
    });

    test('an unterminated string ends the last statement', () {
      expect(parts("SELECT 1; SELECT 'x"), "SELECT 1 | SELECT 'x");
    });

    test('statementAt finds the statement around or before the caret', () {
      const sql = 'SELECT 1;\nSELECT 2;\n';
      expect(statementAt(sql, 3), (start: 0, end: 8));
      expect(statementAt(sql, 12), (start: 10, end: 18));
      expect(statementAt(sql, sql.length), (start: 10, end: 18));
      expect(statementAt('', 0), isNull);
    });
  });

  test('statementLabel names the verb and object', () {
    expect(statementLabel('select * from t'), 'SELECT');
    expect(statementLabel('INSERT INTO notes VALUES (1)'), 'INSERT INTO notes');
    expect(statementLabel('update people set a = 1'), 'UPDATE people');
    expect(statementLabel('CREATE TABLE IF NOT EXISTS x (a)'), 'CREATE TABLE');
    expect(
      statementLabel('CREATE UNIQUE INDEX i ON t (a)'),
      'CREATE UNIQUE INDEX i',
    );
    expect(statementLabel('PRAGMA user_version'), 'PRAGMA user_version');
  });

  test('lineAndColumn counts from 1', () {
    expect(lineAndColumn('ab\ncd', 0), (line: 1, column: 1));
    expect(lineAndColumn('ab\ncd', 4), (line: 2, column: 2));
  });

  group('completion', () {
    final columns = {
      'people': ['id', 'name', 'email'],
      'notes': ['id', 'person_id', 'body'],
    };
    final names = ['people', 'notes'];

    test('wordAt reads the word and a qualifier', () {
      expect(wordAt('SELECT na', 9), (start: 7, prefix: 'na', qualifier: null));
      expect(wordAt('SELECT p.na', 11), (
        start: 9,
        prefix: 'na',
        qualifier: 'p',
      ));
      expect(wordAt('SELECT p.', 9), (start: 9, prefix: '', qualifier: 'p'));
      expect(wordAt('SELECT ', 7), isNull);
      expect(wordAt('LIMIT 1', 7), isNull);
    });

    test('columns of the named tables come first', () {
      const sql = 'SELECT b FROM notes';
      final word = wordAt(sql, 8)!;
      final c = completionsFor(
        word: word,
        statement: sql,
        names: names,
        columns: columns,
      );
      expect(c.first, 'body');
      expect(c, contains('between'), reason: 'a lowercase prefix');
    });

    test('a qualifier (alias or table) lists its columns', () {
      const sql = 'SELECT n.b FROM notes AS n';
      final word = wordAt(sql, 10)!;
      expect(
        completionsFor(
          word: word,
          statement: sql,
          names: names,
          columns: columns,
        ),
        ['body'],
      );
      const sql2 = 'SELECT people. FROM people';
      expect(
        completionsFor(
          word: wordAt(sql2, 14)!,
          statement: sql2,
          names: names,
          columns: columns,
        ),
        ['id', 'name', 'email'],
      );
    });

    test('keywords follow the case of what was typed', () {
      const sql = 'sel';
      expect(
        completionsFor(
          word: wordAt(sql, 3)!,
          statement: sql,
          names: names,
          columns: columns,
        ),
        contains('select'),
      );
    });

    test('referencedTables reads tables and aliases', () {
      expect(referencedTables('SELECT * FROM people p JOIN notes AS n ON 1'), {
        'people': 'people',
        'p': 'people',
        'notes': 'notes',
        'n': 'notes',
      });
      expect(referencedTables('INSERT INTO "my t" VALUES (1)'), {
        'my t': 'my t',
      });
    });
  });

  test('parseParameterText reads literals; anything else is text', () {
    expect(parseParameterText('NULL'), isNull);
    expect(parseParameterText(' 42 '), 42);
    expect(parseParameterText('-3.5e2'), -350.0);
    expect(parseParameterText("'it''s'"), "it's");
    expect(parseParameterText("x'0A0b'"), Uint8List.fromList([10, 11]));
    expect(parseParameterText('true'), 1);
    expect(parseParameterText('Ann'), 'Ann');
    expect(parseParameterText(''), '');
  });

  test('sqlName quotes only what needs it', () {
    expect(sqlName('people'), 'people');
    expect(sqlName('order'), '"order"');
    expect(sqlName('my table'), '"my table"');
    expect(sqlName('a"b'), '"a""b"');
  });

  group('exports', () {
    test('CSV quotes what needs quoting; NULL is empty; BLOB is hex', () {
      final csv = rowsToCsv(
        ['a', 'b', 'c'],
        [
          [1, 'x,y', null],
          [
            'say "hi"',
            'two\nlines',
            Uint8List.fromList([255, 0]),
          ],
        ],
      );
      expect(csv, 'a,b,c\r\n1,"x,y",\r\n"say ""hi""","two\nlines",FF00');
    });

    test('JSON keeps types; BLOBs and non-finite reals are marked', () {
      final json =
          jsonDecode(
                rowsToJson(
                  ['n', 'r', 'b'],
                  [
                    [
                      1,
                      double.infinity,
                      Uint8List.fromList([1, 2]),
                    ],
                  ],
                ),
              )
              as List;
      expect(json.single, {
        'n': 1,
        'r': 'Infinity',
        'b': {r'$blob': 'AQI='},
      });
    });

    test('exportFileName is name-date-time.ext', () {
      expect(
        exportFileName('saves', 'sql', DateTime(2026, 11, 20, 9, 5, 7)),
        'saves-20261120-090507.sql',
      );
    });

    test('hexDump shows offset, hex and ASCII', () {
      final dump = hexDump(Uint8List.fromList('Hello, world!\x00'.codeUnits));
      expect(
        dump,
        startsWith('00000000  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 00'),
      );
      expect(dump, contains('Hello, world!.'));
    });
  });

  test('a selection falls back to the first pane its object has', () {
    final s = AdminSelection(
      'db',
      kind: AdminObjectKind.trigger,
      object: 't',
      pane: AdminPane.data,
    );
    expect(s.pane, AdminPane.structure);
    expect(AdminSelection('db').pane, AdminPane.overview);
    expect(
      AdminSelection('DB', kind: AdminObjectKind.table, object: 'T'),
      AdminSelection('db', kind: AdminObjectKind.table, object: 't'),
    );
  });
}
