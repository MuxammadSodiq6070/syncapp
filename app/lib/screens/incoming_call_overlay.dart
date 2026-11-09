import 'package:flutter/material.dart';

import '../core/call_controller.dart';
import 'call_screen.dart';

/// Transparent overlay that shows incoming/active call UI on top of any screen.
/// Automatically manages full-screen CallScreen overlay whenever
/// controller.state != CallState.idle.
class IncomingCallOverlay extends StatefulWidget {
  const IncomingCallOverlay({
    super.key,
    required this.controller,
    required this.child,
  });

  final CallController controller;
  final Widget child;

  @override
  State<IncomingCallOverlay> createState() => _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends State<IncomingCallOverlay> {
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onCallStateChanged);
    _syncOverlay();
  }

  @override
  void didUpdateWidget(IncomingCallOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onCallStateChanged);
      widget.controller.addListener(_onCallStateChanged);
      _syncOverlay();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onCallStateChanged);
    _removeOverlayEntry();
    super.dispose();
  }

  void _onCallStateChanged() {
    if (!mounted) return;
    _syncOverlay();
  }

  void _syncOverlay() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final isCallActive = widget.controller.state != CallState.idle;
      if (isCallActive) {
        _showOverlay();
      } else {
        _removeOverlayEntry();
      }
    });
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true) ?? Overlay.maybeOf(context);
    if (overlay != null) {
      _overlayEntry = OverlayEntry(
        builder: (_) => CallScreen(controller: widget.controller),
      );
      overlay.insert(_overlayEntry!);
    } else {
      // Rebuild so Stack fallback in build() renders CallScreen
      if (mounted) setState(() {});
    }
  }

  void _removeOverlayEntry() {
    if (_overlayEntry != null) {
      if (_overlayEntry!.mounted) {
        _overlayEntry!.remove();
      }
      _overlayEntry = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // If OverlayEntry couldn't be used (e.g. no Overlay in context hierarchy),
    // fallback to rendering CallScreen directly in a Stack.
    final isCallActive = widget.controller.state != CallState.idle;
    final fallbackToStack = isCallActive && _overlayEntry == null;

    return Stack(
      children: [
        widget.child,
        if (fallbackToStack)
          Positioned.fill(
            child: CallScreen(controller: widget.controller),
          ),
      ],
    );
  }
}
