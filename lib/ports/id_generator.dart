// IdGenerator port. Command ids, idempotency keys, request ids, audit ids.
//
// No uuid or crypto package (architecture gate). Ids are opaque: they must
// not embed a patient's name, so a request id in an effect list cannot reveal
// who owns it.

import 'dart:math';

abstract interface class IdGenerator {
  /// Returns a new id with the given prefix, e.g. `cmd`, `key`, `req`, `evt`.
  String newId(String prefix);
}

/// Small local generator: prefix, time, counter, random suffix.
class LocalIdGenerator implements IdGenerator {
  LocalIdGenerator({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  int _counter = 0;

  static const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

  @override
  String newId(String prefix) {
    _counter++;
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final suffix = List.generate(
      8,
      (_) => _alphabet[_random.nextInt(_alphabet.length)],
    ).join();
    return '$prefix-$time-${_counter.toRadixString(36)}-$suffix';
  }
}

