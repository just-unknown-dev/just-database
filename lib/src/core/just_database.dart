import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, internal;

import '../engine/engine.dart';
import '../persistence/codec.dart';
import '../persistence/crypto.dart';
import '../persistence/sql_dump.dart';
import '../persistence/store.dart';
import '../sql/parser.dart';
import '../sql/sql_exception.dart';
import '../storage/catalog.dart';
import '../storage/schema.dart';
import '../storage/values.dart';
import 'async_lock.dart';
import 'database_change.dart';
import 'database_manager.dart';
import 'database_mode.dart';
import 'migration.dart';
import '../io/file_store.dart'
    if (dart.library.js_interop) '../web/idb_store.dart';
import 'query_builder.dart';
import 'query_result.dart';

/// A SQL database: an in-memory SQLite-style engine, saved to a file
/// (IndexedDB on the web) after every committed change.
///
/// ```dart
/// final db = await JustDatabase.open('app');
/// await db.execute('CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT)');
/// await db.execute('INSERT INTO users (name) VALUES (?)', ['Ann']);
/// final r = await db.query('SELECT * FROM users WHERE name = :name', {'name': 'Ann'});
/// print(r.rows);
/// await db.close();
/// ```
///
/// Opening a name that is already open returns the same instance;
/// [close] then only closes it when every opener has closed it.
final class JustDatabase {
  JustDatabase._(this.name, this.mode, this.persist, this._encryptionKey);

  /// The database's name (also its file name).
  final String name;

  /// How statements are ordered and saves batched.
  final DatabaseMode mode;

  /// Whether the database is saved (to a file, or IndexedDB on the web).
  /// False for an in-memory database, and after storage became unavailable.
  bool persist;

  // The passphrase openers must give (changeEncryptionKey replaces it).
  String? _encryptionKey;

  /// How long [DatabaseMode.writeFast] waits to batch changes into one
  /// save.
  static Duration writeFastDelay = const Duration(milliseconds: 250);

  /// Called when persistent storage turned out to be unavailable (the web
  /// in some private windows) and [open] fell back to an in-memory
  /// database.
  static void Function(String name, String reason)? onStorageDowngrade;

  /// Called when a save in the background fails. [flush] and [close]
  /// throw the error too.
  void Function(Object error, StackTrace stack)? onSaveError;

  static final Map<String, JustDatabase> _registry = {};
  static final Map<String, Future<JustDatabase>> _opening = {};
  static final Map<String, Future<void>> _closing = {};

  Catalog _catalog = Catalog();
  late Engine _engine = Engine(_catalog);
  final AsyncLock _lock = AsyncLock();
  DatabaseStore? _store;
  FileKey? _fileKey;
  Future<void> Function()? _releaseLock;
  int _refs = 1;
  bool _isOpen = true;
  int _txDepth = 0;

  // Saving.
  int _savedMutations = 0;
  Future<void>? _saving;
  bool _saveAgain = false;
  Timer? _batchTimer;
  Object? _saveError;
  StackTrace? _saveStack;

  // Change events.
  final StreamController<DatabaseChange> _changes =
      StreamController<DatabaseChange>.broadcast();
  int _notifiedMutations = 0;
  int _notifiedSchema = 0;
  bool _changeScheduled = false;
  Set<String>? _replacedTables;

  // ---------------------------------------------------------------------------
  // Opening and closing
  // ---------------------------------------------------------------------------

