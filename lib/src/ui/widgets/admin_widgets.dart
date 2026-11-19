/// Small widgets and helpers shared by the admin UI.
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../core/database_mode.dart';
import '../admin_utils.dart';

/// Pushes [page] with the theme in effect at [context], so pages pushed from
/// a themed admin screen keep its theme.
@internal
Future<T?> pushAdminPage<T>(BuildContext context, Widget page) {
  final navigator = Navigator.of(context);
  final themed = InheritedTheme.captureAll(
    context,
    page,
    to: navigator.context,
  );
  return navigator.push<T>(MaterialPageRoute<T>(builder: (_) => themed));
}

/// Shows [message] as an error SnackBar on the nearest messenger.
@internal
void showAdminError(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final cs = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: cs.errorContainer,
        content: Text(message, style: TextStyle(color: cs.onErrorContainer)),
        showCloseIcon: true,
        closeIconColor: cs.onErrorContainer,
      ),
    );
}

/// Shows [message] as a SnackBar on the nearest messenger.
@internal
void showAdminMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
}

/// A centred icon, title, message and optional action.
@internal
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(color: cs.onSurface),
            ),
            if (message != null) ...[
              const SizedBox(height: 4),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// The tone of a [MessageBanner].
@internal
enum BannerTone { info, success, error }

/// An inline message with an icon, coloured from the colour scheme.
@internal
class MessageBanner extends StatelessWidget {
  const MessageBanner({
    super.key,
    required this.message,
    this.tone = BannerTone.info,
    this.onClose,
    this.margin = EdgeInsets.zero,
  });

  final String message;
  final BannerTone tone;
  final VoidCallback? onClose;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (Color bg, Color fg, IconData icon) = switch (tone) {
      BannerTone.info => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
        Icons.info_outline,
      ),
      BannerTone.success => (
        cs.primaryContainer,
        cs.onPrimaryContainer,
        Icons.check_circle_outline,
      ),
      BannerTone.error => (
        cs.errorContainer,
        cs.onErrorContainer,
        Icons.error_outline,
      ),
    };
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(fontSize: 13, color: fg),
            ),
          ),
          if (onClose != null)
            InkWell(
              onTap: onClose,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close, size: 18, color: fg),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small rounded label.
@internal
class AdminTag extends StatelessWidget {
  const AdminTag({
    super.key,
    required this.label,
    this.icon,
    required this.background,
    required this.foreground,
  });

  /// A tag for [mode].
  factory AdminTag.mode(BuildContext context, DatabaseMode mode) {
    final cs = Theme.of(context).colorScheme;
    return AdminTag(
      label: modeLabel(mode),
      icon: modeIcon(mode),
      background: cs.secondaryContainer,
      foreground: cs.onSecondaryContainer,
    );
  }

  /// A tag for an encrypted database.
  factory AdminTag.encrypted(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AdminTag(
      label: 'Encrypted',
      icon: Icons.lock_outline,
      background: cs.tertiaryContainer,
      foreground: cs.onTertiaryContainer,
    );
  }

  /// A neutral tag.
  factory AdminTag.neutral(
    BuildContext context,
    String label, {
    IconData? icon,
  }) {
    final cs = Theme.of(context).colorScheme;
    return AdminTag(
      label: label,
      icon: icon,
      background: cs.surfaceContainerHighest,
      foreground: cs.onSurfaceVariant,
    );
  }

  final String label;
  final IconData? icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled card that groups related settings or details.
@internal
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.children,
    this.titleColor,
  });

  final String title;
  final List<Widget> children;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: titleColor ?? cs.primary,
              ),
            ),
          ),
          const Divider(height: 1),
          ...children,
        ],
      ),
    );
  }
}
