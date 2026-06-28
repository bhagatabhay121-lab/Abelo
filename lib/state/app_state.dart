import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:flutter_audio_tagger/flutter_audio_tagger.dart';
import 'package:flutter_audio_tagger/tag.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:home_widget/home_widget.dart';
import '../api/saavn_api.dart';
import '../services/speed_dial_service.dart';
import '../services/local_music_service.dart';
import '../services/lock_screen_service.dart';
import '../models/song.dart';
import '../screens/youtube_screen.dart' show YtApi, YtVideo, parseYtDuration;
import '../services/youtube_service.dart';

// ============================================================
// Playlist model
// ============================================================
class TaarPlaylist {
  String id;
  String name;
  List<Song> songs;
  DateTime createdAt;

  TaarPlaylist({
    required this.id,
    required this.name,
    required this.songs,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'songs': songs.map((s) => s.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory TaarPlaylist.fromJson(Map<String, dynamic> json) => TaarPlaylist(
        id: json['id'],
        name: json['name'],
        songs: (json['songs'] as List)
            .map((e) => Song.fromCache(Map<String, dynamic>.from(e)))
            .toList(),
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt']) ?? DateTime.now()
            : DateTime.now(),
      );
}

/// A simple mutable time range, used to track which portions of a song
/// have actually been heard (for Speed Dial's seek-aware completion tracking).
class _PlayRange {
  Duration start;
  Duration end;
  _PlayRange(this.start, this.end);
}

enum TaarRepeatMode { off, all, one }

/// Represents the download state of a single song.
enum DownloadStatus { idle, downloading, done, error }

class DownloadState {
  final DownloadStatus status;
  final double progress; // 0.0 – 1.0
  final String? filePath;
  final String? artPath; // sidecar .jpg cover art path
  final String? error;

  const DownloadState({
    this.status = DownloadStatus.idle,
    this.progress = 0,
    this.filePath,
    this.artPath,
    this.error,
  });

  DownloadState copyWith({
    DownloadStatus? status,
    double? progress,
    String? filePath,
    String? artPath,
    String? error,
  }) =>
      DownloadState(
        status: status ?? this.status,
        progress: progress ?? this.progress,
        filePath: filePath ?? this.filePath,
        artPath: artPath ?? this.artPath,
        error: error ?? this.error,
      );
}

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  late SaavnApi api;
  final AudioPlayer player = AudioPlayer();
  final SpeedDialService speedDial = SpeedDialService();
  final LocalMusicService localMusic = LocalMusicService();

  bool _isLocalSong(Song song) => song.id.startsWith('local:');

  // FIX: Use a single ConcatenatingAudioSource so the notification system
  // knows the total queue length and properly shows/hides skip next/prev buttons.
  final _playlist = ConcatenatingAudioSource(children: []);

  // ---- Settings ----
  String quality = '160kbps';
  String themeMode = 'dark';
  String language = 'hindi';
  bool autoplay = true;

  // ---- Onboarding / greeting ----
  String username = '';
  bool restored = false;

  // ---- Queue / playback state ----
  List<Song> queue = [];
  List<Song> _originalQueue = []; // for un-shuffle
  int currentIndex = -1;
  bool isShuffled = false;
  TaarRepeatMode repeatMode = TaarRepeatMode.off;
  bool isLoadingTrack = false;

  // ---- Last-played session restore ----
  Song? _pendingRestoreSong;
  Duration _pendingRestorePosition = Duration.zero;
  DateTime? _lastSessionSaveAt;

  // ---- Recommendations ----
  final Map<String, List<Song>> _relatedCache = {};
  final Map<String, Future<List<Song>>> _relatedInFlight = {};
  bool isFetchingMore = false;
  bool noMoreRecommendations = false;
  String? _noMoreRecoSeedId;
  String? _explicitSeedId;

  // ---- Internal flag to prevent concurrent play calls ----
  bool _isPlayingInProgress = false;

  // ---- Sleep timer ----
  Timer? _sleepTimer;
  DateTime? sleepTimerEndsAt;
  int? sleepAfterNSongs;

  // ---- Downloads ----
  final Map<String, DownloadState> _downloads = {};
  final _dio = Dio();
  final Map<String, CancelToken> _cancelTokens = {};

  // ---- Widget position throttle ----
  DateTime? _lastWidgetPositionUpdateAt;

  DownloadState downloadState(String songId) =>
      _downloads[songId] ?? const DownloadState();

  bool isDownloaded(String songId) =>
      _downloads[songId]?.status == DownloadStatus.done;

  Set<String> get downloadedFilePaths => {
        for (final entry in _downloads.entries)
          if (entry.value.status == DownloadStatus.done &&
              entry.value.filePath != null)
            entry.value.filePath!,
      };

  Song? get currentSong =>
      currentIndex >= 0 && currentIndex < queue.length ? queue[currentIndex] : null;

  // ---- Library ----
  final Set<String> likedIds = {};
  final Map<String, Song> likedSongs = {};
  final List<Song> recentlyPlayed = [];
  final List<TaarPlaylist> playlists = [];

  AppState() {
    api = SaavnApi();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _restore();
    await _initPlayer();
    _wirePlayerListeners();
    _listenToWidgetClicks();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveLastSession();
    }
    if (state == AppLifecycleState.detached) {
      player.pause();
    }
  }

  // ============================================================
  // Home Widget
  // ============================================================

  /// Listens for button-tap broadcasts from the home screen widget.
  void _listenToWidgetClicks() {
    HomeWidget.setAppGroupId('com.example.taar');
    _widgetClickSub = HomeWidget.widgetClicked.listen((Uri? uri) {
      if (uri == null) return;
      switch (uri.host) {
        case 'play_pause':
          if (player.playing) {
            player.pause();
          } else {
            player.play();
          }
          break;
        case 'prev':
          prevSong();
          break;
        case 'next':
          nextSong();
          break;
      }
    });
  }

  /// Called whenever the song or play/pause state changes.
  /// Saves ALL widget data including position + duration, then redraws.
  Future<void> updateHomeWidget() async {
    try {
      final song = currentSong;
      await HomeWidget.saveWidgetData<String>('widget_title',      song?.title  ?? '');
      await HomeWidget.saveWidgetData<String>('widget_artist',     song?.artist ?? '');
      await HomeWidget.saveWidgetData<String>('widget_image',      song?.image  ?? '');
      await HomeWidget.saveWidgetData<bool>  ('widget_is_playing', player.playing);
      // ← FIXED: save position & duration so progress bar is accurate
      await HomeWidget.saveWidgetData<int>   ('widget_position_ms', player.position.inMilliseconds);
      await HomeWidget.saveWidgetData<int>   ('widget_duration_ms', (player.duration ?? Duration.zero).inMilliseconds);
      await HomeWidget.updateWidget(androidName: 'com.example.taar.TaarWidgetProvider');
    } catch (e) {
      debugPrint('Home widget update failed: $e');
    }
  }

  /// Writes only position/duration prefs without a full widget redraw.
  /// Called every 5 s from _positionSub to keep the progress bar moving
  /// while the app is in the foreground — cheap, no bitmap reload.
  Future<void> _saveWidgetPosition() async {
    try {
      await HomeWidget.saveWidgetData<int>(
          'widget_position_ms', player.position.inMilliseconds);
      await HomeWidget.saveWidgetData<int>(
          'widget_duration_ms', (player.duration ?? Duration.zero).inMilliseconds);
      // No updateWidget() call here — Kotlin AlarmManager picks it up within 15 s.
    } catch (_) {}
  }

  // ============================================================
  // Player Initialization
  // ============================================================
  Future<void> _initPlayer() async {
    final restoredSong = _pendingRestoreSong;
    if (restoredSong != null) {
      queue = [restoredSong];
      _originalQueue = [restoredSong];
      currentIndex = 0;

      final source = AudioSource.uri(
        Uri.parse(restoredSong.mediaUrls[quality] ??
            restoredSong.mediaUrl ??
            restoredSong.previewUrl ??
            ''),
        headers: restoredSong.mediaHeaders,
        tag: MediaItem(
          id: restoredSong.id,
          title: restoredSong.title,
          artist: restoredSong.artist,
          album: restoredSong.album,
          artUri: restoredSong.image.isNotEmpty
              ? Uri.tryParse(restoredSong.image)
              : null,
          duration: restoredSong.durationSec > 0
              ? Duration(seconds: restoredSong.durationSec)
              : null,
        ),
      );
      await _playlist.add(source);

      notifyListeners();
      updateHomeWidget();

      try {
        await player.setAudioSource(
          _playlist,
          initialIndex: 0,
          initialPosition: _pendingRestorePosition,
        );
      } catch (e) {
        debugPrint('Restoring last session failed: $e');
      }

      if (!_isLocalSong(restoredSong)) {
        _maybePrefetchAhead();
      }
      _pendingRestoreSong = null;
      notifyListeners();
    } else {
      await player.setAudioSource(_playlist, initialIndex: 0, initialPosition: Duration.zero);
    }
  }

  // ============================================================
  // Persistence
  // ============================================================
  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    quality = prefs.getString('quality') ?? quality;
    themeMode = prefs.getString('themeMode') ?? themeMode;
    language = prefs.getString('language') ?? language;
    autoplay = prefs.getBool('autoplay') ?? autoplay;
    username = prefs.getString('username') ?? username;

    final likedJson = prefs.getString('likedSongs');
    if (likedJson != null) {
      final list = (jsonDecode(likedJson) as List);
      for (final e in list) {
        final s = Song.fromCache(Map<String, dynamic>.from(e));
        likedIds.add(s.id);
        likedSongs[s.id] = s;
      }
    }
    final recentJson = prefs.getString('recentlyPlayed');
    if (recentJson != null) {
      final list = (jsonDecode(recentJson) as List);
      recentlyPlayed
          .addAll(list.map((e) => Song.fromCache(Map<String, dynamic>.from(e))));
    }
    final playlistsJson = prefs.getString('playlists');
    if (playlistsJson != null) {
      final list = (jsonDecode(playlistsJson) as List);
      playlists.addAll(list.map((e) => TaarPlaylist.fromJson(Map<String, dynamic>.from(e))));
    }

    final lastSongJson = prefs.getString('lastSong');
    if (lastSongJson != null) {
      try {
        final song = Song.fromCache(
            Map<String, dynamic>.from(jsonDecode(lastSongJson)));
        if (song.id.isNotEmpty) {
          _pendingRestoreSong = song;
          final posMs = prefs.getInt('lastPositionMs') ?? 0;
          _pendingRestorePosition = Duration(milliseconds: posMs);
        }
      } catch (_) {}
    }

    restored = true;
    notifyListeners();
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('quality', quality);
    await prefs.setString('themeMode', themeMode);
    await prefs.setString('language', language);
    await prefs.setBool('autoplay', autoplay);
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'likedSongs',
        jsonEncode(
            likedSongs.values.map((s) => s.toJson()).toList()));
    await prefs.setString(
        'recentlyPlayed',
        jsonEncode(
            recentlyPlayed.take(15).map((s) => s.toJson()).toList()));
    await prefs.setString(
        'playlists',
        jsonEncode(playlists.map((p) => p.toJson()).toList()));
  }

  Future<void> _saveLastSession() async {
    final song = currentSong;
    if (song == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastSong', jsonEncode(song.toJson()));
      await prefs.setInt('lastPositionMs', player.position.inMilliseconds);
      _lastSessionSaveAt = DateTime.now();
    } catch (_) {}
  }

  void updateSettings({
    String? quality,
    String? themeMode,
    String? language,
    bool? autoplay,
  }) {
    if (quality != null) this.quality = quality;
    if (themeMode != null) this.themeMode = themeMode;
    if (language != null) this.language = language;
    if (autoplay != null) this.autoplay = autoplay;
    _saveSettings();
    notifyListeners();
  }

  // ============================================================
  // Playlist CRUD
  // ============================================================
  TaarPlaylist createPlaylist(String name) {
    final pl = TaarPlaylist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name.trim(),
      songs: [],
    );
    playlists.add(pl);
    _saveLibrary();
    notifyListeners();
    return pl;
  }

  void renamePlaylist(String playlistId, String newName) {
    final pl = playlists.firstWhere((p) => p.id == playlistId, orElse: () => throw Exception('Not found'));
    pl.name = newName.trim();
    _saveLibrary();
    notifyListeners();
  }

  void deletePlaylist(String playlistId) {
    playlists.removeWhere((p) => p.id == playlistId);
    _saveLibrary();
    notifyListeners();
  }

  void savePlaylists() {
    _saveLibrary();
    notifyListeners();
  }

  void addSongToPlaylist(String playlistId, Song song) {
    final pl = playlists.firstWhere((p) => p.id == playlistId, orElse: () => throw Exception('Not found'));
    if (!pl.songs.any((s) => s.id == song.id)) {
      pl.songs.add(song);
      _saveLibrary();
      notifyListeners();
    }
  }

  void removeSongFromPlaylist(String playlistId, String songId) {
    final pl = playlists.firstWhere((p) => p.id == playlistId, orElse: () => throw Exception('Not found'));
    pl.songs.removeWhere((s) => s.id == songId);
    _saveLibrary();
    notifyListeners();
  }

  bool isSongInPlaylist(String playlistId, String songId) {
    try {
      final pl = playlists.firstWhere((p) => p.id == playlistId);
      return pl.songs.any((s) => s.id == songId);
    } catch (_) {
      return false;
    }
  }

  Future<void> setUsername(String name) async {
    username = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', username);
    notifyListeners();
  }

  // ============================================================
  // Library actions
  // ============================================================
  bool isLiked(String songId) => likedIds.contains(songId);

  void toggleLike(Song song) {
    if (likedIds.contains(song.id)) {
      likedIds.remove(song.id);
      likedSongs.remove(song.id);
    } else {
      likedIds.add(song.id);
      likedSongs[song.id] = song;
    }
    _saveLibrary();
    notifyListeners();
  }

  void _pushRecent(Song song) {
    recentlyPlayed.removeWhere((s) => s.id == song.id);
    recentlyPlayed.insert(0, song);
    if (recentlyPlayed.length > 15) {
      recentlyPlayed.removeRange(15, recentlyPlayed.length);
    }
    _saveLibrary();
    if (song.id.startsWith('yt:')) {
      _pushYtHistory(song);
    }
  }

  static const _kYtHistoryKey = 'yt_watch_history';

  Future<void> _pushYtHistory(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kYtHistoryKey) ?? [];
      final videoId = song.id.replaceFirst('yt:', '');
      raw.removeWhere((s) {
        try { return (jsonDecode(s) as Map)['id'] == videoId; } catch (_) { return false; }
      });
      raw.insert(0, jsonEncode({
        'id': videoId,
        'title': song.title,
        'channelName': song.artist,
        'thumbnail': song.image,
        'viewCount': '',
        'publishedAt': '',
        'duration': song.durationSec > 0
            ? 'PT${song.durationSec ~/ 60}M${song.durationSec % 60}S'
            : '',
      }));
      if (raw.length > 100) raw.removeLast();
      await prefs.setStringList(_kYtHistoryKey, raw);
    } catch (_) {}
  }

  // ============================================================
  // Player listeners
  // ============================================================
  Song? _trackingForSong;
  final List<_PlayRange> _coveredRanges = [];
  Duration? _lastTrackedPos;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Uri?>? _widgetClickSub;

  static const _kMaxNaturalForwardTick = Duration(seconds: 2);

  void _listenForCompletion() {
    final song = currentSong;
    if (song == null) return;
    _trackingForSong = song;
    _coveredRanges.clear();
    final pos = player.position;
    _coveredRanges.add(_PlayRange(pos, pos));
    _lastTrackedPos = pos;
  }

  void _onPositionTick(Duration pos) {
    if (_trackingForSong == null) return;
    final last = _lastTrackedPos;
    if (last == null) {
      _coveredRanges.add(_PlayRange(pos, pos));
      _lastTrackedPos = pos;
      return;
    }

    final delta = pos - last;
    final isNaturalPlayback =
        delta >= Duration.zero && delta <= _kMaxNaturalForwardTick;

    if (isNaturalPlayback) {
      final current = _coveredRanges.last;
      if (pos > current.end) current.end = pos;
    } else {
      _coveredRanges.add(_PlayRange(pos, pos));
    }
    _lastTrackedPos = pos;
  }

  double _coveredSeconds() {
    if (_coveredRanges.isEmpty) return 0;
    final sorted = List<_PlayRange>.from(_coveredRanges)
      ..sort((a, b) => a.start.compareTo(b.start));

    final merged = <_PlayRange>[];
    for (final r in sorted) {
      if (merged.isEmpty || r.start > merged.last.end) {
        merged.add(_PlayRange(r.start, r.end));
      } else if (r.end > merged.last.end) {
        merged.last.end = r.end;
      }
    }

    final totalMs =
        merged.fold<int>(0, (sum, r) => sum + (r.end - r.start).inMilliseconds);
    return totalMs / 1000.0;
  }

  void _maybeRecordCompletion() {
    final song = _trackingForSong;
    if (song == null) return;

    final coveredSec = _coveredSeconds();
    if (coveredSec > 0 && !_isLocalSong(song)) {
      speedDial.recordCompletion(song, coveredSec);
    }

    _trackingForSong = null;
    _coveredRanges.clear();
    _lastTrackedPos = null;
  }

  void _wirePlayerListeners() {
    player.currentIndexStream.listen((index) {
      if (index != null && index != currentIndex) {
        _maybeRecordCompletion();
        currentIndex = index;
        if (currentSong != null) {
          _pushRecent(currentSong!);
          if (!_isLocalSong(currentSong!)) speedDial.recordPlay(currentSong!);
          _listenForCompletion();
          _saveLastSession();
          updateHomeWidget(); // ← update widget on song change
        }
        notifyListeners();
      }
    });

    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        final dur = player.duration;
        if (dur != null && dur.inSeconds > 0) {
          _maybeRecordCompletion();
          _onTrackEnded();
        }
      }
    });

    player.playingStream.listen((playing) {
      if (!playing) _saveLastSession();
      if (Platform.isAndroid) {
        LockScreenService.instance.setPlaybackActive(playing);
      }
      updateHomeWidget(); // ← update widget on play/pause
      notifyListeners();
    });

    // ← FIXED: throttled position updates for progress bar
    _positionSub = player.positionStream.listen((pos) {
      _onPositionTick(pos);

      // Save session every 8 s (unchanged)
      final lastSave = _lastSessionSaveAt;
      if (lastSave == null ||
          DateTime.now().difference(lastSave) > const Duration(seconds: 8)) {
        _saveLastSession();
      }

      // Write position/duration to prefs every 5 s while playing.
      // The Kotlin AlarmManager polls every 15 s and reads these values
      // to update the progress bar — even when Flutter is backgrounded.
      if (player.playing) {
        final lastWPos = _lastWidgetPositionUpdateAt;
        if (lastWPos == null ||
            DateTime.now().difference(lastWPos) > const Duration(seconds: 5)) {
          _lastWidgetPositionUpdateAt = DateTime.now();
          _saveWidgetPosition();
        }
      }
    });
  }

  // ============================================================
  // Playback
  // ============================================================

  Future<void> playLocalSongs(List<LocalSong> localSongs, int startIndex) async {
    final songs = localSongs.map((ls) => ls.toSong()).toList();
    await setQueueAndPlay(songs, startIndex);
  }

  Future<void> setQueueAndPlay(List<Song> songs, int startIndex,
      {bool suppressAutoReco = false}) async {
    queue = List.of(songs);
    _originalQueue = List.of(songs);
    isShuffled = false;
    noMoreRecommendations = false;
    _noMoreRecoSeedId = null;

    final chosenSong = songs.isNotEmpty ? songs[startIndex] : null;
    _explicitSeedId = chosenSong?.id;
    _relatedCache.clear();
    _relatedInFlight.clear();
    await speedDial.clearMoodWindow();

    await setQueue(songs, startIndex: startIndex);
    if (!suppressAutoReco) _maybePrefetchAhead();
  }

  Future<void> setQueue(List<Song> songs, {int startIndex = 0}) async {
    queue = List.of(songs);
    currentIndex = startIndex;

    final sources = songs.map((s) => AudioSource.uri(
      Uri.parse(s.mediaUrls[quality] ?? s.mediaUrl ?? s.previewUrl ?? ''),
      headers: s.mediaHeaders,
      tag: MediaItem(
        id: s.id,
        title: s.title,
        artist: s.artist,
        album: s.album,
        artUri: s.image.isNotEmpty ? Uri.tryParse(s.image) : null,
        duration: s.durationSec > 0 ? Duration(seconds: s.durationSec) : null,
      ),
    )).toList();

    await _playlist.clear();
    await _playlist.addAll(sources);

    isLoadingTrack = true;
    _isPlayingInProgress = true;
    notifyListeners();

    try {
      await player.seek(Duration.zero, index: startIndex);
      isLoadingTrack = false;
      _isPlayingInProgress = false;
      notifyListeners();
      await player.play();
      if (currentSong != null) {
        _pushRecent(currentSong!);
        if (!_isLocalSong(currentSong!)) speedDial.recordPlay(currentSong!);
        _listenForCompletion();
        _saveLastSession();
        updateHomeWidget(); // ← update widget when new queue starts
      }
    } catch (e) {
      debugPrint('Playback failed: $e');
      isLoadingTrack = false;
      _isPlayingInProgress = false;
      notifyListeners();

      final hasNext = currentIndex + 1 < queue.length;
      if (hasNext) {
        await Future.delayed(const Duration(milliseconds: 300));
        final nextIdx = currentIndex + 1;
        currentIndex = nextIdx;
        notifyListeners();
        await player.seekToNext();
        await player.play();
      }
    }
  }

  Future<void> playByIndex(int index) async {
    if (index < 0 || index >= queue.length) return;
    if (_isPlayingInProgress) return;

    currentIndex = index;
    notifyListeners();

    isLoadingTrack = true;
    _isPlayingInProgress = true;
    notifyListeners();

    try {
      await player.seek(Duration.zero, index: index);
      isLoadingTrack = false;
      _isPlayingInProgress = false;
      notifyListeners();
      await player.play();
      if (currentSong != null) {
        _pushRecent(currentSong!);
        if (!_isLocalSong(currentSong!)) speedDial.recordPlay(currentSong!);
        _listenForCompletion();
        _saveLastSession();
        updateHomeWidget(); // ← update widget
      }
    } catch (e) {
      debugPrint('Playback failed: $e');
      isLoadingTrack = false;
      _isPlayingInProgress = false;
      notifyListeners();

      final hasNext = currentIndex + 1 < queue.length;
      if (hasNext) {
        await Future.delayed(const Duration(milliseconds: 300));
        final nextIdx = currentIndex + 1;
        currentIndex = nextIdx;
        notifyListeners();
        await player.seekToNext();
        await player.play();
      }
    }
    _maybePrefetchAhead();
  }

  Future<void> togglePlayPause() async {
    if (player.playing) {
      await player.pause();
    } else {
      await player.play();
    }
    notifyListeners();
  }

  Future<void> nextSong() async {
    if (queue.isEmpty) return;
    if (repeatMode == TaarRepeatMode.one) {
      await player.seek(Duration.zero);
      await player.play();
      return;
    }

    _isPlayingInProgress = false;

    int next = currentIndex + 1;
    if (next >= queue.length) {
      if (repeatMode == TaarRepeatMode.all) {
        next = 0;
      } else if (autoplay && currentSong != null) {
        await ensureRelatedFor(currentSong!);
        if (currentIndex + 1 >= queue.length) return;
      } else {
        return;
      }
    }

    await player.seekToNext();
    await player.play();
    _maybePrefetchAhead();
  }

  Future<void> prevSong() async {
    if (queue.isEmpty) return;
    if ((player.position.inSeconds) > 3) {
      await player.seek(Duration.zero);
      return;
    }

    _isPlayingInProgress = false;

    int prev = currentIndex - 1;
    if (prev < 0) {
      if (repeatMode == TaarRepeatMode.all) {
        prev = queue.length - 1;
      } else {
        await player.seek(Duration.zero);
        return;
      }
    }

    await player.seekToPrevious();
    await player.play();
  }

  Future<void> _onTrackEnded() async {
    if (sleepAfterNSongs != null) {
      sleepAfterNSongs = sleepAfterNSongs! - 1;
      if (sleepAfterNSongs! <= 0) {
        sleepAfterNSongs = null;
        player.pause();
        notifyListeners();
        return;
      }
      notifyListeners();
    }
    if (repeatMode == TaarRepeatMode.one) {
      await player.seek(Duration.zero);
      await player.play();
      return;
    }
    if (currentIndex + 1 < queue.length) {
      await nextSong();
    } else if (repeatMode == TaarRepeatMode.all && queue.isNotEmpty) {
      _isPlayingInProgress = false;
      await player.seek(Duration.zero, index: 0);
      await player.play();
    } else if (autoplay && currentSong != null) {
      await ensureRelatedFor(currentSong!);
      if (currentIndex + 1 < queue.length) {
        await nextSong();
      }
    }
  }

  // ============================================================
  // Recommendations
  // ============================================================
  Set<String> get _queuedIds => queue.map((s) => s.id).toSet();

  Future<List<Song>> ensureRelatedFor(Song song) {
    final cached = _relatedCache[song.id];
    if (cached != null) return Future.value(cached);
    final inFlight = _relatedInFlight[song.id];
    if (inFlight != null) return inFlight;

    final future = _fetchAndSpliceRelated(song);
    _relatedInFlight[song.id] = future;
    future.whenComplete(() => _relatedInFlight.remove(song.id));
    return future;
  }

  Future<List<Song>> _fetchAndSpliceRelated(Song song) async {
    List<Song> related = [];

    if (song.id.startsWith('yt:')) {
      try {
        final videoId = song.id.substring(3);
        final ytApi = YtApi();
        var candidates = await ytApi.suggestions(videoId, maxResults: 15);

        if (candidates.isEmpty) {
          final result = await ytApi.search(
            '${song.title} ${song.artist}',
            maxResults: 15,
          );
          candidates = result.videos.where((v) => v.id != videoId).toList();
        }

        final toTry = candidates.take(8).toList();
        final resolved = await Future.wait(toTry.map((v) async {
          try {
            final info = await YoutubeStreamService.getStreamInfo(v.id);
            final audioUrl = info.bestAudioUrl;
            if (audioUrl == null) return null;
            return Song(
              id: 'yt:${v.id}',
              title: v.title,
              artist: v.channelName,
              image: v.thumbnail,
              album: 'YouTube',
              durationSec: parseYtDuration(v.duration),
              mediaUrl: audioUrl,
              mediaHeaders: info.streamHeaders,
            );
          } catch (_) {
            return null;
          }
        }));

        related = resolved.whereType<Song>().toList();
      } catch (e) {
        debugPrint('YouTube related fetch failed: $e');
      }
    } else {
      try {
        final seedId = _explicitSeedId ?? speedDial.moodSeedId ?? song.id;
        _explicitSeedId = null;
        related = (await api.fetchReco(seedId))
            .where((s) => s.id.isNotEmpty && s.id != song.id)
            .toList();
      } catch (e) {
        debugPrint('Related songs fetch failed: $e');
      }
    }

    final songIdx = queue.indexWhere((s) => s.id == song.id);
    if (songIdx > -1 && related.isNotEmpty) {
      final seen = _queuedIds;
      final toInsert = <Song>[
        for (final s in related)
          if (seen.add(s.id)) s,
      ];
      if (toInsert.isNotEmpty) {
        queue.insertAll(songIdx + 1, toInsert);

        final sources = toInsert.map((s) => AudioSource.uri(
          Uri.parse(s.mediaUrls[quality] ?? s.mediaUrl ?? s.previewUrl ?? ''),
          headers: s.mediaHeaders,
          tag: MediaItem(
            id: s.id,
            title: s.title,
            artist: s.artist,
            album: s.album,
            artUri: s.image.isNotEmpty ? Uri.tryParse(s.image) : null,
            duration: s.durationSec > 0 ? Duration(seconds: s.durationSec) : null,
          ),
        )).toList();
        await _playlist.insertAll(songIdx + 1, sources);

        notifyListeners();
      }
    }

    _relatedCache[song.id] = related;
    return related;
  }

  void _maybePrefetchAhead() {
    if (!autoplay) return;
    final song = currentSong;
    if (song == null || queue.isEmpty) return;
    if (currentIndex >= queue.length - 2) {
      ensureRelatedFor(song);
    }
  }

  Future<void> extendQueueWithMoreReco() async {
    if (queue.isEmpty || isFetchingMore) return;
    final seed = queue.last;
    if (noMoreRecommendations && _noMoreRecoSeedId == seed.id) return;

    isFetchingMore = true;
    notifyListeners();
    try {
      final before = queue.length;
      await ensureRelatedFor(seed);
      if (queue.length == before) {
        noMoreRecommendations = true;
        _noMoreRecoSeedId = seed.id;
      } else {
        noMoreRecommendations = false;
        _noMoreRecoSeedId = null;
      }
    } finally {
      isFetchingMore = false;
      notifyListeners();
    }
  }

  void toggleShuffle() {
    isShuffled = !isShuffled;
    if (isShuffled) {
      _originalQueue = List.of(queue);
      final current = currentSong;
      final rest = List<Song>.of(queue)..removeAt(currentIndex);
      rest.shuffle();
      queue = [if (current != null) current, ...rest];
      currentIndex = 0;
    } else {
      final current = currentSong;
      queue = List.of(_originalQueue);
      if (current != null) {
        final idx = queue.indexWhere((s) => s.id == current.id);
        currentIndex = idx >= 0 ? idx : 0;
      }
    }
    notifyListeners();
  }

  void cycleRepeat() {
    repeatMode =
        TaarRepeatMode.values[(repeatMode.index + 1) % TaarRepeatMode.values.length];
    notifyListeners();
  }

  void playNext(Song song) {
    final insertAt = currentIndex > -1 ? currentIndex + 1 : queue.length;
    queue.insert(insertAt, song);

    final source = AudioSource.uri(
      Uri.parse(song.mediaUrls[quality] ?? song.mediaUrl ?? song.previewUrl ?? ''),
      headers: song.mediaHeaders,
      tag: MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        artUri: song.image.isNotEmpty ? Uri.tryParse(song.image) : null,
        duration: song.durationSec > 0 ? Duration(seconds: song.durationSec) : null,
      ),
    );
    _playlist.insert(insertAt, source);

    notifyListeners();
  }

  void addToQueueEnd(Song song) {
    queue.add(song);

    final source = AudioSource.uri(
      Uri.parse(song.mediaUrls[quality] ?? song.mediaUrl ?? song.previewUrl ?? ''),
      headers: song.mediaHeaders,
      tag: MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        artUri: song.image.isNotEmpty ? Uri.tryParse(song.image) : null,
        duration: song.durationSec > 0 ? Duration(seconds: song.durationSec) : null,
      ),
    );
    _playlist.add(source);

    notifyListeners();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= queue.length) return;
    if (newIndex < 0 || newIndex > queue.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final movingCurrent = oldIndex == currentIndex;
    final song = queue.removeAt(oldIndex);
    queue.insert(newIndex, song);
    if (movingCurrent) {
      currentIndex = newIndex;
    } else if (oldIndex < currentIndex && newIndex >= currentIndex) {
      currentIndex -= 1;
    } else if (oldIndex > currentIndex && newIndex <= currentIndex) {
      currentIndex += 1;
    }
    notifyListeners();
  }

  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= queue.length) return;
    if (index == currentIndex) return;
    queue.removeAt(index);
    if (index < currentIndex) currentIndex -= 1;
    notifyListeners();
    try {
      await _playlist.removeAt(index);
    } catch (e) {
      debugPrint('removeFromQueue: failed to update audio source: $e');
    }
  }

  // ============================================================
  // Sleep timer
  // ============================================================
  void setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    sleepAfterNSongs = null;
    sleepTimerEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      player.pause();
      sleepTimerEndsAt = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void setSleepAfterNSongs(int n) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepTimerEndsAt = null;
    sleepAfterNSongs = n;
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepTimerEndsAt = null;
    sleepAfterNSongs = null;
    notifyListeners();
  }

  // ============================================================
  // Downloads
  // ============================================================

  Future<void> downloadSong(Song song) async {
    final songId = song.id;
    if (_downloads[songId]?.status == DownloadStatus.downloading) return;
    if (_downloads[songId]?.status == DownloadStatus.done) return;

    String? url = song.mediaUrls[quality] ?? song.mediaUrl;
    if (url == null || url.isEmpty) {
      try {
        final data = await api.fetchSongUrl(songId, quality: quality);
        if (data['status']?.toString() == 'success') {
          url = data['media_url']?.toString();
        }
      } catch (_) {}
    }
    url ??= song.previewUrl;
    if (url == null || url.isEmpty) {
      _downloads[songId] = const DownloadState(
          status: DownloadStatus.error, error: 'No URL available');
      notifyListeners();
      return;
    }

    final safeTitle = song.title.replaceAll(RegExp(r'[\/\:*?"<>|]'), '_');
    final publicMusicDir = Directory('/storage/emulated/0/Music');
    await publicMusicDir.create(recursive: true);
    final filePath = '${publicMusicDir.path}/$safeTitle.m4a';

    _downloads[songId] = const DownloadState(
        status: DownloadStatus.downloading, progress: 0);
    notifyListeners();

    final cancelToken = CancelToken();
    _cancelTokens[songId] = cancelToken;

    try {
      await _dio.download(
        url,
        filePath,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = received / total;
            _downloads[songId] = DownloadState(
                status: DownloadStatus.downloading, progress: progress);
            notifyListeners();
          }
        },
      );

      Uint8List? artBytes;
      if (song.image.isNotEmpty) {
        try {
          final artResp = await _dio.get<List<int>>(
            song.image,
            options: Options(responseType: ResponseType.bytes),
          );
          if (artResp.data != null && artResp.data!.isNotEmpty) {
            artBytes = Uint8List.fromList(artResp.data!);
          }
        } catch (_) {}
      }

      String? artPath;
      try {
        final tagger = FlutterAudioTagger();
        await tagger.editTags(
          Tag(
            title: song.title,
            artist: song.artist,
            album: song.album ?? '',
            year: null,
            genre: null,
            language: song.language,
            composer: null,
            country: null,
            quality: quality,
            lyrics: null,
            artwork: null,
          ),
          filePath,
        );
        if (artBytes != null) {
          await tagger.setArtWork(artBytes, filePath);
        }
      } catch (_) {}

      if (artBytes != null) {
        try {
          final artFile = File('${publicMusicDir.path}/$safeTitle.jpg');
          await artFile.writeAsBytes(artBytes);
          artPath = artFile.path;
        } catch (_) {}
      }

      _downloads[songId] =
          DownloadState(status: DownloadStatus.done, filePath: filePath, artPath: artPath, progress: 1.0);
      notifyListeners();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _downloads[songId] = const DownloadState(status: DownloadStatus.idle);
      } else {
        _downloads[songId] = DownloadState(
            status: DownloadStatus.error, error: e.message ?? 'Download failed');
      }
      notifyListeners();
    } finally {
      _cancelTokens.remove(songId);
    }
  }

  void cancelDownload(String songId) {
    _cancelTokens[songId]?.cancel('User cancelled');
    _cancelTokens.remove(songId);
  }

  // ============================================================
  // YouTube Video Download
  // ============================================================

  Future<void> downloadYoutubeVideo(Song song) async {
    if (!song.id.startsWith('yt:')) return;
    final videoId = song.id.substring(3);
    final dlKey = '${song.id}_video';

    if (_downloads[dlKey]?.status == DownloadStatus.downloading) return;
    if (_downloads[dlKey]?.status == DownloadStatus.done) return;

    _downloads[dlKey] = const DownloadState(
        status: DownloadStatus.downloading, progress: 0);
    notifyListeners();

    try {
      final info = await YoutubeStreamService.getStreamInfo(videoId);
      final videoUrl = info.muxed.isNotEmpty
          ? info.muxed.first.url
          : info.bestVideoUrl;

      if (videoUrl == null || videoUrl.isEmpty) {
        _downloads[dlKey] = const DownloadState(
            status: DownloadStatus.error, error: 'No video stream available');
        notifyListeners();
        return;
      }

      final safeTitle = song.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final publicMoviesDir = Directory('/storage/emulated/0/Movies/Taar');
      await publicMoviesDir.create(recursive: true);
      final filePath = '${publicMoviesDir.path}/$safeTitle.mp4';

      final cancelToken = CancelToken();
      _cancelTokens[dlKey] = cancelToken;

      final headers = info.streamHeaders ?? {};

      await _dio.download(
        videoUrl,
        filePath,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          headers: headers,
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            _downloads[dlKey] = DownloadState(
                status: DownloadStatus.downloading,
                progress: received / total);
            notifyListeners();
          }
        },
      );

      _downloads[dlKey] = DownloadState(
          status: DownloadStatus.done,
          filePath: filePath,
          progress: 1.0);
      notifyListeners();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _downloads[dlKey] = const DownloadState(status: DownloadStatus.idle);
      } else {
        _downloads[dlKey] = DownloadState(
            status: DownloadStatus.error,
            error: e.message ?? 'Video download failed');
      }
      notifyListeners();
    } catch (e) {
      _downloads[dlKey] = DownloadState(
          status: DownloadStatus.error, error: e.toString());
      notifyListeners();
    } finally {
      _cancelTokens.remove(dlKey);
    }
  }

  DownloadState videoDownloadState(String songId) =>
      _downloads['${songId}_video'] ?? const DownloadState();


  bool isVideoDownloaded(String songId) =>
      _downloads['${songId}_video']?.status == DownloadStatus.done;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _widgetClickSub?.cancel();
    super.dispose();
  }
}