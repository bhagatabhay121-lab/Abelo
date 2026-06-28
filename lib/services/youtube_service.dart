import 'dart:convert';
import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────────────────────────
// InnerTube client definitions
//
// Priority order (revised after cross-checking against YoutubeExplode's
// current, working implementation — see VideoController.cs):
//
//   1. ANDROID_VR (Oculus Quest)  — As of 2026, YouTube requires a Proof of
//      Origin (PO) token for stream URLs from almost every InnerTube client
//      (TV embedded, iOS, Android...). ANDROID_VR is the one client that
//      still does NOT require a PO token and returns fully-formed, directly
//      playable URLs. This is why YoutubeExplode uses it as its *primary*
//      client (github.com/Tyrrrz/YoutubeExplode, issue #933).
//
//      IMPORTANT: clientVersion must stay <= ~1.60. YouTube's own player
//      comments (see yt-dlp's INNERTUBE_CLIENTS) note that ANDROID_VR builds
//      newer than ~1.65 switch to SABR-only streaming, where the JSON no
//      longer contains plain playable `url` fields at all. The previous
//      version here (1.65.10) was *past* that threshold, which is a likely
//      reason streams kept failing — YoutubeExplode deliberately pins
//      1.60.19 to stay under it.
//
//   2. TVHTML5_SIMPLY_EMBEDDED_PLAYER — last-resort fallback. It still
//      returns formats for some videos (notably age-restricted ones), but
//      now requires a PO token for HTTPS/DASH playback too, so its URLs may
//      look valid in the JSON yet fail (or hang) once actually streamed.
//      Kept only as a final fallback, not tried first.
//
//   3. IOS / 4. ANDROID — broad fallbacks; also PO-token-gated in most
//      cases now, kept only in case a specific video responds differently.
// ─────────────────────────────────────────────────────────────────────────────

const _androidVrClient = {
  'clientName': 'ANDROID_VR',
  'clientVersion': '1.60.19',
  'deviceMake': 'Oculus',
  'deviceModel': 'Quest 3',
  'androidSdkVersion': 32,
  'userAgent':
      'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; Quest 3 Build/SQ3A.220605.009.A1) gzip',
  'osName': 'Android',
  'osVersion': '12L',
  'hl': 'en',
  'timeZone': 'UTC',
  'utcOffsetMinutes': 0,
};
const _androidVrClientName = '28';

const _tvEmbedClient = {
  'clientName': 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
  'clientVersion': '2.0',
  'hl': 'en',
  'timeZone': 'UTC',
  'utcOffsetMinutes': 0,
};
const _tvEmbedClientName = '85';

const _iosClient = {
  'clientName': 'IOS',
  'clientVersion': '21.02.3',
  'deviceMake': 'Apple',
  'deviceModel': 'iPhone16,2',
  'userAgent':
      'com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
  'osName': 'iPhone',
  'osVersion': '18.3.2.22D82',
  'hl': 'en',
  'timeZone': 'UTC',
  'utcOffsetMinutes': 0,
};
const _iosClientName = '5';

const _androidClient = {
  'clientName': 'ANDROID',
  'clientVersion': '21.02.35',
  'androidSdkVersion': 30,
  'userAgent':
      'com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip',
  'osName': 'Android',
  'osVersion': '11',
  'hl': 'en',
  'timeZone': 'UTC',
  'utcOffsetMinutes': 0,
};
const _androidClientName = '3';

const _innertubeEndpoint =
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';

const _webUA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────

class YtStreamFormat {
  final int itag;
  final String url;
  final String mime;
  final String quality;
  final int width;
  final int height;
  final int fps;
  final int bitrate;
  final int size;
  final String vcodec;
  final String acodec;
  final bool isMuxed;

  const YtStreamFormat({
    required this.itag,
    required this.url,
    required this.mime,
    required this.quality,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrate,
    required this.size,
    required this.vcodec,
    required this.acodec,
    required this.isMuxed,
  });

  String get label {
    final parts = <String>[];
    if (height > 0) parts.add('${height}p');
    if (fps > 0 && fps != 30) parts.add('@${fps}fps');
    if (isMuxed) parts.add('muxed');
    return parts.join(' ');
  }

  String get sizeLabel {
    if (size <= 0) return '';
    if (size >= 1024 * 1024 * 1024) return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    if (size >= 1024 * 1024) return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }
}

