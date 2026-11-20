/// The admin screen's settings, SQL history and snippets, kept with
/// just_storage under one key.
@internal
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, internal;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:just_storage/just_storage.dart';

import '../core/database_mode.dart';

/// One run of the SQL console.
@internal
final class HistoryEntry {
  /// Creates an entry.
  const HistoryEntry({
    required this.sql,
    required this.database,
    required this.at,
    required this.ok,
    this.summary = '',
  });

  /// What ran.
  final String sql;

  /// The database it ran on.
  final String database;

  /// When it ran.
  final DateTime at;

  /// Whether every statement succeeded.
  final bool ok;

  /// A short outcome, such as `3 rows` or the error.
  final String summary;

  Map<String, Object?> toJson() => {
    'sql': sql,
    'db': database,
    'at': at.toUtc().toIso8601String(),
    'ok': ok,
    'summary': summary,
  };

  static HistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final sql = json['sql'];
    final db = json['db'];
    final at = DateTime.tryParse('${json['at']}');
    if (sql is! String || db is! String || at == null) return null;
    return HistoryEntry(
      sql: sql,
      database: db,
      at: at,
      ok: json['ok'] != false,
      summary: json['summary'] is String ? json['summary'] as String : '',
    );
  }
}

/// A saved statement.
@internal
final class SqlSnippet {
  /// Creates a snippet.
  const SqlSnippet({required this.name, required this.sql});

  /// Its name.
  final String name;

  /// Its SQL.
  final String sql;

  Map<String, Object?> toJson() => {'name': name, 'sql': sql};

  static SqlSnippet? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final sql = json['sql'];
    if (name is! String || sql is! String) return null;
    return SqlSnippet(name: name, sql: sql);
  }
}

/// The admin screen's settings, history and snippets.
///
/// With [remember] they are read from and written to just_storage's
/// standard storage (key [storageKey]); otherwise they live only as long as
/// this object.
@internal
final class AdminPreferences {
  AdminPreferences({
    required this.remember,
    this.defaultMode = DatabaseMode.standard,
    this.persistByDefault = true,
    this.themeMode = ThemeMode.dark,
  });

  /// The just_storage key.
  static const String storageKey = 'just_database.admin';

  /// The most history entries kept.
  static const int maxHistory = 100;

  /// The page sizes the data browser offers.
  static const List<int> pageSizes = [25, 50, 100, 250, 500];

  /// Whether the preferences are kept between runs.
  final bool remember;

  /// The mode of new databases (and of saved ones the screen opens).
  DatabaseMode defaultMode;

  /// Whether new databases are saved.
  bool persistByDefault;

  /// Light, dark or the device's setting.
  ThemeMode themeMode;

  /// Rows per page in the data browser.
  int pageSize = 50;

  /// SQL console runs, newest first.
  final List<HistoryEntry> history = [];

  /// Saved statements.
  final List<SqlSnippet> snippets = [];

  Timer? _saveTimer;
  bool _changedBeforeLoad = false;
  bool _loaded = false;

  /// Reads the stored preferences (when [remember] is on). Values changed
  /// before this finishes win over the stored ones.
  Future<void> load() async {
    if (!remember) return;
    try {
      final storage = await JustStorage.standard();
      final text = await storage.read(storageKey);
      if (text != null) _apply(jsonDecode(text));
    } catch (e) {
      debugPrint('just_database admin: settings could not be read: $e');
    } finally {
      _loaded = true;
    }
  }

  void _apply(Object? json) {
    if (json is! Map) return;
    if (!_changedBeforeLoad) {
      final mode = DatabaseMode.values
          .where((m) => m.name == json['defaultMode'])
          .firstOrNull;
      if (mode != null) defaultMode = mode;
      if (json['persistByDefault'] is bool) {
        persistByDefault = json['persistByDefault'] as bool;
      }
      final theme = ThemeMode.values
          .where((m) => m.name == json['themeMode'])
          .firstOrNull;
      if (theme != null) themeMode = theme;
      final size = json['pageSize'];
      if (size is int && pageSizes.contains(size)) pageSize = size;
    }
    final storedHistory = [
      for (final e in (json['history'] as List?) ?? const [])
        ?HistoryEntry.fromJson(e),
    ];
    history
      ..addAll(storedHistory)
      ..sort((a, b) => b.at.compareTo(a.at));
    if (history.length > maxHistory) {
      history.removeRange(maxHistory, history.length);
    }
    final known = {for (final s in snippets) s.name};
    for (final e in (json['snippets'] as List?) ?? const []) {
      final s = SqlSnippet.fromJson(e);
      if (s != null && known.add(s.name)) snippets.add(s);
    }
  }

  Map<String, Object?> toJson() => {
    'defaultMode': defaultMode.name,
    'persistByDefault': persistByDefault,
    'themeMode': themeMode.name,
    'pageSize': pageSize,
    'history': [for (final h in history) h.toJson()],
    'snippets': [for (final s in snippets) s.toJson()],
  };

  /// Notes a change; it is saved shortly (when [remember] is on).
  void changed() {
    if (!_loaded) _changedBeforeLoad = true;
    if (!remember) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      _saveTimer = null;
      unawaited(save());
    });
  }

  /// Writes the preferences now (when [remember] is on).
  Future<void> save() async {
    if (!remember) return;
    try {
      final storage = await JustStorage.standard();
      await storage.write(storageKey, jsonEncode(toJson()));
    } catch (e) {
      debugPrint('just_database admin: settings could not be saved: $e');
    }
  }

  /// Saves a change still waiting, and stops waiting.
  void dispose() {
    final timer = _saveTimer;
    _saveTimer = null;
    if (timer != null && timer.isActive) {
      timer.cancel();
      unawaited(save());
    }
  }
}
