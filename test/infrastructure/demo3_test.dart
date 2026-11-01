// DEMO3 Acceptance Test (docs/TEST-PLAN.md, docs/DEMO-RUNBOOK.md).
//
// Steps:
// 1. Ramesh requests. Priya requests.
// 2. Clinic confirms with ACK_LOST armed.
// 3. First call throws AckLostFailure (after commit).
// 4. Submit the identical command with the same idempotency key.
//
// Expect:
// - Second call returns stored result
// - replayed == true
// - Exactly one command row in database
// - Exactly one CONFIRMED row in database
// - Slot version incremented exactly once (version 1)
// - Effects length stable across replay

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

  test('DEMO3: ACK_LOST throws after commit, retry with same key replays stored result without double mutation', () async {
    // 1. Ramesh & Priya request
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-ramesh-1',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-ramesh',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-priya-1',
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      requestId: 'req-priya',
      patientId: 'patient-priya',
      expectedSlotVersion: 0,
    ));

    // 2. Arm ACK_LOST (one-shot)
    chaos.armed = ChaosArm.ackLost;

    final confirmCmd = AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: 'cmd-confirm-original',
      idempotencyKey: 'key-confirm-ramesh',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-ramesh',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    );

    // 3. First attempt commits, then throws AckLostFailure
    expect(() => authority.submit(confirmCmd), throwsA(isA<AckLostFailure>()));

    // Verify commit was durable: slot version is 1, Ramesh is CONFIRMED, Priya is WAITLISTED
    final slotRow1 = (await db.query('slots', where: 'slot_id = ?', whereArgs: ['slot-1830'])).first;
    expect(slotRow1['version'], 1);

    final reqRamesh1 = (await db.query('requests', where: 'request_id = ?', whereArgs: ['req-ramesh'])).first;
    expect(reqRamesh1['status'], 'CONFIRMED');

    final reqPriya1 = (await db.query('requests', where: 'request_id = ?', whereArgs: ['req-priya'])).first;
    expect(reqPriya1['status'], 'WAITLISTED');

    // Exactly one confirm command row
    final commandsAfterFirst = await db.query('commands', where: "command_type = 'ConfirmRequest'");
    expect(commandsAfterFirst, hasLength(1));
    expect(commandsAfterFirst.first['command_id'], 'cmd-confirm-original');
    expect(commandsAfterFirst.first['status'], 'SUCCEEDED');

    // 4. Retry with the SAME idempotency key (even with a new commandId or refreshed versions)
    final retryCmd = confirmCmd.withExpectedVersions(expectedSlotVersion: 1, expectedRequestVersion: 1);
    final retryRes = await authority.submit(retryCmd);

    expect(retryRes.isApplied, isTrue);
    expect(retryRes.replayed, isTrue, reason: 'Must be marked as replayed');
    expect(retryRes.slot!.availability, SlotAvailability.booked);
    expect(retryRes.slot!.version, 1);
    expect(retryRes.request!.status, RequestStatus.confirmed);
    expect(retryRes.effects, hasLength(2));

    // Verify database state after retry: NO SECOND MUTATION
    final slotRow2 = (await db.query('slots', where: 'slot_id = ?', whereArgs: ['slot-1830'])).first;
    expect(slotRow2['version'], 1, reason: 'Slot version must NOT bump twice');

    final commandsAfterRetry = await db.query('commands', where: "command_type = 'ConfirmRequest'");
    expect(commandsAfterRetry, hasLength(1), reason: 'Commands table must still have exactly one confirm row');

    final confirmedCount = await db.query('requests', where: "slot_id = 'slot-1830' AND status = 'CONFIRMED'");
    expect(confirmedCount, hasLength(1));
  });
}
