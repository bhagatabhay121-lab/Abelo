import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../app_assets.dart';
import '../models/song.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'album_playlist_screen.dart';
import 'artist_screen.dart';
import 'now_playing_screen.dart';

class SearchScreen extends StatefulWidget {
  final String? initialQuery;
  const SearchScreen({super.key, this.initialQuery});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  bool _loading = false;
  List<Song> songs = [];
  List<BrowseItem> albums = [];
  List<BrowseItem> artists = [];
  List<BrowseItem> playlists = [];

  // Home state (shown before any search)
  List<BrowseItem> _featuredArtists = [];
  List<BrowseItem> _featuredAlbums = [];
  List<BrowseItem> _moodsGenres = [];
  bool _homeLoading = false;

  // Scroll controller for results list — triggers reco on scroll-to-bottom
  final ScrollController _resultsScroll = ScrollController();
  static const double _recoScrollThreshold = 300;

  // Recent searches stored in memory
  final List<String> _recentSearches = [];

  // Trending suggestions
  static const List<String> _trending = [
    'Arijit Singh',
    'Diljit Dosanjh',
    'AR Rahman',
    'Pritam',
    'Shreya Ghoshal',
    'Bollywood Hits',
    'Lo-fi Chill',
    'Party Mix',
  ];

  // Queries used to populate the home browse sections
  static const List<String> _artistSeeds = [
    'Arijit Singh', 'Diljit Dosanjh', 'Shreya Ghoshal', 'AR Rahman',
    'Pritam', 'Atif Aslam', 'Neha Kakkar', 'Badshah',
  ];
  static const List<String> _albumSeeds = [
    'Bollywood 2024', 'Lo-fi Chill', 'Party Hits', 'Romantic Songs',
  ];

