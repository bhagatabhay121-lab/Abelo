import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import '../theme.dart';
import '../models/song.dart';
import '../state/app_state.dart';
import '../services/youtube_service.dart';
import '../services/speed_dial_service.dart';
import '../widgets/speed_dial_widget.dart';
import 'now_playing_screen.dart';
import '../widgets/mini_player.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Parse ISO 8601 duration like PT4M13S → total seconds.
int parseYtDuration(String iso) {
  if (iso.isEmpty) return 0;
  final h = int.tryParse(RegExp(r'(\d+)H').firstMatch(iso)?.group(1) ?? '0') ?? 0;
  final m = int.tryParse(RegExp(r'(\d+)M').firstMatch(iso)?.group(1) ?? '0') ?? 0;
  final s = int.tryParse(RegExp(r'(\d+)S').firstMatch(iso)?.group(1) ?? '0') ?? 0;
  return h * 3600 + m * 60 + s;
}

/// Minimum duration (seconds) a video must have to be shown anywhere in the
/// app. Videos shorter than this are reels, intros, or interstitials — not
/// full songs. Applied in the API layer so every surface is covered at once.
const int kMinTrackSeconds = 80;

/// Returns true if [v] is too short to be a real track and should be hidden.
/// When [v.duration] is empty (stub or unresolved) we let it through so we
/// don't accidentally hide videos whose metadata hasn't loaded yet.
bool isShortVideo(YtVideo v) {
  if (v.duration.isEmpty) return false;
  return parseYtDuration(v.duration) < kMinTrackSeconds;
}

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

class YtVideo {
  final String id;
  final String title;
  final String channelName;
  final String thumbnail;
  final String viewCount;
  final String publishedAt;
  final String duration; // e.g. "PT3M45S" from API

  const YtVideo({
    required this.id,
    required this.title,
    required this.channelName,
    required this.thumbnail,
    required this.viewCount,
    required this.publishedAt,
    this.duration = '',
  });

  factory YtVideo.fromSearchItem(Map<String, dynamic> item) {
    final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
    final id = (item['id'] is Map)
        ? (item['id']['videoId'] ?? '')
        : (item['id'] ?? '');
    final thumbs = snippet['thumbnails'] as Map<String, dynamic>? ?? {};
    final thumb =
        ((thumbs['maxres'] ?? thumbs['high'] ?? thumbs['medium'] ?? thumbs['default'])
            as Map<String, dynamic>?)?['url'] as String? ?? '';
    return YtVideo(
      id: id.toString(),
      title: snippet['title'] as String? ?? '',
      channelName: snippet['channelTitle'] as String? ?? '',
      thumbnail: thumb,
      viewCount: _formatViews((item['statistics'] as Map?)?['viewCount']?.toString()),
      publishedAt: snippet['publishedAt'] as String? ?? '',
      duration: (item['contentDetails'] as Map?)?['duration'] as String? ?? '',
    );
  }

  static String _formatViews(String? raw) {
    if (raw == null) return '';
    final n = int.tryParse(raw) ?? 0;
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M views';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}K views';
    return '$n views';
  }

  /// Parse ISO 8601 duration like PT4M13S → "4:13"
  String get durationFormatted {
    if (duration.isEmpty) return '';
    final h = RegExp(r'(\d+)H').firstMatch(duration)?.group(1);
    final m = RegExp(r'(\d+)M').firstMatch(duration)?.group(1);
    final s = RegExp(r'(\d+)S').firstMatch(duration)?.group(1);
    final mm = (m ?? '0').padLeft(h != null ? 2 : 1, '0');
    final ss = (s ?? '0').padLeft(2, '0');
    return h != null ? '$h:$mm:$ss' : '$mm:$ss';
  }

  String get timeAgo {
    if (publishedAt.isEmpty) return '';
    final dt = DateTime.tryParse(publishedAt);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 365) return '${(diff.inDays / 365).floor()}y ago';
    if (diff.inDays > 30) return '${(diff.inDays / 30).floor()}mo ago';
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    return '${diff.inMinutes}m ago';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// YouTube Data API v3 helper
// ─────────────────────────────────────────────────────────────────────────────

const _kYtApiKey = 'AIzaSyB5b818f0KATngTdLCcBlwyXlxxsKKcJoI';

/// YouTube Music official channel — the single source of truth for the
/// YouTube tab's home feed. Mirrors main.py's `CHANNEL_ID`.
const String kYtMusicChannelId = 'UC-9-kyTW8ZkZNDHQJ6FgpwQ';

// ─────────────────────────────────────────────────────────────────────────────
// India filter — manual keyword list based on observed playlist titles.
// A playlist passes if its title contains ANY of these strings
// (case-insensitive). Mirrors main.py's INDIA_KEYWORDS / is_india_playlist.
// ─────────────────────────────────────────────────────────────────────────────
const List<String> kIndiaPlaylistKeywords = [
  'india',
  'indian',
  ' - in ', // carousel tag: "[CAROUSEL] - IN /music carousel"
  '/in ', // alternate carousel format
  'hindi',
  'bollywood',
  'desi',
  'punjabi',
  'tamil',
  'telugu',
  'kannada',
  'malayalam',
  'marathi',
  'bhojpuri',
  'haryanvi',
];

/// Returns true if [title] is India-specific, per [kIndiaPlaylistKeywords].
/// Mirrors main.py's `is_india_playlist`.
bool isIndiaPlaylist(String title) {
  final low = title.toLowerCase();
  return kIndiaPlaylistKeywords.any((kw) => low.contains(kw));
}

class YtApi {
  static const _base = 'https://www.googleapis.com/youtube/v3';
  // Extra parts to fetch rich metadata in one call
  static const _videoParts = 'snippet,statistics,contentDetails';

