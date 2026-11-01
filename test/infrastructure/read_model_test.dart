// Read model privacy and projection tests (I17, I18).

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/application/demo_actor_directory.dart';
import 'package:opd_slot_guard/domain/command_fingerprint.dart';
import 'package:opd_slot_guard/domain/request_status.dart';
import 'package:opd_slot_guard/infrastructure/sqlite_appointment_authority.dart';
import 'package:opd_slot_guard/infrastructure/sqlite_appointment_read_model.dart';
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
  late SqliteAppointmentReadModel readModel;

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
    readModel = SqliteAppointmentReadModel(
      db: db,
      directory: directory,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('I17 & I18: Patient read model strictly hides other patient, clinic sees both', () async {
    // Execute DEMO1: Ramesh requests, Priya requests, Clinic confirms Ramesh
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

    // I17: Patient projection for Ramesh
    final rameshProjection = await readModel.load(DemoActorDirectory.ramesh.actor);
    final rameshSlot = rameshProjection.slots.firstWhere((s) => s.slotId == 'slot-1830');

    expect(rameshSlot.availability, SlotAvailability.booked);
    expect(rameshSlot.myRequest, isNotNull);
    expect(rameshSlot.myRequest!.status, RequestStatus.confirmed);
    expect(rameshSlot.myRequest!.patientId, 'patient-ramesh');
    expect(rameshSlot.clinicRequests, isEmpty);

    // Verify projection contains ZERO trace of Priya's patient_id or display name
    for (final slot in rameshProjection.slots) {
      expect(slot.clinicRequests, isEmpty);
      if (slot.myRequest != null) {
        expect(slot.myRequest!.patientId, 'patient-ramesh');
      }
    }

    // I17: Patient projection for Priya
    final priyaProjection = await readModel.load(DemoActorDirectory.priya.actor);
    final priyaSlot = priyaProjection.slots.firstWhere((s) => s.slotId == 'slot-1830');

    expect(priyaSlot.availability, SlotAvailability.booked);
    expect(priyaSlot.myRequest, isNotNull);
    expect(priyaSlot.myRequest!.status, RequestStatus.waitlisted);
    expect(priyaSlot.myRequest!.patientId, 'patient-priya');
    expect(priyaSlot.clinicRequests, isEmpty);

    // I18: Clinic projection sees all requests with display names
    final clinicProjection = await readModel.load(DemoActorDirectory.clinicDesk.actor);
    final clinicSlot = clinicProjection.slots.firstWhere((s) => s.slotId == 'slot-1830');

    expect(clinicSlot.availability, SlotAvailability.booked);
    expect(clinicSlot.clinicRequests, hasLength(2));
    expect(clinicSlot.clinicRequests.first.patientDisplayName, 'Ramesh');
    expect(clinicSlot.clinicRequests.first.status, RequestStatus.confirmed);
    expect(clinicSlot.clinicRequests.last.patientDisplayName, 'Priya');
    expect(clinicSlot.clinicRequests.last.status, RequestStatus.waitlisted);
  });
}
