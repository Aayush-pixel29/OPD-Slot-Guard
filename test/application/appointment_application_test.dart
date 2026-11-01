// Application layer tests: A2, A3, A4 (docs/TEST-PLAN.md).

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/application/appointment_application.dart';
import 'package:opd_slot_guard/application/demo_actor_directory.dart';
import 'package:opd_slot_guard/domain/command_fingerprint.dart';
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
  late AppointmentApplication app;

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
    app = AppointmentApplication(
      authority: authority,
      idGenerator: idGen,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('A2: ACK_LOST automatically retries once inside application and ends on success', () async {
    // Seed request
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-req-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    // Arm ACK_LOST
    chaos.armed = ChaosArm.ackLost;

    final gesture = app.createTransitionGesture(
      type: CommandType.confirmRequest,
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    );

    final res = await app.executeGesture(gesture);
    expect(res.isSuccess, isTrue);
    expect(res.banner, isNull, reason: 'Replayed success has no error banner');
    expect(app.pendingGesture, isNull);

    // Verify only 1 confirm committed
    final confirmed = await db.query('requests', where: "slot_id = 'slot-1830' AND status = 'CONFIRMED'");
    expect(confirmed, hasLength(1));
  });

  test('A3: OFFLINE retains pending gesture so next submit reuses key', () async {
    chaos.armed = ChaosArm.offline;

    final gesture = app.createRequestGesture(
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    );
    final originalKey = gesture.idempotencyKey;

    final res = await app.executeGesture(gesture);
    expect(res.isSuccess, isFalse);
    expect(res.banner, isNotNull);
    expect(app.pendingGesture, isNotNull);
    expect(app.pendingGesture!.idempotencyKey, originalKey);

    // Manual retry of pending gesture succeeds
    final retryRes = await app.executeGesture(app.pendingGesture!);
    expect(retryRes.isSuccess, isTrue);
    expect(app.pendingGesture, isNull);
  });

  test('A4: ILLEGAL_TRANSITION clears pending gesture so next tap mints new key', () async {
    // Ramesh requests
    await authority.submit(AppointmentCommand.requestSlot(
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-req-r',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    ));

    // Decline request
    await authority.submit(AppointmentCommand.transition(
      type: CommandType.declineRequest,
      commandId: idGen.newId('cmd'),
      idempotencyKey: 'key-dec-r',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    ));

    // Now try to cancel DECLINED row -> ILLEGAL_TRANSITION
    final gesture = app.createTransitionGesture(
      type: CommandType.cancelRequest,
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-r',
      expectedSlotVersion: 0,
      expectedRequestVersion: 1,
    );

    final res = await app.executeGesture(gesture);
    expect(res.isSuccess, isFalse);
    expect(res.machineCode, 'ILLEGAL_TRANSITION');
    expect(app.pendingGesture, isNull, reason: 'Terminal rejection clears pending gesture');

    // Next tap creates a fresh gesture with a new key
    final nextGesture = app.createRequestGesture(
      actorId: 'patient-priya',
      slotId: 'slot-1830',
      patientId: 'patient-priya',
      expectedSlotVersion: 0,
    );
    expect(nextGesture.idempotencyKey, isNot(gesture.idempotencyKey));
  });
}