  Future<({List<YtVideo> videos, String? nextPageToken})> search(
    String query, {
    int maxResults = 50,
    String? pageToken,
  }) async {
    // Step 1: search for video IDs
    final searchUri = Uri.parse(
      '$_base/search?part=snippet&type=video'
      '&q=${Uri.encodeQueryComponent(query)}'
      '&maxResults=$maxResults&key=$_kYtApiKey'
      '${pageToken != null ? '&pageToken=$pageToken' : ''}',
    );
    final searchRes =
        await http.get(searchUri).timeout(const Duration(seconds: 12));
    if (searchRes.statusCode != 200) throw Exception('YT API ${searchRes.statusCode}');
    final searchData = jsonDecode(searchRes.body) as Map<String, dynamic>;
    final searchItems = searchData['items'] as List? ?? [];
    final next = searchData['nextPageToken'] as String?;
    final ids = searchItems
        .map((e) => (e as Map)['id']?['videoId']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .join(',');
    if (ids.isEmpty) return (videos: <YtVideo>[], nextPageToken: next);

    // Step 2: fetch full details (statistics + contentDetails) for those IDs
    final detailUri = Uri.parse(
        '$_base/videos?part=$_videoParts&id=$ids&key=$_kYtApiKey');
    final detailRes =
        await http.get(detailUri).timeout(const Duration(seconds: 12));
    final detailData = jsonDecode(detailRes.body) as Map<String, dynamic>;
    final items = (detailData['items'] as List? ?? [])
        .map((e) => YtVideo.fromSearchItem(Map<String, dynamic>.from(e as Map)))
        .where((v) => v.id.isNotEmpty && !isShortVideo(v))
        .toList();
    return (videos: items, nextPageToken: next);
  }

  /// Fetches YouTube-like suggestions for [videoId] using the Data API v3.
  ///
  /// Strategy (mirrors how YouTube's recommendation seed actually works):
  ///   1. Fetch the video's own snippet → extract tags, categoryId, channelId,
  ///      title.  These are the exact signals YouTube's engine uses.
  ///   2. Build a smart search: first try tags (most specific), then fall back
  ///      to a topic search built from the title words + category, then fall
  ///      back to a channel search so users always get *something*.
  ///   3. Enrich results with statistics + contentDetails in one extra call
  ///      (same 2-step pattern as [search]) so the tiles show views & duration.
  Future<List<YtVideo>> suggestions(
    String videoId, {
    int maxResults = 15,
  }) async {
    // ── Step 1: fetch seed video metadata ────────────────────────────────────
    final seedUri = Uri.parse(
      '$_base/videos?part=snippet,contentDetails&id=$videoId&key=$_kYtApiKey',
    );
    final seedRes = await http.get(seedUri).timeout(const Duration(seconds: 10));
    if (seedRes.statusCode != 200) return [];

    final seedData = jsonDecode(seedRes.body) as Map<String, dynamic>;
    final seedItems = seedData['items'] as List? ?? [];
    if (seedItems.isEmpty) return [];

    final seed = seedItems.first as Map<String, dynamic>;
    final snippet = seed['snippet'] as Map<String, dynamic>? ?? {};

    final channelId  = snippet['channelId']  as String? ?? '';
    final categoryId = snippet['categoryId'] as String? ?? '10'; // 10 = Music
    final rawTags    = (snippet['tags'] as List?)?.cast<String>() ?? [];
    final title      = snippet['title'] as String? ?? '';

    // ── Step 2: build search query from signals ───────────────────────────────
    // Priority: tags → title keywords → channel videos
    // Tags are the richest signal (artist name, song name, genre, mood).
    // We take the first 3 most-specific tags (shortest = most specific usually)
    // and join them so the search stays focused.
    String searchQuery;
    List<String>? channelFallbackId;

    if (rawTags.isNotEmpty) {
      final topTags = (rawTags.toList()..sort((a, b) => a.length - b.length))
          .take(3)
          .toList();
      searchQuery = topTags.join(' ');
    } else if (title.isNotEmpty) {
      // Strip common noise words and use the core title + category 10 (Music)
      final words = title
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 2)
          .take(4)
          .join(' ');
      searchQuery = words.isNotEmpty ? words : title;
    } else {
      // Last resort: search the same channel
      searchQuery = '';
      if (channelId.isNotEmpty) channelFallbackId = [channelId];
    }

    // ── Step 3: search for related video IDs ─────────────────────────────────
    late Uri searchUri;
    if (searchQuery.isNotEmpty) {
      searchUri = Uri.parse(
        '$_base/search?part=snippet&type=video'
        '&q=${Uri.encodeQueryComponent(searchQuery)}'
        '&videoCategoryId=$categoryId'
        '&maxResults=${maxResults + 5}' // +5 to have room after filtering self
        '&key=$_kYtApiKey',
      );
    } else {
      // Channel fallback
      searchUri = Uri.parse(
        '$_base/search?part=snippet&type=video'
        '&channelId=${channelFallbackId!.first}'
        '&maxResults=${maxResults + 5}'
        '&key=$_kYtApiKey',
      );
    }

    final searchRes =
        await http.get(searchUri).timeout(const Duration(seconds: 12));
    if (searchRes.statusCode != 200) return [];

    final searchData = jsonDecode(searchRes.body) as Map<String, dynamic>;
    final searchItems = searchData['items'] as List? ?? [];

    // Filter out the seed video itself
    final ids = searchItems
        .map((e) => (e as Map)['id']?['videoId']?.toString() ?? '')
        .where((id) => id.isNotEmpty && id != videoId)
        .take(maxResults)
        .join(',');
    if (ids.isEmpty) return [];

    // ── Step 4: enrich with statistics + contentDetails ──────────────────────
    final detailUri = Uri.parse(
      '$_base/videos?part=$_videoParts&id=$ids&key=$_kYtApiKey',
    );
    final detailRes =
        await http.get(detailUri).timeout(const Duration(seconds: 12));
    if (detailRes.statusCode != 200) return [];

    final detailData = jsonDecode(detailRes.body) as Map<String, dynamic>;
    return (detailData['items'] as List? ?? [])
        .map((e) =>
            YtVideo.fromSearchItem(Map<String, dynamic>.from(e as Map)))
        .where((v) => v.id.isNotEmpty && v.id != videoId && !isShortVideo(v))
        .toList();
  }

  // Channel metadata, India-filtered playlists, and tracks for the home feed
  // are handled by YouTubeMusicService (pure HTTP) — see _loadChannelData()
  // in the screen state below, which mirrors main.py's execution flow.
}

// ─────────────────────────────────────────────────────────────────────────────
// YouTubeMusicService — pure HTTP implementation mirroring main.py exactly.
// Uses http.get with the YouTube Data API v3 REST endpoints directly,
// which is exactly what main.py does via googleapiclient.discovery.
// This avoids any googleapis Dart package issues that silently swallow errors.
// ─────────────────────────────────────────────────────────────────────────────

class YouTubeMusicService {
  final String _apiKey;
  static const _base = 'https://www.googleapis.com/youtube/v3';
  static const _videoParts = 'snippet,statistics,contentDetails';

  YouTubeMusicService(this._apiKey);

  Uri _uri(String endpoint, Map<String, String> params) =>
      Uri.parse('$_base/$endpoint').replace(queryParameters: {
        ...params,
        'key': _apiKey,
      });

  /// 1. Mirrors main.py get_channel_metadata — title, subscribers, views, avatar.
  Future<YtChannelMeta?> getChannelMetadata(String channelId) async {
    try {
      final res = await http
          .get(_uri('channels', {
            'part': 'snippet,statistics,contentDetails',
            'id': channelId,
          }))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        debugPrint('getChannelMetadata HTTP ${res.statusCode}: ${res.body}');
        return null;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = data['items'] as List? ?? [];
      if (items.isEmpty) return null;
      final item = items.first as Map<String, dynamic>;
      final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
      final stats = item['statistics'] as Map<String, dynamic>? ?? {};
      final thumbs = (snippet['thumbnails'] as Map<String, dynamic>?) ?? {};
      final thumb = (thumbs['high']?['url'] ??
              thumbs['medium']?['url'] ??
              thumbs['default']?['url'] ??
              '') as String;
      return YtChannelMeta(
        title: snippet['title'] as String? ?? 'Unknown',
        subscribers: stats['subscriberCount'] as String? ?? '0',
        views: stats['viewCount'] as String? ?? '0',
        thumbnail: thumb,
      );
    } catch (e) {
      debugPrint('getChannelMetadata failed: $e');
      return null;
    }
  }

  /// 2. Mirrors main.py get_india_playlists — fetches every playlist on the
  ///    channel (paginated), then keeps only the India-specific ones using
  ///    [isIndiaPlaylist] / [kIndiaPlaylistKeywords].
  Future<List<YtPlaylist>> getIndiaPlaylists(String channelId) async {
    final allPlaylists = <YtPlaylist>[];
    String? nextPageToken;

    debugPrint('  Fetching all playlists from channel (paginated)…');
    try {
      do {
        final params = <String, String>{
          'part': 'snippet,contentDetails',
          'channelId': channelId,
          'maxResults': '50',
          if (nextPageToken != null) 'pageToken': nextPageToken,
        };
        final res = await http
            .get(_uri('playlists', params))
            .timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) {
          debugPrint('getIndiaPlaylists HTTP ${res.statusCode}: ${res.body}');
          break;
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        for (final item in (data['items'] as List? ?? [])) {
          final m = item as Map<String, dynamic>;
          final snippet = m['snippet'] as Map<String, dynamic>? ?? {};
          final details = m['contentDetails'] as Map<String, dynamic>? ?? {};
          final thumbs = (snippet['thumbnails'] as Map<String, dynamic>?) ?? {};
          final thumb = (thumbs['maxres']?['url'] ??
                  thumbs['high']?['url'] ??
                  thumbs['medium']?['url'] ??
                  thumbs['default']?['url'] ??
                  '') as String;
          allPlaylists.add(YtPlaylist(
            id: m['id'] as String? ?? '',
            title: snippet['title'] as String? ?? 'Untitled Playlist',
            thumbnail: thumb,
            itemCount: (details['itemCount'] as int?) ?? 0,
          ));
        }
        nextPageToken = (jsonDecode(res.body)
            as Map<String, dynamic>)['nextPageToken'] as String?;
      } while (nextPageToken != null);
    } catch (e) {
      debugPrint('getIndiaPlaylists failed: $e');
      // Fall through with whatever we collected before the error.
    }

    // ── Manual India filter (mirrors main.py's INDIA_KEYWORDS check) ────────
    final indiaPlaylists =
        allPlaylists.where((p) => isIndiaPlaylist(p.title)).toList();

    debugPrint('  Total playlists found : ${allPlaylists.length}');
    debugPrint('  India playlists kept  : ${indiaPlaylists.length}');
    return indiaPlaylists;
  }

