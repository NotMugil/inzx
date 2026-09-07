import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/desede_engine.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

import '../../models/models.dart';

/// Decoded stream information from JioSaavn
class JioSaavnStream {
  final String url;
  final int? kbps;
  final String format;

  const JioSaavnStream({
    required this.url,
    this.kbps,
    this.format = 'mp4',
  });

  String get streamUrl => url;
  int get bitrateKbps => kbps ?? 320;

  @override
  String toString() => 'JioSaavnStream(${kbps ?? '?'}kbps, $format, $url)';
}

/// Raw parsed song item from JioSaavn API
class JioSaavnSong {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final int durationSeconds;
  final String encryptedMediaUrl;
  final bool supports320;
  final bool isExplicit;
  final String? image;

  const JioSaavnSong({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    required this.durationSeconds,
    required this.encryptedMediaUrl,
    required this.supports320,
    required this.isExplicit,
    this.image,
  });

  factory JioSaavnSong.fromJson(Map<String, dynamic> json) {
    final moreInfo = json['more_info'] as Map<String, dynamic>? ?? {};
    
    // Extract primary artists
    String artistName = '';
    final artistMap = moreInfo['artistMap'] as Map<String, dynamic>?;
    if (artistMap != null) {
      final primary = artistMap['primary_artists'] as List<dynamic>?;
      if (primary != null && primary.isNotEmpty) {
        artistName = primary
            .map((a) => (a as Map<String, dynamic>)['name']?.toString() ?? '')
            .where((n) => n.isNotEmpty)
            .join(', ');
      }
    }
    if (artistName.isEmpty) {
      artistName = moreInfo['singers']?.toString() ??
          moreInfo['music']?.toString() ??
          '';
    }

    final has320 = moreInfo['320kbps']?.toString().toLowerCase() == 'true';
    final explicit = json['explicit_content']?.toString() == '1' ||
        json['explicit_content']?.toString().toLowerCase() == 'true';

    final durationSec = int.tryParse(moreInfo['duration']?.toString() ?? '0') ?? 0;
    final albumName = moreInfo['album']?.toString();

    return JioSaavnSong(
      id: json['id']?.toString() ?? '',
      title: _decodeHtmlEntities(json['title']?.toString() ?? ''),
      artist: _decodeHtmlEntities(artistName),
      album: albumName != null ? _decodeHtmlEntities(albumName) : null,
      durationSeconds: durationSec,
      encryptedMediaUrl: moreInfo['encrypted_media_url']?.toString() ?? '',
      supports320: has320,
      isExplicit: explicit,
      image: json['image']?.toString(),
    );
  }

  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&#039;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }
}

/// Service to interact with JioSaavn API for 320kbps audio streams
class JioSaavnService {
  static final JioSaavnService _instance = JioSaavnService._internal();
  factory JioSaavnService() => _instance;
  static JioSaavnService get instance => _instance;

  JioSaavnService._internal();

  static const String _baseUrl = 'https://www.jiosaavn.com/api.php';
  static const String _desKey = '383465913834659138346591'; // 24-byte key for 3DES

  /// In-memory cache for resolved stream URLs by track ID
  final Map<String, JioSaavnStream> _streamCache = {};
  /// Track IDs where no matching JioSaavn stream was found
  final Set<String> _noMatchTrackIds = {};

