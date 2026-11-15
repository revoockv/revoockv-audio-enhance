import 'dart:math' as math;
import 'dart:typed_data';

import 'package:revoockv_audio_enhance/revoockv_audio_enhance.dart';
import 'package:test/test.dart';

void main() {
  const int rate = 8000;
  const SilenceTrimmer trimmer = SilenceTrimmer();

  /// One second per level (dBFS) of a 440 Hz tone; `null` is digital silence.
  Samples take(List<double?> levels) {
    final Float64List out = Float64List(levels.length * rate);
    for (int s = 0; s < levels.length; s++) {
      final double? db = levels[s];
      if (db == null) continue;
      final double amplitude = math.sqrt2 * math.pow(10, db / 20);
      for (int i = 0; i < rate; i++) {
        out[s * rate + i] = amplitude * math.sin(2 * math.pi * 440 * i / rate);
      }
    }
    return <Float64List>[out];
  }

  test('cuts the silence around the singing', () {
    final (int start, int end) = trimmer.keptRange(
      take(<double?>[null, null, -20, -18, -20, null]),
      rate,
      paddingSeconds: 0,
    );
    expect((start / rate, end / rate), (2.0, 5.0));
  });

  test('a take that is loud all along keeps its quieter start and end', () {
    // Music from the speaker under the voice: the quietest second is only 12 dB under the loudest.
    final (int start, int end) = trimmer.keptRange(
      take(<double?>[-26, -26, -14, -14, -14, -14, -14, -14, -14, -14, -26, -26]),
      rate,
      paddingSeconds: 0,
    );
    expect((start, end), (0, 12 * rate));
  });
}
