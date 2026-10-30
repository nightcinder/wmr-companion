import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import '../tool/src/pose_capture_prepare.dart';
import '../tool/src/pose_filter_tuning.dart';

/// Segment ids the guided bench writes, in its order.
const List<String> _segments = [
  'still',
  'drifting',
  'slow_pan',
  'medium_pan',
  'fast_flick',
  'occlusion',
];

int _runFor(String segment) => segment == 'occlusion' ? 1 : 4;

PoseRecording _recording({
  required TrackingVendor runtime,
  required TrackedHand hand,
  required String segment,
  int run = 1,
  int samples = 5,
  Duration span = const Duration(seconds: 30),
  bool withProvenance = true,
}) {
  final frames = <TrackingFrame>[];
  final stepNs = samples > 1 ? span.inMicroseconds * 1000 ~/ (samples - 1) : 0;
  for (var index = 0; index < samples; index++) {
    final time = 1000000000 + index * stepNs;
    final pose = TrackedPose(
      pose: Pose(
        translation: Vector3(0.2 + index * 0.001, -0.25, -0.35),
        rotation: Quaternion.identity(),
      ),
    );
    frames.add(
      TrackingFrame(
        timeNs: time,
        hostTimeNs: time,
        leftHand: hand == TrackedHand.left
            ? HandPose(hand: hand, palm: pose)
            : null,
        rightHand: hand == TrackedHand.right
            ? HandPose(hand: hand, palm: pose)
            : null,
      ),
    );
  }
  return PoseRecording(
    samples: [
      for (final frame in frames)
        PoseRecordingSample(hostTimeNs: frame.hostTimeNs!, tracking: frame),
    ],
    provenance: withProvenance
        ? {
            'kind': 'hardware',
            'runtime': runtime.name,
            'hand': hand.name.toUpperCase(),
            'motion': segment,
            'run_index': run,
            'app_commit': 'abc1234',
            'firmware_sha': 'def5678',
            'anchor_rate_hz': 90.0,
            'seconds': span.inSeconds,
          }
        : const {},
  );
}

RecordingInput _input({
  required TrackingVendor runtime,
  required TrackedHand hand,
  required String segment,
  int run = 1,
  bool withProvenance = true,
}) => RecordingInput(
  fileName:
      'pose_capture_${runtime.name}_${hand.name}_$segment'
      '${run > 1 ? '_run$run' : ''}.json',
  recording: _recording(
    runtime: runtime,
    hand: hand,
    segment: segment,
    run: run,
    withProvenance: withProvenance,
  ),
);