  /// 3. Mirrors main.py get_tracks_from_playlist — walks every page of the
  ///    playlist, then enriches the video IDs with statistics + duration via
  ///    the videos endpoint (chunked at 50 IDs per request, the API limit).
  Future<List<YtVideo>> getTracksFromPlaylist(String playlistId) async {
    final ids = <String>[];
    String? nextPageToken;
    try {
      do {
        final params = <String, String>{
          'part': 'snippet,contentDetails',
          'playlistId': playlistId,
          'maxResults': '50',
          if (nextPageToken != null) 'pageToken': nextPageToken,
        };
        final res = await http
            .get(_uri('playlistItems', params))
            .timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) {
          debugPrint('getTracksFromPlaylist HTTP ${res.statusCode}: ${res.body}');
          break;
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        for (final item in (data['items'] as List? ?? [])) {
          final videoId = ((item as Map)['snippet']
                  as Map<String, dynamic>?)?['resourceId']
              ?['videoId'] as String? ??
              '';
          if (videoId.isNotEmpty) ids.add(videoId);
        }
        nextPageToken = data['nextPageToken'] as String?;
      } while (nextPageToken != null);
    } catch (e) {
      debugPrint('getTracksFromPlaylist failed: $e');
      return [];
    }

    if (ids.isEmpty) return [];

    // Enrich with statistics + contentDetails, 50 IDs per request (API limit).
    final videos = <YtVideo>[];
    for (var i = 0; i < ids.length; i += 50) {
      final end = (i + 50 > ids.length) ? ids.length : i + 50;
      final chunk = ids.sublist(i, end);
      try {
        final detRes = await http
            .get(Uri.parse('$_base/videos').replace(queryParameters: {
              'part': _videoParts,
              'id': chunk.join(','),
              'key': _kYtApiKey,
            }))
            .timeout(const Duration(seconds: 12));
        if (detRes.statusCode != 200) {
          videos.addAll(_idsToStubVideos(chunk));
          continue;
        }
        final detData = jsonDecode(detRes.body) as Map<String, dynamic>;
        videos.addAll((detData['items'] as List? ?? [])
            .map((e) =>
                YtVideo.fromSearchItem(Map<String, dynamic>.from(e as Map)))
            .where((v) => v.id.isNotEmpty && !isShortVideo(v)));
      } catch (_) {
        videos.addAll(_idsToStubVideos(chunk));
      }
    }
    return videos;
  }

  /// Fallback: return stub YtVideo objects when enrichment fails,
  /// so the carousel still shows the video IDs we know exist.
  List<YtVideo> _idsToStubVideos(List<String> ids) => ids
      .map((id) => YtVideo(
            id: id,
            title: 'Loading…',
            channelName: '',
            thumbnail: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
            viewCount: '',
            publishedAt: '',
          ))
      .toList();
}

// ─────────────────────────────────────────────────────────────────────────────
// Channel data models
// ─────────────────────────────────────────────────────────────────────────────

class YtChannelMeta {
  final String title;
  final String subscribers;
  final String views;
  final String thumbnail;

  const YtChannelMeta({
    required this.title,
    required this.subscribers,
    required this.views,
    required this.thumbnail,
  });

  String get subscribersFormatted {
    final n = int.tryParse(subscribers) ?? 0;
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M subscribers';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}K subscribers';
    return '$n subscribers';
  }

  String get viewsFormatted {
    final n = int.tryParse(views) ?? 0;
    if (n >= 1000000000) return '${(n / 1000000000).toStringAsFixed(1)}B views';
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M views';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}K views';
    return '$n views';
  }
}

class YtPlaylist {
  final String id;
  final String title;
  final String thumbnail;
  final int itemCount;

  const YtPlaylist({
    required this.id,
    required this.title,
    required this.thumbnail,
    required this.itemCount,
  });
}

class YtPlaylistSection {
  final YtPlaylist playlist;
  final List<YtVideo> tracks;
  bool isLoading;