  final http.Client _client = http.Client();

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
        'X-Forwarded-For': '49.36.0.1',
        'X-Real-IP': '49.36.0.1',
        'Accept-Language': 'en-IN,en;q=0.9',
        'Cookie': 'explicit_content=1',
      };

  /// Decrypts the media URL using DES/ECB/PKCS7
  String decryptUrl(String encryptedUrl) {
    if (encryptedUrl.trim().isEmpty) return '';
    try {
      final keyBytes = utf8.encode(_desKey);
      final cipher = PaddedBlockCipherImpl(
        PKCS7Padding(),
        ECBBlockCipher(DESedeEngine()),
      );
      final params = PaddedBlockCipherParameters(
        KeyParameter(Uint8List.fromList(keyBytes)),
        null,
      );
      cipher.init(false, params);
      final cipherText = base64.decode(encryptedUrl.trim());
      final decryptedBytes = cipher.process(Uint8List.fromList(cipherText));
      return utf8.decode(decryptedBytes).trim();
    } catch (e) {
      if (kDebugMode) {
        print('JioSaavnService: URL decryption failed: $e');
      }
      return '';
    }
  }

  /// Extracts the best available CDN stream URL with conditional 320kbps upgrade
  JioSaavnStream? bestStream(String encryptedUrl, bool supports320) {
    final decrypted = decryptUrl(encryptedUrl);
    if (decrypted.isEmpty) return null;

    final suffixRegex = RegExp(r'_(48|96|160|320)\.(mp4|aac|mp3)$');
    final match = suffixRegex.firstMatch(decrypted);

    if (match == null) {
      return JioSaavnStream(
        url: decrypted,
        kbps: supports320 ? 320 : null,
      );
    }

    final offered = int.tryParse(match.group(1) ?? '');
    final ext = match.group(2) ?? 'mp4';

    if (supports320) {
      final upgradedUrl = decrypted.replaceRange(
        match.start,
        match.end,
        '_320.$ext',
      );
      return JioSaavnStream(
        url: upgradedUrl,
        kbps: 320,
        format: ext,
      );
    } else {
      return JioSaavnStream(
        url: decrypted,
        kbps: offered,
        format: ext,
      );
    }
  }

  /// Search JioSaavn catalogue for songs matching [query]
  Future<List<JioSaavnSong>> searchSongs(String query, {int limit = 10}) async {
    if (query.trim().isEmpty) return [];

    try {
      final uri = Uri.parse(_baseUrl).replace(queryParameters: {
        '__call': 'search.getResults',
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'android',
        'q': query.trim(),
        'p': '1',
        'n': limit.toString(),
      });

      final response = await _client.get(uri, headers: _headers).timeout(
            const Duration(seconds: 5),
          );

      if (response.statusCode != 200) {
        return [];
      }

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return [];

      final results = decoded['results'] as List<dynamic>? ?? [];
      final songs = results
          .map((item) => JioSaavnSong.fromJson(item as Map<String, dynamic>))
          .toList();

      // Prioritize explicit tracks ahead of clean edits
      songs.sort((a, b) {
        if (a.isExplicit && !b.isExplicit) return -1;
        if (!a.isExplicit && b.isExplicit) return 1;
        return 0;
      });

      return songs;
    } catch (e) {
      if (kDebugMode) {
        print('JioSaavnService: search error: $e');
      }
      return [];
    }
  }

  /// Cleans packaging and suffixes from track title
  static String cleanTitle(String title) {
    String cleaned = title;
    // Strip common YouTube Music labels and version tags in brackets
    cleaned = cleaned.replaceAll(
      RegExp(
        r'[\(\[\{](?:official\s*(?:video|audio|music\s*video)|lyric\s*video|audio|video|visualizer|hd|4k|remastered|from\s*"[^"]*")[\)\]\}]',
        caseSensitive: false,
      ),
      '',
    );
    // Strip "feat." or "ft."
    cleaned = cleaned.replaceAll(
      RegExp(r'\s+(?:feat|ft)\.?\s+.*$', caseSensitive: false),
      '',
    );
    return cleaned.trim();
  }

  /// Extract primary artist name
  static String primaryArtist(String artist) {
    if (artist.isEmpty) return '';
    final parts = artist.split(RegExp(r'[,&/•]|(?:\s+feat\.?\s+)'));
    return parts.first.trim().toLowerCase();
  }

  /// Match a target track with candidate songs from JioSaavn
  JioSaavnSong? matchTrack(Track target, List<JioSaavnSong> candidates) {
    if (candidates.isEmpty) return null;

    final targetCleanTitle = cleanTitle(target.title).toLowerCase();
    final targetPrimaryArtist = primaryArtist(target.artist);
    final targetDurationSec = target.duration.inSeconds;

    JioSaavnSong? bestMatch;
    int bestScore = -1;

    for (final candidate in candidates) {
      final candidateCleanTitle = cleanTitle(candidate.title).toLowerCase();
      final candidatePrimaryArtist = primaryArtist(candidate.artist);

      // 1. Title matching
      int score = 0;
      if (candidateCleanTitle == targetCleanTitle) {
        score += 50;
      } else if (candidateCleanTitle.contains(targetCleanTitle) ||
          targetCleanTitle.contains(candidateCleanTitle)) {
        score += 30;
      } else {
        // Words overlap check
        final targetWords = targetCleanTitle.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
        final candidateWords = candidateCleanTitle.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
        final common = targetWords.intersection(candidateWords);
        if (common.isEmpty) continue; // No title words in common
        score += common.length * 10;
      }

      // 2. Artist matching
      if (targetPrimaryArtist.isNotEmpty && candidatePrimaryArtist.isNotEmpty) {
        if (candidatePrimaryArtist.contains(targetPrimaryArtist) ||
            targetPrimaryArtist.contains(candidatePrimaryArtist)) {
          score += 40;
        } else {
          // Check if candidate artist mentions any of the target artist words
          final targetArtistParts = targetPrimaryArtist.split(RegExp(r'\s+'));
          final matchesArtist = targetArtistParts.any(
            (part) => part.length > 2 && candidatePrimaryArtist.contains(part),
          );
          if (matchesArtist) {
            score += 20;
          }
        }
      }

      // 3. Duration matching (if known)
      if (targetDurationSec > 0 && candidate.durationSeconds > 0) {
        final diff = (targetDurationSec - candidate.durationSeconds).abs();
        if (diff <= 3) {
          score += 30;
        } else if (diff <= 6) {
          score += 15;
        } else if (diff > 12) {
          // Large duration discrepancy usually means different edit / remix / music video
          score -= 30;
        }
      }

      // 4. Quality preference
      if (candidate.supports320) {
        score += 10;
      }

      // 5. Explicit flag matching
      if (target.isExplicit == candidate.isExplicit) {
        score += 5;
      }

      if (score > bestScore && score >= 40) {
        bestScore = score;
        bestMatch = candidate;
      }
    }

    return bestMatch;
  }

  /// Get the best stream for [track] from JioSaavn, using cache when available
  Future<JioSaavnStream?> getBestStreamForTrack(Track track) async {
    // 1. Check in-memory stream cache
    if (_streamCache.containsKey(track.id)) {
      return _streamCache[track.id];
    }
    if (_noMatchTrackIds.contains(track.id)) {
      return null;
    }

    try {
      // 2. Build search query
      final cleanedTitle = cleanTitle(track.title);
      final primary = primaryArtist(track.artist);
      final query = primary.isNotEmpty ? '$cleanedTitle $primary' : cleanedTitle;

      final results = await searchSongs(query, limit: 8);
      if (results.isEmpty) {
        _noMatchTrackIds.add(track.id);
        return null;
      }

      // 3. Find best match
      final matched = matchTrack(track, results);
      if (matched == null || matched.encryptedMediaUrl.isEmpty) {
        _noMatchTrackIds.add(track.id);
        return null;
      }

      // 4. Resolve stream URL
      final stream = bestStream(matched.encryptedMediaUrl, matched.supports320);
      if (stream == null || stream.url.isEmpty) {
        _noMatchTrackIds.add(track.id);
        return null;
      }

      // 5. Cache result
      _streamCache[track.id] = stream;
      if (kDebugMode) {
        print(
          'JioSaavnService: Matched "${track.title}" -> "${matched.title}" (${stream.kbps}kbps)',
        );
      }
      return stream;
    } catch (e) {
      if (kDebugMode) {
        print('JioSaavnService: getBestStreamForTrack error: $e');
      }
      return null;
    }
  }

  /// Returns a cached stream for [trackId] if already resolved, without making network requests
  JioSaavnStream? getCachedStream(String trackId) => _streamCache[trackId];

  /// Clear all cached streams
  void clearCache() {
    _streamCache.clear();
    _noMatchTrackIds.clear();
  }
}
