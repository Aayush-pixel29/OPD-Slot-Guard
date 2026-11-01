// ActorPolicy (03-LLD.md §3, ADR-03 "Authorization without authentication").
//
// Authorization runs on the actor id carried by the command, never on a
// widget global. Pure Dart. No Flutter, sqflite, HTTP, Firebase, Gemini, or
// notifications.

import 'command_fingerprint.dart';

enum ActorRole { patient, clinic }

class Actor {
  const Actor({required this.id, required this.role});

  final String id;
  final ActorRole role;

  bool get isPatient => role == ActorRole.patient;
  bool get isClinic => role == ActorRole.clinic;
}

/// Resolves an actor id to an [Actor], or null when unknown.
///
/// Injected at the composition root (the demo directory today, a credential
/// binding in production). Unknown actors are `FORBIDDEN` before SQL writes.
typedef ActorLookup = Actor? Function(String actorId);

class ActorPolicy {
  const ActorPolicy();

  /// | Command         | Patient, own row          | Patient, other | Clinic |
  /// | RequestSlot     | allow if payload == actor | deny           | deny   |
  /// | ConfirmRequest  | deny                      | deny           | allow  |
  /// | DeclineRequest  | deny                      | deny           | allow  |
  /// | CancelRequest   | allow                     | deny           | allow  |
  /// | WaitlistRequest | deny                      | deny           | allow  |
  ///
  /// [actor] null means the actor id was unknown: deny.
  /// [patientId] is the payload patient for RequestSlot, or the target row's
  /// `patient_id` for every other command.
  bool isAllowed({
    required Actor? actor,
    required CommandType type,
    required String? patientId,
  }) {
    if (actor == null) return false;
    final ownsRow = actor.isPatient && patientId == actor.id;
    switch (type) {
      case CommandType.requestSlot:
        return ownsRow;
      case CommandType.confirmRequest:
      case CommandType.declineRequest:
      case CommandType.waitlistRequest:
        return actor.isClinic;
      case CommandType.cancelRequest:
        return actor.isClinic || ownsRow;
    }
  }
}

