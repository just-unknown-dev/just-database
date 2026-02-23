import 'package:flutter/foundation.dart';
import '../core/database.dart';
import '../core/database_manager.dart';
import '../core/database_mode.dart';
import '../core/secure_key_manager.dart';
import '../sql/executor.dart';

/// Provider for managing database state and operations in the admin UI.
class DatabaseProvider extends ChangeNotifier {
  List<DatabaseInfo> _databases = [];
  JustDatabase? _currentDatabase;
  DatabaseMode _defaultMode = DatabaseMode.standard;
  bool _persistEnabled = true;
  QueryResult? _lastQueryResult;
  String? _lastError;
  bool _isLoading = false;
  final List<String> _queryHistory = [];

  // ---------------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------------

  List<DatabaseInfo> get databases => List.unmodifiable(_databases);
  JustDatabase? get currentDatabase => _currentDatabase;
  DatabaseMode get defaultMode => _defaultMode;
  bool get persistEnabled => _persistEnabled;
  QueryResult? get lastQueryResult => _lastQueryResult;
  String? get lastError => _lastError;
  bool get isLoading => _isLoading;
  List<String> get queryHistory => List.unmodifiable(_queryHistory);
  bool get hasDatabaseOpen => _currentDatabase != null;

  // ---------------------------------------------------------------------------
  // Database management
  // ---------------------------------------------------------------------------

  Future<void> refreshDatabases() async {
    _setLoading(true);
    try {
      _databases = await DatabaseManager.listDatabases();
      // Reload current database reference if it was recreated
      if (_currentDatabase != null) {
        _currentDatabase =
            DatabaseManager.getOpenDatabase(_currentDatabase!.name) ??
            _currentDatabase;
      }
      _clearError();
    } catch (e) {
      _setError(e.toString());
    } finally {
      _setLoading(false);
    }
  }

  Future<void> createDatabase(
    String name, {
    DatabaseMode? mode,
    bool? persist,
  }) async {
    _setLoading(true);
    try {
      final effectiveMode = mode ?? _defaultMode;
      // For secure mode, auto-generate and persist the key via just_storage.
      // No user password is required.
      String? encryptionKey;
      if (effectiveMode == DatabaseMode.secure) {
        encryptionKey = await SecureKeyManager.resolveAutoKey(dbName: name);
      }
      final db = await DatabaseManager.open(
        name,
        mode: effectiveMode,
        persist: persist ?? _persistEnabled,
        encryptionKey: encryptionKey,
      );
      _currentDatabase = db;
      await refreshDatabases();
      _clearError();
    } catch (e) {
      _setError('Failed to create database: $e');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> selectDatabase(String name) async {
    _setLoading(true);
    try {
      // Check if already open
      final existing = DatabaseManager.getOpenDatabase(name);
      if (existing != null) {
        _currentDatabase = existing;
        _lastQueryResult = null;
        _clearError();
        return;
      }
      // Look up the mode from the known database list so we can supply the
      // auto-managed encryption key for secure databases.
      final info = _databases.where((d) => d.name == name).firstOrNull;
      String? encryptionKey;
      if (info?.mode == DatabaseMode.secure) {
        encryptionKey = await SecureKeyManager.resolveAutoKey(dbName: name);
      }
      _currentDatabase = await DatabaseManager.open(
        name,
        mode: info?.mode ?? _defaultMode,
        persist: _persistEnabled,
        encryptionKey: encryptionKey,
      );
      _lastQueryResult = null;
      _clearError();
    } catch (e) {
      _setError('Failed to open database: $e');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> deleteDatabase(String name) async {
    _setLoading(true);
    try {
      if (_currentDatabase?.name == name) _currentDatabase = null;
      // Clean up the auto-managed key from secure storage if one exists.
      await SecureKeyManager.clearAutoKey(dbName: name);
      await DatabaseManager.deleteDatabase(name);
      _lastQueryResult = null;
      await refreshDatabases();
      _clearError();
    } catch (e) {
      _setError('Failed to delete database: $e');
    } finally {
      _setLoading(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Query execution
  // ---------------------------------------------------------------------------

  Future<void> runQuery(String sql) async {
    if (_currentDatabase == null) {
      _setError('No database selected. Create or open one first.');
      return;
    }
    final trimmed = sql.trim();
    if (trimmed.isEmpty) return;

    _setLoading(true);
    try {
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('select')) {
        _lastQueryResult = await _currentDatabase!.query(trimmed);
      } else {
        _lastQueryResult = await _currentDatabase!.execute(trimmed);
        // Refresh schema after DDL/DML
        await refreshDatabases();
      }

      if (_lastQueryResult!.success) {
        _clearError();
        _addToHistory(trimmed);
      } else {
        _setError(_lastQueryResult!.errorMessage ?? 'Unknown error');
      }
    } catch (e) {
      _lastQueryResult = null;
      _setError('Error: $e');
    } finally {
      _setLoading(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  void setPersistEnabled(bool value) {
    _persistEnabled = value;
    notifyListeners();
  }

  void setDefaultMode(DatabaseMode mode) {
    _defaultMode = mode;
    notifyListeners();
  }

  Future<void> clearAllDatabases() async {
    _setLoading(true);
    try {
      await DatabaseManager.deleteAll();
      _currentDatabase = null;
      _lastQueryResult = null;
      _clearError();
      await refreshDatabases();
    } catch (e) {
      _setError('Failed to clear databases: $e');
    } finally {
      _setLoading(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  void _addToHistory(String sql) {
    _queryHistory.remove(sql); // remove duplicate
    _queryHistory.insert(0, sql);
    if (_queryHistory.length > 50) _queryHistory.removeLast();
  }

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }

  void _setError(String msg) {
    _lastError = msg;
    notifyListeners();
  }

  void _clearError() {
    _lastError = null;
  }
}
