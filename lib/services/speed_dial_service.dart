import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Scoring constants
// ─────────────────────────────────────────────────────────────────────────────

/// Divisor that converts net seconds heard into points.
///   points = netSecondsHeard / _kSecondsPerPoint
/// Example: user listens 90 s (seek-adjusted) → 90 / 10 = 9.0 pts
const _kSecondsPerPoint   = 10;

const _kPlayPts           = 0.0;   // bonus per play-start (currently 0)
const _kMaxDialSlots      = 18;    // max cards shown

// Decay constants
const _kDecayGraceDays    = 7;     // days before decay begins
const _kDecayPerDay       = 20;  // points removed per day after grace period

// ─────────────────────────────────────────────────────────────────────────────
// A single dated point event — one row per listening session
// ─────────────────────────────────────────────────────────────────────────────
class PointEvent {
  final DateTime date;   // UTC day this was earned
  final double   points; // raw points earned that session

  const PointEvent({required this.date, required this.points});

  Map<String, dynamic> toJson() => {
    'date'  : date.toIso8601String(),
    'points': points,
  };

  factory PointEvent.fromJson(Map<String, dynamic> j) => PointEvent(
    date  : DateTime.parse(j['date'] as String),
    points: (j['points'] as num).toDouble(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-song stats — now event-sourced with decay
// ─────────────────────────────────────────────────────────────────────────────
class SongStats {
  final String       songId;
  int                plays;
  final List<PointEvent> events; // every earning event, oldest → newest
  DateTime?          lastPlayed;

  SongStats({
    required this.songId,
    this.plays        = 0,
    List<PointEvent>? events,
    this.lastPlayed,
  }) : events = events ?? [];

  // ── Point accounting ───────────────────────────────────────────────────────

  /// Total points earned (sum of all events, ignoring decay).
  double get totalEarned => events.fold(0.0, (s, e) => s + e.points);

  /// Effective score today, applying day-level decay to each event
  /// individually.
  ///
  /// Each event contributes:
  ///   effectivePoints = max(0, rawPoints - _kDecayPerDay × max(0, daysOld - _kDecayGraceDays))
  ///
  /// Events that have fully decayed contribute 0 and are pruned on next save.
  double get score {
    final now = _utcDay(DateTime.now());
    double total = 0.0;
    for (final e in events) {
      final daysOld = now.difference(_utcDay(e.date)).inDays;
      final decay   = _kDecayPerDay * (daysOld - _kDecayGraceDays).clamp(0, double.infinity);
      final effective = (e.points - decay).clamp(0.0, double.infinity);
      total += effective;
    }
    return total;
  }

  /// True if every event has decayed to zero — caller should remove this song.
  bool get fullyDecayed => score == 0.0 && events.isNotEmpty;

  /// Remove events whose effective contribution is already 0 to keep storage lean.
  void pruneDecayed() {
    final now = _utcDay(DateTime.now());
    events.removeWhere((e) {
      final daysOld = now.difference(_utcDay(e.date)).inDays;
      final decay   = _kDecayPerDay * (daysOld - _kDecayGraceDays).clamp(0, double.infinity);
      return (e.points - decay) <= 0.0;
    });
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'songId'    : songId,
    'plays'     : plays,
    'events'    : events.map((e) => e.toJson()).toList(),
    'lastPlayed': lastPlayed?.toIso8601String(),
  };

  factory SongStats.fromJson(Map<String, dynamic> j) => SongStats(
    songId    : j['songId'] as String,
    plays     : (j['plays'] as int?) ?? 0,
    events    : (j['events'] as List? ?? [])
        .map((e) => PointEvent.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    lastPlayed: j['lastPlayed'] != null
        ? DateTime.tryParse(j['lastPlayed'] as String)
        : null,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper — truncate DateTime to UTC date only (midnight)
// ─────────────────────────────────────────────────────────────────────────────
DateTime _utcDay(DateTime dt) => DateTime.utc(dt.year, dt.month, dt.day);

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────
class SpeedDialService extends ChangeNotifier {
  static const _prefsKey  = 'speed_dial_stats';
  static const _songsKey  = 'speed_dial_songs';
  static const _windowKey = 'speed_dial_window';

  // ── Sliding window constants ───────────────────────────────────────────────
  static const _kWindowSize = 8; // recent songs for mood seed

  final Map<String, SongStats> _stats      = {};
  final Map<String, Song>      _songCache  = {};
  final List<Map<String, dynamic>> _recentWindow = [];

  List<Song> _dialSongs = [];
  /// JioSaavn-only Speed Dial songs (excludes YouTube tracks).
  List<Song> get dialSongs => _dialSongs.where((s) => !s.id.startsWith('yt:')).toList();

  /// Top 30 songs by score (pool for Quick Pick random selection).
  List<Song> _top30Songs = [];

  /// Returns a shuffled selection of up to 16 JioSaavn songs drawn randomly
  /// from the top 30 scored songs. YouTube tracks are excluded.
  List<Song> get quickPickSongs {
    final saavnTop = _top30Songs.where((s) => !s.id.startsWith('yt:')).toList();
    if (saavnTop.isEmpty) return [];
    final pool = List<Song>.from(saavnTop);
    pool.shuffle(Random());
    return pool.take(16).toList();
  }

  // ── YouTube-specific getters (yt: prefix) ─────────────────────────────────

  /// Speed Dial songs sourced only from YouTube play history (id starts with 'yt:').
  List<Song> get ytDialSongs =>
      _dialSongs.where((s) => s.id.startsWith('yt:')).toList();

  /// Quick Pick songs sourced only from YouTube play history.
  List<Song> get ytQuickPickSongs {
    final ytTop = _top30Songs.where((s) => s.id.startsWith('yt:')).toList();
    if (ytTop.isEmpty) return [];
    final pool = List<Song>.from(ytTop);
    pool.shuffle(Random());
    return pool.take(16).toList();
  }

  SpeedDialService() {
    _restore();
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();

    final statsJson = prefs.getString(_prefsKey);
    if (statsJson != null) {
      final list = jsonDecode(statsJson) as List;
      for (final e in list) {
        final s = SongStats.fromJson(Map<String, dynamic>.from(e as Map));
        _stats[s.songId] = s;
      }
    }

    final songsJson = prefs.getString(_songsKey);
    if (songsJson != null) {
      final list = jsonDecode(songsJson) as List;
      for (final e in list) {
        final song = Song.fromCache(Map<String, dynamic>.from(e as Map));
        _songCache[song.id] = song;
      }
    }

    final windowJson = prefs.getString(_windowKey);
    if (windowJson != null) {
      final list = jsonDecode(windowJson) as List;
      _recentWindow.addAll(
        list.map((e) => Map<String, dynamic>.from(e as Map)),
      );
    }

    _decayAndPrune(); // run decay on restore so stale data is cleaned up immediately
    _rebuild();
    notifyListeners();
  }

  Future<void> _persist() async {
    // Prune fully-decayed songs before saving to keep storage lean
    _decayAndPrune();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey,
        jsonEncode(_stats.values.map((s) => s.toJson()).toList()));
    await prefs.setString(
        _songsKey,
        jsonEncode(_songCache.values.map((s) => s.toJson()).toList()));
    await prefs.setString(_windowKey, jsonEncode(_recentWindow));
  }

  // ── Decay & pruning ───────────────────────────────────────────────────────

  /// Prunes zero-contribution events inside each song, then removes songs
  /// whose total effective score has hit 0.
  void _decayAndPrune() {
    final deadSongs = <String>[];

    for (final entry in _stats.entries) {
      entry.value.pruneDecayed();
      if (entry.value.events.isEmpty) {
        deadSongs.add(entry.key);
      }
    }

    for (final id in deadSongs) {
      _stats.remove(id);
      _songCache.remove(id);
    }
  }

  // ── Core tracking API ─────────────────────────────────────────────────────

  /// Call this whenever a song starts playing.
  void recordPlay(Song song) {
    _songCache[song.id] = song;
    final stats = _ensureStats(song.id);
    stats.plays++;
    stats.lastPlayed = DateTime.now();
    // play-start earns _kPlayPts; skip event if 0 to avoid clutter
    if (_kPlayPts > 0) {
      stats.events.add(PointEvent(date: DateTime.now(), points: _kPlayPts));
    }
    _rebuild();
    notifyListeners();
    _persist();
  }

  /// Call with the net seconds the user actually heard (seek-adjusted).
  /// The caller ([AppState._maybeRecordCompletion]) already computes this
  /// via merged [_coveredRanges], so no further adjustment is needed here.
  ///
  ///   points = netSecondsHeard / _kSecondsPerPoint
  ///
  /// Duration doesn't matter — a 10-min song and a 2-min song earn the same
  /// points for the same number of seconds genuinely listened.
  void recordCompletion(Song song, double netSecondsHeard) {
    _songCache[song.id] = song;
    final stats  = _ensureStats(song.id);
    stats.lastPlayed = DateTime.now();

    final earned = (netSecondsHeard.clamp(0.0, double.infinity)) / _kSecondsPerPoint;

    if (earned > 0) {
      stats.events.add(PointEvent(date: DateTime.now(), points: earned));
    }

    // ── Update mood window ────────────────────────────────────────────────
    // Only count songs the user genuinely listened to — skip anything under
    // 40 net seconds (seek-adjusted) so skipped or accidentally-opened songs
    // don't influence the reco seed.
    if (netSecondsHeard >= 40.0) {
      _recentWindow.removeWhere((e) => e['songId'] == song.id);
      _recentWindow.add({
        'songId'      : song.id,
        'netSeconds'  : netSecondsHeard,
        'playedAt'    : DateTime.now().toIso8601String(),
      });
      if (_recentWindow.length > _kWindowSize) {
        _recentWindow.removeAt(0);
      }
    }

    _rebuild();
    notifyListeners();
    _persist();
  }

  SongStats _ensureStats(String id) =>
      _stats.putIfAbsent(id, () => SongStats(songId: id));

  void _rebuild() {
    final scored = _stats.entries
        .where((e) => _songCache.containsKey(e.key) && e.value.score > 0)
        .map((e) => MapEntry(_songCache[e.key]!, e.value.score))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    _dialSongs   = scored.take(_kMaxDialSlots).map((e) => e.key).toList();
    _top30Songs  = scored.take(40).map((e) => e.key).toList();
  }

  SongStats? statsFor(String songId) => _stats[songId];

  // ── Mood-aware reco seed (sliding window) ─────────────────────────────────

  String? get moodSeedId {
    if (_recentWindow.isEmpty) return null;

    final n = _recentWindow.length;
    String? bestId;
    double  bestScore = -1;

    for (int i = 0; i < n; i++) {
      final entry      = _recentWindow[i];
      final songId     = entry['songId'] as String;
      // netSeconds replaces the old completion fraction; cap at 600s (10 min)
      // so an unusually long song doesn't dominate the seed selection.
      final netSec     = ((entry['netSeconds'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 600.0);
      final recencyWeight = (i + 1) / n;
      final score = netSec * recencyWeight;

      if (score > bestScore) {
        bestScore = score;
        bestId    = songId;
      }
    }

    return bestId;
  }

  // ── Debug helper ──────────────────────────────────────────────────────────

  /// Returns a human-readable breakdown of a song's point history + decay.
  ///
  /// 1 pt = 10 seconds of net (seek-adjusted) listening.
  String debugSummary(String songId) {
    final stats = _stats[songId];
    if (stats == null) return 'No data for $songId';

    final now    = _utcDay(DateTime.now());
    final buffer = StringBuffer();
    buffer.writeln('Song: $songId');
    buffer.writeln('Plays: ${stats.plays}');
    buffer.writeln('Total earned (undecayed): ${stats.totalEarned.toStringAsFixed(2)} pts');
    buffer.writeln('Effective score (after decay): ${stats.score.toStringAsFixed(2)} pts');
    buffer.writeln('Events (1 pt = $_kSecondsPerPoint s of net listening):');

    for (final e in stats.events) {
      final daysOld = now.difference(_utcDay(e.date)).inDays;
      final decay   = _kDecayPerDay * (daysOld - _kDecayGraceDays).clamp(0, double.infinity);
      final eff     = (e.points - decay).clamp(0.0, double.infinity);
      buffer.writeln(
        '  ${e.date.toLocal().toString().substring(0, 10)}'
        '  earned=${e.points.toStringAsFixed(2)}'
        '  age=${daysOld}d'
        '  decay=${decay.toStringAsFixed(2)}'
        '  effective=${eff.toStringAsFixed(2)}',
      );
    }
    return buffer.toString();
  }

  // ── Clear all ─────────────────────────────────────────────────────────────

  /// Immediately seeds the mood window with [song] without requiring
  /// real listen time. Used when user explicitly taps a song from search
  /// so scroll-based reco can use mood from the very first extend call.
  /// Uses a nominal netSeconds of 60 so it scores above the 40s threshold
  /// but doesn't dominate a window full of real listens.
  void seedMoodWindow(Song song) {
    _songCache[song.id] = song;
    _recentWindow.removeWhere((e) => e['songId'] == song.id);
    _recentWindow.add({
      'songId'    : song.id,
      'netSeconds': 60.0,
      'playedAt'  : DateTime.now().toIso8601String(),
    });
    if (_recentWindow.length > _kWindowSize) _recentWindow.removeAt(0);
    _persist();
  }

  /// Resets only the recent-play window used for mood-aware seed selection.
  /// Call this whenever the user makes an explicit song/queue choice so that
  /// the next reco cycle starts fresh from the newly-chosen song instead of
  /// being dominated by whatever was in the old window.
  /// Stats and scores are preserved.
  Future<void> clearMoodWindow() async {
    _recentWindow.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_windowKey);
    // No notifyListeners() needed — callers don't observe the window directly.
  }

  Future<void> clearAll() async {
    _stats.clear();
    _songCache.clear();
    _recentWindow.clear();
    _dialSongs = [];
    _top30Songs = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    await prefs.remove(_songsKey);
    await prefs.remove(_windowKey);
    notifyListeners();
  }
}