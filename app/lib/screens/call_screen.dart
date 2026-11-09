import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/call_controller.dart';

// ─── Call Screen ─────────────────────────────────────────────────────────────

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.controller});
  final CallController controller;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with SingleTickerProviderStateMixin {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  late final AnimationController _pulseAnim;
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    widget.controller.addListener(_onStateChanged);
    _pulseAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _scheduleHideControls();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (!mounted) return;
    _onStateChanged();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {
      _localRenderer.srcObject = widget.controller.localStream;
      _remoteRenderer.srcObject = widget.controller.remoteStream;
    });
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && widget.controller.state == CallState.connected) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _onTapScreen() {
    if (widget.controller.state != CallState.connected) {
      if (!_controlsVisible) setState(() => _controlsVisible = true);
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onStateChanged);
    _hideControlsTimer?.cancel();
    _pulseAnim.dispose();
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final session = ctrl.session;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _onTapScreen,
        child: Stack(
          children: [
            // ── Background / Remote stream ──────────────────────────
            if (ctrl.state == CallState.connected && session?.type == CallType.video)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              _CallBackground(session: session, state: ctrl.state, pulseAnim: _pulseAnim),

            // ── Local video (PiP corner) ────────────────────────────
            if (ctrl.state == CallState.connected &&
                session?.type == CallType.video &&
                !ctrl.isCameraOff)
              Positioned(
                top: MediaQuery.of(context).padding.top + 16,
                right: 16,
                width: 100,
                height: 140,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RTCVideoView(_localRenderer, mirror: ctrl.isFrontCamera),
                ),
              ),

            // ── Gradient overlay ───────────────────────────────────
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.6),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.7),
                    ],
                    stops: const [0, 0.4, 1],
                  ),
                ),
              ),
            ),

            // ── Top info bar ───────────────────────────────────────
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 0,
              right: 0,
              child: _TopBar(ctrl: ctrl),
            ),

            // ── Bottom controls ────────────────────────────────────
            AnimatedOpacity(
              opacity: (ctrl.state != CallState.connected || _controlsVisible) ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 48),
                  child: _buildBottomControls(ctrl),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls(CallController ctrl) {
    switch (ctrl.state) {
      case CallState.calling:
        return _OutgoingControls(ctrl: ctrl);
      case CallState.ringing:
        return _IncomingControls(ctrl: ctrl);
      case CallState.connected:
        return _ConnectedControls(ctrl: ctrl);
      default:
        return const SizedBox.shrink();
    }
  }
}

// ─── Top bar (name + duration) ───────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({required this.ctrl});
  final CallController ctrl;

  String get _statusText {
    switch (ctrl.state) {
      case CallState.calling:
        return 'Chaqirmoqda...';
      case CallState.ringing:
        return 'Kiruvchi qo\'ng\'iroq';
      case CallState.connected:
        final d = ctrl.callDuration;
        final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
        final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
        final hh = d.inHours > 0 ? '${d.inHours}:' : '';
        return '$hh$mm:$ss';
      case CallState.ended:
        return 'Qo\'ng\'iroq tugadi';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final peerName = ctrl.session?.peerName;
    final displayName = (peerName != null && peerName.isNotEmpty) ? peerName : 'Foydalanuvchi';

    return Column(
      children: [
        Text(
          displayName,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w600,
            shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _statusText,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: 15,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
          ),
        ),
      ],
    );
  }
}

// ─── Background for audio / calling / ringing state ──────────────────────────

class _CallBackground extends StatelessWidget {
  const _CallBackground({this.session, required this.state, required this.pulseAnim});
  final CallSession? session;
  final CallState state;
  final AnimationController pulseAnim;

  @override
  Widget build(BuildContext context) {
    final peerName = session?.peerName ?? '';
    return Stack(
      fit: StackFit.expand,
      children: [
        // Dark gradient background
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0A0F28), Color(0xFF131B3A), Color(0xFF0D1526)],
            ),
          ),
        ),
        // Animated pulse rings behind avatar
        Center(
          child: AnimatedBuilder(
            animation: pulseAnim,
            builder: (_, _) => Stack(
              alignment: Alignment.center,
              children: [
                _PulseRing(scale: 1.6 + pulseAnim.value * 0.2, opacity: 0.1),
                _PulseRing(scale: 1.3 + pulseAnim.value * 0.15, opacity: 0.15),
                _PulseRing(scale: 1.0 + pulseAnim.value * 0.1, opacity: 0.2),
              ],
            ),
          ),
        ),
        // Avatar
        Center(
          child: _Avatar(
            avatar: session?.peerAvatar,
            name: peerName,
            size: 110,
          ),
        ),
      ],
    );
  }
}

