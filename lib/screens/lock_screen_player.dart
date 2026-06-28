import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:marquee/marquee.dart';
import '../app_assets.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../api/lrclib_api.dart';
import '../services/lock_screen_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LockScreenPlayer
//
// Full-screen player shown OVER the Android lock screen.
//
// Changes vs original:
//  • Play/pause button replaced with _MusicRingButton (blob + orbit animation)
//    — same widget used in now_playing_screen.dart
//  • Lyrics button added next to the like button
//  • Tapping lyrics button flips the card to show synced/plain lyrics
//    (same fetch logic as NowPlayingScreen, just inlined here)
// ─────────────────────────────────────────────────────────────────────────────

class LockScreenPlayer extends StatefulWidget {
  const LockScreenPlayer({super.key});

  @override
  State<LockScreenPlayer> createState() => _LockScreenPlayerState();
}

class _LockScreenPlayerState extends State<LockScreenPlayer>
    with TickerProviderStateMixin {
  // Drag-down-to-dismiss
  double _dragY = 0;
  static const double _kDismissThreshold = 110.0;

  // Slide-up entrance
  late AnimationController _enterCtrl;
  late Animation<Offset> _enterSlide;

  // ── Lyrics state ──────────────────────────────────────────────────────────
  bool _showLyrics = false;
  String? _lyrics;
  String? _lyricsCopyright;
  bool _lyricsLoading = false;
  String? _lyricsForSongId;

  // LRCLIB synced lyrics
  List<LrcLine> _syncedLines = [];
  List<GlobalKey> _lrcLineKeys = [];
  int _activeLrcLine = -1;
  final ScrollController _syncedScrollCtrl = ScrollController();

  // Flip card animation
  late AnimationController _flipCtrl;
  late Animation<double> _flipAnim;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _enterSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOutCubic));
    _enterCtrl.forward();

    _flipCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _flipAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _flipCtrl, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _flipCtrl.dispose();
    _syncedScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    // If the device is still locked, move the app to background instead of
    // revealing the home screen behind the lock screen overlay.
    final stillLocked = await LockScreenService.instance.isDeviceLocked();
    if (!mounted) return;
    if (stillLocked) {
      // Send the app to background — the lock screen overlay stays intact
      // and the OS keyguard is shown to the user instead of the home screen.
      await SystemNavigator.pop(animated: true);
      return;
    }
    _enterCtrl.reverse().then((_) {
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
    });
  }

  // ── Lyrics toggle ─────────────────────────────────────────────────────────
  void _toggleLyrics(AppState app) {
    final song = app.currentSong;
    if (song == null) return;
    if (!_showLyrics) {
      _loadLyrics(app, song);
      _flipCtrl.forward();
    } else {
      _flipCtrl.reverse();
    }
    setState(() => _showLyrics = !_showLyrics);
  }

  Future<void> _loadLyrics(AppState app, song) async {
    if (_lyricsForSongId == song.id) return;
    if (mounted) {
      setState(() {
        _lyricsLoading = true;
        _lyrics = null;
        _lyricsCopyright = null;
        _lyricsForSongId = song.id;
        _syncedLines = [];
        _lrcLineKeys = [];
        _activeLrcLine = -1;
      });
    }

    // ── 0. LRCLIB synced lyrics first ─────────────────────────────────────
    try {
      final matches = await LrcLibApi.searchSmart(
        title: song.title,
        artist: song.artist,
      );
      final usable = matches.where((m) => m.hasSynced || m.hasPlain).toList();
      if (usable.isNotEmpty && mounted) {
        final match = usable.first;
        if (match.hasSynced) {
          _syncedLines = match.parseSynced();
          _lrcLineKeys =
              List.generate(_syncedLines.length, (_) => GlobalKey());
        }
        if (match.hasPlain) _lyrics = match.plainLyrics;
      }
    } catch (_) {
      // LRCLIB unreachable
    }

    // ── 1. JioSaavn fallback if nothing synced yet ────────────────────────
    if (_syncedLines.isEmpty && (_lyrics == null || _lyrics!.isEmpty)) {
      try {
        final data = await app.api.fetchLyrics(song.id);
        final raw = (data['lyrics'] ?? '').toString().trim();
        if (raw.isNotEmpty) {
          _lyrics = raw.replaceAll(RegExp(r'<br\s*/?>',
              caseSensitive: false), '\n');
          _lyricsCopyright = data['lyrics_copyright']?.toString();
        }
      } catch (_) {}

      // ── 2. lyrics.ovh as last resort ─────────────────────────────────
      if (_lyrics == null || _lyrics!.isEmpty) {
        try {
          final artists = song.artist.split(', ');
          for (final artist in artists) {
            final encodedArtist = Uri.encodeComponent(artist.trim());
            final encodedTitle = Uri.encodeComponent(song.title);
            final res = await http
                .get(Uri.parse(
                    'https://api.lyrics.ovh/v1/$encodedArtist/$encodedTitle'))
                .timeout(const Duration(seconds: 8));
            if (res.statusCode == 200) {
              final body = jsonDecode(res.body) as Map<String, dynamic>;
              final raw = (body['lyrics'] ?? '').toString().trim();
              if (raw.isNotEmpty) {
                _lyrics = raw;
                break;
              }
            }
          }
        } catch (_) {}
      }
    }

    if (mounted) setState(() => _lyricsLoading = false);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final song = app.currentSong;

    if (song == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _dismiss());
      return const SizedBox.shrink();
    }

    final dismissFraction = (_dragY / _kDismissThreshold).clamp(0.0, 1.0);

    return SlideTransition(
      position: _enterSlide,
      child: GestureDetector(
        onVerticalDragUpdate: (d) {
          setState(() {
            _dragY = (_dragY + d.delta.dy).clamp(0, _kDismissThreshold * 1.6);
          });
        },
        onVerticalDragEnd: (d) {
          if (_dragY > _kDismissThreshold ||
              (d.primaryVelocity ?? 0) > 500) {
            _dismiss(); // now async — fire and forget is fine
          } else {
            setState(() => _dragY = 0);
          }
        },
        onVerticalDragCancel: () => setState(() => _dragY = 0),
        child: Transform.translate(
          offset: Offset(0, _dragY),
          child: Opacity(
            opacity: (1.0 - dismissFraction * 0.45).clamp(0.0, 1.0),
            child: Scaffold(
              backgroundColor: Colors.black,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  // ── Blurred album art background ─────────────────────
                  _art(song.image, fit: BoxFit.cover),
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.45),
                            Colors.black.withOpacity(0.90),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── Content ──────────────────────────────────────────
                  SafeArea(
                    child: Column(
                      children: [
                        // Drag handle + label
                        const SizedBox(height: 10),
                        Center(
                          child: Container(
                            width: 38,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.28),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.lock_outline_rounded,
                                size: 12,
                                color: Colors.white.withOpacity(0.38)),
                            const SizedBox(width: 5),
                            Text(
                              'NOW PLAYING',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.38),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.8,
                              ),
                            ),
                          ],
                        ),

                        // ── Flip card: album art ↔ lyrics ─────────────
                        Expanded(
                          flex: 5,
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(32, 18, 32, 0),
                            child: Center(
                              child: AnimatedBuilder(
                                animation: _flipAnim,
                                builder: (context, child) {
                                  final t = _flipAnim.value;
                                  // Front (art) visible when t < 0.5
                                  // Back (lyrics) visible when t >= 0.5
                                  final showBack = t >= 0.5;
                                  final angle =
                                      t * 3.14159265358979; // 0 → π
                                  return Transform(
                                    alignment: Alignment.center,
                                    transform: Matrix4.identity()
                                      ..setEntry(3, 2, 0.001)
                                      ..rotateY(angle),
                                    child: showBack
                                        ? Transform(
                                            alignment: Alignment.center,
                                            transform: Matrix4.identity()
                                              ..rotateY(3.14159265358979),
                                            child:
                                                _lyricsCard(app, song),
                                          )
                                        : _albumArtCard(song),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),

                        // ── Title + artist + like + lyrics ────────────
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(28, 24, 12, 0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      height: 30,
                                      child: song.title.length > 22
                                          ? Marquee(
                                              key: ValueKey(song.id),
                                              text: song.title,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w800,
                                                fontSize: 22,
                                              ),
                                              blankSpace: 60,
                                              velocity: 28,
                                              pauseAfterRound:
                                                  const Duration(seconds: 2),
                                            )
                                          : Text(
                                              song.title,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w800,
                                                fontSize: 22,
                                              ),
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                            ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      song.artist,
                                      style: TextStyle(
                                        color:
                                            Colors.white.withOpacity(0.58),
                                        fontSize: 14.5,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              // Like button
                              IconButton(
                                icon: Icon(
                                  app.isLiked(song.id)
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: app.isLiked(song.id)
                                      ? TaarColors.vermilion
                                      : Colors.white.withOpacity(0.60),
                                  size: 24,
                                ),
                                onPressed: () => app.toggleLike(song),
                              ),
                              // Lyrics button
                              IconButton(
                                icon: Icon(
                                  Icons.lyrics_rounded,
                                  color: _showLyrics
                                      ? TaarColors.marigold
                                      : Colors.white.withOpacity(0.55),
                                  size: 24,
                                ),
                                tooltip: _showLyrics
                                    ? 'Hide lyrics'
                                    : 'Show lyrics',
                                onPressed: () => _toggleLyrics(app),
                              ),
                            ],
                          ),
                        ),

                        // ── Seek bar ──────────────────────────────────
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(28, 16, 28, 0),
                          child: StreamBuilder<Duration>(
                            stream: app.player.positionStream,
                            builder: (context, snap) {
                              final pos = snap.data ?? Duration.zero;
                              final dur =
                                  app.player.duration ?? Duration.zero;
                              final maxMs = dur.inMilliseconds
                                  .toDouble()
                                  .clamp(1.0, double.infinity);
                              final posMs = pos.inMilliseconds
                                  .toDouble()
                                  .clamp(0.0, maxMs);
                              return Column(
                                children: [
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 4,
                                      thumbShape:
                                          const RoundSliderThumbShape(
                                              enabledThumbRadius: 7),
                                      activeTrackColor: TaarColors.marigold,
                                      inactiveTrackColor:
                                          Colors.white.withOpacity(0.18),
                                      thumbColor: Colors.white,
                                      overlayColor: TaarColors.marigold
                                          .withOpacity(0.2),
                                    ),
                                    child: Slider(
                                      min: 0,
                                      max: maxMs,
                                      value: posMs,
                                      onChanged: (v) => app.player.seek(
                                          Duration(
                                              milliseconds: v.toInt())),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(_fmt(pos),
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.white
                                                    .withOpacity(0.48))),
                                        Text(_fmt(dur),
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.white
                                                    .withOpacity(0.48))),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),

                        // ── Controls ──────────────────────────────────
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceEvenly,
                            children: [
                              // Shuffle / repeat toggle
                              IconButton(
                                icon: Icon(
                                  app.isShuffled
                                      ? Icons.shuffle
                                      : app.repeatMode ==
                                              TaarRepeatMode.one
                                          ? Icons.repeat_one
                                          : Icons.repeat,
                                  color: (app.isShuffled ||
                                          app.repeatMode !=
                                              TaarRepeatMode.off)
                                      ? TaarColors.jadeBright
                                      : Colors.white.withOpacity(0.45),
                                  size: 24,
                                ),
                                onPressed: () {
                                  if (!app.isShuffled &&
                                      app.repeatMode ==
                                          TaarRepeatMode.off) {
                                    app.toggleShuffle();
                                  } else if (app.isShuffled) {
                                    app.toggleShuffle();
                                    if (app.repeatMode ==
                                        TaarRepeatMode.off) {
                                      app.cycleRepeat();
                                    }
                                  } else {
                                    app.cycleRepeat();
                                  }
                                },
                              ),
                              // Previous
                              IconButton(
                                icon: Icon(Icons.skip_previous_rounded,
                                    color: Colors.white.withOpacity(0.88),
                                    size: 44),
                                onPressed: app.prevSong,
                              ),
                              // Play / pause — animated music ring button
                              _MusicRingButton(
                                isPlaying: app.player.playing,
                                isLoading: app.isLoadingTrack,
                                onTap: app.togglePlayPause,
                              ),
                              // Next
                              IconButton(
                                icon: Icon(Icons.skip_next_rounded,
                                    color: Colors.white.withOpacity(0.88),
                                    size: 44),
                                onPressed: app.nextSong,
                              ),
                              // Close overlay
                              IconButton(
                                icon: Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.white.withOpacity(0.50),
                                    size: 28),
                                onPressed: _dismiss,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Album art card (flip front) ──────────────────────────────────────────
  Widget _albumArtCard(song) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.93, end: 1.0).animate(anim),
          child: child,
        ),
      ),
      child: Container(
        key: ValueKey(song.id),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: TaarColors.marigold.withOpacity(0.32),
              blurRadius: 55,
              spreadRadius: 8,
              offset: const Offset(0, 16),
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.55),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: AspectRatio(
            aspectRatio: 1,
            child: _art(song.image, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }

  // ── Lyrics card (flip back) ───────────────────────────────────────────────
  Widget _lyricsCard(AppState app, song) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: Colors.black.withOpacity(0.55),
            border: Border.all(
              color: TaarColors.marigold.withOpacity(0.22),
              width: 1.2,
            ),
          ),
          child: _lyricsContent(app, song),
        ),
      ),
    );
  }

  Widget _lyricsContent(AppState app, song) {
    if (_lyricsLoading) {
      return const Center(
        child: CircularProgressIndicator(
            color: TaarColors.marigold, strokeWidth: 2.5),
      );
    }
    final hasSynced = _syncedLines.isNotEmpty;
    if (!hasSynced && (_lyrics == null || _lyrics!.isEmpty)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lyrics_outlined,
                  color: Colors.white.withOpacity(0.3), size: 32),
              const SizedBox(height: 12),
              Text(
                'Lyrics not available',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.45), fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    if (hasSynced) {
      return _syncedLyricsView(app);
    }
    // Plain text
    return Scrollbar(
      thumbVisibility: true,
      radius: const Radius.circular(4),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              _lyrics!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.85),
            ),
            if (_lyricsCopyright != null &&
                _lyricsCopyright!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(color: Colors.white.withOpacity(0.1)),
              const SizedBox(height: 6),
              Text(
                _lyricsCopyright!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 9.5, color: Colors.white.withOpacity(0.25)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _syncedLyricsView(AppState app) {
    return StreamBuilder<Duration>(
      stream: app.player.positionStream,
      builder: (context, snap) {
        final pos = snap.data ?? app.player.position;
        int idx = -1;
        for (var i = 0; i < _syncedLines.length; i++) {
          if (_syncedLines[i].time <= pos) {
            idx = i;
          } else {
            break;
          }
        }
        if (idx != _activeLrcLine) {
          _activeLrcLine = idx;
          if (idx >= 0 && idx < _lrcLineKeys.length) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final lineCtx = _lrcLineKeys[idx].currentContext;
              if (lineCtx != null) {
                Scrollable.ensureVisible(
                  lineCtx,
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOutCubic,
                  alignment: 0.42,
                );
              }
            });
          }
        }
        return ListView.builder(
          controller: _syncedScrollCtrl,
          padding: const EdgeInsets.symmetric(vertical: 50, horizontal: 16),
          itemCount: _syncedLines.length,
          itemBuilder: (context, i) {
            final line = _syncedLines[i];
            final active = i == idx;
            return Container(
              key: _lrcLineKeys[i],
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 220),
                style: TextStyle(
                  color: active
                      ? TaarColors.marigold
                      : Colors.white.withOpacity(0.40),
                  fontSize: active ? 15.5 : 13.5,
                  fontWeight:
                      active ? FontWeight.w800 : FontWeight.w500,
                  height: 1.5,
                ),
                child: Text(
                  line.text.isEmpty ? '•' : line.text,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _MusicRingButton — Liquid Soundwave Play Button (same as now_playing_screen)
//
// 12 radial soundwave bars shoot outward from the button rim.
// A morphing blob breathes behind the button.
// On pause, bars collapse and blob deflates.
// ─────────────────────────────────────────────────────────────────────────────
class _MusicRingButton extends StatefulWidget {
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onTap;

  const _MusicRingButton({
    required this.isPlaying,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_MusicRingButton> createState() => _MusicRingButtonState();
}

class _MusicRingButtonState extends State<_MusicRingButton>
    with TickerProviderStateMixin {
  late AnimationController _clock;
  late AnimationController _blob;
  late AnimationController _tap;
  late Animation<double> _tapScale;
  late AnimationController _fade;

  @override
  void initState() {
    super.initState();

    _clock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 100),
    );

    _blob = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );

    _tap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _tapScale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.86)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 35),
      TweenSequenceItem(
          tween: Tween(begin: 0.86, end: 1.08)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 40),
      TweenSequenceItem(
          tween: Tween(begin: 1.08, end: 1.0)
              .chain(CurveTween(curve: Curves.elasticOut)),
          weight: 25),
    ]).animate(_tap);

    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    if (widget.isPlaying) _startAll();
  }

  void _startAll() {
    _clock.repeat();
    _blob.repeat(reverse: true);
    _fade.forward();
  }

  void _stopAll() {
    _clock.stop();
    _blob.stop();
    _blob.animateTo(0, duration: const Duration(milliseconds: 600));
    _fade.reverse();
  }

  @override
  void didUpdateWidget(_MusicRingButton old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying != old.isPlaying) {
      widget.isPlaying ? _startAll() : _stopAll();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    _blob.dispose();
    _tap.dispose();
    _fade.dispose();
    super.dispose();
  }

  void _handleTap() {
    _tap.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: Listenable.merge([_clock, _blob, _tapScale, _fade]),
        builder: (context, _) {
          return ScaleTransition(
            scale: _tapScale,
            child: SizedBox(
              width: 130,
              height: 130,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // ── Morphing blob glow ────────────────────────────
                  Opacity(
                    opacity: _fade.value,
                    child: CustomPaint(
                      size: const Size(130, 130),
                      painter: _BlobPainter(
                        phase: _blob.value,
                        color: TaarColors.marigold,
                      ),
                    ),
                  ),

                  // ── Orbiting particles ────────────────────────────
                  Opacity(
                    opacity: _fade.value,
                    child: CustomPaint(
                      size: const Size(130, 130),
                      painter: _OrbitParticlesPainter(
                        timeValue: _clock.value * 100,
                        color: TaarColors.marigold,
                      ),
                    ),
                  ),

                  // ── Glass core ────────────────────────────────────
                  ClipOval(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: widget.isPlaying
                                ? [
                                    TaarColors.marigold.withOpacity(0.55),
                                    TaarColors.marigold.withOpacity(0.18),
                                  ]
                                : [
                                    Colors.white.withOpacity(0.18),
                                    Colors.white.withOpacity(0.05),
                                  ],
                          ),
                          border: Border.all(
                            color: widget.isPlaying
                                ? TaarColors.marigold.withOpacity(0.80)
                                : Colors.white.withOpacity(0.28),
                            width: 1.6,
                          ),
                        ),
                        child: Center(
                          child: widget.isLoading
                              ? const SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2.5),
                                )
                              : AnimatedSwitcher(
                                  duration:
                                      const Duration(milliseconds: 200),
                                  transitionBuilder: (child, anim) =>
                                      ScaleTransition(
                                          scale: anim, child: child),
                                  child: Icon(
                                    widget.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    key: ValueKey(widget.isPlaying),
                                    color: Colors.white,
                                    size: 34,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Orbiting particles painter ────────────────────────────────────────────────
class _OrbitParticlesPainter extends CustomPainter {
  final double timeValue;
  final Color color;

  const _OrbitParticlesPainter({
    required this.timeValue,
    required this.color,
  });

  static const List<List<double>> _rings = [
    [46.0, 0.90, 5, 3.4, 0.00, 0.00],
    [57.0, 0.55, 7, 2.4, 0.38, 0.30],
    [66.0, 0.35, 9, 1.7, -0.28, 0.62],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const twoPi = 3.14159265358979 * 2;
    const trailSteps = 4;
    const trailAngleStep = 0.09;

    for (final ring in _rings) {
      final ringR = ring[0];
      final speed = ring[1];
      final count = ring[2].toInt();
      final baseRad = ring[3];
      final tilt = ring[4];
      final phase = ring[5];
      final cosTilt = _cos(tilt);

      for (int i = 0; i < count; i++) {
        final baseAngle =
            (i / count) * twoPi + timeValue * speed * twoPi + phase;
        final ex = _cos(baseAngle) * ringR;
        final ey = _sin(baseAngle) * ringR * cosTilt;
        final depth = _sin(baseAngle) * 0.5 + 0.5;
        final dotR = baseRad * (0.45 + depth * 0.55);
        final opacity = 0.25 + depth * 0.75;
        _drawDot(canvas, cx + ex, cy + ey, dotR, opacity);

        for (int tr = 1; tr <= trailSteps; tr++) {
          final ta = baseAngle - tr * trailAngleStep;
          final tex = _cos(ta) * ringR;
          final tey = _sin(ta) * ringR * cosTilt;
          final tDepth = _sin(ta) * 0.5 + 0.5;
          final tDotR = baseRad * (0.45 + tDepth * 0.55) * (1.0 - tr * 0.18);
          final tOpacity = opacity * (1.0 - tr * 0.22);
          if (tDotR > 0.3) {
            _drawDot(canvas, cx + tex, cy + tey, tDotR, tOpacity * 0.55);
          }
        }
      }
    }
  }

  void _drawDot(Canvas canvas, double x, double y, double r, double opacity) {
    final paint = Paint()
      ..color = color.withOpacity(opacity.clamp(0.0, 1.0))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(x, y), r, paint);
  }

  static double _cos(double a) {
    const pi2 = 3.14159265358979 * 2;
    a = a % pi2;
    double r = 1, t = 1;
    for (int n = 1; n <= 12; n++) {
      t *= -a * a / ((2 * n - 1) * (2 * n));
      r += t;
    }
    return r;
  }

  static double _sin(double a) {
    const pi2 = 3.14159265358979 * 2;
    a = a % pi2;
    double r = a, t = a;
    for (int n = 1; n <= 12; n++) {
      t *= -a * a / ((2 * n) * (2 * n + 1));
      r += t;
    }
    return r;
  }

  @override
  bool shouldRepaint(_OrbitParticlesPainter old) =>
      old.timeValue != timeValue || old.color != color;
}

// ── Morphing blob painter ─────────────────────────────────────────────────────
class _BlobPainter extends CustomPainter {
  final double phase;
  final Color color;

  const _BlobPainter({required this.phase, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const twoPi = 3.14159265358979 * 2;
    const baseR = 52.0;
    const morphAmp = 7.0;
    const pointCount = 6;

    final pts = <Offset>[];
    for (int i = 0; i < pointCount; i++) {
      final angle = (i / pointCount) * twoPi;
      final r = baseR + _sin((phase + i * 0.16) * twoPi) * morphAmp;
      pts.add(Offset(cx + _cos(angle) * r, cy + _sin(angle) * r));
    }

    final path = Path();
    final n = pts.length;
    for (int i = 0; i < n; i++) {
      final curr = pts[i];
      final next = pts[(i + 1) % n];
      final prev = pts[(i - 1 + n) % n];
      final nn = pts[(i + 2) % n];
      final c1 = Offset(
        curr.dx + (next.dx - prev.dx) * 0.18,
        curr.dy + (next.dy - prev.dy) * 0.18,
      );
      final c2 = Offset(
        next.dx - (nn.dx - curr.dx) * 0.18,
        next.dy - (nn.dy - curr.dy) * 0.18,
      );
      if (i == 0) path.moveTo(curr.dx, curr.dy);
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, next.dx, next.dy);
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withOpacity(0.07)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withOpacity(0.11)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withOpacity(0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  static double _cos(double a) {
    const pi2 = 3.14159265358979 * 2;
    a = a % pi2;
    double r = 1, t = 1;
    for (int n = 1; n <= 12; n++) {
      t *= -a * a / ((2 * n - 1) * (2 * n));
      r += t;
    }
    return r;
  }

  static double _sin(double a) {
    const pi2 = 3.14159265358979 * 2;
    a = a % pi2;
    double r = a, t = a;
    for (int n = 1; n <= 12; n++) {
      t *= -a * a / ((2 * n) * (2 * n + 1));
      r += t;
    }
    return r;
  }

  @override
  bool shouldRepaint(_BlobPainter old) =>
      old.phase != phase || old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared image helper
// ─────────────────────────────────────────────────────────────────────────────
Widget _art(String url,
    {double? width, double? height, BoxFit fit = BoxFit.cover}) {
  Widget ph() => Image.asset(AppAssets.placeholderCover,
      fit: fit, width: width, height: height);
  if (url.isEmpty) return ph();
  if (url.startsWith('/') || url.startsWith('file://')) {
    final path = url.replaceFirst('file://', '');
    return Image.file(File(path),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, __, ___) => ph());
  }
  return CachedNetworkImage(
    imageUrl: url,
    width: width,
    height: height,
    fit: fit,
    errorWidget: (_, __, ___) => ph(),
  );
}