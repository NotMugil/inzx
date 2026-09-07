import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';

/// Service for extracting and caching embedded album art from local audio files.
class LocalArtworkService {
  static final Map<String, Uint8List> _memoryCache = <String, Uint8List>{};
  static Directory? _cacheDir;

  /// Fast synchronous check for cached image bytes in memory.
  static Uint8List? getCachedBytes(String localFilePath) {
    return _memoryCache[localFilePath];
  }

  /// Manually populate memory cache (e.g., right after downloading or in tests).
  static void setMemoryCache(String localFilePath, Uint8List bytes) {
    if (localFilePath.trim().isNotEmpty && bytes.isNotEmpty) {
      _memoryCache[localFilePath.trim()] = bytes;
    }
  }

  /// Evict cached artwork for a deleted file from memory and disk cache.
  static void evict(String localFilePath) {
    final trimmed = localFilePath.trim();
    if (trimmed.isEmpty) return;
    _memoryCache.remove(trimmed);
    try {
      if (_cacheDir != null) {
        final cacheFile = File('${_cacheDir!.path}/${trimmed.hashCode}.jpg');
        if (cacheFile.existsSync()) {
          cacheFile.deleteSync();
        }
      }
    } catch (_) {}
  }

  /// Get the persistent artwork cache directory.
  static Future<Directory> _getCacheDirectory() async {
    if (_cacheDir != null) return _cacheDir!;
    try {
      final tempDir = await getTemporaryDirectory();
      final artDir = Directory('${tempDir.path}/embedded_art');
      if (!await artDir.exists()) {
        await artDir.create(recursive: true);
      }
      _cacheDir = artDir;
      return artDir;
    } catch (_) {
      final sysTemp = Directory.systemTemp;
      final artDir = Directory('${sysTemp.path}/inzx_art');
      if (!await artDir.exists()) {
        await artDir.create(recursive: true);
      }
      _cacheDir = artDir;
      return artDir;
    }
  }

  /// Resolve embedded cover art bytes for a local audio file.
  static Future<Uint8List?> getArtworkBytes(String localFilePath) async {
    final trimmedPath = localFilePath.trim();
    if (trimmedPath.isEmpty) return null;

    // 1. In-memory cache hit
    final memoryHit = _memoryCache[trimmedPath];
    if (memoryHit != null && memoryHit.isNotEmpty) {
      return memoryHit;
    }

    final audioFile = File(trimmedPath);
    if (!await audioFile.exists()) return null;

    // 2. Persistent disk cache check
    try {
      final cacheDir = await _getCacheDirectory();
      final cacheFile = File('${cacheDir.path}/${trimmedPath.hashCode}.jpg');
      if (await cacheFile.exists() && await cacheFile.length() > 0) {
        final bytes = await cacheFile.readAsBytes();
        if (bytes.isNotEmpty) {
          _memoryCache[trimmedPath] = bytes;
          return bytes;
        }
      }
    } catch (_) {}

    // 3. Legacy companion .cover.jpg check (if present from older downloads)
    try {
      final legacyCover = File('$trimmedPath.cover.jpg');
      if (await legacyCover.exists() && await legacyCover.length() > 0) {
        final bytes = await legacyCover.readAsBytes();
        if (bytes.isNotEmpty) {
          _memoryCache[trimmedPath] = bytes;
          _saveToDiskCache(trimmedPath, bytes);
          return bytes;
        }
      }
    } catch (_) {}

    // 4. In-file extraction
    Uint8List? extracted;
    final lower = trimmedPath.toLowerCase();

    // M4A / MP4 direct box parse
    if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) {
      try {
        final fileBytes = await audioFile.readAsBytes();
        extracted = _extractMp4Cover(fileBytes);
      } catch (e) {
        if (kDebugMode) {
          print('LocalArtworkService: MP4 direct extract error: $e');
        }
      }
    }

    // WebM / Opus Matroska attachments
    if (extracted == null && (lower.endsWith('.opus') || lower.endsWith('.webm'))) {
      try {
        final fileBytes = await audioFile.readAsBytes();
        extracted = _extractWebmCover(fileBytes);
      } catch (e) {
        if (kDebugMode) {
          print('LocalArtworkService: WebM direct extract error: $e');
        }
      }
    }

