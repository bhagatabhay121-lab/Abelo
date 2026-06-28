/// Mirrors the `toSong()` normalizer in index.html — JioSaavn's raw JSON
/// is messy and shapes differ per endpoint, so every place that touches
/// a song goes through this model.
class Song {
  final String id;
  final String title;
  final String artist;
  final String image; // already upgraded to 500x500 where possible
  final String? album;
  final int durationSec;
  final Map<String, String> mediaUrls; // "96kbps" -> url, "320kbps" -> url ...
  String? mediaUrl;    // resolved/default-quality stream url
  String? previewUrl;  // 30-second preview — used as last-resort fallback
  // Extra HTTP headers (e.g. User-Agent) the player MUST send when fetching
  // mediaUrl/mediaUrls. Required for YouTube-sourced ('yt:' prefixed) songs —
  // googlevideo.com URLs are bound to the InnerTube client that issued them
  // and can reject or stall requests sent with a mismatched/missing
  // User-Agent. Saavn URLs don't need this and leave it null.
  Map<String, String>? mediaHeaders;
  final String? primaryArtistIds; // comma separated, used for "more by artist"
  final String? language;
  final String? permaUrl; // JioSaavn canonical share URL

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.image,
    this.album,
    this.durationSec = 0,
    Map<String, String>? mediaUrls,
    this.mediaUrl,
    this.previewUrl,
    this.mediaHeaders,
    this.primaryArtistIds,
    this.language,
    this.permaUrl,
  }) : mediaUrls = mediaUrls ?? {};

  factory Song.fromJson(Map<String, dynamic> json) {
    final moreInfo = (json['more_info'] is Map)
        ? Map<String, dynamic>.from(json['more_info'])
        : <String, dynamic>{};

    String img = (json['image'] ?? '').toString();
    img = img.replaceAll('150x150', '500x500').replaceAll('50x50', '500x500');

    String artist = json['subtitle']?.toString() ??
        moreInfo['singers']?.toString() ??
        moreInfo['primary_artists']?.toString() ??
        json['primary_artists']?.toString() ??
        json['music']?.toString() ??
        'Unknown Artist';

    // Prefer subtitle-based artist parsing like the HTML's artistFromSubtitle:
    // "Artist - Album" format → take left side.
    final sub = json['subtitle']?.toString() ?? '';
    if (sub.contains(' - ')) {
      artist = sub.split(' - ')[0].trim();
    }

    final mediaUrlsRaw = (json['media_urls'] ?? moreInfo['media_urls']);
    final mediaUrls = <String, String>{};
    if (mediaUrlsRaw is Map) {
      mediaUrlsRaw.forEach((k, v) {
        if (v != null) mediaUrls[k.toString()] = v.toString();
      });
    }

    int duration = 0;
    final rawDuration = moreInfo['duration'] ?? json['duration'];
    if (rawDuration != null) {
      duration = int.tryParse(rawDuration.toString()) ?? 0;
    }

    // Extract the playable stream URL — mirror the HTML's:
    //   mediaUrl: data.media_url || info.media_url
    final rawMediaUrl =
        (json['media_url'] ?? moreInfo['media_url'])?.toString();

    // Extract the preview URL — mirror the HTML's:
    //   preview: info.media_preview_url || data.media_preview_url
    final rawPreviewUrl =
        (moreInfo['media_preview_url'] ?? json['media_preview_url'])
            ?.toString();

    return Song(
      id: (json['id'] ?? '').toString(),
      title: _decodeHtml(
          (json['title'] ?? json['song'] ?? 'Unknown Title').toString()),
      artist: _decodeHtml(artist),
      image: img,
      album: json['album']?.toString() ?? moreInfo['album']?.toString(),
      durationSec: duration,
      mediaUrls: mediaUrls,
      mediaUrl: (rawMediaUrl?.isNotEmpty == true) ? rawMediaUrl : null,
      previewUrl: (rawPreviewUrl?.isNotEmpty == true) ? rawPreviewUrl : null,
      primaryArtistIds: moreInfo['primary_artists_id']?.toString() ??
          moreInfo['artistMap']?.toString(),
      language: json['language']?.toString(),
      permaUrl: (json['perma_url'] ?? moreInfo['perma_url'])?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'image': image,
        'album': album,
        'durationSec': durationSec,
        'mediaUrls': mediaUrls,
        'mediaUrl': mediaUrl,
        'previewUrl': previewUrl,
        'mediaHeaders': mediaHeaders,
        'language': language,
        'permaUrl': permaUrl,
      };

  factory Song.fromCache(Map<String, dynamic> json) => Song(
        id: json['id'],
        title: json['title'],
        artist: json['artist'],
        image: json['image'],
        album: json['album'],
        durationSec: json['durationSec'] ?? 0,
        mediaUrls: Map<String, String>.from(json['mediaUrls'] ?? {}),
        mediaUrl: json['mediaUrl'],
        previewUrl: json['previewUrl'],
        mediaHeaders: json['mediaHeaders'] != null
            ? Map<String, String>.from(json['mediaHeaders'])
            : null,
        language: json['language'],
        permaUrl: json['permaUrl'],
      );

  static String _decodeHtml(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}

/// Generic horizontal-row item: album, playlist, artist, radio station,
/// or genre/mood tile from the home screen ("browse_discover").
class BrowseItem {
  final String id;
  final String title;
  final String subtitle;
  final String image;
  final String type; // album | playlist | artist | radio | mix | genre

  BrowseItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.image,
    required this.type,
  });

  factory BrowseItem.fromJson(Map<String, dynamic> json,
      {String type = 'album'}) {
    String img = (json['image'] ?? '').toString();
    img = img.replaceAll('150x150', '500x500').replaceAll('50x50', '500x500');
    return BrowseItem(
      id: (json['id'] ?? json['stationid'] ?? '').toString(),
      title: Song._decodeHtml(
          (json['title'] ?? json['name'] ?? json['listname'] ?? '')
              .toString()),
      subtitle: Song._decodeHtml((json['subtitle'] ??
              json['primary_artists'] ??
              json['firstname'] ??
              json['language'] ??
              '')
          .toString()),
      image: img,
      type: type,
    );
  }
}
