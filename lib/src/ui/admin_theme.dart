/// The admin screen's colours and its light and dark appearance.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import 'just_database_admin_controller.dart';

/// The coral of the Just Unknown logo: the workbench's accent colour.
@internal
const Color adminCoral = Color(0xFFF5746F);

/// Gives [child] the admin screen's theme in the brightness the
/// controller's [JustDatabaseAdminController.themeMode] asks for.
///
/// Without a [theme] it is the workbench's own: [adminColours] in the
/// app's font, density and platform. A given [theme] is used as it is in
/// its own brightness, and in the other one a theme is made from its
/// colours.
///
/// Pages the screen pushes get their own [AdminTheme] (see
/// `pushAdminPage`), so a change of appearance reaches them as well.
@internal
class AdminTheme extends StatefulWidget {
  const AdminTheme({
    super.key,
    required this.controller,
    this.theme,
    required this.child,
  });

  /// Whose [JustDatabaseAdminController.themeMode] to follow.
  final JustDatabaseAdminController controller;

  /// The screen's theme; the workbench's own when null.
  final ThemeData? theme;

  /// What to theme.
  final Widget child;

  /// The nearest [AdminTheme] above [context], or null.
  static AdminTheme? maybeOf(BuildContext context) =>
      context.findAncestorWidgetOfExactType<AdminTheme>();

  @override
  State<AdminTheme> createState() => _AdminThemeState();
}

class _AdminThemeState extends State<AdminTheme> {
  ThemeData? _from;
  bool? _own;
  Brightness? _to;
  ThemeData? _made;

  ThemeData _resolve(BuildContext context) {
    final given = widget.theme;
    final target = switch (widget.controller.themeMode) {
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
    };
    if (given != null && given.brightness == target) return given;
    final from = given ?? Theme.of(context);
    final own = given == null;
    if (!identical(_from, from) || _own != own || _to != target) {
      _from = from;
      _own = own;
      _to = target;
      _made = themeWithColours(
        from,
        own
            ? adminColours(target)
            : ColorScheme.fromSeed(
                seedColor: from.colorScheme.primary,
                brightness: target,
              ),
      );
    }
    return _made!;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, child) => Theme(data: _resolve(context), child: child!),
    child: widget.child,
  );
}

/// Text on [adminCoral].
const Color _ink = Color(0xFF1B1B1B);

/// The workbench's own colours with [brightness]: black, white and greys,
/// with [adminCoral] as the accent.
///
/// Surfaces, outlines and selections are neutral. The coral is the dark
/// scheme's primary colour (buttons, tabs, focus, highlighted icons) and
/// both schemes' primary container (the add button, success banners). On
/// light surfaces it is too pale for text and icons, so the light scheme's
/// primary is a deeper shade of it. SQL strings and warnings get a gold.
@internal
ColorScheme adminColours(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  ColorScheme scheme(DynamicSchemeVariant variant) => ColorScheme.fromSeed(
    seedColor: adminCoral,
    brightness: brightness,
    dynamicSchemeVariant: variant,
  );
  final neutral = scheme(DynamicSchemeVariant.monochrome);
  final accent = scheme(DynamicSchemeVariant.content);
  return neutral.copyWith(
    primary: dark ? adminCoral : accent.primary,
    onPrimary: dark ? _ink : accent.onPrimary,
    primaryContainer: adminCoral,
    onPrimaryContainer: _ink,
    inversePrimary: accent.inversePrimary,
    secondary: accent.secondary,
    onSecondary: accent.onSecondary,
    tertiary: accent.tertiary,
    onTertiary: accent.onTertiary,
    tertiaryContainer: Color.alphaBlend(
      accent.tertiary.withValues(alpha: dark ? 0.2 : 0.15),
      neutral.surface,
    ),
    onTertiaryContainer: accent.tertiary,
    surfaceTint: const Color(0x00000000), // raised surfaces stay grey
  );
}

/// A theme with [colours] and [base]'s font, density and platform.
@internal
ThemeData themeWithColours(ThemeData base, ColorScheme colours) {
  final font = base.textTheme.bodyMedium;
  return ThemeData(
    colorScheme: colours,
    fontFamily: font?.fontFamily,
    fontFamilyFallback: font?.fontFamilyFallback,
    visualDensity: base.visualDensity,
    platform: base.platform,
    materialTapTargetSize: base.materialTapTargetSize,
    pageTransitionsTheme: base.pageTransitionsTheme,
    splashFactory: base.splashFactory,
  );
}
