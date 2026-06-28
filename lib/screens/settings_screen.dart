import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_assets.dart';
import '../state/app_state.dart';
import '../theme.dart';

// ─────────────────────────────────────────────────────────────────
//  Entry point
// ─────────────────────────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  // All searchable items: (display text, route builder)
  static const _allItems = [
    // Theme
    'Dark Mode', 'Use System Theme', 'Accent Color & Hue',
    'Background Gradient', 'Card Gradient', 'Bottom Sheets Gradient',
    'Canvas Color', 'Card Color', 'Use Amoled Dark Mode Settings', 'Current Theme',
    // App UI
    'Player Screen Background', 'Use Dense Miniplayer', 'Buttons to show in Mini Player',
    'Compact Notification Buttons', 'Blacklisted Home Sections',
    'Show Playlists on Home Screen', 'Show Last Session',
    'Navigation Bar Tabs', 'Enable Artwork Gestures',
    'Enable Volume Gesture Controls', 'Use Less Data for Images',
    // Music & Playback
    'Music Language', 'Spotify Local Charts Location', 'Streaming Quality',
    'Streaming Quality (Wifi)', 'YouTube Streaming Quality',
    'Load Last Session on App Start', 'Replay on Skip Previous',
    'Enforce Repeating', 'Autoplay', 'Cache Songs',
    // Others
    'Language', 'API Root', 'Your Name',
    // Backup
    'Create Backup', 'Restore', 'Auto Backup',
    // About
    'Version', 'Share App', 'Contact Us',
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? <String>[]
        : _allItems
            .where((s) => s.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: const Text('Settings',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
      ),
      body: Column(
        children: [
          // ── Search bar ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                  prefixIcon: Icon(Icons.search, color: Colors.white.withOpacity(0.4)),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),

          // ── Content ─────────────────────────────────────────────
          Expanded(
            child: _query.isEmpty
                ? _buildMainList(context)
                : _buildSearchResults(context, filtered),
          ),
        ],
      ),
    );
  }

  Widget _buildMainList(BuildContext context) {
    final cats = [
      _CategoryItem(
        icon: Icons.auto_fix_high,
        title: 'Theme',
        subtitle: 'Dark Mode, Accent Color & Hue, Use System Theme',
        onTap: () => _push(context, const _ThemeSubScreen()),
      ),
      _CategoryItem(
        icon: Icons.design_services,
        title: 'App UI',
        subtitle: 'Player Screen Background, Buttons to show in Mini Player, Use Dense Miniplayer',
        onTap: () => _push(context, const _AppUISubScreen()),
      ),
      _CategoryItem(
        icon: Icons.music_note,
        title: 'Music & Playback',
        subtitle: 'Music Language, Streaming Quality, Spotify Local Charts Location',
        onTap: () => _push(context, const _MusicPlaybackSubScreen()),
      ),
      _CategoryItem(
        icon: Icons.settings,
        title: 'Others',
        subtitle: 'Language, Include/Exclude Folders, Min Audio Length to search music',
        onTap: () => _push(context, const _OthersSubScreen()),
      ),
      _CategoryItem(
        icon: Icons.history,
        title: 'Backup & Restore',
        subtitle: 'Create Backup, Restore, Auto Backup',
        onTap: () => _push(context, const _BackupSubScreen()),
      ),
      _CategoryItem(
        icon: Icons.info_outline,
        title: 'About',
        subtitle: 'Version, Share App, Contact Us',
        onTap: () => _push(context, const _AboutSubScreen()),
      ),
    ];

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: cats.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) => _buildCategoryTile(cats[i]),
    );
  }

  Widget _buildCategoryTile(_CategoryItem item) {
    return InkWell(
      onTap: item.onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(item.icon, color: Colors.white, size: 26),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 3),
                  Text(item.subtitle,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.45),
                          fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults(BuildContext context, List<String> items) {
    if (items.isEmpty) {
      return Center(
        child: Text('No results for "$_query"',
            style: TextStyle(color: Colors.white.withOpacity(0.4))),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: items.length,
      itemBuilder: (_, i) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(items[i], style: const TextStyle(color: Colors.white)),
        leading: const Icon(Icons.settings, color: Colors.white54, size: 20),
      ),
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen),
    );
  }
}

class _CategoryItem {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _CategoryItem(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap});
}

