import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../app_assets.dart';
import '../models/song.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../screens/now_playing_screen.dart';
import 'playlist_picker.dart';
import 'glass_widget.dart';

/// Horizontal song row used in queues, search results, album/playlist
/// tracklists and the library — mirrors .song-row / songCardHTML rows.
/// Trailing action is a "⋮" overflow (matching the reference's song
/// rows) rather than an inline heart — liked state is shown as a small
/// pink heart glyph next to the overflow button when applicable.
class SongTile extends StatelessWidget {
  final Song song;
  final int index;
  final List<Song> contextQueue;
  final VoidCallback? onTap;
  final bool dense;

  const SongTile({
    super.key,
    required this.song,
    required this.index,
    required this.contextQueue,
    this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final isCurrent = app.currentSong?.id == song.id;
    final liked = app.isLiked(song.id);

    return InkWell(
      onTap: onTap ?? () {
        context.read<AppState>().setQueueAndPlay(contextQueue, index);
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
      },
      onLongPress: () => showSongActionSheet(context, song),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 6 : 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: song.image,
                width: dense ? 42 : 52,
                height: dense ? 42 : 52,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Image.asset(
                  AppAssets.placeholderSong,
                  width: dense ? 42 : 52,
                  height: dense ? 42 : 52,
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
                      fontWeight: FontWeight.w600,
                      fontSize: 14.5,
                      color: isCurrent ? TaarColors.marigold : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: TaarColors.creamDim),
                  ),
                ],
              ),
            ),
            if (liked) const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.favorite, size: 16, color: TaarColors.vermilion),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, size: 20, color: TaarColors.creamDim),
              onPressed: () => showSongActionSheet(context, song),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet of song actions — mirrors the reference's "Play Next /
/// Add to Queue / Add to Playlist / Share" context menu (the Joytify
/// "Watch Video"/"Add to Playlist" entries are omitted since Taar has no
/// video or custom-playlist feature; Share is wired to share_plus).
void showSongActionSheet(BuildContext context, Song song) {
  final app = context.read<AppState>();
  showGlassMenuDialog(
    context: context,
    title: song.title,
    header: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: song.image,
            width: 44, height: 44, fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Image.asset(
                AppAssets.placeholderSong, width: 44, height: 44, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white, fontSize: 14)),
              Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.55))),
            ],
          ),
        ),
      ],
    ),
    items: [
      ListTile(
        leading: const Icon(Icons.playlist_play, color: Colors.white),
        title: const Text('Play Next', style: TextStyle(color: Colors.white)),
        onTap: () { app.playNext(song); Navigator.pop(context); },
      ),
      ListTile(
        leading: const Icon(Icons.queue_music, color: Colors.white),
        title: const Text('Add to Queue', style: TextStyle(color: Colors.white)),
        onTap: () { app.addToQueueEnd(song); Navigator.pop(context); },
      ),
      ListTile(
        leading: const Icon(Icons.playlist_add, color: Colors.white),
        title: const Text('Add to Playlist', style: TextStyle(color: Colors.white)),
        onTap: () {
          Navigator.pop(context);
          showAddToPlaylistSheet(context, song);
        },
      ),
      ListTile(
        leading: Icon(app.isLiked(song.id) ? Icons.favorite : Icons.favorite_border,
            color: app.isLiked(song.id) ? TaarColors.vermilion : Colors.white),
        title: Text(app.isLiked(song.id) ? 'Remove from Liked Songs' : 'Add to Liked Songs',
            style: const TextStyle(color: Colors.white)),
        onTap: () { app.toggleLike(song); Navigator.pop(context); },
      ),
      ListTile(
        leading: const Icon(Icons.share_outlined, color: Colors.white),
        title: const Text('Share', style: TextStyle(color: Colors.white)),
        onTap: () {
          Navigator.pop(context);
          Share.share('${song.title} — ${song.artist}');
        },
      ),
    ],
  );
}