class YtVideoInfo {
  final String videoId;
  final String title;
  final String author;
  final String duration;
  final int durationSeconds;
  final String? hlsManifest;
  final List<YtStreamFormat> muxed;
  final List<YtStreamFormat> videoOnly;
  final List<YtStreamFormat> audioOnly;
  // The User-Agent of the InnerTube client that actually produced the
  // stream URLs. Google's CDN (googlevideo.com) frequently rejects or
  // stalls requests that don't carry a matching User-Agent, so the player
  // MUST send this same header when it requests the URL, or playback can
  // hang/spin instead of failing cleanly.
  final String? userAgent;

  const YtVideoInfo({
    required this.videoId,
    required this.title,
    required this.author,
    required this.duration,
    required this.durationSeconds,
    this.hlsManifest,
    required this.muxed,
    required this.videoOnly,
    required this.audioOnly,
    this.userAgent,
  });

  /// Headers that MUST be sent when requesting any of this video's stream
  /// URLs (passed to AudioSource.uri's `headers:` param).
  Map<String, String>? get streamHeaders =>
      userAgent == null ? null : {'User-Agent': userAgent!};

  String? get bestVideoUrl {
    if (muxed.isNotEmpty) return muxed.first.url;
    if (hlsManifest != null) return hlsManifest;
    return null;
  }

  String? get bestAudioUrl {
    if (audioOnly.isNotEmpty) return audioOnly.first.url;
    return bestVideoUrl;
  }

  bool get hasPlayableStreams =>
      muxed.isNotEmpty || hlsManifest != null || audioOnly.isNotEmpty;

  List<String> get videoQualityLabels {
    final seen = <String>{};
    final labels = <String>[];
    for (final f in muxed) {
      if (f.quality.isNotEmpty && seen.add(f.quality)) labels.add(f.quality);
    }
    return labels;
  }