class _PulseRing extends StatelessWidget {
  const _PulseRing({required this.scale, required this.opacity});
  final double scale;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale,
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: opacity), width: 2),
        ),
      ),
    );
  }
}

// ─── Avatar widget ────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  const _Avatar({this.avatar, required this.name, required this.size});
  final String? avatar;
  final String name;
  final double size;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    final trimmed = name.trim();
    return trimmed.isNotEmpty ? trimmed[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFF4A90E2), Color(0xFF1E3A8A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(color: const Color(0xFF4A90E2).withValues(alpha: 0.4), blurRadius: 20, spreadRadius: 5),
        ],
      ),
      child: avatar != null && avatar!.isNotEmpty
          ? ClipOval(
              child: Image.network(
                avatar!,
                fit: BoxFit.cover,
                width: size,
                height: size,
                errorBuilder: (_, _, _) => _Initials(initials: _initials, size: size),
              ),
            )
          : _Initials(initials: _initials, size: size),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.initials, required this.size});
  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        initials,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ─── Outgoing call controls ───────────────────────────────────────────────────

class _OutgoingControls extends StatelessWidget {
  const _OutgoingControls({required this.ctrl});
  final CallController ctrl;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CallBtn(
          icon: Icons.call_end,
          color: const Color(0xFFE53935),
          size: 68,
          onTap: ctrl.hangUp,
          label: 'Qo\'yish',
        ),
      ],
    );
  }
}

// ─── Incoming call controls ───────────────────────────────────────────────────

class _IncomingControls extends StatelessWidget {
  const _IncomingControls({required this.ctrl});
  final CallController ctrl;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CallBtn(
              icon: Icons.call_end,
              color: const Color(0xFFE53935),
              size: 68,
              onTap: ctrl.rejectCall,
            ),
            const SizedBox(height: 8),
            const Text('Rad etish', style: TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CallBtn(
              icon: ctrl.session?.type == CallType.video ? Icons.videocam : Icons.call,
              color: const Color(0xFF43A047),
              size: 68,
              onTap: ctrl.answerCall,
            ),
            const SizedBox(height: 8),
            const Text('Qabul qilish', style: TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      ],
    );
  }
}

// ─── Connected call controls ──────────────────────────────────────────────────

class _ConnectedControls extends StatelessWidget {
  const _ConnectedControls({required this.ctrl});
  final CallController ctrl;

  @override
  Widget build(BuildContext context) {
    final isVideo = ctrl.session?.type == CallType.video;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SmallBtn(
              icon: ctrl.isMuted ? Icons.mic_off : Icons.mic,
              active: ctrl.isMuted,
              label: ctrl.isMuted ? 'Unmute' : 'Mute',
              onTap: ctrl.toggleMute,
            ),
            const SizedBox(width: 24),
            if (isVideo) ...[
              _SmallBtn(
                icon: ctrl.isCameraOff ? Icons.videocam_off : Icons.videocam,
                active: ctrl.isCameraOff,
                label: ctrl.isCameraOff ? 'Kamera yoq' : 'Kamera o\'ch',
                onTap: ctrl.toggleCamera,
              ),
              const SizedBox(width: 24),
              _SmallBtn(
                icon: Icons.flip_camera_ios,
                active: false,
                label: 'Almashtir',
                onTap: ctrl.switchCamera,
              ),
              const SizedBox(width: 24),
            ],
            _SmallBtn(
              icon: Icons.speaker,
              active: false,
              label: 'Speaker',
              onTap: () {}, // TODO: wire speaker toggle via audioplayers
            ),
          ],
        ),
        const SizedBox(height: 28),
        _CallBtn(
          icon: Icons.call_end,
          color: const Color(0xFFE53935),
          size: 72,
          onTap: ctrl.hangUp,
        ),
      ],
    );
  }
}

// ─── Shared button widgets ────────────────────────────────────────────────────

class _CallBtn extends StatelessWidget {
  const _CallBtn({
    required this.icon,
    required this.color,
    required this.size,
    required this.onTap,
    this.label,
  });
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 16, spreadRadius: 2)],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.45),
      ),
    );
  }
}

class _SmallBtn extends StatelessWidget {
  const _SmallBtn({
    required this.icon,
    required this.active,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final bool active;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: active ? Colors.white.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: Icon(icon, color: active ? Colors.white : Colors.white70, size: 26),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}