  /// Opens (or creates) the database [name].
  ///
  /// [name] is 1–128 letters, digits, `_`, `.` or `-` ([ArgumentError]
  /// otherwise). With [persist] (the default) the database lives in a file
  /// in the app's support directory, or IndexedDB on the web; with
  /// [encryptionKey] that file is AES-256-GCM encrypted with a key derived
  /// from the passphrase by PBKDF2-HMAC-SHA256 (600 000 iterations, a
  /// random salt per file).
  ///
  /// Opening a name that is open already returns that instance; it must
  /// have been opened with the same [mode], [persist] and [encryptionKey]
  /// ([StateError] otherwise).
  ///
  /// Throws [StateError] when the file cannot be read (damaged, written by
  /// a newer version, the wrong key, encrypted but no key given, or open in
  /// another process). The file is left as it is.
  static Future<JustDatabase> open(
    String name, {
    DatabaseMode mode = DatabaseMode.standard,
    bool persist = true,
    String? encryptionKey,
  }) async {
    validateDatabaseName(name);
    if (encryptionKey != null && encryptionKey.isEmpty) {
      throw ArgumentError(
        'An encryptionKey must not be empty.',
        'encryptionKey',
      );
    }
    if (encryptionKey != null && !persist) {
      throw ArgumentError(
        'An encryptionKey needs persist: true (an in-memory database is never written).',
        'encryptionKey',
      );
    }
    final key = name.toLowerCase();
    // A close of this name still saving holds its file: wait for it.
    final closing = _closing[key];
    if (closing != null) await closing.catchError((Object _) {});
    final pending = _opening[key];
    if (pending != null) {
      await pending.catchError(
        (Object _) => JustDatabase._(name, mode, false, null),
      );
    }
    final existing = _registry[key];
    if (existing != null) {
      final sameKey =
          (existing._encryptionKey == null) == (encryptionKey == null) &&
          (encryptionKey == null ||
              constantTimeEquals(existing._encryptionKey!, encryptionKey));
      if (existing.mode != mode ||
          existing._requestedPersist != persist ||
          !sameKey) {
        throw StateError(
          'database $name is already open with a different mode, persist '
          'setting or encryptionKey',
        );
      }
      existing._refs++;
      return existing;
    }
    final db = JustDatabase._(name, mode, persist, encryptionKey)
      .._requestedPersist = persist;
    final future = db._load().then((_) => db);
    _opening[key] = future;
    try {
      await future;
      db
        .._notifiedMutations = db._catalog.log.mutations
        .._notifiedSchema = db._catalog.schemaVersion;
      db._catalog.log.takeTouched();
      _registry[key] = db;
      DatabaseManager.notifyListChanged();
      return db;
    } finally {
      _opening.remove(key);
    }
  }

  late bool _requestedPersist;

  Future<void> _load() async {
    if (!persist) return;
    final store = createPlatformStore();
    _store = store;
    try {
      try {
        _releaseLock = await store.lock(name);
      } on StorageUnavailableException catch (e) {
        _downgrade(e.reason);
        return;
      }
      Uint8List? bytes;
      try {
        bytes = await store.read(name);
      } on StorageUnavailableException catch (e) {
        _downgrade(e.reason);
        return;
      }
      final passphrase = _encryptionKey;
      if (bytes == null) {
        if (passphrase != null) {
          _fileKey = await FileKey.create(store, passphrase);
        }
        // Write the new, empty database now, so it exists (and is listed,
        // encrypted or not) before its first change.
        _savedMutations = -1;
        await _saveOnce();
        final e = _saveError;
        if (e != null) {
          Error.throwWithStackTrace(e, _saveStack ?? StackTrace.current);
        }
        return;
      }
      Uint8List plain;
      if (looksEncrypted(bytes)) {
        if (passphrase == null) {
          throw StateError(
            'database $name is encrypted; open it with its encryptionKey '
            '(${store.describe(name)})',
          );
        }
        try {
          final (p, k) = await openDatabase(store, passphrase, bytes);
          plain = p;
          _fileKey = k ?? await FileKey.create(store, passphrase);
          if (k == null) _savedMutations = -1; // re-save as format 2
        } on StateError {
          throw StateError(
            'wrong encryptionKey for database $name, or the file is damaged '
            '(${store.describe(name)})',
          );
        }
      } else {
        if (passphrase != null) {
          throw StateError(
            'database $name is not encrypted; open it without an encryptionKey '
            'and call changeEncryptionKey() to encrypt it',
          );
        }
        plain = bytes;
      }
      Catalog catalog;
      try {
        final json = jsonDecode(utf8.decode(plain, allowMalformed: false));
        if (json is! Map<String, Object?>) {
          throw const FormatException('not an object');
        }
        catalog = decodeCatalog(json);
        if ((json['version'] as int?) != currentFormatVersion) {
          _savedMutations = -1;
        }
      } on FormatException catch (e) {
        throw StateError(
          'database $name could not be read (${store.describe(name)}): ${e.message}. '
          'The file was left untouched.',
        );
      }
      _catalog = catalog;
      _engine = Engine(catalog);
      if (_savedMutations == 0) _savedMutations = catalog.log.mutations;
    } catch (_) {
      final release = _releaseLock;
      _releaseLock = null;
      await release?.call();
      rethrow;
    }
  }

