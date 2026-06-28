import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../app_assets.dart';
import '../models/song.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/glass_widget.dart';
import '../screens/now_playing_screen.dart';
import '../screens/local_music_screen.dart';
import '../screens/settings_screen.dart';

// ============================================================
// Library Screen — menu-style list matching reference UI
// ============================================================
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        automaticallyImplyLeading: false,
        titleSpacing: 20,
        title: const Text('Library',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _LibraryMenuItem(
            icon: Icons.queue_music_rounded,
            label: 'Now Playing',
            onTap: () {
              final app = context.read<AppState>();
              if (app.currentSong != null) {
                Navigator.of(context).push(PageRouteBuilder(
                  opaque: false,
                  pageBuilder: (_, __, ___) => const NowPlayingScreen(),
                  transitionsBuilder: (_, anim, __, child) => SlideTransition(
                    position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                        .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
                    child: child,
                  ),
                ));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Nothing playing right now')),
                );
              }
            },
          ),
          _LibraryMenuItem(
            icon: Icons.history_rounded,
            label: 'Last Session',
            onTap: () => _push(context, const _LastSessionScreen()),
          ),
          _LibraryMenuItem(
            icon: Icons.smartphone_rounded,
            label: 'My Device Music',
            onTap: () => _push(context, const LocalMusicScreen()),
          ),
          _LibraryMenuItem(
            icon: Icons.playlist_play_rounded,
            label: 'Playlists',
            onTap: () => _push(context, const PlaylistsScreen()),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Divider(color: Colors.white12, height: 32),
          ),
          _LibraryMenuItem(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onTap: () => _push(context, const SettingsScreen()),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }
}

class _LibraryMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _LibraryMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 26),
            const SizedBox(width: 20),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Favorites / Liked Songs screen
// ============================================================
class _FavoritesScreen extends StatelessWidget {
  const _FavoritesScreen();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final liked = app.likedSongs.values.toList();
    return _SongListScreen(
      title: 'Favorites',
      emptyMessage: 'Go and Add Something',
      songs: liked,
      tabs: const ['Songs', 'Albums', 'Artists', 'Genres'],
    );
  }
}

// ============================================================
// Last Session screen
// ============================================================
class _LastSessionScreen extends StatelessWidget {
  const _LastSessionScreen();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return _SongListScreen(
      title: 'Last Session',
      emptyMessage: 'Go and Play Something',
      songs: app.recentlyPlayed,
    );
  }
}

// ============================================================
// My Music screen (downloads)
// ============================================================
class _MyMusicScreen extends StatelessWidget {
  const _MyMusicScreen();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final downloaded = app.likedSongs.values
        .where((s) => app.isDownloaded(s.id))
        .toList();
    return _SongListScreen(
      title: 'My Music',
      emptyMessage: 'Download Something First',
      songs: downloaded,
    );
  }
}

// ============================================================
// Subscriptions stub
// ============================================================
class _SubscriptionsScreen extends StatelessWidget {
  const _SubscriptionsScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        title: const Text('Subscriptions'),
      ),
      body: _EmptyState(headline: 'Nothing to\nShow Here', sub: 'No subscriptions yet'),
    );
  }
}

