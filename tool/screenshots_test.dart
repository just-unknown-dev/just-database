// Renders the workbench screenshots in assets/screenshots (README and
// pub.dev): a desktop window in dark (the default) and in light, and three
// phone screens.
//
//   flutter test tool/screenshots_test.dart
//
// It runs as a widget test with the real Roboto and Material Icons fonts
// (from the Flutter SDK) and a monospace font from the system, so text is
// not drawn as test boxes. Add --dart-define=raw=<folder> to also write each
// screen on its own, unframed.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/ui.dart';

import '../test/ui/ui_test_support.dart';

const _out = 'assets/screenshots';
const _raw = String.fromEnvironment('raw');

/// Pixels per logical pixel in the files.
const _scale = 2.0;

const _desktop = Size(1440, 900);
const _phone = Size(390, 844);

final _boundary = GlobalKey();

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------

Directory _materialFonts() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final dir = Directory('$root/bin/cache/artifacts/material_fonts');
    if (dir.existsSync()) return dir;
  }
  // flutter_tester lives in <flutter>/bin/cache/artifacts/engine/<platform>.
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    final fonts = Directory('${dir.path}/material_fonts');
    if (fonts.existsSync()) return fonts;
    dir = dir.parent;
  }
  throw StateError('The Material fonts were not found; set FLUTTER_ROOT.');
}

const _monoFiles = [
  r'C:\Windows\Fonts\consola.ttf',
  '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
  '/usr/share/fonts/TTF/DejaVuSansMono.ttf',
  '/Library/Fonts/Courier New.ttf',
];