List<RecordingInput> _corpus() => [
  for (final hand in TrackedHand.values)
    for (final segment in _segments)
      for (var run = 1; run <= _runFor(segment); run++)
        _input(
          runtime: TrackingVendor.viture,
          hand: hand,
          segment: segment,
          run: run,
        ),
];

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pose-capture-prepare-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('converts and splits a complete corpus by runtime, hand and motion', () {
    final corpus = prepareCorpus(
      _corpus(),
      plan: const PoseCorpusPlan(runsPerClass: 4),
    );

    expect(corpus.isComplete, isTrue);
    expect(corpus.captures, hasLength(42));
    expect(corpus.paths, contains('viture/right/mediumPan/run4.json'));
    expect(corpus.paths, contains('viture/left/occlusion/run1.json'));

    final slow = corpus.captures.singleWhere(
      (prepared) => prepared.relativePath == 'viture/left/slowPan/run2.json',
    );
    expect(slow.capture.runtime, TrackingVendor.viture);
    expect(slow.capture.motion, PoseMotion.slowPan);
    expect(slow.capture.run, 2);
    expect(slow.capture.samples, hasLength(5));
    expect(slow.capture.samples.first.position.x, closeTo(0.2, 1e-9));
    expect(slow.capture.provenance['hand'], 'LEFT');
    expect(slow.capture.provenance['source_file'], startsWith('pose_capture_'));
    expect(
      slow.capture.provenance['prepared_by'],
      'tool/pose_capture_prepare.dart',
    );

    corpus.writeTo(temp);
    final written = File('${temp.path}/viture/left/mediumPan/run3.json');
    expect(written.existsSync(), isTrue);
    final decoded = PoseCapture.decode(written.readAsStringSync());
    expect(PoseCapture.format, 'wmr-pose-capture');
    expect(decoded.motion, PoseMotion.mediumPan);
    expect(decoded.run, 3);
    expect(decoded.appCommit, 'abc1234');
    expect(decoded.firmwareSha, 'def5678');

    final coverage = File('${temp.path}/coverage.md').readAsStringSync();
    expect(coverage, contains('| viture | left | 4/4 | 4/4 |'));
    expect(coverage, contains('4/4 | 1/1 |'));
  });

  test('refuses an incomplete corpus and names the missing cell', () async {
    final captures = Directory('${temp.path}/captures')..createSync();
    final corpus = [
      for (final hand in TrackedHand.values)
        for (final segment in _segments)
          for (var run = 1; run <= _runFor(segment); run++)
            if (!(hand == TrackedHand.right &&
                segment == 'medium_pan' &&
                run == 4))
              (hand: hand, segment: segment, run: run),
    ];
    for (final cell in corpus) {
      final name =
          'pose_capture_viture_${cell.hand.name}_${cell.segment}'
          '${cell.run > 1 ? '_run${cell.run}' : ''}.json';
      File('${captures.path}/$name').writeAsStringSync(
        _recording(
          runtime: TrackingVendor.viture,
          hand: cell.hand,
          segment: cell.segment,
          run: cell.run,
        ).encode(),
      );
    }

    final out = Directory('${temp.path}/out');
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/pose_capture_prepare.dart',
      '--captures',
      captures.path,
      '--out',
      out.path,
    ], workingDirectory: Directory.current.path);

    expect(result.exitCode, 1, reason: '${result.stderr}');
    expect(result.stderr, contains('viture/right/mediumPan: 3 of 4 runs'));
    expect(result.stdout, contains('**missing**'));
    // Nothing is written for a refused corpus.
    final written = out.existsSync()
        ? out.listSync(recursive: true).whereType<File>()
        : const <File>[];
    expect(written, isEmpty);
  });

  test('refuses a complete cell whose run is shorter than 30 s', () {
    final inputs = [
      for (final input in _corpus())
        if (input.fileName == 'pose_capture_viture_right_medium_pan_run2.json')
          RecordingInput(
            fileName: input.fileName,
            recording: _recording(
              runtime: TrackingVendor.viture,
              hand: TrackedHand.right,
              segment: 'medium_pan',
              run: 2,
              span: const Duration(seconds: 5),
            ),
          )
        else
          input,
    ];

    final corpus = prepareCorpus(inputs);

    expect(corpus.isComplete, isFalse);
    expect(
      corpus.missingCells,
      contains('viture/right/mediumPan: 3 of 4 runs'),
    );
    expect(
      corpus.missingCells,
      contains('viture/right/mediumPan: run 2 is 5.0 s, needs 30 s'),
    );
    expect(corpus.coverage.toMarkdown(), contains('3/4 **missing**'));
  });

  test('accepts a run a frame short of 30 s and does not time occlusion', () {
    final inputs = [
      for (final input in _corpus())
        if (input.fileName ==
            'pose_capture_viture_right_medium_pan_run2.json')
          RecordingInput(
            fileName: input.fileName,
            recording: _recording(
              runtime: TrackingVendor.viture,
              hand: TrackedHand.right,
              segment: 'medium_pan',
              run: 2,
              span: const Duration(milliseconds: 29900),
            ),
          )
        else if (input.fileName ==
            'pose_capture_viture_left_occlusion.json')
          RecordingInput(
            fileName: input.fileName,
            recording: _recording(
              runtime: TrackingVendor.viture,
              hand: TrackedHand.left,
              segment: 'occlusion',
              span: const Duration(seconds: 5),
            ),
          )
        else
          input,
    ];

    final corpus = prepareCorpus(inputs);

    expect(corpus.isComplete, isTrue);
    expect(corpus.missingCells, isEmpty);
    expect(
      corpus.coverage.runs(
        TrackingVendor.viture,
        TrackedHand.right,
        PoseMotion.mediumPan,
      ),
      4,
    );
  });

  test('refuses a file name that asks for run 0', () {
    expect(
      labelsFromFileName('pose_capture_viture_right_still_run0.json'),
      isNull,
    );
    expect(labelsFromFileName('pose_capture_viture_right_still.json')?.run, 1);
  });

  test('skips debug-screen recordings that cannot be placed in a cell', () {
    final directory = Directory('${temp.path}/phone')..createSync();
    final placeable = _input(
      runtime: TrackingVendor.viture,
      hand: TrackedHand.right,
      segment: 'fast_flick',
    );
    File('${directory.path}/${placeable.fileName}')
        .writeAsStringSync(placeable.recording.encode());
    File('${directory.path}/pose-20261030T120000.json').writeAsStringSync(
      _recording(
        runtime: TrackingVendor.viture,
        hand: TrackedHand.right,
        segment: 'still',
        withProvenance: false,
      ).encode(),
    );

    final skipped = <String>[];
    final inputs = readRecordingDirectory(directory, onSkip: skipped.add);

    expect(inputs, hasLength(1));
    expect(skipped, ['pose-20261030T120000.json']);
  });

  test('reads a tester bundle and trusts its diagnostics labels', () {
    // The file name says left/still; the bundle manifest says right, run 2 and
    // the recording holds the right hand.
    final recording = _recording(
      runtime: TrackingVendor.viture,
      hand: TrackedHand.right,
      segment: 'still',
      run: 2,
      withProvenance: false,
    );
    final diagnostics = jsonEncode({
      'format': 'wmr-test-bundle/1',
      'pose_captures': [
        {
          'file': 'pose_capture_viture_left_still.json',
          'runtime': 'viture',
          'hand': 'right',
          'segment': 'still',
          'run': 2,
          'anchor_rate_hz': 90,
        },
      ],
    });
    final archive = Archive();
    void add(String name, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('manifest.md', '# bundle\n');
    add('diagnostics.json', diagnostics);
    add('pose_capture_viture_left_still.json', recording.encode());
    final bundle = File('${temp.path}/bundle.zip')
      ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));

    final inputs = readTesterBundle(bundle);
    expect(inputs, hasLength(1));

    final prepared = prepareCorpus(
      inputs,
      plan: const PoseCorpusPlan(runsPerClass: 2),
    ).captures.single;
    // The manifest wins over the file name.
    expect(prepared.labels.hand, TrackedHand.right);
    expect(prepared.labels.run, 2);
    expect(prepared.labels.source, 'diagnostics.json');
    expect(prepared.relativePath, 'viture/right/still/run2.json');
    expect(prepared.capture.run, 2);
  });

  test('falls back to the bundle file name when provenance is missing', () {
    final input = _input(
      runtime: TrackingVendor.xreal,
      hand: TrackedHand.right,
      segment: 'fast_flick',
      run: 3,
      withProvenance: false,
    );

    final labels = resolveLabels(input);
    expect(labels.runtime, TrackingVendor.xreal);
    expect(labels.hand, TrackedHand.right);
    expect(labels.motion, PoseMotion.fastFlick);
    expect(labels.run, 3);
    expect(labels.source, 'file name');
  });
}
