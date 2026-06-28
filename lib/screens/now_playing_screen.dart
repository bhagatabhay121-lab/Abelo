import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:marquee/marquee.dart';
import '../app_assets.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../models/song.dart';
import '../widgets/glass_widget.dart';
import '../screens/artist_screen.dart';
import '../screens/album_playlist_screen.dart';
import '../widgets/playlist_picker.dart';
import '../api/saavn_api.dart';
import '../api/lrclib_api.dart';
import '../services/youtube_service.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

Widget _sheetHandle() => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.25),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );

class _NowPlayingScreenState extends State<NowPlayingScreen>
    with TickerProviderStateMixin {
  // ── Swipe-down-to-dismiss ───────────────────────────────────────────────────
  double _dismissDragY = 0;
  static const double _kDismissThreshold = 120.0;

  // ── Flip animation ─────────────────────────────────────────────────────────
  late AnimationController _flipCtrl;
  late Animation<double> _flipAnim;
  bool _showLyrics = false;

  // ── Song title slide animation ──────────────────────────────────────────────
  String? _animatedSongId;

  // ── YouTube Audio/Video tab ─────────────────────────────────────────────────
  // true = video mode, false = audio mode (default)
  bool _ytVideoMode = false;
  // Cached video stream URL so we don't re-fetch on every rebuild
  String? _ytVideoUrl;
  String? _ytVideoForSongId;
  bool _ytVideoLoading = false;
  String? _ytVideoError;
  // Controller for the in-player video (uses just_audio's player synced via position)
  // We re-use AppState's audio player for seek/play/pause synchronization and
  // display the video via a native VideoPlayerController layered on top.
  VideoPlayerController? _videoController; // loaded lazily when Video tab is tapped
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  // ── Lyrics state ───────────────────────────────────────────────────────────
  String? _lyrics;
  String? _lyricsCopyright;
  bool _lyricsLoading = false;
  String? _lyricsForSongId;

  // ── LRCLIB synced-lyrics state ─────────────────────────────────────────────
  // A title search on LRCLIB can return many matches (different songs that
  // share a name, reposts of the same song, instrumentals, ...) so we keep
  // them all and let the user pick manually via _showLrcMatchPicker below.
  List<LrcLibResult> _lrcMatches = [];
  LrcLibResult? _selectedLrcMatch;
  List<LrcLine> _syncedLines = [];
  List<GlobalKey> _lrcLineKeys = [];
  int _activeLrcLine = -1;
  final ScrollController _syncedScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _flipCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _flipAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _flipCtrl, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void dispose() {
    _flipCtrl.dispose();
    _syncedScrollCtrl.dispose();
    _disposeVideoController();
    super.dispose();
  }

  void _disposeVideoController() {
    _playingSubscription?.cancel();
    _playingSubscription = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _videoController?.dispose();
    _videoController = null;
  }

  /// Called when the user taps the "Video" tab for a YouTube song.
  /// Fetches the muxed video URL (re-uses cached stream info when possible)
  /// and stores it so the video widget can be built.
  Future<void> _loadYtVideo(Song song) async {
    if (_ytVideoForSongId == song.id && _ytVideoUrl != null) return;
    if (!song.id.startsWith('yt:')) return;

    final app = context.read<AppState>();

    setState(() {
      _ytVideoLoading = true;
      _ytVideoError = null;
      _ytVideoUrl = null;
      _ytVideoForSongId = song.id;
    });
    _disposeVideoController();

    try {
      final videoId = song.id.substring(3);
      final info = await YoutubeStreamService.getStreamInfo(videoId);
      // Prefer a muxed stream (video+audio). Fall back to HLS manifest.
      final url = info.muxed.isNotEmpty
          ? info.muxed.first.url
          : info.hlsManifest;
      if (url == null || url.isEmpty) {
        if (mounted) {
          setState(() {
            _ytVideoLoading = false;
            _ytVideoError = 'No video stream available for this track.';
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _ytVideoUrl = url;
          _ytVideoLoading = false;
        });
        // Initialize the VideoPlayerController inline
        _disposeVideoController();
        final headers = <String, String>{
          'User-Agent': 'com.google.android.youtube/17.31.35 (Linux; U; Android 11)',
        };
        final ctrl = VideoPlayerController.networkUrl(
          Uri.parse(url),
          httpHeaders: headers,
        );
        await ctrl.initialize();
        if (!mounted) { ctrl.dispose(); return; }
        setState(() => _videoController = ctrl);
        // Sync play state with audio player
        if (app.player.playing) {
          ctrl.play();
        }
        // Sync video position to audio player position
        final pos = app.player.position;
        if (pos.inMilliseconds > 500) await ctrl.seekTo(pos);

        // Keep video in sync with audio player going forward
        _playingSubscription?.cancel();
        _playingSubscription = app.player.playingStream.listen((playing) {
          if (!mounted) return;
          final c = _videoController;
          if (c == null || !c.value.isInitialized) return;
          if (playing && !c.value.isPlaying) {
            c.play();
          } else if (!playing && c.value.isPlaying) {
            c.pause();
          }
        });

        _positionSubscription?.cancel();
        _positionSubscription = app.player.positionStream.listen((position) {
          if (!mounted) return;
          final c = _videoController;
          if (c == null || !c.value.isInitialized) return;
          final diff = (c.value.position - position).abs();
          if (diff > const Duration(milliseconds: 800)) {
            c.seekTo(position);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _ytVideoLoading = false;
          _ytVideoError = 'Failed to load video: $e';
        });
      }
    }
  }

  void _switchToVideoMode(Song song) {
    if (_ytVideoMode) return;
    setState(() => _ytVideoMode = true);
    _loadYtVideo(song);
    // Also flip back from lyrics if showing
    if (_showLyrics) {
      setState(() => _showLyrics = false);
      _flipCtrl.reverse();
    }
  }

  void _switchToAudioMode() {
    if (!_ytVideoMode) return;
    setState(() => _ytVideoMode = false);
  }

  /// Shows the YouTube download dialog — asks whether the user wants
  /// Audio only (.m4a) or Video (.mp4).
  void _showYtDownloadDialog(BuildContext context, AppState app, Song song) {
    showGlassBottomSheet(
      context: context,
      builder: (ctx, _) => SafeArea(
        child: Wrap(
          children: [
            _sheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _songArt(song.image, width: 48, height: 48, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15)),
                        const SizedBox(height: 3),
                        Text(song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.55),
                                fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: Colors.white.withOpacity(0.1), height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('Download as',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.1)),
            ),
            const SizedBox(height: 8),
            // Audio option
            Consumer<AppState>(builder: (ctx2, app2, _) {
              final dl = app2.downloadState(song.id);
              final done = dl.status == DownloadStatus.done;
              final downloading = dl.status == DownloadStatus.downloading;
              return ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: TaarColors.marigold.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    done ? Icons.download_done : Icons.audiotrack_rounded,
                    color: done ? TaarColors.jadeBright : TaarColors.marigold,
                    size: 22,
                  ),
                ),
                title: Text(
                  done ? 'Audio Downloaded' : downloading
                      ? 'Downloading Audio… ${(dl.progress * 100).round()}%'
                      : 'Audio Only',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15),
                ),
                subtitle: Text(
                  done ? 'Saved to Music folder' : '.m4a • Audio stream only',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.45), fontSize: 12),
                ),
                trailing: done
                    ? const Icon(Icons.check_circle,
                        color: TaarColors.jadeBright, size: 20)
                    : downloading
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              value: dl.progress,
                              color: TaarColors.marigold,
                              strokeWidth: 2.5,
                            ))
                        : Icon(Icons.chevron_right,
                            color: Colors.white.withOpacity(0.3)),
                onTap: done || downloading
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        app2.downloadSong(song);
                      },
              );
            }),
            // Video option
            Consumer<AppState>(builder: (ctx2, app2, _) {
              final vdl = app2.videoDownloadState(song.id);
              final done = vdl.status == DownloadStatus.done;
              final downloading = vdl.status == DownloadStatus.downloading;
              return ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    done ? Icons.download_done : Icons.videocam_rounded,
                    color: done ? TaarColors.jadeBright : Colors.redAccent,
                    size: 22,
                  ),
                ),
                title: Text(
                  done ? 'Video Downloaded' : downloading
                      ? 'Downloading Video… ${(vdl.progress * 100).round()}%'
                      : 'Video',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15),
                ),
                subtitle: Text(
                  done ? 'Saved to Movies/Taar' : '.mp4 • Video + Audio',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.45), fontSize: 12),
                ),
                trailing: done
                    ? const Icon(Icons.check_circle,
                        color: TaarColors.jadeBright, size: 20)
                    : downloading
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              value: vdl.progress,
                              color: Colors.redAccent,
                              strokeWidth: 2.5,
                            ))
                        : Icon(Icons.chevron_right,
                            color: Colors.white.withOpacity(0.3)),
                onTap: done || downloading
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        app2.downloadYoutubeVideo(song);
                      },
              );
            }),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _loadLyrics(AppState app, Song song) async {
    if (_lyricsForSongId == song.id) return;
    setState(() {
      _lyricsLoading = true;
      _lyrics = null;
      _lyricsCopyright = null;
      _lyricsForSongId = song.id;
      _lrcMatches = [];
      _selectedLrcMatch = null;
      _syncedLines = [];
      _lrcLineKeys = [];
      _activeLrcLine = -1;
    });

    // ── 0. LRCLIB first — the only source that gives time-synced lyrics.
    // Title+artist is tried first (usually a clean single match); if that
    // comes back empty we fall back to a title-only search, which is the
    // broad "many results for one title" search and why a manual picker
    // matters — see _showLrcMatchPicker.
    try {
      final primaryArtist = song.artist.split(',').first.trim();
      final matches = await LrcLibApi.searchSmart(
        title: song.title,
        artist: primaryArtist,
      );
      final usable = matches.where((m) => m.hasSynced || m.hasPlain).toList();
      if (usable.isNotEmpty && mounted) {
        setState(() {
          _lrcMatches = usable;
          _applyLrcMatch(_bestLrcGuess(usable, song.durationSec));
        });
      }
    } catch (_) {
      // LRCLIB unreachable — fall through to JioSaavn/lyrics.ovh below.
    }

    // ── 1+2. Existing JioSaavn → lyrics.ovh fallback, only if LRCLIB had
    // nothing usable for this song.
    if (_syncedLines.isEmpty && (_lyrics == null || _lyrics!.isEmpty)) {
      String? lyricsText;
      String? lyricsCopyright;
      try {
        final data = await app.api.fetchLyrics(song.id);
        final raw = (data['lyrics'] ?? '').toString().trim();
        if (raw.isNotEmpty) {
          lyricsText = raw.replaceAll(
              RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
          lyricsCopyright = data['lyrics_copyright']?.toString();
        }
      } catch (_) {
        // JioSaavn failed — will fall through to lyrics.ovh
      }

      if (lyricsText == null || lyricsText.isEmpty) {
        final artists = song.artist
            .split(',')
            .map((a) => a.trim())
            .where((a) => a.isNotEmpty)
            .toList();

        final encodedTitle = song.title.trim().replaceAll(' ', '%20');

        for (final artist in artists) {
          try {
            final encodedArtist = artist.replaceAll(' ', '%20');
            final url = Uri.parse(
                'https://api.lyrics.ovh/v1/$encodedArtist/$encodedTitle');
            final res =
                await http.get(url).timeout(const Duration(seconds: 10));
            if (res.statusCode == 200) {
              final body = jsonDecode(res.body) as Map<String, dynamic>;
              final raw = (body['lyrics'] ?? '').toString().trim();
              if (raw.isNotEmpty) {
                lyricsText = raw;
                break; // found lyrics — stop checking other artists
              }
            }
          } catch (_) {
            // this artist failed — try the next one
          }
        }
      }

      if (mounted) {
        setState(() {
          _lyrics = lyricsText ?? _lyrics ?? '';
          _lyricsCopyright = lyricsCopyright;
        });
      }
    }

    if (mounted) setState(() => _lyricsLoading = false);
  }

  /// LRCLIB title searches often return several near-duplicate
  /// submissions of the same song (different uploaders, slightly
  /// different durations) — prefer ones that actually carry synced
  /// lyrics, then pick whichever's duration is closest to the track
  /// that's playing. Still just a default: the user can always open
  /// the picker and choose a different match by hand.
  LrcLibResult _bestLrcGuess(List<LrcLibResult> matches, int songDurationSec) {
    final withSynced = matches.where((m) => m.hasSynced).toList();
    final pool = withSynced.isNotEmpty ? withSynced : matches;
    if (songDurationSec <= 0) return pool.first;
    final sorted = [...pool]..sort((a, b) => (a.duration - songDurationSec)
        .abs()
        .compareTo((b.duration - songDurationSec).abs()));
    return sorted.first;
  }

  void _applyLrcMatch(LrcLibResult match) {
    _selectedLrcMatch = match;
    if (match.hasSynced) {
      _syncedLines = match.parseSynced();
      _lrcLineKeys = List.generate(_syncedLines.length, (_) => GlobalKey());
      _activeLrcLine = -1;
      if (match.hasPlain) _lyrics = match.plainLyrics;
    } else {
      _syncedLines = [];
      _lrcLineKeys = [];
      _activeLrcLine = -1;
      if (match.hasPlain) _lyrics = match.plainLyrics;
    }
  }

  /// Lets the user manually pick which LRCLIB result to use — necessary
  /// because a title search can come back with lyrics for several
  /// different songs/artists/album pressings, not just one.
  void _showLrcMatchPicker(BuildContext context, Song song) {
    showGlassBottomSheet(
      context: context,
      isDraggable: true,
      initialSize: 0.5,
      minSize: 0.32,
      maxSize: 0.85,
      builder: (ctx, scrollCtrl) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Row(
              children: [
                const Icon(Icons.lyrics_outlined, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Choose lyrics match',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.white.withOpacity(0.09)),
          Expanded(
            child: ListView.builder(
              controller: scrollCtrl,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: _lrcMatches.length,
              itemBuilder: (_, i) {
                final m = _lrcMatches[i];
                final selected = identical(m, _selectedLrcMatch);
                final subtitleParts = <String>[
                  if (m.artistName.isNotEmpty) m.artistName,
                  if ((m.albumName ?? '').isNotEmpty) m.albumName!,
                  if (m.duration > 0) _fmt(Duration(seconds: m.duration.round())),
                ];
                return ListTile(
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() => _applyLrcMatch(m));
                  },
                  leading: Icon(
                    m.hasSynced ? Icons.graphic_eq_rounded : Icons.notes_rounded,
                    color: selected
                        ? TaarColors.marigold
                        : Colors.white.withOpacity(0.6),
                  ),
                  title: Text(
                    m.trackName.isEmpty ? song.title : m.trackName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: selected ? TaarColors.marigold : Colors.white,
                        fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    subtitleParts.join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.55), fontSize: 12),
                  ),
                  trailing: selected
                      ? const Icon(Icons.check_circle,
                          color: TaarColors.marigold, size: 20)
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _toggleLyricsTab() {
    final app = context.read<AppState>();
    final song = app.currentSong;
    if (!_showLyrics) {
      if (song != null) _loadLyrics(app, song);
      setState(() => _showLyrics = true);
      _flipCtrl.forward();
    } else {
      setState(() => _showLyrics = false);
      _flipCtrl.reverse();
    }
  }

  void _showOverflowMenu(BuildContext context, AppState app, Song song) {
    showGlassMenuDialog(
      context: context,
      title: song.title,
      items: [
        ListTile(
          leading: const Icon(Icons.share_outlined, color: Colors.white),
          title: const Text('Share', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            final shareUrl = song.permaUrl?.isNotEmpty == true
                ? song.permaUrl!
                : 'https://www.jiosaavn.com/song/${song.id}';
            Share.share(shareUrl);
          },
        ),
        ListTile(
          leading: const Icon(Icons.playlist_add, color: Colors.white),
          title: const Text('Add to Playlist', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            showAddToPlaylistSheet(context, song);
          },
        ),
        Consumer<AppState>(
          builder: (ctx2, app2, _) {
            // YouTube songs get a special "Audio or Video?" download dialog
            if (song.id.startsWith('yt:')) {
              final audioDl = app2.downloadState(song.id);
              final videoDl = app2.videoDownloadState(song.id);
              final anyDone = audioDl.status == DownloadStatus.done ||
                  videoDl.status == DownloadStatus.done;
              final anyDownloading =
                  audioDl.status == DownloadStatus.downloading ||
                  videoDl.status == DownloadStatus.downloading;
              return ListTile(
                leading: anyDownloading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: TaarColors.marigold, strokeWidth: 2))
                    : Icon(
                        anyDone
                            ? Icons.download_done
                            : Icons.download_outlined,
                        color: anyDone ? TaarColors.jadeBright : Colors.white,
                      ),
                title: Text(
                  anyDone
                      ? 'Downloaded'
                      : anyDownloading
                          ? 'Downloading…'
                          : 'Download',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: anyDone
                    ? const Text('Tap to download another format',
                        style: TextStyle(
                            color: TaarColors.creamDim, fontSize: 12))
                    : null,
                onTap: anyDownloading
                    ? null
                    : () {
                        Navigator.pop(context);
                        _showYtDownloadDialog(context, app2, song);
                      },
              );
            }

            // Regular (Saavn) songs — original behaviour
            final dl = app2.downloadState(song.id);
            return ListTile(
              leading: dl.status == DownloadStatus.downloading
                  ? SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                        value: dl.progress,
                        color: TaarColors.marigold,
                        strokeWidth: 2,
                      ))
                  : Icon(
                      dl.status == DownloadStatus.done
                          ? Icons.download_done
                          : Icons.download_outlined,
                      color: dl.status == DownloadStatus.done
                          ? TaarColors.jadeBright
                          : Colors.white,
                    ),
              title: Text(
                dl.status == DownloadStatus.done
                    ? 'Downloaded'
                    : dl.status == DownloadStatus.downloading
                        ? 'Downloading... ${(dl.progress * 100).round()}%'
                        : 'Download',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: dl.status == DownloadStatus.done ||
                      dl.status == DownloadStatus.downloading
                  ? null
                  : () {
                      Navigator.pop(context);
                      app2.downloadSong(song);
                    },
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.bedtime_outlined, color: Colors.white),
          title: Text(
            app.sleepTimerEndsAt != null
                ? 'Sleep timer running…'
                : app.sleepAfterNSongs != null
                    ? '${app.sleepAfterNSongs} song${app.sleepAfterNSongs == 1 ? '' : 's'} left…'
                    : 'Sleep Timer',
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: (app.sleepTimerEndsAt != null || app.sleepAfterNSongs != null)
              ? const Text('Tap to cancel', style: TextStyle(color: TaarColors.creamDim))
              : null,
          onTap: () {
            Navigator.pop(context);
            if (app.sleepTimerEndsAt != null || app.sleepAfterNSongs != null) {
              app.cancelSleepTimer();
            } else {
              _showSleepTimerPicker(context, app);
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.album_outlined, color: Colors.white),
          title: const Text('View Album', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _openAlbum(context, app, song);
          },
        ),
        ListTile(
          leading: const Icon(Icons.library_music_outlined, color: Colors.white),
          title: const Text('Related Albums', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _openRelatedAlbums(context, app, song);
          },
        ),
        ListTile(
          leading: const Icon(Icons.person_outline_rounded, color: Colors.white),
          title: const Text('View Artist', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _openArtist(context, song);
          },
        ),
        ListTile(
          leading: const Icon(Icons.queue_music_rounded, color: Colors.white),
          title: const Text('More from this Artist', style: TextStyle(color: Colors.white)),
          subtitle: Text(song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: TaarColors.creamDim, fontSize: 12)),
          onTap: () {
            Navigator.pop(context);
            _playMoreFromArtist(context, app, song);
          },
        ),
        ListTile(
          leading: const Icon(Icons.equalizer_rounded, color: Colors.white),
          title: const Text('Equalizer', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _showEqualizerDialog(context);
          },
        ),
        ListTile(
          leading: const Icon(Icons.info_outline_rounded, color: Colors.white),
          title: const Text('Song Details', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _showSongDetails(context, song);
          },
        ),
      ],
    );
  }

  Future<void> _openAlbum(BuildContext context, AppState app, Song song) async {
    // Try to get album_id from song details API (more_info.album_id)
    String? albumId;
    String albumTitle = song.album ?? song.title;

    try {
      final data = await app.api.fetchSong(song.id);
      final raw = data['songs'] is List
          ? (data['songs'] as List).isNotEmpty
              ? Map<String, dynamic>.from((data['songs'] as List).first)
              : <String, dynamic>{}
          : Map<String, dynamic>.from(data);
      final moreInfo = raw['more_info'] is Map
          ? Map<String, dynamic>.from(raw['more_info'])
          : <String, dynamic>{};
      albumId = (moreInfo['album_id'] ?? raw['album_id'])?.toString();
      albumTitle = (raw['album'] ?? moreInfo['album'] ?? albumTitle).toString();
    } catch (_) {}

    if (albumId == null || albumId.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Album info not available'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AlbumPlaylistScreen(
            id: albumId!,
            type: 'album',
            title: albumTitle,
          ),
        ),
      );
    }
  }

  Future<void> _playMoreFromArtist(BuildContext context, AppState app, Song song) async {
    // Resolve primary artist id from song
    final ids = (song.primaryArtistIds ?? '').split(',');
    final artistId = ids.firstWhere((s) => s.trim().isNotEmpty, orElse: () => '').trim();

    if (artistId.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Artist info not available')),
        );
      }
      return;
    }

    // Show loading snackbar
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
            const SizedBox(width: 14),
            Text('Loading more from ${song.artist}…'),
          ]),
          duration: const Duration(seconds: 10),
          backgroundColor: TaarColors.ink2,
        ),
      );
    }

    try {
      final songs = await app.api.fetchArtistOtherTopSongs(artistId, songId: song.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (songs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No more songs found for ${song.artist}')),
        );
        return;
      }
      // Append to queue after current position so they play next
      for (final s in songs) app.addToQueueEnd(s);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${songs.length} songs by ${song.artist} added to queue'),
          backgroundColor: TaarColors.ink2,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  Future<void> _openRelatedAlbums(BuildContext context, AppState app, Song song) async {
    // Resolve album_id from song details
    String? albumId;
    try {
      final data = await app.api.fetchSong(song.id);
      final raw = data['songs'] is List && (data['songs'] as List).isNotEmpty
          ? Map<String, dynamic>.from((data['songs'] as List).first)
          : Map<String, dynamic>.from(data);
      final moreInfo = raw['more_info'] is Map
          ? Map<String, dynamic>.from(raw['more_info'])
          : <String, dynamic>{};
      albumId = (moreInfo['album_id'] ?? raw['album_id'])?.toString();
    } catch (_) {}

    if (albumId == null || albumId.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Album info not available')),
        );
      }
      return;
    }

    if (!context.mounted) return;
    showGlassBottomSheet(
      context: context,
      isDraggable: true,
      initialSize: 0.55,
      builder: (ctx, sc) => _RelatedAlbumsSheet(
        albumId: albumId!,
        api: app.api,
        scrollController: sc,
      ),
    );
  }

  void _openArtist(BuildContext context, Song song) {
    // primaryArtistIds is comma-separated — take the first one
    final ids = (song.primaryArtistIds ?? '').split(',');
    final artistId = ids.firstWhere((s) => s.trim().isNotEmpty, orElse: () => '').trim();

    if (artistId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Artist info not available'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArtistScreen(artistId: artistId),
      ),
    );
  }

  void _showEqualizerDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.60),
      builder: (ctx) => const _EqualizerDialog(),
    );
  }

  void _showSongDetails(BuildContext context, Song song) {
    String _fmtDuration(int secs) {
      final m = secs ~/ 60;
      final s = secs % 60;
      return '$m:${s.toString().padLeft(2, '0')}';
    }

    showGlassBottomSheet(
      context: context,
      builder: (ctx, _) => SafeArea(
        child: Wrap(
          children: [
            _sheetHandle(),
            // Header: art + title
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _songArt(song.image, width: 64, height: 64, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(song.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15)),
                        const SizedBox(height: 4),
                        Text(song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.55),
                                fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.white.withOpacity(0.08)),
            const SizedBox(height: 8),
            // Detail rows
            _DetailRow(label: 'Album', value: song.album?.isNotEmpty == true ? song.album! : '—'),
            _DetailRow(label: 'Artist', value: song.artist),
            _DetailRow(
              label: 'Duration',
              value: song.durationSec > 0 ? _fmtDuration(song.durationSec) : '—',
            ),
            _DetailRow(
              label: 'Language',
              value: song.language?.isNotEmpty == true
                  ? song.language![0].toUpperCase() + song.language!.substring(1)
                  : '—',
            ),
            _DetailRow(label: 'Song ID', value: song.id, mono: true),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _showSleepTimerPicker(BuildContext context, AppState app) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          int _tab = 0; // 0 = by time, 1 = by songs
          return StatefulBuilder(
            builder: (ctx2, setInner) {
              const timeOptions = [15, 30, 45, 60, 90];
              const songOptions = [1, 2, 3, 5, 10];
              return BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Dialog(
                  backgroundColor: Colors.transparent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  child: GlassBox(
                    borderRadius: BorderRadius.circular(24),
                    opacity: 0.22,
                    blur: 30,
                    borderColor: Colors.white.withOpacity(0.15),
                    borderWidth: 1.2,
                    shadows: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 32,
                        offset: const Offset(0, 8),
                      ),
                    ],
                    padding: const EdgeInsets.fromLTRB(0, 22, 0, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Title row
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          child: Row(
                            children: [
                              const Icon(Icons.bedtime_outlined, color: Colors.white, size: 20),
                              const SizedBox(width: 10),
                              Text('Sleep Timer', style: TaarTheme.display(context, size: 16)),
                              const Spacer(),
                              GestureDetector(
                                onTap: () => Navigator.pop(ctx),
                                child: Icon(Icons.close_rounded, color: Colors.white.withOpacity(0.45), size: 20),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Tab pills
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(30),
                            ),
                            padding: const EdgeInsets.all(3),
                            child: Row(
                              children: [
                                _SleepTab(label: 'By Time', selected: _tab == 0, onTap: () => setInner(() => _tab = 0)),
                                _SleepTab(label: 'By Songs', selected: _tab == 1, onTap: () => setInner(() => _tab = 1)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Divider(color: Colors.white.withOpacity(0.08), height: 1),
                        if (_tab == 0)
                          ...timeOptions.map((m) => ListTile(
                                dense: true,
                                leading: const Icon(Icons.timer_outlined, color: Colors.white, size: 20),
                                title: Text('$m minutes', style: const TextStyle(color: Colors.white, fontSize: 14)),
                                trailing: Icon(Icons.chevron_right_rounded, color: Colors.white.withOpacity(0.3), size: 18),
                                onTap: () {
                                  app.setSleepTimer(Duration(minutes: m));
                                  Navigator.pop(ctx);
                                },
                              ))
                        else
                          ...songOptions.map((n) => ListTile(
                                dense: true,
                                leading: const Icon(Icons.music_note_outlined, color: Colors.white, size: 20),
                                title: Text('After $n song${n == 1 ? '' : 's'}', style: const TextStyle(color: Colors.white, fontSize: 14)),
                                trailing: Icon(Icons.chevron_right_rounded, color: Colors.white.withOpacity(0.3), size: 18),
                                onTap: () {
                                  app.setSleepAfterNSongs(n);
                                  Navigator.pop(ctx);
                                },
                              )),
                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showSpeedPopover(BuildContext context, AppState app) {
    return showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final speed = app.player.speed;
          return BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Dialog(
              backgroundColor: Colors.transparent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: GlassBox(
                borderRadius: BorderRadius.circular(20),
                opacity: 0.18,
                blur: 24,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Adjust Speed', style: TaarTheme.display(context, size: 17)),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, color: Colors.white),
                          onPressed: () {
                            app.player.setSpeed((speed - 0.1).clamp(0.5, 2.0));
                            setDialogState(() {});
                          },
                        ),
                        SizedBox(
                          width: 56,
                          child: Text(speed.toStringAsFixed(1),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 18, color: Colors.white)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline, color: Colors.white),
                          onPressed: () {
                            app.player.setSpeed((speed + 0.1).clamp(0.5, 2.0));
                            setDialogState(() {});
                          },
                        ),
                      ],
                    ),
                    Slider(
                      min: 0.5,
                      max: 2.0,
                      value: speed.clamp(0.5, 2.0),
                      activeColor: TaarColors.marigold,
                      inactiveColor: Colors.white.withOpacity(0.15),
                      onChanged: (v) {
                        app.player.setSpeed(v);
                        setDialogState(() {});
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openUpNext(BuildContext context, AppState app) {
    showGlassBottomSheet(
      context: context,
      isDraggable: true,
      initialSize: 0.62,
      minSize: 0.4,
      maxSize: 0.92,
      builder: (ctx, scrollController) =>
          _UpNextSheet(scrollController: scrollController),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final song = app.currentSong;

    // Trigger title slide animation when song changes
    if (song != null && _animatedSongId != song.id) {
      _animatedSongId = song.id;
      // Reset YouTube video mode when a new song starts.
      // If the new song is not a YouTube song, always switch back to audio.
      if (_ytVideoMode && !song.id.startsWith('yt:')) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _ytVideoMode = false;
            _ytVideoUrl = null;
            _ytVideoForSongId = null;
          });
          _disposeVideoController();
        });
      }
      // If the card is currently flipped to lyrics, flip it back to the
      // album-art front for the new track — lyrics only reload once the
      // user opens that tab again. setState can't run mid-build, so this
      // is deferred to right after this frame.
      if (_showLyrics) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _showLyrics = false);
          _flipCtrl.reverse();
        });
      }
    }

    final dismissFraction = (_dismissDragY / _kDismissThreshold).clamp(0.0, 1.0);

    return GestureDetector(
      onVerticalDragUpdate: (d) {
        // Only allow dragging downward
        if (d.delta.dy > 0 || _dismissDragY > 0) {
          setState(() {
            _dismissDragY = (_dismissDragY + d.delta.dy).clamp(0.0, _kDismissThreshold * 1.8);
          });
        }
      },
      onVerticalDragEnd: (d) {
        final velocity = d.primaryVelocity ?? 0;
        if (_dismissDragY > _kDismissThreshold || velocity > 600) {
          Navigator.of(context).pop();
        } else {
          setState(() => _dismissDragY = 0);
        }
      },
      onVerticalDragCancel: () => setState(() => _dismissDragY = 0),
      child: Transform.translate(
        offset: Offset(0, _dismissDragY),
        child: Opacity(
          opacity: (1.0 - dismissFraction * 0.4).clamp(0.0, 1.0),
          child: Scaffold(
      backgroundColor: Colors.black,
      body: song == null
          ? const Center(
              child: Text('Nothing playing', style: TextStyle(color: TaarColors.creamDim)))
          : Stack(
              fit: StackFit.expand,
              children: [
                // Blurred album art background
                _songArt(song.image, fit: BoxFit.cover),
                BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.55),
                          Colors.black.withOpacity(0.88),
                        ],
                      ),
                    ),
                  ),
                ),
                // Content
                SafeArea(
                  child: Column(
                    children: [
                      // Top bar
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.keyboard_arrow_down,
                                  size: 30, color: Colors.white),
                              onPressed: () => Navigator.pop(context),
                            ),
                            const Spacer(),
                            // ── YouTube Audio / Video tab pill ─────────────
                            if (song.id.startsWith('yt:')) ...[
                              _YtMediaTabPill(
                                videoMode: _ytVideoMode,
                                onAudio: _switchToAudioMode,
                                onVideo: () => _switchToVideoMode(song),
                              ),
                              const SizedBox(width: 4),
                            ],
                            IconButton(
                              icon: Icon(
                                Icons.lyrics_rounded,
                                size: 24,
                                color: _showLyrics
                                    ? TaarColors.marigold
                                    : Colors.white,
                              ),
                              onPressed: _toggleLyricsTab,
                            ),
                            if (!song.id.startsWith('local:'))
                            IconButton(
                              icon: const Icon(Icons.more_vert, color: Colors.white),
                              onPressed: () => _showOverflowMenu(context, app, song),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: _playerTab(context, app, song),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    ),),),
    );
  }

  Widget _playerTab(BuildContext context, AppState app, Song song) {
    final hasNext = app.currentIndex + 1 < app.queue.length;
    final nextSong = hasNext ? app.queue[app.currentIndex + 1] : null;

    // Build the main media widget (video area OR album-art/lyrics flip card)
    Widget mediaWidget;
    if (_ytVideoMode && song.id.startsWith('yt:')) {
      mediaWidget = _ytVideoArea(context, song);
    } else {
      mediaWidget = GestureDetector(
        onHorizontalDragEnd: (details) {
          if (_showLyrics) return;
          if (details.primaryVelocity == null) return;
          if (details.primaryVelocity! < -250) {
            app.nextSong();
          } else if (details.primaryVelocity! > 250) {
            app.prevSong();
          }
        },
        child: AnimatedBuilder(
          animation: _flipAnim,
          builder: (context, _) {
            final angle = _flipAnim.value * 3.14159265;
            final isFrontVisible = _flipAnim.value < 0.5;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateY(angle),
              child: isFrontVisible
                  // ── FRONT: album art ─────────────────────────────────
                  ? AspectRatio(
                      aspectRatio: 1,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: ScaleTransition(
                              scale: Tween(begin: 0.92, end: 1.0).animate(anim),
                              child: child),
                        ),
                        child: Hero(
                          tag: 'album_art_hero',
                          child: Container(
                            key: ValueKey(song.id),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(22),
                              boxShadow: [
                                BoxShadow(
                                  color: TaarColors.marigold.withOpacity(0.25),
                                  blurRadius: 40,
                                  spreadRadius: 4,
                                  offset: const Offset(0, 10),
                                ),
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.5),
                                  blurRadius: 20,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: _songArt(song.image, fit: BoxFit.cover),
                            ),
                          ),
                        ),
                      ),
                    )
                  // ── BACK: lyrics (mirrored so it reads correctly) ────
                  : Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()..rotateY(3.14159265),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                                color: TaarColors.marigold.withOpacity(0.3),
                                width: 1.5),
                            boxShadow: [
                              BoxShadow(
                                color: TaarColors.marigold.withOpacity(0.2),
                                blurRadius: 36,
                                spreadRadius: 2,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: _lyricsCardContent(context, app, song),
                          ),
                        ),
                      ),
                    ),
            );
          },
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 10),
      child: Column(
        children: [
          // ── Main media area ───────────────────────────────────────────────
          Expanded(
            child: Center(child: mediaWidget),
          ),
          const SizedBox(height: 18),

          // Song info + like
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 28,
                      child: song.title.length > 22
                          ? Marquee(
                              key: ValueKey(song.id),
                              text: song.title,
                              style: TaarTheme.display(context, size: 21, weight: FontWeight.w800)
                                  .copyWith(color: Colors.white),
                              blankSpace: 60,
                              velocity: 28,
                              pauseAfterRound: const Duration(seconds: 2),
                              startPadding: 0,
                              fadingEdgeStartFraction: 0.0,
                              fadingEdgeEndFraction: 0.08,
                            )
                          : Text(song.title,
                              style: TaarTheme.display(context, size: 21, weight: FontWeight.w800)
                                  .copyWith(color: Colors.white),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(height: 3),
                    Text(song.artist,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.6), fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                    app.isLiked(song.id) ? Icons.favorite : Icons.favorite_border,
                    size: 24,
                    color: app.isLiked(song.id)
                        ? TaarColors.vermilion
                        : Colors.white.withOpacity(0.7)),
                onPressed: () => app.toggleLike(song),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Speed label
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () =>
                  _showSpeedPopover(context, app).then((_) {
                if (mounted) setState(() {});
              }),
              child: GlassBox(
                borderRadius: BorderRadius.circular(8),
                opacity: 0.12,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Text('${app.player.speed.toStringAsFixed(1)}x',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.7), fontSize: 12)),
              ),
            ),
          ),
          const SizedBox(height: 4),

          // Seek Bar
          StreamBuilder<Duration>(
            stream: app.player.positionStream,
            builder: (context, snap) {
              final pos = snap.data ?? Duration.zero;
              final dur = app.player.duration ?? Duration.zero;
              final durationMs = dur.inMilliseconds.toDouble().clamp(1.0, double.infinity);
              final posMs = pos.inMilliseconds.toDouble().clamp(0.0, durationMs);

              String fmt(Duration d) {
                final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
                final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
                return '$m:$s';
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: TaarColors.marigold,
                      inactiveTrackColor: Colors.white.withOpacity(0.22),
                      thumbColor: Colors.white,
                      overlayColor: Colors.white.withOpacity(0.15),
                    ),
                    child: Slider(
                      value: posMs,
                      min: 0,
                      max: durationMs,
                      onChanged: app.isLoadingTrack
                          ? null
                          : (val) => app.player.seek(Duration(milliseconds: val.toInt())),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(fmt(pos),
                            style: TextStyle(fontSize: 11.5, color: Colors.white.withOpacity(0.55))),
                        Text(fmt(dur),
                            style: TextStyle(fontSize: 11.5, color: Colors.white.withOpacity(0.55))),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),

          // Controls row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _PlayModeButton(
                isShuffled: app.isShuffled,
                repeatMode: app.repeatMode,
                onTap: () {
                  // Cycle: shuffle -> repeat all -> repeat one -> off
                  if (!app.isShuffled && app.repeatMode == TaarRepeatMode.off) {
                    app.toggleShuffle(); // shuffle ON
                  } else if (app.isShuffled) {
                    app.toggleShuffle(); // shuffle OFF
                    // move to repeat all
                    if (app.repeatMode == TaarRepeatMode.off) app.cycleRepeat();
                  } else if (app.repeatMode == TaarRepeatMode.all) {
                    app.cycleRepeat(); // repeat one
                  } else if (app.repeatMode == TaarRepeatMode.one) {
                    app.cycleRepeat(); // off
                  }
                },
              ),
              IconButton(
                icon: Icon(Icons.skip_previous,
                    color: Colors.white.withOpacity(0.9), size: 36),
                onPressed: () {
                  app.prevSong();
                },
              ),
              // Play / Pause glass button with music animation
              _MusicRingButton(
                isPlaying: app.player.playing,
                isLoading: app.isLoadingTrack,
                onTap: app.togglePlayPause,
              ),
              IconButton(
                icon: Icon(Icons.skip_next,
                    color: Colors.white.withOpacity(0.9), size: 36),
                onPressed: () {
                  app.nextSong();
                },
              ),
              if (!song.id.startsWith('local:'))
              _DownloadButton(song: song),
            ],
          ),
          const SizedBox(height: 14),

          // Next up card
          if (nextSong != null)
            GestureDetector(
              onTap: () => _openUpNext(context, app),
              onVerticalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity < -250) {
                  _openUpNext(context, app);
                }
              },
              child: GlassBox(
                borderRadius: BorderRadius.circular(16),
                opacity: 0.13,
                blur: 20,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('NEXT UP',
                              style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: TaarColors.marigold,
                                  letterSpacing: 1.4)),
                          const SizedBox(height: 3),
                          Text(nextSong.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                          Text(nextSong.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.55),
                                  fontSize: 11.5)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _songArt(nextSong.image, width: 46, height: 46, fit: BoxFit.cover,
                        placeholder: () => Image.asset(AppAssets.placeholderSong, width: 46, height: 46, fit: BoxFit.cover)),
                    ),
                    const SizedBox(width: 10),
                    Icon(Icons.queue_music_outlined,
                        color: Colors.white.withOpacity(0.4), size: 18),
                  ],
                ),
              ),
            )
          else if (app.queue.length > 1)
            GestureDetector(
              onTap: () => _openUpNext(context, app),
              child: GlassBox(
                borderRadius: BorderRadius.circular(16),
                opacity: 0.12,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.queue_music_outlined,
                        color: Colors.white.withOpacity(0.55), size: 18),
                    const SizedBox(width: 10),
                    const Text('Up Next',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                    const Spacer(),
                    Icon(Icons.chevron_right,
                        color: Colors.white.withOpacity(0.4), size: 18),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 6),
        ],
      ),
    );
  }

  // ── Lyrics content rendered on the back face of the flip card ─────────────
  Widget _lyricsCardContent(BuildContext context, AppState app, Song song) {
    // Not yet triggered
    if (_lyricsForSongId != song.id && !_lyricsLoading) {
      return _lyricsCenterMessage(
        icon: Icons.lyrics_outlined,
        message: 'Loading lyrics…',
      );
    }
    // Loading spinner
    if (_lyricsLoading) {
      return const Center(
        child: CircularProgressIndicator(color: TaarColors.marigold, strokeWidth: 2.5),
      );
    }
    final hasSynced = _syncedLines.isNotEmpty;
    // No lyrics found anywhere
    if (!hasSynced && (_lyrics == null || _lyrics!.isEmpty)) {
      return _lyricsCenterMessage(
        emoji: ':(',
        message: 'Lyrics Not Available',
      );
    }
    return Stack(
      children: [
        // Subtle album art blurred behind lyrics for depth
        Positioned.fill(
          child: Opacity(
            opacity: 0.08,
            child: _songArt(song.image, fit: BoxFit.cover,
              placeholder: () => const SizedBox.shrink()),
          ),
        ),
        if (hasSynced)
          // ── Time-synced lyrics (LRCLIB) — fixed title, auto-scrolling lines
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 44),
                  child: Text(song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: TaarColors.marigold,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          letterSpacing: 0.4)),
                ),
                Expanded(child: _syncedLyricsView(context, app)),
              ],
            ),
          )
        else
          // ── Static plain-text lyrics — JioSaavn / lyrics.ovh / LRCLIB plain
          Scrollbar(
            thumbVisibility: true,
            radius: const Radius.circular(4),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Small song title header inside card
                  Text(song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: TaarColors.marigold,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          letterSpacing: 0.4)),
                  const SizedBox(height: 10),
                  Text(
                    _lyrics!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        height: 1.85),
                  ),
                  if (_lyricsCopyright != null && _lyricsCopyright!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Divider(color: Colors.white.withOpacity(0.1)),
                    const SizedBox(height: 8),
                    Text(_lyricsCopyright!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 10.5, color: Colors.white.withOpacity(0.35))),
                  ],
                ],
              ),
            ),
          ),
        // ── Copy & Share action row ── shown when lyrics are available
        if (hasSynced || (_lyrics != null && _lyrics!.isNotEmpty))
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withOpacity(0.55),
                  ],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(12, 20, 12, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _lyricsActionButton(
                    icon: Icons.copy_rounded,
                    label: 'Copy',
                    onTap: () => _copyLyrics(context, song),
                  ),
                  const SizedBox(width: 12),
                  _lyricsActionButton(
                    icon: Icons.share_rounded,
                    label: 'Share',
                    onTap: () => _shareLyrics(song),
                  ),
                ],
              ),
            ),
          ),
        // ── "N matches" chip — only shown when LRCLIB returned more than
        // one candidate, so the user can manually pick the right one.
        if (_lrcMatches.length > 1)
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () => _showLrcMatchPicker(context, song),
              child: GlassBox(
                borderRadius: BorderRadius.circular(20),
                opacity: 0.20,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.swap_vert_rounded,
                        size: 13, color: Colors.white),
                    const SizedBox(width: 4),
                    Text('${_lrcMatches.length} matches',
                        style: const TextStyle(
                            fontSize: 10.5,
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Renders `_syncedLines`, highlighting and auto-centering whichever
  /// line matches the current playback position.
  Widget _syncedLyricsView(BuildContext context, AppState app) {
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
          padding: const EdgeInsets.symmetric(vertical: 70, horizontal: 22),
          itemCount: _syncedLines.length,
          itemBuilder: (context, i) {
            final line = _syncedLines[i];
            final active = i == idx;
            return Container(
              key: _lrcLineKeys[i],
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 220),
                style: TextStyle(
                  color: active
                      ? TaarColors.marigold
                      : Colors.white.withOpacity(0.42),
                  fontSize: active ? 16.5 : 14.5,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
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

  Widget _lyricsActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: GlassBox(
        borderRadius: BorderRadius.circular(20),
        opacity: 0.22,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  String _getLyricsText(Song song) {
    if (_syncedLines.isNotEmpty) {
      return _syncedLines.map((l) => l.text).where((t) => t.isNotEmpty).join('\n');
    }
    return _lyrics ?? '';
  }

  void _copyLyrics(BuildContext context, Song song) {
    final text = _getLyricsText(song);
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: '${song.title}\n\n$text'));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Lyrics copied to clipboard'),
        backgroundColor: Colors.black87,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _shareLyrics(Song song) {
    final text = _getLyricsText(song);
    if (text.isEmpty) return;
    Share.share('${song.title} — ${song.artist}\n\n$text');
  }

  Widget _lyricsCenterMessage({IconData? icon, String? emoji, required String message}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (emoji != null)
              Text(emoji,
                  style: const TextStyle(fontSize: 32, color: Colors.white)),
            if (icon != null)
              Icon(icon, size: 40, color: Colors.white.withOpacity(0.35)),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 14,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  // ── YouTube inline video area — uses video_player package ──────────────────
  Widget _ytVideoArea(BuildContext context, Song song) {
    if (_ytVideoLoading) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(
                  color: Colors.redAccent, strokeWidth: 2.5),
              const SizedBox(height: 14),
              Text('Loading video stream…',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.55), fontSize: 13)),
            ],
          ),
        ),
      );
    }

    if (_ytVideoError != null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _ytVideoError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.6), fontSize: 13),
                ),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: () => _loadYtVideo(song),
                child: const Text('Retry',
                    style: TextStyle(color: Colors.redAccent)),
              ),
            ],
          ),
        ),
      );
    }

    if (_ytVideoUrl == null) {
      // Hasn't started loading yet — shouldn't normally happen
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Center(
            child: CircularProgressIndicator(color: Colors.redAccent),
          ),
        ),
      );
    }

    // Video URL is ready — show inline VideoPlayer
    final ctrl = _videoController;
    if (ctrl == null || !ctrl.value.isInitialized) {
      // Controller still initializing
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Center(
            child: CircularProgressIndicator(color: Colors.redAccent, strokeWidth: 2.5),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Inline video player ─────────────────────────────────────────
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: AspectRatio(
            aspectRatio: ctrl.value.aspectRatio,
            child: Stack(
              alignment: Alignment.topLeft,
              children: [
                VideoPlayer(ctrl),
                // HD badge
                Positioned(
                  top: 8, left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white24, width: 0.5),
                    ),
                    child: const Text('HD VIDEO',
                        style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Kept for legacy reference — video now plays inline, no longer needed.
  void _openVideoInSystemPlayer(BuildContext context, Song song) async {
    final url = _ytVideoUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
} // end _NowPlayingScreenState

// ────────────────────────────────────────────────────────────────────────────
// Up Next tile — transparent row, no card per item
// ────────────────────────────────────────────────────────────────────────────
// ────────────────────────────────────────────────────────────────────────────
// "Up Next" sheet — an infinite-scrolling queue feed. As the user scrolls
// towards the bottom of the upcoming-songs list, it asks AppState for more
// JioSaavn recommendations seeded from the last queued song, splices them
// in, and keeps going — so the list effectively never runs out, like an
// endless radio station built entirely from "songs related to the last one".
// ────────────────────────────────────────────────────────────────────────────
class _UpNextSheet extends StatefulWidget {
  final ScrollController? scrollController;
  const _UpNextSheet({this.scrollController});

  @override
  State<_UpNextSheet> createState() => _UpNextSheetState();
}

class _UpNextSheetState extends State<_UpNextSheet> {
  static const double _loadMoreThreshold = 400;

  @override
  void initState() {
    super.initState();
    widget.scrollController?.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.scrollController?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final sc = widget.scrollController;
    if (sc == null || !sc.hasClients) return;
    final remaining = sc.position.maxScrollExtent - sc.position.pixels;
    if (remaining < _loadMoreThreshold) {
      context.read<AppState>().extendQueueWithMoreReco();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, app, _) {
        final upcoming = List.generate(
          (app.queue.length - app.currentIndex - 1).clamp(0, app.queue.length),
          (i) => app.currentIndex + 1 + i,
        );
        return Column(
          children: [
            _sheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(Icons.queue_music_rounded,
                      color: TaarColors.marigold, size: 19),
                  const SizedBox(width: 9),
                  Text('Up Next',
                      style: TaarTheme.display(context,
                          size: 17, weight: FontWeight.w700)),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${upcoming.length} songs',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.50),
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            Divider(
                height: 1,
                thickness: 0.5,
                color: Colors.white.withOpacity(0.08)),
            const SizedBox(height: 4),
            Expanded(
              child: upcoming.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.queue_music_outlined,
                              size: 52, color: Colors.white.withOpacity(0.18)),
                          const SizedBox(height: 14),
                          Text('Queue is empty',
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.38),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500)),
                        ],
                      ),
                    )
                  : ReorderableListView.builder(
                      scrollController: widget.scrollController,
                      padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
                      buildDefaultDragHandles: false,
                      itemCount: upcoming.length,
                      proxyDecorator: (child, idx, anim) => Material(
                        color: Colors.transparent,
                        elevation: 0,
                        child: child,
                      ),
                      onReorder: (oldI, newI) {
                        app.reorderQueue(upcoming[oldI], app.currentIndex + 1 + newI);
                      },
                      itemBuilder: (context, i) {
                        final idx = upcoming[i];
                        final s = app.queue[idx];
                        return Dismissible(
                          key: ValueKey('${s.id}_$idx'),
                          direction: DismissDirection.horizontal,
                          background: const _UpNextSwipeBg(alignment: Alignment.centerLeft),
                          secondaryBackground: const _UpNextSwipeBg(alignment: Alignment.centerRight),
                          onDismissed: (direction) {
                            app.removeFromQueue(idx);
                          },
                          child: _UpNextTile(
                            key: ValueKey('tile_${s.id}_$idx'),
                            song: s,
                            position: i + 1,
                            reorderIndex: i,
                            isNext: i == 0,
                            isLast: i == upcoming.length - 1,
                            onTap: () {
                              app.playByIndex(idx);
                              Navigator.pop(context);
                            },
                            onLike: () => app.toggleLike(s),
                            isLiked: app.isLiked(s.id),
                          ),
                        );
                      },
                    ),
            ),
            _UpNextFooter(
              isFetchingMore: app.isFetchingMore,
              noMoreRecommendations: app.noMoreRecommendations,
            ),
          ],
        );
      },
    );
  }
}