// ─────────────────────────────────────────────────────────────────
//  Shared helpers
// ─────────────────────────────────────────────────────────────────
class _SubScreen extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SubScreen({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 20)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: children,
      ),
    );
  }
}

// Simple row: title + subtitle on left, widget on right
Widget _settingRow({
  required String title,
  String? subtitle,
  Widget? trailing,
  VoidCallback? onTap,
}) {
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.45),
                          fontSize: 12.5)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing,
          ],
        ],
      ),
    ),
  );
}

Widget _divider() => Divider(
      height: 1,
      thickness: 0.4,
      color: Colors.white.withOpacity(0.1),
    );

// Pink toggle matching the reference
Widget _pinkSwitch(bool value, ValueChanged<bool> onChanged) {
  return Switch(
    value: value,
    onChanged: onChanged,
    activeColor: Colors.white,
    activeTrackColor: TaarColors.marigold,
    inactiveThumbColor: Colors.white,
    inactiveTrackColor: const Color(0xFF3A3A3A),
    trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
  );
}

// Dropdown matching the reference style
Widget _dropdownValue<T>({
  required T value,
  required List<T> items,
  required ValueChanged<T?> onChanged,
  required String Function(T) label,
}) {
  return DropdownButton<T>(
    value: value,
    icon: const Icon(Icons.arrow_drop_down, color: Colors.white60),
    underline: const SizedBox(),
    dropdownColor: const Color(0xFF1E1E1E),
    style: const TextStyle(color: Colors.white, fontSize: 14),
    items: items.map((i) => DropdownMenuItem(value: i, child: Text(label(i)))).toList(),
    onChanged: onChanged,
  );
}

// ─────────────────────────────────────────────────────────────────
//  Theme sub-screen
// ─────────────────────────────────────────────────────────────────
class _ThemeSubScreen extends StatefulWidget {
  const _ThemeSubScreen();
  @override
  State<_ThemeSubScreen> createState() => _ThemeSubScreenState();
}

class _ThemeSubScreenState extends State<_ThemeSubScreen> {
  // Local extra toggles (stored in prefs via AppState in a real app;
  // here we keep them in widget state to match the UI faithfully)
  bool _bgGradient = false;
  bool _cardGradient = false;
  bool _bottomSheetGradient = false;
  String _canvasColor = 'Grey';
  String _cardColor = 'Grey900';
  String _currentTheme = 'Default';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final isDark = app.themeMode == 'dark';
    final useSystem = false; // placeholder — extend AppState to support

