import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';
import 'app_assets.dart';
import 'state/app_state.dart';
import 'services/speed_dial_service.dart';
import 'services/local_music_service.dart';
import 'services/lock_screen_service.dart';
import 'theme.dart';
import 'screens/root_shell.dart';
import 'screens/onboarding_screen.dart';

/// Global navigator key — used by LockScreenService to push the lock-screen
/// overlay from outside the widget tree (e.g. from native EventChannel events).
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid || Platform.isIOS) {
    try {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'com.taar.app.channel.audio',
        androidNotificationChannelName: 'Taar Music',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
        preloadArtwork: true,
      );
    } catch (e) {
      debugPrint('JustAudioBackground.init failed (no media notification): $e');
    }
  }

  // Start listening to native keyguard events so the overlay can be
  // pushed/popped whenever the screen locks or unlocks during playback.
  if (Platform.isAndroid) {
    LockScreenService.instance.init(navigatorKey);
  }

  final appState = AppState();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: appState),
        ChangeNotifierProvider<SpeedDialService>.value(
            value: appState.speedDial),
        ChangeNotifierProvider<LocalMusicService>.value(
            value: appState.localMusic),
      ],
      child: const TaarApp(),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Root app widget
// ─────────────────────────────────────────────────────────────────────────────
class TaarApp extends StatelessWidget {
  const TaarApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Taar',
      debugShowCheckedModeBanner: false,
      theme: app.themeMode == 'light' ? TaarTheme.light() : TaarTheme.dark(),
      home: !app.restored
          ? const _SplashScreen()
          : (app.username.isEmpty
              ? const OnboardingScreen()
              : const _AppInit()),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Splash — shown only while SharedPreferences restores
// ─────────────────────────────────────────────────────────────────────────────
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TaarColors.ink,
      body: Center(
        child: Image.asset(AppAssets.logoWhite, width: 64, height: 64),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Post-splash initializer — requests permissions and handles lock screen
// on resume.
// ─────────────────────────────────────────────────────────────────────────────
class _AppInit extends StatefulWidget {
  const _AppInit();

  @override
  State<_AppInit> createState() => _AppInitState();
}

class _AppInitState extends State<_AppInit> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestNotificationPermission();
      _requestFullScreenIntentPermissionIfNeeded();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // When the app is resumed (e.g. user taps the media notification on the
  // lock screen), check if the device is still locked and show overlay.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      final app = context.read<AppState>();
      if (app.player.playing) {
        LockScreenService.instance.onAppResume(context);
      }
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
  }

  // Android 14+ only: the custom full-screen lock player needs this special
  // permission, which has no in-app dialog — only Settings. We check once on
  // startup and, if missing, send the user straight to the right screen.
  // (Below Android 14 this is a no-op — the permission is granted at
  // install time via the USE_FULL_SCREEN_INTENT manifest entry.)
  Future<void> _requestFullScreenIntentPermissionIfNeeded() async {
    if (!Platform.isAndroid) return;
    try {
      final granted =
          await LockScreenService.instance.hasFullScreenIntentPermission();
      if (!granted) {
        await LockScreenService.instance.openFullScreenIntentSettings();
      }
    } catch (e) {
      debugPrint('Full-screen intent permission check failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => const RootShell();
}