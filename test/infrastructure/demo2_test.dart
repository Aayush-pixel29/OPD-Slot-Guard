// DEMO2 Acceptance Test (docs/TEST-PLAN.md, docs/DEMO-RUNBOOK.md).
//
// Steps:
// Continue from DEMO1 (Ramesh CONFIRMED, Priya WAITLISTED, slot BOOKED, version 1).
// Ramesh cancels.
//
// Expect:
// - Ramesh CANCELLED
// - Slot AVAILABLE
// - Priya restored to REQUESTED
// - Priya is NOT CONFIRMED (no auto-confirm)
// - Slot version 2
// - Priya queue_ms unchanged

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/application/demo_actor_directory.dart';
import 'package:opd_slot_guard/domain/command_fingerprint.dart';
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
  late SqliteAppointmentAuthority authority;

  setUp(() async {
    db = await openTestDatabase();
    clock = FakeClock(currentMs: 1000, stepMs: 1000);
    idGen = LocalIdGenerator();
    directory = DemoActorDirectory();
    authority = SqliteAppointmentAuthority(
      db: db,
      clock: clock,
      idGenerator: idGen,
      actorLookup: directory.findActor,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('DEMO2: Ramesh cancels confirmed slot; Priya returns to REQUESTED, not auto-confirmed', () async {
    // Setup DEMO1 state
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-ramesh-1',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-ramesh',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    final resPriya = await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-priya-1',
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      requestId: 'req-priya',
      patientId: 'patient-priya',
      expectedSlotVersion: 0,
    ));
    final priyaQueueMs = resPriya.request!.queueMs;

    await authority.submit(AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-clinic-confirm',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-ramesh',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    ));

    // DEMO2: Ramesh cancels his CONFIRMED appointment
    final cancelCmd = AppointmentCommand.transition(
      type: CommandType.cancelRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-ramesh-cancel',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-ramesh',
      expectedSlotVersion: 1,
      expectedRequestVersion: 1,
    );

    final cancelRes = await authority.submit(cancelCmd);
    expect(cancelRes.isApplied, isTrue);
    expect(cancelRes.slot!.availability, SlotAvailability.available);
    expect(cancelRes.slot!.version, 2);
    expect(cancelRes.request!.status, RequestStatus.cancelled);

    // Assert effects: Ramesh CANCELLED, Priya REQUESTED
    expect(
      cancelRes.effects.map((e) => (e.requestId, e.from, e.to)).toList(),
      [
        ('req-ramesh', RequestStatus.confirmed, RequestStatus.cancelled),
        ('req-priya', RequestStatus.waitlisted, RequestStatus.requested),
      ],
    );

    // Verify row assertions directly via SQL
    final slotRow = (await db.query('slots', where: 'slot_id = ?', whereArgs: ['slot-1830'])).first;
    expect(slotRow['version'], 2);

    final reqRamesh = (await db.query('requests', where: 'request_id = ?', whereArgs: ['req-ramesh'])).first;
    expect(reqRamesh['status'], 'CANCELLED');
    expect(reqRamesh['version'], 2);

    final reqPriya = (await db.query('requests', where: 'request_id = ?', whereArgs: ['req-priya'])).first;
    expect(reqPriya['status'], 'REQUESTED');
    expect(reqPriya['version'], 2);
    expect(reqPriya['queue_ms'], priyaQueueMs, reason: 'Priya queue_ms must not change');

    final confirmedRows = await db.query('requests', where: "slot_id = 'slot-1830' AND status = 'CONFIRMED'");
    expect(confirmedRows, isEmpty, reason: 'Reopening must never auto-confirm another patient');
  });
}