Future<void> _loadFonts() async {
  Future<void> load(String family, Iterable<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  final fonts = _materialFonts().path;
  await load('Roboto', [
    for (final w in ['regular', 'medium', 'bold', 'italic', 'mediumitalic'])
      '$fonts/roboto-$w.ttf',
  ]);
  await load('MaterialIcons', ['$fonts/materialicons-regular.otf']);
  // Under the first name the workbench asks for, whichever font it is.
  final mono = _monoFiles.where((f) => File(f).existsSync()).take(1);
  if (mono.isNotEmpty) await load('Consolas', mono);
}

// ---------------------------------------------------------------------------
// Sample data
// ---------------------------------------------------------------------------

const _players = [
  ('Aria', 'Mage', 34, 51240, 1830, true, '2026-11-20T09:41:00Z'),
  ('Bram', 'Knight', 29, 40110, 960, false, '2026-11-19T22:15:00Z'),
  ('Cass', 'Rogue', 31, 44870, 2410, true, '2026-11-20T09:38:00Z'),
  ('Dorian', 'Cleric', 22, 25530, 410, false, '2026-11-18T18:02:00Z'),
  ('Elin', 'Ranger', 37, 58960, 3120, true, '2026-11-20T09:40:00Z'),
  ('Fenna', 'Mage', 18, 17250, 275, false, '2026-11-17T12:30:00Z'),
  ('Gus', 'Knight', 41, 68400, 4005, false, '2026-11-20T07:55:00Z'),
  ('Hana', 'Cleric', 27, 36020, 1120, true, '2026-11-20T09:12:00Z'),
  ('Ivo', 'Rogue', 12, 8830, 90, false, '2026-11-12T20:44:00Z'),
  ('Juno', 'Ranger', 25, 31680, 845, false, '2026-11-19T16:20:00Z'),
  ('Kai', 'Knight', 33, 49210, 1675, true, '2026-11-20T09:33:00Z'),
  ('Lena', 'Mage', 39, 63300, 2990, false, '2026-11-20T08:05:00Z'),
  ('Milo', 'Cleric', 15, 12480, 160, false, '2026-11-15T11:10:00Z'),
  ('Nia', 'Rogue', 28, 38440, 1385, true, '2026-11-20T09:27:00Z'),
  ('Oren', 'Ranger', 20, 21790, 330, false, '2026-11-18T21:48:00Z'),
  ('Pia', 'Knight', 36, 56120, 2260, false, '2026-11-19T23:59:00Z'),
];

const _levels = ['Bamboo Forest', 'Moonlit Castle', 'Sky Temple'];

String _two(int n) => n.toString().padLeft(2, '0');

Future<JustDatabase> _seedSaveGame() async {
  final db = await JustDatabase.open('save_game');
  await db.executeScript('''
    CREATE TABLE players (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      class TEXT NOT NULL CHECK (class IN ('Knight', 'Ranger', 'Mage', 'Rogue', 'Cleric')),
      level INTEGER NOT NULL DEFAULT 1,
      xp INTEGER NOT NULL DEFAULT 0,
      gold INTEGER NOT NULL DEFAULT 0,
      online BOOLEAN NOT NULL DEFAULT 0,
      last_seen DATETIME
    );
    CREATE TABLE items (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      rarity TEXT NOT NULL DEFAULT 'common',
      value INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE inventory (
      player_id INTEGER NOT NULL REFERENCES players (id) ON DELETE CASCADE,
      item_id INTEGER NOT NULL REFERENCES items (id),
      qty INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (player_id, item_id)
    );
    CREATE TABLE runs (
      id INTEGER PRIMARY KEY,
      player_id INTEGER NOT NULL REFERENCES players (id) ON DELETE CASCADE,
      level_name TEXT NOT NULL,
      score INTEGER NOT NULL,
      time_ms INTEGER NOT NULL,
      finished_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    CREATE INDEX runs_player ON runs (player_id);
    CREATE INDEX runs_score ON runs (level_name, score);
    CREATE VIEW leaderboard AS
      SELECT p.name, p.class, MAX(r.score) AS best, COUNT(r.id) AS runs
      FROM players p JOIN runs r ON r.player_id = p.id
      GROUP BY p.id ORDER BY best DESC;
    CREATE VIEW online_players AS
      SELECT id, name, class, level FROM players WHERE online = 1;
    CREATE TRIGGER run_xp AFTER INSERT ON runs BEGIN
      UPDATE players SET xp = xp + NEW.score / 10 WHERE id = NEW.player_id;
    END;
    INSERT INTO items (name, rarity, value) VALUES
      ('Iron Sword', 'common', 40), ('Oak Bow', 'common', 35),
      ('Moonblade', 'epic', 1200), ('Healing Potion', 'common', 15),
      ('Phoenix Feather', 'legendary', 5000), ('Shadow Cloak', 'rare', 640);
  ''');
  await db.transaction((tx) async {
    for (final (name, cls, level, xp, gold, online, seen) in _players) {
      await tx.execute(
        'INSERT INTO players (name, class, level, xp, gold, online, '
        'last_seen) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [name, cls, level, xp, gold, online, seen],
      );
    }
    for (var p = 1; p <= _players.length; p++) {
      for (var i = 0; i < 1 + p % 3; i++) {
        await tx.execute(
          'INSERT OR IGNORE INTO inventory (player_id, item_id, qty) '
          'VALUES (?, ?, ?)',
          [p, 1 + (p + i * 2) % 6, 1 + (p * 7 + i) % 5],
        );
      }
      for (var r = 0; r < 2 + p % 4; r++) {
        await tx.execute(
          'INSERT INTO runs (player_id, level_name, score, time_ms, '
          'finished_at) VALUES (?, ?, ?, ?, ?)',
          [
            p,
            _levels[(p + r) % _levels.length],
            8000 + (p * 7919 + r * 104729) % 42000,
            95000 + (p * 3571 + r * 7307) % 160000,
            '2026-11-${_two(10 + (p + r) % 10)}'
                'T${_two((8 + r * 3) % 24)}:${_two((p * 7) % 60)}:00Z',
          ],
        );
      }
    }
  });
  await db.flush();
  return db;
}

Future<JustDatabase> _seedSettings() async {
  final db = await JustDatabase.open('settings', mode: DatabaseMode.readFast);
  await db.executeScript('''
    CREATE TABLE prefs (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    INSERT INTO prefs VALUES
      ('audio.music', '0.6'), ('audio.sfx', '0.8'), ('video.vsync', 'true'),
      ('video.scale', '2'), ('input.layout', 'wasd'), ('ui.language', 'en'),
      ('ui.subtitles', 'true'), ('net.region', 'eu-west');
  ''');
  await db.flush();
  return db;
}

/// Saved databases the screen lists as closed: one plain, one locked.
Future<void> _seedClosed() async {
  final telemetry = await JustDatabase.open(
    'telemetry',
    mode: DatabaseMode.writeFast,
  );
  await telemetry.execute(
    'CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT, at DATETIME)',
  );
  for (var i = 0; i < 400; i++) {
    await telemetry.execute(
      'INSERT INTO events (name, at) VALUES (?, CURRENT_TIMESTAMP)',
      ['event_${i % 12}'],
    );
  }
  await telemetry.close();
  final cloud = await JustDatabase.open(
    'cloud_save',
    encryptionKey: 'correct horse battery staple',
  );
  await cloud.execute('CREATE TABLE slots (id INTEGER PRIMARY KEY, data)');
  await cloud.close();
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// The app gives the workbench its font; the colours are the workbench's.
Widget _app(JustDatabaseAdminController c) => RepaintBoundary(
  key: _boundary,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: 'Roboto'),
    home: JustDatabaseAdminScreen(controller: c),
  ),
);

