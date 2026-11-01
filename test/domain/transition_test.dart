// D1, D2: the transition table, exhaustively over all 25 ordered pairs.

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/domain/request_status.dart';
import 'package:opd_slot_guard/domain/transition.dart';

void main() {
  const r = RequestStatus.requested;
  const c = RequestStatus.confirmed;
  const w = RequestStatus.waitlisted;
  const d = RequestStatus.declined;
  const x = RequestStatus.cancelled;

  const legalPairs = <(RequestStatus, RequestStatus)>{
    (r, c), (r, w), (r, d), (r, x),
    (w, r), (w, d), (w, x),
    (c, x),
  };

  test('D1 every legal pair from the solution brief is allowed', () {
    for (final (from, to) in legalPairs) {
      expect(legalTransition(from, to), TransitionVerdict.allowed,
          reason: '${from.wire} -> ${to.wire}');
    }
  });

  test('D2 every other ordered pair, including self, is illegal', () {
    var illegalCount = 0;
    for (final from in RequestStatus.values) {
      for (final to in RequestStatus.values) {
        if (legalPairs.contains((from, to))) continue;
        illegalCount++;
        expect(legalTransition(from, to), TransitionVerdict.illegalTransition,
            reason: '${from.wire} -> ${to.wire}');
      }
    }
    expect(illegalCount, 25 - legalPairs.length);
  });

  test('WAITLISTED -> CONFIRMED is illegal (no confirm from the waitlist)', () {
    expect(legalTransition(w, c), TransitionVerdict.illegalTransition);
  });

  test('DECLINED and CANCELLED are terminal', () {
    for (final to in RequestStatus.values) {
      expect(legalTransition(d, to), TransitionVerdict.illegalTransition);
      expect(legalTransition(x, to), TransitionVerdict.illegalTransition);
    }
    expect(d.isTerminal && x.isTerminal, isTrue);
    expect(r.isLive && w.isLive && c.isLive, isTrue);
  });

  test('wire strings match the schema CHECK constraint', () {
    expect(RequestStatus.values.map((s) => s.wire), [
      'REQUESTED', 'CONFIRMED', 'WAITLISTED', 'DECLINED', 'CANCELLED',
    ]);
    for (final s in RequestStatus.values) {
      expect(RequestStatus.fromWire(s.wire), s);
    }
    expect(() => RequestStatus.fromWire('PROMOTED'), throwsFormatException);
  });
}