  @override
  void initState() {
    super.initState();
    _resultsScroll.addListener(_onResultsScroll);
    _loadHomeData();
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _controller.text = widget.initialQuery!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runSearch(widget.initialQuery!.trim());
      });
    }
  }

  Future<void> _loadHomeData() async {
    if (!mounted) return;
    setState(() => _homeLoading = true);
    final app = context.read<AppState>();

    try {
      // Fetch artists, albums, and home data (for moods/genres) in parallel
      final artistFutures = _artistSeeds.map((q) => app.api.searchArtists(q));
      final albumFutures = _albumSeeds.map((q) => app.api.searchAlbums(q));

      final artistResults = await Future.wait(artistFutures);
      final albumResults = await Future.wait(albumFutures);
      final homeRaw = await app.api.fetchHomeData();

      List extractList(Map<String, dynamic> raw, List<String> keys) {
        for (final k in keys) {
          final v = raw[k];
          if (v is List) return v;
          if (v is Map && v['results'] is List) return v['results'];
          if (v is Map && v['data'] is List) return v['data'];
        }
        return [];
      }

      final featuredArtists = <BrowseItem>[];
      for (final raw in artistResults) {
        final list = extractList(raw, ['results', 'artists']);
        if (list.isNotEmpty) {
          featuredArtists.add(
            BrowseItem.fromJson(Map<String, dynamic>.from(list.first), type: 'artist'),
          );
        }
      }

      final featuredAlbums = <BrowseItem>[];
      for (final raw in albumResults) {
        final list = extractList(raw, ['results', 'albums']);
        for (final e in list.take(3)) {
          featuredAlbums.add(
            BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'album'),
          );
        }
      }

      final moodsGenres = (homeRaw['browse_discover'] as List? ??
              homeRaw['genres'] as List? ??
              homeRaw['moods'] as List? ??
              [])
          .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e as Map), type: 'genre'))
          .toList();

      if (mounted) {
        setState(() {
          _featuredArtists = featuredArtists;
          _featuredAlbums = featuredAlbums;
          _moodsGenres = moodsGenres;
          _homeLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _homeLoading = false);
    }
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() { songs = []; albums = []; artists = []; playlists = []; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _runSearch(q.trim()));
  }

  Future<void> _runSearch(String q) async {
    if (q.isNotEmpty && !_recentSearches.contains(q)) {
      setState(() {
        _recentSearches.insert(0, q);
        if (_recentSearches.length > 8) _recentSearches.removeLast();
      });
    }

    setState(() => _loading = true);
    final app = context.read<AppState>();
    try {
      final results = await Future.wait([
        app.api.searchSongs(q),
        app.api.searchAlbums(q),
        app.api.searchArtists(q),
        app.api.searchPlaylists(q),
      ]);

      List extractList(Map<String, dynamic> raw, List<String> keys) {
        for (final k in keys) {
          final v = raw[k];
          if (v is List) return v;
          if (v is Map && v['results'] is List) return v['results'];
          if (v is Map && v['data'] is List) return v['data'];
        }
        return [];
      }

      setState(() {
        songs = extractList(results[0], ['results', 'songs'])
            .map((e) => Song.fromJson(Map<String, dynamic>.from(e))).toList();
        albums = extractList(results[1], ['results', 'albums'])
            .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'album')).toList();
        artists = extractList(results[2], ['results', 'artists'])
            .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'artist')).toList();
        playlists = extractList(results[3], ['results', 'playlists'])
            .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'playlist')).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Search failed: $e')));
    }
  }

  void _onResultsScroll() {
    if (!_resultsScroll.hasClients) return;
    final remaining = _resultsScroll.position.maxScrollExtent - _resultsScroll.position.pixels;
    if (remaining < _recoScrollThreshold) {
      context.read<AppState>().extendQueueWithMoreReco();
    }
  }

  void _applyChip(String label) {
    _controller.text = label;
    _focusNode.unfocus();
    _runSearch(label);
  }

  void _openAlbum(BrowseItem item) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => AlbumPlaylistScreen(id: item.id, type: item.type, title: item.title),
    ));
  }

  void _openArtist(BrowseItem item) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistScreen(artistId: item.id)));
  }

  @override
  Widget build(BuildContext context) {
    final hasQuery = _controller.text.trim().isNotEmpty;
    final hasResults = songs.isNotEmpty || albums.isNotEmpty || artists.isNotEmpty || playlists.isNotEmpty;

    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        elevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 16,
        title: _SearchPill(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          hasQuery: hasQuery,
          onClear: () {
            _controller.clear();
            _onChanged('');
          },
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: TaarColors.line),
        ),
      ),
      body: !hasQuery
          ? _emptyState()
          : _loading
              ? const Center(child: CircularProgressIndicator(color: TaarColors.marigold))
              : !hasResults
                  ? _noResults()
                  : _resultsList(),
    );
  }

  // ── Empty state ───────────────────────────────────────────────────────────
  Widget _emptyState() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
      children: [
        // Recent searches
        if (_recentSearches.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Recent',
                    style: TextStyle(
                        color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                GestureDetector(
                  onTap: () => setState(() => _recentSearches.clear()),
                  child: const Text('Clear all',
                      style: TextStyle(color: TaarColors.creamDim, fontSize: 13)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _recentSearches.map((q) => _Chip(
                label: q,
                icon: Icons.history_rounded,
                onTap: () => _applyChip(q),
                onDelete: () => setState(() => _recentSearches.remove(q)),
              )).toList(),
            ),
          ),
          const SizedBox(height: 28),
        ],

        // ── Featured Artists ───────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Popular Artists',
                  style: TextStyle(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
              if (_homeLoading)
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8, color: TaarColors.marigold),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 118,
          child: _homeLoading
              ? const SizedBox()
              : _featuredArtists.isEmpty
                  ? Center(
                      child: Text('Could not load artists',
                          style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12)))
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount: _featuredArtists.length,
                      itemBuilder: (_, i) => _artistCard(_featuredArtists[i]),
                    ),
        ),
        const SizedBox(height: 24),

        // ── Featured Albums ────────────────────────────────────────────────
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text('Popular Albums',
              style: TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          height: 162,
          child: _homeLoading
              ? const SizedBox()
              : _featuredAlbums.isEmpty
                  ? Center(
                      child: Text('Could not load albums',
                          style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12)))
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount: _featuredAlbums.length,
                      itemBuilder: (_, i) => _albumCard(_featuredAlbums[i]),
                    ),
        ),
        const SizedBox(height: 28),

        // ── Trending chips ─────────────────────────────────────────────────
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Trending',
              style: TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text('Popular searches right now',
              style: TextStyle(color: TaarColors.creamDim, fontSize: 12)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _trending.map((label) => _Chip(
              label: label,
              icon: Icons.trending_up_rounded,
              iconColor: TaarColors.marigold,
              onTap: () => _applyChip(label),
            )).toList(),
          ),
        ),

        // ── Moods & Genres ─────────────────────────────────────────────────
        if (_moodsGenres.isNotEmpty) ...[ 
          const SizedBox(height: 28),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text('Moods & Genres',
                style: TextStyle(
                    color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 2.4,
            ),
            itemCount: _moodsGenres.length,
            itemBuilder: (context, i) {
              final item = _moodsGenres[i];
              return GestureDetector(
                onTap: () => _applyChip(item.title),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(item.image, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(color: TaarColors.ink3)),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Colors.black.withOpacity(0.75), Colors.transparent],
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(item.title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13.5,
                                  color: Colors.white)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  // ── Horizontal artist card ─────────────────────────────────────────────────
  Widget _artistCard(BrowseItem item) {
    return GestureDetector(
      onTap: () => _openArtist(item),
      child: Container(
        width: 80,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: TaarColors.marigold.withOpacity(0.28),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipOval(
                child: CachedNetworkImage(
                  imageUrl: item.image,
                  width: 72,
                  height: 72,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Image.asset(
                    AppAssets.placeholderArtist,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Horizontal album card ──────────────────────────────────────────────────
  Widget _albumCard(BrowseItem item) {
    return GestureDetector(
      onTap: () => _openAlbum(item),
      child: Container(
        width: 120,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: item.image,
                width: 120,
                height: 120,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Image.asset(
                  AppAssets.placeholderAlbum,
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (item.subtitle.isNotEmpty)
              Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: TaarColors.creamDim,
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _noResults() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_off_rounded, size: 72, color: TaarColors.creamDim.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('No results for "${_controller.text}"',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('Try a different song, artist or album',
              style: TextStyle(color: TaarColors.creamDim, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _resultsList() {
    final app = context.read<AppState>();
    return ListView(
      controller: _resultsScroll,
      children: [
        if (songs.isNotEmpty) ...[
          _sectionHeader('Songs'),
          ...songs.map((song) => _songRow(song, app)),
        ],
        if (albums.isNotEmpty) ...[
          _sectionHeader('Albums'),
          ...albums.map((item) => _browseRow(
            item: item,
            subtitle: item.subtitle,
            onTap: () => _openAlbum(item),
            onMore: () => _showMoreSheet(context, item.title, [
              _sheetOption(Icons.album_rounded, 'View Album', () => _openAlbum(item)),
            ]),
          )),
        ],
        if (artists.isNotEmpty) ...[
          _sectionHeader('Artists'),
          ...artists.map((item) => _browseRow(
            item: item,
            subtitle: 'Artist',
            circular: true,
            onTap: () => _openArtist(item),
            onMore: () => _showMoreSheet(context, item.title, [
              _sheetOption(Icons.person_rounded, 'View Artist', () => _openArtist(item)),
            ]),
          )),
        ],
        if (playlists.isNotEmpty) ...[
          _sectionHeader('Playlists'),
          ...playlists.map((item) => _browseRow(
            item: item,
            subtitle: item.subtitle,
            onTap: () => _openAlbum(item),
            onMore: () => _showMoreSheet(context, item.title, [
              _sheetOption(Icons.queue_music_rounded, 'View Playlist', () => _openAlbum(item)),
            ]),
          )),
        ],
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: TaarColors.marigold,
            letterSpacing: 0.3,
          )),
    );
  }

  Widget _songRow(Song song, AppState app) {
    void _playSong() {
      app.setQueueAndPlay([song], 0, suppressAutoReco: true);
      // Seed mood window so scroll-based extendQueueWithMoreReco()
      // uses mood (this song) instead of falling back to bare song.id
      app.speedDial.seedMoodWindow(song);
      // Immediately load recommendations for this song
      app.ensureRelatedFor(song);
      Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, __, ___) => const NowPlayingScreen(),
          transitionsBuilder: (_, anim, __, child) => SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(anim),
            child: child,
          ),
        ),
      );
    }
    return InkWell(
      onTap: _playSong,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
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
                    AppAssets.placeholderSong, width: 52, height: 52, fit: BoxFit.cover),
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
                          color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 3),
                  Text(
                    'Song • ${song.artist}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: TaarColors.creamDim, fontSize: 12),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: () => _showMoreSheet(context, song.title, [
                _sheetOption(Icons.play_arrow_rounded, 'Play Now', _playSong),
                _sheetOption(Icons.playlist_add_rounded, 'Add to Queue', () => app.addToQueueEnd(song)),
                _sheetOption(
                  app.isLiked(song.id) ? Icons.favorite : Icons.favorite_border,
                  app.isLiked(song.id) ? 'Unlike' : 'Like',
                  () => app.toggleLike(song),
                ),
              ]),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.more_vert, color: TaarColors.creamDim, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _browseRow({
    required BrowseItem item,
    required String subtitle,
    required VoidCallback onTap,
    required VoidCallback onMore,
    bool circular = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(circular ? 26 : 6),
              child: CachedNetworkImage(
                imageUrl: item.image,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Image.asset(
                  item.type == 'artist' ? AppAssets.placeholderArtist : AppAssets.placeholderAlbum,
                  width: 52, height: 52, fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: TaarColors.creamDim, fontSize: 12)),
                ],
              ),
            ),
            GestureDetector(
              onTap: onMore,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.more_vert, color: TaarColors.creamDim, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showMoreSheet(BuildContext context, String title, List<Widget> options) {
    showModalBottomSheet(
      context: context,
      backgroundColor: TaarColors.ink2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 36, height: 4,
              decoration: BoxDecoration(color: TaarColors.line, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            const Divider(color: TaarColors.line, height: 1),
            ...options,
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  ListTile _sheetOption(IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: TaarColors.creamDim, size: 22),
      title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
      onTap: () { Navigator.pop(context); onTap(); },
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _resultsScroll.dispose();
    super.dispose();
  }
}

// ── Pill-shaped search bar ────────────────────────────────────────────────────
class _SearchPill extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final bool hasQuery;
  final VoidCallback onClear;

  const _SearchPill({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.hasQuery,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: TaarColors.ink2,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: TaarColors.line, width: 1),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          const Icon(Icons.search_rounded, color: TaarColors.creamDim, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: !hasQuery,
              onChanged: onChanged,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: const InputDecoration(
                hintText: 'Songs, albums or artists',
                hintStyle: TextStyle(color: TaarColors.creamDim, fontSize: 15),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
                filled: false,
              ),
            ),
          ),
          if (hasQuery) ...[
            GestureDetector(
              onTap: onClear,
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.close_rounded, color: TaarColors.creamDim, size: 18),
              ),
            ),
          ] else
            const SizedBox(width: 14),
        ],
      ),
    );
  }
}

// ── Chip widget ───────────────────────────────────────────────────────────────
class _Chip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _Chip({
    required this.label,
    required this.icon,
    this.iconColor = TaarColors.creamDim,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.only(left: 10, right: onDelete != null ? 4 : 12, top: 7, bottom: 7),
        decoration: BoxDecoration(
          color: TaarColors.ink2,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: TaarColors.line, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: iconColor),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
            if (onDelete != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onDelete,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded, size: 13, color: TaarColors.creamDim),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}