import 'dart:async';

import 'audio_progress.dart';
import 'audio_task.dart';

/// Runs [work] on the main thread after the current event (the web has no isolates); returns a
/// function that keeps it from starting.
void Function() startWork<T>(
  AudioWork<T> work, {
  required void Function(AudioProgress progress) onProgress,
  required void Function(T value) onDone,
  required void Function(Object error, StackTrace stack) onError,
}) {
  bool stopped = false;
  Timer.run(() {
    if (stopped) return;
    try {
      onDone(work(onProgress));
    } catch (error, stack) {
      onError(error, stack);
    }
  });
  return () => stopped = true;
}
