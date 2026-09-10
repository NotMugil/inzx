import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'canvas_artwork.dart';

/// Apple Music's motion artwork — exposed on Apple Music's Catalog API
/// as `editorialVideo`.
///
/// Uses the anonymous bearer token that Apple's web player generates for public
/// browsing, cached until near expiry.
class AppleMusicCanvasService {
  static const String _ampBase = 'https://amp-api.music.apple.com/v1/catalog';
  static const String _webPlayerUrl = 'https://music.apple.com/us/browse';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  static final http.Client _client = http.Client();

  static String? _cachedToken;
  static DateTime? _tokenExpiresAt;
  static DateTime? _retryTokenAfter;

  /// Search Apple Music Catalog for a track's motion artwork.
  static Future<CanvasArtwork?> search(
    String title,
    String artist, [
    String? album,
  ]) async {
    try {
      final token = await _getToken();
      if (token == null) return null;

      final term = StringBuffer();
      if (!title.toLowerCase().contains(artist.toLowerCase())) {
        term.write('$artist ');
      }
      term.write(title);
      if (album != null &&
          album.trim().isNotEmpty &&
          !title.toLowerCase().contains(album.toLowerCase())) {
        term.write(' $album');
      }

      final uri = Uri.parse('$_ampBase/us/search').replace(
        queryParameters: {
          'term': term.toString().trim(),
          'types': 'songs',
          'limit': '10',
          'extend': 'editorialVideo',
          'include': 'albums',
        },
      );

      final response = await _client.get(
        uri,
        headers: _authHeaders(token),
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 401) {
        _cachedToken = null;
        _tokenExpiresAt = null;
        return null;
      }
      if (response.statusCode != 200) return null;

      final root = jsonDecode(response.body) as Map<String, dynamic>;
      final results = root['results'] as Map<String, dynamic>?;
      final songs = results?['songs'] as Map<String, dynamic>?;
      final hits = songs?['data'] as List<dynamic>?;
      if (hits == null || hits.isEmpty) return null;

      for (final hit in hits) {
        if (hit is! Map<String, dynamic>) continue;
        final attributes = hit['attributes'] as Map<String, dynamic>?;
        if (attributes == null) continue;

        final songName = attributes['name'] as String?;
        final songArtist = attributes['artistName'] as String?;
        final songAlbum = attributes['albumName'] as String?;

        if (songName == null || songArtist == null) continue;
        if (!CanvasArtwork(
          url: '',
          title: songName,
          artist: songArtist,
          source: CanvasSource.appleMusic,
        ).matches(title, artist, album)) {
          continue;
        }

        // 1. Check inline editorialVideo on song
        final editorialVideo =
            attributes['editorialVideo'] as Map<String, dynamic>?;
        if (editorialVideo != null) {
          final urls = _extractMotionUrls(editorialVideo);
          if (urls != null) {
            final candidate = CanvasArtwork(
              url: urls.$1,
              fallbackUrl: urls.$2,
              title: songName,
              artist: songArtist,
              album: songAlbum,
              source: CanvasSource.appleMusic,
            );
            debugPrint('AppleMusicCanvas: Found inline motion artwork for "$songName"');
            return candidate;
          }
        }

        // 2. Fetch album's editorialVideo (where 95%+ of Apple motion covers live)
        final albumId = _extractAlbumId(hit);
        if (albumId != null) {
          final albumArtwork = await _fetchAlbumMotion(
            albumId: albumId,
            bearer: token,
            songName: songName,
            songArtist: songArtist,
          );
          if (albumArtwork != null) {
            return albumArtwork;
          }
        }
      }
    } catch (e) {
      debugPrint('AppleMusicCanvas: Search error: $e');
    }
    return null;
  }

  static String? _extractAlbumId(Map<String, dynamic> songHit) {
    try {
      final relationshipId = songHit['relationships']?['albums']?['data']?[0]?['id'] as String?;
      if (relationshipId != null && !relationshipId.startsWith('pl.')) {
        return relationshipId;
      }
    } catch (_) {}

    final url = songHit['attributes']?['url'] as String?;
    if (url != null && url.contains('/album/')) {
      final afterAlbum = url.split('/album/').last.split('?').first;
      final seg = afterAlbum.split('/').last;
      if (RegExp(r'^\d+$').hasMatch(seg)) {
        return seg;
      }
    }
    return null;
  }