  void _downgrade(String reason) {
    persist = false;
    _store = null;
    final release = _releaseLock;
    _releaseLock = null;
    unawaited(release?.call());
    onStorageDowngrade?.call(name, reason);
    DatabaseManager.notifyListChanged();
    debugPrint('just_database: $name is in memory only: $reason');
  }

  /// Whether this instance is open.
  bool get isOpen => _isOpen;

  /// Why [name] cannot name a database (1–128 letters, digits, `_`, `.` or
  /// `-`, not starting with `.` or `-`, no `..`, not ending with `.`, not a
  /// device name such as `CON`), or null when it can.
  static String? nameProblem(String name) => databaseNameProblem(name);

  /// The open databases, by name.
  static List<JustDatabase> get openDatabases =>
      List.unmodifiable(_registry.values);

  /// The open database named [name], or null.
  static JustDatabase? findOpen(String name) => _registry[name.toLowerCase()];

  /// Closes this opener's use of the database. When every opener has
  /// closed it: waits for running statements, rolls back an open
  /// transaction, saves, and releases the file. Closing twice is harmless.
  ///
  /// Throws the error of the final save, if it fails (the database is
  /// closed anyway).
  Future<void> close() async {
    if (!_isOpen) return;
    if (--_refs > 0) return;
    await _shutDown();
  }

  /// Closes every opener's use at once (used before deleting the file).
  Future<void> closeAll() async {
    if (!_isOpen) return;
    _refs = 0;
    await _shutDown();
  }

  Future<void> _shutDown() async {
    _isOpen = false;
    final key = name.toLowerCase();
    _registry.remove(key);
    final done = Completer<void>();
    _closing[key] = done.future;
    try {
      await _lock.run(() => _engine.rollbackOpenTransaction());
      _batchTimer?.cancel();
      _batchTimer = null;
      await _flushSaves(force: true);
    } finally {
      final release = _releaseLock;
      _releaseLock = null;
      await release?.call();
      if (identical(_closing[key], done.future)) _closing.remove(key);
      done.complete();
      unawaited(_changes.close());
      DatabaseManager.notifyListChanged();
    }
    final e = _saveError;
    if (e != null) {
      _saveError = null;
      Error.throwWithStackTrace(e, _saveStack ?? StackTrace.current);
    }
  }

  void _ensureOpen() {
    if (!_isOpen) throw StateError('database $name is closed');
  }

  // ---------------------------------------------------------------------------
  // Statements
  // ---------------------------------------------------------------------------

  static final Object _txZoneKey = Object();

  bool get _inOwnTransactionZone => identical(Zone.current[_txZoneKey], this);

  /// Runs one statement of any kind. [parameters] binds `?`, `?NNN`,
  /// `:name`, `@name` and `$name`: a list by position, or a map by name
  /// (with or without the prefix). Values may be null, `int`, `double`,
  /// `String`, `Uint8List`, `bool` (stored as 1/0) or `DateTime` (stored
  /// as ISO-8601 UTC text).
  ///
  /// A failed statement changes nothing and returns a result whose
  /// `error` says why. (Inside [transaction], the [Transaction]'s own
  /// methods throw instead.)
  Future<QueryResult> execute(String sql, [Object? parameters]) {
    _ensureOpen();
    if (_inOwnTransactionZone) {
      return Future.value(_runNow(sql, parameters, readOnly: false));
    }
    return _lock.run(() => _runNow(sql, parameters, readOnly: false));
  }

