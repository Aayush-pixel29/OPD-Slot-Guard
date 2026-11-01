// Patient-safe banners and error copy (03-LLD.md §10, FAILURE-MATRIX.md).
//
// These sentences must never expose internal numbers (404, 500), technical
// class names (SQLite, Exception), or stack traces to patients.

class PatientMessages {
  const PatientMessages._();

  static const String offline =
      'Could not reach the clinic. Nothing was changed.';

  static const String transactionAbort =
      'Could not save that action. Nothing was changed.';

  static const String ackLostChecking =
      'Connection dropped after sending. Checking the appointment.';

  static const String staleVersion =
      'This appointment changed. Here is the latest status.';

  static const String capacityExceeded =
      'That slot is no longer open for confirmation.';

  static const String illegalTransition =
      'That action is no longer available.';

  static const String alreadyActive =
      'You already have a request for this slot.';

  static const String notFound =
      'That appointment is no longer on the board.';

  static const String forbidden =
      'You cannot do that with this identity.';

  static const String idempotencyPayloadMismatch =
      'That retry did not match the original action.';

  static const String ambiguousExhaustion =
      'Check the appointment status before trying again.';

  static String bannerForCode(String code) {
    switch (code) {
      case 'OFFLINE':
        return offline;
      case 'TRANSACTION_ABORT':
        return transactionAbort;
      case 'ACK_LOST':
        return ackLostChecking;
      case 'STALE_VERSION':
        return staleVersion;
      case 'CAPACITY_EXCEEDED':
        return capacityExceeded;
      case 'ILLEGAL_TRANSITION':
        return illegalTransition;
      case 'ALREADY_ACTIVE':
        return alreadyActive;
      case 'NOT_FOUND':
        return notFound;
      case 'FORBIDDEN':
        return forbidden;
      case 'IDEMPOTENCY_PAYLOAD_MISMATCH':
        return idempotencyPayloadMismatch;
      case 'AMBIGUOUS_EXHAUSTION':
      case 'TIMEOUT':
      case '500':
      case '502':
      case '503':
      case '504':
        return ambiguousExhaustion;
      default:
        return 'Could not complete that action. Please check the board.';
    }
  }
}