// ============================================================
// Stats stub
// ============================================================
class _StatsScreen extends StatelessWidget {
  const _StatsScreen();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        title: const Text('Stats'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _StatCard(label: 'Songs Liked', value: '${app.likedSongs.length}'),
          const SizedBox(height: 12),
          _StatCard(label: 'Recently Played', value: '${app.recentlyPlayed.length}'),
          const SizedBox(height: 12),
          _StatCard(label: 'Playlists Created', value: '${app.playlists.length}'),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: TaarColors.ink2,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: TaarColors.creamDim, fontSize: 15)),
          Text(value,
              style: const TextStyle(
                  color: TaarColors.marigold, fontSize: 24, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

// ============================================================
// Playlists screen
// ============================================================
class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        title: const Text('Playlists',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
      ),
      body: ListView(
        children: [
          // Actions
          _PlaylistAction(
            icon: Icons.add,
            label: 'Create Playlist',
            onTap: () => _showCreateDialog(context, app),
          ),
          _PlaylistAction(
            icon: Icons.login_rounded,
            label: 'Import Playlist',
            onTap: () => _showImportDialog(context, app),
          ),
          _PlaylistAction(
            icon: Icons.merge_type_rounded,
            label: 'Merge Playlists',
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Merge coming soon')),
            ),
          ),
          // Divider
          Divider(height: 1, color: Colors.white.withOpacity(0.07), indent: 16, endIndent: 16),
          const SizedBox(height: 8),
          // ── Liked Songs (default, always-visible) ──
          _LikedSongsTile(
            count: app.likedSongs.length,
            songs: app.likedSongs.values.toList(),
          ),
          if (app.playlists.isNotEmpty) ...[
            Divider(height: 1, color: Colors.white.withOpacity(0.07), indent: 16, endIndent: 16),
            const SizedBox(height: 4),
            ...app.playlists.map((pl) => _PlaylistTile(
                  playlist: pl,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PlaylistDetailScreen(playlistId: pl.id),
                  )),
                  onMore: () => _showPlaylistOptions(context, app, pl),
                )),
          ],
        ],
      ),
    );
  }

  void _showImportDialog(BuildContext context, AppState app) {
    final ctrl = TextEditingController();
    bool isLoading = false;
    String? errorText;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setS) => AlertDialog(
          backgroundColor: TaarColors.ink2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            'Import Playlist',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Paste a JioSaavn playlist URL',
                style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'https://www.jiosaavn.com/s/playlist/...',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12),
                        enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white.withOpacity(0.2))),
                        focusedBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: TaarColors.marigold)),
                        errorText: errorText,
                        errorStyle: const TextStyle(color: TaarColors.vermilion),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.paste_rounded, color: TaarColors.creamDim, size: 20),
                    tooltip: 'Paste',
                    onPressed: () async {
                      final data = await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) ctrl.text = data!.text!;
                    },
                  ),
                ],
              ),
              if (isLoading) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator(color: TaarColors.marigold, strokeWidth: 2)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(ctx2),
              child: Text('Cancel', style: TextStyle(color: Colors.white.withOpacity(0.5))),
            ),
            TextButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      final url = ctrl.text.trim();
                      if (url.isEmpty) {
                        setS(() => errorText = 'Please enter a URL');
                        return;
                      }
                      if (!url.contains('jiosaavn.com')) {
                        setS(() => errorText = 'Only JioSaavn playlist URLs supported');
                        return;
                      }
                      setS(() { isLoading = true; errorText = null; });
                      try {
                        final raw = await app.api.fetchPlaylistByUrl(url);
                        final name = (raw['listname'] ?? raw['title'] ?? raw['name'] ?? 'Imported Playlist').toString();
                        final songsRaw = (raw['songs'] ?? raw['list'] ?? []) as List;
                        final songs = songsRaw
                            .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
                            .toList();
                        if (songs.isEmpty) {
                          setS(() { isLoading = false; errorText = 'No songs found in playlist'; });
                          return;
                        }
                        // Create local playlist and bulk-add songs
                        app.createPlaylist(name);
                        final pl = app.playlists.last;
                        for (final song in songs) {
                          app.addSongToPlaylist(pl.id, song);
                        }
                        if (ctx2.mounted) Navigator.pop(ctx2);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Imported "$name" — ${songs.length} songs'),
                              backgroundColor: TaarColors.ink3,
                            ),
                          );
                        }
                      } catch (e) {
                        setS(() { isLoading = false; errorText = 'Import failed: ${e.toString().replaceAll('Exception: ', '')}'; });
                      }
                    },
              child: const Text('Import', style: TextStyle(color: TaarColors.marigold, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context, AppState app) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TaarColors.ink2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('New Playlist', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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
                app.createPlaylist(ctrl.text);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Create', style: TextStyle(color: TaarColors.marigold, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _showPlaylistOptions(BuildContext context, AppState app, TaarPlaylist pl) {
    showGlassMenuDialog(
      context: context,
      title: pl.name,
      titleIcon: Icons.queue_music_rounded,
      items: [
        ListTile(
          leading: const Icon(Icons.play_arrow_rounded, color: Colors.white),
          title: const Text('Play', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            if (pl.songs.isNotEmpty) app.setQueueAndPlay(pl.songs, 0);
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined, color: Colors.white),
          title: const Text('Rename', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _showRenameDialog(context, app, pl);
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: TaarColors.vermilion),
          title: const Text('Delete', style: TextStyle(color: TaarColors.vermilion)),
          onTap: () {
            Navigator.pop(context);
            app.deletePlaylist(pl.id);
          },
        ),
      ],
    );
  }

  void _showRenameDialog(BuildContext context, AppState app, TaarPlaylist pl) {
    final ctrl = TextEditingController(text: pl.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TaarColors.ink2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Rename Playlist', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'New name',
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
                app.renamePlaylist(pl.id, ctrl.text);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Save', style: TextStyle(color: TaarColors.marigold, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _PlaylistAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PlaylistAction({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(width: 20),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontSize: 16, fontWeight: FontWeight.w400)),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Liked Songs — default pinned playlist tile
// ============================================================
class _LikedSongsTile extends StatelessWidget {
  final int count;
  final List<Song> songs;
  const _LikedSongsTile({required this.count, required this.songs});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LikedSongsScreen()),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Heart-tinted art grid
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: songs.isEmpty
                  ? Container(
                      width: 52,
                      height: 52,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0xFF6A0572), Color(0xFFE91E63)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: const Icon(Icons.favorite, color: Colors.white, size: 26),
                    )
                  : songs.length < 4
                      ? Stack(children: [
                          CachedNetworkImage(
                            imageUrl: songs.first.image,
                            width: 52,
                            height: 52,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              width: 52,
                              height: 52,
                              color: TaarColors.ink3,
                              child: const Icon(Icons.favorite, color: Colors.pinkAccent),
                            ),
                          ),
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Icon(Icons.favorite, color: Colors.pinkAccent, size: 12),
                            ),
                          ),
                        ])
                      : SizedBox(
                          width: 52,
                          height: 52,
                          child: GridView.count(
                            crossAxisCount: 2,
                            physics: const NeverScrollableScrollPhysics(),
                            children: songs.take(4).map((s) => CachedNetworkImage(
                                  imageUrl: s.image,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => Container(
                                    color: TaarColors.ink3,
                                    child: const Icon(Icons.favorite, color: Colors.pinkAccent, size: 12),
                                  ),
                                )).toList(),
                          ),
                        ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Liked Songs',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$count song${count == 1 ? '' : 's'}',
                    style: const TextStyle(color: TaarColors.creamDim, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.favorite, color: Colors.pinkAccent, size: 20),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Liked Songs full-screen playlist
// ============================================================
class LikedSongsScreen extends StatelessWidget {
  const LikedSongsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final songs = app.likedSongs.values.toList();

    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        title: const Text('Liked Songs',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
        actions: [
          if (songs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded,
                  color: TaarColors.marigold, size: 28),
              onPressed: () => app.setQueueAndPlay(songs, 0),
            ),
        ],
      ),
      body: songs.isEmpty
          ? const _EmptyState(
              headline: 'Nothing to\nShow Here',
              sub: 'Like a song to save it here',
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 120),
              itemCount: songs.length,
              itemBuilder: (_, i) => _LikedSongRow(
                song: songs[i],
                index: i,
                allSongs: songs,
              ),
            ),
    );
  }
}