    // audio_metadata_reader (MP3 ID3v2 APIC, FLAC, OGG, WAV, fallback MP4)
    if (extracted == null && !lower.endsWith('.webm') && !lower.endsWith('.opus')) {
      try {
        final meta = readMetadata(audioFile, getImage: true);
        if (meta.pictures.isNotEmpty) {
          final picBytes = meta.pictures.first.bytes;
          if (picBytes.isNotEmpty) {
            extracted = picBytes;
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('LocalArtworkService: audio_metadata_reader error: $e');
        }
      }
    }

    if (extracted != null && extracted.isNotEmpty) {
      _memoryCache[trimmedPath] = extracted;
      _saveToDiskCache(trimmedPath, extracted);
      return extracted;
    }

    return null;
  }

  /// Get the cached File containing the artwork for a local audio file.
  static Future<File?> getArtworkFile(String localFilePath) async {
    final bytes = await getArtworkBytes(localFilePath);
    if (bytes == null || bytes.isEmpty) return null;

    try {
      final cacheDir = await _getCacheDirectory();
      final cacheFile = File('${cacheDir.path}/${localFilePath.trim().hashCode}.jpg');
      if (await cacheFile.exists() && await cacheFile.length() > 0) {
        return cacheFile;
      }
      await cacheFile.writeAsBytes(bytes, flush: true);
      return cacheFile;
    } catch (_) {
      return null;
    }
  }

  static void _saveToDiskCache(String localFilePath, Uint8List bytes) async {
    try {
      final cacheDir = await _getCacheDirectory();
      final cacheFile = File('${cacheDir.path}/${localFilePath.trim().hashCode}.jpg');
      await cacheFile.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  /// Extract `covr` payload from MP4/M4A box tree.
  static Uint8List? _extractMp4Cover(Uint8List bytes) {
    final covrPattern = latin1.encode('covr');
    final dataPattern = latin1.encode('data');
    for (int i = 0; i < bytes.length - 16; i++) {
      if (bytes[i] == covrPattern[0] &&
          bytes[i + 1] == covrPattern[1] &&
          bytes[i + 2] == covrPattern[2] &&
          bytes[i + 3] == covrPattern[3]) {
        for (int j = i + 4; j < bytes.length - 16 && j < i + 250; j++) {
          if (bytes[j] == dataPattern[0] &&
              bytes[j + 1] == dataPattern[1] &&
              bytes[j + 2] == dataPattern[2] &&
              bytes[j + 3] == dataPattern[3]) {
            final dataSize = ((bytes[j - 4] & 0xFF) << 24) |
                ((bytes[j - 3] & 0xFF) << 16) |
                ((bytes[j - 2] & 0xFF) << 8) |
                (bytes[j - 1] & 0xFF);
            final payloadStart = j + 12; // (j - 4) + 8 byte box header + 8 byte data header
            final payloadLength = dataSize - 16;
            if (payloadStart + payloadLength <= bytes.length && payloadLength > 0) {
              return bytes.sublist(payloadStart, payloadStart + payloadLength);
            }
          }
        }
      }
    }
    return null;
  }

  /// Extract `FileData` (0x465C) from WebM/Matroska attachments.
  static Uint8List? _extractWebmCover(Uint8List bytes) {
    for (int i = 0; i < bytes.length - 10; i++) {
      if (bytes[i] == 0x46 && bytes[i + 1] == 0x5C) {
        int pos = i + 2;
        if (pos >= bytes.length) return null;
        int firstByte = bytes[pos];
        int length = 0;
        int mask = 0x80;
        int numBytes = 1;
        while ((firstByte & mask) == 0 && mask > 0) {
          mask >>= 1;
          numBytes++;
        }
        length = firstByte & (mask - 1);
        for (int k = 1; k < numBytes; k++) {
          pos++;
          if (pos >= bytes.length) return null;
          length = (length << 8) | bytes[pos];
        }
        pos++;
        if (pos + length <= bytes.length && length > 0) {
          return bytes.sublist(pos, pos + length);
        }
      }
    }
    return null;
  }

  /// Clear in-memory cache.
  static void clearMemoryCache() {
    _memoryCache.clear();
  }
}
