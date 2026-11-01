// D3, D4, D5: SlotCapacityPolicy fails closed outside capacity 1.

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/domain/failures.dart';
import 'package:opd_slot_guard/domain/request_status.dart';
import 'package:opd_slot_guard/domain/slot_capacity_policy.dart';

void main() {
  const policy = SlotCapacityPolicy();

  test('D3 capacity 1, confirmed 0 -> admit', () {
    expect(policy.canAdmitConfirmation(capacity: 1, confirmedCount: 0), isTrue);
  });

  test('D4 capacity 1, confirmed 1 -> refuse', () {
    expect(
        policy.canAdmitConfirmation(capacity: 1, confirmedCount: 1), isFalse);
  });

  test('D5 capacity 2 throws CapacitySeamException (unfinished N seam)', () {
    expect(() => policy.canAdmitConfirmation(capacity: 2, confirmedCount: 0),
        throwsA(isA<CapacitySeamException>()));
    expect(() => policy.canAdmitConfirmation(capacity: 0, confirmedCount: 0),
        throwsA(isA<CapacitySeamException>()));
  });

  test('availability is derived: BOOKED iff confirmed >= capacity', () {
    expect(policy.availabilityOf(capacity: 1, confirmedCount: 0),
        SlotAvailability.available);
    expect(policy.availabilityOf(capacity: 1, confirmedCount: 1),
        SlotAvailability.booked);
  });
}

