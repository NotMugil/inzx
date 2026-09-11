import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../models/models.dart';
import '../../providers/providers.dart';

/// Plays a podcast episode as video (muxed stream) in a dedicated screen.
///
/// Video is a foreground experience: it pauses the audio player and does not
/// join the background audio queue.
class PodcastVideoScreen extends ConsumerStatefulWidget {
  final Episode episode;

  const PodcastVideoScreen({super.key, required this.episode});

  @override
  ConsumerState<PodcastVideoScreen> createState() =>
      _PodcastVideoScreenState();
}

class _PodcastVideoScreenState extends ConsumerState<PodcastVideoScreen> {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    // Don't let audio and video play at once.
    ref.read(audioPlayerServiceProvider).pause();
    _init();
  }

  Future<void> _init() async {
    try {
      final service = ref.read(innerTubeServiceProvider);
      final url = await service.getVideoStreamUrl(widget.episode.videoId);
      if (url == null) {
        setState(() {
          _loading = false;
          _error = 'No video stream available for this episode.';
        });
        return;
      }
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      controller.addListener(_onTick);
      await controller.play();
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Couldn\'t play video.\n$e';
        });
      }
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    c.value.isPlaying ? c.pause() : c.play();
  }

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          ep.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: controller?.value.aspectRatio ?? 16 / 9,
            child: Container(
              color: Colors.black,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        )
                      : GestureDetector(
                          onTap: () =>
                              setState(() => _showControls = !_showControls),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              VideoPlayer(controller!),
                              if (_showControls)
                                Container(
                                  color: Colors.black26,
                                  child: Center(
                                    child: IconButton(
                                      iconSize: 56,
                                      icon: Icon(
                                        controller.value.isPlaying
                                            ? Icons.pause_circle_filled_rounded
                                            : Icons.play_circle_fill_rounded,
                                        color: Colors.white,
                                      ),
                                      onPressed: _togglePlay,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
            ),
          ),
          if (controller != null && controller.value.isInitialized)
            VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              colors: VideoProgressColors(
                playedColor: Theme.of(context).colorScheme.primary,
                bufferedColor: Colors.white24,
                backgroundColor: Colors.white12,
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ep.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (ep.subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      ep.subtitle!,
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                  if (ep.description != null && ep.description!.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      ep.description!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
