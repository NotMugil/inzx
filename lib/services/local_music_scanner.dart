import 'dart:io';
import 'package:flutter/foundation.dart' show compute, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hive/hive.dart';
import '../models/models.dart';
import '../core/services/cache/hive_service.dart';
import '../data/entities/track_entity.dart';
import '../data/entities/download_entity.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'local_artwork_service.dart';

/// Provider for scanned local music folders
final localMusicFoldersProvider =
    StateNotifierProvider<LocalMusicFoldersNotifier, List<String>>((ref) {
      return LocalMusicFoldersNotifier();
    });

/// Provider for scanned local tracks
final localTracksProvider =
    StateNotifierProvider<LocalTracksNotifier, List<Track>>((ref) {
      return LocalTracksNotifier();
    });

/// Provider for scan progress
final scanProgressProvider = StateProvider<ScanProgress?>((ref) => null);

/// Scan progress state
class ScanProgress {
  final int scannedFiles;
  final int totalFiles;
  final String currentFile;
  final bool isComplete;

  ScanProgress({
    this.scannedFiles = 0,
    this.totalFiles = 0,
    this.currentFile = '',
    this.isComplete = false,
  });

  double get progress => totalFiles > 0 ? scannedFiles / totalFiles : 0;
}

/// Local music folders notifier
class LocalMusicFoldersNotifier extends StateNotifier<List<String>> {
  LocalMusicFoldersNotifier() : super([]) {
    _loadPersisted();
  }

  Future<void> _loadPersisted() async {
    try {
      final box = HiveService.localMusicFoldersBox;
      final rawFolders = box.values.toList();
      final validFolders =
          rawFolders.where((p) => Directory(p).existsSync()).toList();
      state = validFolders;
      if (validFolders.length != rawFolders.length) {
        await _persist();
      }
    } catch (e) {
      if (kDebugMode) {
        print('LocalMusicFoldersNotifier: Load error: $e');
      }
    }
  }

  Future<void> _persist() async {
    try {
      final box = HiveService.localMusicFoldersBox;
      await box.clear();
      if (state.isNotEmpty) {
        final entries = {for (final p in state) p: p};
        await box.putAll(entries);
      }
    } catch (e) {
      if (kDebugMode) {
        print('LocalMusicFoldersNotifier: Persist error: $e');
      }
    }
  }

  void addFolder(String path) {
    if (!state.contains(path)) {
      state = [...state, path];
      _persist();
    }
  }

  void removeFolder(String path) {
    state = state.where((p) => p != path).toList();
    _persist();
  }

  void clear() {
    state = [];
    _persist();
  }
}

/// Local tracks notifier
class LocalTracksNotifier extends StateNotifier<List<Track>> {
  LocalTracksNotifier() : super([]) {
    _loadPersisted();
  }

