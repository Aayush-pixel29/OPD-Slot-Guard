// Command types and the canonical idempotency fingerprint (ADR-02).
//
// Pure Dart. No Flutter, sqflite, HTTP, Firebase, Gemini, or notifications.

/// `wire` is the exact string stored in `commands.command_type`.
enum CommandType {
  requestSlot('RequestSlot'),
  confirmRequest('ConfirmRequest'),
  declineRequest('DeclineRequest'),
  cancelRequest('CancelRequest'),
  waitlistRequest('WaitlistRequest');

  const CommandType(this.wire);

  final String wire;

  static CommandType fromWire(String value) {
    for (final type in CommandType.values) {
      if (type.wire == value) return type;
    }
    throw FormatException('Unknown command type', value);
  }
}

/// The one and only fingerprint helper (ADR-02 "Cost": mandatory).
///
/// `v1|{type}|{actorId}|{slotId}|{requestId or -}|{patientId or -}`
///
/// Excluded on purpose: commandId, both expected versions, queue_ms,
/// timestamps. A retry of the same gesture must match after a refresh.
String commandFingerprint({
  required CommandType type,
  required String actorId,
  required String slotId,
  String? requestId,
  String? patientId,
}) {
  final fields = <String>[actorId, slotId, ?requestId, ?patientId];
  for (final field in fields) {
    // A separator inside an id would let two different payloads produce the
    // same canonical string. Ids come from the local generator and never
    // contain '|' or empty values.
    if (field.isEmpty || field.contains('|') || field == '-') {
      throw ArgumentError.value(field, 'id', 'not a valid fingerprint field');
    }
  }
  return [
    'v1',
    type.wire,
    actorId,
    slotId,
    requestId ?? '-',
    patientId ?? '-',
  ].join('|');
}
