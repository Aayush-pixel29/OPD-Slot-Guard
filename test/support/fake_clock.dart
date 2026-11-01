// Fake clock for deterministic tests. Starts at 1000 and advances by 1000 by default.

import 'package:opd_slot_guard/ports/clock.dart';

class FakeClock implements Clock {
  FakeClock({this.currentMs = 1000, this.stepMs = 1000});

  int currentMs;
  int stepMs;

  @override
  int nowMs() {
    final ms = currentMs;
    currentMs += stepMs;
    return ms;
  }
}
