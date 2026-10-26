import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import 'debug_providers.dart';
import 'pose_recording_store.dart';
import 'pose_replay.dart';

/// Records the debug viewer's poses and replays saved files into it.
///
/// Recording is taken from [debugPosesProvider], so the file contains the same
/// fused [ControllerPose]s the viewer shows plus the tracking frame that
/// positioned them. Stopping a recording loads it into replay immediately, so
/// the round trip is visible without a second action.
class PoseRecorderPanel extends ConsumerStatefulWidget {
  const PoseRecorderPanel({super.key, required this.source});

  final DebugSource source;

  @override
  ConsumerState<PoseRecorderPanel> createState() => _PoseRecorderPanelState();
}

class _PoseRecorderPanelState extends ConsumerState<PoseRecorderPanel> {
  PoseRecordingBuilder? _builder;
  String? _lastSaved;

  bool get _recording => _builder != null;

  void _capture(PoseRecordingBuilder builder, DebugPoses? poses) {
    if (poses == null) return;
    final time =
        poses.left?.hostTimeNs ??
        poses.right?.hostTimeNs ??
        poses.tracking?.hostTimeNs;
    if (time == null) return;
    builder.add(
      hostTimeNs: time,
      left: poses.left,
      right: poses.right,
      tracking: poses.tracking,
    );
  }

  void _start() {
    final builder = PoseRecordingBuilder();
    _capture(builder, ref.read(debugPosesProvider(widget.source)).value);
    setState(() => _builder = builder);
  }

  Future<void> _stop() async {
    final builder = _builder;
    if (builder == null) return;
    final recording = builder.build();
    setState(() => _builder = null);
    if (recording.isEmpty) {
      _message('Nothing recorded');
      return;
    }
    ref.read(poseReplayProvider.notifier).load(recording);
    try {
      final store = await ref.read(poseRecordingStoreProvider.future);
      final file = await store.save(recording, DateTime.now());
      if (!mounted) return;
      setState(() => _lastSaved = file.uri.pathSegments.last);
      _message(
        'Saved ${recording.samples.length} samples to ${file.uri.pathSegments.last}',
      );
    } on Object catch (error) {
      if (!mounted) return;
      _message('Recording kept in memory; file write failed: $error');
    }
  }

  Future<void> _openFile() async {
    try {
      final store = await ref.read(poseRecordingStoreProvider.future);
      final files = store.list();
      if (!mounted) return;
      if (files.isEmpty) {
        _message('No pose recordings in ${store.directory.path}');
        return;
      }
      final file = await showDialog<File>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Replay pose recording'),
          children: [
            for (final file in files)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(file),
                child: Text(file.uri.pathSegments.last),
              ),
          ],
        ),
      );
      if (file == null || !mounted) return;
      final recording = await store.load(file);
      if (!mounted) return;
      ref.read(poseReplayProvider.notifier).load(recording);
      _message('Replaying ${recording.samples.length} samples');
    } on PoseRecordingException catch (error) {
      if (!mounted) return;
      _message('Not a pose recording: ${error.message}');
    } on Object catch (error) {
      if (!mounted) return;
      _message('Could not read recording: $error');
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(debugPosesProvider(widget.source), (_, next) {
      final builder = _builder;
      if (builder != null) _capture(builder, next.value);
    });
    final replay = ref.watch(poseReplayProvider);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Pose recording', style: theme.textTheme.titleMedium),
            const Spacer(),
            if (_lastSaved != null)
              Flexible(
                child: Text(
                  _lastSaved!,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_recording)
              FilledButton.icon(
                key: const ValueKey('pose-stop-button'),
                onPressed: _stop,
                icon: const Icon(Icons.stop),
                label: Text('Stop (${_builder!.length})'),
              )
            else
              FilledButton.tonalIcon(
                key: const ValueKey('pose-record-button'),
                onPressed: replay.active ? null : _start,
                icon: const Icon(Icons.fiber_manual_record),
                label: const Text('Record'),
              ),
            OutlinedButton.icon(
              key: const ValueKey('pose-load-button'),
              onPressed: _recording ? null : _openFile,
              icon: const Icon(Icons.folder_open),
              label: const Text('Replay file...'),
            ),
            if (replay.active) ...[
              IconButton(
                key: const ValueKey('pose-replay-play'),
                tooltip: replay.playing ? 'Pause replay' : 'Play replay',
                onPressed: replay.recording!.isEmpty
                    ? null
                    : () => ref.read(poseReplayProvider.notifier).toggle(),
                icon: Icon(replay.playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: 'Previous sample',
                onPressed: () => ref.read(poseReplayProvider.notifier).step(-1),
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: 'Next sample',
                onPressed: () => ref.read(poseReplayProvider.notifier).step(1),
                icon: const Icon(Icons.skip_next),
              ),
              IconButton(
                key: const ValueKey('pose-replay-close'),
                tooltip: 'Stop replay',
                onPressed: () => ref.read(poseReplayProvider.notifier).clear(),
                icon: const Icon(Icons.close),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          replay.active
              ? 'REPLAY ${replay.index + 1} / ${replay.total}  '
                    't=${(replay.offset.inMicroseconds / 1000000).toStringAsFixed(3)} s'
              : _recording
              ? 'Recording ${_builder!.length} samples'
              : 'Record the viewer, or replay a saved versioned JSON file.',
          key: const ValueKey('pose-replay-status'),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