class _LikedSongRow extends StatelessWidget {
  final Song song;
  final int index;
  final List<Song> allSongs;

  const _LikedSongRow({
    required this.song,
    required this.index,
    required this.allSongs,
  });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final isCurrent = app.currentSong?.id == song.id;

    return InkWell(
      onTap: () {
        app.setQueueAndPlay(allSongs, index);
        Navigator.of(context).push(PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, __, ___) => const NowPlayingScreen(),
          transitionsBuilder: (_, anim, __, child) => SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: song.image,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Image.asset(
                  AppAssets.placeholderCover,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 12),
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
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: TaarColors.creamDim, fontSize: 12),
                  ),
                ],
              ),
            ),
            // Unlike button
            IconButton(
              icon: const Icon(Icons.favorite, color: Colors.pinkAccent, size: 20),
              onPressed: () => app.toggleLike(song),
              tooltip: 'Unlike',
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final TaarPlaylist playlist;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _PlaylistTile({required this.playlist, required this.onTap, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Playlist art grid or placeholder
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _PlaylistArt(songs: playlist.songs),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(playlist.name,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text('${playlist.songs.length} songs',
                      style: const TextStyle(color: TaarColors.creamDim, fontSize: 12)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
              onPressed: onMore,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistArt extends StatelessWidget {
  final List<Song> songs;
  const _PlaylistArt({required this.songs});

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) {
      return Container(
        width: 52,
        height: 52,
        color: TaarColors.ink3,
        child: const Icon(Icons.music_note, color: TaarColors.creamDim, size: 26),
      );
    }
    if (songs.length < 4) {
      return CachedNetworkImage(
        imageUrl: songs.first.image,
        width: 52,
        height: 52,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => Container(
          width: 52, height: 52, color: TaarColors.ink3,
          child: const Icon(Icons.music_note, color: TaarColors.creamDim),
        ),
      );
    }
    // 2x2 grid of first 4 covers
    final imgs = songs.take(4).toList();
    return SizedBox(
      width: 52,
      height: 52,
      child: GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        children: imgs.map((s) => CachedNetworkImage(
              imageUrl: s.image,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) =>
                  Container(color: TaarColors.ink3, child: const Icon(Icons.music_note, color: TaarColors.creamDim, size: 12)),
            )).toList(),
      ),
    );
  }
}

// ============================================================
// Playlist Detail screen
// ============================================================
class PlaylistDetailScreen extends StatelessWidget {
  final String playlistId;
  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    TaarPlaylist? pl;
    try {
      pl = app.playlists.firstWhere((p) => p.id == playlistId);
    } catch (_) {}

    if (pl == null) {
      return Scaffold(
        backgroundColor: TaarColors.ink,
        appBar: AppBar(backgroundColor: TaarColors.ink),
        body: const Center(child: Text('Playlist not found', style: TextStyle(color: TaarColors.creamDim))),
      );
    }

    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        title: Text(pl.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (pl.songs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded, color: TaarColors.marigold, size: 28),
              onPressed: () => app.setQueueAndPlay(pl!.songs, 0),
            ),
        ],
      ),
      body: pl.songs.isEmpty
          ? _EmptyState(headline: 'Nothing to\nShow Here', sub: 'Add songs to this playlist')
          : ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 120),
              buildDefaultDragHandles: false,
              itemCount: pl.songs.length,
              onReorder: (oldI, newI) {
                // Reorder within playlist
                if (newI > oldI) newI -= 1;
                final song = pl!.songs.removeAt(oldI);
                pl.songs.insert(newI, song);
                app.notifyListeners();
                app.savePlaylists();
              },
              itemBuilder: (ctx, i) {
                final s = pl!.songs[i];
                return _PlaylistSongRow(
                  key: ValueKey('${s.id}_$i'),
                  song: s,
                  index: i,
                  playlist: pl,
                  reorderIndex: i,
                  contextQueue: pl.songs,
                );
              },
            ),
    );
  }
}

