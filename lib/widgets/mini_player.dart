import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:marquee/marquee.dart';
import '../app_assets.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../screens/now_playing_screen.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with TickerProviderStateMixin {
  // ── Song-change slide/fade ─────────────────────────────────
  int _slideDirection = 1;
  String? _prevSongId;

  // Drag tracking for real-time rubber-band feedback
  double _dragOffset = 0;
  static const double _kDragThreshold = 60.0;

  late AnimationController _ctrl;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;

  // ── First-appearance entrance animation ───────────────────
  late AnimationController _entranceCtrl;
  late Animation<double> _entranceScale;
  late Animation<double> _entranceFade;

  bool _hasAppeared = false; // track if mini player has shown before

  @override
  void initState() {
    super.initState();

    // Song-change controller — start at 1.0 (completed) so the FIRST
    // song is immediately visible at full opacity with no offset.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: 1.0, // ← KEY FIX: start complete so first song is visible
    );
    _buildSwipeAnims();

    // Entrance controller — plays once when the mini player first appears
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _entranceScale = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOutBack),
    );
    _entranceFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOut),
    );
  }

  void _buildSwipeAnims() {
    _slideAnim = Tween<Offset>(
      begin: Offset(_slideDirection.toDouble(), 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  void _triggerSwipeAnim(int direction) {
    _slideDirection = direction;
    _buildSwipeAnims();
    _ctrl.forward(from: 0);
  }

  void _openNowPlaying(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 400),
        reverseTransitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (_, __, ___) => const NowPlayingScreen(),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
                  .animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _entranceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final song = app.currentSong;
    if (song == null) return const SizedBox.shrink();

    // ── Entrance animation (first time mini player appears) ──
    if (!_hasAppeared) {
      _hasAppeared = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceCtrl.forward();
      });
    }

    // ── Song-change animation (second song onwards) ──────────
    if (_prevSongId != null && _prevSongId != song.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _triggerSwipeAnim(_slideDirection);
      });
    }
    _prevSongId = song.id;

    return AnimatedBuilder(
      animation: _entranceCtrl,
      builder: (context, child) {
        // Only apply entrance transform while it's running
        final entranceDone = _entranceCtrl.isCompleted;
        return Transform.scale(
          scale: entranceDone ? 1.0 : _entranceScale.value,
          child: Opacity(
            opacity: entranceDone ? 1.0 : _entranceFade.value,
            child: child,
          ),
        );
      },
      child: GestureDetector(
        onTap: () => _openNowPlaying(context),
        onVerticalDragEnd: (details) {
          // Swipe up (negative velocity) → open now playing screen
          if ((details.primaryVelocity ?? 0) < -200) {
            _openNowPlaying(context);
          }
        },
        onHorizontalDragUpdate: (details) {
          setState(() {
            _dragOffset += details.delta.dx;
            _dragOffset = _dragOffset.clamp(
                -_kDragThreshold * 1.4, _kDragThreshold * 1.4);
          });
        },
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          final triggered =
              _dragOffset.abs() > _kDragThreshold || velocity.abs() > 250;

          if (triggered) {
            if (_dragOffset < 0 || velocity < -250) {
              setState(() {
                _slideDirection = 1;
                _dragOffset = 0;
              });
              app.nextSong();
            } else {
              setState(() {
                _slideDirection = -1;
                _dragOffset = 0;
              });
              app.prevSong();
            }
          } else {
            setState(() => _dragOffset = 0);
          }
        },
        onHorizontalDragCancel: () => setState(() => _dragOffset = 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              height: 68,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withOpacity(0.14),
                    TaarColors.marigold.withOpacity(0.08),
                  ],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                    color: Colors.white.withOpacity(0.16), width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.4),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        // ── Album art + song info slide together ──────
                        Expanded(
                          child: Transform.translate(
                            offset: Offset(_dragOffset * 0.35, 0),
                            child: SlideTransition(
                              position: _slideAnim,
                              child: FadeTransition(
                                opacity: _fadeAnim,
                                child: Row(
                                  children: [
                                    // Art — Hero source
                                    Hero(
                                      tag: 'album_art_hero',
                                      flightShuttleBuilder: (_, anim, direction, ___, ____) {
                                        final forward = direction == HeroFlightDirection.push;
                                        return AnimatedBuilder(
                                          animation: anim,
                                          builder: (_, __) {
                                            final t = forward ? anim.value : 1 - anim.value;
                                            final radius = Tween<double>(begin: 10, end: 22).transform(t);
                                            return ClipRRect(
                                              borderRadius: BorderRadius.circular(radius),
                                              child: _miniArt(song.image),
                                            );
                                          },
                                        );
                                      },
                                      child: AnimatedSwitcher(
                                        duration:
                                            const Duration(milliseconds: 300),
                                        switchInCurve: Curves.easeOutCubic,
                                        switchOutCurve: Curves.easeInCubic,
                                        transitionBuilder: (child, anim) =>
                                            FadeTransition(
                                                opacity: anim, child: child),
                                        child: ClipRRect(
                                          key: ValueKey(song.image),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          child: _miniArt(song.image),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    // Title + artist
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          SizedBox(
                                            height: 17,
                                            child: song.title.length > 26
                                                ? Marquee(
                                                    text: song.title,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 13.5,
                                                        color: Colors.white),
                                                    blankSpace: 40,
                                                    velocity: 18,
                                                    pauseAfterRound:
                                                        const Duration(
                                                            seconds: 2),
                                                  )
                                                : Text(
                                                    song.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 13.5,
                                                        color: Colors.white),
                                                  ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            song.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 11.5,
                                                color: Colors.white
                                                    .withOpacity(0.6)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // ── Controls ──────────────────────────────────
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 36, minHeight: 36),
                          icon: Icon(
                              app.isLiked(song.id)
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 20,
                              color: app.isLiked(song.id)
                                  ? TaarColors.vermilion
                                  : Colors.white.withOpacity(0.7)),
                          onPressed: () => app.toggleLike(song),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 36, minHeight: 36),
                          icon: app.isLoadingTrack
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: TaarColors.marigold),
                                )
                              : AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  transitionBuilder: (child, anim) =>
                                      ScaleTransition(
                                          scale: anim, child: child),
                                  child: Icon(
                                    app.player.playing
                                        ? Icons.pause_circle_filled
                                        : Icons.play_circle_fill,
                                    key: ValueKey(app.player.playing),
                                    size: 32,
                                    color: Colors.white,
                                  ),
                                ),
                          onPressed: app.togglePlayPause,
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 36, minHeight: 36),
                          icon: Icon(Icons.skip_next_rounded,
                              size: 26,
                              color: Colors.white.withOpacity(0.85)),
                          onPressed: () {
                            setState(() => _slideDirection = 1);
                            app.nextSong();
                          },
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  // Progress bar
                  StreamBuilder<Duration>(
                    stream: app.player.positionStream,
                    builder: (context, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final dur =
                          app.player.duration ?? const Duration(seconds: 1);
                      final progress = dur.inMilliseconds == 0
                          ? 0.0
                          : pos.inMilliseconds / dur.inMilliseconds;
                      return TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                            begin: 0, end: progress.clamp(0.0, 1.0)),
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                        builder: (context, value, _) =>
                            LinearProgressIndicator(
                          value: value,
                          minHeight: 2,
                          backgroundColor: Colors.white.withOpacity(0.12),
                          valueColor: const AlwaysStoppedAnimation(
                              TaarColors.marigold),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _miniArt(String imageUrl) {
  if (imageUrl.isEmpty) {
    return Image.asset(AppAssets.placeholderCover, width: 46, height: 46, fit: BoxFit.cover);
  }
  if (imageUrl.startsWith('/') || imageUrl.startsWith('file://')) {
    final path = imageUrl.replaceFirst('file://', '');
    return Image.file(File(path), width: 46, height: 46, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            Image.asset(AppAssets.placeholderCover, width: 46, height: 46, fit: BoxFit.cover));
  }
  return CachedNetworkImage(
    imageUrl: imageUrl, width: 46, height: 46, fit: BoxFit.cover,
    errorWidget: (_, __, ___) =>
        Image.asset(AppAssets.placeholderCover, width: 46, height: 46, fit: BoxFit.cover),
  );
}