/// Slim status row pinned under the upcoming list: a spinner while more
/// recommendations are loading, or a quiet end-of-the-line message once
/// JioSaavn genuinely has nothing further to suggest.
class _UpNextFooter extends StatelessWidget {
  final bool isFetchingMore;
  final bool noMoreRecommendations;

  const _UpNextFooter({
    required this.isFetchingMore,
    required this.noMoreRecommendations,
  });

  @override
  Widget build(BuildContext context) {
    if (!isFetchingMore && !noMoreRecommendations) {
      return const SizedBox.shrink();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Padding(
        key: ValueKey(isFetchingMore),
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: isFetchingMore
              ? [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: TaarColors.marigold.withOpacity(0.85),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Finding more songs you\'ll like…',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.45),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500),
                  ),
                ]
              : [
                  Icon(Icons.radio_rounded,
                      size: 14, color: Colors.white.withOpacity(0.30)),
                  const SizedBox(width: 8),
                  Text(
                    'No more recommendations right now',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.35),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500),
                  ),
                ],
        ),
      ),
    );
  }
}

/// Red "delete" backdrop revealed while a tile is being swiped away in the
/// Up Next list — mirrors the left/right swipe direction with the trash
/// icon and edge-aligned padding.
class _UpNextSwipeBg extends StatelessWidget {
  final Alignment alignment;
  const _UpNextSwipeBg({required this.alignment});

