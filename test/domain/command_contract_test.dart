// I24 and the result_json contract (03-LLD.md §4, §6).

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/domain/command_fingerprint.dart';
import 'package:opd_slot_guard/domain/failures.dart';
import 'package:opd_slot_guard/domain/request_status.dart';
import 'package:opd_slot_guard/ports/appointment_authority.dart';

void main() {
  test('I24 RequestSlot carries no client queue_ms and no expected request '
      'version', () {
    final command = AppointmentCommand.requestSlot(
      commandId: 'cmd-1',
      idempotencyKey: 'key-1',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-1',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    );
    expect(command.type, CommandType.requestSlot);
    expect(command.expectedRequestVersion, isNull);
    expect(command.intent.expectedRequestVersion, isNull);
    // There is no queueMs on the command or the intent; this would not
    // compile if one were added and referenced here, so assert via the
    // stored fingerprint instead: queue position is not part of identity.
    expect(command.fingerprint.split('|'), hasLength(6));
  });

  test('transition factory refuses RequestSlot type', () {
    expect(
        () => AppointmentCommand.transition(
              type: CommandType.requestSlot,
              commandId: 'cmd',
              idempotencyKey: 'key',
              actorId: 'clinic-desk',
              slotId: 'slot-1830',
              requestId: 'req',
              expectedSlotVersion: 0,
              expectedRequestVersion: 0,
            ),
        throwsArgumentError);
  });

  test('result_json round-trips and never contains the replayed flag', () {
    const result = CommandResult(
      outcome: CommandOutcome.applied,
      code: okCode,
      commandId: 'cmd-1',
      commandType: CommandType.confirmRequest,
      slot: SlotSnapshot(
        slotId: 'slot-1830',
        version: 1,
        capacity: 1,
        confirmedCount: 1,
        availability: SlotAvailability.booked,
      ),
      request: RequestSnapshot(
        requestId: 'req-r',
        patientId: 'patient-ramesh',
        status: RequestStatus.confirmed,
        version: 1,
        queueMs: 1000,
      ),
      effects: [
        CommandEffect(
            requestId: 'req-r',
            from: RequestStatus.requested,
            to: RequestStatus.confirmed),
        CommandEffect(
            requestId: 'req-p',
            from: RequestStatus.requested,
            to: RequestStatus.waitlisted),
      ],
    );
    final stored = result.encode();
    expect(stored, isNot(contains('replayed')));

    final replay = CommandResult.decode(stored, replayed: true);
    expect(replay.replayed, isTrue);
    expect(replay.encode(), stored, reason: 'replay must not rewrite result');
    expect(replay.effects, hasLength(2));
    expect(replay.slot!.availability, SlotAvailability.booked);
    expect(replay.request!.status, RequestStatus.confirmed);
  });

  test('rejection result exposes its machine code', () {
    const rejection = CommandResult(
      outcome: CommandOutcome.rejected,
      code: 'FORBIDDEN',
      commandId: 'cmd-2',
      commandType: CommandType.confirmRequest,
      slot: null,
      request: null,
      effects: [],
    );
    final decoded = CommandResult.decode(rejection.encode());
    expect(decoded.isApplied, isFalse);
    expect(decoded.rejectionCode, RejectionCode.forbidden);
  });

  test('machine codes match 03-LLD.md §6', () {
    expect(RejectionCode.values.map((c) => c.wire).toSet(), {
      'NOT_FOUND',
      'FORBIDDEN',
      'ILLEGAL_TRANSITION',
      'STALE_VERSION',
      'CAPACITY_EXCEEDED',
      'ALREADY_ACTIVE',
      'IDEMPOTENCY_PAYLOAD_MISMATCH',
    });
    expect(const OfflineFailure().code, 'OFFLINE');
    expect(const TransactionAbortFailure().code, 'TRANSACTION_ABORT');
    expect(const AckLostFailure().code, 'ACK_LOST');
  });
}

