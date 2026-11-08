import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

class SyncError implements Exception {
  SyncError(this.code);
  final String code;

  /// Text fit to show a person, for both gateway codes and core messages.
  String get message =>
      const {
        'offline': "You're offline. Try again when you reconnect.",
        'username_taken': 'That username is already taken.',
        'invalid_username': 'Usernames use 3-32 letters, numbers or underscores.',
        'invalid_name': 'Enter a name of up to 64 characters.',
        'rate_limited': 'Too many requests. Wait a moment and try again.',
        'too_many_listings': 'You can have up to 20 listings at a time.',
        'ai_not_configured': "AI isn't set up on this server yet.",
        'ai_busy': 'The AI is busy right now. Try again shortly.',
        'ai_refused': "The AI declined to answer that.",
        'ai_failed': "The AI couldn't reply. Try again.",
        'bad_request': "That request wasn't valid.",
        'server_error': 'The server had a problem. Try again.',
        'not_found': 'That no longer exists.',
      }[code] ??
      code;

  @override
  String toString() => message;
}

abstract class SyncBackend {
  Stream<Map<String, dynamic>> get updates;
  Future<Map<String, dynamic>> call(String type, [Map<String, dynamic> params = const {}]);
  void dispose();
}

typedef _CreateC = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SendC = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _SendDart = void Function(Pointer<Void>, Pointer<Utf8>);
typedef _ReceiveC = Pointer<Utf8> Function(Pointer<Void>, Double);
typedef _ReceiveDart = Pointer<Utf8> Function(Pointer<Void>, double);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

DynamicLibrary _openCore() {
  final override = Platform.environment['SYNC_CORE_LIB'];
  if (override != null) return DynamicLibrary.open(override);
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  return DynamicLibrary.open('libsync_core.so');
}

/// Talks to sync_core over FFI. A background isolate sits in the blocking receive
/// call, so the UI isolate never waits on the core and frames are never delayed by it.
class NativeBackend implements SyncBackend {
  NativeBackend._(this._lib, this._client) {
    _send = _lib.lookupFunction<_SendC, _SendDart>('sync_client_send');
    _destroy = _lib.lookupFunction<_DestroyC, _DestroyDart>('sync_client_destroy');
  }

  static Future<NativeBackend> start({
    required String dataDir,
    required String localKeyHex,
    required String gatewayUrl,
  }) async {
    final lib = _openCore();
    final create = lib.lookupFunction<_CreateC, _CreateC>('sync_client_create');
    final dir = dataDir.toNativeUtf8(), key = localKeyHex.toNativeUtf8(), url = gatewayUrl.toNativeUtf8();
    final client = create(dir, key, url);
    malloc.free(dir);
    malloc.free(key);
    malloc.free(url);
    if (client == nullptr) {
      throw SyncError("Couldn't open local data. Check the server address starts with ws://.");
    }
    final backend = NativeBackend._(lib, client);
    await backend._startPump();
    return backend;
  }

  final DynamicLibrary _lib;
  final Pointer<Void> _client;
  late final _SendDart _send;
  late final _DestroyDart _destroy;
  final _updates = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _inbox = ReceivePort();
  SendPort? _pumpControl;
  int _nextExtra = 0;

  Future<void> _startPump() async {
    final ready = Completer<void>();
    _inbox.listen((m) {
      if (m is SendPort) {
        _pumpControl = m;
        ready.complete();
      } else if (m == null) {
        _inbox.close();
        _destroy(_client);
        _updates.close();
      } else {
        _onEvent(jsonDecode(m as String) as Map<String, dynamic>);
      }
    });
    await Isolate.spawn(_pump, _PumpArgs(_inbox.sendPort, _client.address));
    await ready.future;
  }

  void _onEvent(Map<String, dynamic> e) {
    final extra = e['@extra'];
    if (extra is int) {
      final c = _pending.remove(extra);
      if (c == null) return;
      if (e['@type'] == 'error') {
        c.completeError(SyncError(e['message'] as String? ?? 'failed'));
      } else {
        c.complete(e);
      }
    } else {
      _updates.add(e);
    }
  }

  @override
  Stream<Map<String, dynamic>> get updates => _updates.stream;

  @override
  Future<Map<String, dynamic>> call(String type, [Map<String, dynamic> params = const {}]) {
    final id = ++_nextExtra;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    final json = jsonEncode({...params, '@type': type, '@extra': id}).toNativeUtf8();
    _send(_client, json);
    malloc.free(json);
    return c.future;
  }

  @override
  void dispose() {
    for (final c in _pending.values) {
      c.completeError(SyncError('offline'));
    }
    _pending.clear();
    _pumpControl?.send('stop');
  }
}

class _PumpArgs {
  _PumpArgs(this.port, this.client);
  final SendPort port;
  final int client;
}

Future<void> _pump(_PumpArgs args) async {
  final lib = _openCore();
  final receive = lib.lookupFunction<_ReceiveC, _ReceiveDart>('sync_client_receive');
  final free = lib.lookupFunction<_FreeC, _FreeDart>('sync_string_free');
  final client = Pointer<Void>.fromAddress(args.client);
  final control = ReceivePort();
  args.port.send(control.sendPort);
  var running = true;
  control.listen((_) => running = false);
  while (running) {
    final s = receive(client, 0.1);
    if (s != nullptr) {
      args.port.send(s.toDartString());
      free(s);
    }
    await Future<void>.delayed(Duration.zero); // lets the stop message arrive
  }
  control.close();
  args.port.send(null);
}