  @override
  Widget build(BuildContext context) {
    final isLeft = alignment == Alignment.centerLeft;
    return Container(
      color: TaarColors.vermilion.withOpacity(0.85),
      alignment: alignment,
      padding: EdgeInsets.only(left: isLeft ? 28 : 0, right: isLeft ? 0 : 28),
      child: const Icon(Icons.delete_outline_rounded,
          color: Colors.white, size: 24),
    );
  }
}

class _UpNextTile extends StatelessWidget {
  final Song song;
  final int position;
  final int reorderIndex;
  final bool isNext;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onLike;
  final bool isLiked;

  const _UpNextTile({
    super.key,
    required this.song,
    required this.position,
    required this.reorderIndex,
    required this.isNext,
    required this.onTap,
    required this.onLike,
    required this.isLiked,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    // NOTE: ReorderableListView injects a white Material surface per-item.
    // We counter it by painting our own transparent surface on top via
    // Ink (which respects the InkWell ancestor) and keeping all containers
    // Colors.transparent.
    return ColoredBox(
      // Extremely subtle tint on "NEXT" row — fully transparent otherwise
      color: isNext
          ? TaarColors.marigold.withOpacity(0.05)
          : Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            splashColor: Colors.white.withOpacity(0.05),
            highlightColor: Colors.white.withOpacity(0.03),
            child: Padding(
              // Extra right padding = 0 so drag handle reaches the edge cleanly
              padding: const EdgeInsets.only(
                  left: 16, top: 11, bottom: 11, right: 4),
              child: Row(
                children: [
                  // Album art + NEXT badge
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: _songArt(song.image, fit: BoxFit.cover,
                            placeholder: () => Image.asset(AppAssets.placeholderSong, fit: BoxFit.cover)),
                        ),
                        if (isNext)
                          Positioned(
                            bottom: 0, left: 0, right: 0,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                  bottom: Radius.circular(9)),
                              child: Container(
                                height: 15,
                                color: TaarColors.marigold.withOpacity(0.90),
                                alignment: Alignment.center,
                                child: const Text('NEXT',
                                    style: TextStyle(
                                        fontSize: 7,
                                        fontWeight: FontWeight.w900,
                                        color: Colors.white,
                                        letterSpacing: 0.6)),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 13),
                  // Title + artist
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white
                                  .withOpacity(isNext ? 1.0 : 0.82),
                              fontWeight: isNext
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              fontSize: 13.5,
                            )),
                        const SizedBox(height: 2),
                        Text(song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.38),
                              fontSize: 11.5,
                            )),
                      ],
                    ),
                  ),
                  // Like — only show when liked, otherwise invisible tap zone
                  // so the row feels cleaner (matches screenshot complaint)
                  GestureDetector(
                    onTap: onLike,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 36,
                      height: 48,
                      child: Center(
                        child: Icon(
                          isLiked ? Icons.favorite : Icons.favorite_border,
                          color: isLiked
                              ? TaarColors.vermilion
                              : Colors.white.withOpacity(0.18),
                          size: 17,
                        ),
                      ),
                    ),
                  ),
                  // Drag handle — ReorderableDragStartListener with manual index
                  // because buildDefaultDragHandles:false is set on the list
                  ReorderableDragStartListener(
                    index: reorderIndex,
                    child: SizedBox(
                      width: 36,
                      height: 48,
                      child: Center(
                        child: Icon(
                          Icons.drag_handle_rounded,
                          color: Colors.white.withOpacity(0.20),
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!isLast)
            Divider(
              height: 1,
              thickness: 0.5,
              indent: 77,
              endIndent: 0,
              color: Colors.white.withOpacity(0.06),
            ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────

/// Returns the correct image widget for a song's artwork.
/// Handles both network URLs (online songs) and local file paths (device songs).
Widget _songArt(String imageUrl, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
  Widget Function()? placeholder,
}) {
  final ph = placeholder ?? () => Image.asset(AppAssets.placeholderCover, fit: fit, width: width, height: height);
  if (imageUrl.isEmpty) return ph();
  if (imageUrl.startsWith('/') || imageUrl.startsWith('file://')) {
    final path = imageUrl.replaceFirst('file://', '');
    final file = File(path);
    return Image.file(
      file,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, __, ___) => ph(),
    );
  }
  return CachedNetworkImage(
    imageUrl: imageUrl,
    width: width,
    height: height,
    fit: fit,
    errorWidget: (_, __, ___) => ph(),
  );
}

// Download button with circular progress bar and percentage inside the circle
// ────────────────────────────────────────────────────────────────────────────
class _DownloadButton extends StatelessWidget {
  final Song song;
  const _DownloadButton({required this.song});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    // ── YouTube songs: show the audio-or-video dialog ─────────────────────
    if (song.id.startsWith('yt:')) {
      final audioDl = app.downloadState(song.id);
      final videoDl = app.videoDownloadState(song.id);
      final anyDownloading = audioDl.status == DownloadStatus.downloading ||
          videoDl.status == DownloadStatus.downloading;
      final anyDone = audioDl.status == DownloadStatus.done ||
          videoDl.status == DownloadStatus.done;

      return SizedBox(
        width: 48,
        height: 48,
        child: GestureDetector(
          onTap: () {
            // Find the NowPlayingScreen state to call _showYtDownloadDialog
            final state = context
                .findAncestorStateOfType<_NowPlayingScreenState>();
            state?._showYtDownloadDialog(context, app, song);
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (anyDownloading)
                SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    value: audioDl.status == DownloadStatus.downloading
                        ? audioDl.progress
                        : videoDl.progress,
                    color: Colors.redAccent,
                    strokeWidth: 2.5,
                  ),
                ),
              Icon(
                anyDone
                    ? Icons.download_done
                    : anyDownloading
                        ? Icons.download_outlined
                        : Icons.download_outlined,
                color: anyDone
                    ? TaarColors.jadeBright
                    : anyDownloading
                        ? Colors.redAccent
                        : Colors.white.withOpacity(0.7),
                size: 26,
              ),
            ],
          ),
        ),
      );
    }

    // ── Regular (Saavn/local) songs: original behaviour ───────────────────
    final dl = app.downloadState(song.id);

    return SizedBox(
      width: 48,
      height: 48,
      child: GestureDetector(
        onTap: () {
          if (dl.status == DownloadStatus.idle ||
              dl.status == DownloadStatus.error) {
            app.downloadSong(song);
          } else if (dl.status == DownloadStatus.downloading) {
            app.cancelDownload(song.id);
          }
          // done: tap shows a snackbar or does nothing
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (dl.status == DownloadStatus.downloading)
              SizedBox(
                width: 36,
                height: 36,
                child: CustomPaint(
                  painter: _CircularProgressPainter(
                    progress: dl.progress,
                    trackColor: Colors.white.withOpacity(0.15),
                    progressColor: TaarColors.marigold,
                    strokeWidth: 2.5,
                  ),
                ),
              ),
            if (dl.status == DownloadStatus.downloading)
              Text(
                '${(dl.progress * 100).round()}%',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    fontWeight: FontWeight.w700),
              )
            else
              Icon(
                dl.status == DownloadStatus.done
                    ? Icons.download_done
                    : Icons.download_outlined,
                color: dl.status == DownloadStatus.done
                    ? TaarColors.jadeBright
                    : dl.status == DownloadStatus.error
                        ? TaarColors.vermilion
                        : Colors.white.withOpacity(0.7),
                size: 26,
              ),
          ],
        ),
      ),
    );
  }
}