Future<ui.Image> _grab(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: _scale),
  ))!;
  if (_raw.isNotEmpty) await _write(tester, image, '$_raw/$name.png');
  return image;
}

Future<void> _write(WidgetTester tester, ui.Image image, String path) async {
  await tester.runAsync(() async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// [shots] side by side on a transparent background, with rounded corners
/// and a soft shadow; [phone] adds a phone's bezel. A window's edge is
/// outlined, lightly when the shots are [dark].
Future<ui.Image> _frame(
  WidgetTester tester,
  List<ui.Image> shots, {
  required bool phone,
  bool dark = false,
}) async {
  const s = _scale;
  const pad = 20 * s;
  const gap = 36 * s;
  final bezel = phone ? 9 * s : 0.0;
  final screenRadius = (phone ? 34 : 10) * s;
  final w = shots.first.width.toDouble();
  final h = shots.first.height.toDouble();
  final frameW = w + 2 * bezel;
  final frameH = h + 2 * bezel;
  final width = 2 * pad + shots.length * frameW + (shots.length - 1) * gap;
  final height = 2 * pad + frameH;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var i = 0; i < shots.length; i++) {
    final frame = Rect.fromLTWH(pad + i * (frameW + gap), pad, frameW, frameH);
    final outer = RRect.fromRectAndRadius(
      frame,
      Radius.circular(screenRadius + bezel),
    );
    canvas.drawShadow(
      Path()..addRRect(outer),
      const Color(0xFF000000),
      6 * s,
      false,
    );
    if (phone) {
      canvas.drawRRect(outer, Paint()..color = const Color(0xFF1D1B20));
    }
    final screen = RRect.fromRectAndRadius(
      frame.deflate(bezel),
      Radius.circular(screenRadius),
    );
    canvas
      ..save()
      ..clipRRect(screen)
      ..drawImage(shots[i], screen.outerRect.topLeft, Paint())
      ..restore();
    if (!phone) {
      canvas.drawRRect(
        screen,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s
          ..color = dark ? const Color(0x2EFFFFFF) : const Color(0x24000000),
      );
    }
  }
  final picture = recorder.endRecording();
  return (await tester.runAsync(
    () => picture.toImage(width.round(), height.round()),
  ))!;
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// The shots
// ---------------------------------------------------------------------------

void main() {
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());

  Future<(JustDatabase, JustDatabase)> setUpData(WidgetTester tester) async {
    await tester.runAsync(_loadFonts);
    await tester.runAsync(_seedClosed);
    final game = await drive(tester, _seedSaveGame);
    final settings = await drive(tester, _seedSettings);
    return (game, settings);
  }

  Future<void> tearDownData(
    WidgetTester tester,
    JustDatabaseAdminController c,
    List<JustDatabase> dbs,
  ) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    for (final db in dbs) {
      await drive(tester, db.close);
    }
    await tester.runAsync(() => DatabaseManager.deleteAll());
  }

  testWidgets('desktop', (tester) async {
    debugDisableShadows = false; // real shadows instead of black outlines
    final (game, settings) = await setUpData(tester);
    useLargeWindow(tester, size: _desktop);
    final c = JustDatabaseAdminController(rememberSettings: false);
    await tester.pumpWidget(_app(c));
    await pumpUntil(tester, () => c.databases.length == 4);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('jdb-db-save_game')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-object-table-players')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const ValueKey('jdb-header-level')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('jdb-cell-2-2')));
    await tester.pumpAndSettle();
    await _rightClick(tester, find.byKey(const ValueKey('jdb-cell-2-2')));
    await tester.tap(find.text('Edit row…'));
    await tester.pumpAndSettle();
    final dark = await _grab(tester, 'desktop_data');
    await _write(
      tester,
      await _frame(tester, [dark], phone: false, dark: true),
      '$_out/workbench_desktop.png',
    );

    // Light: the user's pick (the app bar's toggle or Settings).
    c.setThemeMode(ThemeMode.light);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-pane-tab-sql')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-sql')),
      '-- The best run of each player\n'
      'SELECT p.name, p.class, MAX(r.score) AS best, COUNT(*) AS runs\n'
      'FROM players p JOIN runs r ON r.player_id = p.id\n'
      'WHERE p.level >= :min_level\n'
      'GROUP BY p.id\n'
      'ORDER BY best DESC;',
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-param-:min_level')),
      '20',
    );
    await tester.tap(find.byKey(const ValueKey('jdb-run')));
    await tester.pumpAndSettle();
    final light = await _grab(tester, 'desktop_sql_light');
    await _write(
      tester,
      await _frame(tester, [light], phone: false),
      '$_out/workbench_desktop_light.png',
    );

    await tearDownData(tester, c, [game, settings]);
    debugDisableShadows = true; // checked before tear-downs run
  });

  testWidgets('phone', (tester) async {
    debugDisableShadows = false; // real shadows instead of black outlines
    final (game, settings) = await setUpData(tester);
    useLargeWindow(tester, size: _phone);
    final c = JustDatabaseAdminController(rememberSettings: false);
    await tester.pumpWidget(_app(c));
    await pumpUntil(tester, () => c.databases.length == 4);
    final home = await _grab(tester, 'phone_home');

    await tester.tap(find.byKey(const ValueKey('jdb-db-save_game')));
    await tester.pumpAndSettle();
    final database = await _grab(tester, 'phone_database');

    await tester.tap(find.byKey(const ValueKey('jdb-object-table-players')));
    await tester.pumpAndSettle();
    final table = await _grab(tester, 'phone_table');

    await tester.tap(find.text('Elin'));
    await tester.pumpAndSettle();
    final sheet = await _grab(tester, 'phone_row_sheet');
    await tester.tapAt(const Offset(195, 80));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-nav-sql')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-sql')),
      'SELECT name, level, gold\nFROM players\nWHERE online\nORDER BY level DESC;',
    );
    await tester.tap(find.byKey(const ValueKey('jdb-run')));
    await tester.pumpAndSettle();
    final sql = await _grab(tester, 'phone_sql');

    await _write(
      tester,
      await _frame(tester, [database, table, sql], phone: true, dark: true),
      '$_out/workbench_phone.png',
    );
    // Not framed, but kept with --dart-define=raw for a look.
    home.dispose();
    sheet.dispose();

    await tearDownData(tester, c, [game, settings]);
    debugDisableShadows = true; // checked before tear-downs run
  });
}
