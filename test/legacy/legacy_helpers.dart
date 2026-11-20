// Shared helpers for the 1.x tests ported to the 2.0 API.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

int _counter = 0;

/// A database name nobody else in this test run uses.
String uniqueName(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_counter++}';

/// Opens a fresh in-memory database with a unique name.
Future<JustDatabase> openMemory([String prefix = 'legacy']) =>
    JustDatabase.open(uniqueName(prefix), persist: false);

/// Runs [sql] on [db] and expects it to succeed.
Future<QueryResult> exec(
  JustDatabase db,
  String sql, [
  Object? parameters,
]) async {
  final result = await db.execute(sql, parameters);
  expect(result.success, isTrue, reason: '$sql\n→ ${result.errorMessage}');
  return result;
}

/// Runs the SELECT [sql] on [db], expects it to succeed and returns its rows.
Future<List<Map<String, Object?>>> rows(
  JustDatabase db,
  String sql, [
  Object? parameters,
]) async {
  final result = await db.query(sql, parameters);
  expect(result.success, isTrue, reason: '$sql\n→ ${result.errorMessage}');
  return result.rows;
}

/// Closes every database still open (for tearDown).
Future<void> closeAllOpen() async {
  await DatabaseManager.closeAll();
  for (final db in JustDatabase.openDatabases) {
    try {
      await db.closeAll();
    } catch (_) {
      // A failed final save; the database is closed anyway.
    }
  }
}
