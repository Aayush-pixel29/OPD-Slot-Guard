// Invariants and Pipeline Tests (docs/TEST-PLAN.md I1 - I23).

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/application/demo_actor_directory.dart';
import 'package:opd_slot_guard/domain/command_fingerprint.dart';
import 'package:opd_slot_guard/domain/failures.dart';
import 'package:opd_slot_guard/domain/request_status.dart';
import 'package:opd_slot_guard/infrastructure/sqlite_appointment_authority.dart';
import 'package:opd_slot_guard/ports/appointment_authority.dart';
import 'package:opd_slot_guard/ports/id_generator.dart';
import 'package:sqflite/sqflite.dart';

import '../support/fake_clock.dart';
import '../support/ffi_database.dart';

void main() {
  late Database db;
  late FakeClock clock;
  late IdGenerator idGen;
  late DemoActorDirectory directory;
  late ChaosState chaos;
  late SqliteAppointmentAuthority authority;

  setUp(() async {
    db = await openTestDatabase();
    clock = FakeClock(currentMs: 1000, stepMs: 1000);
    idGen = LocalIdGenerator();
    directory = DemoActorDirectory();
    chaos = ChaosState();
    authority = SqliteAppointmentAuthority(
      db: db,
      clock: clock,
      idGenerator: idGen,
      actorLookup: directory.findActor,
      chaos: chaos,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('I1: Two sequential confirms of two requests on same slot', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-p',
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      requestId: 'req-p',
      patientId: 'patient-priya',
      expectedSlotVersion: 0,
    ));

    // Confirm Ramesh
    final res1 = await authority.submit(AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-c1',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    ));
    expect(res1.isApplied, isTrue);

    // Confirm Priya (who was moved to WAITLISTED)
    final res2 = await authority.submit(AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-c2',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-p',
      expectedSlotVersion: 1,
      expectedRequestVersion: 1,
    ));
    // WAITLISTED -> CONFIRMED is illegal transition
    expect(res2.isApplied, isFalse);
    expect(res2.code, RejectionCode.illegalTransition.wire);

    final confirmed = await db.query('requests', where: "slot_id = 'slot-1830' AND status = 'CONFIRMED'");
    expect(confirmed, hasLength(1));
  });

  test('I2: Cancel REQUESTED while another REQUESTED exists', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-p',
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      requestId: 'req-p',
      patientId: 'patient-priya',
      expectedSlotVersion: 0,
    ));

    final cancelRes = await authority.submit(AppointmentCommand.transition(
      type: CommandType.cancelRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-cancel-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    ));
    expect(cancelRes.isApplied, isTrue);
    expect(cancelRes.slot!.version, 0, reason: 'Slot version unchanged when non-confirmed cancelled');

    final reqP = (await db.query('requests', where: 'request_id = ?', whereArgs: ['req-p'])).first;
    expect(reqP['status'], 'REQUESTED');
  });

  test('I3: Cancel WAITLISTED while another is CONFIRMED', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-p',
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      requestId: 'req-p',
      patientId: 'patient-priya',
      expectedSlotVersion: 0,
    ));

    await authority.submit(AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-c',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    ));

    // Priya cancels her WAITLISTED request
    final cancelPriya = await authority.submit(AppointmentCommand.transition(
      type: CommandType.cancelRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-cancel-p',
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      requestId: 'req-p',
      expectedSlotVersion: 1,
      expectedRequestVersion: 1,
    ));
    expect(cancelPriya.isApplied, isTrue);
    expect(cancelPriya.slot!.version, 1, reason: 'Slot version unchanged on waitlisted cancel');
    expect(cancelPriya.slot!.availability, SlotAvailability.booked);

    final reqR = (await db.query('requests', where: 'request_id = ?', whereArgs: ['req-r'])).first;
    expect(reqR['status'], 'CONFIRMED');
  });

  test('I4: Reopen restores multiple waitlisted patients in queue_ms order', () async {
    // Ramesh requests (queue 1000)
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    // Confirm Ramesh
    await authority.submit(AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-c',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    ));

    // Priya requests while BOOKED -> enters WAITLISTED directly
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-p',
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      requestId: 'req-p',
      patientId: 'patient-priya',
      expectedSlotVersion: 1,
    ));

    // Ramesh cancels -> Priya restored to REQUESTED
    final cancelRes = await authority.submit(AppointmentCommand.transition(
      type: CommandType.cancelRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-cancel-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 1,
      expectedRequestVersion: 1,
    ));
    expect(cancelRes.isApplied, isTrue);
    expect(cancelRes.effects.last.requestId, 'req-p');
    expect(cancelRes.effects.last.to, RequestStatus.requested);
  });

  test('I6: Decline CONFIRMED is ILLEGAL_TRANSITION', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    await authority.submit(AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-c',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    ));

    final res = await authority.submit(AppointmentCommand.transition(
      type: CommandType.declineRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-d',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 1,
      expectedRequestVersion: 1,
    ));
    expect(res.isApplied, isFalse);
    expect(res.code, RejectionCode.illegalTransition.wire);
  });

  test('I7: Decline REQUESTED sets status DECLINED without changing slot version', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    final res = await authority.submit(AppointmentCommand.transition(
      type: CommandType.declineRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-d',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    ));
    expect(res.isApplied, isTrue);
    expect(res.request!.status, RequestStatus.declined);
    expect(res.slot!.version, 0);
  });

  test('I8: Request while BOOKED enters directly as WAITLISTED', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    await authority.submit(AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-c',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    ));

    final resPriya = await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-p',
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      requestId: 'req-p',
      patientId: 'patient-priya',
      expectedSlotVersion: 1,
    ));
    expect(resPriya.isApplied, isTrue);
    expect(resPriya.request!.status, RequestStatus.waitlisted);
  });

  test('I9: Second live request same patient, same slot returns ALREADY_ACTIVE', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-1',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-1',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    final res2 = await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-2',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-2',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));
    expect(res2.isApplied, isFalse);
    expect(res2.code, RejectionCode.alreadyActive.wire);
  });

  test('I11: Same key, different payload returns IDEMPOTENCY_PAYLOAD_MISMATCH', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: 'cmd-original',
      idempotencyKey: 'key-fixed',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-ramesh',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    final mismatched = AppointmentCommand.requestSlot(
      commandId: 'cmd-second',
      idempotencyKey: 'key-fixed',
      actorId: 'patient-priya', // different actor and patient
      slotId: 'slot-1830',
      requestId: 'req-priya',
      patientId: 'patient-priya',
      expectedSlotVersion: 0,
    );
    final res = await authority.submit(mismatched);
    expect(res.isApplied, isFalse);
    expect(res.code, RejectionCode.idempotencyPayloadMismatch.wire);
  });

  test('I12 & I13: Stale version returns STALE_VERSION with no command row, then retry succeeds', () async {
    final staleCmd = AppointmentCommand.requestSlot(
      commandId: 'cmd-stale',
      idempotencyKey: 'key-retryable',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-ramesh',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 99, // Stale!
    );
    final res = await authority.submit(staleCmd);
    expect(res.isApplied, isFalse);
    expect(res.code, RejectionCode.staleVersion.wire);

    // Assert NO commands row was stored
    final commands = await db.query('commands', where: "idempotency_key = 'key-retryable'");
    expect(commands, isEmpty);

    // I13: Same key retried with refreshed slot version
    final freshCmd = staleCmd.withExpectedVersions(expectedSlotVersion: 0);
    final freshRes = await authority.submit(freshCmd);
    expect(freshRes.isApplied, isTrue);
    expect(freshRes.request!.status, RequestStatus.requested);
  });

  test('I14: Stored REJECTED (FORBIDDEN) replays identical rejection', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-req-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    final patientConfirm = AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: 'cmd-forbidden',
      idempotencyKey: 'key-forbidden',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    );

    final res1 = await authority.submit(patientConfirm);
    expect(res1.isApplied, isFalse);
    expect(res1.code, RejectionCode.forbidden.wire);

    final res2 = await authority.submit(patientConfirm);
    expect(res2.isApplied, isFalse);
    expect(res2.code, RejectionCode.forbidden.wire);
    expect(res2.replayed, isTrue);
  });

  test('I15: OFFLINE throws without writing command or request rows', () async {
    chaos.armed = ChaosArm.offline;

    final cmd = AppointmentCommand.requestSlot(
      commandId: 'cmd-off',
      idempotencyKey: 'key-off',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-off',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    );

    expect(() => authority.submit(cmd), throwsA(isA<OfflineFailure>()));

    final commands = await db.query('commands');
    expect(commands, isEmpty);
    final requests = await db.query('requests');
    expect(requests, isEmpty);

    // Retry with same key succeeds
    final retryRes = await authority.submit(cmd);
    expect(retryRes.isApplied, isTrue);
  });

  test('I16: TRANSACTION_ABORT rolls back cleanly, then retry succeeds', () async {
    chaos.armed = ChaosArm.abort;

    final cmd = AppointmentCommand.requestSlot(
      commandId: 'cmd-abort',
      idempotencyKey: 'key-abort',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-abort',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    );

    expect(() => authority.submit(cmd), throwsA(isA<TransactionAbortFailure>()));

    final commands = await db.query('commands');
    expect(commands, isEmpty);
    final requests = await db.query('requests');
    expect(requests, isEmpty);

    // Retry succeeds once
    final retryRes = await authority.submit(cmd);
    expect(retryRes.isApplied, isTrue);
    expect(await db.query('commands'), hasLength(1));
    expect(await db.query('requests'), hasLength(1));
  });

  test('I22 & I23: Authorization denies patient confirm and unknown actor', () async {
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-req-test',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-test',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    final patientConfirm = AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: idGen.newId('key-c-patient'),
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-test',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    );
    final res1 = await authority.submit(patientConfirm);
    expect(res1.code, RejectionCode.forbidden.wire);

    final unknownActor = AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: idGen.newId('key-c-unknown'),
      actorId: 'hacker-unknown',
      slotId: 'slot-1830',
      requestId: 'req-test',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    );
    final res2 = await authority.submit(unknownActor);
    expect(res2.code, RejectionCode.forbidden.wire);
  });
}
