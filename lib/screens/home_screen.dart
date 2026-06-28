import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import '../models/song.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/browse_row.dart';
import '../widgets/song_tile.dart';
import 'album_playlist_screen.dart';
import 'artist_screen.dart';
import 'now_playing_screen.dart';
import 'search_screen.dart';
import '../widgets/speed_dial_widget.dart';
import '../services/speed_dial_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loading = true;
  String? _error;

  List<Song> trendingSongs = [];
  List<BrowseItem> trendingItems = [];
  List<BrowseItem> charts = [];
  List<BrowseItem> newAlbums = [];
  List<BrowseItem> topPlaylists = [];
  List<BrowseItem> artists = [];
  List<BrowseItem> radio = [];
  List<BrowseItem> freshHits = [];
  List<BrowseItem> cityMod = [];
  String cityModTitle = "What's Hot";

  @override
  void initState() {
    super.initState();
    _load();
  }

  List _pick(Map<String, dynamic> raw, List<String> keys) {
    for (final k in keys) {
      final v = raw[k];
      if (v is List) return v;
      if (v is Map && v['data'] is List) return v['data'];
    }
    return [];
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final app = context.read<AppState>();
      final raw = await app.api.fetchHomeData();

      trendingSongs = [];
      trendingItems = [];
      for (final e in _pick(raw, ['new_trending', 'trending'])) {
        final item = Map<String, dynamic>.from(e);
        final type = (item['type'] ?? '').toString();
        final moreInfo = (item['more_info'] is Map)
            ? Map<String, dynamic>.from(item['more_info'])
            : <String, dynamic>{};

        if (type == 'song') {
          final song = Song.fromJson(item);
          if (song.id.isNotEmpty) {
            trendingSongs.add(song);
            trendingItems.add(BrowseItem(
              id: song.id, title: song.title,
              subtitle: song.artist, image: song.image, type: 'song',
            ));
          }
        } else if (type == 'album') {
          final id = (item['id'] ?? moreInfo['album_id'] ?? '').toString();
          if (id.isNotEmpty) trendingItems.add(BrowseItem.fromJson(item, type: 'album'));
        } else if (type == 'playlist') {
          final id = (item['id'] ?? moreInfo['listid'] ?? '').toString();
          if (id.isNotEmpty) trendingItems.add(BrowseItem.fromJson(item, type: 'playlist'));
        }
      }

      charts = _pick(raw, ['charts'])
          .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'playlist'))
          .toList();

      newAlbums = [];
      for (final e in _pick(raw, ['new_albums', 'albums'])) {
        final item = Map<String, dynamic>.from(e);
        final type = (item['type'] ?? 'album').toString();
        if (type == 'song') continue;
        newAlbums.add(BrowseItem.fromJson(item, type: type == 'playlist' ? 'playlist' : 'album'));
      }

      topPlaylists = _pick(raw, ['top_playlists', 'playlists'])
          .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'playlist'))
          .toList();

      artists = _pick(raw, ['artist_recos', 'artists'])
          .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'artist'))
          .toList();

      radio = _pick(raw, ['radio', 'top_radio_station', 'stations'])
          .map((e) => BrowseItem.fromJson(Map<String, dynamic>.from(e), type: 'radio'))
          .toList();

      // Fresh Hits — promo sections (mirrors HTML's renderFresh)
      final modules = raw['modules'] is Map ? Map<String, dynamic>.from(raw['modules']) : <String, dynamic>{};
      freshHits = [];
      for (final key in raw.keys) {
        if (key.startsWith('promo:vx:data:') && raw[key] is List) {
          final items = raw[key] as List;
          for (final e in items) {
            freshHits.add(BrowseItem.fromJson(Map<String, dynamic>.from(e),
                type: (e['type'] ?? 'album').toString()));
          }
          if (freshHits.isNotEmpty) break;
        }
      }

      // City Mod — what's hot locally
      cityMod = _pick(raw, ['city_mod'])
          .map((e) {
            final item = Map<String, dynamic>.from(e);
            final type = (item['type'] ?? 'song').toString();
            return BrowseItem.fromJson(item, type: type);
          }).toList();
      cityModTitle = modules['city_mod']?['title'] ?? "What's Hot";

      setState(() => _loading = false);
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _openTrendingItem(BrowseItem item) {
    if (item.type == 'song') {
      final index = trendingSongs.indexWhere((s) => s.id == item.id);
      if (index != -1) context.read<AppState>().setQueueAndPlay(trendingSongs, index);
      return;
    }
    _openBrowseItem(item);
  }

  void _openBrowseItem(BrowseItem item) {
    switch (item.type) {
      case 'artist':
        Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistScreen(artistId: item.id)));
        break;
      case 'radio':
        _playRadio(item);
        break;
      case 'genre':
        Navigator.push(context, MaterialPageRoute(builder: (_) => SearchScreen(initialQuery: item.title)));
        break;
      default:
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => AlbumPlaylistScreen(
            id: item.id, type: item.type == 'album' ? 'album' : 'playlist', title: item.title,
          ),
        ));
    }
  }

  Future<void> _playRadio(BrowseItem item) async {
    final app = context.read<AppState>();
    try {
      final songs = await app.api.getRadioSongs(item.id, count: 20);
      if (songs.isNotEmpty) app.setQueueAndPlay(songs, 0);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Radio failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final quickPick = context.watch<SpeedDialService>().quickPickSongs;

    return Scaffold(
      body: SafeArea(
        child: _loading
            ? _skeleton()
            : _error != null
                ? _errorState()
                : RefreshIndicator(
                    onRefresh: _load,
                    color: TaarColors.marigold,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        _header(context, app),
                        const SizedBox(height: 8),

                        // ── Speed Dial ───────────────────────────────────
                        const SpeedDialWidget(),

                        // ── Quick Pick ───────────────────────────────────
                        if (quickPick.isNotEmpty) ...[
                          _quickPickSection(quickPick),
                          const SizedBox(height: 16),
                        ],

                        // ── New & Trending ───────────────────────────────
                        if (trendingItems.isNotEmpty) ...[
                          BrowseRow(title: 'New & Trending', items: trendingItems, onTap: _openTrendingItem),
                          const SizedBox(height: 16),
                        ],

                        // ── Top Charts ───────────────────────────────────
                        BrowseRow(title: 'Top Charts', items: charts, onTap: _openBrowseItem),
                        const SizedBox(height: 16),

                        // ── New Releases / Albums ────────────────────────
                        BrowseRow(title: 'New Releases', items: newAlbums, onTap: _openBrowseItem),
                        const SizedBox(height: 16),

                        // ── Editorial Playlists ──────────────────────────
                        BrowseRow(title: 'Editorial Picks', items: topPlaylists, onTap: _openBrowseItem),
                        const SizedBox(height: 16),

                        // ── Fresh Hits (promo) ───────────────────────────
                        if (freshHits.isNotEmpty) ...[
                          BrowseRow(title: 'Fresh Hits', items: freshHits, onTap: _openBrowseItem),
                          const SizedBox(height: 16),
                        ],

                        // ── What's Hot in City ───────────────────────────
                        if (cityMod.isNotEmpty) ...[
                          BrowseRow(title: cityModTitle, items: cityMod, onTap: _openBrowseItem),
                          const SizedBox(height: 16),
                        ],

                        // ── Artist Radio ─────────────────────────────────
                        BrowseRow(title: 'Artist Radio', items: artists, onTap: _openBrowseItem, circular: true),
                        const SizedBox(height: 16),

                        // ── Radio Stations ───────────────────────────────
                        BrowseRow(title: 'Radio Stations', items: radio, onTap: _openBrowseItem),
                        const SizedBox(height: 16),

                        // ── Moods & Genres moved to Search screen ────────

                      ],
                    ),
                  ),
      ),
    );
  }

  /// Plays a last-session song, then queues recommendations based on it.
  Future<void> _playWithReco(Song song) async {
    final app = context.read<AppState>();
    // Play the tapped song immediately
    app.setQueueAndPlay([song], 0);
    // Navigate to now playing
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
    // Fetch recommendations seeded from the tapped song itself — not the
    // overall mood/taste seed — so recos match what you just clicked on.
    try {
      final seedId = song.id;
      final recos = await app.api.fetchReco(seedId);
      if (recos.isNotEmpty) {
        app.setQueueAndPlay([song, ...recos], 0);
      }
    } catch (_) {
      // If reco fetch fails, single song keeps playing — no crash
    }
  }

  /// Quick Pick — random selection of up to 9 songs from the user's top 30
  /// most-listened songs, shown in the same horizontal-paging list UI as the
  /// old Last Session. Songs are pre-shuffled by the service getter so each
  /// home-screen build shows a fresh random set.
  Widget _quickPickSection(List<Song> songs) {
    // Split into pages of 4 (same layout as Last Session)
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
                    return SizedBox(
                      height: rowHeight,
                      child: SongTile(
                        song: song,
                        index: 0,
                        contextQueue: [song],
                        dense: true,
                        onTap: () => _playWithReco(song),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, AppState app) {
    final name = app.username.isEmpty ? null : app.username;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Hi There,',
                      style: TaarTheme.display(context, size: 26, weight: FontWeight.w800)
                          .copyWith(color: TaarColors.marigold)),
                  if (name != null)
                    Text(name,
                        style: TaarTheme.display(context, size: 26, weight: FontWeight.w800)
                            .copyWith(color: Colors.white)),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const SearchScreen())),
            icon: const Icon(Icons.search, color: TaarColors.marigold, size: 26),
            tooltip: 'Search',
          ),
        ],
      ),
    );
  }

  Widget _skeleton() => Shimmer.fromColors(
        baseColor: TaarColors.ink3,
        highlightColor: TaarColors.ink2,
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: 6,
          itemBuilder: (_, __) => Container(
            height: 130,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: TaarColors.ink3, borderRadius: BorderRadius.circular(12)),
          ),
        ),
      );

  Widget _errorState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Failed to load', style: TaarTheme.display(context, size: 20)),
              const SizedBox(height: 8),
              Text(_error ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: TaarColors.creamDim)),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: TaarColors.marigold, foregroundColor: Colors.white),
                onPressed: _load,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
}