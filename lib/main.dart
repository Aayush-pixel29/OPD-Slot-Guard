// OPD Slot Guard: Composition Root (02-HLD.md §11).

import 'package:flutter/material.dart';

import 'application/appointment_application.dart';
import 'application/demo_actor_directory.dart';
import 'infrastructure/demo_database.dart';
import 'infrastructure/sqlite_appointment_authority.dart';
import 'infrastructure/sqlite_appointment_read_model.dart';
import 'ports/clock.dart';
import 'ports/id_generator.dart';
import 'presentation/board_page.dart';
import 'presentation/clinic_board_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dbManager = DemoDatabaseManager();
  final db = await dbManager.open();
  const clock = SystemClock();
  final idGen = LocalIdGenerator();
  final directory = DemoActorDirectory();
  final chaosState = ChaosState();

  final authority = SqliteAppointmentAuthority(
    db: db,
    clock: clock,
    idGenerator: idGen,
    actorLookup: directory.findActor,
    chaos: chaosState,
  );

  final readModel = SqliteAppointmentReadModel(
    db: db,
    directory: directory,
  );

  final application = AppointmentApplication(
    authority: authority,
    idGenerator: idGen,
  );

  final controller = ClinicBoardController(
    application: application,
    readModel: readModel,
    directory: directory,
    chaosState: chaosState,
    db: db,
    onResetDatabase: dbManager.reset,
  );

  await controller.init();

  runApp(OpdSlotGuardApp(controller: controller));
}

class OpdSlotGuardApp extends StatelessWidget {
  const OpdSlotGuardApp({required this.controller, super.key});

  final ClinicBoardController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OPD Slot Guard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF006688),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: BoardPage(controller: controller),
    );
  }
}
