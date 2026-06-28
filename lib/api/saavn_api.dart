import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dart_des/dart_des.dart';
import '../models/song.dart';

/// Talks directly to JioSaavn's private web API — main.py is no longer
/// needed. Same method names/signatures as before, so screens/widgets that
/// call `api.fetchHomeData()`, `api.search(...)`, etc. don't need to change.
///
/// The one thing main.py was doing that a plain HTTP client can't skip:
/// JioSaavn returns every stream link as `encrypted_media_url` (DES/ECB,
/// fixed key, base64). That decryption now happens here on-device via
/// pointycastle instead of server-side — see enrichMediaUrls() below,
/// ported 1:1 from main.py's enrich_media_urls()/decrypt_media_url().
class SaavnApi {
  static const _jioHost = 'www.jiosaavn.com';
  static const _apiStr = '/api.php?_format=json&_marker=0&ctx=web6dot0';

  static const _desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _mobileUA =
      'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/149.0.0.0 Mobile Safari/537.36';

  /// Full session cookie from your own jiosaavn.com browser session.
  /// reco.getreco seems to need a "real" session to return results.
  ///
  /// NOTE: this string carries your real geo location, session, and
  /// ad-tracking IDs. Fine for a personal build on your own device — do
  /// NOT commit this file to a public repo or ship it in a shared APK.
  static const String _sessionCookie =
      '_ga_BXVL6HHR7F=GS2.1.s1754145673\$o1\$g0\$t1754145673\$j60\$l0\$h0; '
      '_ga=GA1.1.1586258144.1754145673; B=c69be7ae799c7dfe35494f836b9773aa; '
      'L=hindi; mm_latlong=22.3008%2C73.2043; CT=NzU4OTY0MDcz; _pl=web6dot0-; '
      'DL=english; geo=2409%3A40c1%3A4159%3Af53f%3Ac890%3A4ae0%3A74f6%3A8ce3%2CIN%2CGujarat%2CVadodara%2C390001; '
      'CH=G03%2CA07%2CO00%2CL03; '
      'FCCDCF=%5Bnull%2Cnull%2Cnull%2Cnull%2Cnull%2Cnull%2C%5B%5B32%2C%22%5B%5C%224da6488f-d42f-426a-b87a-c50e5faf33d7%5C%22%2C%5B1776507851%2C315000000%5D%5D%22%5D%5D%5D; '
      'FCNEC=%5B%5B%22AKsRol-Hmsc_FCXl23o582kKTSQilzKmm18VPCvQdfA-LW-23AvHCAoykC3P5yC9deMUKWnX-nF_Nixq6uIqgOPS7mkXI-qg9k9l5_3_M2Ie2CNWOPuRs7QKSxL3Z38I_k1cBZQrnifQtBC9ItYx30i-rDIhQtVu9g%3D%3D%22%5D%5D; '
      'network=phone; SG=u; '
      '__gads=ID=5b22d2fec7dac0da:T=1776507852:RT=1781969877:S=ALNI_MY3NWpSsgxbbA2vnZAz7DsD7SBNfw; '
      '__gpi=UID=00001269353d8f69:T=1776507852:RT=1781969877:S=ALNI_MZcYgX4X4HSX_b_iuBL2gA8LjEP0A; '
      '__eoi=ID=df1961e6f11b0da9:T=1776507852:RT=1781969877:S=AA-AfjaR5mPytphVRsz-O2pc8aiv; '
      '_ga_0S33EMSFSM=GS2.1.s1781968890\$o19\$g1\$t1781970147\$j60\$l0\$h0; '
      'I=qp1cy7Jy5j%2FpUKV4EbYJ23N2y7hNqTaRadiYDkJc0bUiGxtz4HzvNkh7s0XL2KeObf%2BPx43m2zzv4dhoI5IMCZvPzSt%2BOWEBgQ948Ew1r4FH5JXmF87OwPCzH%2B%2BSMTYxssTedISjtfrull8xh%2FhOfifiswT%2B248v7gwGg9QvqVpi1FjvZ4dSffkG%2FMNn1RvjlrttHwb3%2BklnFJP%2BZPWFdRwP89t%2Fenl6GkTr4xjHZ%2FN6%2F5tx0RN%2FwQUAX7Rcfwd470%2F9iOB7%2F5z2tIJnlgu%2FcCCX5eUpx6s9Mz1RFQoLIjGIbJSJ1jRsBvNEK5wfDBFu';

