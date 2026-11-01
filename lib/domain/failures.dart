// Machine codes and failure types (03-LLD.md §6, FAILURE-MATRIX.md).
//
// Pure Dart. No Flutter, sqflite, HTTP, Firebase, Gemini, or notifications.

/// Domain rejection codes. `wire` is the machine code stored in
/// `result_json.code` and shown only on the diagnostics sheet.
enum RejectionCode {
  notFound('NOT_FOUND'),
  forbidden('FORBIDDEN'),
  illegalTransition('ILLEGAL_TRANSITION'),

  /// Never stored under an idempotency key (ADR-02 rule 9).
  staleVersion('STALE_VERSION'),
  capacityExceeded('CAPACITY_EXCEEDED'),
  alreadyActive('ALREADY_ACTIVE'),
  idempotencyPayloadMismatch('IDEMPOTENCY_PAYLOAD_MISMATCH');

  const RejectionCode(this.wire);

  final String wire;

  static RejectionCode fromWire(String value) {
    for (final code in RejectionCode.values) {
      if (code.wire == value) return code;
    }
    throw FormatException('Unknown rejection code', value);
  }
}

/// Success code stored in `result_json.code`.
const String okCode = 'OK';

/// Transport failures. They are never stored as a command status.
///
/// - [OfflineFailure]: thrown before `BEGIN`. Nothing written.
/// - [TransactionAbortFailure]: thrown inside the transaction. Rolled back.
/// - [AckLostFailure]: thrown after `COMMIT`. The stored status is already
///   `SUCCEEDED`; the cure is replay with the same idempotency key.
sealed class TransportFailure implements Exception {
  const TransportFailure();

  String get code;

  @override
  String toString() => code;
}

final class OfflineFailure extends TransportFailure {
  const OfflineFailure();

  @override
  String get code => 'OFFLINE';
}

final class TransactionAbortFailure extends TransportFailure {
  const TransactionAbortFailure([this.reason]);

  /// Machine-readable reason for diagnostics only (for example a constraint
  /// name). Never shown on patient copy.
  final String? reason;

  @override
  String get code => 'TRANSACTION_ABORT';
}

final class AckLostFailure extends TransportFailure {
  const AckLostFailure();

  @override
  String get code => 'ACK_LOST';
}

/// Thrown by [SlotCapacityPolicy] when capacity is not 1.
/// The capacity-N seam is deliberately unfinished (ADR-03): fail closed.
final class CapacitySeamException implements Exception {
  const CapacitySeamException(this.capacity);

  final int capacity;

  @override
  String toString() =>
      'CapacitySeamException: capacity $capacity is not supported by the '
      'prototype policy (ADR-03).';
}