  YtPlaylistSection({
    required this.playlist,
    required this.tracks,
    this.isLoading = false,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Main YouTube Screen
// ─────────────────────────────────────────────────────────────────────────────

class YouTubeScreen extends StatefulWidget {
  const YouTubeScreen({super.key});

  @override
  State<YouTubeScreen> createState() => _YouTubeScreenState();
}

class _YouTubeScreenState extends State<YouTubeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _api = YtApi();
  final _ytMusicService = YouTubeMusicService(_kYtApiKey);
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _searchFocus = FocusNode();

  // Search state — sectioned results (5 each, like JioSaavn)
  bool _loading = false;
  String? _error;
  bool _isSearching = false;
  String _searchQuery = '';
  bool _showSearchBar = false;

  List<YtVideo> _searchSongs = [];
  List<YtVideo> _searchArtists = [];
  List<YtVideo> _searchPlaylists = [];
  List<YtVideo> _searchAlbums = [];

  // Persistent watch history (loaded from SharedPreferences)
  List<YtVideo> _history = [];
  bool _showHistory = false;
  static const _kHistoryKey = 'yt_watch_history';

  // YouTube Music channel data (mirrors main.py: metadata + India playlists + tracks)
  YtChannelMeta? _channelMeta;
  List<YtPlaylistSection> _playlistSections = [];
  bool _channelLoading = false;
  String? _channelError;

  // AppState listener — tracks Up Next song changes
  AppState? _appState;
  String? _lastTrackedSongId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchFocus.addListener(() {
      // If user dismissed keyboard without submitting, collapse back to pill
      if (!_searchFocus.hasFocus && !_isSearching) {
        setState(() => _showSearchBar = false);
      }
    });
    _loadHistory();
    _loadChannelData();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Reload history when user comes back to the app (e.g. after using Up Next)
    if (state == AppLifecycleState.resumed) {
      _loadHistory();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload history every time this screen is navigated back to
    _loadHistory();
    // Subscribe to AppState to catch song changes from Up Next
    final app = Provider.of<AppState>(context, listen: false);
    if (_appState != app) {
      _appState?.removeListener(_onAppStateChanged);
      _appState = app;
      _appState!.addListener(_onAppStateChanged);
    }
  }

  void _onAppStateChanged() {
    final song = _appState?.currentSong;
    if (song == null) return;
    // When a new yt: song starts (e.g. from Up Next), refresh history
    if (song.id.startsWith('yt:') && song.id != _lastTrackedSongId) {
      _lastTrackedSongId = song.id;
      _loadHistory();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appState?.removeListener(_onAppStateChanged);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _scrollCtrl
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  // ── history persistence ────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kHistoryKey) ?? [];
      final loaded = raw
          .map((s) {
            try {
              final m = jsonDecode(s) as Map<String, dynamic>;
              return YtVideo(
                id: m['id'] as String,
                title: m['title'] as String,
                channelName: m['channelName'] as String,
                thumbnail: m['thumbnail'] as String,
                viewCount: m['viewCount'] as String? ?? '',
                publishedAt: m['publishedAt'] as String? ?? '',
                duration: m['duration'] as String? ?? '',
              );
            } catch (_) {
              return null;
            }
          })
          .whereType<YtVideo>()
          .toList();
      if (mounted) setState(() => _history = loaded);
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _history.map((v) => jsonEncode({
            'id': v.id,
            'title': v.title,
            'channelName': v.channelName,
            'thumbnail': v.thumbnail,
            'viewCount': v.viewCount,
            'publishedAt': v.publishedAt,
            'duration': v.duration,
          })).toList();
      await prefs.setStringList(_kHistoryKey, encoded);
    } catch (_) {}
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHistoryKey);
    if (mounted) setState(() => _history = []);
  }

  void _onScroll() {
    // Scroll listener kept for future use (no infinite search)
  }

  // ── loads ────────────────────────────────────────────────────────────────

  /// Mirrors main.py's execution flow exactly, via YouTubeMusicService:
  ///   1. getChannelMetadata  → channel title, subscribers, views
  ///   2. getIndiaPlaylists   → all playlists, filtered to India-specific ones
  ///   3. getTracksFromPlaylist (per playlist) → video rows
  ///
  /// This is the *only* data source for the YouTube tab's home feed.
  Future<void> _loadChannelData() async {
    if (_channelLoading) return;
    setState(() {
      _channelLoading = true;
      _channelError = null;
    });

    try {
      // ── Step 1: channel metadata ──────────────────────────────────────────
      // Mirrors: meta = get_channel_metadata(CHANNEL_ID)
      final meta = await _ytMusicService.getChannelMetadata(kYtMusicChannelId);
      if (meta == null) {
        if (mounted) {
          setState(() {
            _channelError =
                'Could not fetch channel metadata. Check the API key or channel ID.';
            _channelLoading = false;
          });
        }
        return;
      }

      // ── Step 2: India-filtered playlists ──────────────────────────────────
      // Mirrors: india_playlists = get_india_playlists(CHANNEL_ID)
      final indiaPlaylists =
          await _ytMusicService.getIndiaPlaylists(kYtMusicChannelId);

      if (!mounted) return;
      setState(() {
        _channelMeta = meta;
        _playlistSections = indiaPlaylists
            .where((p) => p.id.isNotEmpty)
            .map((p) => YtPlaylistSection(playlist: p, tracks: [], isLoading: true))
            .toList();
        _channelLoading = false;
      });

      // ── Step 3: tracks per playlist ────────────────────────────────────────
      // Mirrors: for pl in india_playlists: tracks = get_tracks_from_playlist(...)
      for (int i = 0; i < _playlistSections.length; i++) {
        if (!mounted) return;
        final section = _playlistSections[i];
        try {
          final tracks = await _ytMusicService.getTracksFromPlaylist(section.playlist.id);
          if (!mounted) return;
          setState(() {
            _playlistSections[i] = YtPlaylistSection(
              playlist: section.playlist,
              tracks: tracks,
              isLoading: false,
            );
          });
        } catch (_) {
          if (!mounted) return;
          setState(() {
            _playlistSections[i] = YtPlaylistSection(
              playlist: section.playlist,
              tracks: [],
              isLoading: false,
            );
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _channelError = 'Could not load YouTube Music data. Check your internet connection.';
          _channelLoading = false;
        });
      }
    }
  }

  /// Sectioned search — runs 4 queries in parallel and caps each at 5 results.
  /// Categories: Songs, Artists, Playlists, Albums (like JioSaavn search).
  Future<void> _search(String q) async {
    if (q.trim().isEmpty) { _clearSearch(); return; }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _searchQuery = q.trim();
      _isSearching = true;
      _searchSongs = [];
      _searchArtists = [];
      _searchPlaylists = [];
      _searchAlbums = [];
    });
    try {
      // Run 4 targeted searches in parallel — each capped at 5 visible results
      final results = await Future.wait([
        _api.search('${q.trim()} song', maxResults: 10),
        _api.search('${q.trim()} artist', maxResults: 10),
        _api.search('${q.trim()} playlist', maxResults: 10),
        _api.search('${q.trim()} album', maxResults: 10),
      ]);
      if (mounted) {
        setState(() {
          _searchSongs     = results[0].videos.take(5).toList();
          _searchArtists   = results[1].videos.take(5).toList();
          _searchPlaylists = results[2].videos.take(5).toList();
          _searchAlbums    = results[3].videos.take(5).toList();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _showSearchBar = false;
      _searchSongs = [];
      _searchArtists = [];
      _searchPlaylists = [];
      _searchAlbums = [];
    });
  }

  void _openVideo(YtVideo video) {
    // Persist to history (most recent first, no duplicates, max 100)
    _history.removeWhere((v) => v.id == video.id);
    _history.insert(0, video);
    if (_history.length > 100) _history.removeLast();
    _saveHistory();
    setState(() {});

    _playYoutubeAudio(video);
  }

  Future<void> _playYoutubeAudio(YtVideo video) async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // ── Step 1: Navigate to NowPlayingScreen immediately ─────────────────────
    // We already have title, artist, thumbnail — enough to show the player UI
    // while stream extraction happens in the background. This mirrors how every
    // real music app works: tap → screen opens instantly, audio starts shortly.
    nav.push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => const NowPlayingScreen(),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position:
              Tween(begin: const Offset(0, 1), end: Offset.zero).animate(anim),
          child: child,
        ),
      ),
    );

    // ── Step 2: Pre-populate AppState with a loading placeholder ─────────────
    // This makes the mini player and NowPlayingScreen show the correct
    // title/art immediately, with isLoadingTrack=true (spinner in player).
    final placeholder = Song(
      id: 'yt:${video.id}',
      title: video.title,
      artist: video.channelName,
      image: video.thumbnail,
      album: 'YouTube',
      durationSec: _parseDuration(video.duration),
      mediaUrl: '', // will be filled in below
    );
    app.queue = [placeholder];
    app.currentIndex = 0;
    app.isLoadingTrack = true;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    app.notifyListeners();

