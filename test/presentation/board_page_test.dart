// Presentation Smoke Tests: P1, P2 (docs/TEST-PLAN.md).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/application/appointment_application.dart';
import 'package:opd_slot_guard/application/demo_actor_directory.dart';
import 'package:opd_slot_guard/infrastructure/sqlite_appointment_authority.dart';
import 'package:opd_slot_guard/infrastructure/sqlite_appointment_read_model.dart';
import 'package:opd_slot_guard/ports/id_generator.dart';
import 'package:opd_slot_guard/presentation/board_page.dart';
import 'package:opd_slot_guard/presentation/clinic_board_controller.dart';
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
  late SqliteAppointmentReadModel readModel;
  late AppointmentApplication app;
  late ClinicBoardController controller;

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
    readModel = SqliteAppointmentReadModel(
      db: db,
      directory: directory,
    );
    app = AppointmentApplication(
      authority: authority,
      idGenerator: idGen,
    );
    controller = ClinicBoardController(
      application: app,
      readModel: readModel,
      directory: directory,
      chaosState: chaos,
      db: db,
      onResetDatabase: () async {},
    );
    await controller.init();
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('P1: BoardPage renders all 6 slots including 6:30 PM and identity switcher', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: BoardPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // Verify 6 slots
    expect(find.text('4:00 PM'), findsOneWidget);
    expect(find.text('4:30 PM'), findsOneWidget);
    expect(find.text('5:00 PM'), findsOneWidget);
    expect(find.text('5:30 PM'), findsOneWidget);
    expect(find.text('6:00 PM'), findsOneWidget);
    expect(find.text('6:30 PM'), findsOneWidget);
    expect(find.text('DEMO PRIMARY'), findsOneWidget);

    // Verify Role Switcher chips
    expect(find.text('Ramesh'), findsOneWidget);
    expect(find.text('Priya'), findsOneWidget);
    expect(find.text('Clinic Desk'), findsOneWidget);
  });

  test('P2: Switching to Clinic Desk updates projection and clinic views (TEST-PLAN controller test)', () async {
    expect(controller.actor.isPatient, isTrue);

    await controller.switchActor(DemoActorDirectory.clinicDesk.actor);

    expect(controller.actor.isClinic, isTrue);
    expect(controller.cards, hasLength(6));
    final slot1830 = controller.cards.firstWhere((s) => s.slotId == 'slot-1830');
    expect(slot1830.label, '6:30 PM');
  });
}