  YtStreamFormat? muxedForQuality(String quality) {
    for (final f in muxed) {
      if (f.quality == quality) return f;
    }
    return muxed.isNotEmpty ? muxed.first : null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class YoutubeStreamService {
  static String extractVideoId(String input) {
    input = input.trim();
    for (final p in [
      RegExp(r'(?:v=)([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtu\.be/([a-zA-Z0-9_-]{11})'),
      RegExp(r'/(?:embed|shorts|v)/([a-zA-Z0-9_-]{11})'),
    ]) {
      final m = p.firstMatch(input);
      if (m != null) return m.group(1)!;
    }
    if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(input)) return input;
    throw Exception('Cannot extract video ID from: $input');
  }

  static Future<String?> _fetchVisitorData(http.Client c, String id) async {
    try {
      final resp = await c.get(
        Uri.parse('https://www.youtube.com/watch?v=$id&hl=en'),
        headers: {'User-Agent': _webUA, 'Accept-Language': 'en-US,en;q=0.9'},
      ).timeout(const Duration(seconds: 6));
      for (final p in [
        RegExp(r'"VISITOR_DATA"\s*:\s*"([^"]+)"'),
        RegExp(r'"visitorData"\s*:\s*"([^"]+)"'),
      ]) {
        final m = p.firstMatch(resp.body);
        if (m != null) return m.group(1);
      }
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>> _innertubeCall(
    http.Client c,
    Map<String, dynamic> client,
    String clientName,
    String videoId,
    String? visitorData,
  ) async {
    final ctx = Map<String, dynamic>.from(client);
    if (visitorData != null) ctx['visitorData'] = visitorData;
    final resp = await c.post(
      Uri.parse(_innertubeEndpoint),
      headers: {
        'Content-Type': 'application/json',
        'X-YouTube-Client-Name': clientName,
        'X-YouTube-Client-Version': client['clientVersion'] as String,
        'Origin': 'https://www.youtube.com',
        'X-Goog-Visitor-Id': visitorData ?? '',
        'User-Agent': (client['userAgent'] as String?) ?? _webUA,
      },
      body: jsonEncode({
        'context': {'client': ctx},
        'videoId': videoId,
        'playbackContext': {
          'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
        },
        'contentCheckOk': true,
        'racyCheckOk': true,
      }),
    ).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Picks candidate `url` fields out of formats/adaptiveFormats.
  static List<String> _candidateUrls(Map<String, dynamic> d) {
    final sd = d['streamingData'] as Map<String, dynamic>? ?? {};
    final urls = <String>[];
    for (final key in ['formats', 'adaptiveFormats']) {
      final list = sd[key] as List?;
      if (list == null) continue;
      for (final f in list) {
        final url = (f as Map)['url'] as String?;
        if (url != null && url.isNotEmpty) urls.add(url);
      }
    }
    return urls;
  }

  /// Returns true only when the response is actually playable right now —
  /// not just when it merely *contains* a `url` field.
  ///
  /// As of 2026, YouTube requires a Proof-of-Origin token for almost every
  /// InnerTube client. A PO-token-gated client (TV embedded, iOS, Android)
  /// still returns a normal-looking `url` in the JSON — it just 403s the
  /// instant that URL is actually requested. Trusting the URL's mere
  /// presence (the old behavior) means we'd hand a dead link straight to
  /// the audio player, which is exactly what produced "stuck on loading" or
  /// a confusing late error. YoutubeExplode avoids this with a HEAD request
  /// before accepting a stream (see StreamClient.TryGetContentLengthAsync);
  /// we do the same here, on one representative candidate, before
  /// committing to this client's response.
  static Future<bool> _streamsOk(http.Client c, Map<String, dynamic> d) async {
    final sd = d['streamingData'] as Map<String, dynamic>? ?? {};
    if (sd['hlsManifestUrl'] != null) return true; // HLS isn't probed per-segment

    final candidates = _candidateUrls(d);
    if (candidates.isEmpty) return false;

    try {
      final resp = await c
          .head(Uri.parse(candidates.first))
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200 || resp.statusCode == 206;
    } catch (_) {
      return false;
    }
  }

  static Future<({Map<String, dynamic> data, String userAgent})> _playerResponse(
    http.Client c, String videoId, String? visitorData) async {
    // Try clients in priority order — ANDROID_VR first. As of 2026 it's the
    // one InnerTube client that doesn't require a PO token (see comment
    // block above the client definitions), confirmed against YoutubeExplode's
    // current, working VideoController.GetPlayerResponseAsync.
    final clients = [
      (_androidVrClient, _androidVrClientName),
      (_tvEmbedClient, _tvEmbedClientName),
      (_iosClient, _iosClientName),
      (_androidClient, _androidClientName),
    ];
    // Hard overall deadline across *all* client attempts. Without this, a
    // slow/stalled network can chain 4 sequential per-call timeouts (up to
    // ~32s) on top of the visitor-data lookup, during which the UI shows no
    // feedback at all (the loading snackbar auto-dismisses after 10s) —
    // looking exactly like "stuck on loading" before an error ever appears.
    final deadline = DateTime.now().add(const Duration(seconds: 22));
    Exception? lastErr;
    for (final (ctx, cname) in clients) {
      if (DateTime.now().isAfter(deadline)) break;
      try {
        final data = await _innertubeCall(
            c, ctx as Map<String, dynamic>, cname, videoId, visitorData);
        final ps = data['playabilityStatus'] as Map<String, dynamic>? ?? {};
        final status = ps['status'] as String? ?? '';
        if (status == 'LOGIN_REQUIRED') continue;
        if (status != 'OK' && status.isNotEmpty) continue;
        if (await _streamsOk(c, data)) {
          return (data: data, userAgent: ctx['userAgent'] as String? ?? _webUA);
        }
      } on Exception catch (e) {
        lastErr = e;
      }
    }
    throw lastErr ?? Exception('All InnerTube clients failed for $videoId');
  }

  static ({String vcodec, String acodec}) _codecs(String mime) {
    String v = '', a = '';
    final m = RegExp(r'codecs="([^"]+)"').firstMatch(mime);
    if (m != null) {
      for (final c in m.group(1)!.split(',')) {
        final ct = c.trim();
        if (RegExp(r'^(avc|vp[89]|av01|hev|hvc|dvh)').hasMatch(ct)) v = ct;
        else if (RegExp(r'^(mp4a|opus|ac-3|ec-3|flac)').hasMatch(ct)) a = ct;
      }
    }
    return (vcodec: v, acodec: a);
  }

  /// Resolve a plain URL from a format object.
  /// Cipher/signatureCipher URLs are intentionally skipped — we cannot
  /// decode them without running YouTube's JS player, and any URL extracted
  /// from them without decryption will 403.
  static String? _resolveUrl(Map<String, dynamic> fmt) {
    final url = fmt['url'] as String?;
    if (url != null && url.isNotEmpty) return url;
    // Do NOT attempt to use signatureCipher/cipher URLs — they require JS
    // player decryption that we cannot perform on-device.
    return null;
  }

  static Future<YtVideoInfo> getStreamInfo(String input) async {
    final videoId = extractVideoId(input);
    final c = http.Client();
    try {
      // Hard ceiling on the *entire* lookup. Previously there was no overall
      // timeout, only per-request ones, so a degraded connection could leave
      // the UI hanging for up to ~95s (visitor data + 4 sequential client
      // attempts) with nothing visible after the loading snackbar's fixed
      // 10s auto-dismiss — looking exactly like a permanent freeze before it
      // either finally played or finally errored.
      final visitorData = await _fetchVisitorData(c, videoId);
      final result = await _playerResponse(c, videoId, visitorData)
          .timeout(const Duration(seconds: 25));
      final pr = result.data;
      final userAgent = result.userAgent;

      final ps = pr['playabilityStatus'] as Map<String, dynamic>? ?? {};
      final status = ps['status'] as String? ?? '';
      if (status != 'OK' && status.isNotEmpty) {
        throw Exception(ps['reason'] ?? status);
      }

      final d = pr['videoDetails'] as Map<String, dynamic>? ?? {};
      final durSec = int.tryParse(d['lengthSeconds']?.toString() ?? '') ?? 0;
      final h = durSec ~/ 3600;
      final min = (durSec % 3600) ~/ 60;
      final s = durSec % 60;

      final sd = pr['streamingData'] as Map<String, dynamic>? ?? {};
      final hls = sd['hlsManifestUrl'] as String?;
      final muxed = <YtStreamFormat>[];
      final videoOnly = <YtStreamFormat>[];
      final audioOnly = <YtStreamFormat>[];

      void add(List<dynamic> list, {required bool forceMuxed}) {
        for (final raw in list) {
          final f = raw as Map<String, dynamic>;
          final url = _resolveUrl(f);
          if (url == null) continue; // skip cipher-only streams
          final mime = f['mimeType'] as String? ?? '';
          final (:vcodec, :acodec) = _codecs(mime);
          final hasV = vcodec.isNotEmpty || mime.startsWith('video/');
          final hasA = acodec.isNotEmpty;
          final entry = YtStreamFormat(
            itag: f['itag'] as int? ?? 0,
            url: url,
            mime: mime.split(';').first.trim(),
            quality: (f['qualityLabel'] ?? f['audioQuality'] ?? '') as String,
            width: f['width'] as int? ?? 0,
            height: f['height'] as int? ?? 0,
            fps: f['fps'] as int? ?? 0,
            bitrate: f['bitrate'] as int? ?? 0,
            size: int.tryParse(f['contentLength']?.toString() ?? '') ?? 0,
            vcodec: vcodec,
            acodec: acodec,
            isMuxed: forceMuxed || (hasV && hasA),
          );
          if (forceMuxed || (hasV && hasA)) {
            muxed.add(entry);
          // ignore: curly_braces_in_flow_control_structures
          } else if (hasV) videoOnly.add(entry);
          // ignore: curly_braces_in_flow_control_structures
          else if (hasA) audioOnly.add(entry);
        }
      }

      add(sd['formats'] as List? ?? [], forceMuxed: true);
      add(sd['adaptiveFormats'] as List? ?? [], forceMuxed: false);
      muxed.sort((a, b) => b.height != a.height ? b.height - a.height : b.fps - a.fps);
      videoOnly.sort((a, b) => b.height != a.height ? b.height - a.height : b.fps - a.fps);
      audioOnly.sort((a, b) => b.bitrate - a.bitrate);

      // If we got an HLS manifest URL that's a valid fallback even with no
      // adaptive/muxed streams, treat it as usable.
      if (muxed.isEmpty && hls == null && audioOnly.isEmpty) {
        throw Exception(
            'No playable streams found. The video may be restricted, region-locked, or age-gated.');
      }

      return YtVideoInfo(
        videoId: videoId,
        title: d['title'] as String? ?? 'Unknown',
        author: d['author'] as String? ?? 'Unknown',
        duration: h > 0
            ? '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
            : '${min.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}',
        durationSeconds: durSec,
        hlsManifest: hls,
        muxed: muxed,
        videoOnly: videoOnly,
        audioOnly: audioOnly,
        userAgent: userAgent,
      );
    } finally {
      c.close();
    }
  }

  static Future<String> getBestAudioUrl(String videoId) async {
    final info = await getStreamInfo(videoId);
    final url = info.bestAudioUrl;
    if (url == null) throw Exception('No audio stream available');
    return url;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // "Up next" / related suggestions — YouTube's actual suggestion feature.
  //
  // The InnerTube `/next` endpoint is what powers the real "Up next" panel
  // and autoplay on youtube.com — not a keyword search. It's metadata-only
  // (no stream URLs), so it isn't PO-token-gated the way `/player` is.
  // ─────────────────────────────────────────────────────────────────────────

  static const _nextEndpoint =
      'https://www.youtube.com/youtubei/v1/next?prettyPrint=false';

  // The WEB client is used here (and only here) because its "Up next"
  // renderer shapes (compactVideoRenderer, etc.) are the long-standing,
  // best-documented ones. This call never touches stream URLs, so the
  // PO-token concerns that drive client choice in _playerResponse don't
  // apply.
  static const _webNextClient = {
    'clientName': 'WEB',
    'clientVersion': '2.20240101.00.00',
    'hl': 'en',
    'gl': 'US',
  };

  static String? _textOf(dynamic node) {
    if (node is! Map) return null;
    if (node['simpleText'] is String) return node['simpleText'] as String;
    final runs = node['runs'] as List?;
    if (runs != null && runs.isNotEmpty) {
      return runs.map((r) => (r as Map)['text']?.toString() ?? '').join();
    }
    return null;
  }

  /// Fetches YouTube's own "Up next" / related-video suggestions for
  /// [videoId] — the same feature that drives the Up Next panel and
  /// autoplay on youtube.com. Falls back to an empty list (never throws) so
  /// callers can fall back to a keyword search if YouTube's response shape
  /// shifts in a way this parser doesn't expect.
  static Future<List<YtSuggestion>> getWatchNextSuggestions(
    String videoId, {
    int max = 10,
  }) async {
    final c = http.Client();
    try {
      final resp = await c
          .post(
            Uri.parse(_nextEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': _webUA,
              'Origin': 'https://www.youtube.com',
            },
            body: jsonEncode({
              'context': {'client': _webNextClient},
              'videoId': videoId,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      final seen = <String>{videoId};
      final out = <YtSuggestion>[];

      // Recursive walk rather than a hardcoded path: YouTube reshuffles
      // *where* these renderer objects live in the tree fairly often, but
      // the renderer shapes themselves (compactVideoRenderer etc.) have
      // stayed stable for years, so hunting for them anywhere is more
      // resilient than pinning an exact nested path.
      void visit(dynamic node) {
        if (out.length >= max) return;
        if (node is Map) {
          for (final key in const [
            'compactVideoRenderer',
            'playlistPanelVideoRenderer',
            'gridVideoRenderer',
            'videoRenderer',
          ]) {
            final r = node[key];
            if (r is Map) {
              final id = r['videoId'] as String?;
              if (id != null && id.isNotEmpty && seen.add(id)) {
                final thumbs =
                    (r['thumbnail']?['thumbnails'] as List?) ?? const [];
                final thumb = thumbs.isNotEmpty
                    ? (thumbs.last as Map)['url'] as String? ?? ''
                    : '';
                out.add(YtSuggestion(
                  videoId: id,
                  title: _textOf(r['title']) ?? 'Unknown',
                  author: _textOf(r['shortBylineText']) ??
                      _textOf(r['longBylineText']) ??
                      _textOf(r['ownerText']) ??
                      '',
                  thumbnail: thumb,
                ));
              }
            }
          }
          for (final v in node.values) {
            if (out.length >= max) return;
            visit(v);
          }
        } else if (node is List) {
          for (final v in node) {
            if (out.length >= max) return;
            visit(v);
          }
        }
      }

      visit(data);
      return out;
    } catch (_) {
      return [];
    } finally {
      c.close();
    }
  }
}

/// A YouTube "Up next" / related suggestion — sourced from YouTube's own
/// suggestion feature (see [YoutubeStreamService.getWatchNextSuggestions]),
/// not a generic keyword search.
class YtSuggestion {
  final String videoId;
  final String title;
  final String author;
  final String thumbnail;

  const YtSuggestion({
    required this.videoId,
    required this.title,
    required this.author,
    required this.thumbnail,
  });
}