    // ── Step 3: Extract stream URL in the background ──────────────────────────
    try {
      final info = await YoutubeStreamService.getStreamInfo(video.id);
      final audioUrl = info.bestAudioUrl;
      if (audioUrl == null) throw Exception('No audio stream found');

      if (!mounted) return;

      final song = Song(
        id: 'yt:${video.id}',
        title: video.title,
        artist: video.channelName,
        image: video.thumbnail,
        album: 'YouTube',
        durationSec: _parseDuration(video.duration),
        mediaUrl: audioUrl,
        mediaHeaders: info.streamHeaders,
      );

      // This clears isLoadingTrack and starts actual playback:
      await app.setQueueAndPlay([song], 0);
    } catch (e) {
      if (!mounted) return;
      // Pop the NowPlayingScreen since we can't play anything
      nav.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not play video: $e'),
          backgroundColor: TaarColors.vermilion,
        ),
      );
    }
  }

  /// Parse ISO 8601 duration like PT4M13S → total seconds.
  int _parseDuration(String iso) => parseYtDuration(iso);

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TaarColors.ink,
      body: SafeArea(
        bottom: false,
        child: _showHistory ? _buildHistoryScreen() : _buildMainScreen(),
      ),
    );
  }

  Widget _buildMainScreen() {
    return RefreshIndicator(
      onRefresh: _isSearching ? () => _search(_searchQuery) : _loadChannelData,
      color: TaarColors.marigold,
      backgroundColor: TaarColors.ink2,
      child: CustomScrollView(
        controller: _scrollCtrl,
        slivers: [
          SliverToBoxAdapter(child: _buildHeader()),
          SliverToBoxAdapter(child: _buildSearchPill()),

          if (_isSearching) ...[
            // ── Search results ─────────────────────────────────────────────
            if (_loading)
              _buildSkeleton()
            else if (_error != null)
              SliverFillRemaining(child: _buildError())
            else
              SliverToBoxAdapter(child: _buildSearchResults()),
          ] else ...[
            // ── Home feed — sourced entirely from main.py's logic: ──────────
            // channel metadata → India-filtered playlists → tracks per playlist
            if (_history.isNotEmpty) ...[
              SliverToBoxAdapter(child: _buildSectionHeader('Watch Again')),
              SliverToBoxAdapter(child: _buildWatchAgainCarousel()),
            ],

            // ── YouTube Speed Dial (Most Played on YouTube) ────────────────
            SliverToBoxAdapter(child: _buildYtSpeedDial()),

            // ── YouTube Quick Pick ─────────────────────────────────────────
            SliverToBoxAdapter(child: _buildYtQuickPick()),

            if (_channelLoading && _channelMeta == null)
              SliverToBoxAdapter(child: _buildChannelSkeleton())
            else ...[
              if (_channelMeta != null)
                SliverToBoxAdapter(child: _buildChannelBanner(_channelMeta!)),
              if (_channelError != null)
                SliverToBoxAdapter(child: _buildChannelError())
              else if (_playlistSections.isEmpty)
                SliverToBoxAdapter(child: _buildNoIndiaPlaylists())
              else
                ...() {
                  // Pin "Top Tracks" playlists above everything else
                  final topTracks = _playlistSections
                      .where((s) => s.playlist.title.toLowerCase().contains('top track'))
                      .toList();
                  final others = _playlistSections
                      .where((s) => !s.playlist.title.toLowerCase().contains('top track'))
                      .toList();
                  return [...topTracks, ...others]
                      .map((s) => SliverToBoxAdapter(child: _buildPlaylistSection(s)))
                      .toList();
                }(),
            ],
          ],

          const SliverToBoxAdapter(child: SizedBox(height: 140)),
        ],
      ),
    );
  }

  // ── History full screen ────────────────────────────────────────────────────

  Widget _buildHistoryScreen() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 8, 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded,
                    color: Colors.white, size: 20),
                onPressed: () => setState(() => _showHistory = false),
              ),
              const SizedBox(width: 2),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Watch History',
                    style: GoogleFonts.poppins(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: TaarColors.marigold,
                    ),
                  ),
                  Text(
                    '${_history.length} video${_history.length == 1 ? '' : 's'}',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: TaarColors.creamDim,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              if (_history.isNotEmpty)
                TextButton.icon(
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        backgroundColor: TaarColors.ink2,
                        title: const Text('Clear History',
                            style: TextStyle(color: Colors.white)),
                        content: const Text('Remove all watch history?',
                            style: TextStyle(color: TaarColors.creamDim)),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel')),
                          TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Clear',
                                  style: TextStyle(
                                      color: TaarColors.vermilion))),
                        ],
                      ),
                    );
                    if (confirm == true) _clearHistory();
                  },
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 16, color: TaarColors.vermilion),
                  label: const Text('Clear',
                      style:
                          TextStyle(color: TaarColors.vermilion, fontSize: 13)),
                ),
            ],
          ),
        ),
        const Divider(color: TaarColors.ink3, height: 1),
        Expanded(
          child: _history.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.history_rounded,
                          color: TaarColors.creamDim, size: 52),
                      const SizedBox(height: 14),
                      Text('No watch history yet',
                          style: GoogleFonts.poppins(
                              color: TaarColors.creamDim,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      const Text('Videos you play will appear here',
                          style: TextStyle(
                              color: TaarColors.creamDim, fontSize: 13)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 140),
                  itemCount: _history.length,
                  itemBuilder: (ctx, i) {
                    final v = _history[i];
                    return Dismissible(
                      key: ValueKey(v.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: TaarColors.vermilion.withOpacity(0.15),
                        child: const Icon(Icons.delete_outline_rounded,
                            color: TaarColors.vermilion),
                      ),
                      onDismissed: (_) {
                        setState(() => _history.removeAt(i));
                        _saveHistory();
                      },
                      child: _VideoTile(
                        video: v,
                        onTap: () => _openVideo(v),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
      child: Row(
        children: [
          // YouTube logo area — matches home screen greeting style
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'YouTube',
                style: GoogleFonts.poppins(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: TaarColors.marigold,
                ),
              ),
              Text(
                _isSearching ? 'Search results' : 'Music Videos · India',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: TaarColors.creamDim,
                ),
              ),
            ],
          ),
          const Spacer(),
          // YouTube red play icon
          const Icon(Icons.play_circle_fill, color: Color(0xFFFF0000), size: 32),
          // History button
          IconButton(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.history_rounded, color: TaarColors.creamDim, size: 22),
                if (_history.isNotEmpty)
                  Positioned(
                    right: -3, top: -3,
                    child: Container(
                      width: 8, height: 8,
                      decoration: const BoxDecoration(
                        color: TaarColors.marigold,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: () => setState(() => _showHistory = true),
            tooltip: 'Watch History',
          ),
          // Refresh
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: TaarColors.creamDim, size: 22),
            onPressed: _isSearching ? () => _search(_searchQuery) : _loadChannelData,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  // ── search pill (always visible, matches home screen style) ───────────────

  Widget _buildSearchPill() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _showSearchBar || _isSearching
            ? _buildActiveSearch()
            : GestureDetector(
                key: const ValueKey('pill'),
                onTap: () {
                  setState(() => _showSearchBar = true);
                  Future.delayed(
                      const Duration(milliseconds: 50),
                      () => _searchFocus.requestFocus());
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                  decoration: BoxDecoration(
                    color: TaarColors.ink2,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.search, color: TaarColors.marigold, size: 20),
                      SizedBox(width: 10),
                      Text(
                        'Search music videos…',
                        style: TextStyle(color: TaarColors.creamDim, fontSize: 14.5),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildActiveSearch() {
    return Container(
      key: const ValueKey('active'),
      height: 50,
      decoration: BoxDecoration(
        color: TaarColors.ink2,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: TaarColors.marigoldDim, width: 1.5),
      ),
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        autofocus: true,
        style: const TextStyle(color: Colors.white, fontSize: 14.5),
        decoration: InputDecoration(
          hintText: 'Search music videos…',
          hintStyle: const TextStyle(color: TaarColors.creamDim, fontSize: 14.5),
          prefixIcon: const Icon(Icons.search_rounded, color: TaarColors.marigold, size: 20),
          suffixIcon: GestureDetector(
            onTap: _clearSearch,
            child: const Icon(Icons.close_rounded, color: TaarColors.creamDim, size: 20),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: _search,
        textInputAction: TextInputAction.search,
      ),
    );
  }

  // ── section header (matches home screen BrowseRow style) ─────────────────

  Widget _buildSectionHeader(String title, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          Text(title, style: TaarTheme.sectionHeader(context, size: 17)),
          if (trailing != null) ...[const Spacer(), trailing],
        ],
      ),
    );
  }

  // ── Watch Again carousel (persistent history) ─────────────────────────────

  Widget _buildWatchAgainCarousel() {
    return SizedBox(
      height: 202,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _history.length,
        itemBuilder: (_, i) {
          final v = _history[i];
          return GestureDetector(
            onTap: () => _openVideo(v),
            child: Container(
              width: 160,
              margin: const EdgeInsets.only(right: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.network(
                          v.thumbnail,
                          width: 160,
                          height: 160,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 160, height: 160,
                            color: TaarColors.ink3,
                            child: const Icon(Icons.music_video,
                                color: TaarColors.creamDim, size: 40),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 8, top: 8,
                        child: Container(
                          width: 22, height: 22,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.play_arrow, size: 14, color: Colors.white),
                        ),
                      ),
                      if (v.durationFormatted.isNotEmpty)
                        Positioned(
                          right: 6, bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.82),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(v.durationFormatted,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    v.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13, color: Colors.white),
                  ),
                  Text(
                    v.channelName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: TaarColors.creamDim),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Sectioned Search Results (like JioSaavn) ─────────────────────────────

  Widget _buildSearchResults() {
    final hasAny = _searchSongs.isNotEmpty || _searchArtists.isNotEmpty ||
        _searchPlaylists.isNotEmpty || _searchAlbums.isNotEmpty;

    if (!hasAny) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, color: TaarColors.creamDim, size: 52),
            const SizedBox(height: 14),
            Text(
              'No results for "$_searchQuery"',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                  color: TaarColors.creamDim, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              'Try a different song, artist or album',
              textAlign: TextAlign.center,
              style: TextStyle(color: TaarColors.creamDim, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Songs ─────────────────────────────────────────────────────────────
        if (_searchSongs.isNotEmpty) ...[
          _searchSectionHeader('Songs'),
          ..._searchSongs.map((v) => _SearchVideoTile(
                video: v,
                subtitle: 'Song · ${v.channelName}',
                onTap: () => _openVideo(v),
              )),
        ],

        // ── Artists ───────────────────────────────────────────────────────────
        if (_searchArtists.isNotEmpty) ...[
          _searchSectionHeader('Artists'),
          ..._searchArtists.map((v) => _SearchVideoTile(
                video: v,
                subtitle: 'Artist · ${v.channelName}',
                circular: true,
                onTap: () => _openVideo(v),
              )),
        ],

        // ── Playlists ─────────────────────────────────────────────────────────
        if (_searchPlaylists.isNotEmpty) ...[
          _searchSectionHeader('Playlists'),
          ..._searchPlaylists.map((v) => _SearchVideoTile(
                video: v,
                subtitle: 'Playlist · ${v.channelName}',
                onTap: () => _openVideo(v),
              )),
        ],

        // ── Albums ────────────────────────────────────────────────────────────
        if (_searchAlbums.isNotEmpty) ...[
          _searchSectionHeader('Albums'),
          ..._searchAlbums.map((v) => _SearchVideoTile(
                video: v,
                subtitle: 'Album · ${v.channelName}',
                onTap: () => _openVideo(v),
              )),
        ],

        const SizedBox(height: 140),
      ],
    );
  }

  Widget _searchSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: TaarColors.marigold,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  // ── YouTube Speed Dial ────────────────────────────────────────────────────

  /// Speed Dial widget filtered to YouTube-only songs.
  /// Shows the user's most-played YouTube tracks in a 3-column paged grid.
  Widget _buildYtSpeedDial() {
    final songs = context.watch<SpeedDialService>().ytDialSongs;
    if (songs.isEmpty) return const SizedBox.shrink();

    const perPage = 9;
    final pages = <List<Song>>[];
    for (int i = 0; i < songs.length; i += perPage) {
      pages.add(songs.sublist(i, (i + perPage) > songs.length ? songs.length : (i + perPage)));
    }

    final screenW = MediaQuery.of(context).size.width;
    final cardW = (screenW - 32 - 16) / 3;
    final cardH = cardW;

    int currentPage = 0;

    return StatefulBuilder(builder: (context, setPageState) {
      final pageCtrl = PageController();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF0000).withOpacity(0.18),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFFF0000), width: 1.5),
                  ),
                  child: const Icon(Icons.play_circle_fill,
                      size: 18, color: Color(0xFFFF0000)),
                ),
                const SizedBox(width: 10),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your top YouTube plays',
                      style: TextStyle(
                          fontSize: 11,
                          color: TaarColors.creamDim,
                          fontWeight: FontWeight.w500),
                    ),
                    Text(
                      'Most Played',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Colors.white),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(
            height: cardH * 3 + 8 * 2,
            child: PageView.builder(
              controller: pageCtrl,
              itemCount: pages.length,
              onPageChanged: (p) => setPageState(() => currentPage = p),
              itemBuilder: (context, pageIndex) {
                final pageSongs = pages[pageIndex];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemCount: pageSongs.length,
                    itemBuilder: (context, i) => _YtSpeedDialCard(
                      song: pageSongs[i],
                      onTap: () {
                        // Reconstruct a YtVideo-like play from the Song cache
                        final s = pageSongs[i];
                        final videoId = s.id.startsWith('yt:') ? s.id.substring(3) : s.id;
                        final video = YtVideo(
                          id: videoId,
                          title: s.title,
                          channelName: s.artist,
                          thumbnail: s.image,
                          viewCount: '',
                          publishedAt: '',
                        );
                        _openVideo(video);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          if (pages.length > 1) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(pages.length, (i) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == currentPage ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == currentPage
                        ? Colors.white
                        : Colors.white.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ],
          const SizedBox(height: 8),
        ],
      );
    });
  }

  // ── YouTube Quick Pick ────────────────────────────────────────────────────

  /// Quick Pick — random selection from the user's top YouTube videos.
  Widget _buildYtQuickPick() {
    final songs = context.watch<SpeedDialService>().ytQuickPickSongs;
    if (songs.isEmpty) return const SizedBox.shrink();

    final pages = <List<Song>>[];
    for (int i = 0; i < songs.length; i += 4) {
      pages.add(songs.sublist(i, i + 4 > songs.length ? songs.length : i + 4));
    }
    const double rowHeight = 68.0;
    const int perPage = 4;
    final double listHeight = rowHeight * perPage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Text('Quick Pick', style: TaarTheme.sectionHeader(context, size: 17)),
        ),
        SizedBox(
          height: listHeight,
          child: PageView.builder(
            controller: PageController(viewportFraction: 0.93),
            itemCount: pages.length,
            itemBuilder: (context, pageIndex) {
              final pageSongs = pages[pageIndex];
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  children: pageSongs.map((song) {
                    final videoId = song.id.startsWith('yt:') ? song.id.substring(3) : song.id;
                    return SizedBox(
                      height: rowHeight,
                      child: InkWell(
                        onTap: () {
                          final video = YtVideo(
                            id: videoId,
                            title: song.title,
                            channelName: song.artist,
                            thumbnail: song.image,
                            viewCount: '',
                            publishedAt: '',
                          );
                          _openVideo(video);
                        },
                        splashColor: TaarColors.marigold.withOpacity(0.08),
                        highlightColor: TaarColors.marigold.withOpacity(0.04),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  song.image,
                                  width: 50, height: 50,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 50, height: 50,
                                    color: TaarColors.ink3,
                                    child: const Icon(Icons.music_video,
                                        color: TaarColors.creamDim, size: 22),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      song.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      song.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: TaarColors.creamDim, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.play_circle_outline_rounded,
                                  color: TaarColors.creamDim, size: 22),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ── Channel banner (metadata from getChannelMetadata) ───────────────────

  Widget _buildChannelBanner(YtChannelMeta meta) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: TaarColors.ink2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TaarColors.line, width: 1),
      ),
      child: Row(
        children: [
          // Channel avatar
          ClipOval(
            child: meta.thumbnail.isNotEmpty
                ? Image.network(meta.thumbnail, width: 48, height: 48, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _channelAvatarFallback())
                : _channelAvatarFallback(),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        meta.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Verified badge
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF0000),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check, size: 9, color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  meta.subscribersFormatted,
                  style: const TextStyle(color: TaarColors.creamDim, fontSize: 12),
                ),
                Text(
                  meta.viewsFormatted,
                  style: const TextStyle(color: TaarColors.creamDim, fontSize: 11),
                ),
              ],
            ),
          ),
          // YouTube red logo
          const Icon(Icons.play_circle_fill, color: Color(0xFFFF0000), size: 30),
        ],
      ),
    );
  }

  Widget _channelAvatarFallback() => Container(
        width: 48, height: 48,
        color: const Color(0xFFFF0000),
        child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 24),
      );

  /// One horizontal row per playlist — mirrors main.py's playlist loop.
  Widget _buildPlaylistSection(YtPlaylistSection section) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header: playlist title + "See all" button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  section.playlist.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TaarTheme.sectionHeader(context, size: 16),
                ),
              ),
              if (!section.isLoading && section.tracks.isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => YtPlaylistScreen(
                        playlist: section.playlist,
                        tracks: section.tracks,
                        onPlayVideo: _openVideo,
                      ),
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('See all',
                          style: TextStyle(
                              color: TaarColors.marigold,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600)),
                      SizedBox(width: 2),
                      Icon(Icons.chevron_right_rounded,
                          color: TaarColors.marigold, size: 16),
                    ],
                  ),
                )
              else if (section.playlist.itemCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    '${section.playlist.itemCount} videos',
                    style: const TextStyle(color: TaarColors.creamDim, fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ),

        // Tracks carousel
        SizedBox(
          height: 202,
          child: section.isLoading
              ? _buildPlaylistShimmer()
              : section.tracks.isEmpty
                  ? const Center(
                      child: Text('No videos',
                          style: TextStyle(color: TaarColors.creamDim, fontSize: 13)),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: section.tracks.length,
                      itemBuilder: (_, i) {
                        final v = section.tracks[i];
                        return GestureDetector(
                          onTap: () => _openVideo(v),
                          child: Container(
                            width: 160,
                            margin: const EdgeInsets.only(right: 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Stack(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(14),
                                      child: Image.network(
                                        v.thumbnail,
                                        width: 160, height: 160,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Container(
                                          width: 160, height: 160,
                                          color: TaarColors.ink3,
                                          child: const Icon(Icons.music_video,
                                              color: TaarColors.creamDim, size: 40),
                                        ),
                                      ),
                                    ),
                                    // Play button overlay
                                    Positioned(
                                      left: 8, top: 8,
                                      child: Container(
                                        width: 22, height: 22,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.55),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.play_arrow,
                                            size: 14, color: Colors.white),
                                      ),
                                    ),
                                    // Duration badge
                                    if (v.durationFormatted.isNotEmpty)
                                      Positioned(
                                        right: 6, bottom: 6,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 5, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withOpacity(0.82),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            v.durationFormatted,
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  v.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: Colors.white),
                                ),
                                Text(
                                  v.channelName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 11.5, color: TaarColors.creamDim),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  /// Shimmer placeholder while a single playlist's tracks are loading.
  Widget _buildPlaylistShimmer() {
    return Shimmer.fromColors(
      baseColor: TaarColors.ink3,
      highlightColor: TaarColors.ink2,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 4,
        itemBuilder: (_, __) => Container(
          width: 160,
          margin: const EdgeInsets.only(right: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 160, height: 160,
                decoration: BoxDecoration(
                  color: TaarColors.ink3,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              const SizedBox(height: 8),
              Container(height: 12, width: 120, color: TaarColors.ink3),
              const SizedBox(height: 4),
              Container(height: 11, width: 80, color: TaarColors.ink3),
            ],
          ),
        ),
      ),
    );
  }

  /// Full-screen shimmer while the channel metadata + playlists first load.
  Widget _buildChannelSkeleton() {
    return Shimmer.fromColors(
      baseColor: TaarColors.ink3,
      highlightColor: TaarColors.ink2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Banner skeleton
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            height: 72,
            decoration: BoxDecoration(
              color: TaarColors.ink3,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          // Two playlist row skeletons
          for (int r = 0; r < 2; r++) ...[
            Container(
              margin: const EdgeInsets.fromLTRB(16, 14, 100, 8),
              height: 16,
              color: TaarColors.ink3,
            ),
            SizedBox(
              height: 202,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: 4,
                itemBuilder: (_, __) => Container(
                  width: 160,
                  margin: const EdgeInsets.only(right: 14),
                  decoration: BoxDecoration(
                    color: TaarColors.ink3,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── home feed: India-playlist empty / error states ───────────────────────
  // Mirrors main.py's `if not india_playlists: print("No India-specific
  // playlists found."); raise SystemExit()` and the channel-metadata guard.

  Widget _buildNoIndiaPlaylists() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 36, 20, 20),
      child: Column(
        children: [
          const Icon(Icons.playlist_remove_rounded,
              color: TaarColors.creamDim, size: 48),
          const SizedBox(height: 14),
          Text(
            'No India-specific playlists found',
            style: GoogleFonts.poppins(
              color: TaarColors.creamDim,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'This channel has no playlists matching the India keyword filter right now.',
            textAlign: TextAlign.center,
            style: TextStyle(color: TaarColors.creamDim, fontSize: 12.5, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelError() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Column(
        children: [
          const Icon(Icons.wifi_off_rounded, color: TaarColors.vermilion, size: 44),
          const SizedBox(height: 14),
          Text(
            _channelError ?? 'Something went wrong.',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13.5, height: 1.5),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: TaarColors.marigold),
            onPressed: _loadChannelData,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  // ── empty state ───────────────────────────────────────────────────────────

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, color: TaarColors.creamDim, size: 52),
            const SizedBox(height: 14),
            Text('No videos found',
                style: GoogleFonts.poppins(
                    color: TaarColors.creamDim,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('Try a different search term',
                style: TextStyle(color: TaarColors.creamDim, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  // ── error ─────────────────────────────────────────────────────────────────

  Widget _buildError() {
    final isKeyError =
        _error?.contains('400') == true || _error?.contains('403') == true;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, color: TaarColors.vermilion, size: 52),
            const SizedBox(height: 16),
            Text(
              isKeyError
                  ? 'YouTube API key error.\nCheck _kYtApiKey.'
                  : 'Could not load videos.\nCheck your internet connection.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                  color: Colors.white70, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: TaarColors.marigold),
              onPressed: () => _search(_searchQuery),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  // ── shimmer skeleton ──────────────────────────────────────────────────────

  SliverToBoxAdapter _buildSkeleton() {
    return SliverToBoxAdapter(
      child: Shimmer.fromColors(
        baseColor: TaarColors.ink3,
        highlightColor: TaarColors.ink2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Container(
                width: 140, height: 18,
                decoration: BoxDecoration(
                    color: TaarColors.ink3,
                    borderRadius: BorderRadius.circular(6))),
            ),
            for (int i = 0; i < 8; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                        width: 130, height: 74,
                        decoration: BoxDecoration(
                            color: TaarColors.ink3,
                            borderRadius: BorderRadius.circular(10))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(height: 13, color: TaarColors.ink3),
                          const SizedBox(height: 5),
                          Container(height: 13, width: 180, color: TaarColors.ink3),
                          const SizedBox(height: 8),
                          Container(height: 11, width: 110, color: TaarColors.ink3),
                          const SizedBox(height: 4),
                          Container(height: 11, width: 80, color: TaarColors.ink3),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadMoreIndicator() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(color: TaarColors.marigold, strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('Loading more…',
                style: TextStyle(color: TaarColors.creamDim, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildEndOfList() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline_rounded,
                color: TaarColors.creamDim, size: 14),
            SizedBox(width: 6),
            Text("You're all caught up",
                style: TextStyle(color: TaarColors.creamDim, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Video tile — wider thumbnail, cleaner info layout
// ─────────────────────────────────────────────────────────────────────────────

class _VideoTile extends StatelessWidget {
  final YtVideo video;
  final VoidCallback onTap;

  const _VideoTile({required this.video, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: TaarColors.marigold.withOpacity(0.08),
      highlightColor: TaarColors.marigold.withOpacity(0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    video.thumbnail,
                    width: 130,
                    height: 74,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 130, height: 74,
                      color: TaarColors.ink3,
                      child: const Icon(Icons.music_video,
                          color: TaarColors.creamDim, size: 28),
                    ),
                  ),
                ),
                // Duration badge
                if (video.durationFormatted.isNotEmpty)
                  Positioned(
                    right: 4, bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.82),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        video.durationFormatted,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    video.channelName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: TaarColors.creamDim, fontSize: 12),
                  ),
                  if (video.viewCount.isNotEmpty || video.timeAgo.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      [video.viewCount, video.timeAgo]
                          .where((s) => s.isNotEmpty)
                          .join('  ·  '),
                      style: const TextStyle(color: TaarColors.creamDim, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.more_vert_rounded, color: TaarColors.creamDim, size: 18),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// YtPlaylistScreen — full-screen playlist/album view for a YouTube playlist.
// Filters out videos with duration < 80 seconds (intros, skits, shorts).
// ─────────────────────────────────────────────────────────────────────────────

class YtPlaylistScreen extends StatefulWidget {
  final YtPlaylist playlist;
  final List<YtVideo> tracks;
  final void Function(YtVideo) onPlayVideo;

  const YtPlaylistScreen({
    super.key,
    required this.playlist,
    required this.tracks,
    required this.onPlayVideo,
  });

  @override
  State<YtPlaylistScreen> createState() => _YtPlaylistScreenState();
}

class _YtPlaylistScreenState extends State<YtPlaylistScreen> {
  // Tracks are already filtered at the API layer (isShortVideo / kMinTrackSeconds)
  // before they reach this screen. We just show what we receive.
  List<YtVideo> get _filtered => widget.tracks;

  String get _subtitle {
    final count = widget.tracks.length;
    return '$count ${count == 1 ? 'song' : 'songs'}';
  }

  void _playAll() {
    if (_filtered.isEmpty) return;
    _filtered.first; // just trigger open via callback
    _openFirst();
  }

  void _openFirst() {
    if (_filtered.isEmpty) return;
    widget.onPlayVideo(_filtered.first);
  }

  void _shufflePlay() {
    if (_filtered.isEmpty) return;
    final shuffled = List<YtVideo>.from(_filtered)..shuffle();
    widget.onPlayVideo(shuffled.first);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TaarColors.ink,
      body: CustomScrollView(
        slivers: [
          // ── Collapsible header ──────────────────────────────────────────
          SliverAppBar(
            backgroundColor: TaarColors.ink,
            pinned: true,
            expandedHeight: 280,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.pin,
              background: _buildHeader(),
            ),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Divider(height: 1, color: TaarColors.line),
            ),
          ),

          // ── Play / Shuffle bar ──────────────────────────────────────────
          SliverToBoxAdapter(child: _buildPlayBar()),

          // ── Song list ───────────────────────────────────────────────────
          if (_filtered.isEmpty)
            SliverFillRemaining(child: _buildEmpty())
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => _buildTrackTile(_filtered[i], i),
                childCount: _filtered.length,
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 140)),
        ],
      ),
      bottomNavigationBar: Consumer<AppState>(
        builder: (context, app, _) {
          if (app.currentSong == null) return const SizedBox.shrink();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: MiniPlayer(),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader() {
    final thumb = widget.playlist.thumbnail;
    return Container(
      color: TaarColors.ink,
      padding: const EdgeInsets.fromLTRB(16, 90, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Playlist art
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: thumb.isNotEmpty
                ? Image.network(
                    thumb,
                    width: 148,
                    height: 148,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _artFallback(),
                  )
                : _artFallback(),
          ),
          const SizedBox(width: 16),
          // Title + meta
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF0000).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                        color: const Color(0xFFFF0000).withOpacity(0.4)),
                  ),
                  child: const Text(
                    'YouTube Music',
                    style: TextStyle(
                        color: Color(0xFFFF0000),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.playlist.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _subtitle,
                  style: const TextStyle(
                      color: TaarColors.creamDim,
                      fontSize: 12.5,
                      height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _artFallback() => Container(
        width: 148,
        height: 148,
        color: TaarColors.ink3,
        child: const Icon(Icons.queue_music_rounded,
            color: TaarColors.creamDim, size: 48),
      );

  Widget _buildPlayBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          // Play all
          Expanded(
            child: FilledButton.icon(
              onPressed: _filtered.isEmpty ? null : _playAll,
              style: FilledButton.styleFrom(
                backgroundColor: TaarColors.marigold,
                foregroundColor: TaarColors.ink,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text('Play',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ),
          ),
          const SizedBox(width: 10),
          // Shuffle
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _filtered.isEmpty ? null : _shufflePlay,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: TaarColors.line),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              icon: const Icon(Icons.shuffle_rounded, size: 18),
              label: const Text('Shuffle',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackTile(YtVideo v, int index) {
    return InkWell(
      onTap: () => widget.onPlayVideo(v),
      splashColor: TaarColors.marigold.withOpacity(0.08),
      highlightColor: TaarColors.marigold.withOpacity(0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Index number
            SizedBox(
              width: 28,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: TaarColors.creamDim,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 8),
            // Thumbnail
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    v.thumbnail,
                    width: 112,
                    height: 63,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 112,
                      height: 63,
                      color: TaarColors.ink3,
                      child: const Icon(Icons.music_video,
                          color: TaarColors.creamDim, size: 24),
                    ),
                  ),
                ),
                if (v.durationFormatted.isNotEmpty)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.82),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        v.durationFormatted,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    v.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  if (v.channelName.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      v.channelName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: TaarColors.creamDim, fontSize: 11.5),
                    ),
                  ],
                  if (v.viewCount.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      v.viewCount,
                      style: const TextStyle(
                          color: TaarColors.creamDim, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.more_vert_rounded,
                color: TaarColors.creamDim, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.playlist_remove_rounded,
              color: TaarColors.creamDim, size: 52),
          const SizedBox(height: 14),
          Text('No songs found',
              style: GoogleFonts.poppins(
                  color: TaarColors.creamDim,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
            'No songs available in this playlist',
            textAlign: TextAlign.center,
            style:
                TextStyle(color: TaarColors.creamDim, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// YouTube Speed Dial Card — thumbnail art with play overlay and title label
// ─────────────────────────────────────────────────────────────────────────────

class _YtSpeedDialCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const _YtSpeedDialCard({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Thumbnail
            Image.network(
              song.image,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: TaarColors.ink3,
                child: const Icon(Icons.music_video,
                    color: TaarColors.creamDim, size: 32),
              ),
            ),

            // Gradient overlay for legibility
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.80),
                    ],
                    stops: const [0.4, 1.0],
                  ),
                ),
              ),
            ),

            // Song title at bottom
            Positioned(
              left: 5, right: 5, bottom: 5,
              child: Text(
                song.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  height: 1.25,
                ),
              ),
            ),

            // YouTube red play badge top-left
            Positioned(
              top: 5, left: 5,
              child: Container(
                width: 20, height: 20,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF0000).withOpacity(0.85),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow,
                    size: 13, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Search result row — matches JioSaavn search_screen style exactly
// ─────────────────────────────────────────────────────────────────────────────

class _SearchVideoTile extends StatelessWidget {
  final YtVideo video;
  final String subtitle;
  final VoidCallback onTap;
  final bool circular;

  const _SearchVideoTile({
    required this.video,
    required this.subtitle,
    required this.onTap,
    this.circular = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: TaarColors.marigold.withOpacity(0.08),
      highlightColor: TaarColors.marigold.withOpacity(0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(circular ? 26 : 6),
              child: Image.network(
                video.thumbnail,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 52,
                  height: 52,
                  color: TaarColors.ink3,
                  child: const Icon(Icons.music_video,
                      color: TaarColors.creamDim, size: 22),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: TaarColors.creamDim, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.more_vert, color: TaarColors.creamDim, size: 20),
          ],
        ),
      ),
    );
  }
}
