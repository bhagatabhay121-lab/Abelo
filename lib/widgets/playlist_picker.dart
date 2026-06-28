import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Shows a bottom sheet (or create-dialog if no playlists exist) that lets
/// the user pick a playlist to add [song] to.
/// Extracted here to avoid circular imports between song_tile ↔ library_screen.
void showAddToPlaylistSheet(BuildContext context, Song song) {
  final app = context.read<AppState>();

  if (app.playlists.isEmpty) {
    _showCreateAndAdd(context, app, song);
    return;
  }

  showModalBottomSheet(
    context: context,
    backgroundColor: TaarColors.ink2,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header row
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                const Text('Add to Playlist',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _showCreateAndAdd(context, app, song);
                  },
                  icon: const Icon(Icons.add, size: 18, color: TaarColors.marigold),
                  label: const Text('New',
                      style: TextStyle(
                          color: TaarColors.marigold, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: TaarColors.line),
          // Playlist list
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: Consumer<AppState>(
              builder: (_, app2, __) => ListView.builder(
                shrinkWrap: true,
                itemCount: app2.playlists.length,
                itemBuilder: (_, i) {
                  final pl = app2.playlists[i];
                  final already = app2.isSongInPlaylist(pl.id, song.id);
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: _PlaylistArtSmall(songs: pl.songs),
                    ),
                    title: Text(pl.name,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                    subtitle: Text('${pl.songs.length} songs',
                        style: const TextStyle(
                            color: TaarColors.creamDim, fontSize: 12)),
                    trailing: already
                        ? const Icon(Icons.check_circle,
                            color: TaarColors.marigold, size: 22)
                        : const Icon(Icons.add_circle_outline,
                            color: Colors.white, size: 22),
                    onTap: already
                        ? null
                        : () {
                            app2.addSongToPlaylist(pl.id, song);
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Added to ${pl.name}'),
                                  behavior: SnackBarBehavior.floating));
                          },
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

void _showCreateAndAdd(BuildContext context, AppState app, Song song) {
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
          child: Text('Cancel',
              style: TextStyle(color: Colors.white.withOpacity(0.5))),
        ),
        TextButton(
          onPressed: () {
            if (ctrl.text.trim().isNotEmpty) {
              final pl = app.createPlaylist(ctrl.text);
              app.addSongToPlaylist(pl.id, song);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Added to ${pl.name}'),
                  behavior: SnackBarBehavior.floating));
            }
          },
          child: const Text('Create & Add',
              style: TextStyle(
                  color: TaarColors.marigold, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
}

class _PlaylistArtSmall extends StatelessWidget {
  final List<Song> songs;
  const _PlaylistArtSmall({required this.songs});

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) {
      return Container(
        width: 40,
        height: 40,
        color: TaarColors.ink3,
        child: const Icon(Icons.music_note, color: TaarColors.creamDim, size: 18),
      );
    }
    return CachedNetworkImage(
      imageUrl: songs.first.image,
      width: 40,
      height: 40,
      fit: BoxFit.cover,
      errorWidget: (_, __, ___) => Container(
        width: 40,
        height: 40,
        color: TaarColors.ink3,
        child: const Icon(Icons.music_note, color: TaarColors.creamDim),
      ),
    );
  }
}
