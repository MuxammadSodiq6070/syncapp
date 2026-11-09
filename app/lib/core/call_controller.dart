import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'sound_service.dart';

// ─── Call State ─────────────────────────────────────────────────────────────

enum CallState { idle, calling, ringing, connected, ended }

enum CallType { audio, video }

class CallSession {
  final String callId;
  final String peerId;
  final String peerName;
  final String? peerAvatar;
  final CallType type;
  final bool isOutgoing;

  CallSession({
    required this.callId,
    required this.peerId,
    required this.peerName,
    this.peerAvatar,
    required this.type,
    required this.isOutgoing,
  });
}

// ─── STUN / TURN configuration ───────────────────────────────────────────────

const _iceServers = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    // Add your Coturn TURN server here:
    // {
    //   'urls': 'turn:your-turn-server.com:3478',
    //   'username': 'syncuser',
    //   'credential': 'changeme',
    // },
  ],
  'sdpSemantics': 'unified-plan',
};

const _mediaConstraints = {
  'audio': true,
  'video': {
    'facingMode': 'user',
    'width': {'ideal': 1280},
    'height': {'ideal': 720},
  },
};

const _audioOnlyConstraints = {
  'audio': true,
  'video': false,
};

// ─── Typedef for signaling sender ────────────────────────────────────────────

typedef SignalSender = void Function(Map<String, dynamic> signal);

// ─── CallController ─────────────────────────────────────────────────────────

class CallController extends ChangeNotifier {
  CallController({required this.myId, required this.sendSignal});

  final String myId;
  final SignalSender sendSignal;

  // Public state
  CallState state = CallState.idle;
  CallSession? session;
  MediaStream? localStream;
  MediaStream? remoteStream;
  bool isMuted = false;
  bool isCameraOff = false;
  bool isFrontCamera = true;
  Duration callDuration = Duration.zero;

  // Private
  RTCPeerConnection? _pc;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescSet = false;
  Timer? _timeoutTimer;
  Timer? _durationTimer;
  DateTime? _connectedAt;

  // ── Outgoing call ────────────────────────────────────────────────────────

