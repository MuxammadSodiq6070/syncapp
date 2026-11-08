import 'package:flutter/widgets.dart';

import '../core/app_state.dart';

class SyncScope extends InheritedWidget {
  const SyncScope({
    super.key,
    required this.state,
    required this.gateway,
    this.onDeleteAccount,
    this.onLockApp,
    this.onUpdate2FA,
    this.has2FA = false,
    required super.child,
  });

  final AppState state;
  final String gateway;
  final Future<void> Function()? onDeleteAccount;
  final VoidCallback? onLockApp;
  final Future<void> Function()? onUpdate2FA;
  final bool has2FA;

  static SyncScope of(BuildContext context) => context.getInheritedWidgetOfExactType<SyncScope>()!;

  @override
  bool updateShouldNotify(SyncScope old) => state != old.state || gateway != old.gateway || has2FA != old.has2FA;
}

extension SyncContext on BuildContext {
  AppState get sync => SyncScope.of(this).state;
}
