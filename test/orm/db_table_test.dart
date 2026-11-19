// Audit probes for the ORM layer (DbTable / DbColumn / DbRecord).
// Every test asserts the CORRECT behaviour.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

class Item extends DbRecord {
  final String name;
  final double? score;
  final Uint8List? data;
  final DateTime? at;
  final bool? flag;
  final int? n;

  const Item({
    super.id,
    required this.name,
    this.score,
    this.data,
    this.at,
    this.flag,
    this.n,
  });

  @override
  Map<String, dynamic> toMap() => {
    'name': name,
    if (score != null) 'score': score,
    if (data != null) 'data': data,
    if (at != null) 'at': at,
    if (flag != null) 'flag': flag,
    if (n != null) 'n': n,
  };
}

class Items extends DbTable<Item> {
  Items([this.extra = const []]);
  final List<DbColumn> extra;

  @override
  String get tableName => 'items';

  @override
  List<DbColumn> get columns => [
    DbColumn.text('name', notNull: true),
    DbColumn.real('score'),
    DbColumn.blob('data'),
    DbColumn.datetime('at'),
    DbColumn.boolean('flag'),
    DbColumn.integer('n'),
    ...extra,
  ];

  @override
  Item fromRow(Map<String, Object?> row) => Item(
    id: row.intValue('id'),
    name: row.stringValue('name')!,
    score: row.doubleValue('score'),
    data: row.bytesValue('data'),
    at: row.dateTimeValue('at'),
    flag: row.boolValue('flag'),
    n: row.intValue('n'),
  );
}

Future<JustDatabase> _db() => JustDatabase.open(
  'orm_${DateTime.now().microsecondsSinceEpoch}',
  persist: false,
);

void main() {
  test('STO orm-blob: a Uint8List field round-trips', () async {
    final db = await _db();
    final t = Items();
    await t.createTable(db);
    final saved = await t.insert(
      db,
      Item(name: 'b', data: Uint8List.fromList([1, 2, 255])),
    );
    final back = await t.findById(db, saved.id!);
    expect(back!.data, Uint8List.fromList([1, 2, 255]));
  });

  test('STO orm-infinity: a double.infinity field is stored or rejected '
      'with a clear error', () async {
    final db = await _db();
    final t = Items();
    await t.createTable(db);
    for (final v in [double.infinity, double.nan]) {
      Item? saved;
      try {
        saved = await t.insert(db, Item(name: 'x', score: v));
      } on DbTableException {
        continue; // rejecting is fine
      }
      // SQLite stores NaN as NULL; infinities are kept.
      if (v.isNaN) {
        expect(saved.score, isNull);
      } else {
        expect(saved.score, v);
      }
    }
  });

  test(
    'STO orm-negative-default: DbColumn.integer(defaultValue: -1)',
    () async {
      final db = await _db();
      final t = Items([DbColumn.integer('lives', defaultValue: -1)]);
      await t.createTable(db);
    },
  );

  test(
    'STO orm-keyword-col: a column named "date" / "key" / "count"',
    () async {
      final db = await _db();
      final failed = <String>[];
      for (final name in [
        'date', 'key', 'count', 'order', 'value', 'text', 'index', 'min',
        'max', 'sum', 'group', 'end', 'set', 'row', 'all', 'to', 'default',
        'type',
        'level',
        'status',
        'time',
        'user',
        'real', // name/data: base columns
        'view', 'action', 'left', 'right', 'limit', 'offset', 'in', 'is',
      ]) {
        final t = Items([DbColumn.text(name)]);
        try {
          await t.dropTable(db);
          await t.createTable(db);
          await t.insert(db, const Item(name: 'z'));
          // where is raw SQL: a reserved word must be quoted there.
          await t.findAll(
            db,
            where: '${quoteIdentifier(name)} IS NULL',
            orderBy: name,
          );
        } catch (e) {
          failed.add(name);
        }
      }
      expect(failed, isEmpty);
    },
  );

  test(
    'STO orm-concurrent-insert: insert() returns the row it inserted',
    () async {
      final db = await _db();
      final t = Items();
      await t.createTable(db);
      final both = await Future.wait([
        t.insert(db, const Item(name: 'A')),
        t.insert(db, const Item(name: 'B')),
      ]);
      expect(both.map((e) => e.name).toList(), ['A', 'B']);
      expect(both[0].id, isNot(both[1].id));
    },
  );

  test(
    'STO orm-datetime: a DateTime field round-trips as the same instant',
    () async {
      final db = await _db();
      final t = Items();
      await t.createTable(db);
      final at = DateTime(2024, 5, 6, 7, 8, 9, 10, 11); // local
      final saved = await t.insert(db, Item(name: 'd', at: at));
      expect(
        saved.at!.isAtSameMomentAs(at),
        isTrue,
        reason: '${saved.at} vs $at',
      );
    },
  );

  test('STO orm-bool: a bool field round-trips', () async {
    final db = await _db();
    final t = Items();
    await t.createTable(db);
    final saved = await t.insert(db, const Item(name: 'f', flag: false));
    expect(saved.flag, false);
  });

  test('STO orm-insertAll-in-tx: insertAll inside db.transaction', () async {
    final db = await _db();
    final t = Items();
    await t.createTable(db);
    await db.transaction((_) async {
      await t.insertAll(db, const [Item(name: 'a'), Item(name: 'b')]);
    });
    expect(await t.count(db), 2);
  });
}
