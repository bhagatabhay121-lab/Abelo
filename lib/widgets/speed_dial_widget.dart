import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/speed_dial_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../app_assets.dart';
import '../screens/now_playing_screen.dart';

/// "Most Played" — 3-column grid of up to 18 top songs, personalized from
/// listening history (plays, completion, likes), paged in groups of 9
/// (3 rows × 3 cols) with dot indicators.
///
/// Drop this anywhere in a ListView:
///   SpeedDialWidget()
class SpeedDialWidget extends StatefulWidget {
  const SpeedDialWidget({super.key});

  @override
  State<SpeedDialWidget> createState() => _SpeedDialWidgetState();
}

class _SpeedDialWidgetState extends State<SpeedDialWidget> {
  final PageController _pageCtrl = PageController();
  int _currentPage = 0;

  static const _perPage = 9; // 3 cols × 3 rows

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final songs = context.watch<SpeedDialService>().dialSongs;

    if (songs.isEmpty) return const SizedBox.shrink();

    // Split into pages of 9
    final pages = <List<Song>>[];
    for (int i = 0; i < songs.length; i += _perPage) {
      pages.add(songs.sublist(
          i, (i + _perPage) > songs.length ? songs.length : (i + _perPage)));
    }

    // Each card: roughly square. We compute width from screen width minus
    // padding (16 left + 16 right) and gap (8px × 2 between 3 cols).
    final screenW = MediaQuery.of(context).size.width;
    final cardW = (screenW - 32 - 16) / 3; // 32 = H padding, 16 = 2 gaps
    final cardH = cardW; // square

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Section header ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              // User avatar circle
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: TaarColors.marigold.withOpacity(0.2),
                  shape: BoxShape.circle,
                  border: Border.all(color: TaarColors.marigold, width: 1.5),
                ),
                child: const Icon(Icons.person,
                    size: 18, color: TaarColors.marigold),
              ),
              const SizedBox(width: 10),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Built from your listening',
                    style: TextStyle(
                        fontSize: 11,
                        color: TaarColors.creamDim,
                        fontWeight: FontWeight.w500),
                  ),
                  Text(
                    'Most Played',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Colors.white),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── Paged grid ──────────────────────────────────────────────────────
        SizedBox(
          height: cardH * 3 + 8 * 2, // 3 rows + 2 row gaps
          child: PageView.builder(
            controller: _pageCtrl,
            itemCount: pages.length,
            onPageChanged: (p) => setState(() => _currentPage = p),
            itemBuilder: (context, pageIndex) {
              final pageSongs = pages[pageIndex];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                  ),
                  itemCount: pageSongs.length,
                  itemBuilder: (context, i) =>
                      _SongCard(song: pageSongs[i]),
                ),
              );
            },
          ),
        ),

        // ── Dot indicators (only if >1 page) ────────────────────────────────
        if (pages.length > 1) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(pages.length, (i) {
              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _currentPage ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: i == _currentPage
                      ? Colors.white
                      : Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
          ),
        ],

        const SizedBox(height: 8),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Individual card
// ─────────────────────────────────────────────────────────────────────────────
class _SongCard extends StatelessWidget {
  final Song song;

  const _SongCard({required this.song});

  /// Plays just the tapped song (by its id), then fetches recommendations
  /// for it and splices them into the queue — same approach as the "Last
  /// Session" tiles on the home screen. Done as an explicit fetch (not via
  /// the auto-prefetch path) because that path is gated behind the
  /// autoplay setting and silently skips fetching when it's off.
  Future<void> _play(BuildContext context) async {
    final app = context.read<AppState>();
    app.setQueueAndPlay([song], 0);
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => const NowPlayingScreen(),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero)
              .animate(anim),
          child: child,
        ),
      ),
    );
    try {
      // Seed recos from the tapped song itself, so recos match what you
      // just clicked on rather than your overall taste/mood history.
      final seedId = song.id;
      final recos = await app.api.fetchReco(seedId);
      if (recos.isNotEmpty) {
        app.setQueueAndPlay([song, ...recos], 0);
      }
    } catch (_) {
      // If reco fetch fails, the single song keeps playing — no crash.
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _play(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Album art
            CachedNetworkImage(
              imageUrl: song.image,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Image.asset(
                  AppAssets.placeholderSong,
                  fit: BoxFit.cover),
            ),

            // Gradient overlay for label legibility
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.78),
                    ],
                    stops: const [0.45, 1.0],
                  ),
                ),
              ),
            ),

            // Song title at bottom
            Positioned(
              left: 5,
              right: 5,
              bottom: 5,
              child: Text(
                song.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  height: 1.25,
                ),
              ),
            ),

            // Small play icon in top-left (mirrors YT Music badge)
            Positioned(
              top: 5,
              left: 5,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow,
                    size: 13, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}