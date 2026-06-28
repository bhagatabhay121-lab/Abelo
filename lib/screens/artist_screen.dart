import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../app_assets.dart';
import '../models/song.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/browse_row.dart';
import 'album_playlist_screen.dart';

class ArtistScreen extends StatefulWidget {
  final String artistId;
  const ArtistScreen({super.key, required this.artistId});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  bool _loading = true;
  String? _error;

  // Basic info
  String _name      = '';
  String _image     = '';
  String _followers = '';

  // About fields
  String _bio              = '';
  String _dob              = '';
  String _dominantLanguage = '';
  String _dominantType     = '';
  bool   _isVerified       = false;
  List<String> _availableLanguages = [];
  String _fb      = '';
  String _twitter = '';
  String _wiki    = '';

  // Content
  List<Song>       _topSongs         = [];
  List<Song>       _otherTopSongs    = [];
  bool             _otherSongsLoading = false;
  List<BrowseItem> _albums        = [];
  List<BrowseItem> _playlists     = [];
  List<BrowseItem> _similarArtists = [];

  // UI state
  bool _showAllSongs  = false;
  bool _aboutExpanded = false;

  static const int _songsPreview = 5;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    try {
      final raw = await app.api.fetchArtist(widget.artistId);

      // ── image ──────────────────────────────────────────────────────────────
      String img = (raw['image'] ?? '').toString();
      img = img.replaceAll('150x150', '500x500').replaceAll('50x50', '500x500');

      // ── songs / albums / playlists ─────────────────────────────────────────
      final topSongsRaw  = (raw['topSongs']  ?? raw['top_songs']  ?? []) as List;
      final albumsRaw    = (raw['topAlbums'] ?? raw['top_albums'] ?? []) as List;
      final playlistsRaw = (raw['topPlaylists'] ??
          raw['top_playlists'] ??
          raw['dedicated_artist_playlist'] ??
          raw['featured_artist_playlist'] ??
          raw['playlists'] ?? []) as List;

      // ── similar artists — JioSaavn returns a Map<id, obj> or a List ────────
      List similarRaw = [];
      final simField = raw['similarArtists'] ?? raw['similar_artists'] ?? raw['similar'];
      if (simField is List) {
        similarRaw = simField;
      } else if (simField is Map) {
        similarRaw = simField.values.toList();
      }

      // ── bio — may be a List<Map> with {text, language} or a plain String ───
      String bioText = '';
      final bioField = raw['bio'];
      if (bioField is List && bioField.isNotEmpty) {
        // Pick the English entry first, fall back to first entry
        final eng = bioField.firstWhere(
          (e) => (e['language'] ?? '').toString().toLowerCase() == 'english',
          orElse: () => bioField.first,
        );
        bioText = (eng['text'] ?? '').toString();
      } else if (bioField is String) {
        bioText = bioField;
      }
      // Strip HTML tags if any
      bioText = bioText.replaceAll(RegExp(r'<[^>]*>'), '').trim();

      // ── available languages ────────────────────────────────────────────────
      final langField = raw['availableLanguages'] ?? raw['available_languages'];
      List<String> langs = [];
      if (langField is List) {
        langs = langField.map((e) => e.toString()).toList();
      }

      setState(() {
        _name      = (raw['name'] ?? 'Artist').toString();
        _image     = img;
        _followers = (raw['follower_count'] ?? raw['fan_count'] ?? '').toString();

        _bio              = bioText;
        _dob              = (raw['dob'] ?? '').toString();
        _dominantLanguage = (raw['dominantLanguage'] ?? raw['dominant_language'] ?? '').toString();
        _dominantType     = (raw['dominantType'] ?? raw['dominant_type'] ?? '').toString();
        _isVerified       = raw['isVerified'] == true || raw['is_verified'] == true;
        _availableLanguages = langs;
        _fb      = (raw['fb']      ?? raw['facebook'] ?? '').toString();
        _twitter = (raw['twitter'] ?? '').toString();
        _wiki    = (raw['wiki']    ?? raw['wikipedia'] ?? '').toString();

        _topSongs = topSongsRaw
            .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _albums = albumsRaw
            .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'album'))
            .toList();
        _playlists = playlistsRaw
            .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'playlist'))
            .toList();
        _similarArtists = similarRaw
            .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'artist'))
            .toList();

        _loading = false;
      });

      // Fetch "other top songs" in background once we know the artist id
      _fetchOtherTopSongs(widget.artistId);
    } catch (e) {
      setState(() {
        _error   = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _fetchOtherTopSongs(String artistId) async {
    setState(() => _otherSongsLoading = true);
    try {
      final songs = await context.read<AppState>().api
          .fetchArtistOtherTopSongs(artistId);
      if (mounted) setState(() { _otherTopSongs = songs; _otherSongsLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _otherSongsLoading = false);
    }
  }

  Future<void> _playRadio() async {
    final app = context.read<AppState>();
    try {
      final station   = await app.api.createArtistRadio(_name);
      final stationId = (station['stationid'] ?? station['stationId'] ?? '').toString();
      if (stationId.isEmpty) throw Exception('No station id returned');
      final songs = await app.api.getRadioSongs(stationId, count: 20);
      if (songs.isNotEmpty) app.setQueueAndPlay(songs, 0);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Radio failed: $e')));
      }
    }
  }

  // ── section header (pink title + optional "Show all" pill) ─────────────────
  Widget _sectionHeader(String title,
      {VoidCallback? onShowAll, bool showingAll = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 12, 10),
      child: Row(
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: TaarColors.marigold)),
          const Spacer(),
          if (onShowAll != null)
            GestureDetector(
              onTap: onShowAll,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  border:
                      Border.all(color: Colors.white.withOpacity(0.35)),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(showingAll ? 'Show less' : 'Show all',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500)),
              ),
            ),
        ],
      ),
    );
  }

  // ── single song row ─────────────────────────────────────────────────────────
  Widget _songRow(Song song, int index, List<Song> queue) {
    return InkWell(
      onTap: () => context.read<AppState>().setQueueAndPlay(queue, index),
      splashColor: Colors.white.withOpacity(0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CachedNetworkImage(
                imageUrl: song.image,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Image.asset(
                    AppAssets.placeholderSong,
                    width: 52, height: 52, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                  const SizedBox(height: 3),
                  Text(song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.55),
                          fontSize: 12.5)),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.more_vert,
                  color: Colors.white.withOpacity(0.55), size: 20),
              onPressed: () {},
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }

  // ── large horizontal card row (albums / playlists) ──────────────────────────
  Widget _largeCardRow(List<BrowseItem> items, String type) {
    return SizedBox(
      height: 210,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          final placeholder = type == 'artist'
              ? AppAssets.placeholderArtist
              : type == 'album'
                  ? AppAssets.placeholderAlbum
                  : AppAssets.placeholderSong;
          return GestureDetector(
            onTap: () {
              if (type == 'album' || type == 'playlist') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AlbumPlaylistScreen(
                        id: item.id, type: type, title: item.title),
                  ),
                );
              }
            },
            child: Container(
              width: 160,
              margin: const EdgeInsets.only(right: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedNetworkImage(
                      imageUrl: item.image,
                      width: 160,
                      height: 160,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Image.asset(placeholder,
                          width: 160, height: 160, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5)),
                  if (item.subtitle.isNotEmpty)
                    Text(item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 11.5)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── "Fans might also like" — large circular cards ──────────────────────────
  Widget _similarArtistsRow() {
    return SizedBox(
      height: 195,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _similarArtists.length,
        itemBuilder: (context, i) {
          final item = _similarArtists[i];
          return GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ArtistScreen(artistId: item.id),
              ),
            ),
            child: Container(
              width: 140,
              margin: const EdgeInsets.only(right: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Larger circular avatar
                  Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: TaarColors.marigold.withOpacity(0.35),
                          width: 2),
                    ),
                    child: ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: item.image,
                        width: 130,
                        height: 130,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Image.asset(
                            AppAssets.placeholderArtist,
                            width: 130,
                            height: 130,
                            fit: BoxFit.cover),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                  if (item.subtitle.isNotEmpty)
                    Text(item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 11.5)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── About section card ──────────────────────────────────────────────────────
  Widget _aboutSection() {
    // Collect the info rows we have data for
    final infoRows = <_AboutRow>[];

    if (_dominantType.isNotEmpty)
      infoRows.add(_AboutRow(Icons.person_outline, 'Type',
          _dominantType[0].toUpperCase() + _dominantType.substring(1)));

    if (_dominantLanguage.isNotEmpty)
      infoRows.add(_AboutRow(Icons.language_outlined, 'Language',
          _dominantLanguage[0].toUpperCase() + _dominantLanguage.substring(1)));

    if (_availableLanguages.isNotEmpty)
      infoRows.add(_AboutRow(Icons.queue_music_outlined, 'Also sings in',
          _availableLanguages.map((l) => l[0].toUpperCase() + l.substring(1)).join(', ')));

    if (_dob.isNotEmpty)
      infoRows.add(_AboutRow(Icons.cake_outlined, 'Date of Birth', _dob));

    if (_followers.isNotEmpty)
      infoRows.add(_AboutRow(Icons.people_outline, 'Followers', _followers));

    if (_fb.isNotEmpty)
      infoRows.add(_AboutRow(Icons.link_outlined, 'Facebook', _fb));

    if (_twitter.isNotEmpty)
      infoRows.add(_AboutRow(Icons.tag_outlined, 'Twitter / X', _twitter));

    if (_wiki.isNotEmpty)
      infoRows.add(_AboutRow(Icons.menu_book_outlined, 'Wikipedia', _wiki));

    final hasBio  = _bio.isNotEmpty;
    final hasInfo = infoRows.isNotEmpty;

    if (!hasBio && !hasInfo) return const SizedBox.shrink();

    // Bio snippet — show first 200 chars collapsed, full on expand
    const bioSnippetLen = 200;
    final bioCollapsed =
        hasBio && _bio.length > bioSnippetLen && !_aboutExpanded;
    final bioDisplay = bioCollapsed
        ? '${_bio.substring(0, bioSnippetLen).trimRight()}…'
        : _bio;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: TaarColors.ink2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.07)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Artist avatar + name inside the card ─────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
              child: Row(
                children: [
                  ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: _image,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Image.asset(
                          AppAssets.placeholderArtist,
                          width: 56, height: 56, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(_name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15)),
                            ),
                            if (_isVerified) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.verified_rounded,
                                  color: TaarColors.marigold, size: 16),
                            ],
                          ],
                        ),
                        if (_followers.isNotEmpty)
                          Text('$_followers followers',
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.5),
                                  fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // divider
            Divider(height: 1, color: Colors.white.withOpacity(0.08)),

            // ── Bio text ─────────────────────────────────────────────────────
            if (hasBio)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Text(bioDisplay,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.75),
                        fontSize: 13.5,
                        height: 1.55)),
              ),

            // ── Info rows ────────────────────────────────────────────────────
            if (hasInfo && _aboutExpanded) ...[
              const SizedBox(height: 14),
              Divider(height: 1, color: Colors.white.withOpacity(0.08)),
              ...infoRows.map((r) => _aboutInfoRow(r)),
            ],

            // ── Read more / Show less toggle ──────────────────────────────────
            if (hasBio || hasInfo)
              GestureDetector(
                onTap: () => setState(() => _aboutExpanded = !_aboutExpanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: Row(
                    children: [
                      Text(_aboutExpanded ? 'Show less' : 'Read more',
                          style: TextStyle(
                              color: TaarColors.marigold,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                      const SizedBox(width: 4),
                      Icon(
                          _aboutExpanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: TaarColors.marigold,
                          size: 18),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _aboutInfoRow(_AboutRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(r.icon, color: TaarColors.marigold, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.label,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.45),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5)),
                const SizedBox(height: 2),
                Text(r.value,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TaarColors.ink,
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: TaarColors.marigold))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Failed to load: $_error',
                        style:
                            const TextStyle(color: TaarColors.creamDim)),
                  ),
                )
              : CustomScrollView(
                  slivers: [
                    // ── Hero header ─────────────────────────────────────────
                    SliverAppBar(
                      expandedHeight: 300,
                      pinned: true,
                      backgroundColor: TaarColors.ink,
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      flexibleSpace: FlexibleSpaceBar(
                        collapseMode: CollapseMode.pin,
                        background: Stack(
                          fit: StackFit.expand,
                          children: [
                            CachedNetworkImage(
                              imageUrl: _image,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => Image.asset(
                                  AppAssets.placeholderArtist,
                                  fit: BoxFit.cover),
                            ),
                            Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  stops: const [0.35, 1.0],
                                  colors: [
                                    Colors.transparent,
                                    Colors.black.withOpacity(0.85),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              left: 16,
                              right: 16,
                              bottom: 18,
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.center,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      Flexible(
                                        child: Text(_name,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 28,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: -0.3)),
                                      ),
                                      if (_isVerified) ...[
                                        const SizedBox(width: 8),
                                        Icon(Icons.verified_rounded,
                                            color: TaarColors.marigold,
                                            size: 22),
                                      ],
                                    ],
                                  ),
                                  if (_followers.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text('$_followers followers',
                                        style: TextStyle(
                                            color: Colors.white
                                                .withOpacity(0.65),
                                            fontSize: 13)),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── Subscribe + Play buttons ─────────────────────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding:
                            const EdgeInsets.fromLTRB(16, 18, 16, 6),
                        child: Row(
                          children: [
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: TaarColors.marigold,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(99)),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 22, vertical: 13),
                                elevation: 0,
                              ),
                              icon: const Icon(
                                  Icons.notifications_outlined,
                                  size: 18),
                              label: const Text('Subscribe',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15)),
                              onPressed: () {},
                            ),
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: _topSongs.isEmpty
                                  ? null
                                  : () => context
                                      .read<AppState>()
                                      .setQueueAndPlay(_topSongs, 0),
                              child: Container(
                                width: 48,
                                height: 48,
                                decoration: const BoxDecoration(
                                  color: TaarColors.marigold,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.play_arrow,
                                    color: Colors.white, size: 26),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── Songs ────────────────────────────────────────────────
                    if (_topSongs.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: _sectionHeader(
                          'Songs',
                          onShowAll: _topSongs.length > _songsPreview
                              ? () => setState(
                                  () => _showAllSongs = !_showAllSongs)
                              : null,
                          showingAll: _showAllSongs,
                        ),
                      ),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final visible = _showAllSongs
                                ? _topSongs
                                : _topSongs
                                    .take(_songsPreview)
                                    .toList();
                            return _songRow(visible[i], i, _topSongs);
                          },
                          childCount: _showAllSongs
                              ? _topSongs.length
                              : _topSongs.length
                                  .clamp(0, _songsPreview),
                        ),
                      ),
                    ],

                    // ── Other Top Songs ──────────────────────────────────
                    if (_otherSongsLoading || _otherTopSongs.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: _sectionHeader('More from $_name'),
                      ),
                      if (_otherSongsLoading)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(child: CircularProgressIndicator(
                                color: TaarColors.marigold, strokeWidth: 2)),
                          ),
                        )
                      else
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => _songRow(
                                _otherTopSongs[i], i, _otherTopSongs),
                            childCount: _otherTopSongs.length,
                          ),
                        ),
                    ],

                    // ── Albums ───────────────────────────────────────────────
                    if (_albums.isNotEmpty) ...[
                      SliverToBoxAdapter(
                          child: _sectionHeader('Albums')),
                      SliverToBoxAdapter(
                          child: _largeCardRow(_albums, 'album')),
                    ],

                    // ── Playlists by Artist ───────────────────────────────────
                    if (_playlists.isNotEmpty) ...[
                      SliverToBoxAdapter(
                          child:
                              _sectionHeader('Playlists by $_name')),
                      SliverToBoxAdapter(
                          child: _largeCardRow(_playlists, 'playlist')),
                    ],

                    // ── Fans might also like ──────────────────────────────────
                    if (_similarArtists.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: _sectionHeader('Fans might also like'),
                      ),
                      SliverToBoxAdapter(
                        child: _similarArtistsRow(),
                      ),
                    ],

                    // ── About ────────────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: _sectionHeader('About'),
                    ),
                    SliverToBoxAdapter(
                      child: _aboutSection(),
                    ),

                    const SliverToBoxAdapter(
                        child: SizedBox(height: 40)),
                  ],
                ),
    );
  }
}

// Simple data class for About info rows
class _AboutRow {
  final IconData icon;
  final String   label;
  final String   value;
  const _AboutRow(this.icon, this.label, this.value);
}