  /// Runs one read-only statement (SELECT, or a PRAGMA that reads). Any
  /// other statement fails with [SqlErrorKind.misuse]. See [execute].
  Future<QueryResult> query(String sql, [Object? parameters]) {
    _ensureOpen();
    if (_inOwnTransactionZone ||
        (mode == DatabaseMode.readFast && !_lock.isBusy)) {
      return Future.value(_runNow(sql, parameters, readOnly: true));
    }
    if (mode == DatabaseMode.readFast &&
        _txDepth == 0 &&
        !_engine.inTransaction) {
      return Future.value(_runNow(sql, parameters, readOnly: true));
    }
    return _lock.run(() => _runNow(sql, parameters, readOnly: true));
  }

  /// Runs every statement of [sql] in order and stops at the first that
  /// fails; the last result is then the failure. Parameters are not
  /// supported here.
  Future<List<QueryResult>> executeScript(String sql) {
    _ensureOpen();
    List<QueryResult> run() {
      final List<ParsedStatement> statements;
      try {
        statements = Parser.parseScript(sql);
      } on SqlException catch (e) {
        return [QueryResult.failure(e)];
      }
      final results = <QueryResult>[];
      for (final s in statements) {
        final r = _runParsed(s, const [], readOnly: false);
        results.add(r);
        if (!r.success) break;
      }
      return results;
    }

    if (_inOwnTransactionZone) return Future.value(run());
    return _lock.run(run);
  }

  QueryResult _runNow(
    String sql,
    Object? parameters, {
    required bool readOnly,
  }) {
    final ParsedStatement parsed;
    try {
      parsed = Parser.parseOne(sql);
    } on SqlException catch (e) {
      return QueryResult.failure(e);
    }
    final List<Object?> bound;
    try {
      bound = _bind(parsed, parameters);
    } on SqlException catch (e) {
      return QueryResult.failure(e.withSql(sql));
    }
    return _runParsed(parsed, bound, readOnly: readOnly);
  }

  QueryResult _runParsed(
    ParsedStatement parsed,
    List<Object?> bound, {
    required bool readOnly,
  }) {
    if (readOnly && !Engine.isReadOnly(parsed.statement)) {
      return QueryResult.failure(
        SqlException(
          'query() only runs SELECT (and reading PRAGMAs); use execute()',
          kind: SqlErrorKind.misuse,
          sql: parsed.sql,
        ),
      );
    }
    final watch = Stopwatch()..start();
    try {
      final r = _engine.execute(parsed, bound);
      return QueryResult.success(
        columns: r.columns,
        values: r.rows,
        affectedRows: r.changes,
        lastInsertRowId: r.lastInsertRowId,
        elapsed: watch.elapsed,
      );
    } on SqlException catch (e) {
      return QueryResult.failure(e, elapsed: watch.elapsed);
    } catch (e, st) {
      return QueryResult.failure(
        SqlException('internal error: $e\n$st', sql: parsed.sql),
        elapsed: watch.elapsed,
      );
    } finally {
      _afterStatement();
    }
  }

  List<Object?> _bind(ParsedStatement parsed, Object? parameters) {
    final n = parsed.parameterCount;
    if (parameters == null) {
      if (n == 0) return const [];
      throw SqlException.misuse(
        'this statement takes $n parameter(s) but none were given',
      );
    }
    Object? bind(Object? v) {
      try {
        return bindValue(v);
      } on ArgumentError catch (e) {
        throw SqlException.misuse('${e.message}');
      }
    }

    if (parameters is List) {
      if (parameters.length != n) {
        throw SqlException.misuse(
          'this statement takes $n parameter(s), ${parameters.length} were given',
        );
      }
      return [for (final v in parameters) bind(v)];
    }
    if (parameters is Map) {
      final values = List<Object?>.filled(n, null);
      final filled = List<bool>.filled(n, false);
      for (final e in parameters.entries) {
        var key = '${e.key}';
        if (key.startsWith(':') ||
            key.startsWith('@') ||
            key.startsWith(r'$')) {
          key = key.substring(1);
        }
        final i = parsed.names[key];
        if (i == null) throw SqlException.misuse('no parameter named $key');
        values[i - 1] = bind(e.value);
        filled[i - 1] = true;
      }
      for (var i = 0; i < n; i++) {
        if (!filled[i]) {
          throw SqlException.misuse('parameter ${i + 1} was not given a value');
        }
      }
      return values;
    }
    throw SqlException.misuse('parameters must be a List or a Map');
  }

