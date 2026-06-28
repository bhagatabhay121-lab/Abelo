import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/song.dart';
import '../state/app_state.dart';
import '../services/local_music_service.dart';
import '../theme.dart';
import '../screens/now_playing_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry point — consumed from LibraryScreen's "My Device Music" menu item
// ─────────────────────────────────────────────────────────────────────────────
class LocalMusicScreen extends StatefulWidget {
  const LocalMusicScreen({super.key});

  @override
  State<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends State<LocalMusicScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  final _searchCtrl = TextEditingController();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _searchCtrl.addListener(() {
      context.read<LocalMusicService>().setSearch(_searchCtrl.text);
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Permissions + scan ───────────────────────────────────────────────────

  Future<void> _requestAndScan() async {
    final svc = context.read<LocalMusicService>();

    if (Platform.isAndroid) {
      // Strategy: try READ_MEDIA_AUDIO first (Android 13+).
      // If denied/restricted, fall back to READ_EXTERNAL_STORAGE (Android <= 12).
      // This avoids the unreliable getprop version check.
      bool granted = false;

      final audioStatus = await Permission.audio.status;
      if (audioStatus.isGranted) {
        granted = true;
      } else {
        final audioRequest = await Permission.audio.request();
        if (audioRequest.isGranted) {
          granted = true;
        } else {
          // READ_MEDIA_AUDIO not applicable (Android <= 12) - try storage
          final storageStatus = await Permission.storage.status;
          if (storageStatus.isGranted) {
            granted = true;
          } else {
            final storageRequest = await Permission.storage.request();
            granted = storageRequest.isGranted;
          }
        }
      }

      if (!granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Storage permission required to scan music'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: openAppSettings,
            ),
          ),
        );
        return;
      }
    }

    // Collect every file path that AppState already tracks as a completed
    // download so scanDevice() won't create a duplicate LocalSong for it.
    final app = context.read<AppState>();
    final downloadedPaths = app.downloadedFilePaths;
    await svc.scanDevice(excludePaths: downloadedPaths);
  }

  // ── File picker import ───────────────────────────────────────────────────

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.audio,
    );
    if (result == null) return;
    final paths = result.paths.whereType<String>().toList();
    if (!mounted) return;
    await context.read<LocalMusicService>().importFiles(paths);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${paths.length} file(s) added to library')),
    );
  }

  // ── Play helpers ─────────────────────────────────────────────────────────

  void _playSong(BuildContext ctx, LocalSong song, List<LocalSong> queue) {
    final app = ctx.read<AppState>();
    final songs = queue.map((s) => s.toSong()).toList();
    final idx = queue.indexWhere((s) => s.id == song.id);
    app.setQueueAndPlay(songs, idx < 0 ? 0 : idx);
    Navigator.of(ctx).push(PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, __, ___) => const NowPlayingScreen(),
      transitionsBuilder: (_, anim, __, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<LocalMusicService>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        titleSpacing: 4,
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search songs, artists, albums…',
                  hintStyle:
                      TextStyle(color: Colors.white.withOpacity(0.4)),
                  border: InputBorder.none,
                ),
              )
            : const Text('My Device Music',
                style:
                    TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
        actions: [
          // Search toggle
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _searchCtrl.clear();
                  svc.setSearch('');
                }
              });
            },
          ),
          // Sort menu
          PopupMenuButton<LocalSortOrder>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            color: TaarColors.ink2,
            onSelected: (order) => svc.setSort(order),
            itemBuilder: (_) => [
              _sortItem(LocalSortOrder.title, 'Title', svc),
              _sortItem(LocalSortOrder.artist, 'Artist', svc),
              _sortItem(LocalSortOrder.album, 'Album', svc),
              _sortItem(LocalSortOrder.dateAdded, 'Date Added', svc),
              _sortItem(LocalSortOrder.duration, 'Duration', svc),
            ],
          ),
          // More actions
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: TaarColors.ink2,
            onSelected: (v) {
              if (v == 'scan') _requestAndScan();
              if (v == 'import') _pickFiles();
              if (v == 'clear') _confirmClearAll(context, svc);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'scan',
                child: ListTile(
                    leading: Icon(Icons.folder_open), title: Text('Scan Device')),
              ),
              const PopupMenuItem(
                value: 'import',
                child: ListTile(
                    leading: Icon(Icons.add_to_photos),
                    title: Text('Import Files')),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: ListTile(
                    leading: Icon(Icons.delete_sweep),
                    title: Text('Clear Library')),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: TaarColors.marigold,
          labelColor: Colors.white,
          unselectedLabelColor: TaarColors.creamDim,
          tabs: const [
            Tab(text: 'Songs'),
            Tab(text: 'Albums'),
            Tab(text: 'Artists'),
            Tab(text: 'Playlists'),
          ],
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tab,
            children: [
              _SongsTab(onPlay: _playSong),
              _AlbumsTab(onPlay: _playSong),
              _ArtistsTab(onPlay: _playSong),
              _PlaylistsTab(onPlay: _playSong),
            ],
          ),

          // Scan progress overlay
          if (svc.isScanning)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                color: TaarColors.ink2,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: TaarColors.marigold,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Scanning… ${svc.scanProgress} files found',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const LinearProgressIndicator(
                      color: TaarColors.marigold,
                      backgroundColor: TaarColors.ink3,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),

      // FAB — quick scan
      floatingActionButton: svc.songs.isEmpty && !svc.isScanning
          ? FloatingActionButton.extended(
              backgroundColor: TaarColors.marigold,
              icon: const Icon(Icons.folder_open, color: Colors.white),
              label: const Text('Scan Device',
                  style: TextStyle(color: Colors.white)),
              onPressed: _requestAndScan,
            )
          : null,
    );
  }

  PopupMenuItem<LocalSortOrder> _sortItem(
      LocalSortOrder order, String label, LocalMusicService svc) {
    final active = svc.sortOrder == order;
    return PopupMenuItem(
      value: order,
      child: Row(
        children: [
          Icon(
            svc.sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
            size: 16,
            color: active ? TaarColors.marigold : Colors.transparent,
          ),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  color:
                      active ? TaarColors.marigold : Colors.white)),
        ],
      ),
    );
  }

  void _confirmClearAll(BuildContext context, LocalMusicService svc) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TaarColors.ink2,
        title: const Text('Clear Library',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Remove all songs from your local library? '
          'Your actual files won\'t be deleted.',
          style: TextStyle(color: TaarColors.creamDim),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: TaarColors.creamDim))),
          TextButton(
              onPressed: () {
                svc.clearAll();
                Navigator.pop(context);
              },
              child: const Text('Clear',
                  style: TextStyle(color: TaarColors.marigold))),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Songs tab
