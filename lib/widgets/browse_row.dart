import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../app_assets.dart';
import '../models/song.dart';
import '../theme.dart';

/// Mirrors the horizontal card carousels on the home/search screens
/// ("Celebrating Father's Day", "Trending community playlists", etc. in
/// the reference) — square art with a small translucent play badge in
/// the corner, bold white title, grey subtitle underneath.
class BrowseRow extends StatelessWidget {
  final String title;
  final List<BrowseItem> items;
  final void Function(BrowseItem) onTap;
  final bool circular; // true for artists

  const BrowseRow({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.circular = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Text(title, style: TaarTheme.sectionHeader(context, size: 17)),
        ),
        SizedBox(
          height: circular ? 198 : 202,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              final placeholder = item.type == 'artist'
                  ? AppAssets.placeholderArtist
                  : item.type == 'album'
                      ? AppAssets.placeholderAlbum
                      : AppAssets.placeholderSong;
              return GestureDetector(
                onTap: () => onTap(item),
                child: Container(
                  width: 160,
                  margin: const EdgeInsets.only(right: 14),
                  child: Column(
                    crossAxisAlignment: circular ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                    children: [
                      Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(circular ? 80 : 14),
                            child: CachedNetworkImage(
                              imageUrl: item.image,
                              width: 160,
                              height: 160,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) =>
                                  Image.asset(placeholder, width: 160, height: 160, fit: BoxFit.cover),
                            ),
                          ),
                          if (!circular)
                            Positioned(
                              left: 8,
                              top: 8,
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.45),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.play_arrow, size: 14, color: Colors.white),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.white),
                      ),
                      if (item.subtitle.isNotEmpty)
                        Text(
                          item.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: TaarColors.creamDim),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