  // ---------------------------------------------------------------------------
  // Transactions
  // ---------------------------------------------------------------------------

  /// Whether a transaction is open.
  bool get inTransaction => _engine.inTransaction;

  /// Runs [action] in a transaction that holds the database: other callers
  /// wait until it ends. Statements made through [tx] throw [SqlException]
  /// when they fail (this database's own methods, called inside [action],
  /// run in the transaction too but return failed results). If [action]
  /// throws, everything it did is rolled back and the error is rethrown;
  /// otherwise the transaction commits.
  ///
  /// Nested calls become savepoints.
  Future<T> transaction<T>(Future<T> Function(Transaction tx) action) {
    _ensureOpen();
    if (_inOwnTransactionZone) return _nested(action);
    return _lock.run(() async {
      _engineRun('BEGIN');
      _txDepth = 1;
      try {
        final result = await runZoned(
          () => action(Transaction._(this)),
          zoneValues: {_txZoneKey: this},
        );
        if (_engine.inTransaction) _engineRun('COMMIT');
        return result;
      } catch (_) {
        if (_engine.inTransaction) _engineRun('ROLLBACK');
        rethrow;
      } finally {
        _txDepth = 0;
        _afterStatement();
      }
    });
  }

  Future<T> _nested<T>(Future<T> Function(Transaction tx) action) async {
    final sp = 'jdb_sp_${_txDepth++}';
    _engineRun('SAVEPOINT $sp');
    try {
      final result = await action(Transaction._(this));
      _engineRun('RELEASE $sp');
      return result;
    } catch (_) {
      if (_engine.inTransaction) {
        _engineRun('ROLLBACK TO $sp');
        _engineRun('RELEASE $sp');
      }
      rethrow;
    } finally {
      _txDepth--;
    }
  }

  void _engineRun(String sql) =>
      _engine.execute(Parser.parseOne(sql), const []);

  /// Runs `BEGIN`. Prefer [transaction], which also keeps other callers
  /// out: a transaction begun here is shared by every caller of this
  /// database until it ends.
  Future<QueryResult> beginTransaction() => execute('BEGIN');

  /// Runs `COMMIT`.
  Future<QueryResult> commit() => execute('COMMIT');

  /// Runs `ROLLBACK`, or `ROLLBACK TO [savepoint]`.
  Future<QueryResult> rollback({String? savepoint}) => execute(
    savepoint == null
        ? 'ROLLBACK'
        : 'ROLLBACK TO ${quoteIdentifier(savepoint)}',
  );

  /// Runs `SAVEPOINT name`.
  Future<QueryResult> savepoint(String name) =>
      execute('SAVEPOINT ${quoteIdentifier(name)}');

  /// Runs `RELEASE name`.
  Future<QueryResult> releaseSavepoint(String name) =>
      execute('RELEASE ${quoteIdentifier(name)}');

  // ---------------------------------------------------------------------------
  // Saving
  // ---------------------------------------------------------------------------

  void _afterStatement() {
    _scheduleChanges();
    if (!persist || _engine.inTransaction) return;
    if (_catalog.log.mutations == _savedMutations) return;
    if (mode == DatabaseMode.writeFast) {
      _batchTimer ??= Timer(writeFastDelay, () {
        _batchTimer = null;
        unawaited(_startSave());
      });
    } else {
      unawaited(_startSave());
    }
  }