class _PlaylistSongRow extends StatelessWidget {
  final Song song;
  final int index;
  final TaarPlaylist playlist;
  final int reorderIndex;
  final List<Song> contextQueue;

  const _PlaylistSongRow({
    super.key,
    required this.song,
    required this.index,
    required this.playlist,
    required this.reorderIndex,
    required this.contextQueue,
  });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final isCurrent = app.currentSong?.id == song.id;

    return InkWell(
      onTap: () {
        app.setQueueAndPlay(contextQueue, index);
        Navigator.of(context).push(PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, __, ___) => const NowPlayingScreen(),
          transitionsBuilder: (_, anim, __, child) => SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: song.image,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Image.asset(
                    AppAssets.placeholderCover, width: 48, height: 48, fit: BoxFit.cover),
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
                      style: TextStyle(
                          color: isCurrent ? TaarColors.marigold : Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: TaarColors.creamDim, fontSize: 12)),
                ],
              ),
            ),
            // Remove from playlist
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: TaarColors.vermilion, size: 20),
              onPressed: () => app.removeSongFromPlaylist(playlist.id, song.id),
            ),
            // Drag handle
            ReorderableDragStartListener(
              index: reorderIndex,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.drag_handle_rounded,
                    color: Colors.white.withOpacity(0.25), size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Generic Song List screen (Favorites / Last Session / My Music)
// ============================================================
class _SongListScreen extends StatelessWidget {
  final String title;
  final String emptyMessage;
  final List<Song> songs;
  final List<String>? tabs;

  const _SongListScreen({
    required this.title,
    required this.emptyMessage,
    required this.songs,
    this.tabs,
  });

  @override
  Widget build(BuildContext context) {
    final hasTabs = tabs != null && tabs!.isNotEmpty;

    Widget body = songs.isEmpty
        ? _EmptyState(headline: 'Nothing to\nShow Here', sub: emptyMessage)
        : ListView.builder(
            padding: const EdgeInsets.only(bottom: 120),
            itemCount: songs.length,
            itemBuilder: (_, i) =>
                SongTile(song: songs[i], index: i, contextQueue: songs),
          );

    if (hasTabs) {
      return DefaultTabController(
        length: tabs!.length,
        child: Scaffold(
          backgroundColor: TaarColors.ink,
          appBar: AppBar(
            backgroundColor: TaarColors.ink,
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
            actions: [
              IconButton(icon: const Icon(Icons.search), onPressed: () {}),
              IconButton(icon: const Icon(Icons.filter_list), onPressed: () {}),
            ],
            bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorColor: TaarColors.marigold,
              labelColor: Colors.white,
              unselectedLabelColor: TaarColors.creamDim,
              indicatorSize: TabBarIndicatorSize.tab,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              tabs: tabs!.map((t) => Tab(text: t)).toList(),
            ),
          ),
          body: TabBarView(
            children: [
              // Songs tab — real content
              body,
              // Albums/Artists/Genres — stubs
              ...List.generate(
                tabs!.length - 1,
                (_) => _EmptyState(headline: 'Nothing to\nShow Here', sub: emptyMessage),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
        actions: [
          IconButton(icon: const Icon(Icons.menu), onPressed: () {}),
        ],
      ),
      body: body,
    );
  }
}

// ============================================================
// Empty state widget — matching reference "Nothing to Show Here" style
// ============================================================
class _EmptyState extends StatelessWidget {
  final String headline;
  final String sub;

  const _EmptyState({required this.headline, required this.sub});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const RotatedBox(
              quarterTurns: 3,
              child: Text(
                'Nothing to',
                style: TextStyle(
                    color: TaarColors.marigold,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 1),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Show Here',
                      style: TextStyle(
                          color: TaarColors.marigold,
                          fontSize: 34,
                          fontWeight: FontWeight.w900,
                          height: 1.0)),
                  Text(sub,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}