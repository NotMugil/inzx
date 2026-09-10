import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../../models/models.dart';
import 'canvas_artwork.dart';
import 'tidal_canvas_service.dart';
import 'community_canvas_service.dart';
import 'apple_music_canvas_service.dart';

class _CacheEntry {
  final CanvasArtwork? artwork;
  final bool withAlbum;
  final DateTime timestamp;

  _CacheEntry({
    required this.artwork,
    required this.withAlbum,
    required this.timestamp,
  });

  bool reusable(bool hasAlbumNow) {
    // If we have a hit, it's always reusable.
    if (artwork != null) return true;
    // If it was a miss with album, it's final.
    if (withAlbum) return true;
    // If it was a miss without album, and we still don't have album, it's reusable.
    return !hasAlbumNow;
  }
}

/// Central repository orchestrating motion artwork (Canvas) resolution across
/// Tidal, Community, and Apple Music providers.
///
/// Features:
/// - Priority: Tidal (1280x1280 Square MP4) -> Community Canvas -> Apple Music.
/// - In-flight query deduplication.
/// - LRU memory cache with negative-caching to eliminate redundant queries for songs without canvas.
/// - Intelligent title noise scrubbing (removes YouTube packaging such as "| Official Video").
class CanvasRepository {
  CanvasRepository._();
  static final CanvasRepository instance = CanvasRepository._();

  static const int _maxCacheSize = 128;
  final LinkedHashMap<String, _CacheEntry> _cache = LinkedHashMap();
  final Map<String, Future<CanvasArtwork?>> _inFlight = {};

  /// Get the animated canvas for a [track], or null if none exists.
  Future<CanvasArtwork?> canvasFor(Track track) async {
    final title = cleanTitle(track.title);
    final artist = cleanArtist(track.artist);
    if (title.isEmpty || artist.isEmpty) return null;

    final album = track.album?.trim();
    final hasAlbum = album != null && album.isNotEmpty;
    final key = 'track|${track.id}';

    // Check synchronous cache
    final cached = _cache[key];
    if (cached != null && cached.reusable(hasAlbum)) {
      return cached.artwork;
    }

    // Deduplicate in-flight fetches
    if (_inFlight.containsKey(key)) {
      return _inFlight[key];
    }

    final future = _resolve(title, artist, album, hasAlbum);
    _inFlight[key] = future;

    try {
      final result = await future;
      _putCache(key, _CacheEntry(
        artwork: result,
        withAlbum: hasAlbum,
        timestamp: DateTime.now(),
      ));
      return result;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Get the animated canvas for an [album] and [artist].
  Future<CanvasArtwork?> canvasForAlbum(String album, String artist) async {
    final cleanAlbumName = cleanTitle(album);
    final cleanArtistName = cleanArtist(artist);
    if (cleanAlbumName.isEmpty || cleanArtistName.isEmpty) return null;

    final key = 'album|$cleanAlbumName|$cleanArtistName';
    final cached = _cache[key];
    if (cached != null) return cached.artwork;

    if (_inFlight.containsKey(key)) {
      return _inFlight[key];
    }

    final future = _resolveAlbum(cleanAlbumName, cleanArtistName);
    _inFlight[key] = future;

    try {
      final result = await future;
      _putCache(key, _CacheEntry(
        artwork: result,
        withAlbum: true,
        timestamp: DateTime.now(),
      ));
      return result;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<CanvasArtwork?> _resolve(
    String title,
    String artist,
    String? album,
    bool hasAlbum,
  ) async {
    // 1. Tidal (Preferred: pristine 1280x1280 1:1 square MP4s)
    try {
      final tidalHit = await TidalCanvasService.search(title, artist, album);
      if (tidalHit != null) return tidalHit;
    } catch (e) {
      debugPrint('CanvasRepository: Tidal error: $e');
    }

    // 2. Apple Music (Huge catalog coverage via album motion artwork)
    try {
      final appleHit = await AppleMusicCanvasService.search(title, artist, album);
      if (appleHit != null) return appleHit;
    } catch (e) {
      debugPrint('CanvasRepository: Apple Music error: $e');
    }

    // 3. Community Canvas (Fast index lookup for classic tracks and curated loops)
    try {
      final communityHit = await CommunityCanvasService.search(title, artist, album);
      if (communityHit != null) return communityHit;
    } catch (e) {
      debugPrint('CanvasRepository: Community error: $e');
    }

    return null;
  }

  Future<CanvasArtwork?> _resolveAlbum(String album, String artist) async {
    // 1. Tidal
    final tidalHit = await TidalCanvasService.searchAlbum(album, artist);
    if (tidalHit != null) return tidalHit;

    // 2. Community
    final communityHit = await CommunityCanvasService.searchAlbum(album, artist);
    if (communityHit != null) return communityHit;

    // 3. Apple Music
    final appleHit = await AppleMusicCanvasService.searchAlbum(album, artist);
    if (appleHit != null) return appleHit;

    return null;
  }

  void _putCache(String key, _CacheEntry entry) {
    _cache.remove(key);
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = entry;
  }

  /// Remove YouTube video title packaging, bracketed noise, and labels
  /// that catalogue services never see.
  static String cleanTitle(String input) {
    var s = input
        .split(' | ')
        .first
        .replaceAll(
          RegExp(
            r'\((?:from|official|lyrical|video|audio|lyrics|music video|full song|visualizer|remastered|deluxe|explicit)[^)]*\)',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\[(?:from|official|lyrical|video|audio|lyrics|music video|full song|visualizer|remastered|deluxe|explicit|hd|4k)[^\]]*\]',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(?:official (?:video|audio|music video|lyric video)|lyrical|full song|4k video|hd video)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // If formatted as "Artist - Title", extract the title
    if (s.contains(' - ')) {
      final parts = s.split(' - ');
      if (parts.length == 2 && parts[1].trim().isNotEmpty) {
        s = parts[1].trim();
      }
    }

    return s.isEmpty ? input.trim() : s;
  }

  static String cleanArtist(String input) {
    var s = input
        .replaceAll(RegExp(r'\s*-\s*Topic', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*VEVO', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*Official\s*(?:Channel)?', caseSensitive: false), '')
        .trim();
    return s.isEmpty ? input.trim() : s;
  }

  static String cleanNoise(String input) => cleanTitle(input);
}
