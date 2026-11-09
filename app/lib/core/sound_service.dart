import 'package:audioplayers/audioplayers.dart';

/// Manages all sound effects: ringtones, message sounds, notifications.
/// Uses audioplayers package (already in pubspec).
class SoundService {
  SoundService._();
  static final SoundService instance = SoundService._();

  final AudioPlayer _ringtonePlayer = AudioPlayer();
  final AudioPlayer _effectPlayer = AudioPlayer();
  bool _muted = false;

  Future<void> init() async {
    await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
    await _effectPlayer.setReleaseMode(ReleaseMode.release);
  }

  void setMuted(bool v) => _muted = v;

  /// Incoming call ringtone (looped)
  Future<void> playRingtone() async {
    if (_muted) return;
    await _ringtonePlayer.stop();
    await _ringtonePlayer.play(AssetSource('sounds/ringtone.mp3'));
  }

  /// Outgoing call dial tone (looped)
  Future<void> playOutgoingRing() async {
    if (_muted) return;
    await _ringtonePlayer.stop();
    await _ringtonePlayer.play(AssetSource('sounds/outgoing_ring.mp3'));
  }

  /// Stop any ringtone
  Future<void> stopRingtone() async {
    await _ringtonePlayer.stop();
  }

  /// Call connected chime
  Future<void> playCallConnect() async {
    if (_muted) return;
    await _effectPlayer.play(AssetSource('sounds/call_connect.mp3'));
  }

  /// Call ended / hung up sound
  Future<void> playCallEnd() async {
    if (_muted) return;
    await _effectPlayer.play(AssetSource('sounds/call_end.mp3'));
  }

  /// Message sent whoosh
  Future<void> playMessageSent() async {
    if (_muted) return;
    await _effectPlayer.play(AssetSource('sounds/message_sent.mp3'));
  }

  /// Incoming message pop
  Future<void> playMessageReceived() async {
    if (_muted) return;
    await _effectPlayer.play(AssetSource('sounds/message_received.mp3'));
  }

  /// Push / local notification ping
  Future<void> playNotification() async {
    if (_muted) return;
    await _effectPlayer.play(AssetSource('sounds/notification.mp3'));
  }

  void dispose() {
    _ringtonePlayer.dispose();
    _effectPlayer.dispose();
  }
}