// ─────────────────────────────────────────────────────────────────────────────
class _SongsTab extends StatelessWidget {
  final void Function(BuildContext, LocalSong, List<LocalSong>) onPlay;
  const _SongsTab({required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<LocalMusicService>();
    final songs = svc.filteredSongs;

    if (songs.isEmpty) {
      return _EmptyState(
        icon: Icons.music_note_outlined,
        title: 'No songs yet',
        subtitle: svc.searchQuery.isNotEmpty
            ? 'No results for "${svc.searchQuery}"'
            : 'Tap Scan Device or Import Files to add music',
      );
    }

    return Column(
      children: [
        // Play-all bar
        _PlayAllBar(
          count: songs.length,
          onPlayAll: () => onPlay(context, songs.first, songs),
          onShuffle: () {
            final shuffled = List.of(songs)..shuffle();
            onPlay(context, shuffled.first, shuffled);
          },
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 120),
            itemCount: songs.length,
            itemBuilder: (ctx, i) {
              final s = songs[i];
              return _LocalSongTile(
                song: s,
                onTap: () => onPlay(ctx, s, songs),
                onFav: () => svc.toggleFavourite(s.id),
                onRemove: () => svc.removeSong(s.id),
                onAddToPlaylist: () =>
                    _showAddToPlaylist(ctx, svc, s),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showAddToPlaylist(
      BuildContext ctx, LocalMusicService svc, LocalSong song) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: TaarColors.ink2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _AddToPlaylistSheet(svc: svc, song: song),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Albums tab
// ─────────────────────────────────────────────────────────────────────────────
class _AlbumsTab extends StatelessWidget {
  final void Function(BuildContext, LocalSong, List<LocalSong>) onPlay;
  const _AlbumsTab({required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<LocalMusicService>();
    final albums = svc.albums;

    if (albums.isEmpty) {
      return const _EmptyState(
          icon: Icons.album_outlined, title: 'No albums', subtitle: '');
    }

    final keys = albums.keys.toList()..sort();
    return GridView.builder(
      padding: const EdgeInsets.all(16).copyWith(bottom: 120),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.85,
      ),
      itemCount: keys.length,
      itemBuilder: (ctx, i) {
        final name = keys[i];
        final songs = albums[name]!;
        return GestureDetector(
          onTap: () => onPlay(ctx, songs.first, songs),
          child: _AlbumCard(name: name, songs: songs),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artists tab
// ─────────────────────────────────────────────────────────────────────────────
class _ArtistsTab extends StatelessWidget {
  final void Function(BuildContext, LocalSong, List<LocalSong>) onPlay;
  const _ArtistsTab({required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<LocalMusicService>();
    final artists = svc.artists;

    if (artists.isEmpty) {
      return const _EmptyState(
          icon: Icons.person_outline, title: 'No artists', subtitle: '');
    }

    final keys = artists.keys.toList()..sort();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 120),
      itemCount: keys.length,
      itemBuilder: (ctx, i) {
        final name = keys[i];
        final songs = artists[name]!;
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: TaarColors.marigold.withOpacity(0.18),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                  color: TaarColors.marigold, fontWeight: FontWeight.bold),
            ),
          ),
          title: Text(name,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          subtitle: Text('${songs.length} song${songs.length == 1 ? '' : 's'}',
              style:
                  const TextStyle(color: TaarColors.creamDim, fontSize: 12)),
          onTap: () => _showArtistSongs(ctx, name, songs),
        );
      },
    );
  }

  void _showArtistSongs(
      BuildContext ctx, String artist, List<LocalSong> songs) {
    Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => _ArtistSongsScreen(
        artist: artist,
        songs: songs,
        onPlay: onPlay,
      ),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artist songs sub-screen
// ─────────────────────────────────────────────────────────────────────────────
class _ArtistSongsScreen extends StatelessWidget {
  final String artist;
  final List<LocalSong> songs;
  final void Function(BuildContext, LocalSong, List<LocalSong>) onPlay;

  const _ArtistSongsScreen(
      {required this.artist, required this.songs, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TaarColors.ink,
      appBar: AppBar(
        backgroundColor: TaarColors.ink,
        title: Text(artist,
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          _PlayAllBar(
            count: songs.length,
            onPlayAll: () => onPlay(context, songs.first, songs),
            onShuffle: () {
              final s = List.of(songs)..shuffle();
              onPlay(context, s.first, s);
            },
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 100),
              itemCount: songs.length,
              itemBuilder: (ctx, i) {
                final s = songs[i];
                return _LocalSongTile(
                  song: s,
                  onTap: () => onPlay(ctx, s, songs),
                  onFav: () =>
                      ctx.read<LocalMusicService>().toggleFavourite(s.id),
                  onRemove: null,
                  onAddToPlaylist: null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Playlists tab
// ─────────────────────────────────────────────────────────────────────────────
class _PlaylistsTab extends StatelessWidget {
  final void Function(BuildContext, LocalSong, List<LocalSong>) onPlay;
  const _PlaylistsTab({required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<LocalMusicService>();
    final playlists = svc.playlists;

    return Column(
      children: [
        // Create playlist button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add, color: TaarColors.marigold, size: 18),
            label: const Text('New Playlist',
                style: TextStyle(color: TaarColors.marigold)),
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: TaarColors.marigold),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20))),
            onPressed: () => _createPlaylist(context, svc),
          ),
        ),

        if (playlists.isEmpty)
          const Expanded(
            child: _EmptyState(
                icon: Icons.playlist_add,
                title: 'No playlists',
                subtitle: 'Create a playlist to organise your music'),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 120),
              itemCount: playlists.length,
              itemBuilder: (ctx, i) {
                final pl = playlists[i];
                final songs = svc.songsForPlaylist(pl.id);
                return ListTile(
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                        color: TaarColors.ink3,
                        borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.queue_music_rounded,
                        color: TaarColors.marigold),
                  ),
                  title: Text(pl.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      '${songs.length} song${songs.length == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: TaarColors.creamDim, fontSize: 12)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: TaarColors.creamDim),
                    onPressed: () => svc.deletePlaylist(pl.id),
                  ),
                  onTap: songs.isEmpty
                      ? null
                      : () => onPlay(ctx, songs.first, songs),
                );
              },
            ),
          ),
      ],
    );
  }

  void _createPlaylist(BuildContext ctx, LocalMusicService svc) {
    final ctrl = TextEditingController();
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: TaarColors.ink2,
        title: const Text('New Playlist',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: TaarColors.creamDim),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: TaarColors.creamDim))),
          TextButton(
              onPressed: () {
                final name = ctrl.text.trim();
                if (name.isNotEmpty) svc.createPlaylist(name);
                Navigator.pop(ctx);
              },
              child: const Text('Create',
                  style: TextStyle(color: TaarColors.marigold))),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared widgets
// ─────────────────────────────────────────────────────────────────────────────

/// A single local song row.
class _LocalSongTile extends StatelessWidget {
  final LocalSong song;
  final VoidCallback onTap;
  final VoidCallback onFav;
  final VoidCallback? onRemove;
  final VoidCallback? onAddToPlaylist;

  const _LocalSongTile({
    required this.song,
    required this.onTap,
    required this.onFav,
    this.onRemove,
    this.onAddToPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    final dur = song.durationSec > 0 ? _fmtDur(song.durationSec) : '';
    final ext = song.path.split('.').last.toUpperCase();

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: TaarColors.ink3,
          borderRadius: BorderRadius.circular(8),
        ),
        child: song.artPath != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(song.artPath!), fit: BoxFit.cover),
              )
            : const Icon(Icons.music_note, color: TaarColors.marigold, size: 22),
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        '${song.artist}${dur.isNotEmpty ? ' • $dur' : ''} • $ext',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: TaarColors.creamDim, fontSize: 11.5),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onFav,
            child: Icon(
              song.isFavourite ? Icons.favorite : Icons.favorite_border,
              color:
                  song.isFavourite ? TaarColors.vermilion : TaarColors.creamDim,
              size: 20,
            ),
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert,
                color: TaarColors.creamDim, size: 20),
            color: TaarColors.ink2,
            onSelected: (v) {
              if (v == 'remove') onRemove?.call();
              if (v == 'playlist') onAddToPlaylist?.call();
            },
            itemBuilder: (_) => [
              if (onAddToPlaylist != null)
                const PopupMenuItem(
                    value: 'playlist',
                    child: ListTile(
                        dense: true,
                        leading: Icon(Icons.playlist_add, size: 18),
                        title: Text('Add to Playlist'))),
              if (onRemove != null)
                const PopupMenuItem(
                    value: 'remove',
                    child: ListTile(
                        dense: true,
                        leading: Icon(Icons.remove_circle_outline,
                            size: 18, color: Colors.redAccent),
                        title: Text('Remove from Library',
                            style:
                                TextStyle(color: Colors.redAccent)))),
            ],
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  String _fmtDur(int sec) {
    final m = (sec ~/ 60).toString();
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Play-all bar shown at top of songs / artist screens.
class _PlayAllBar extends StatelessWidget {
  final int count;
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;

  const _PlayAllBar(
      {required this.count,
      required this.onPlayAll,
      required this.onShuffle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Text('$count song${count == 1 ? '' : 's'}',
              style: const TextStyle(
                  color: TaarColors.creamDim, fontSize: 12.5)),
          const Spacer(),
          // Play all
          _pill(Icons.play_arrow_rounded, 'Play All', onPlayAll),
          const SizedBox(width: 8),
          // Shuffle
          _pill(Icons.shuffle_rounded, 'Shuffle', onShuffle),
        ],
      ),
    );
  }

  Widget _pill(IconData icon, String label, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: TaarColors.marigold.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: TaarColors.marigold.withOpacity(0.5), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: TaarColors.marigold, size: 16),
              const SizedBox(width: 4),
              Text(label,
                  style: const TextStyle(
                      color: TaarColors.marigold,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
}

/// Album art grid card.
class _AlbumCard extends StatelessWidget {
  final String name;
  final List<LocalSong> songs;
  const _AlbumCard({required this.name, required this.songs});

  @override
  Widget build(BuildContext context) {
    final art = songs.firstWhere((s) => s.artPath != null,
        orElse: () => songs.first);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: art.artPath != null
                ? Image.file(File(art.artPath!), fit: BoxFit.cover,
                    width: double.infinity)
                : Container(
                    color: TaarColors.ink3,
                    child: const Center(
                      child: Icon(Icons.album, color: TaarColors.marigold,
                          size: 40),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Text(name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13)),
        Text('${songs.length} track${songs.length == 1 ? '' : 's'}',
            style: const TextStyle(
                color: TaarColors.creamDim, fontSize: 11)),
      ],
    );
  }
}

/// Add-to-playlist bottom sheet.
class _AddToPlaylistSheet extends StatelessWidget {
  final LocalMusicService svc;
  final LocalSong song;
  const _AddToPlaylistSheet({required this.svc, required this.song});

  @override
  Widget build(BuildContext context) {
    final playlists = svc.playlists;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2))),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Add to Playlist',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 8),
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No playlists. Create one first.',
                  style: TextStyle(color: TaarColors.creamDim)),
            )
          else
            ...playlists.map((pl) => ListTile(
                  leading: const Icon(Icons.queue_music_rounded,
                      color: TaarColors.marigold),
                  title: Text(pl.name,
                      style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    svc.addToPlaylist(pl.id, song);
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            'Added "${song.title}" to ${pl.name}')));
                  },
                )),
        ],
      ),
    );
  }
}

/// Empty state placeholder.
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyState(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: TaarColors.creamDim),
            const SizedBox(height: 16),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: TaarColors.creamDim, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}