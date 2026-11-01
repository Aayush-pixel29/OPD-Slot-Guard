// Clock port (03-LLD.md §8). `queue_ms` comes from here, inside the
// authority's transaction. Tests use a fake starting at 1000, +1000 per read.

abstract interface class Clock {
  int nowMs();
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  int nowMs() => DateTime.now().millisecondsSinceEpoch;
}

