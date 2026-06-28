import 'dart:convert';
import 'package:http/http.dart' as http;

/// A single time-stamped line from an LRCLIB `syncedLyrics` blob, e.g.
/// the line produced by parsing `[01:24.28] Yeah, I'm a big dawg (Big dawg)`.
class LrcLine {
  final Duration time;
  final String text;
  const LrcLine(this.time, this.text);
}

/// One result row from LRCLIB's `/api/search` endpoint. A single title
/// search (e.g. "Big Dawgs") can return many of these — different songs
/// that happen to share a name, different submissions of the same song,
/// instrumentals, etc. — so callers should let the user disambiguate
/// rather than blindly taking the first one.
class LrcLibResult {
  final int id;
  final String trackName;
  final String artistName;
  final String? albumName;
  final double duration; // seconds
  final bool instrumental;
  final String? plainLyrics;
  final String? syncedLyrics; // raw "[mm:ss.xx] text" block, or null

  const LrcLibResult({
    required this.id,
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.duration = 0,
    this.instrumental = false,
    this.plainLyrics,
    this.syncedLyrics,
  });

  factory LrcLibResult.fromJson(Map<String, dynamic> json) {
    double parseDuration(dynamic v) {
      if (v is num) return v.toDouble();
      return double.tryParse(v?.toString() ?? '') ?? 0;
    }

    return LrcLibResult(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      trackName:
          (json['trackName'] ?? json['name'] ?? '').toString().trim(),
      artistName: (json['artistName'] ?? '').toString().trim(),
      albumName: json['albumName']?.toString(),
      duration: parseDuration(json['duration']),
      instrumental: json['instrumental'] == true,
      plainLyrics: json['plainLyrics']?.toString(),
      syncedLyrics: json['syncedLyrics']?.toString(),
    );
  }

  bool get hasSynced =>
      !instrumental && syncedLyrics != null && syncedLyrics!.trim().isNotEmpty;
  bool get hasPlain =>
      !instrumental && plainLyrics != null && plainLyrics!.trim().isNotEmpty;

  /// LRC timestamps look like `[mm:ss.xx]` (occasionally `[mm:ss:xx]` or
  /// with 3-digit milliseconds). Lines with no readable text (pure music
  /// tags) are kept so timing stays correct, rendered as a bullet.
  static final RegExp _lrcLine =
      RegExp(r'^\[(\d{2}):(\d{2})(?:[.:](\d{1,3}))?\]\s*(.*)$');

  List<LrcLine> parseSynced() {
    if (!hasSynced) return const [];
    final lines = <LrcLine>[];
    for (final raw in syncedLyrics!.split('\n')) {
      final m = _lrcLine.firstMatch(raw.trim());
      if (m == null) continue;
      final minutes = int.parse(m.group(1)!);
      final seconds = int.parse(m.group(2)!);
      final fracRaw = (m.group(3) ?? '0').padRight(3, '0').substring(0, 3);
      final millis = int.parse(fracRaw);
      final text = (m.group(4) ?? '').trim();
      lines.add(LrcLine(
        Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
        text,
      ));
    }
    return lines;
  }
}

/// Thin client for https://lrclib.net's public lyrics API — the same
/// database backing the site's own search UI
/// (https://lrclib.net/search/big%20dawgs). Used to fetch time-synced
/// lyrics, which JioSaavn/lyrics.ovh don't provide.
class LrcLibApi {
  static const _searchUrl = 'https://lrclib.net/api/search';

  static Map<String, String> get _headers => {
        'User-Agent': 'TaarMusic (Flutter lyrics client)',
        'Accept': 'application/json',
      };

  /// Raw search — mirrors LRCLIB's own search box: title is required,
  /// artist narrows it down. Spaces in either field are percent-encoded
  /// (the %20 the site's URL bar shows) by [Uri]'s query encoding.
  static Future<List<LrcLibResult>> search({
    required String title,
    String? artist,
  }) async {
    final params = <String, String>{'track_name': title};
    if (artist != null && artist.trim().isNotEmpty) {
      params['artist_name'] = artist.trim();
    }
    final uri = Uri.parse(_searchUrl).replace(queryParameters: params);
    final res = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 12),
        );
    if (res.statusCode != 200) {
      throw Exception('lrclib search failed: ${res.statusCode}');
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => LrcLibResult.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Searches title+artist first (usually a tight, unambiguous match);
  /// if that comes back empty, retries with just the title — which is
  /// the broad "many lyrics for the same name" search the user sees at
  /// lrclib.net/search/<title>, and the reason picking a match manually
  /// matters: a bare title search can surface entirely different songs.
  static Future<List<LrcLibResult>> searchSmart({
    required String title,
    String? artist,
  }) async {
    if (artist != null && artist.trim().isNotEmpty) {
      try {
        final withArtist = await search(title: title, artist: artist);
        if (withArtist.isNotEmpty) return withArtist;
      } catch (_) {
        // fall through to the title-only search below
      }
    }
    return search(title: title);
  }
}
