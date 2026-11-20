// Runs SQL on a bare engine (no JustDatabase): the SQL, storage and
// harness-based tests use it.
import 'package:just_database/just_database.dart';
import 'package:just_database/src/engine/engine.dart';
import 'package:just_database/src/sql/parser.dart';
import 'package:just_database/src/storage/catalog.dart';

class EngineHarness {
  EngineHarness([Object? _]) : engine = Engine(Catalog());
  final Engine engine;

  List<String> get triggerNames => [
    for (final t in engine.catalog.triggers) t.name,
  ];
  List<String> get viewNames => [for (final v in engine.catalog.views) v.name];
  TableSchema? schemaOf(String table) => engine.catalog.table(table)?.schema;

  Future<QueryResult> executeSQL(String sql) async {
    try {
      final p = Parser.parseOne(sql);
      final r = engine.execute(p, const []);
      return QueryResult.success(
        columns: r.columns,
        values: r.rows,
        affectedRows: r.changes,
        lastInsertRowId: r.lastInsertRowId,
      );
    } on SqlException catch (e) {
      return QueryResult.failure(e);
    }
  }
}