  static Future<CanvasArtwork?> _fetchAlbumMotion({
    required String albumId,
    required String bearer,
    required String songName,
    required String songArtist,
  }) async {
    try {
      final albumUri = Uri.parse('$_ampBase/us/albums/$albumId?extend=editorialVideo');
      final response = await _client.get(
        albumUri,
        headers: _authHeaders(bearer),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final albumObj = data['data']?[0]?['attributes'] as Map<String, dynamic>?;
      if (albumObj == null) return null;

      final albumName = albumObj['name'] as String? ?? '';
      if (_isCompilation(albumName)) return null;

      final albumVideo = albumObj['editorialVideo'] as Map<String, dynamic>?;
      if (albumVideo == null) return null;

      final urls = _extractMotionUrls(albumVideo);
      if (urls == null) return null;

      debugPrint('AppleMusicCanvas: Found album motion artwork on "$albumName" for "$songName"');
      return CanvasArtwork(
        url: urls.$1,
        fallbackUrl: urls.$2,
        title: songName,
        artist: songArtist,
        album: albumName,
        source: CanvasSource.appleMusic,
      );
    } catch (e) {
      debugPrint('AppleMusicCanvas: Fetch album motion error: $e');
      return null;
    }
  }

  static bool _isCompilation(String name) {
    final lower = name.toLowerCase();
    const markers = [
      'playlist',
      'set list',
      'essentials',
      'dj mix',
      'mixed',
      'apple music',
      "today's hits",
      'session',
    ];
    return markers.any(lower.contains);
  }

  /// Search Apple Music Catalog for an album's motion artwork.
  static Future<CanvasArtwork?> searchAlbum(String album, String artist) async {
    try {
      final token = await _getToken();
      if (token == null) return null;

      final term = album.toLowerCase().contains(artist.toLowerCase())
          ? album
          : '$artist $album';

      final uri = Uri.parse('$_ampBase/us/search').replace(
        queryParameters: {
          'term': term,
          'types': 'albums',
          'limit': '10',
          'extend': 'editorialVideo',
        },
      );

      final response = await _client.get(
        uri,
        headers: _authHeaders(token),
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 401) {
        _cachedToken = null;
        _tokenExpiresAt = null;
        return null;
      }
      if (response.statusCode != 200) return null;

      final root = jsonDecode(response.body) as Map<String, dynamic>;
      final results = root['results'] as Map<String, dynamic>?;
      final albums = results?['albums'] as Map<String, dynamic>?;
      final hits = albums?['data'] as List<dynamic>?;
      if (hits == null || hits.isEmpty) return null;

      for (final hit in hits) {
        if (hit is! Map<String, dynamic>) continue;
        final attributes = hit['attributes'] as Map<String, dynamic>?;
        if (attributes == null) continue;

        final albumName = attributes['name'] as String?;
        final artistName = attributes['artistName'] as String?;
        final editorialVideo =
            attributes['editorialVideo'] as Map<String, dynamic>?;
        if (editorialVideo == null) continue;

        final urls = _extractMotionUrls(editorialVideo);
        if (urls != null) {
          final candidate = CanvasArtwork(
            url: urls.$1,
            fallbackUrl: urls.$2,
            title: albumName,
            artist: artistName,
            album: albumName,
            source: CanvasSource.appleMusic,
          );
          if (candidate.matches(album, artist, album)) {
            debugPrint('AppleMusicCanvas: Found album motion artwork for "$albumName"');
            return candidate;
          }
        }
      }
    } catch (e) {
      debugPrint('AppleMusicCanvas: Album search error: $e');
    }
    return null;
  }

  static (String, String?)? _extractMotionUrls(Map<String, dynamic> video) {
    String? link(String key) {
      final asset = video[key] as Map<String, dynamic>?;
      if (asset == null) return null;
      return (asset['video'] ??
              asset['videoUrl'] ??
              asset['hlsUrl'] ??
              asset['url']) as String?;
    }

    final square = link('motionDetailSquare') ?? link('motionSquareVideo1x1');
    final raw = link('motionDetailRaw');
    final tall = link('motionDetailTall') ?? link('motionTallVideo3x4');

    final primary = square ?? raw ?? tall;
    if (primary == null || primary.isEmpty) return null;

    final alternate = [square, raw, tall].firstWhere(
      (url) => url != null && url != primary && url.isNotEmpty,
      orElse: () => null,
    );

    return (primary, alternate);
  }

  static Map<String, String> _authHeaders(String bearer) => {
        'Authorization': 'Bearer $bearer',
        'Origin': 'https://music.apple.com',
        'Referer': 'https://music.apple.com/',
        'User-Agent': _userAgent,
      };

  static Future<String?> _getToken() async {
    final now = DateTime.now();
    if (_cachedToken != null &&
        _tokenExpiresAt != null &&
        now.isBefore(_tokenExpiresAt!.subtract(const Duration(minutes: 1)))) {
      return _cachedToken;
    }

    if (_retryTokenAfter != null && now.isBefore(_retryTokenAfter!)) {
      return null;
    }

    try {
      final htmlResp = await _client.get(
        Uri.parse(_webPlayerUrl),
        headers: {'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 8));

      if (htmlResp.statusCode != 200) {
        _retryTokenAfter = now.add(const Duration(minutes: 15));
        return null;
      }

      final scriptMatches = RegExp(r'/assets/index(?:-legacy)?[~-][A-Za-z0-9_-]+\.js')
          .allMatches(htmlResp.body)
          .map((m) => m.group(0))
          .whereType<String>()
          .toSet();

      for (final scriptPath in scriptMatches) {
        final scriptResp = await _client.get(
          Uri.parse('https://music.apple.com$scriptPath'),
          headers: {'User-Agent': _userAgent},
        ).timeout(const Duration(seconds: 8));

        if (scriptResp.statusCode != 200) continue;

        final jwtMatches = RegExp(r'ey[A-Za-z0-9_-]+\.ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+')
            .allMatches(scriptResp.body)
            .map((m) => m.group(0))
            .whereType<String>();

        for (final jwt in jwtMatches) {
          final exp = _extractJwtExpiry(jwt);
          if (exp != null && exp.isAfter(now)) {
            _cachedToken = jwt;
            _tokenExpiresAt = exp;
            debugPrint('AppleMusicCanvas: Scraped anonymous web token (expires in ${exp.difference(now).inHours}h)');
            return jwt;
          }
        }
      }
    } catch (e) {
      debugPrint('AppleMusicCanvas: Token scraping error: $e');
    }

    _retryTokenAfter = now.add(const Duration(minutes: 15));
    return null;
  }

  static DateTime? _extractJwtExpiry(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;
      String normalized = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      final payload = jsonDecode(utf8.decode(base64Decode(normalized))) as Map<String, dynamic>;
      final expSec = payload['exp'] as int?;
      if (expSec != null) {
        return DateTime.fromMillisecondsSinceEpoch(expSec * 1000);
      }
    } catch (_) {}
    return null;
  }
}
