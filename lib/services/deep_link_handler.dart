import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../main.dart';
import '../models/track.dart';
import '../providers/music_providers.dart';
import '../providers/ytmusic_providers.dart';
import '../screens/widgets/playlist_screen.dart';
import '../screens/widgets/artist_screen.dart';
import '../screens/widgets/album_screen.dart';
import '../screens/widgets/now_playing_screen.dart';

class DeepLinkHandler {
  static final DeepLinkHandler instance = DeepLinkHandler._();
  DeepLinkHandler._();

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  bool _isInitialized = false;

  void initialize(BuildContext context, WidgetRef ref) {
    if (_isInitialized) return;
    _isInitialized = true;
    _appLinks = AppLinks();

    // Handle incoming links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen((Uri? uri) {
      if (uri != null) {
        _handleDeepLink(uri, ref);
      }
    }, onError: (err) {
      debugPrint('Error handling deep link: $err');
    });

    // Handle initial link if app was launched from a link
    _appLinks.getInitialLink().then((Uri? uri) {
      if (uri != null) {
        // Wait for rootNavigatorKey context to be mounted & ready
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleDeepLink(uri, ref);
        });
      }
    });
  }

  void _handleDeepLink(Uri uri, WidgetRef ref) {
    debugPrint('DeepLinkHandler: Received link -> $uri');

    // 1. Custom scheme: inzx://open/<type>?id=<id>
    if (uri.scheme == 'inzx' && uri.host == 'open') {
      final pathSegments = uri.pathSegments;
      if (pathSegments.isEmpty) return;

      final type = pathSegments.first; // 'playlist', 'album', 'artist', 'song'
      final id = uri.queryParameters['id'];

      if (id == null || id.isEmpty) return;

      _navigateToItem(type, id, ref);
      return;
    }

    // 2. GitHub Pages redirect URL: https://nirmaleeswar30.github.io/Inzx/redirect.html?url=...
    if (uri.host.contains('github.io') && uri.queryParameters.containsKey('url')) {
      final rawUrlParam = uri.queryParameters['url']!;
      final decodedString = _decodeBase64Url(rawUrlParam);
      if (decodedString != null) {
        try {
          final decodedUri = Uri.parse(decodedString);
          _handleDeepLink(decodedUri, ref);
          return;
        } catch (e) {
          debugPrint('Error parsing decoded deep link URI: $e');
        }
      }
    }
  }

  void _navigateToItem(String type, String id, WidgetRef ref) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) {
      debugPrint('DeepLinkHandler: rootNavigatorKey.currentContext is null');
      return;
    }

    switch (type) {
      case 'playlist':
        PlaylistScreen.open(context, playlistId: id);
        break;
      case 'album':
        AlbumScreen.open(context, albumId: id);
        break;
      case 'artist':
        ArtistScreen.open(context, artistId: id);
        break;
      case 'song':
      case 'track':
      case 'video':
        _handleSongDeepLink(id, ref);
        break;
      default:
        debugPrint('Unknown deep link type: $type');
    }
  }

  Future<void> _handleSongDeepLink(String songId, WidgetRef ref) async {
    try {
      debugPrint('DeepLinkHandler: Loading target song $songId...');

      final messenger = rootScaffoldMessengerKey.currentState;
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Opening shared song...'),
          duration: Duration(seconds: 2),
        ),
      );

      final ytService = ref.read(innerTubeServiceProvider);
      Track? targetTrack = await ytService.getSongDetails(songId);

      targetTrack ??= Track(
        id: songId,
        title: 'Shared Song',
        artist: 'YouTube Music',
        thumbnailUrl: 'https://img.youtube.com/vi/$songId/hqdefault.jpg',
        duration: Duration.zero,
      );

      final playerService = ref.read(audioPlayerServiceProvider);
      await playerService.playTrack(targetTrack, enableRadio: true);

      final context = rootNavigatorKey.currentContext;
      if (context != null && context.mounted) {
        NowPlayingScreen.show(context);
      }
    } catch (e, stack) {
      debugPrint('Error loading deep linked song $songId: $e\n$stack');
    }
  }

  static String? _decodeBase64Url(String raw) {
    try {
      String normalized = Uri.decodeComponent(raw).replaceAll(' ', '+');
      switch (normalized.length % 4) {
        case 2:
          normalized += '==';
          break;
        case 3:
          normalized += '=';
          break;
      }
      final bytes = base64.decode(normalized);
      return utf8.decode(bytes);
    } catch (e) {
      debugPrint('Base64 decode error: $e');
      return null;
    }
  }

  void dispose() {
    _linkSubscription?.cancel();
  }

  /// When true, [createShareUrl] returns the native YouTube Music link instead
  /// of an Inzx deep link. Kept in sync with the user's setting by
  /// [ShareNativeLinksNotifier].
  static bool useNativeYtMusicLinks = false;

  static const String shareNativeLinksPrefKey =
      'inzx_share_native_ytmusic_links';

  /// Build a plain YouTube Music URL for a shared item, or null for a type
  /// that has no direct equivalent.
  static String? nativeYtMusicUrl(String type, String id) {
    switch (type) {
      case 'song':
        return 'https://music.youtube.com/watch?v=$id';
      case 'playlist':
        final list = id.startsWith('VL') ? id.substring(2) : id;
        return 'https://music.youtube.com/playlist?list=$list';
      case 'album':
        return 'https://music.youtube.com/browse/$id';
      case 'artist':
        return 'https://music.youtube.com/channel/$id';
    }
    return null;
  }

  /// Creates a share URL for the given item.
  /// [type] should be 'playlist', 'album', 'artist', or 'song'.
  ///
  /// Returns a native YouTube Music link when the user has opted out of Inzx
  /// deep links; otherwise a base64 redirect that opens the item in Inzx.
  static String createShareUrl(String type, String id) {
    if (useNativeYtMusicLinks) {
      final native = nativeYtMusicUrl(type, id);
      if (native != null) return native;
    }

    final deepLink = 'inzx://open/$type?id=$id';
    final bytes = utf8.encode(deepLink);
    final base64DeepLink = base64.encode(bytes);

    // Fallback to github pages redirect url
    final baseUrl = 'https://nirmaleeswar30.github.io/Inzx/redirect.html';
    return '$baseUrl?url=$base64DeepLink';
  }
}
