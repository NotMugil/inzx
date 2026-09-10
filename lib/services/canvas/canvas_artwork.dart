enum CanvasSource {
  tidal,
  community,
  appleMusic,
}

/// A looping video that stands in for a track's cover art — Tidal Video Cover,
/// Apple Music Motion Artwork, or Community Canvas.
class CanvasArtwork {
  final String url;
  final String? fallbackUrl;
  final String? title;
  final String? artist;
  final String? album;
  final CanvasSource source;

  const CanvasArtwork({
    required this.url,
    this.fallbackUrl,
    this.title,
    this.artist,
    this.album,
    required this.source,
  });

  /// Whether this clip accurately belongs to the track or album requested.
  /// Fold away punctuation, casing, bracketed noise, and accented characters.
  bool matches(String wantTitle, String wantArtist, [String? wantAlbum]) {
    final normOurTitle = title != null ? normalizeForMatch(title!) : '';
    final normWantTitle = normalizeForMatch(wantTitle);

    final titleOk = title == null ||
        normWantTitle.isEmpty ||
        normOurTitle == normWantTitle ||
        normOurTitle.contains(normWantTitle) ||
        normWantTitle.contains(normOurTitle);

    final wantedArtists = splitArtists(wantArtist);
    final ourArtists = splitArtists(artist ?? '');
    final artistOk = artist == null ||
        wantArtist.trim().isEmpty ||
        wantedArtists.isEmpty ||
        ourArtists.isEmpty ||
        wantedArtists.any((want) =>
            ourArtists.any((it) => it == want || it.contains(want) || want.contains(it)));

    return titleOk && artistOk;
  }

  static String foldDiacritics(String text) {
    const withDia = 'ÀÁÂÃÄÅàáâãäåÒÓÔÕÖØòóôõöøÈÉÊËèéêëÌÍÎÏìíîïÙÚÛÜùúûüÝýÿÑñÇç';
    const noDia   = 'AAAAAAaaaaaaOOOOOOooooooEEEEeeeeIIIIiiiiUUUUuuuuYyyNnCc';
    var out = text;
    for (int i = 0; i < withDia.length; i++) {
      out = out.replaceAll(withDia[i], noDia[i]);
    }
    return out;
  }

  static String normalizeForMatch(String raw) {
    return foldDiacritics(raw)
        .toLowerCase()
        .replaceAll(RegExp(r'[\(\[\{].*?[\)\]\}]'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static List<String> splitArtists(String raw) {
    return raw
        .split(RegExp(
          r'(?:\s*,\s*|\s*&\s*|\s+×\s+|\s+x\s+|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b)',
          caseSensitive: false,
        ))
        .map(normalizeForMatch)
        .where((element) => element.isNotEmpty)
        .toList();
  }
}