  Future<void> _startSave() {
    if (_saving != null) {
      _saveAgain = true;
      return _saving!;
    }
    final f = _saveLoop();
    _saving = f;
    return f;
  }

  Future<void> _saveLoop() async {
    try {
      do {
        _saveAgain = false;
        await _saveOnce();
      } while (_saveAgain);
    } finally {
      _saving = null;
    }
  }

  Future<void> _saveOnce() async {
    final store = _store;
    if (!persist || store == null) return;
    // Take the snapshot between statements, and never in a transaction:
    // its COMMIT starts the next save.
    final snapshot = await _lock.run(() {
      if (_engine.inTransaction) return null;
      final m = _catalog.log.mutations;
      if (m == _savedMutations) return null;
      return (encodeCatalogBytes(_catalog), m);
    });
    if (snapshot == null) return;
    final (plain, mutations) = snapshot;
    try {
      final key = _fileKey;
      final bytes = key == null ? plain : await sealDatabase(store, key, plain);
      await store.write(name, bytes);
      _savedMutations = mutations;
      _saveError = null;
    } catch (e, st) {
      _saveError = e;
      _saveStack = st;
      onSaveError?.call(e, st);
      if (onSaveError == null) {
        debugPrint('just_database: saving $name failed: $e');
      }
    }
  }

  Future<void> _flushSaves({bool force = false}) async {
    if (!persist) return;
    _batchTimer?.cancel();
    _batchTimer = null;
    while (_saving != null) {
      await _saving;
    }
    if (_catalog.log.mutations != _savedMutations) {
      await _startSave();
    }
  }

  /// Waits until every committed change so far is saved. Throws when the
  /// last save failed (background saves report failures to [onSaveError]).
  /// Completes at once for an in-memory database.
  Future<void> flush() async {
    _ensureOpen();
    await _flushSaves();
    final e = _saveError;
    if (e != null) {
      Error.throwWithStackTrace(e, _saveStack ?? StackTrace.current);
    }
  }

  /// Why the last save failed, or null when it succeeded (or nothing was
  /// saved yet). Background failures also go to [onSaveError].
  Object? get saveError => _saveError;

  /// How many openers hold this database: [close] closes it when the last
  /// one does.
  @internal
  int get openerCount => _isOpen ? _refs : 0;

  // ---------------------------------------------------------------------------
  // Change events
  // ---------------------------------------------------------------------------

  /// The changes made to this database: an event after each statement,
  /// script or transaction that changed something. A transaction's changes
  /// arrive when it commits; one rolled back sends nothing. Events come
  /// asynchronously (statements run together send one), and the stream
  /// closes when the database does.
  ///
  /// ```dart
  /// db.changes.listen((change) {
  ///   if (change.touches('scores')) refreshLeaderboard();
  /// });
  /// ```
  Stream<DatabaseChange> get changes => _changes.stream;

  void _scheduleChanges() {
    if (_changeScheduled) return;
    _changeScheduled = true;
    scheduleMicrotask(_emitChanges);
  }

  void _emitChanges() {
    _changeScheduled = false;
    // A transaction's changes are reported when it ends.
    if (_changes.isClosed || _engine.inTransaction) return;
    final log = _catalog.log;
    final touched = log.takeTouched();
    final replaced = _replacedTables;
    _replacedTables = null;
    final mutations = log.mutations;
    final schema = _catalog.schemaVersion;
    if (replaced == null && mutations == _notifiedMutations) return;
    final schemaChanged = replaced != null || schema != _notifiedSchema;
    _notifiedMutations = mutations;
    _notifiedSchema = schema;
    _changes.add(
      DatabaseChange(
        tables: Set.unmodifiable({
          ...?replaced,
          if (replaced != null)
            for (final t in _catalog.tables) t.name,
          ...touched,
        }),
        schemaChanged: schemaChanged,
      ),
    );
  }