  Map<String, String> _headers({bool fullSession = false}) => {
        'Accept': '*/*',
        'User-Agent': fullSession ? _mobileUA : _desktopUA,
        'Referer': 'https://www.jiosaavn.com/',
        'Cookie': fullSession ? _sessionCookie : 'L=hindi%2Cenglish',
      };

  Uri _u(String params, {bool v4 = true}) {
    final base = v4 ? '$_apiStr&api_version=4' : _apiStr;
    return Uri.parse('https://$_jioHost$base&$params');
  }

  Future<dynamic> _getRaw(Uri uri, {bool fullSession = false}) async {
    final res = await http
        .get(uri, headers: _headers(fullSession: fullSession))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('JioSaavn error ${res.statusCode}: ${res.body}');
    }
    return jsonDecode(res.body);
  }

  Future<Map<String, dynamic>> _get(Uri uri, {bool fullSession = false}) async {
    final decoded = await _getRaw(uri, fullSession: fullSession);
    enrichMediaUrls(decoded);
    if (decoded is List) return {'list': decoded};
    return Map<String, dynamic>.from(decoded as Map);
  }

  // ---- Home -------------------------------------------------------------
  Future<Map<String, dynamic>> fetchHomeData() =>
      _get(_u('__call=webapi.getLaunchData'));

  // ---- Search -------------------------------------------------------------
  Future<Map<String, dynamic>> search(String q) => _get(
      _u('p=1&q=${Uri.encodeQueryComponent(q)}&n=20&__call=search.getResults'));
  Future<Map<String, dynamic>> searchSongs(String q) => _get(
      _u('p=1&q=${Uri.encodeQueryComponent(q)}&n=5&__call=search.getResults'));
  Future<Map<String, dynamic>> searchAlbums(String q) => _get(_u(
      'p=1&q=${Uri.encodeQueryComponent(q)}&n=5&__call=search.getAlbumResults'));
  Future<Map<String, dynamic>> searchArtists(String q) => _get(_u(
      'p=1&q=${Uri.encodeQueryComponent(q)}&n=5&__call=search.getArtistResults'));
  Future<Map<String, dynamic>> searchPlaylists(String q) => _get(_u(
      'p=1&q=${Uri.encodeQueryComponent(q)}&n=5&__call=search.getPlaylistResults'));

  // ---- Details -------------------------------------------------------------
  Future<Map<String, dynamic>> fetchAlbum(String albumId) => _get(_u(
      '__call=content.getAlbumDetails&cc=in&albumid=${Uri.encodeQueryComponent(albumId)}'));
  Future<Map<String, dynamic>> fetchPlaylist(String playlistId) => _get(_u(
      '__call=playlist.getDetails&cc=in&listid=${Uri.encodeQueryComponent(playlistId)}'));

  /// Fetch a playlist by its full JioSaavn share URL.
  /// Supports URLs like:
  ///   https://www.jiosaavn.com/s/playlist/.../<token>
  ///   https://www.jiosaavn.com/featured/.../<token>
  Future<Map<String, dynamic>> fetchPlaylistByUrl(String url) async {
    final token = _extractToken(url);
    if (token == null) throw Exception('Could not extract playlist token from URL');
    return _get(_u('__call=webapi.get&token=${Uri.encodeQueryComponent(token)}&type=playlist&p=1&n=500&includeMetaTags=0'));
  }

  /// Extract the last path segment (token) from a JioSaavn share URL.
  static String? _extractToken(String url) {
    try {
      final uri = Uri.parse(url.trim());
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      return segments.isNotEmpty ? segments.last : null;
    } catch (_) {
      return null;
    }
  }
  Future<Map<String, dynamic>> fetchSong(String songId) => _get(_u(
      'pids=${Uri.encodeQueryComponent(songId)}&__call=song.getDetails'));
  Future<Map<String, dynamic>> fetchArtist(String artistId) => _get(_u(
      'artistId=${Uri.encodeQueryComponent(artistId)}&n_song=20&n_album=20&page=1'
      '&category=alphabetical&sort_order=asc&__call=artist.getArtistPageDetails'));

  // ---- Playback / lyrics / recs ---------------------------------------------
  Future<Map<String, dynamic>> fetchSongUrl(String songId,
      {String quality = '160kbps'}) async {
    final data = await _get(
        _u('pids=${Uri.encodeQueryComponent(songId)}&__call=song.getDetails'));

    final song = _findSongObject(data, songId);
    if (song == null) {
      throw Exception('song not found in JioSaavn response');
    }

    final moreInfo = (song['more_info'] is Map)
        ? Map<String, dynamic>.from(song['more_info'])
        : song;
    final mediaUrlsRaw = (moreInfo['media_urls'] ?? song['media_urls'] ?? {});
    final mediaUrls = Map<String, String>.from(mediaUrlsRaw as Map);

    final chosen = mediaUrls[quality] ??
        mediaUrls['160kbps'] ??
        mediaUrls['96kbps'] ??
        mediaUrls['320kbps'] ??
        (mediaUrls.isNotEmpty ? mediaUrls.values.first : null);

    if (chosen == null) {
      throw Exception(
          'Could not derive a playable URL for $songId (encrypted_media_url missing/undecryptable)');
    }

    return {
      'status': 'success',
      'id': song['id'] ?? songId,
      'title': song['title'] ?? song['song'],
      'duration': moreInfo['duration'] ?? song['duration'],
      'image': song['image'],
      'media_urls': mediaUrls,
      'media_url': chosen,
      'quality': quality,
    };
  }

  Future<Map<String, dynamic>> fetchLyrics(String songId) => _get(_u(
      '__call=lyrics.getLyrics&lyrics_id=${Uri.encodeQueryComponent(songId)}'));

  /// reco.getreco returns a BARE JSON ARRAY (not the usual keyed dict),
  /// and needs the mobile UA + full session cookie to return results.
  Future<List<Song>> fetchReco(String songId) async {
    final raw = await _getRaw(
      _u('__call=reco.getreco&pid=${Uri.encodeQueryComponent(songId)}'),
      fullSession: true,
    );

    final List list = raw is List
        ? raw
        : (raw is Map ? (raw['songs'] ?? raw['data'] ?? []) : []);

    enrichMediaUrls(list);
    return list
        .map((e) => Song.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchAlbumReco(String albumId) async {
    final data = await _get(_u(
        'albumid=\${Uri.encodeQueryComponent(albumId)}&language=hindi&k=20&__call=reco.getAlbumReco'));
    final raw = data['list'] ?? data['data'] ?? data['albums'] ?? data['reco'] ?? [];
    if (raw is List) return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return [];
  }

  Future<List<Song>> fetchArtistOtherTopSongs(String artistId,
      {String songId = ''}) async {
    final data = await _get(_u(
      'artist_ids=${Uri.encodeQueryComponent(artistId)}&song_id=${Uri.encodeQueryComponent(songId)}'
      '&language=hindi,english&count=20&__call=search.artistOtherTopSongs',
    ));
    final list = (data['songs'] ?? data['data'] ?? data['list'] ?? []) as List;
    return list
        .map((e) => Song.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  // ---- Radio -------------------------------------------------------------
  Future<Map<String, dynamic>> createArtistRadio(String name) => _get(_u(
      'name=${Uri.encodeQueryComponent(name)}&language=hindi&__call=webradio.createArtistStation'));
  Future<Map<String, dynamic>> createFeaturedRadio(String name) => _get(_u(
      'name=${Uri.encodeQueryComponent(name)}&language=hindi&__call=webradio.createFeaturedStation'));
  Future<List<Song>> getRadioSongs(String stationId, {int count = 10}) async {
    final data = await _get(_u(
        'stationid=${Uri.encodeQueryComponent(stationId)}&k=$count&__call=webradio.getSong'));
    final list = (data['songs'] ?? data['list'] ?? []) as List;
    return list
        .map((e) => Song.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  // ---- helpers -------------------------------------------------------------
  Map<String, dynamic>? _findSongObject(
      Map<String, dynamic> data, String songId) {
    if (data[songId] is Map) {
      return Map<String, dynamic>.from(data[songId] as Map);
    }
    for (final key in ['songs', 'data']) {
      final v = data[key];
      if (v is List && v.isNotEmpty) {
        for (final item in v) {
          if (item is Map && item['id']?.toString() == songId) {
            return Map<String, dynamic>.from(item);
          }
        }
        if (v.first is Map) return Map<String, dynamic>.from(v.first as Map);
      }
    }
    if (data.containsKey('more_info') ||
        data.containsKey('encrypted_media_url')) {
      return data;
    }
    if (data.length == 1) {
      final only = data.values.first;
      if (only is Map) return Map<String, dynamic>.from(only);
    }
    return null;
  }
}

// ============================================================
// JioSaavn media-URL decryption — ported from main.py
// ------------------------------------------------------------
// JioSaavn encrypts every streamable URL with DES (ECB mode,
// PKCS5 padding) under a fixed, long-public key. Decrypting
// `encrypted_media_url` yields a plain CDN URL targeting 96kbps;
// every other bitrate is the same path with the suffix swapped.
// ============================================================
const String _desKey = '38346591';
const Map<String, String> _qualitySuffix = {
  '12kbps': '_12.mp4',
  '48kbps': '_48.mp4',
  '96kbps': '_96.mp4',
  '160kbps': '_160.mp4',
  '320kbps': '_320.mp4',
};

String? _decryptMediaUrl(String? encrypted) {
  if (encrypted == null || encrypted.isEmpty) return null;
  try {
    // JioSaavn sends URL-safe base64 (- and _ instead of + and /) with no
    // padding. Must normalize before decoding — this was the silent failure.
    String b64 = encrypted.trim().replaceAll('-', '+').replaceAll('_', '/');
    final int rem = b64.length % 4;
    if (rem != 0) b64 += '=' * (4 - rem);
    final raw = base64.decode(b64);

    // Use dart_des for single DES ECB — the encrypt package has no DES class,
    // and pointycastle 3.x+ removed DESEngine from its public API.
    final des = DES(
      key: utf8.encode(_desKey),
      mode: DESMode.ECB,
      paddingType: DESPaddingType.PKCS5,
    );
    final decrypted = des.decrypt(raw);
    return utf8.decode(decrypted);
  } catch (_) {
    return null;
  }
}

Map<String, String> _buildQualityUrls(String decryptedUrl) {
  if (decryptedUrl.contains('_96.mp4')) {
    final base = decryptedUrl.replaceAll('_96.mp4', '{suffix}');
    return _qualitySuffix
        .map((q, suf) => MapEntry(q, base.replaceAll('{suffix}', suf)));
  }
  return {'320kbps': decryptedUrl};
}

/// Walk any JSON structure returned by JioSaavn and, wherever an
/// `encrypted_media_url` field is found, decrypt it in place and attach:
///   - media_urls: { "12kbps": url, ... "320kbps": url }
///   - media_url:  the 160kbps URL, as a convenience default
/// Mirrors enrich_media_urls() in main.py — runs on-device now instead
/// of on the (removed) backend.
void enrichMediaUrls(dynamic node) {
  if (node is Map) {
    final enc = node['encrypted_media_url'];
    if (enc is String && enc.isNotEmpty && !node.containsKey('media_urls')) {
      final decrypted = _decryptMediaUrl(enc);
      if (decrypted != null) {
        final qualities = _buildQualityUrls(decrypted);
        node['media_urls'] = qualities;
        node['media_url'] = qualities['160kbps'] ??
            (qualities.isNotEmpty ? qualities.values.first : null);
      }
    }
    for (final v in node.values.toList()) {
      enrichMediaUrls(v);
    }
  } else if (node is List) {
    for (final item in node) {
      enrichMediaUrls(item);
    }
  }
}