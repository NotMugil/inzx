import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/models.dart';
import '../../providers/providers.dart';
import 'podcast_video_screen.dart';

/// Dedicated screen for a podcast show: header, save/subscribe, show
/// description, and a list of episodes with rich (timestamp/link) descriptions.
class PodcastScreen extends ConsumerStatefulWidget {
  final String podcastId;
  final String? title;
  final String? thumbnailUrl;

  const PodcastScreen({
    super.key,
    required this.podcastId,
    this.title,
    this.thumbnailUrl,
  });

  static void open(
    BuildContext context, {
    required String podcastId,
    String? title,
    String? thumbnailUrl,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PodcastScreen(
          podcastId: podcastId,
          title: title,
          thumbnailUrl: thumbnailUrl,
        ),
      ),
    );
  }

  @override
  ConsumerState<PodcastScreen> createState() => _PodcastScreenState();
}

class _PodcastScreenState extends ConsumerState<PodcastScreen> {
  bool? _savedOverride; // optimistic save state
  bool _descExpanded = false;

  Future<void> _playEpisode(Podcast podcast, int index) async {
    final player = ref.read(audioPlayerServiceProvider);
    final tracks = podcast.episodes.map((e) => e.toTrack()).toList();
    await player.playQueue(
      tracks,
      startIndex: index,
      sourceId: podcast.id,
      sourceTitle: podcast.title,
    );
  }

  Future<void> _seekWithinEpisode(Episode ep, Duration position) async {
    final player = ref.read(audioPlayerServiceProvider);
    final current = ref.read(currentTrackProvider);
    if (current?.id == ep.videoId) {
      await player.seek(position);
    } else {
      await player.playQueue([ep.toTrack()], sourceId: ep.podcastId);
      // Best-effort: seek once the stream has had a moment to load.
      await Future.delayed(const Duration(milliseconds: 700));
      await player.seek(position);
    }
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _toggleSave(Podcast podcast) async {
    final current = _savedOverride ?? podcast.saved;
    setState(() => _savedOverride = !current);
    final ok = await ref
        .read(ytMusicPodcastSaveActionProvider)
        .setSaved(podcast.id, !current);
    if (!ok && mounted) {
      setState(() => _savedOverride = current);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update library')),
      );
    }
  }

  void _openVideo(Episode ep) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PodcastVideoScreen(episode: ep)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final accent = ref.watch(effectiveAccentColorProvider);
    final textColor = isDark ? Colors.white : colorScheme.onSurface;
    final secondary = textColor.withValues(alpha: 0.6);
    final async = ref.watch(ytMusicPodcastProvider(widget.podcastId));

