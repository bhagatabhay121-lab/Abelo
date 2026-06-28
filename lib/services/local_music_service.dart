import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:audio_info/audio_info.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';

/// A local song, parsed from the device file system.
class LocalSong {
  final String id;       // absolute file path (stable on-device key)
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationSec;
  final String? artPath; // embedded-art cache path, null until extracted
  DateTime addedAt;
  bool isFavourite;

  LocalSong({
    required this.id,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationSec = 0,
    this.artPath,
    DateTime? addedAt,
    this.isFavourite = false,
  }) : addedAt = addedAt ?? DateTime.now();

  /// Convert to the shared [Song] model so all existing playback, Speed Dial,
  /// and NowPlaying widgets work without modification.
  Song toSong() => Song(
        id: 'local:$id',
        title: title,
        artist: artist,
        image: artPath ?? '',
        album: album.isNotEmpty ? album : null,
        durationSec: durationSec,
        mediaUrl: 'file://$path',
        mediaUrls: {'local': 'file://$path'},
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'durationSec': durationSec,
        'artPath': artPath,
        'addedAt': addedAt.toIso8601String(),
        'isFavourite': isFavourite,
      };

  factory LocalSong.fromJson(Map<String, dynamic> j) => LocalSong(
        id: j['id'] as String,
        path: j['path'] as String,
        title: j['title'] as String? ?? 'Unknown',
        artist: j['artist'] as String? ?? 'Unknown Artist',
        album: j['album'] as String? ?? '',
        durationSec: j['durationSec'] as int? ?? 0,
        artPath: j['artPath'] as String?,
        addedAt: j['addedAt'] != null
            ? DateTime.tryParse(j['addedAt'] as String) ?? DateTime.now()
            : DateTime.now(),
        isFavourite: j['isFavourite'] as bool? ?? false,
      );

  LocalSong copyWith({String? artPath, bool? isFavourite}) => LocalSong(
        id: id,
        path: path,
        title: title,
        artist: artist,
        album: album,
        durationSec: durationSec,
        artPath: artPath ?? this.artPath,
        addedAt: addedAt,
        isFavourite: isFavourite ?? this.isFavourite,
      );
}

enum LocalSortOrder { title, artist, album, dateAdded, duration }

/// Scans the device for audio files and maintains a persisted local library.
///
/// Scanning strategy (Android/iOS):
///   1. Walk the standard music directories recursively.
///   2. Collect files whose extension is in [_kAudioExts].
///   3. Build [LocalSong] entries with names parsed from the file path because
///      we do NOT pull in `on_audio_query` or `flutter_media_metadata` to keep
///      the dependency list minimal — titles are derived from the filename and
///      can be enriched by a metadata plugin later without changing this API.
///
/// All state changes call [notifyListeners], so consumers can `watch<>` it.
class LocalMusicService extends ChangeNotifier {
  static const _kPrefsKey = 'local_library_v1';

  static const _kAudioExts = {
    '.mp3', '.m4a', '.aac', '.flac', '.ogg',
    '.wav', '.opus', '.wma', '.alac',
  };

  // Directories scanned on Android. On iOS we only accept user-picked files.
  static const _kScanRoots = [
    '/storage/emulated/0/Music',
    '/storage/emulated/0/Download',
    '/sdcard/Music',
  ];

  // ── State ─────────────────────────────────────────────────────────────────

  List<LocalSong> _songs = [];
  List<LocalSong> get songs => _songs;

  bool isScanning = false;
  int scanProgress = 0;   // files found so far during scan
  String? scanError;

  LocalSortOrder sortOrder = LocalSortOrder.title;
  bool sortAscending = true;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  // Recently imported via file-picker (single or multi)
  final List<LocalSong> _importQueue = [];

  // ── Init ──────────────────────────────────────────────────────────────────

  Directory? _artCacheDir;

  LocalMusicService() {
    _initAndRestore();
  }

