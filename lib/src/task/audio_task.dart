import 'dart:async';

import 'audio_progress.dart';
import 'task_runner_web.dart' if (dart.library.isolate) 'task_runner_io.dart' as runner;

/// Work that reports its progress through the listener it is given.
typedef AudioWork<T> = T Function(AudioProgressListener report);

/// Thrown by [AudioTask.result] after [AudioTask.cancel].
final class AudioTaskCancelledException implements Exception {
  /// Creates a new [AudioTaskCancelledException].
  const AudioTaskCancelledException();

  @override
  String toString() => 'AudioTaskCancelledException: the task was cancelled';
}

/// Thrown by [AudioTask.result] when the work failed with an error that could not be passed back
/// from the background isolate as it was.
final class AudioTaskException implements Exception {
  /// The error, as text.
  final String message;

  /// Creates a new [AudioTaskException].
  const AudioTaskException(this.message);

  @override
  String toString() => 'AudioTaskException: $message';
}

/// A piece of audio work running in the background: watch [progress], await [result], or
/// [cancel] it.
///
/// On platforms with isolates (everything but the web) the work runs in its own isolate, so the
/// UI stays smooth and [cancel] stops it at once. On the web it runs on the main thread after the
/// current event; [cancel] then only helps before it has started.
///
/// The work must be sendable to another isolate: a closure that captures audio, settings and
/// tools is fine; one that captures sockets, ports or UI objects is not.
final class AudioTask<T> {
  final StreamController<AudioProgress> _progress;
  final Completer<T> _result;
  void Function()? _stop;

  AudioTask._(this._progress, this._result);

  /// Starts [work] in the background.
  factory AudioTask.start(AudioWork<T> work) {
    final AudioTask<T> task = AudioTask<T>._(StreamController<AudioProgress>.broadcast(), Completer<T>());
    task._stop = runner.startWork<T>(work, onProgress: task._onProgress, onDone: task._onDone, onError: task._onError);
    return task;
  }

  /// Progress reports while the work runs; closes when it ends. Listening is optional — reports
  /// nobody listens to are dropped.
  Stream<AudioProgress> get progress => _progress.stream;

  /// The outcome of the work; fails with [AudioTaskCancelledException] after [cancel].
  Future<T> get result => _result.future;

  /// Whether the work has finished, failed or been cancelled.
  bool get isDone => _result.isCompleted;

  /// Stops the work; [result] fails with [AudioTaskCancelledException]. Does nothing once done.
  void cancel() {
    if (_result.isCompleted) return;
    _stop?.call();
    _onError(const AudioTaskCancelledException(), StackTrace.current);
  }

  void _onProgress(AudioProgress progress) {
    if (!_progress.isClosed) _progress.add(progress);
  }

  void _onDone(T value) {
    if (_result.isCompleted) return;
    _result.complete(value);
    unawaited(_progress.close());
  }

  void _onError(Object error, StackTrace stack) {
    if (_result.isCompleted) return;
    _result.completeError(error, stack);
    unawaited(_progress.close());
  }
}
