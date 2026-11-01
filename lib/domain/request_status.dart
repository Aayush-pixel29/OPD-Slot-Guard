// Domain value types for OPD Slot Guard (03-LLD.md §3).
//
// Pure Dart. This file must not import Flutter, sqflite, HTTP, Firebase,
// Gemini, or notification SDKs.

/// Lifecycle of one appointment request row.
///
/// `wire` is the exact string stored in `requests.status`.
enum RequestStatus {
  requested('REQUESTED'),
  confirmed('CONFIRMED'),
  waitlisted('WAITLISTED'),
  declined('DECLINED'),
  cancelled('CANCELLED');

  const RequestStatus(this.wire);

  final String wire;

  /// Live rows occupy the `ux_one_live_request_per_patient_slot` index.
  bool get isLive =>
      this == requested || this == waitlisted || this == confirmed;

  /// `DECLINED` and `CANCELLED` are terminal.
  bool get isTerminal => !isLive;

  static RequestStatus fromWire(String value) {
    for (final status in RequestStatus.values) {
      if (status.wire == value) return status;
    }
    throw FormatException('Unknown request status', value);
  }
}

/// Derived slot availability. There is no stored slot status.
enum SlotAvailability {
  available('AVAILABLE'),
  booked('BOOKED');

  const SlotAvailability(this.wire);

  final String wire;

  static SlotAvailability fromWire(String value) {
    for (final availability in SlotAvailability.values) {
      if (availability.wire == value) return availability;
    }
    throw FormatException('Unknown slot availability', value);
  }
}

/// One bookable slot. `capacity` is always 1 in the prototype.
class Slot {
  const Slot({
    required this.slotId,
    required this.label,
    required this.startMinute,
    required this.capacity,
    required this.version,
  });

  final String slotId;
  final String label;
  final int startMinute;
  final int capacity;
  final int version;
}

/// One patient's request for one slot.
class AppointmentRequest {
  const AppointmentRequest({
    required this.requestId,
    required this.patientId,
    required this.slotId,
    required this.status,
    required this.queueMs,
    required this.version,
  });

  final String requestId;
  final String patientId;
  final String slotId;
  final RequestStatus status;

  /// Authority clock value assigned on insert. Never client supplied,
  /// never rewritten by waitlist or restore.
  final int queueMs;
  final int version;
}

/// Canonical restore / park order: `queue_ms` ascending, then `request_id`.
int compareQueueOrder(AppointmentRequest a, AppointmentRequest b) {
  final byQueue = a.queueMs.compareTo(b.queueMs);
  if (byQueue != 0) return byQueue;
  return a.requestId.compareTo(b.requestId);
}