/// Custom painter for the circular progress ring.
class _CircularProgressPainter extends CustomPainter {
  final double progress;
  final Color trackColor;
  final Color progressColor;
  final double strokeWidth;

  _CircularProgressPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
    this.strokeWidth = 3.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // Track ring
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    // Progress arc
    const startAngle = -3.14159 / 2; // start at top
    final sweepAngle = 2 * 3.14159 * progress.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      Paint()
        ..color = progressColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CircularProgressPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

// ────────────────────────────────────────────────────────────────────────────
// Unified play-mode icon: cycles through shuffle → repeat-all → repeat-one → off
// ────────────────────────────────────────────────────────────────────────────
class _PlayModeButton extends StatelessWidget {
  final bool isShuffled;
  final TaarRepeatMode repeatMode;
  final VoidCallback onTap;

  const _PlayModeButton({
    required this.isShuffled,
    required this.repeatMode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color;
    String tooltip;

    if (isShuffled) {
      icon = Icons.shuffle;
      color = TaarColors.jadeBright;
      tooltip = 'Shuffle';
    } else if (repeatMode == TaarRepeatMode.all) {
      icon = Icons.repeat;
      color = TaarColors.jadeBright;
      tooltip = 'Repeat All';
    } else if (repeatMode == TaarRepeatMode.one) {
      icon = Icons.repeat_one;
      color = TaarColors.marigold;
      tooltip = 'Repeat One';
    } else {
      icon = Icons.shuffle;
      color = Colors.white.withOpacity(0.5);
      tooltip = 'Off';
    }

    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, color: color),
        onPressed: onTap,
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Reusable label/value row for the Song Details sheet
// ────────────────────────────────────────────────────────────────────────────
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;

  const _DetailRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.40),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white.withOpacity(0.88),
                fontSize: 13,
                fontWeight: FontWeight.w500,
                fontFamily: mono ? 'monospace' : null,
                letterSpacing: mono ? 0.5 : 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill tab used inside the sleep timer dialog.
class _SleepTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SleepTab({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: selected ? Colors.white.withOpacity(0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white.withOpacity(0.5),
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Equalizer Dialog ──────────────────────────────────────────────────────────

class _EqualizerDialog extends StatefulWidget {
  const _EqualizerDialog();

  @override
  State<_EqualizerDialog> createState() => _EqualizerDialogState();
}

class _EqualizerDialogState extends State<_EqualizerDialog> {
  static const _bands = ['60Hz', '230Hz', '910Hz', '4kHz', '14kHz'];
  static const _labels = ['Bass', 'Low Mid', 'Mid', 'High Mid', 'Treble'];

  final List<double> _gains = [0, 0, 0, 0, 0]; // -12 to +12 dB
  String _preset = 'Custom';

  static const _presets = <String, List<double>>{
    'Flat':       [0,    0,    0,    0,    0],
    'Bass Boost': [8,    4,    0,   -2,   -2],
    'Treble':     [-2,  -2,    0,    4,    8],
    'Vocal':      [-2,   0,    6,    4,    0],
    'Rock':       [5,    3,   -1,    3,    5],
    'Pop':        [-1,   2,    5,    2,   -1],
    'Jazz':       [3,    2,    0,    2,    3],
    'Classical':  [5,    3,   -2,    3,    4],
    'Custom':     [0,    0,    0,    0,    0],
  };

  void _applyPreset(String name) {
    final values = _presets[name];
    if (values == null) return;
    setState(() {
      _preset = name;
      for (int i = 0; i < 5; i++) _gains[i] = values[i];
    });
  }

  Color _gainColor(double gain) {
    if (gain > 4) return TaarColors.marigold;
    if (gain > 0) return TaarColors.marigold.withOpacity(0.65);
    if (gain < -4) return TaarColors.vermilion;
    if (gain < 0) return TaarColors.vermilion.withOpacity(0.65);
    return Colors.white.withOpacity(0.45);
  }

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: Colors.white.withOpacity(0.18), width: 1.2),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 50, offset: const Offset(0, 16)),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Header ─────────────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
                        child: Row(
                          children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(
                                color: TaarColors.marigold.withOpacity(0.18),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: TaarColors.marigold.withOpacity(0.30)),
                              ),
                              child: const Icon(Icons.equalizer_rounded, color: TaarColors.marigold, size: 20),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Equalizer', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                                  Text('Adjust your sound', style: TextStyle(color: Colors.white54, fontSize: 11.5)),
                                ],
                              ),
                            ),
                            GestureDetector(
                              onTap: () => Navigator.pop(context),
                              child: Container(
                                width: 30, height: 30,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.10),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white.withOpacity(0.12)),
                                ),
                                child: Icon(Icons.close_rounded, color: Colors.white.withOpacity(0.65), size: 16),
                              ),
                            ),
                          ],
                        ),
                      ),

                      Divider(height: 1, color: Colors.white.withOpacity(0.08)),

                      // ── Preset chips ───────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                        child: SizedBox(
                          height: 32,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: _presets.keys.where((k) => k != 'Custom').map((name) {
                              final active = _preset == name;
                              return GestureDetector(
                                onTap: () => _applyPreset(name),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  margin: const EdgeInsets.only(right: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: active ? TaarColors.marigold.withOpacity(0.22) : Colors.white.withOpacity(0.07),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: active ? TaarColors.marigold.withOpacity(0.60) : Colors.white.withOpacity(0.10),
                                      width: active ? 1.2 : 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    name,
                                    style: TextStyle(
                                      color: active ? TaarColors.marigold : Colors.white.withOpacity(0.65),
                                      fontSize: 12,
                                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),

                      // ── EQ Sliders ─────────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                        child: SizedBox(
                          height: 200,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: List.generate(5, (i) {
                              final gain = _gains[i];
                              final color = _gainColor(gain);
                              return Expanded(
                                child: Column(
                                  children: [
                                    // dB label
                                    Text(
                                      '${gain >= 0 ? '+' : ''}${gain.round()}',
                                      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
                                    ),
                                    const SizedBox(height: 4),
                                    // Vertical slider
                                    Expanded(
                                      child: RotatedBox(
                                        quarterTurns: 3,
                                        child: SliderTheme(
                                          data: SliderTheme.of(context).copyWith(
                                            trackHeight: 3.5,
                                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                            activeTrackColor: color,
                                            inactiveTrackColor: Colors.white.withOpacity(0.12),
                                            thumbColor: color,
                                            overlayColor: color.withOpacity(0.18),
                                          ),
                                          child: Slider(
                                            value: gain,
                                            min: -12,
                                            max: 12,
                                            divisions: 24,
                                            onChanged: (v) {
                                              setState(() {
                                                _gains[i] = v;
                                                _preset = 'Custom';
                                              });
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    // Band label
                                    Text(_bands[i], style: const TextStyle(color: Colors.white54, fontSize: 9.5, fontWeight: FontWeight.w600)),
                                    Text(_labels[i], style: const TextStyle(color: Colors.white38, fontSize: 8.5)),
                                  ],
                                ),
                              );
                            }),
                          ),
                        ),
                      ),

                      Divider(height: 1, color: Colors.white.withOpacity(0.08)),

                      // ── Footer buttons ─────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        child: Row(
                          children: [
                            // Reset button
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _applyPreset('Flat'),
                                child: Container(
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.07),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.white.withOpacity(0.10)),
                                  ),
                                  child: const Center(
                                    child: Text('Reset', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 14)),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            // Apply button
                            Expanded(
                              flex: 2,
                              child: GestureDetector(
                                onTap: () => Navigator.pop(context),
                                child: Container(
                                  height: 42,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [TaarColors.marigold, TaarColors.marigold.withOpacity(0.75)],
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: [
                                      BoxShadow(color: TaarColors.marigold.withOpacity(0.35), blurRadius: 12, offset: const Offset(0, 4)),
                                    ],
                                  ),
                                  child: const Center(
                                    child: Text('Apply', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                                  ),
                                ),
                              ),
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
        ),
      ),
    );
  }
}

// ── Related Albums bottom-sheet widget ────────────────────────────────────────
class _RelatedAlbumsSheet extends StatefulWidget {
  final String albumId;
  final SaavnApi api;
  final ScrollController? scrollController;

  const _RelatedAlbumsSheet({
    required this.albumId,
    required this.api,
    this.scrollController,
  });

  @override
  State<_RelatedAlbumsSheet> createState() => _RelatedAlbumsSheetState();
}

class _RelatedAlbumsSheetState extends State<_RelatedAlbumsSheet> {
  List<Map<String, dynamic>> _reco = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.api.fetchAlbumReco(widget.albumId).then((result) {
      if (mounted) setState(() { _reco = result; _loading = false; });
    }).catchError((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _sheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
            child: Row(
              children: [
                const Icon(Icons.library_music_outlined, color: TaarColors.marigold, size: 19),
                const SizedBox(width: 9),
                Text('Related Albums',
                    style: TaarTheme.display(context, size: 17, weight: FontWeight.w700)),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.white.withOpacity(0.08)),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(
                    color: TaarColors.marigold, strokeWidth: 2))
                : _reco.isEmpty
                    ? Center(
                        child: Text('No related albums found',
                            style: TextStyle(color: Colors.white.withOpacity(0.5))),
                      )
                    : GridView.builder(
                        controller: widget.scrollController,
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          childAspectRatio: 0.75,
                        ),
                        itemCount: _reco.length,
                        itemBuilder: (_, i) {
                          final album = _reco[i];
                          final aId = (album['id'] ?? '').toString();
                          final aTitle = (album['title'] ?? album['album'] ?? 'Album').toString();
                          String aImg = (album['image'] ?? '').toString();
                          aImg = aImg
                              .replaceAll('150x150', '500x500')
                              .replaceAll('50x50', '500x500');
                          final artist = (album['subtitle'] ?? album['primary_artists'] ?? album['artist'] ?? '').toString();
                          return GestureDetector(
                            onTap: aId.isEmpty
                                ? null
                                : () {
                                    Navigator.pop(context);
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => AlbumPlaylistScreen(
                                          id: aId, type: 'album', title: aTitle),
                                      ),
                                    );
                                  },
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: CachedNetworkImage(
                                      imageUrl: aImg,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      errorWidget: (_, __, ___) => Container(
                                        color: TaarColors.ink3,
                                        child: const Icon(Icons.album,
                                            color: TaarColors.creamDim, size: 40),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(aTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12.5)),
                                if (artist.isNotEmpty)
                                  Text(artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: TaarColors.creamDim, fontSize: 11)),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _MusicRingButton — Liquid Soundwave Play Button
//
// Design: 12 radial soundwave bars shoot outward from the button rim like a
// clock face. Each bar animates with a unique phase offset, height, and easing
// — creating the illusion of a real-time waveform radiating from the music.
// A morphing blob (superellipse with 6 control points) breathes behind the
// button. On pause, all bars gracefully collapse inward and the blob deflates.
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
  // Master clock — drives all bar animations
  late AnimationController _clock;
  // Blob morph controller
  late AnimationController _blob;
  // Tap spring
  late AnimationController _tap;
  late Animation<double> _tapScale;
  // Fade-in/out the bars when toggling play
  late AnimationController _fade;

  @override
  void initState() {
    super.initState();

    // Long duration so .value climbs slowly like elapsed time (0→1 over 100s)
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
                  // ── Morphing blob glow behind everything ──────────────
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

                  // ── Orbiting particles ────────────────────────────────
                  Opacity(
                    opacity: _fade.value,
                    child: CustomPaint(
                      size: const Size(130, 130),
                      painter: _OrbitParticlesPainter(
                        timeValue: _clock.value * 100, // scale to seconds
                        color: TaarColors.marigold,
                      ),
                    ),
                  ),

                  // ── Glass core ────────────────────────────────────────
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
// 3 rings of particles orbit the button in tilted ellipses at different speeds.
// Each particle has a comet-like trail. Depth-sorting makes far particles
// smaller and dimmer — creating a genuine 3D orbital feel.
class _OrbitParticlesPainter extends CustomPainter {
  final double timeValue; // elapsed seconds (unbounded, from repeating controller scaled externally)
  final Color color;

  const _OrbitParticlesPainter({
    required this.timeValue,
    required this.color,
  });

  // Ring definitions: [radius, angularSpeed, particleCount, dotRadius, tiltAngle, phaseOffset]
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
      final ringR   = ring[0];
      final speed   = ring[1];
      final count   = ring[2].toInt();
      final baseRad = ring[3];
      final tilt    = ring[4]; // cos(tilt) compresses Y — makes it look tilted
      final phase   = ring[5];

      final cosTilt = _cos(tilt);

      for (int i = 0; i < count; i++) {
        final baseAngle =
            (i / count) * twoPi + timeValue * speed * twoPi + phase;

        // ── Head particle ────────────────────────────────────────────────
        final ex = _cos(baseAngle) * ringR;
        final ey = _sin(baseAngle) * ringR * cosTilt;

        // Depth: +1 = closest (bottom), -1 = farthest (top)
        final depth = _sin(baseAngle) * 0.5 + 0.5; // 0→1
        final dotR  = baseRad * (0.45 + depth * 0.55);
        final opacity = 0.25 + depth * 0.75;

        _drawDot(canvas, cx + ex, cy + ey, dotR, opacity);

        // ── Comet trail ──────────────────────────────────────────────────
        for (int tr = 1; tr <= trailSteps; tr++) {
          final ta = baseAngle - tr * trailAngleStep;
          final tex = _cos(ta) * ringR;
          final tey = _sin(ta) * ringR * cosTilt;
          final tDepth = _sin(ta) * 0.5 + 0.5;
          final tDotR  = baseRad * (0.45 + tDepth * 0.55) * (1.0 - tr * 0.18);
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
      final nn   = pts[(i + 2) % n];
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
// YouTube Audio / Video tab pill — shown in the NowPlayingScreen top bar
// only when the current song is a YouTube song (id starts with "yt:").
// Looks and feels like the equivalent control in YouTube Music.
// ─────────────────────────────────────────────────────────────────────────────
class _YtMediaTabPill extends StatelessWidget {
  final bool videoMode;
  final VoidCallback onAudio;
  final VoidCallback onVideo;

  const _YtMediaTabPill({
    required this.videoMode,
    required this.onAudio,
    required this.onVideo,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.15), width: 1),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Pill(
            label: 'Audio',
            icon: Icons.audiotrack_rounded,
            selected: !videoMode,
            onTap: onAudio,
          ),
          _Pill(
            label: 'Video',
            icon: Icons.videocam_rounded,
            selected: videoMode,
            selectedColor: Colors.redAccent,
            onTap: onVideo,
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onTap;

  const _Pill({
    required this.label,
    required this.icon,
    required this.selected,
    this.selectedColor = TaarColors.marigold,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? selectedColor.withOpacity(0.9) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: selectedColor.withOpacity(0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
                ]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: selected ? Colors.white : Colors.white.withOpacity(0.6),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white.withOpacity(0.6),
                fontSize: 11.5,
                fontWeight:
                    selected ? FontWeight.w700 : FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}