    return Scaffold(
      backgroundColor: isDark ? Colors.black : colorScheme.surface,
      body: async.when(
        loading: () => _scaffoldBody(
          isDark,
          textColor,
          const Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => _scaffoldBody(
          isDark,
          textColor,
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Couldn\'t load podcast.\n$e',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: secondary)),
            ),
          ),
        ),
        data: (podcast) {
          if (podcast == null) {
            return _scaffoldBody(
              isDark,
              textColor,
              Center(
                child: Text('Podcast not found',
                    style: TextStyle(color: secondary)),
              ),
            );
          }
          final saved = _savedOverride ?? podcast.saved;
          final currentTrack = ref.watch(currentTrackProvider);

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                backgroundColor: Colors.transparent,
                elevation: 0,
                iconTheme: IconThemeData(color: textColor),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Cover
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 190,
                          height: 190,
                          child: (podcast.thumbnailUrl ?? widget.thumbnailUrl) !=
                                  null
                              ? CachedNetworkImage(
                                  imageUrl: (podcast.thumbnailUrl ??
                                      widget.thumbnailUrl)!,
                                  fit: BoxFit.cover,
                                )
                              : Container(
                                  color: isDark
                                      ? Colors.grey[850]
                                      : Colors.grey[300],
                                  child: Icon(Icons.podcasts_rounded,
                                      size: 64, color: secondary),
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        podcast.title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (podcast.author != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          podcast.author!,
                          style: TextStyle(color: secondary, fontSize: 14),
                        ),
                      ],
                      const SizedBox(height: 16),
                      // Actions: Play latest + Save
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: podcast.episodes.isEmpty
                                ? null
                                : () => _playEpisode(podcast, 0),
                            style: FilledButton.styleFrom(
                              backgroundColor: accent,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 22, vertical: 12),
                            ),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Play latest'),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: () => _toggleSave(podcast),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: saved ? accent : textColor,
                              side: BorderSide(
                                color: saved
                                    ? accent
                                    : textColor.withValues(alpha: 0.3),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 12),
                            ),
                            icon: Icon(saved
                                ? Icons.check_rounded
                                : Icons.add_rounded),
                            label: Text(saved ? 'Saved' : 'Save'),
                          ),
                        ],
                      ),
                      if (podcast.description != null &&
                          podcast.description!.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: GestureDetector(
                            onTap: () => setState(
                                () => _descExpanded = !_descExpanded),
                            child: _RichDescription(
                              text: podcast.description!,
                              color: secondary,
                              linkColor: accent,
                              maxLines: _descExpanded ? null : 3,
                              onLink: _openLink,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Episodes',
                          style: TextStyle(
                            color: textColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _EpisodeTile(
                    episode: podcast.episodes[index],
                    isPlaying: currentTrack?.id ==
                        podcast.episodes[index].videoId,
                    isDark: isDark,
                    textColor: textColor,
                    secondary: secondary,
                    accent: accent,
                    onPlay: () => _playEpisode(podcast, index),
                    onWatch: () => _openVideo(podcast.episodes[index]),
                    onSeek: (pos) =>
                        _seekWithinEpisode(podcast.episodes[index], pos),
                    onLink: _openLink,
                    onQueue: () {
                      ref
                          .read(audioPlayerServiceProvider)
                          .addToQueue([podcast.episodes[index].toTrack()]);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Added to queue'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  childCount: podcast.episodes.length,
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
            ],
          );
        },
      ),
    );
  }

  Widget _scaffoldBody(bool isDark, Color textColor, Widget child) {
    return SafeArea(
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: Icon(Icons.arrow_back, color: textColor),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _EpisodeTile extends StatefulWidget {
  final Episode episode;
  final bool isPlaying;
  final bool isDark;
  final Color textColor;
  final Color secondary;
  final Color accent;
  final VoidCallback onPlay;
  final VoidCallback onWatch;
  final VoidCallback onQueue;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<String> onLink;

  const _EpisodeTile({
    required this.episode,
    required this.isPlaying,
    required this.isDark,
    required this.textColor,
    required this.secondary,
    required this.accent,
    required this.onPlay,
    required this.onWatch,
    required this.onQueue,
    required this.onSeek,
    required this.onLink,
  });

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: widget.onPlay,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 96,
                    height: 60,
                    child: ep.thumbnailUrl != null
                        ? CachedNetworkImage(
                            imageUrl: ep.thumbnailUrl!,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            color: widget.isDark
                                ? Colors.grey[850]
                                : Colors.grey[300]),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ep.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            widget.isPlaying ? widget.accent : widget.textColor,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [ep.subtitle, ep.durationText]
                          .where((e) => e != null && e.isNotEmpty)
                          .join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: widget.secondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (ep.progress > 0.01)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: ep.progress,
                  minHeight: 3,
                  backgroundColor: widget.textColor.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation(widget.accent),
                ),
              ),
            ),
          // Action row
          Row(
            children: [
              _actionChip(
                Icons.play_arrow_rounded,
                'Play',
                widget.onPlay,
              ),
              _actionChip(
                Icons.smart_display_outlined,
                'Video',
                widget.onWatch,
              ),
              _actionChip(
                Icons.add_to_queue_rounded,
                'Queue',
                widget.onQueue,
              ),
              const Spacer(),
              if (ep.description != null && ep.description!.isNotEmpty)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: widget.secondary,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
            ],
          ),
          if (_expanded && ep.description != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: _RichDescription(
                text: ep.description!,
                color: widget.secondary,
                linkColor: widget.accent,
                maxLines: null,
                onLink: widget.onLink,
                onTimestamp: widget.onSeek,
              ),
            ),
          Divider(
            height: 20,
            color: widget.textColor.withValues(alpha: 0.08),
          ),
        ],
      ),
    );
  }

  Widget _actionChip(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: TextButton.icon(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: widget.secondary,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}

/// Renders a description with tappable timestamps (seek) and URLs (open).
class _RichDescription extends StatelessWidget {
  final String text;
  final Color color;
  final Color linkColor;
  final int? maxLines;
  final ValueChanged<String> onLink;
  final ValueChanged<Duration>? onTimestamp;

  const _RichDescription({
    required this.text,
    required this.color,
    required this.linkColor,
    required this.maxLines,
    required this.onLink,
    this.onTimestamp,
  });

  static final _pattern = RegExp(
    r'(https?:\/\/[^\s]+)|(\b\d{1,2}:\d{2}(?::\d{2})?\b)',
  );

  Duration _parseTimestamp(String t) {
    final parts = t.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.length == 3) {
      return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
    }
    return Duration(minutes: parts[0], seconds: parts[1]);
  }

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(color: color, fontSize: 13, height: 1.4);
    final spans = <InlineSpan>[];
    int last = 0;
    for (final m in _pattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final matched = m.group(0)!;
      final isUrl = m.group(1) != null;
      if (isUrl) {
        spans.add(TextSpan(
          text: matched,
          style: TextStyle(color: linkColor, decoration: TextDecoration.underline),
          recognizer: (TapGestureRecognizer()..onTap = () => onLink(matched)),
        ));
      } else if (onTimestamp != null) {
        spans.add(TextSpan(
          text: matched,
          style: TextStyle(color: linkColor, fontWeight: FontWeight.w600),
          recognizer: (TapGestureRecognizer()
            ..onTap = () => onTimestamp!(_parseTimestamp(matched))),
        ));
      } else {
        // Timestamp without a seek handler (show description) — plain accent.
        spans.add(TextSpan(text: matched, style: TextStyle(color: linkColor)));
      }
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }

    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow:
          maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}
