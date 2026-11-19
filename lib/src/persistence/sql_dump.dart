import 'package:flutter/foundation.dart' show internal;

import '../storage/catalog.dart';
import '../storage/schema.dart';
import '../storage/values.dart';

/// A SQL script that recreates everything [catalog] holds: tables with
/// their rows (and rowids), indexes, views, triggers and `user_version`,
/// inside one transaction.
///
/// AUTOINCREMENT's high-water mark is not part of the script (the JSON
/// export keeps it): after a restore it is the largest rowid.
@internal
String dumpSql(Catalog catalog) {
  final b = StringBuffer('-- just_database SQL dump\nBEGIN;\n');
  for (final t in catalog.tables) {
    b.writeln('${t.schema.sql};');
  }
  for (final t in catalog.tables) {
    final cols = t.schema.columns;
    final keepRowid =
        t.schema.rowidAlias == null &&
        !cols.any(
          (c) =>
              const {'rowid', 'oid', '_rowid_'}.contains(c.name.toLowerCase()),
        );
    final names = [
      if (keepRowid) '"rowid"',
      for (final c in cols) quoteIdentifier(c.name),
    ].join(', ');
    final table = quoteIdentifier(t.name);
    for (final e in t.entries) {
      final values = [
        if (keepRowid) '${e.key}',
        for (final v in e.value) sqlLiteral(v),
      ].join(', ');
      b.writeln('INSERT INTO $table ($names) VALUES ($values);');
    }
  }
  for (final t in catalog.tables) {
    final cols = t.schema.columns;
    for (final i in t.indexes) {
      if (i.origin != IndexOrigin.manual) continue;
      final parts = [
        for (var k = 0; k < i.columns.length; k++)
          '${quoteIdentifier(cols[i.columns[k]].name)}'
              '${i.collations[k] == Collation.binary ? '' : ' COLLATE ${i.collations[k].name.toUpperCase()}'}',
      ];
      b.writeln(
        'CREATE ${i.unique ? 'UNIQUE ' : ''}INDEX ${quoteIdentifier(i.name)} '
        'ON ${quoteIdentifier(t.name)} (${parts.join(', ')});',
      );
    }
    for (final s in t.spatialIndexes) {
      b.writeln(
        'CREATE SPATIAL INDEX ${quoteIdentifier(s.name)} ON ${quoteIdentifier(t.name)} '
        '(${quoteIdentifier(cols[s.xColumn].name)}, ${quoteIdentifier(cols[s.yColumn].name)});',
      );
    }
  }
  for (final v in catalog.views) {
    b.writeln('${v.sql};');
  }
  for (final t in catalog.triggers) {
    b.writeln('${t.sql};');
  }
  if (catalog.userVersion != 0) {
    b.writeln('PRAGMA user_version = ${catalog.userVersion};');
  }
  b.writeln('COMMIT;');
  return b.toString();
}
