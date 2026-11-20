// The just_database workbench as a Flutter DevTools extension: the screen
// the app can show itself (JustDatabaseAdminScreen), on the databases of
// the app DevTools is connected to. It reaches them through the workbench
// service just_database registers in debug builds.
//
// Built into ../extension/devtools/build (see README.md); not published.

// The remote side of the workbench is internal to just_database, and this
// app is built and shipped with it.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:convert';

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/material.dart';
import 'package:just_database/src/core/workbench_wire.dart';
import 'package:just_database/src/ui/backend/remote_host.dart';
import 'package:just_database/ui.dart';
import 'package:vm_service/vm_service.dart';

void main() => runApp(const DevToolsExtension(child: WorkbenchExtension()));

/// Waits for the connected app's workbench service, then shows the
/// workbench on it; starts over when the app restarts.
class WorkbenchExtension extends StatefulWidget {
  const WorkbenchExtension({super.key});

  @override
  State<WorkbenchExtension> createState() => _WorkbenchExtensionState();
}

class _WorkbenchExtensionState extends State<WorkbenchExtension> {
  JustDatabaseAdminController? _controller;
  IsolateRef? _isolate;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    serviceManager.isolateManager.mainIsolate.addListener(_restart);
    serviceManager.connectedState.addListener(_restart);
    _restart();
  }

  @override
  void dispose() {
    serviceManager.isolateManager.mainIsolate.removeListener(_restart);
    serviceManager.connectedState.removeListener(_restart);
    _controller?.dispose();
    super.dispose();
  }

  /// Drops the workbench of the previous app (or run) and waits for the
  /// service of the current one.
  void _restart() {
    final isolate = serviceManager.connectedState.value.connected
        ? serviceManager.isolateManager.mainIsolate.value
        : null;
    if (isolate?.id == _isolate?.id &&
        (_controller != null || isolate == null)) {
      return;
    }
    _isolate = isolate;
    final old = _controller;
    _controller = null;
    old?.dispose();
    final attempt = ++_attempt;
    setStateIfMounted();
    if (isolate == null) return;
    unawaited(
      serviceManager.serviceExtensionManager
          .waitForServiceExtensionAvailable(workbenchExtension)
          .then((_) {
            if (!mounted || attempt != _attempt) return;
            setState(() {
              _controller = JustDatabaseAdminController.withHost(
                RemoteAdminHost(_DevToolsTransport()),
              );
            });
          }),
    );
  }

  void setStateIfMounted() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) {
      return JustDatabaseAdminScreen(
        key: ObjectKey(controller),
        controller: controller,
        title: 'Just Database',
      );
    }
    final connected = serviceManager.connectedState.value.connected;
    return _Waiting(
      title: connected ? 'Waiting for the app' : 'No app connected',
      message: connected
          ? 'The workbench appears once the app opens a just_database '
                'database in a debug build (JustDatabase.open). It is off '
                'when the app sets JustDatabase.debugDevToolsWorkbench to '
                'false.'
          : 'Run your app in debug mode and connect DevTools to it.',
    );
  }
}

/// Calls the app's workbench service through DevTools' VM service
/// connection.
final class _DevToolsTransport implements WorkbenchTransport {
  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> args,
  ) async {
    final response = await serviceManager.callServiceExtensionOnMainIsolate(
      workbenchExtension,
      args: {'method': method, 'args': jsonEncode(args)},
    );
    return {...?response.json}.cast<String, Object?>();
  }

  @override
  Stream<(String, Map<String, Object?>)> get events {
    final service = serviceManager.service;
    if (service == null) return const Stream.empty();
    return service.onExtensionEvent
        .where(
          (e) => e.extensionKind?.startsWith(workbenchEventPrefix) ?? false,
        )
        .map(
          (e) => (
            e.extensionKind!,
            {...?e.extensionData?.data}.cast<String, Object?>(),
          ),
        );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.storage_outlined,
                  size: 40,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
