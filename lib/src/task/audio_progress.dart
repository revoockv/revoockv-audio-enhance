/// How far a piece of work has got: the current step and how much of it is done.
final class AudioProgress {
  /// 1-based number of the current step.
  final int step;

  /// Number of steps.
  final int steps;

  /// What the step does, in English ("Reducing noise").
  final String label;

  /// Part of the current step that is done, 0.0-1.0.
  final double stepFraction;

  /// Creates a new [AudioProgress].
  const AudioProgress({required this.step, required this.steps, required this.label, this.stepFraction = 0});

  /// A single-step progress of [label], [fraction] done.
  const AudioProgress.single(this.label, [double fraction = 0]) : step = 1, steps = 1, stepFraction = fraction;

  /// Part of all the work that is done, 0.0-1.0 (every step counts the same).
  double get fraction => (step - 1 + stepFraction.clamp(0.0, 1.0)) / steps;

  @override
  String toString() => 'AudioProgress($step/$steps $label ${(fraction * 100).toStringAsFixed(0)} %)';
}

/// Receives progress reports.
typedef AudioProgressListener = void Function(AudioProgress progress);