  /// Changes the encryption: [newKey] encrypts the file with a new
  /// passphrase (or encrypts a plain one), null decrypts it. Saves at once.
  Future<void> changeEncryptionKey(String? newKey) async {
    _ensureOpen();
    final store = _store;
    if (!persist || store == null) {
      throw StateError('an in-memory database has no file to encrypt');
    }
    if (newKey != null && newKey.isEmpty) {
      throw ArgumentError('An encryptionKey must not be empty.', 'newKey');
    }
    final key = newKey == null ? null : await FileKey.create(store, newKey);
    await _lock.run(() {
      _fileKey = key;
      _encryptionKey = newKey;
      _savedMutations = -1;
    });
    await flush();
    DatabaseManager.notifyListChanged();
  }

  // ---------------------------------------------------------------------------
  // Introspection
  // ---------------------------------------------------------------------------

  /// The tables, in creation order.
  List<String> get tableNames => [for (final t in _catalog.tables) t.name];

  /// The views, in creation order.
  List<String> get viewNames => [for (final v in _catalog.views) v.name];

  /// The triggers, in creation order.
  List<String> get triggerNames => [for (final t in _catalog.triggers) t.name];

  /// The schema of [table], or null when there is no such table.
  TableSchema? getTableSchema(String table) => _catalog.table(table)?.schema;

  /// The `CREATE VIEW` statement of [view], or null when there is no such
  /// view.
  String? getViewSql(String view) => _catalog.view(view)?.sql;

  /// The `CREATE TRIGGER` statement of [trigger], or null when there is no
  /// such trigger.
  String? getTriggerSql(String trigger) => _catalog.trigger(trigger)?.sql;

  /// The table or view [trigger] is on, or null when there is no such
  /// trigger.
  String? getTriggerTable(String trigger) => _catalog.trigger(trigger)?.table;

  /// The triggers on [table] (a table or a view), in creation order.
  List<String> triggerNamesForTable(String table) {
    final lower = table.toLowerCase();
    return [
      for (final t in _catalog.triggers)
        if (t.table.toLowerCase() == lower) t.name,
    ];
  }

  /// The indexes of [table] (constraint indexes included).
  List<IndexInfo> indexesForTable(String table) =>
      _catalog.table(table)?.describeIndexes() ?? const [];

  /// The names of the indexes of [table].
  List<String> indexNamesForTable(String table) => [
    for (final i in indexesForTable(table)) i.name,
  ];

  /// The number of rows in [table] (0 when there is no such table).
  int rowCount(String table) => _catalog.table(table)?.rowCount ?? 0;

  /// The number of rows in every table.
  int get totalRows => _catalog.tables.fold(0, (s, t) => s + t.rowCount);

  /// A rough size of the data in memory, in bytes.
  int get estimatedSizeBytes {
    var size = 0;
    for (final t in _catalog.tables) {
      for (final e in t.entries) {
        size += 8;
        for (final v in e.value) {
          size += switch (v) {
            String() => v.length * 2,
            Uint8List() => v.length,
            null => 1,
            _ => 8,
          };
        }
      }
    }
    return size;
  }

  /// [tableNames], for code shared with older web builds.
  Future<List<String>> tableNamesAsync() async => tableNames;

  /// [viewNames], asynchronously.
  Future<List<String>> viewNamesAsync() async => viewNames;

  /// [triggerNames], asynchronously.
  Future<List<String>> triggerNamesAsync() async => triggerNames;

  /// [indexNamesForTable], asynchronously.
  Future<List<String>> indexNamesForTableAsync(String table) async =>
      indexNamesForTable(table);

  /// [getTableSchema], asynchronously.
  Future<TableSchema?> getTableSchemaAsync(String table) async =>
      getTableSchema(table);

  /// [totalRows], asynchronously.
  Future<int> totalRowsAsync() async => totalRows;

  /// [estimatedSizeBytes], asynchronously.
  Future<int> estimatedSizeBytesAsync() async => estimatedSizeBytes;

  /// A fluent builder for simple queries on [table].
  QueryBuilder from(String table) => QueryBuilder(this, table);

  // ---------------------------------------------------------------------------
  // Backup and restore
  // ---------------------------------------------------------------------------

