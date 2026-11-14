import 'dart:isolate';

import 'audio_progress.dart';
import 'audio_task.dart';

/// Runs [work] in a new isolate; returns a function that kills it.
void Function() startWork<T>(
  AudioWork<T> work, {
  required void Function(AudioProgress progress) onProgress,
  required void Function(T value) onDone,
  required void Function(Object error, StackTrace stack) onError,
}) {
  final ReceivePort port = ReceivePort();
  Isolate? isolate;
  bool stopped = false;
  bool finished = false;

  void finish() {
    finished = true;
    port.close();
  }

  port.listen((Object? message) {
    switch (message) {
      case final AudioProgress progress:
        onProgress(progress);
      case _Done<T>(:final T value):
        finish();
        onDone(value);
      case _Failed(:final Object error, :final String stack):
        finish();
        onError(error, StackTrace.fromString(stack));
      case null: // the isolate exited without a result (killed or crashed)
        if (!finished) {
          finish();
          onError(const AudioTaskException('the background isolate stopped unexpectedly'), StackTrace.current);
        }
    }
  });

  Isolate.spawn<_Job<T>>(
    _run,
    _Job<T>(work, port.sendPort),
    onExit: port.sendPort,
    errorsAreFatal: true,
    debugName: 'AudioTask',
  ).then(
    (Isolate spawned) {
      isolate = spawned;
      if (stopped) spawned.kill(priority: Isolate.immediate);
    },
    onError: (Object error, StackTrace stack) {
      if (!finished) {
        finish();
        onError(error, stack);
      }
    },
  );

  return () {
    stopped = true;
    finish();
    isolate?.kill(priority: Isolate.immediate);
  };
}

void _run<T>(_Job<T> job) {
  final SendPort port = job.port;
  try {
    final T value = job.work(port.send);
    Isolate.exit(port, _Done<T>(value));
  } catch (error, stack) {
    try {
      port.send(_Failed(error, stack.toString()));
    } catch (_) {
      port.send(_Failed(AudioTaskException(error.toString()), stack.toString()));
    }
  }
}

final class _Job<T> {
  final AudioWork<T> work;
  final SendPort port;

  const _Job(this.work, this.port);
}

final class _Done<T> {
  final T value;

  const _Done(this.value);
}

final class _Failed {
  final Object error;
  final String stack;

  const _Failed(this.error, this.stack);
}