  Future<void> _initAndRestore() async {
    final appDir = await getApplicationSupportDirectory();
    _artCacheDir = Directory(p.join(appDir.path, 'art_cache'));
    if (!await _artCacheDir!.exists()) {
      await _artCacheDir!.create(recursive: true);
    }
    await _restore();
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _songs = list
            .map((e) => LocalSong.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _applySort();
      } catch (_) {
        _songs = [];
      }
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kPrefsKey, jsonEncode(_songs.map((s) => s.toJson()).toList()));
  }

  // ── Scan ──────────────────────────────────────────────────────────────────

  /// Scan standard music folders on Android.
  /// Call after storage permission is granted.
  /// [excludePaths] — file paths that should not be imported as [LocalSong]s
  /// because they are already tracked elsewhere (e.g. AppState._downloads).
  /// Pass an empty set (the default) to retain the previous behaviour.
  Future<void> scanDevice({Set<String> excludePaths = const {}}) async {
    if (isScanning) return;
    isScanning = true;
    scanProgress = 0;
    scanError = null;
    notifyListeners();

    try {
      final found = <String>[];

      for (final root in _kScanRoots) {
        final dir = Directory(root);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final ext = p.extension(entity.path).toLowerCase();
            if (_kAudioExts.contains(ext)) {
              found.add(entity.path);
              scanProgress = found.length;
              if (found.length % 10 == 0) notifyListeners();
            }
          }
        }
      }

      final existingPaths = {for (final s in _songs) s.path};
      int added = 0;

      for (final filePath in found) {
        // Skip files that are already tracked as app downloads so the song
        // doesn't appear in both the Downloads section and the local library.
        if (excludePaths.contains(filePath)) continue;
        if (!existingPaths.contains(filePath)) {
          _songs.add(await _songFromPath(filePath));
          added++;
        }
      }

      // Also evict any previously-scanned songs whose paths are now excluded
      // (handles the case where the user scanned before downloading).
      _songs.removeWhere((s) => excludePaths.contains(s.path));

      // Remove songs whose file has been deleted
      _songs.removeWhere((s) => !File(s.path).existsSync());

      if (added > 0 || _songs.length != found.length) {
        _applySort();
        await _persist();
      }
    } catch (e) {
      scanError = e.toString();
    } finally {
      isScanning = false;
      notifyListeners();
    }
  }

  /// Add a list of explicitly picked file paths (from file_picker).
  Future<void> importFiles(List<String> paths) async {
    final existingPaths = {for (final s in _songs) s.path};
    bool changed = false;
    for (final path in paths) {
      if (existingPaths.contains(path)) continue;
      final ext = p.extension(path).toLowerCase();
      if (!_kAudioExts.contains(ext)) continue;
      final song = await _songFromPath(path);
      _songs.add(song);
      _importQueue.add(song);
      existingPaths.add(path);
      changed = true;
    }
    if (changed) {
      _applySort();
      notifyListeners();
      await _persist();
    }
  }

  /// Remove a song from the local library (does NOT delete the file).
  Future<void> removeSong(String songId) async {
    _songs.removeWhere((s) => s.id == songId);
    notifyListeners();
    await _persist();
  }

  Future<void> clearAll() async {
    _songs.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPrefsKey);
  }

  // ── Favourite ─────────────────────────────────────────────────────────────

  Future<void> toggleFavourite(String songId) async {
    final idx = _songs.indexWhere((s) => s.id == songId);
    if (idx < 0) return;
    _songs[idx] = _songs[idx].copyWith(isFavourite: !_songs[idx].isFavourite);
    notifyListeners();
    await _persist();
  }

  List<LocalSong> get favourites =>
      _filteredSongs.where((s) => s.isFavourite).toList();

  // ── Sorting / search ──────────────────────────────────────────────────────

  void setSort(LocalSortOrder order, {bool? ascending}) {
    if (sortOrder == order) {
      sortAscending = ascending ?? !sortAscending;
    } else {
      sortOrder = order;
      sortAscending = ascending ?? true;
    }
    _applySort();
    notifyListeners();
  }

  void setSearch(String query) {
    _searchQuery = query.toLowerCase();
    notifyListeners();
  }

  List<LocalSong> get _filteredSongs {
    if (_searchQuery.isEmpty) return _songs;
    return _songs
        .where((s) =>
            s.title.toLowerCase().contains(_searchQuery) ||
            s.artist.toLowerCase().contains(_searchQuery) ||
            s.album.toLowerCase().contains(_searchQuery))
        .toList();
  }

  List<LocalSong> get filteredSongs => _filteredSongs;

  void _applySort() {
    int cmp(LocalSong a, LocalSong b) {
      switch (sortOrder) {
        case LocalSortOrder.title:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case LocalSortOrder.artist:
          return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        case LocalSortOrder.album:
          return a.album.toLowerCase().compareTo(b.album.toLowerCase());
        case LocalSortOrder.dateAdded:
          return a.addedAt.compareTo(b.addedAt);
        case LocalSortOrder.duration:
          return a.durationSec.compareTo(b.durationSec);
      }
    }

    _songs.sort((a, b) => sortAscending ? cmp(a, b) : cmp(b, a));
  }

  // ── Albums / Artists ──────────────────────────────────────────────────────

  Map<String, List<LocalSong>> get albums {
    final map = <String, List<LocalSong>>{};
    for (final s in _songs) {
      final key = s.album.isNotEmpty ? s.album : 'Unknown Album';
      map.putIfAbsent(key, () => []).add(s);
    }
    return map;
  }

  Map<String, List<LocalSong>> get artists {
    final map = <String, List<LocalSong>>{};
    for (final s in _songs) {
      map.putIfAbsent(s.artist, () => []).add(s);
    }
    return map;
  }

  // ── Playlists ─────────────────────────────────────────────────────────────

  final List<_LocalPlaylist> _playlists = [];
  List<_LocalPlaylist> get playlists => List.unmodifiable(_playlists);

  void createPlaylist(String name) {
    _playlists.add(_LocalPlaylist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
    ));
    notifyListeners();
  }

  void addToPlaylist(String playlistId, LocalSong song) {
    final pl = _playlists.firstWhere((p) => p.id == playlistId,
        orElse: () => throw StateError('playlist not found'));
    if (!pl.songIds.contains(song.id)) {
      pl.songIds.add(song.id);
      notifyListeners();
    }
  }

  void removeFromPlaylist(String playlistId, String songId) {
    final pl = _playlists.firstWhere((p) => p.id == playlistId,
        orElse: () => throw StateError('playlist not found'));
    pl.songIds.remove(songId);
    notifyListeners();
  }

  void deletePlaylist(String playlistId) {
    _playlists.removeWhere((p) => p.id == playlistId);
    notifyListeners();
  }

  List<LocalSong> songsForPlaylist(String playlistId) {
    final pl = _playlists.firstWhere((p) => p.id == playlistId,
        orElse: () => throw StateError('playlist not found'));
    return _songs.where((s) => pl.songIds.contains(s.id)).toList();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<LocalSong> _songFromPath(String filePath) async {
    final filename = p.basenameWithoutExtension(filePath);
    // Try to parse "Artist - Title" from filename
    String title = filename;
    String artist = 'Unknown Artist';
    String album = '';

    // Infer album from parent folder name
    final parentDir = p.basename(p.dirname(filePath));
    if (parentDir != 'Music' &&
        parentDir != 'Download' &&
        parentDir != 'Taar') {
      album = parentDir;
    }

    // "Artist - Title" heuristic
    if (filename.contains(' - ')) {
      final parts = filename.split(' - ');
      if (parts.length >= 2) {
        artist = parts[0].trim();
        title = parts.sublist(1).join(' - ').trim();
      }
    }

    // Try embedded cover art first via audio_info
    String? detectedArtPath = await _extractArtwork(filePath);

    // Sidecar fallback: "Song Title.jpg" next to "Song Title.m4a"
    if (detectedArtPath == null) {
      final basePath = filePath.substring(0, filePath.lastIndexOf('.'));
      for (final ext in ['.jpg', '.jpeg', '.png']) {
        final candidate = '$basePath$ext';
        if (File(candidate).existsSync()) {
          detectedArtPath = candidate;
          break;
        }
      }
    }

    return LocalSong(
      id: filePath,
      path: filePath,
      title: title,
      artist: artist,
      album: album,
      artPath: detectedArtPath,
    );
  }

  /// Extracts embedded cover art via [AudioInfo] and caches it to disk.
  /// Returns the cached image path, or null if no artwork is found.
  Future<String?> _extractArtwork(String filePath) async {
    if (_artCacheDir == null) return null;
    try {
      final Uint8List? artwork = await AudioInfo.getAudioImage(filePath);
      if (artwork == null || artwork.isEmpty) return null;
      final cacheKey = filePath.hashCode.toUnsigned(32).toRadixString(16);
      final cacheFile = File(p.join(_artCacheDir!.path, '$cacheKey.jpg'));
      if (!await cacheFile.exists()) {
        await cacheFile.writeAsBytes(artwork);
      }
      return cacheFile.path;
    } catch (_) {
      return null;
    }
  }
}

class _LocalPlaylist {
  final String id;
  String name;
  final List<String> songIds = [];

  _LocalPlaylist({required this.id, required this.name});
}