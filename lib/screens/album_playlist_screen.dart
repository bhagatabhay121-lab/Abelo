import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../app_assets.dart';
import '../models/song.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player.dart';
import '../widgets/glass_widget.dart';
import '../screens/now_playing_screen.dart';
import '../screens/library_screen.dart';
import '../widgets/playlist_picker.dart';

class AlbumPlaylistScreen extends StatefulWidget {
  final String id;
  final String type; // 'album' | 'playlist'
  final String title;

  const AlbumPlaylistScreen({super.key, required this.id, required this.type, required this.title});

  @override
  State<AlbumPlaylistScreen> createState() => _AlbumPlaylistScreenState();
}

class _AlbumPlaylistScreenState extends State<AlbumPlaylistScreen> {
  bool _loading = true;
  String? _error;
  String _title = '';
  String _subtitle = '';   // e.g. "Album · Banny XD"
  String _countLabel = ''; // e.g. "1 Songs"
  String _image = '';
  List<Song> _songs = [];
  List<Map<String, dynamic>> _albumReco = [];
  bool _recoLoading = false;
  String _permaUrl = '';

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    try {
      final raw = widget.type == 'album'
          ? await app.api.fetchAlbum(widget.id)
          : await app.api.fetchPlaylist(widget.id);

      final title = (raw['title'] ?? raw['listname'] ?? raw['name'] ?? widget.title).toString();
      String img = (raw['image'] ?? '').toString();
      img = img.replaceAll('150x150', '500x500').replaceAll('50x50', '500x500');

      final artist = (raw['primary_artists'] ??
              (raw['artistMap'] is Map ? raw['artistMap']['primary_artists'] : null) ??
              raw['firstname'] ??
              'JioSaavn')
          .toString();

      final songsRaw = (raw['songs'] ?? raw['list'] ?? []) as List;
      final songs = songsRaw.map((e) => Song.fromJson(Map<String, dynamic>.from(e))).toList();

      final typeLabel = widget.type == 'album' ? 'Album' : 'Playlist';
      final count = songs.length;

      setState(() {
        _title = title;
        _subtitle = '$typeLabel • $artist';
        _countLabel = '$count ${count == 1 ? 'Song' : 'Songs'}';
        _image = img;
        _songs = songs;
        _permaUrl = (raw['perma_url'] ?? '').toString();
        _loading = false;
      });

      // Fetch related albums in background (only for albums)
      if (widget.type == 'album') _fetchAlbumReco(widget.id);
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _fetchAlbumReco(String albumId) async {
    setState(() => _recoLoading = true);
    try {
      final reco = await context.read<AppState>().api.fetchAlbumReco(albumId);
      if (mounted) setState(() { _albumReco = reco; _recoLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _recoLoading = false);
    }
  }

  void _playAll() {
    if (_songs.isEmpty) return;
    context.read<AppState>().setQueueAndPlay(_songs, 0);
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, __, ___) => const NowPlayingScreen(),
      transitionsBuilder: (_, anim, __, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(anim),
        child: child,
      ),
    ));
  }

  void _shufflePlay() {
    if (_songs.isEmpty) return;
    final app = context.read<AppState>();
    app.setQueueAndPlay(_songs, 0);
    app.toggleShuffle();
  }

  void _showAlbumMenu(BuildContext context) {
    final app = context.read<AppState>();
    showGlassMenuDialog(
      context: context,
      title: _title,
      titleIcon: Icons.album_outlined,
      items: [
        ListTile(
          leading: const Icon(Icons.playlist_add, color: Colors.white),
          title: const Text('Add all to Playlist', style: TextStyle(color: Colors.white)),
          onTap: _songs.isEmpty ? null : () {
            Navigator.pop(context);
            _showAddAllToPlaylistSheet(context, app);
          },
        ),
        ListTile(
          leading: const Icon(Icons.queue_music_rounded, color: Colors.white),
          title: const Text('Add all to Queue', style: TextStyle(color: Colors.white)),
          onTap: _songs.isEmpty ? null : () {
            Navigator.pop(context);
            for (final s in _songs) app.addToQueueEnd(s);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${_songs.length} songs added to queue')));
          },
        ),
        ListTile(
          leading: const Icon(Icons.share_outlined, color: Colors.white),
          title: const Text('Share', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            final url = _permaUrl.isNotEmpty
                ? _permaUrl
                : 'https://www.jiosaavn.com/${widget.type}/${widget.id}';
            Share.share(url);
          },
        ),
      ],
    );
  }

  void _showAddAllToPlaylistSheet(BuildContext context, AppState app) {
    if (app.playlists.isEmpty) {
      final ctrl = TextEditingController();
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: TaarColors.ink2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('New Playlist',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Playlist name',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.2))),
              focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: TaarColors.marigold)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: Colors.white.withOpacity(0.5))),
            ),
            TextButton(
              onPressed: () {
                if (ctrl.text.trim().isNotEmpty) {
                  final pl = app.createPlaylist(ctrl.text);
                  for (final s in _songs) app.addSongToPlaylist(pl.id, s);
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${_songs.length} songs added to ${pl.name}')));
                }
              },
              child: const Text('Create & Add',
                  style: TextStyle(color: TaarColors.marigold, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
      return;
    }

    showGlassBottomSheet(
      context: context,
      isDraggable: true,
      initialSize: 0.55,
      builder: (ctx, sc) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  const Text('Add all to Playlist',
                      style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const PlaylistsScreen()));
                    },
                    icon: const Icon(Icons.add, size: 18, color: TaarColors.marigold),
                    label: const Text('New',
                        style: TextStyle(color: TaarColors.marigold, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.white.withOpacity(0.08)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.builder(
                controller: sc,
                shrinkWrap: true,
                itemCount: app.playlists.length,
                itemBuilder: (_, i) {
                  final pl = app.playlists[i];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: pl.songs.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: pl.songs.first.image,
                              width: 40, height: 40, fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => Container(
                                width: 40, height: 40, color: TaarColors.ink3,
                                child: const Icon(Icons.music_note, color: TaarColors.creamDim)),
                            )
                          : Container(
                              width: 40, height: 40, color: TaarColors.ink3,
                              child: const Icon(Icons.music_note, color: TaarColors.creamDim)),
                    ),
                    title: Text(pl.name,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    subtitle: Text('${pl.songs.length} songs',
                        style: const TextStyle(color: TaarColors.creamDim, fontSize: 12)),
                    trailing: const Icon(Icons.add_circle_outline, color: Colors.white, size: 22),
                    onTap: () {
                      for (final s in _songs) app.addSongToPlaylist(pl.id, s);
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${_songs.length} songs added to ${pl.name}')));
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

    @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TaarColors.ink,
      // ── App bar: back + download + share + overflow ───────────────────
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_outlined, color: Colors.white),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined, color: Colors.white),
            onPressed: _songs.isEmpty
                ? null
                : () {
                    final url = _permaUrl.isNotEmpty
                        ? _permaUrl
                        : 'https://www.jiosaavn.com/${widget.type}/${widget.id}';
                    Share.share(url);
                  },
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: () => _showAlbumMenu(context),
          ),
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
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: TaarColors.marigold))
          : _error != null
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Failed to load: $_error',
                      style: const TextStyle(color: TaarColors.creamDim)),
                ))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    // ── Header: art left, info right ─────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Square art
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: CachedNetworkImage(
                              imageUrl: _image,
                              width: 160,
                              height: 160,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => Image.asset(
                                widget.type == 'album'
                                    ? AppAssets.placeholderAlbum
                                    : AppAssets.placeholderSong,
                                width: 160, height: 160, fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Title + meta + buttons
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Text(
                                  _title,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      height: 1.2),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _countLabel,
                                  style: const TextStyle(
                                      color: TaarColors.creamDim, fontSize: 12.5),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _subtitle,
                                  style: const TextStyle(
                                      color: TaarColors.creamDim, fontSize: 12.5),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 18),
                                // Play + Shuffle row
                                Row(
                                  children: [
                                    // Play pill (filled, accent colour)
                                    Expanded(
                                      child: FilledButton.icon(
                                        style: FilledButton.styleFrom(
                                          backgroundColor: TaarColors.marigold,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 11),
                                          shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(99)),
                                        ),
                                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                                        label: const Text('Play',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w700, fontSize: 14)),
                                        onPressed: _songs.isEmpty ? null : _playAll,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    // Shuffle circle (outlined)
                                    InkWell(
                                      borderRadius: BorderRadius.circular(99),
                                      onTap: _songs.isEmpty ? null : _shufflePlay,
                                      child: Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: Colors.white.withOpacity(0.7), width: 1.5),
                                        ),
                                        child: Icon(Icons.shuffle_rounded,
                                            size: 18,
                                            color: Colors.white.withOpacity(0.85)),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ── "Songs" section header ────────────────────────────
                    if (_songs.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: Text('Songs',
                            style: const TextStyle(
                                color: TaarColors.marigold,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3)),
                      ),

                    if (_songs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text('No songs found',
                              style: TextStyle(color: TaarColors.creamDim)),
                        ),
                      )
                    else
                      // ── Song rows: art + title/subtitle + download/like/more ──
                      ...List.generate(_songs.length, (i) {
                        final song = _songs[i];
                        return _AlbumSongRow(
                          song: song,
                          onTap: () {
                            context.read<AppState>().setQueueAndPlay(_songs, i);
                            Navigator.of(context).push(PageRouteBuilder(
                              opaque: false,
                              pageBuilder: (_, __, ___) => const NowPlayingScreen(),
                              transitionsBuilder: (_, anim, __, child) => SlideTransition(
                                position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                                    .animate(anim),
                                child: child,
                              ),
                            ));
                          },
                        );
                      }),
                    // ── More Like This (Album Reco) ──────────────────────
                    if (widget.type == 'album') ...[
                      const SizedBox(height: 20),
                      if (_recoLoading)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator(
                              color: TaarColors.marigold, strokeWidth: 2)),
                        )
                      else if (_albumReco.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: Text('More Like This',
                              style: const TextStyle(
                                  color: TaarColors.marigold,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.3)),
                        ),
                        SizedBox(
                          height: 190,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: _albumReco.length,
                            itemBuilder: (ctx, i) {
                              final album = _albumReco[i];
                              final albumId = (album['id'] ?? '').toString();
                              final albumTitle = (album['title'] ?? album['album'] ?? 'Album').toString();
                              String albumImg = (album['image'] ?? '').toString();
                              albumImg = albumImg
                                  .replaceAll('150x150', '500x500')
                                  .replaceAll('50x50', '500x500');
                              final artist = (album['subtitle'] ?? album['primary_artists'] ?? album['artist'] ?? '').toString();
                              return GestureDetector(
                                onTap: albumId.isEmpty ? null : () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => AlbumPlaylistScreen(
                                          id: albumId, type: 'album', title: albumTitle),
                                    ),
                                  );
                                },
                                child: Container(
                                  width: 130,
                                  margin: const EdgeInsets.symmetric(horizontal: 4),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: CachedNetworkImage(
                                          imageUrl: albumImg,
                                          width: 130,
                                          height: 130,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, __, ___) => Container(
                                            width: 130, height: 130,
                                            color: TaarColors.ink3,
                                            child: const Icon(Icons.album,
                                                color: TaarColors.creamDim, size: 40),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(albumTitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 12.5)),
                                      if (artist.isNotEmpty)
                                        Text(artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                color: TaarColors.creamDim,
                                                fontSize: 11)),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ],
                ),
    );
  }
}

// ── Individual song row matching the image ────────────────────────────────────
class _AlbumSongRow extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const _AlbumSongRow({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final isCurrent = app.currentSong?.id == song.id;
    final isLiked = app.isLiked(song.id);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CachedNetworkImage(
                imageUrl: song.image,
                width: 50,
                height: 50,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Image.asset(
                    AppAssets.placeholderSong, width: 50, height: 50, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 12),
            // Title + subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? TaarColors.marigold : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${song.artist} • ${song.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: TaarColors.creamDim, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            // Download icon
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(Icons.download_outlined,
                  size: 20, color: Colors.white.withOpacity(0.6)),
              onPressed: () {},
            ),
            // Like icon
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                isLiked ? Icons.favorite : Icons.favorite_outline,
                size: 20,
                color: isLiked ? TaarColors.vermilion : Colors.white.withOpacity(0.6),
              ),
              onPressed: () => app.toggleLike(song),
            ),
            // More
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(Icons.more_vert,
                  size: 20, color: Colors.white.withOpacity(0.6)),
              onPressed: () => showSongActionSheet(context, song),
            ),
          ],
        ),
      ),
    );
  }
}
