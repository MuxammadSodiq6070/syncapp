import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/countries.dart';
import '../core/localization.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';

enum OnboardingStep { telegram, phone, otp, profile, avatar, twoFactor, recovery }

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  // Telegram first: it is the path in use. The phone and code screens stay for the
  // paid providers, and are reached only if the gateway says the bot is not set up.
  OnboardingStep _step = OnboardingStep.telegram;
  String _tgNonce = '';
  String _tgLink = '';
  bool _tgWaiting = false;
  Timer? _tgTimer;

  // Step 1: Phone & OTP (International with Country Picker)
  late Country _selectedCountry;
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  // Every sent code costs money, and the resend countdown lives on the next screen,
  // so going back must not be a way around it.
  DateTime? _lastSmsAt;
  int _countdown = 60;
  int _resendWait = 60;
  String _via = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _selectedCountry = defaultCountry();
  }

  // Step 2: Profile & Bio
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _bioController = TextEditingController();

  // Step 3: Avatar
  String? _avatarPath;
  int _selectedPreset = 0;
  final List<List<Color>> _presets = const [
    [Color(0xFF0A84FF), Color(0xFF5E5CE6)], // Electric Blue / Royal
    [Color(0xFF30D158), Color(0xFF0A84FF)], // Emerald / Cyan
    [Color(0xFFBF5AF2), Color(0xFFFF375F)], // Violet / Rose
    [Color(0xFFFF9F0A), Color(0xFFFF453A)], // Sunset Amber
    [Color(0xFF64D2FF), Color(0xFF007AFF)], // Ice Blue
  ];

  // Step 4: 2FA Password (Cloud password, skippable)
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _hintController = TextEditingController();
  bool _obscurePassword = true;

  // Step 5: Recovery Key
  String? _recoveryKey;
  bool _recoverySaved = false;

  bool _busy = false;

  @override
  void dispose() {
    _timer?.cancel();
    _tgTimer?.cancel();
    _phoneController.dispose();
    _otpController.dispose();
    _nameController.dispose();
    _usernameController.dispose();
    _bioController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _hintController.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _countdown = seconds;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_countdown > 0) {
        setState(() => _countdown--);
      } else {
        t.cancel();
      }
    });
  }

  /// Where the code actually went. Only the gateway knows which provider is
  /// configured, so it says, and the screen stops guessing at an SMS inbox.
  String _sentWhere(String via) => switch (via) {
    'telegram' => tr('code_sent_telegram'),
    'sms' => tr('code_sent_sms'),
    _ => tr('code_sent'),
  };

  /// Turns a gateway error code into something a person can act on. An
  /// unrecognised one is shown as it arrived, which beats hiding a real fault.
  String _codeError(Object e) {
    final text = '$e';
    const known = {
      'no_telegram': 'err_no_telegram',
      'invalid_phone': 'err_invalid_phone',
      'phone_already_used': 'err_phone_already_used',
      'too_soon': 'err_too_soon',
      'phone_daily_limit': 'err_limit',
      'sms_budget_reached': 'err_limit',
      'too_many_signups': 'err_limit',
      'too_many_attempts': 'err_code_expired',
      'code_expired': 'err_code_expired',
      'invalid_code': 'err_code_wrong',
      'verification_failed': 'err_code_wrong',
      'offline': 'err_offline',
    };
    for (final entry in known.entries) {
      if (text.contains(entry.key)) return tr(entry.value);
    }
    return '${tr('sms_error')}: $text';
  }

  // --- Step 1: Telegram ------------------------------------------------------

  /// Opens the bot and waits for it. The gateway makes the nonce, the bot proves
  /// the number and the gateway issues the ticket, so a changed app gains nothing
  /// by lying here.
  Future<void> _startTelegram() async {
    setState(() => _busy = true);
    try {
      final started = await context.sync.startTelegramVerify();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _tgNonce = started.nonce;
        _tgLink = started.url;
        _tgWaiting = true;
      });
      await _openTelegram();
      _tgTimer?.cancel();
      _tgTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollTelegram());
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      // A gateway without a bot configured answers this with "not enabled". The
      // phone and code screens are still there for that case.
      if ('$e'.contains('not enabled') || '$e'.contains('404')) {
        setState(() => _step = OnboardingStep.phone);
        return;
      }
      showToast(context, _codeError(e));
    }
  }

  Future<void> _openTelegram() async {
    if (_tgLink.isEmpty) return;
    final uri = Uri.tryParse(_tgLink);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) showToast(context, tr('tg_open_failed'));
    }
  }

  Future<void> _pollTelegram() async {
    if (_tgNonce.isEmpty || _busy) return;
    String? ticket;
    try {
      ticket = await context.sync.pollTelegramVerify(_tgNonce);
    } catch (_) {
      return; // offline or a hiccup; the next tick tries again
    }
    if (ticket == null || !mounted) return;
    _tgTimer?.cancel();
    setState(() => _busy = true);
    try {
      await context.sync.submitTicket(ticket);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _tgWaiting = false;
        _step = OnboardingStep.profile;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _tgWaiting = false;
        _tgNonce = '';
      });
      showToast(context, _codeError(e));
    }
  }

  void _restartTelegram() {
    _tgTimer?.cancel();
    setState(() {
      _tgNonce = '';
      _tgLink = '';
      _tgWaiting = false;
    });
  }

  Widget _buildTelegramStep(AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: SyncColors.accent),
            alignment: Alignment.center,
            child: const Icon(Icons.send_rounded, color: Colors.white, size: 34),
          ),
        ),
        const SizedBox(height: 18),
        Text(tr('tg_title'), style: SyncText.largeTitle, textAlign: TextAlign.center),
        const SizedBox(height: 10),
        Text(
          _tgWaiting ? tr('tg_waiting') : tr('tg_body'),
          style: SyncText.secondary,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 26),
        if (_tgWaiting) ...[
          const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
          const SizedBox(height: 22),
          GlassButton(label: tr('tg_open_again'), primary: true, onTap: _openTelegram),
          const SizedBox(height: 12),
          Center(
            child: TextButton(onPressed: _restartTelegram, child: Text(tr('tg_restart'), style: SyncText.secondary)),
          ),
        ] else ...[
          GlassButton(
            label: tr('tg_continue'),
            primary: true,
            onTap: _busy ? null : _startTelegram,
          ),
          if (!state.canRequestCode) ...[
            const SizedBox(height: 10),
            Text(tr('connecting'), style: SyncText.caption, textAlign: TextAlign.center),
          ],
        ],
        const SizedBox(height: 14),
        Center(
          child: TextButton(onPressed: _restore, child: Text(tr('restore_account'), style: SyncText.secondary)),
        ),
      ],
    );
  }

  Future<void> _sendOtp() async {
    final rawPhone = _phoneController.text.trim().replaceAll(RegExp(r'\s+'), '');
    if (rawPhone.length < 4) {
      showToast(context, tr('phone_number'));
      return;
    }
    final fullPhone = '${_selectedCountry.dialCode}$rawPhone';
    final since = _lastSmsAt == null ? null : DateTime.now().difference(_lastSmsAt!);
    if (since != null && since.inSeconds < _resendWait) {
      showToast(context, '${tr('resend_in')} ${_resendWait - since.inSeconds} ${tr('sec')}');
      return;
    }
    setState(() => _busy = true);
    try {
      // The gateway sends the code and owns every limit, so a changed app gains
      // nothing by asking more often.
      final sent = await context.sync.requestSmsCode(fullPhone);
      _lastSmsAt = DateTime.now();
      _resendWait = sent.retryAfter;
      _otpController.clear();
      if (mounted) {
        setState(() {
          _busy = false;
          _step = OnboardingStep.otp;
          _via = sent.via;
        });
        _startCountdown(sent.retryAfter);
        showToast(context, _sentWhere(sent.via));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, _codeError(e));
      }
    }
  }

  Future<void> _verifyOtp() async {
    final code = _otpController.text.trim();
    if (code.length < 6) {
      showToast(context, tr('enter_otp'));
      return;
    }
    final fullPhone = '${_selectedCountry.dialCode}${_phoneController.text.trim().replaceAll(RegExp(r'\s+'), '')}';
    setState(() => _busy = true);
    try {
      // The gateway checks the code when the account registers, so a wrong code
      // cannot be waved through here. Waiting for its verdict is what keeps a
      // refusal from looking like success.
      await context.sync.submitCode(fullPhone, code);
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _step = OnboardingStep.profile;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, _codeError(e));
      }
    }
  }

  void _submitProfile() {
    final name = _nameController.text.trim();
    final username = _usernameController.text.trim().replaceFirst('@', '');
    if (name.isEmpty) {
      showToast(context, tr('full_name'));
      return;
    }
    if (username.length < 3) {
      showToast(context, tr('username'));
      return;
    }
    setState(() => _step = OnboardingStep.avatar);
  }

  Future<void> _pickAvatarImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final photo = await picker.pickImage(source: source, imageQuality: 85, maxWidth: 1024);
      if (photo != null) {
        setState(() {
          _avatarPath = photo.path;
        });
      }
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
  }

  void _submitAvatar() {
    setState(() => _step = OnboardingStep.twoFactor);
  }

  void _submit2FA({required bool skip}) {
    if (!skip) {
      final pass = _passwordController.text;
      final confirm = _confirmPasswordController.text;
      if (pass.length < 4) {
        showToast(context, tr('password_short'));
        return;
      }
      if (pass != confirm) {
        showToast(context, tr('passwords_dont_match'));
        return;
      }
    }
    _loadRecoveryKeyAndProceed();
  }

  Future<void> _loadRecoveryKeyAndProceed() async {
    setState(() => _busy = true);
    try {
      final state = context.sync;
      _recoveryKey = await state.recoveryKey();
      setState(() {
        _busy = false;
        _step = OnboardingStep.recovery;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, e);
      }
    }
  }

  Future<void> _finishSetup() async {
    if (!_recoverySaved) {
      showToast(context, tr('recovery_warning'));
      return;
    }
    setState(() => _busy = true);
    try {
      final state = context.sync;
      final username = _usernameController.text.trim().replaceFirst('@', '');
      final name = _nameController.text.trim();
      final fullPhone = '${_selectedCountry.dialCode} ${_phoneController.text.trim()}';

      // Save profile to gateway and core
      await state.setProfile(username, name);

      // Persist additional metadata to secure storage
      const storage = FlutterSecureStorage();
      await storage.write(key: 'sync_user_phone', value: fullPhone);
      await storage.write(key: 'sync_user_country', value: _selectedCountry.code);
      if (_bioController.text.trim().isNotEmpty) {
        await storage.write(key: 'sync_user_bio', value: _bioController.text.trim());
      }
      if (_avatarPath != null) {
        await storage.write(key: 'sync_user_avatar', value: _avatarPath!);
      } else {
        await storage.write(key: 'sync_user_preset_avatar', value: _selectedPreset.toString());
      }
      if (_passwordController.text.isNotEmpty) {
        await storage.write(key: 'sync_2fa_password', value: _passwordController.text);
        if (_hintController.text.isNotEmpty) {
          await storage.write(key: 'sync_2fa_hint', value: _hintController.text.trim());
        }
      }
    } catch (e) {
      if (mounted) showToast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _restore() {
    final c = TextEditingController();
    showGlassSheet<void>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('restore_your_account'), style: SyncText.headline, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              'Enter the 64-character recovery key you saved earlier. Past messages stay on your previous device.',
              style: SyncText.secondary,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            GlassField(controller: c, hint: '64-character recovery key', maxLines: 3, minLines: 2),
            const SizedBox(height: 12),
            GlassButton(
              label: tr('restore'),
              primary: true,
              onTap: () async {
                final state = ctx.sync;
                final nav = Navigator.of(ctx);
                try {
                  await state.importRecoveryKey(c.text.trim().toLowerCase());
                  nav.pop();
                } catch (e) {
                  if (ctx.mounted) showToast(ctx, e);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // This screen must listen for itself. The parent returns it as
    // `const OnboardingScreen()`, and an identical const instance makes Flutter
    // skip the subtree on rebuild, so without this the screen would be built once
    // and never notice the connection coming up: the button stayed disabled and
    // the label stayed on "connecting" for good.
    return ListenableBuilder(
      listenable: context.sync,
      builder: (context, _) => _buildScreen(context, context.sync),
    );
  }

  Widget _buildScreen(BuildContext context, AppState state) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Top Progress Bar
                    _buildProgressBar(),
                    const SizedBox(height: 24),
                    // Current Step View
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(begin: const Offset(0.04, 0), end: Offset.zero).animate(animation),
                          child: child,
                        ),
                      ),
                      child: _buildCurrentStep(state),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar() {
    final totalSteps = 5;
    int currentNum = 1;
    switch (_step) {
      case OnboardingStep.telegram:
      case OnboardingStep.phone:
      case OnboardingStep.otp:
        currentNum = 1;
        break;
      case OnboardingStep.profile:
        currentNum = 2;
        break;
      case OnboardingStep.avatar:
        currentNum = 3;
        break;
      case OnboardingStep.twoFactor:
        currentNum = 4;
        break;
      case OnboardingStep.recovery:
        currentNum = 5;
        break;
    }

    return Column(
      children: [
        Row(
          children: List.generate(totalSteps, (index) {
            final active = index < currentNum;
            return Expanded(
              child: Container(
                height: 4,
                margin: EdgeInsets.symmetric(horizontal: index == 0 || index == totalSteps - 1 ? 2 : 3),
                decoration: BoxDecoration(
                  color: active ? SyncColors.accentBright : Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: SyncColors.accentBright.withValues(alpha: 0.5),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (_step != OnboardingStep.telegram)
              GestureDetector(
                onTap: () {
                  setState(() {
                    switch (_step) {
                      case OnboardingStep.phone:
                        _step = OnboardingStep.telegram;
                        break;
                      case OnboardingStep.otp:
                        _step = OnboardingStep.phone;
                        break;
                      case OnboardingStep.profile:
                        _step = OnboardingStep.otp;
                        break;
                      case OnboardingStep.avatar:
                        _step = OnboardingStep.profile;
                        break;
                      case OnboardingStep.twoFactor:
                        _step = OnboardingStep.avatar;
                        break;
                      case OnboardingStep.recovery:
                        _step = OnboardingStep.twoFactor;
                        break;
                      default:
                        break;
                    }
                  });
                },
                child: const Row(
                  children: [
                    Icon(Icons.arrow_back_ios_new_rounded, size: 14, color: SyncColors.activeTab),
                    SizedBox(width: 4),
                    Text(
                      'Orqaga',
                      style: TextStyle(fontFamily: syncFont, color: SyncColors.activeTab, fontSize: 13),
                    ),
                  ],
                ),
              )
            else
              const SizedBox.shrink(),
            Text(
              'Qadam $currentNum / $totalSteps',
              style: const TextStyle(fontFamily: syncFont, color: SyncColors.textTertiary, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCurrentStep(AppState state) {
    switch (_step) {
      case OnboardingStep.telegram:
        return _buildTelegramStep(state);
      case OnboardingStep.phone:
        return _buildPhoneStep(state);
      case OnboardingStep.otp:
        return _buildOtpStep();
      case OnboardingStep.profile:
        return _buildProfileStep();
      case OnboardingStep.avatar:
        return _buildAvatarStep();
      case OnboardingStep.twoFactor:
        return _buildTwoFactorStep();
      case OnboardingStep.recovery:
        return _buildRecoveryStep();
    }
  }

  // --- Step 1: Phone (Telegram style with Country Picker) ---
  Widget _buildPhoneStep(AppState state) {
    return Column(
      key: const ValueKey('step_phone'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: SyncOrb(size: 72)),
        const SizedBox(height: 20),
        Text(tr('onboarding_title'), style: SyncText.largeTitle, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(tr('onboarding_subtitle'), style: SyncText.secondary, textAlign: TextAlign.center),
        const SizedBox(height: 28),
        // Telegram-style Country Selector
        PressScale(
          onTap: () async {
            final picked = await showCountryPicker(context, current: _selectedCountry);
            if (picked != null) {
              setState(() => _selectedCountry = picked);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Row(
              children: [
                Text(_selectedCountry.flag, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _selectedCountry.displayName,
                    style: SyncText.headline.copyWith(fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _selectedCountry.dialCode,
                  style: const TextStyle(
                    fontFamily: syncFont,
                    color: SyncColors.accentBright,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white54, size: 22),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Phone Number Input Row
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Text(
                _selectedCountry.dialCode,
                style: const TextStyle(
                  fontFamily: syncFont,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GlassField(
                controller: _phoneController,
                hint: tr('phone_hint'),
                keyboardType: TextInputType.phone,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        GlassButton(
          label: tr('get_sms_code'),
          primary: true,
          busy: _busy,
          onTap: !_busy && _phoneController.text.trim().isNotEmpty ? _sendOtp : null,
        ),
        const SizedBox(height: 18),
        Center(
          child: TextButton(
            onPressed: _restore,
            child: Text(tr('restore_account'), style: SyncText.secondary),
          ),
        ),
      ],
    );
  }

  // --- Step 1b: SMS OTP Verification ---
  Widget _buildOtpStep() {
    final fullPhone = '${_selectedCountry.dialCode} ${_phoneController.text.trim()}';
    return Column(
      key: const ValueKey('step_otp'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: CircleAvatar(
            radius: 34,
            backgroundColor: Color(0x330A84FF),
            child: Icon(Icons.sms_outlined, color: SyncColors.accentBright, size: 36),
          ),
        ),
        const SizedBox(height: 18),
        Text(tr('sms_verification'), style: SyncText.largeTitle, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text('$fullPhone ${tr('sms_sent_to')}', style: SyncText.secondary, textAlign: TextAlign.center),
        if (_via.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(_sentWhere(_via), style: SyncText.secondary, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 20),
        GlassField(
          controller: _otpController,
          hint: tr('otp_hint'),
          keyboardType: TextInputType.number,
          onChanged: (v) {
            if (v.trim().length == 6) {
              _verifyOtp();
            } else {
              setState(() {});
            }
          },
        ),
        const SizedBox(height: 16),
        GlassButton(
          label: tr('continue_btn'),
          primary: true,
          onTap: _otpController.text.trim().isNotEmpty ? _verifyOtp : null,
        ),
        const SizedBox(height: 14),
        Center(
          child: _countdown > 0
              ? Text(
                  '${tr('resend_in')} $_countdown ${tr('sec')}',
                  style: const TextStyle(fontFamily: syncFont, color: SyncColors.textTertiary, fontSize: 13),
                )
              : TextButton(
                  onPressed: _sendOtp,
                  child: Text(
                    tr('resend_now'),
                    style: const TextStyle(
                      fontFamily: syncFont,
                      color: SyncColors.accentBright,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() => _step = OnboardingStep.phone),
          child: Text('← ${tr('phone_number')}', style: SyncText.secondary),
        ),
      ],
    );
  }

  // --- Step 2: Name, Username, Bio ---
  Widget _buildProfileStep() {
    return Column(
      key: const ValueKey('step_profile'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: CircleAvatar(
            radius: 34,
            backgroundColor: Color(0x338DB9FF),
            child: Icon(Icons.badge_outlined, color: SyncColors.activeTab, size: 36),
          ),
        ),
        const SizedBox(height: 18),
        Text(tr('setup_profile'), style: SyncText.largeTitle, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(tr('profile_subtitle'), style: SyncText.secondary, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        GlassField(controller: _nameController, hint: tr('full_name_hint'), onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        GlassField(
          controller: _usernameController,
          hint: tr('username_hint'),
          prefixText: '@',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        GlassField(controller: _bioController, hint: tr('bio_hint'), maxLines: 2, minLines: 1),
        const SizedBox(height: 20),
        GlassButton(
          label: tr('continue_btn'),
          primary: true,
          onTap: _nameController.text.trim().isNotEmpty && _usernameController.text.trim().isNotEmpty
              ? _submitProfile
              : null,
        ),
      ],
    );
  }

  // --- Step 3: Avatar ---
  Widget _buildAvatarStep() {
    return Column(
      key: const ValueKey('step_avatar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Text(tr('choose_avatar'), style: SyncText.largeTitle, textAlign: TextAlign.center),
        ),
        const SizedBox(height: 8),
        Text(tr('avatar_subtitle'), style: SyncText.secondary, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        // Central Avatar Preview
        Center(
          child: GestureDetector(
            onTap: () => _pickAvatarImage(ImageSource.gallery),
            child: Stack(
              children: [
                Container(
                  width: 104,
                  height: 104,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: _avatarPath == null
                        ? LinearGradient(
                            colors: _presets[_selectedPreset],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    image: _avatarPath != null
                        ? DecorationImage(image: FileImage(File(_avatarPath!)), fit: BoxFit.cover)
                        : null,
                    boxShadow: [
                      BoxShadow(
                        color: _presets[_selectedPreset][0].withValues(alpha: 0.5),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: _avatarPath == null
                      ? Center(
                          child: Text(
                            _nameController.text.isNotEmpty ? _nameController.text[0].toUpperCase() : 'S',
                            style: const TextStyle(
                              fontFamily: syncFont,
                              color: Colors.white,
                              fontSize: 40,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                      : null,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: CircleAvatar(
                    radius: 17,
                    backgroundColor: SyncColors.accentBright,
                    child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          tr('or_preset'),
          style: const TextStyle(fontFamily: syncFont, color: SyncColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        // Presets selector
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(_presets.length, (i) {
            final isSelected = _avatarPath == null && _selectedPreset == i;
            return GestureDetector(
              onTap: () => setState(() {
                _avatarPath = null;
                _selectedPreset = i;
              }),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: _presets[i], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  border: isSelected ? Border.all(color: Colors.white, width: 3) : null,
                  boxShadow: isSelected
                      ? [BoxShadow(color: _presets[i][0].withValues(alpha: 0.6), blurRadius: 10, spreadRadius: 2)]
                      : null,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 28),
        GlassButton(label: tr('continue_btn'), primary: true, onTap: _submitAvatar),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _submitAvatar,
          child: Text(tr('skip'), style: SyncText.secondary),
        ),
      ],
    );
  }

  // --- Step 4: Two-Step Verification 2FA (Skippable cloud password) ---
  Widget _buildTwoFactorStep() {
    return Column(
      key: const ValueKey('step_2fa'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: CircleAvatar(
            radius: 34,
            backgroundColor: Color(0x33FF9F0A),
            child: Icon(Icons.lock_outline_rounded, color: Color(0xFFFF9F0A), size: 36),
          ),
        ),
        const SizedBox(height: 18),
        Text(tr('two_factor_auth'), style: SyncText.largeTitle, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(tr('two_factor_subtitle'), style: SyncText.secondary, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        GlassField(
          controller: _passwordController,
          hint: tr('two_factor_password'),
          obscure: _obscurePassword,
          trailing: IconButton(
            icon: Icon(
              _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: SyncColors.textSecondary,
            ),
            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
          ),
        ),
        const SizedBox(height: 12),
        GlassField(controller: _confirmPasswordController, hint: tr('two_factor_confirm'), obscure: _obscurePassword),
        const SizedBox(height: 12),
        GlassField(controller: _hintController, hint: tr('two_factor_hint')),
        const SizedBox(height: 24),
        GlassButton(label: tr('continue_btn'), primary: true, busy: _busy, onTap: () => _submit2FA(skip: false)),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => _submit2FA(skip: true),
          child: Text(tr('skip'), style: SyncText.secondary),
        ),
      ],
    );
  }

  // --- Step 5: Cryptographic Recovery Key Backup ---
  Widget _buildRecoveryStep() {
    return Column(
      key: const ValueKey('step_recovery'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: CircleAvatar(
            radius: 34,
            backgroundColor: Color(0x3330D158),
            child: Icon(Icons.vpn_key_rounded, color: Color(0xFF30D158), size: 36),
          ),
        ),
        const SizedBox(height: 18),
        Text(tr('recovery_title'), style: SyncText.largeTitle, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(tr('recovery_subtitle'), style: SyncText.secondary, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        // Key Container
        Glass(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                _recoveryKey ?? '…',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: SyncColors.activeTab,
                  fontSize: 13,
                  letterSpacing: 0.8,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              GlassButton(
                label: tr('copy_key'),
                onTap: () {
                  if (_recoveryKey != null) {
                    Clipboard.setData(ClipboardData(text: _recoveryKey!));
                    showToast(context, tr('copied'));
                    setState(() => _recoverySaved = true);
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Confirmation checkbox
        GestureDetector(
          onTap: () => setState(() => _recoverySaved = !_recoverySaved),
          child: Row(
            children: [
              Checkbox(
                value: _recoverySaved,
                activeColor: SyncColors.accentBright,
                onChanged: (v) => setState(() => _recoverySaved = v ?? false),
              ),
              Expanded(
                child: Text(
                  tr('recovery_confirm_checkbox'),
                  style: const TextStyle(fontFamily: syncFont, color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        GlassButton(
          label: tr('start_messaging'),
          primary: true,
          busy: _busy,
          onTap: _recoverySaved ? _finishSetup : null,
        ),
      ],
    );
  }
}