  Future<void> _loadPersisted() async {
    try {
      final box = HiveService.localMusicTracksBox;
      final allTracks = box.values.map(_trackFromEntity).toList();
      final validTracks = <Track>[];
      final missingIds = <String>[];

      for (final track in allTracks) {
        final filePath = track.localFilePath;
        if (filePath != null &&
            filePath.isNotEmpty &&
            File(filePath).existsSync()) {
          validTracks.add(track);
        } else {
          missingIds.add(track.id);
        }
      }

      state = validTracks;
      if (missingIds.isNotEmpty) {
        await box.deleteAll(missingIds);
        if (kDebugMode) {
          print(
            'LocalTracksNotifier: Pruned ${missingIds.length} missing tracks from Hive',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('LocalTracksNotifier: Load error: $e');
      }
    }
  }

  /// Prune tracks whose files no longer exist on disk
  Future<void> pruneMissingFiles() async {
    final validTracks = <Track>[];
    final missingIds = <String>[];

    for (final track in state) {
      final filePath = track.localFilePath;
      if (filePath != null &&
          filePath.isNotEmpty &&
          File(filePath).existsSync()) {
        validTracks.add(track);
      } else {
        missingIds.add(track.id);
      }
    }

    if (missingIds.isNotEmpty) {
      state = validTracks;
      try {
        await HiveService.localMusicTracksBox.deleteAll(missingIds);
        if (kDebugMode) {
          print(
            'LocalTracksNotifier: pruneMissingFiles pruned ${missingIds.length} tracks',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          print('LocalTracksNotifier: pruneMissingFiles error: $e');
        }
      }
    }
  }

  void addTracks(List<Track> tracks) {
    final existingIds = state.map((t) => t.id).toSet();
    final newTracks = tracks.where((t) => !existingIds.contains(t.id)).toList();
    state = [...state, ...newTracks];
    if (newTracks.isNotEmpty) {
      _persistNewTracks(newTracks);
    }
  }

  /// Syncs a specific folder with fresh scanned tracks, removing deleted/moved files
  Future<void> syncFolderTracks(
    String folderPath,
    List<Track> freshTracks,
  ) async {
    final normalizedFolder = _normalizePath(folderPath);
    final folderWithSep = '$normalizedFolder/';

    final removedIds = <String>[];
    final otherTracks = <Track>[];

    for (final track in state) {
      final filePath = track.localFilePath;
      if (filePath == null || filePath.isEmpty) {
        otherTracks.add(track);
        continue;
      }
      final normalizedFile = _normalizePath(filePath);
      final isInFolder =
          normalizedFile == normalizedFolder ||
          normalizedFile.startsWith(folderWithSep);

      if (isInFolder) {
        removedIds.add(track.id);
      } else {
        otherTracks.add(track);
      }
    }

    state = [...otherTracks, ...freshTracks];

    try {
      final box = HiveService.localMusicTracksBox;
      if (removedIds.isNotEmpty) {
        await box.deleteAll(removedIds);
      }
      if (freshTracks.isNotEmpty) {
        final entities = {for (final t in freshTracks) t.id: _trackToEntity(t)};
        await box.putAll(entities);
      }
    } catch (e) {
      if (kDebugMode) {
        print('LocalTracksNotifier: syncFolderTracks error: $e');
      }
    }
  }

  /// Replaces tracks for all given folders with fresh tracks, removing deleted/moved files
  Future<void> syncAllFolders(
    List<String> folders,
    List<Track> allScannedTracks,
  ) async {
    final normalizedFolders = folders.map(_normalizePath).toList();

    final remaining = <Track>[];
    final removedIds = <String>[];

    for (final track in state) {
      final filePath = track.localFilePath;
      if (filePath == null || filePath.isEmpty) {
        remaining.add(track);
        continue;
      }
      final normalizedFile = _normalizePath(filePath);
      final isInTrackedFolder = normalizedFolders.any((f) {
        final fWithSep = '$f/';
        return normalizedFile == f || normalizedFile.startsWith(fWithSep);
      });

      if (isInTrackedFolder) {
        removedIds.add(track.id);
      } else {
        remaining.add(track);
      }
    }

    state = [...remaining, ...allScannedTracks];

    try {
      final box = HiveService.localMusicTracksBox;
      if (removedIds.isNotEmpty) {
        await box.deleteAll(removedIds);
      }
      if (allScannedTracks.isNotEmpty) {
        final entities = {
          for (final t in allScannedTracks) t.id: _trackToEntity(t),
        };
        await box.putAll(entities);
      }
    } catch (e) {
      if (kDebugMode) {
        print('LocalTracksNotifier: syncAllFolders error: $e');
      }
    }
  }

  void clear() {
    state = [];
    HiveService.localMusicTracksBox.clear();
  }

  /// Delete a single track: removes from state, removes from Hive, and optionally deletes the file from disk
  Future<bool> deleteTrack(Track track, {bool deleteFileFromDisk = true}) async {
    state = state.where((t) => t.id != track.id).toList();
    try {
      await HiveService.localMusicTracksBox.delete(track.id);
    } catch (e) {
      if (kDebugMode) {
        print('LocalTracksNotifier: Hive delete error: $e');
      }
    }

    // If it's also a downloaded track in Hive, delete from DownloadService/Hive
    try {
      if (Hive.isBoxOpen('downloads')) {
        final box = Hive.box<DownloadEntity>('downloads');
        final matchingKeys = <dynamic>[];
        for (final entry in box.toMap().entries) {
          if (entry.value.trackId == track.id ||
              (track.localFilePath != null &&
                  _normalizePath(entry.value.localPath).toLowerCase() ==
                      _normalizePath(track.localFilePath!).toLowerCase())) {
            matchingKeys.add(entry.key);
          }
        }
        if (matchingKeys.isNotEmpty) {
          await box.deleteAll(matchingKeys);
        }
      }
    } catch (_) {}

    // Delete file from disk if requested
    if (deleteFileFromDisk && track.localFilePath != null && track.localFilePath!.isNotEmpty) {
      try {
        final file = File(track.localFilePath!);
        if (await file.exists()) {
          await file.delete();
        }
        // Also delete legacy .cover.jpg if present
        final legacyCover = File('${track.localFilePath}.cover.jpg');
        if (await legacyCover.exists()) {
          await legacyCover.delete();
        }
        // Evict artwork cache
        LocalArtworkService.evict(track.localFilePath!);
      } catch (e) {
        if (kDebugMode) {
          print('LocalTracksNotifier: File delete error: $e');
        }
        return false;
      }
    }
    return true;
  }

  void removeTracksInFolder(String folderPath) {
    final normalizedFolder = _normalizePath(folderPath);
    final folderWithSep = '$normalizedFolder/';

    final removedIds = <String>[];
    final remaining = <Track>[];

    for (final track in state) {
      final filePath = track.localFilePath;
      if (filePath == null || filePath.isEmpty) {
        remaining.add(track);
        continue;
      }

      final normalizedFile = _normalizePath(filePath);
      final isInFolder =
          normalizedFile == normalizedFolder ||
          normalizedFile.startsWith(folderWithSep);

      if (isInFolder) {
        removedIds.add(track.id);
      } else {
        remaining.add(track);
      }
    }

    if (removedIds.isEmpty) return;

    state = remaining;
    HiveService.localMusicTracksBox.deleteAll(removedIds);
  }

  Future<void> _persistNewTracks(List<Track> tracks) async {
    try {
      final box = HiveService.localMusicTracksBox;
      final entities = {for (final t in tracks) t.id: _trackToEntity(t)};
      await box.putAll(entities);
    } catch (e) {
      if (kDebugMode) {
        print('LocalTracksNotifier: Persist error: $e');
      }
    }
  }
}

/// Local music scanner service
class LocalMusicScanner {
  static const _audioExtensions = [
    '.mp3',
    '.m4a',
    '.flac',
    '.wav',
    '.ogg',
    '.aac',
    '.opus',
  ];

  /// Request storage permission
  /// Returns: 'granted', 'denied', or 'permanentlyDenied'
  static Future<String> requestPermissionWithStatus() async {
    if (Platform.isAndroid) {
      // Check if already granted
      final audioStatus = await Permission.audio.status;
      if (audioStatus.isGranted) return 'granted';

      final storageStatus = await Permission.storage.status;
      if (storageStatus.isGranted) return 'granted';

      // Check if permanently denied (user selected "Don't ask again")
      if (audioStatus.isPermanentlyDenied ||
          storageStatus.isPermanentlyDenied) {
        return 'permanentlyDenied';
      }

      // Try requesting audio permission first (Android 13+)
      final audioRequest = await Permission.audio.request();
      if (audioRequest.isGranted) return 'granted';
      if (audioRequest.isPermanentlyDenied) return 'permanentlyDenied';

      // Fall back to storage permission for older Android
      final storageRequest = await Permission.storage.request();
      if (storageRequest.isGranted) return 'granted';
      if (storageRequest.isPermanentlyDenied) return 'permanentlyDenied';

      // Try manage external storage for Android 11+
      final manageStatus = await Permission.manageExternalStorage.request();
      if (manageStatus.isGranted) return 'granted';
      if (manageStatus.isPermanentlyDenied) return 'permanentlyDenied';

      // If we get here, permission was denied but not permanently
      // However on Android, after first denial, system won't show dialog again
      // So we treat any denial as needing settings
      return 'permanentlyDenied';
    }
    return 'granted'; // iOS/Desktop don't need explicit permission
  }

  /// Simple permission check (for backward compatibility)
  static Future<bool> requestPermission() async {
    final status = await requestPermissionWithStatus();
    return status == 'granted';
  }

  /// Open app settings
  static Future<bool> openSettings() async {
    return await openAppSettings();
  }

  /// Pick a folder to add
  static Future<String?> pickFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath();
      return result;
    } catch (e) {
      if (kDebugMode) {
        print('Error picking folder: $e');
      }
      return null;
    }
  }

  /// Scan a directory for audio files
  /// File discovery runs in a background isolate to avoid UI jank
  static Future<List<Track>> scanDirectory(
    String path, {
    void Function(int scanned, int total, String current)? onProgress,
  }) async {
    final directory = Directory(path);

    if (!await directory.exists()) {
      return [];
    }

    // Build download lookup map on main thread (Hive is fast)
    final downloadLookup = await _buildDownloadLookup();

    // Discover audio files in background isolate
    final filePaths = await compute(
      _discoverAudioFilesIsolate,
      _ScanRequest(path: path, extensions: _audioExtensions),
    );

    if (filePaths.isEmpty) return [];

    final tracks = <Track>[];

    // Process files on main thread (needed for progress callback)
    for (int i = 0; i < filePaths.length; i++) {
      final filePath = filePaths[i];
      onProgress?.call(i + 1, filePaths.length, filePath);

      try {
        final track = _fileToTrackSync(filePath, downloadLookup);
        if (track != null) {
          tracks.add(track);
        }
      } catch (e) {
        if (kDebugMode) {
          print('Error processing file $filePath: $e');
        }
      }
    }

    return tracks;
  }

  /// Build a lookup map of downloaded tracks by file path
  static Future<Map<String, DownloadEntity>> _buildDownloadLookup() async {
    try {
      if (!Hive.isBoxOpen('downloads')) {
        await Hive.openBox<DownloadEntity>('downloads');
      }
      final box = Hive.box<DownloadEntity>('downloads');
      final map = <String, DownloadEntity>{};
      for (final e in box.values) {
        map[e.localPath] = e;
        map[_normalizePath(e.localPath).toLowerCase()] = e;
      }
      return map;
    } catch (e) {
      return {};
    }
  }

  /// Convert a file path to a Track (synchronous, uses pre-built lookup & metadata reading)
  static Track? _fileToTrackSync(
    String filePath,
    Map<String, DownloadEntity> downloadLookup,
  ) {
    try {
      // Check if this file is a known download (by exact path or normalized lowercase)
      final entity = downloadLookup[filePath] ??
          downloadLookup[_normalizePath(filePath).toLowerCase()];
      if (entity != null) {
        return Track(
          id: entity.trackId,
          title: entity.title,
          artist: entity.artist,
          album: entity.album,
          duration: Duration(milliseconds: entity.durationMs),
          thumbnailUrl: entity.thumbnailUrl,
          localFilePath: filePath,
        );
      }

      // Try reading metadata directly from the audio file
      String? metaTitle;
      String? metaArtist;
      String? metaAlbum;
      Duration? metaDuration;

      try {
        final audioFile = File(filePath);
        final metadata = readMetadata(audioFile, getImage: false);
        if (metadata.title != null && metadata.title!.trim().isNotEmpty) {
          metaTitle = metadata.title!.trim();
        }
        if (metadata.artist != null && metadata.artist!.trim().isNotEmpty) {
          metaArtist = metadata.artist!.trim();
        }
        if (metadata.album != null && metadata.album!.trim().isNotEmpty) {
          metaAlbum = metadata.album!.trim();
        }
        if (metadata.duration != null && metadata.duration! > Duration.zero) {
          metaDuration = metadata.duration;
        }
      } catch (_) {}

      // Fall back to parsing filename if title/artist not fully extracted
      final fileName = filePath.split(Platform.pathSeparator).last;
      final nameWithoutExt = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');

      String title = metaTitle ?? '';
      String artist = metaArtist ?? '';

      if (title.isEmpty || artist.isEmpty) {
        if (nameWithoutExt.contains(' - ')) {
          final parts = nameWithoutExt.split(' - ');
          if (artist.isEmpty) artist = parts[0].trim();
          if (title.isEmpty) title = parts.sublist(1).join(' - ').trim();
        } else {
          if (title.isEmpty) title = nameWithoutExt;
          if (artist.isEmpty) artist = 'Unknown Artist';
        }
      }

      final id = 'local_${filePath.hashCode}';

      return Track(
        id: id,
        title: title,
        artist: artist,
        album: metaAlbum,
        duration: metaDuration ?? const Duration(minutes: 3),
        thumbnailUrl: null,
        localFilePath: filePath,
      );
    } catch (e) {
      return null;
    }
  }

  /// Scan all registered folders
  static Future<List<Track>> scanAllFolders(
    List<String> folders, {
    void Function(int scanned, int total, String current)? onProgress,
  }) async {
    final allTracks = <Track>[];

    for (final folder in folders) {
      final tracks = await scanDirectory(folder, onProgress: onProgress);
      allTracks.addAll(tracks);
    }

    return allTracks;
  }
}

TrackEntity _trackToEntity(Track track) {
  return TrackEntity(
    id: track.id,
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: track.duration.inMilliseconds,
    thumbnailUrl: track.thumbnailUrl,
    isExplicit: track.isExplicit,
    isLiked: track.isLiked,
    addedAt: track.addedAt,
    localFilePath: track.localFilePath,
  );
}

Track _trackFromEntity(TrackEntity entity) {
  return Track(
    id: entity.id,
    title: entity.title,
    artist: entity.artist,
    album: entity.album,
    duration: Duration(milliseconds: entity.duration),
    thumbnailUrl: entity.thumbnailUrl,
    isExplicit: entity.isExplicit,
    isLiked: entity.isLiked,
    addedAt: entity.addedAt,
    localFilePath: entity.localFilePath,
  );
}

String _normalizePath(String path) {
  return path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
}

/// Request data for isolate file discovery
class _ScanRequest {
  final String path;
  final List<String> extensions;

  _ScanRequest({required this.path, required this.extensions});
}

/// Top-level function for compute() - discovers audio files in a directory
/// Must be top-level to work with compute()
List<String> _discoverAudioFilesIsolate(_ScanRequest request) {
  final filePaths = <String>[];
  final directory = Directory(request.path);

  try {
    // Synchronous recursive listing (runs in isolate, won't block UI)
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        final ext = entity.path.toLowerCase();
        if (request.extensions.any((e) => ext.endsWith(e))) {
          filePaths.add(entity.path);
        }
      }
    }
  } catch (e) {
    // Silently handle permission errors for inaccessible directories
  }

  return filePaths;
}