  Future<void> startCall({
    required String peerId,
    required String peerName,
    String? peerAvatar,
    CallType type = CallType.video,
  }) async {
    if (state != CallState.idle) return;

    final callId = '${myId}_${peerId}_${DateTime.now().millisecondsSinceEpoch}';
    session = CallSession(
      callId: callId,
      peerId: peerId,
      peerName: peerName,
      peerAvatar: peerAvatar,
      type: type,
      isOutgoing: true,
    );

    state = CallState.calling;
    notifyListeners();

    await SoundService.instance.playOutgoingRing();

    try {
      await _createPeerConnection(type);
      await _acquireLocalStream(type);

      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);

      sendSignal({
        '@type': 'call_offer',
        'sender_id': myId,
        'receiver_id': peerId,
        'payload': {
          'call_id': callId,
          'type': type.name,
          'sdp': offer.sdp,
          'sdp_type': offer.type,
        },
      });

      // 30-second ring timeout
      _timeoutTimer = Timer(const Duration(seconds: 30), _onTimeout);
    } catch (e) {
      debugPrint('CallController.startCall error: $e');
      await _terminate(CallState.ended);
    }
  }

  // ── Incoming call ────────────────────────────────────────────────────────

  /// Called when backend delivers a call_offer signal.
  Future<void> onIncomingOffer(Map<String, dynamic> payload) async {
    if (state != CallState.idle) {
      // Already in a call — send busy
      sendSignal({
        '@type': 'call_busy',
        'sender_id': myId,
        'receiver_id': payload['sender_id'],
        'payload': {'call_id': payload['payload']['call_id']},
      });
      return;
    }

    final p = payload['payload'] as Map<String, dynamic>;
    final type = p['type'] == 'audio' ? CallType.audio : CallType.video;

    session = CallSession(
      callId: p['call_id'] as String,
      peerId: payload['sender_id'] as String,
      peerName: payload['sender_name'] as String? ?? 'Unknown',
      peerAvatar: payload['sender_avatar'] as String?,
      type: type,
      isOutgoing: false,
    );

    // Store offer SDP for later answer
    _pendingOffer = RTCSessionDescription(p['sdp'] as String, p['sdp_type'] as String);

    state = CallState.ringing;
    notifyListeners();

    await SoundService.instance.playRingtone();

    // 30-second auto-decline if not answered
    _timeoutTimer = Timer(const Duration(seconds: 30), _onTimeout);
  }

  RTCSessionDescription? _pendingOffer;

  /// User taps "Accept"
  Future<void> answerCall() async {
    if (state != CallState.ringing || session == null || _pendingOffer == null) return;

    _timeoutTimer?.cancel();
    await SoundService.instance.stopRingtone();

    try {
      await _createPeerConnection(session!.type);
      await _acquireLocalStream(session!.type);

      await _pc!.setRemoteDescription(_pendingOffer!);
      _remoteDescSet = true;
      await _flushPendingCandidates();

      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      sendSignal({
        '@type': 'call_answer',
        'sender_id': myId,
        'receiver_id': session!.peerId,
        'payload': {
          'call_id': session!.callId,
          'sdp': answer.sdp,
          'sdp_type': answer.type,
        },
      });
    } catch (e) {
      debugPrint('CallController.answerCall error: $e');
      await _terminate(CallState.ended);
    }
  }

  /// User taps "Reject"
  Future<void> rejectCall() async {
    if (session == null) return;
    sendSignal({
      '@type': 'call_reject',
      'sender_id': myId,
      'receiver_id': session!.peerId,
      'payload': {'call_id': session!.callId},
    });
    await _terminate(CallState.ended);
  }

  /// User taps "Hang up"
  Future<void> hangUp() async {
    if (session == null) return;
    sendSignal({
      '@type': 'call_hangup',
      'sender_id': myId,
      'receiver_id': session!.peerId,
      'payload': {'call_id': session!.callId},
    });
    await _terminate(CallState.ended);
  }

  // ── Incoming signal handlers ─────────────────────────────────────────────

  Future<void> handleSignal(Map<String, dynamic> msg) async {
    final type = msg['@type'] as String;
    final payload = msg['payload'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'call_answer':
        await _onRemoteAnswer(payload);
      case 'call_candidate':
        await _onRemoteCandidate(payload);
      case 'call_hangup':
        await _onRemoteHangup();
      case 'call_reject':
        await _onRemoteReject();
      case 'call_busy':
        await _onRemoteBusy();
    }
  }

  Future<void> _onRemoteAnswer(Map<String, dynamic> payload) async {
    if (_pc == null) return;
    _timeoutTimer?.cancel();
    await SoundService.instance.stopRingtone();

    final desc = RTCSessionDescription(payload['sdp'] as String, payload['sdp_type'] as String);
    await _pc!.setRemoteDescription(desc);
    _remoteDescSet = true;
    await _flushPendingCandidates();
  }

  Future<void> _onRemoteCandidate(Map<String, dynamic> payload) async {
    final candidate = RTCIceCandidate(
      payload['candidate'] as String,
      payload['sdp_mid'] as String?,
      payload['sdp_m_line_index'] as int?,
    );

    if (_remoteDescSet && _pc != null) {
      await _pc!.addCandidate(candidate);
    } else {
      // ICE Trickling: queue until remote description is set
      _pendingCandidates.add(candidate);
    }
  }

  Future<void> _onRemoteHangup() async {
    await SoundService.instance.playCallEnd();
    await _terminate(CallState.ended);
  }

  Future<void> _onRemoteReject() async {
    await SoundService.instance.playCallEnd();
    await _terminate(CallState.ended);
  }

  Future<void> _onRemoteBusy() async {
    await SoundService.instance.playCallEnd();
    await _terminate(CallState.ended);
  }

  // ── Media controls ───────────────────────────────────────────────────────

  Future<void> toggleMute() async {
    isMuted = !isMuted;
    localStream?.getAudioTracks().forEach((t) => t.enabled = !isMuted);
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    isCameraOff = !isCameraOff;
    localStream?.getVideoTracks().forEach((t) => t.enabled = !isCameraOff);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    if (localStream == null) return;
    final tracks = localStream!.getVideoTracks();
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
    isFrontCamera = !isFrontCamera;
    notifyListeners();
  }

  // ── Internal helpers ─────────────────────────────────────────────────────

  Future<void> _createPeerConnection(CallType type) async {
    _pc = await createPeerConnection(_iceServers);

    _pc!.onIceCandidate = (candidate) {
      if (session == null) return;
      sendSignal({
        '@type': 'call_candidate',
        'sender_id': myId,
        'receiver_id': session!.peerId,
        'payload': {
          'call_id': session!.callId,
          'candidate': candidate.candidate,
          'sdp_mid': candidate.sdpMid,
          'sdp_m_line_index': candidate.sdpMLineIndex,
        },
      });
    };

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteStream = event.streams.first;
        notifyListeners();
      }
    };

    _pc!.onConnectionState = (s) {
      debugPrint('RTCPeerConnection state: $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        state = CallState.connected;
        _connectedAt = DateTime.now();
        _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          callDuration = DateTime.now().difference(_connectedAt!);
          notifyListeners();
        });
        SoundService.instance.playCallConnect();
        notifyListeners();
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _terminate(CallState.ended);
      }
    };
  }

  Future<void> _acquireLocalStream(CallType type) async {
    final constraints = type == CallType.video ? _mediaConstraints : _audioOnlyConstraints;
    localStream = await navigator.mediaDevices.getUserMedia(constraints);
    localStream!.getTracks().forEach((t) => _pc!.addTrack(t, localStream!));
    notifyListeners();
  }

  Future<void> _flushPendingCandidates() async {
    for (final c in _pendingCandidates) {
      await _pc?.addCandidate(c);
    }
    _pendingCandidates.clear();
  }

  void _onTimeout() {
    sendSignal({
      '@type': 'call_hangup',
      'sender_id': myId,
      'receiver_id': session?.peerId ?? '',
      'payload': {'call_id': session?.callId ?? '', 'reason': 'timeout'},
    });
    _terminate(CallState.ended);
  }

  Future<void> _terminate(CallState endState) async {
    _timeoutTimer?.cancel();
    _durationTimer?.cancel();
    await SoundService.instance.stopRingtone();

    await localStream?.dispose();
    localStream = null;
    remoteStream = null;

    await _pc?.close();
    _pc = null;

    _pendingCandidates.clear();
    _remoteDescSet = false;
    _pendingOffer = null;
    _connectedAt = null;
    callDuration = Duration.zero;
    session = null;
    state = endState;

    notifyListeners();

    // Reset to idle after a brief delay so UI can show "ended"
    await Future.delayed(const Duration(seconds: 2));
    state = CallState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _terminate(CallState.idle);
    super.dispose();
  }
}
