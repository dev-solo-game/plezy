import 'dart:async';

import 'package:clock/clock.dart';

/// Spaces calls at least [interval] apart and runs them one at a time.
///
/// Cloud drives throttle or flag accounts that list directories too fast, so a
/// driver funnels every API call through one of these. Callers queue in
/// arrival order; a failed call still consumes its slot.
class RequestThrottle {
  RequestThrottle(this.interval);

  final Duration interval;

  Future<void> _tail = Future<void>.value();
  DateTime? _lastStart;

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      final last = _lastStart;
      if (last != null) {
        final wait = interval - clock.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _lastStart = clock.now();
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
