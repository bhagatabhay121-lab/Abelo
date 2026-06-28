/// Centralized paths for the bundled image assets (sourced from the
/// user-provided assets pack). Keeping these in one place means every
/// screen falls back to the same placeholder art when the network image
/// for a song/album/artist fails to load — same idea as the default
/// cover art JioSaavn-based apps fall back to.
class AppAssets {
  static const logo = 'assets/images/ic_launcher.png';
  static const logoWhite = 'assets/images/icon-white-trans.png';
  static const placeholderSong = 'assets/images/placeholder_song.png';
  static const placeholderAlbum = 'assets/images/placeholder_album.png';
  static const placeholderArtist = 'assets/images/placeholder_artist.png';
  static const placeholderCover = 'assets/images/placeholder_cover.jpg';
  static const headerDark = 'assets/images/header_dark.jpg';
  static const lyricsIcon = 'assets/images/lyrics.png';
  static const githubLogoWhite = 'assets/images/github_logo_white.png';
}
