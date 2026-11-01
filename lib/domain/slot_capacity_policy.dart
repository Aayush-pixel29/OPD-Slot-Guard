// SlotCapacityPolicy (03-LLD.md §3, ADR-03).
//
// The only domain code that knows the numeric capacity rule.
// Pure Dart. No Flutter, sqflite, HTTP, Firebase, Gemini, or notifications.

import 'failures.dart';
import 'request_status.dart';

class SlotCapacityPolicy {
  const SlotCapacityPolicy();

  /// Prototype body (fails closed):
  /// - capacity != 1 throws [CapacitySeamException]
  /// - admit iff confirmedCount == 0
  ///
  /// Capacity N migration (ADR-03): admit iff `confirmedCount < capacity`,
  /// remove the throw, and change the SQL seams in the same edit.
  bool canAdmitConfirmation({
    required int capacity,
    required int confirmedCount,
  }) {
    if (capacity != 1) {
      throw CapacitySeamException(capacity);
    }
    return confirmedCount == 0;
  }

  /// `BOOKED` when confirmed count has reached capacity, else `AVAILABLE`.
  /// Derived, never stored.
  SlotAvailability availabilityOf({
    required int capacity,
    required int confirmedCount,
  }) {
    return confirmedCount >= capacity
        ? SlotAvailability.booked
        : SlotAvailability.available;
  }
}

