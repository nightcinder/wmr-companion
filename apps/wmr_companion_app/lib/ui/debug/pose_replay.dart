import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// One step of the debug screen's recorded-pose playback.
class PoseReplayState {
  const PoseReplayState({
    this.recording,
    this.index = 0,
    this.offset = Duration.zero,
    this.playing = false,
  });

  final PoseRecording? recording;
  final int index;

  /// Position in the recording, measured from its first sample.
  final Duration offset;
  final bool playing;

  bool get active => recording != null;

  int get total => recording?.samples.length ?? 0;

  PoseRecordingSample? get sample {
    final value = recording;
    if (value == null || value.samples.isEmpty) return null;
    return value.samples[index.clamp(0, value.samples.length - 1)];
  }

  PoseReplayState copyWith({int? index, Duration? offset, bool? playing}) =>
      PoseReplayState(
        recording: recording,
        index: index ?? this.index,
        offset: offset ?? this.offset,
        playing: playing ?? this.playing,
      );
}

/// Loads a [PoseRecording] and steps it through the viewer at 30 Hz.
///
/// Playback advances by a fixed tick rather than wall-clock time, so a replay
/// is deterministic in tests and on a device. [load] stops any running replay.
class PoseReplay extends Notifier<PoseReplayState> {
  static const Duration tick = Duration(milliseconds: 33);

  Timer? _timer;

  @override
  PoseReplayState build() {
    ref.onDispose(_stopTimer);
    return const PoseReplayState();
  }

  void load(PoseRecording recording) {
    _stopTimer();
    state = PoseReplayState(recording: recording, playing: false);
  }

  void clear() {
    _stopTimer();
    state = const PoseReplayState();
  }

  void play() {
    final recording = state.recording;
    if (recording == null || recording.isEmpty) return;
    if (state.index >= recording.samples.length - 1 &&
        state.offset >= recording.duration) {
      _seek(Duration.zero);
    }
    state = state.copyWith(playing: true);
    _timer?.cancel();
    _timer = Timer.periodic(tick, (_) => _advance());
  }

  void pause() {
    _stopTimer();
    state = state.copyWith(playing: false);
  }

  void toggle() => state.playing ? pause() : play();

  /// Moves by [steps] recorded samples, pausing playback.
  void step(int steps) {
    final recording = state.recording;
    if (recording == null || recording.isEmpty) return;
    _stopTimer();
    final next = (state.index + steps).clamp(0, recording.samples.length - 1);
    final sample = recording.samples[next];
    state = state.copyWith(
      index: next,
      offset: Duration(
        microseconds: ((sample.hostTimeNs - recording.originNs) / 1000).round(),
      ),
      playing: false,
    );
  }

  void _advance() {
    final recording = state.recording;
    if (recording == null || recording.isEmpty) {
      _stopTimer();
      return;
    }
    final next = state.offset + tick;
    if (next >= recording.duration) {
      _stopTimer();
      final last = recording.samples.length - 1;
      state = state.copyWith(
        index: last,
        offset: recording.duration,
        playing: false,
      );
      return;
    }
    final sample = recording.sampleAt(next);
    final index = sample == null
        ? state.index
        : recording.samples.indexOf(sample);
    state = state.copyWith(index: index, offset: next);
  }

  void _seek(Duration offset) {
    final recording = state.recording;
    final sample = recording?.sampleAt(offset);
    state = state.copyWith(
      index: sample == null ? 0 : recording!.samples.indexOf(sample),
      offset: offset,
      playing: false,
    );
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }
}

final poseReplayProvider = NotifierProvider<PoseReplay, PoseReplayState>(
  PoseReplay.new,
);