    return _SubScreen(
      title: 'Theme',
      children: [
        _settingRow(
          title: 'Dark Mode',
          trailing: _pinkSwitch(isDark, (v) => app.updateSettings(themeMode: v ? 'dark' : 'light')),
        ),
        _divider(),
        _settingRow(
          title: 'Use System Theme',
          trailing: _pinkSwitch(useSystem, (_) {}),
        ),
        _divider(),
        _settingRow(
          title: 'Accent Color & Hue',
          subtitle: 'Pink, 700',
          trailing: Container(
            width: 28,
            height: 28,
            decoration: const BoxDecoration(
              color: TaarColors.marigold,
              shape: BoxShape.circle,
            ),
          ),
          onTap: () {},
        ),
        _divider(),
        _settingRow(
          title: 'Background Gradient',
          subtitle: 'Gradient used as background everywhere',
          trailing: _pinkSwitch(_bgGradient, (v) => setState(() => _bgGradient = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Card Gradient',
          subtitle: 'Gradient used in Cards',
          trailing: _pinkSwitch(_cardGradient, (v) => setState(() => _cardGradient = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Bottom Sheets Gradient',
          subtitle: 'Gradient used in Bottom Sheets',
          trailing: _pinkSwitch(_bottomSheetGradient, (v) => setState(() => _bottomSheetGradient = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Canvas Color',
          subtitle: 'Color of Background Canvas',
          trailing: _dropdownValue<String>(
            value: _canvasColor,
            items: const ['Grey', 'Black', 'White'],
            label: (s) => s,
            onChanged: (v) => setState(() => _canvasColor = v!),
          ),
        ),
        _divider(),
        _settingRow(
          title: 'Card Color',
          subtitle: 'Color of Search Bar, Alert Dialogs, Cards',
          trailing: _dropdownValue<String>(
            value: _cardColor,
            items: const ['Grey900', 'Grey800', 'Black'],
            label: (s) => s,
            onChanged: (v) => setState(() => _cardColor = v!),
          ),
        ),
        _divider(),
        _settingRow(
          title: 'Use Amoled Dark Mode Settings',
          onTap: () {},
        ),
        _divider(),
        _settingRow(
          title: 'Current Theme',
          trailing: _dropdownValue<String>(
            value: _currentTheme,
            items: const ['Default', 'Pink', 'Purple', 'Blue'],
            label: (s) => s,
            onChanged: (v) => setState(() => _currentTheme = v!),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  App UI sub-screen
// ─────────────────────────────────────────────────────────────────
class _AppUISubScreen extends StatefulWidget {
  const _AppUISubScreen();
  @override
  State<_AppUISubScreen> createState() => _AppUISubScreenState();
}

class _AppUISubScreenState extends State<_AppUISubScreen> {
  bool _denseMiniPlayer = false;
  bool _showPlaylists = true;
  bool _showLastSession = true;
  bool _artworkGestures = true;
  bool _volumeGestures = false;
  bool _lessData = false;

  @override
  Widget build(BuildContext context) {
    return _SubScreen(
      title: 'App UI',
      children: [
        _settingRow(
          title: 'Player Screen Background',
          subtitle: 'Selected Background will be shown in Player Screen',
          onTap: () {},
        ),
        _divider(),
        _settingRow(
          title: 'Use Dense Miniplayer',
          subtitle: 'Miniplayer height will be reduced (You need to restart app)',
          trailing: _pinkSwitch(_denseMiniPlayer, (v) => setState(() => _denseMiniPlayer = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Buttons to show in Mini Player',
          subtitle: 'Tap to change buttons shown in the Mini Player',
          onTap: () {},
        ),
        _divider(),
        _settingRow(
          title: 'Compact Notification Buttons',
          subtitle: 'Buttons to show in Compact Notification View',
          onTap: () {},
        ),
        _divider(),
        _settingRow(
          title: 'Blacklisted Home Sections',
          subtitle: "Sections with these titles won't be shown on Home Screen",
          onTap: () {},
        ),
        _divider(),
        _settingRow(
          title: 'Show Playlists on Home Screen',
          trailing: _pinkSwitch(_showPlaylists, (v) => setState(() => _showPlaylists = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Show Last Session',
          subtitle: 'Show Last session on Home Screen',
          trailing: _pinkSwitch(_showLastSession, (v) => setState(() => _showLastSession = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Navigation Bar Tabs',
          subtitle: 'Tabs to be shown in bottom navigation bar',
          onTap: () {},
        ),
        _divider(),
        _settingRow(
          title: 'Enable Artwork Gestures',
          subtitle: 'Enables tap, longpress, swipe, etc on the Artwork in Player Screen',
          trailing: _pinkSwitch(_artworkGestures, (v) => setState(() => _artworkGestures = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Enable Volume Gesture Controls',
          subtitle: 'Use vertical swipe on the Artwork in Player Screen to control volume instead of sliding player down',
          trailing: _pinkSwitch(_volumeGestures, (v) => setState(() => _volumeGestures = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Use Less Data for Images',
          subtitle: 'This will reduce the quality of images in the app, but will save your data',
          trailing: _pinkSwitch(_lessData, (v) => setState(() => _lessData = v)),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  Music & Playback sub-screen
// ─────────────────────────────────────────────────────────────────
class _MusicPlaybackSubScreen extends StatefulWidget {
  const _MusicPlaybackSubScreen();
  @override
  State<_MusicPlaybackSubScreen> createState() => _MusicPlaybackSubScreenState();
}

class _MusicPlaybackSubScreenState extends State<_MusicPlaybackSubScreen> {
  bool _loadLastSession = true;
  bool _replayOnSkip = false;
  bool _enforceRepeat = false;
  bool _cacheSongs = false;
  String _wifiQuality = '320kbps';
  String _ytQuality = 'Low';
  String _language = 'English';
  String _chartsLocation = 'USA';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return _SubScreen(
      title: 'Music & Playback',
      children: [
        _settingRow(
          title: 'Music Language',
          subtitle: 'To display songs on Home Screen',
          trailing: InkWell(
            onTap: () => _pickLanguage(context, app),
            child: Text(_language,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
          onTap: () => _pickLanguage(context, app),
        ),
        _divider(),
        _settingRow(
          title: 'Spotify Local Charts Location',
          subtitle: 'Country for Top Spotify Local Charts',
          trailing: Text(_chartsLocation,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
          onTap: () {},
        ),
        _divider(),
        _settingRow(
          title: 'Streaming Quality',
          subtitle: 'Higher quality uses more data',
          trailing: _dropdownValue<String>(
            value: app.quality,
            items: const ['12kbps', '48kbps', '96kbps', '160kbps', '320kbps'],
            label: (s) => s,
            onChanged: (v) => app.updateSettings(quality: v),
          ),
        ),
        _divider(),
        _settingRow(
          title: 'Streaming Quality (Wifi)',
          subtitle: 'This will be used whenever Wifi is connected',
          trailing: _dropdownValue<String>(
            value: _wifiQuality,
            items: const ['96kbps', '160kbps', '320kbps'],
            label: (s) => s,
            onChanged: (v) => setState(() => _wifiQuality = v!),
          ),
        ),
        _divider(),
        _settingRow(
          title: 'YouTube Streaming Quality',
          subtitle: 'Higher quality uses more data',
          trailing: _dropdownValue<String>(
            value: _ytQuality,
            items: const ['Low', 'Medium', 'High'],
            label: (s) => s,
            onChanged: (v) => setState(() => _ytQuality = v!),
          ),
        ),
        _divider(),
        _settingRow(
          title: 'Load Last Session on App Start',
          subtitle: 'Automatically load last session when app starts',
          trailing: _pinkSwitch(_loadLastSession, (v) => setState(() => _loadLastSession = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Replay on Skip Previous',
          subtitle: 'Replay from start instead of skipping to previous song',
          trailing: _pinkSwitch(_replayOnSkip, (v) => setState(() => _replayOnSkip = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Enforce Repeating',
          subtitle: 'Keep the same repeat option for every session',
          trailing: _pinkSwitch(_enforceRepeat, (v) => setState(() => _enforceRepeat = v)),
        ),
        _divider(),
        _settingRow(
          title: 'Autoplay',
          subtitle: 'Automatically add related songs to the queue',
          trailing: _pinkSwitch(app.autoplay, (v) => app.updateSettings(autoplay: v)),
        ),
        _divider(),
        _settingRow(
          title: 'Cache Songs',
          subtitle: 'Songs will be cached for future playback. Additional space on your device will be taken',
          trailing: _pinkSwitch(_cacheSongs, (v) => setState(() => _cacheSongs = v)),
        ),
      ],
    );
  }

  void _pickLanguage(BuildContext context, AppState app) {
    final options = ['Hindi', 'English', 'Punjabi', 'Tamil', 'Telugu', 'Bengali', 'Marathi', 'Gujarati'];
    final selected = app.language.split(',').map((e) => e.trim().toLowerCase()).toSet();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text('Music Language',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 17)),
              ),
              ...options.map((lang) {
                final key = lang.toLowerCase();
                return CheckboxListTile(
                  title: Text(lang, style: const TextStyle(color: Colors.white)),
                  value: selected.contains(key),
                  activeColor: TaarColors.marigold,
                  checkColor: Colors.white,
                  onChanged: (v) {
                    setSheetState(() {
                      v! ? selected.add(key) : selected.remove(key);
                    });
                    setState(() => _language =
                        selected.isEmpty ? 'English' : _capitalize(selected.first));
                    app.updateSettings(language: selected.join(','));
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

// ─────────────────────────────────────────────────────────────────
//  Others sub-screen
// ─────────────────────────────────────────────────────────────────
class _OthersSubScreen extends StatefulWidget {
  const _OthersSubScreen();
  @override
  State<_OthersSubScreen> createState() => _OthersSubScreenState();
}

class _OthersSubScreenState extends State<_OthersSubScreen> {
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _nameCtrl = TextEditingController(text: app.username);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return _SubScreen(
      title: 'Others',
      children: [
        // Language picker
        _settingRow(
          title: 'Language',
          subtitle: 'Preferred search languages',
          trailing: const Icon(Icons.chevron_right, color: Colors.white54),
          onTap: () => _pickLanguage(context, app),
        ),
        _divider(),

        // Your Name
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your Name',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              const SizedBox(height: 4),
              Text('Used for the greeting on Home screen.',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.45), fontSize: 12.5)),
              const SizedBox(height: 10),
              TextField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Enter your name',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: TaarColors.marigold,
                      foregroundColor: Colors.white),
                  onPressed: () {
                    app.setUsername(_nameCtrl.text);
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Name saved')));
                  },
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),

        _divider(),
        _settingRow(
          title: 'Include/Exclude Folders',
          subtitle: 'Choose folders to include or exclude from library',
          trailing: const Icon(Icons.chevron_right, color: Colors.white54),
          onTap: () {},
        ),
        _divider(),
        _settingRow(
          title: 'Min Audio Length',
          subtitle: 'Minimum length (seconds) for songs to appear in search',
          trailing: const Icon(Icons.chevron_right, color: Colors.white54),
          onTap: () {},
        ),
      ],
    );
  }

  void _pickLanguage(BuildContext context, AppState app) {
    final options = ['Hindi', 'English', 'Punjabi', 'Tamil', 'Telugu', 'Bengali', 'Marathi', 'Gujarati'];
    final selected = app.language.split(',').map((e) => e.trim().toLowerCase()).toSet();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text('Preferred Languages',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 17)),
              ),
              ...options.map((lang) {
                final key = lang.toLowerCase();
                return CheckboxListTile(
                  title: Text(lang, style: const TextStyle(color: Colors.white)),
                  value: selected.contains(key),
                  activeColor: TaarColors.marigold,
                  checkColor: Colors.white,
                  onChanged: (v) {
                    setSheetState(() {
                      v! ? selected.add(key) : selected.remove(key);
                    });
                    app.updateSettings(language: selected.join(','));
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  Backup & Restore sub-screen
// ─────────────────────────────────────────────────────────────────
class _BackupSubScreen extends StatefulWidget {
  const _BackupSubScreen();
  @override
  State<_BackupSubScreen> createState() => _BackupSubScreenState();
}

class _BackupSubScreenState extends State<_BackupSubScreen> {
  bool _autoBackup = false;

  @override
  Widget build(BuildContext context) {
    return _SubScreen(
      title: 'Backup & Restore',
      children: [
        _settingRow(
          title: 'Create Backup',
          subtitle: 'Export your playlists and liked songs to a file',
          trailing: const Icon(Icons.chevron_right, color: Colors.white54),
          onTap: () => _showSnack(context, 'Backup created'),
        ),
        _divider(),
        _settingRow(
          title: 'Restore',
          subtitle: 'Import playlists and liked songs from a backup file',
          trailing: const Icon(Icons.chevron_right, color: Colors.white54),
          onTap: () => _showSnack(context, 'Restore tapped'),
        ),
        _divider(),
        _settingRow(
          title: 'Auto Backup',
          subtitle: 'Automatically backup your data',
          trailing: _pinkSwitch(_autoBackup, (v) => setState(() => _autoBackup = v)),
        ),
      ],
    );
  }

  void _showSnack(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

// ─────────────────────────────────────────────────────────────────
//  About sub-screen
// ─────────────────────────────────────────────────────────────────
class _AboutSubScreen extends StatelessWidget {
  const _AboutSubScreen();

  @override
  Widget build(BuildContext context) {
    return _SubScreen(
      title: 'About',
      children: [
        _settingRow(
          title: 'Version',
          subtitle: 'Taar v1.0.0',
          trailing: const SizedBox(),
        ),
        _divider(),
        _settingRow(
          title: 'Share App',
          subtitle: 'Share Taar with your friends',
          trailing: const Icon(Icons.share, color: Colors.white54, size: 20),
          onTap: () => ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Share tapped'))),
        ),
        _divider(),
        _settingRow(
          title: 'Contact Us',
          subtitle: 'Reach out for support or feedback',
          trailing: const Icon(Icons.chevron_right, color: Colors.white54),
          onTap: () {},
        ),
        const SizedBox(height: 40),
        Center(
          child: Column(
            children: [
              Opacity(
                opacity: 0.6,
                child: Image.asset(AppAssets.githubLogoWhite, height: 22),
              ),
              const SizedBox(height: 8),
              Text('Taar — Hear Everything',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.4), fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}
