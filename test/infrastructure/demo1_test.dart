// DEMO1 Acceptance Test (docs/TEST-PLAN.md, docs/DEMO-RUNBOOK.md).
//
// Steps:
// 1. Ramesh requests slot-1830.
// 2. Priya requests slot-1830.
// 3. Clinic confirms Ramesh.
//
// Expect:
// - Slot availability BOOKED
// - Ramesh CONFIRMED
// - Priya WAITLISTED
// - Exactly one confirmed row
// - Slot version 1
// - Priya queue_ms > Ramesh queue_ms, and Priya queue_ms unchanged by confirm

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

  test('DEMO1: Ramesh requests, Priya requests, Clinic confirms Ramesh', () async {
    // 1. Ramesh requests slot-1830
    final cmd1 = AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-ramesh-1',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-ramesh',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    );
    final res1 = await authority.submit(cmd1);
    expect(res1.isApplied, isTrue);
    expect(res1.request!.status, RequestStatus.requested);
    expect(res1.slot!.availability, SlotAvailability.available);
    final rameshQueueMs = res1.request!.queueMs;

    // 2. Priya requests slot-1830
    final cmd2 = AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-priya-1',
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      requestId: 'req-priya',
      patientId: 'patient-priya',
      expectedSlotVersion: 0,
    );
    final res2 = await authority.submit(cmd2);
    expect(res2.isApplied, isTrue);
    expect(res2.request!.status, RequestStatus.requested);
    expect(res2.slot!.availability, SlotAvailability.available);
    final priyaQueueMs = res2.request!.queueMs;

    expect(priyaQueueMs, greaterThan(rameshQueueMs));

    // 3. Clinic confirms Ramesh
    final cmd3 = AppointmentCommand.transition(
      type: CommandType.confirmRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-clinic-confirm',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-ramesh',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    );
    final res3 = await authority.submit(cmd3);
    expect(res3.isApplied, isTrue);
    expect(res3.slot!.availability, SlotAvailability.booked);
    expect(res3.slot!.version, 1);
    expect(res3.request!.status, RequestStatus.confirmed);

    // Verify row assertions directly via raw SQL
    final slotRow = (await db.query('slots', where: 'slot_id = ?', whereArgs: ['slot-1830'])).first;
    expect(slotRow['version'], 1);

    final reqRamesh = (await db.query('requests', where: 'request_id = ?', whereArgs: ['req-ramesh'])).first;
    expect(reqRamesh['status'], 'CONFIRMED');
    expect(reqRamesh['version'], 1);
    expect(reqRamesh['queue_ms'], rameshQueueMs);

    final reqPriya = (await db.query('requests', where: 'request_id = ?', whereArgs: ['req-priya'])).first;
    expect(reqPriya['status'], 'WAITLISTED');
    expect(reqPriya['version'], 1);
    expect(reqPriya['queue_ms'], priyaQueueMs, reason: 'Priya queue_ms must remain unchanged');

    final confirmedRows = await db.query('requests', where: "slot_id = 'slot-1830' AND status = 'CONFIRMED'");
    expect(confirmedRows, hasLength(1));
  });
}
