import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../screens/lock_screen_player.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LockScreenService
//
// The CORRECT approach for showing a full-screen player over the Android
// lock screen:
//
//  1. Native MainActivity always has FLAG_SHOW_WHEN_LOCKED set, so whenever
//     the Activity is in the foreground (brought up by a notification tap or
//     screen-on broadcast), it renders over the keyguard automatically.
//
//  2. An EventChannel streams the current keyguard state (locked/unlocked)
//     to Flutter. We listen here and push/pop the LockScreenPlayer route.
//
//  3. A MethodChannel lets us ask native "is the screen currently locked?"
//     on demand (used when the app resumes from background).
//
//  4. Flutter never tries to "push" itself onto the lock screen from a
//     background state — the OS handles that via the FLAG_SHOW_WHEN_LOCKED
//     Activity attribute combined with the screen-on BroadcastReceiver in
//     native code.
// ─────────────────────────────────────────────────────────────────────────────

class LockScreenService {
  LockScreenService._();
  static final LockScreenService instance = LockScreenService._();

  static const MethodChannel _method =
      MethodChannel('com.example.taar/lock_screen');
  static const EventChannel _events =
      EventChannel('com.example.taar/lock_screen_events');

  bool _overlayShowing = false;
  bool get overlayShowing => _overlayShowing;

  /// Start listening to keyguard state changes from native.
  /// Call once from main.dart after runApp().
  void init(GlobalKey<NavigatorState> navKey) {
    _events.receiveBroadcastStream().listen((dynamic event) {
      final isLocked = event == true;
      final ctx = navKey.currentContext;
      if (ctx == null) return;

      if (isLocked) {
        _showOverlay(ctx);
      } else {
        _hideOverlay(ctx);
      }
    });
  }

  /// Ask native whether the device is currently locked.
  Future<bool> isDeviceLocked() async {
    try {
      final result = await _method.invokeMethod<bool>('isLocked');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Tell native code whether a song is currently playing. The process-level
  /// screen receiver in TaarApplication uses this flag to decide whether to
  /// pop the lock screen player when the screen turns back on — call this
  /// every time play/pause state changes (see app_state.dart).
  Future<void> setPlaybackActive(bool active) async {
    try {
      await _method.invokeMethod('setPlaybackActive', {'active': active});
    } on PlatformException {
      // Non-fatal — worst case the lock screen takeover just won't fire.
    }
  }

  /// On Android 14+, the full-screen-intent notification that wakes the
  /// custom lock screen player needs a permission that can only be granted
  /// from Settings — there's no in-app runtime dialog for it. Call this once
  /// (e.g. from onboarding or a settings toggle) to check/prompt.
  Future<bool> hasFullScreenIntentPermission() async {
    try {
      final result = await _method.invokeMethod<bool>('canUseFullScreenIntent');
      return result ?? true;
    } on PlatformException {
      return true;
    }
  }

  Future<void> openFullScreenIntentSettings() async {
    try {
      await _method.invokeMethod('requestFullScreenIntentPermission');
    } on PlatformException {
      // ignore
    }
  }

  /// Called when the app comes to foreground — show overlay if locked.
  Future<void> onAppResume(BuildContext context) async {
    final locked = await isDeviceLocked();
    if (locked) {
      _showOverlay(context);
    } else {
      _hideOverlay(context);
    }
  }

  void _showOverlay(BuildContext context) {
    if (_overlayShowing) return;
    _overlayShowing = true;
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => const LockScreenPlayer(),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    ).then((_) {
      _overlayShowing = false;
    });
  }

  void _hideOverlay(BuildContext context) {
    if (!_overlayShowing) return;
    Navigator.of(context, rootNavigator: true).maybePop();
    // _overlayShowing is reset in the .then() above
  }
}
