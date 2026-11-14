import 'dart:math' as math;
import 'dart:typed_data';

import 'package:revoockv_audio_enhance/revoockv_audio_enhance.dart';
import 'package:test/test.dart';

void main() {
  const int rate = 48000;
  final math.Random random = math.Random(3);
  final PcmAudio take = PcmAudio(
    samples: <Float64List>[
      SampleOps.generate(
        rate * 20,
        (int i) => 0.2 * math.sin(i / 20.0) * math.sin(i / rate).abs() + 0.002 * (random.nextDouble() - 0.5),
      ),
    ],
    sampleRate: rate,
  );
  final VocalEnhancer enhancer = VocalEnhancer();

  test('enhanceTask streams progress in order and gives the same result as enhance', () async {
    final AudioTask<EnhanceResult> task = enhancer.enhanceTask(take);
    final List<AudioProgress> seen = <AudioProgress>[];
    task.progress.listen(seen.add);
    final EnhanceResult background = await task.result;
    final EnhanceResult here = enhancer.enhance(take);

    expect(background.audio.samples.first, here.audio.samples.first);
    expect(task.isDone, isTrue);
    expect(seen.first.step, 1);
    expect(seen.last.step, seen.last.steps);
    expect(seen.where((AudioProgress p) => p.label == 'Reducing noise' && p.stepFraction > 0), isNotEmpty);
    for (int i = 1; i < seen.length; i++) {
      expect(seen[i].fraction, greaterThanOrEqualTo(seen[i - 1].fraction));
    }
  });

  test('the progress stream closes when the work ends', () async {
    final AudioTask<EnhanceResult> task = enhancer.enhanceTask(take, settings: EnhancePreset.loudnessOnly.settings);
    await expectLater(task.progress, emitsThrough(emitsDone));
    await task.result;
  });

  test('enhanceAsync and analyzeAsync work without watching progress', () async {
    final EnhanceResult result = await enhancer.enhanceAsync(take, settings: EnhancePreset.studio.settings);
    expect(result.after.integratedLufs, closeTo(-14, 0.5));
    final RecordingAnalysis analysis = await enhancer.analyzeAsync(take);
    expect(analysis.durationSeconds, 20);
  });

  test('the sync call reports progress through the callback', () {
    final List<AudioProgress> seen = <AudioProgress>[];
    enhancer.enhance(take, onProgress: seen.add);
    expect(seen.map((AudioProgress p) => p.step).toSet(), hasLength(seen.first.steps));
  });

  test('cancel stops the task and fails the result', () async {
    final AudioTask<EnhanceResult> task = enhancer.enhanceTask(take);
    await task.progress.first;
    task.cancel();
    await expectLater(task.result, throwsA(isA<AudioTaskCancelledException>()));
    expect(task.isDone, isTrue);
  });

  test('any tool runs in the background with its own progress', () async {
    final AudioTask<Samples> task = AudioTask<Samples>.start(
      (AudioProgressListener report) => const NoiseReducer().reduce(
        take.samples,
        take.sampleRate,
        reductionDb: 16,
        sensitivity: 1.5,
        profileSeconds: 0,
        onProgress: (double part) => report(AudioProgress.single('Reducing noise', part)),
      ),
    );
    final List<double> fractions = <double>[];
    task.progress.listen((AudioProgress p) => fractions.add(p.fraction));
    final Samples cleaned = await task.result;
    expect(cleaned.first.length, take.frames);
    expect(fractions, isNotEmpty);
  });

  test('errors of the work reach the result', () async {
    final AudioTask<int> task = AudioTask<int>.start((AudioProgressListener report) => throw StateError('boom'));
    await expectLater(task.result, throwsA(isA<StateError>()));
  });
}
