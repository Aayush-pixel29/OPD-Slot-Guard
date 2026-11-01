// Read model ports and view projections (02-HLD.md §6, 03-LLD.md §9).
//
// Read model is a read-only query join. It is not a command, has no
// idempotency key, and never mutates rows.

import '../domain/actor_policy.dart';
import '../domain/request_status.dart';

class ClinicRequestView {
  const ClinicRequestView({
    required this.requestId,
    required this.patientId,
    required this.patientDisplayName,
    required this.status,
    required this.queueMs,
    required this.version,
  });

  final String requestId;
  final String patientId;
  final String patientDisplayName;
  final RequestStatus status;
  final int queueMs;
  final int version;
}

class SlotCardModel {
  const SlotCardModel({
    required this.slotId,
    required this.label,
    required this.startMinute,
    required this.capacity,
    required this.version,
    required this.availability,
    required this.confirmedCount,
    this.myRequest,
    this.clinicRequests = const [],
  });

  final String slotId;
  final String label;
  final int startMinute;
  final int capacity;
  final int version;
  final SlotAvailability availability;
  final int confirmedCount;

  /// Patient view: that patient's own request status, if any.
  /// Null if the patient has no request for this slot.
  final AppointmentRequest? myRequest;

  /// Clinic view: all requests on this slot, ordered by queue_ms.
  final List<ClinicRequestView> clinicRequests;

  bool get isBooked => availability == SlotAvailability.booked;
  bool get isAvailable => availability == SlotAvailability.available;
}

class BoardProjection {
  const BoardProjection({
    required this.actor,
    required this.slots,
  });

  final Actor actor;
  final List<SlotCardModel> slots;
}

abstract interface class AppointmentReadModel {
  Future<BoardProjection> load(Actor actor);
}
