// A1: Patient Messages Test (docs/TEST-PLAN.md).
//
// Every code in FAILURE-MATRIX.md must have a non-empty patient-safe banner.
// Forbidden substrings must NEVER appear:
// '404', '409', '429', '500', '502', '503', '504', '505', 'SQLite', 'Exception', 'HTTP'.

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/application/patient_messages.dart';

void main() {
  const codes = [
    'OFFLINE',
    'TRANSACTION_ABORT',
    'ACK_LOST',
    'STALE_VERSION',
    'NOT_FOUND',
    'FORBIDDEN',
    'ILLEGAL_TRANSITION',
    'CAPACITY_EXCEEDED',
    'ALREADY_ACTIVE',
    'IDEMPOTENCY_PAYLOAD_MISMATCH',
    'AMBIGUOUS_EXHAUSTION',
    '404',
    '409',
    '429',
    '500',
    '502',
    '503',
    '504',
    '505',
    'TIMEOUT',
  ];

  const forbiddenSubstrings = [
    '404',
    '409',
    '429',
    '500',
    '502',
    '503',
    '504',
    '505',
    'SQLite',
    'Exception',
    'HTTP',
  ];

  test('A1: Every failure code maps to a safe sentence with no forbidden technical terms', () {
    for (final code in codes) {
      final banner = PatientMessages.bannerForCode(code);
      expect(banner, isNotEmpty, reason: 'Banner for $code must not be empty');

      for (final forbidden in forbiddenSubstrings) {
        expect(
          banner.contains(forbidden),
          isFalse,
          reason: 'Banner for $code ("$banner") contains forbidden substring "$forbidden"',
        );
      }
    }
  });
}

