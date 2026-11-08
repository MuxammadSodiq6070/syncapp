import 'dart:io';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'core/app_state.dart';
import 'core/backend.dart';
import 'core/localization.dart';
import 'screens/lock_screen.dart';
import 'screens/onboarding.dart';
import 'screens/shell.dart';
import 'ui/glass.dart';
import 'ui/scope.dart';
import 'ui/theme.dart';

/// The gateway this build talks to. Fixed at build time: a wrong address would make
/// the app unusable, and the core only trusts wss:// certificates signed by a public
/// CA. Point a development build elsewhere with
/// `--dart-define=SYNC_GATEWAY=ws://192.168.1.10:8787`.
const _gateway = String.fromEnvironment('SYNC_GATEWAY', defaultValue: 'wss://sync-gateway.fly.dev');

/// The local key lives in the platform keystore and never in the data folder.
Future<String> _localKey() async {
  const storage = FlutterSecureStorage();
  var key = await storage.read(key: 'sync_local_key');
  if (key == null) {
    final rng = Random.secure();
    key = List.generate(32, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await storage.write(key: 'sync_local_key', value: key);
  }
  return key;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SyncRoot());
}

class SyncRoot extends StatefulWidget {
  const SyncRoot({super.key});

  @override
  State<SyncRoot> createState() => _SyncRootState();
}

class _SyncRootState extends State<SyncRoot> with WidgetsBindingObserver {
  AppState? _state;
  String? _error;
  bool _locked = true;
  String? _cached2faPassword;
  String? _cached2faHint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh2FA(autoLock: true);
    }
  }

  Future<void> _refresh2FA({bool autoLock = false}) async {
    const storage = FlutterSecureStorage();
    final pass = await storage.read(key: 'sync_2fa_password');
    final hint = await storage.read(key: 'sync_2fa_hint');
    if (mounted) {
      setState(() {
        _cached2faPassword = pass;
        _cached2faHint = hint;
        if (autoLock && pass != null && pass.isNotEmpty) {
          _locked = true;
        }
      });
    }
  }

  void _lockNow() {
    if (_cached2faPassword != null && _cached2faPassword!.isNotEmpty) {
      setState(() => _locked = true);
    }
  }

  Future<void> _start() async {
    try {
      try {
        await Firebase.initializeApp();
      } catch (_) {}
      await AppLocale.instance.init();

      const storage = FlutterSecureStorage();
      _cached2faPassword = await storage.read(key: 'sync_2fa_password');
      _cached2faHint = await storage.read(key: 'sync_2fa_hint');
      _locked = _cached2faPassword != null && _cached2faPassword!.isNotEmpty;

      final support = await getApplicationSupportDirectory();
      await support.create(recursive: true);
      final backend = await NativeBackend.start(
        dataDir: support.path,
        localKeyHex: await _localKey(),
        gatewayUrl: _gateway,
      );
      if (mounted) setState(() => _state = AppState(backend));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Permanently deletes identity, database and cached media, returning to a clean state.
  Future<void> _deleteAccount() async {
    final old = _state;
    setState(() {
      _state = null;
      _error = null;
    });
    old?.dispose();

    const storage = FlutterSecureStorage();
    await storage.delete(key: 'sync_local_key');

    try {
      final support = await getApplicationSupportDirectory();
      if (await support.exists()) {
        final entities = support.listSync(recursive: false);
        for (final entity in entities) {
          try {
            if (entity is File) {
              entity.deleteSync();
            } else if (entity is Directory) {
              entity.deleteSync(recursive: true);
            }
          } catch (_) {}
        }
      }
    } catch (_) {}

    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _start();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLocale.instance,
      builder: (context, _) {
        final state = _state;
        final app = MaterialApp(
          title: 'Sync',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: state == null
              ? _Splash(
                  error: _error,
                  onRetry: () {
                    setState(() => _error = null);
                    _start();
                  },
                )
              : ListenableBuilder(
                  listenable: state,
                  builder: (context, _) {
                    if (!state.loaded) return const _Splash();
                    if (state.needsProfile) return const OnboardingScreen();
                    if (_locked && _cached2faPassword != null && _cached2faPassword!.isNotEmpty) {
                      return LockScreen(
                        expectedPassword: _cached2faPassword!,
                        hint: _cached2faHint,
                        onUnlocked: () => setState(() => _locked = false),
                        onReset: _deleteAccount,
                      );
                    }
                    return const ShellScreen();
                  },
                ),
        );
        if (state == null) return app;
        // Above the navigator: pushed routes are siblings of home, not its descendants.
        return SyncScope(
          state: state,
          gateway: _gateway,
          onDeleteAccount: _deleteAccount,
          onLockApp: _lockNow,
          onUpdate2FA: () => _refresh2FA(autoLock: false),
          has2FA: _cached2faPassword != null && _cached2faPassword!.isNotEmpty,
          child: app,
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash({this.error, this.onRetry});
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: Center(
          child: error == null
              ? const SyncOrb(size: 64)
              : EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: "Sync couldn't start",
                  body: error,
                  action: GlassButton(label: 'Try again', onTap: onRetry),
                ),
        ),
      ),
    );
  }
}
