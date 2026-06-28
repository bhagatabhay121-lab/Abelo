import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../widgets/mini_player.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'library_screen.dart';
import 'youtube_screen.dart';

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  final _screens = const [
    HomeScreen(),
    SearchScreen(),
    YouTubeScreen(),
    LibraryScreen(),
  ];

  static const _tabs = [
    (icon: Icons.home_outlined,          activeIcon: Icons.home,             label: 'Home'),
    (icon: Icons.search,                 activeIcon: Icons.search,           label: 'Search'),
    (icon: Icons.play_circle_outline,    activeIcon: Icons.play_circle_fill, label: 'YouTube'),
    (icon: Icons.library_music_outlined, activeIcon: Icons.library_music,    label: 'Library'),
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // canPop: false so we always intercept the back gesture first.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_index != 0) {
          // Not on Home → navigate to Home instead of closing
          setState(() => _index = 0);
        } else {
          // Already on Home → close the app
          SystemNavigator.pop(animated: true);
        }
      },
      child: Scaffold(
        extendBody: true, // lets content go behind the glass nav bar
        body: IndexedStack(index: _index, children: _screens),
        bottomNavigationBar: _GlassBottomBar(
          index: _index,
          tabs: _tabs,
          onTap: (i) => setState(() => _index = i),
        ),
      ),
    );
  }
}

class _GlassBottomBar extends StatelessWidget {
  final int index;
  final List<({IconData icon, IconData activeIcon, String label})> tabs;
  final ValueChanged<int> onTap;

  const _GlassBottomBar({
    required this.index,
    required this.tabs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.55),
                Colors.black.withOpacity(0.80),
              ],
            ),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.08), width: 0.6),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 8, 10, 4),
                  child: MiniPlayer(),
                ),
                SizedBox(
                  height: 60,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(tabs.length, (i) {
                      final tab = tabs[i];
                      final active = i == index;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onTap(i),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          padding: EdgeInsets.symmetric(
                              horizontal: active ? 18 : 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: active
                                ? TaarColors.marigold.withOpacity(0.18)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(24),
                            border: active
                                ? Border.all(
                                    color:
                                        TaarColors.marigold.withOpacity(0.30),
                                    width: 0.8)
                                : null,
                          ),
                          child: Row(
                            children: [
                              Icon(active ? tab.activeIcon : tab.icon,
                                  color: active
                                      ? TaarColors.marigold
                                      : Colors.white.withOpacity(0.55),
                                  size: 22),
                              if (active) ...[
                                const SizedBox(width: 7),
                                Text(tab.label,
                                    style: const TextStyle(
                                        color: TaarColors.marigold,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13)),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}