  /// A SQL script that recreates the whole database (tables, rows,
  /// indexes, views, triggers). AUTOINCREMENT high-water marks are not in
  /// it; [exportJson] keeps them.
  Future<String> exportSql() {
    _ensureOpen();
    return _lock.run(() => dumpSql(_catalog));
  }

  /// The whole database as JSON (the file format), ready for `jsonEncode`.
  Future<Map<String, Object?>> exportJson() {
    _ensureOpen();
    return _lock.run(
      () =>
          jsonDecode(jsonEncode(encodeCatalog(_catalog)))
              as Map<String, Object?>,
    );
  }

  /// Replaces the whole database with what the SQL script [sql] creates
  /// (as [exportSql] writes it). The script runs against an empty database
  /// first; if any statement fails nothing changes and the error is thrown.
  Future<void> importSql(String sql) async {
    _ensureOpen();
    final fresh = Catalog();
    final engine = Engine(fresh)..foreignKeys = false;
    final statements = Parser.parseScript(sql);
    for (var i = 0; i < statements.length; i++) {
      try {
        engine.execute(statements[i], const []);
      } on SqlException catch (e) {
        throw SqlException(
          'statement ${i + 1} of the import failed: ${e.message}',
          kind: e.kind,
          sql: statements[i].sql,
        );
      }
    }
    engine.rollbackOpenTransaction();
    await _replace(fresh);
  }

  /// Replaces the whole database with [json] (as [exportJson] gives it).
  Future<void> importJson(Map<String, Object?> json) async {
    _ensureOpen();
    final Catalog fresh;
    try {
      fresh = decodeCatalog(json);
    } on FormatException catch (e) {
      throw SqlException('the JSON is not a database export: ${e.message}');
    }
    await _replace(fresh);
  }

  Future<void> _replace(Catalog fresh) async {
    await _lock.run(() {
      if (_engine.inTransaction) {
        throw StateError('cannot import while a transaction is open');
      }
      final fk = _engine.foreignKeys;
      _replacedTables = {
        ...?_replacedTables,
        for (final t in _catalog.tables) t.name,
      };
      _catalog = fresh;
      _engine = Engine(fresh)..foreignKeys = fk;
      _savedMutations = -1;
      _scheduleChanges();
    });
    if (persist) await flush();
  }

  // ---------------------------------------------------------------------------
  // Migrations
  // ---------------------------------------------------------------------------

  /// A runner for [migrations] on this database.
  MigrationRunner migrationRunner(List<Migration> migrations) =>
      MigrationRunner(this, migrations);

  /// Applies the pending [migrations] (up to [targetVersion]), each in its
  /// own transaction, and saves. See [MigrationRunner.migrate].
  Future<List<MigrationResult>> migrate(
    List<Migration> migrations, {
    int? targetVersion,
  }) => MigrationRunner(this, migrations).migrate(targetVersion: targetVersion);

  @override
  String toString() =>
      'JustDatabase($name, ${mode.name}${persist ? ', persisted' : ''})';
}

/// The statements of a [JustDatabase.transaction]: like the database's
/// own, but a failure throws [SqlException] (so the transaction rolls
/// back).
final class Transaction {
  Transaction._(this._db);
  final JustDatabase _db;

  /// Runs one statement; throws [SqlException] on failure.
  Future<QueryResult> execute(String sql, [Object? parameters]) async =>
      _db._runNow(sql, parameters, readOnly: false).orThrow();

  /// Runs one read-only statement; throws [SqlException] on failure.
  Future<QueryResult> query(String sql, [Object? parameters]) async =>
      _db._runNow(sql, parameters, readOnly: true).orThrow();

  /// Runs every statement of [sql]; throws at the first failure.
  Future<void> executeScript(String sql) async {
    for (final s in Parser.parseScript(sql)) {
      _db._runParsed(s, const [], readOnly: false).orThrow();
    }
  }

  /// Runs [action] in a savepoint inside this transaction.
  Future<T> transaction<T>(Future<T> Function(Transaction tx) action) =>
      _db._nested(action);
}
