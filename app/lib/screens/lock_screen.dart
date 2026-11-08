import 'package:flutter/material.dart';

import '../core/localization.dart';
import '../ui/glass.dart';
import '../ui/theme.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.expectedPassword, this.hint, required this.onUnlocked, this.onReset});

  final String expectedPassword;
  final String? hint;
  final VoidCallback onUnlocked;
  final VoidCallback? onReset;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _passwordController = TextEditingController();
  bool _obscure = true;
  bool _showHint = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _verify() {
    final input = _passwordController.text;
    if (input == widget.expectedPassword) {
      setState(() => _error = null);
      widget.onUnlocked();
    } else {
      setState(() => _error = tr('invalid_password'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Glass(
                  radius: 28,
                  padding: const EdgeInsets.all(26),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Glowing 2FA Lock Icon
                      Center(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [
                                const Color(0xFFFF9F0A).withValues(alpha: 0.3),
                                const Color(0xFFFF375F).withValues(alpha: 0.3),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            border: Border.all(color: const Color(0xFFFF9F0A).withValues(alpha: 0.6), width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFFFF9F0A).withValues(alpha: 0.3),
                                blurRadius: 24,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.lock_rounded, size: 40, color: Color(0xFFFF9F0A)),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        tr('two_factor_auth'),
                        style: SyncText.largeTitle.copyWith(fontSize: 22),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(tr('enter_2fa_subtitle'), style: SyncText.secondary, textAlign: TextAlign.center),
                      const SizedBox(height: 24),
                      GlassField(
                        controller: _passwordController,
                        hint: tr('two_factor_password'),
                        obscure: _obscure,
                        trailing: IconButton(
                          icon: Icon(
                            _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                            color: SyncColors.textSecondary,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                        onSubmitted: (_) => _verify(),
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          style: const TextStyle(fontFamily: syncFont, color: SyncColors.danger, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (widget.hint != null && widget.hint!.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        if (_showHint)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.lightbulb_outline_rounded, color: Color(0xFFFFD60A), size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${tr('two_factor_hint')}: ${widget.hint}',
                                    style: SyncText.caption.copyWith(color: Colors.white70),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Center(
                            child: TextButton.icon(
                              icon: const Icon(Icons.lightbulb_outline_rounded, size: 16, color: Colors.white54),
                              label: Text(tr('show_hint'), style: SyncText.caption.copyWith(color: Colors.white70)),
                              onPressed: () => setState(() => _showHint = true),
                            ),
                          ),
                      ],
                      const SizedBox(height: 20),
                      GlassButton(label: tr('unlock'), primary: true, onTap: _verify),
                      if (widget.onReset != null) ...[
                        const SizedBox(height: 14),
                        TextButton(
                          onPressed: widget.onReset,
                          child: Text(tr('forgot_password_reset'), style: SyncText.secondary.copyWith(fontSize: 13)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
