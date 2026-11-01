// SqliteAppointmentReadModel: Projection loader for patient and clinic views.
// (02-HLD.md §6, 03-LLD.md §9, Invariant 23).

import 'package:sqflite/sqflite.dart';

import '../application/demo_actor_directory.dart';
import '../domain/actor_policy.dart';
import '../domain/request_status.dart';
import '../domain/slot_capacity_policy.dart';
import '../ports/appointment_read_model.dart';

class SqliteAppointmentReadModel implements AppointmentReadModel {
  SqliteAppointmentReadModel({
    required this.db,
    required this.directory,
    this.capacityPolicy = const SlotCapacityPolicy(),
  });

  final Database db;
  final DemoActorDirectory directory;
  final SlotCapacityPolicy capacityPolicy;

  @override
  Future<BoardProjection> load(Actor actor) async {
    final slotRows = await db.query(
      'slots',
      orderBy: 'start_minute ASC',
    );

    final List<SlotCardModel> cards = [];

    for (final s in slotRows) {
      final slotId = s['slot_id'] as String;
      final label = s['label'] as String;
      final startMinute = s['start_minute'] as int;
      final capacity = s['capacity'] as int;
      final version = s['version'] as int;

      // Count confirmed patients for derived availability
      final confirmedRes = await db.rawQuery(
        "SELECT COUNT(*) as c FROM requests WHERE slot_id = ? AND status = 'CONFIRMED'",
        [slotId],
      );
      final confirmedCount = Sqflite.firstIntValue(confirmedRes) ?? 0;
      final availability = capacityPolicy.availabilityOf(
        capacity: capacity,
        confirmedCount: confirmedCount,
      );

      if (actor.isPatient) {
        // Patient projection (03-LLD.md §9):
        // STRICT PRIVACY: Query matches patient_id = actor.id ONLY.
        // Never selects or exposes another patient's identity.
        final myReqRows = await db.query(
          'requests',
          where: 'slot_id = ? AND patient_id = ?',
          whereArgs: [slotId, actor.id],
          orderBy: 'created_at DESC',
          limit: 1,
        );

        AppointmentRequest? myRequest;
        if (myReqRows.isNotEmpty) {
          final r = myReqRows.first;
          myRequest = AppointmentRequest(
            requestId: r['request_id'] as String,
            patientId: r['patient_id'] as String,
            slotId: r['slot_id'] as String,
            status: RequestStatus.fromWire(r['status'] as String),
            queueMs: r['queue_ms'] as int,
            version: r['version'] as int,
          );
        }

        cards.add(SlotCardModel(
          slotId: slotId,
          label: label,
          startMinute: startMinute,
          capacity: capacity,
          version: version,
          availability: availability,
          confirmedCount: confirmedCount,
          myRequest: myRequest,
          clinicRequests: const [], // Strict privacy: empty for patients
        ));
      } else {
        // Clinic projection:
        // Shows all active and recent terminal requests with display names
        final allReqRows = await db.query(
          'requests',
          where: 'slot_id = ?',
          whereArgs: [slotId],
          orderBy: '''
            CASE status
              WHEN 'CONFIRMED' THEN 1
              WHEN 'REQUESTED' THEN 2
              WHEN 'WAITLISTED' THEN 3
              WHEN 'DECLINED' THEN 4
              WHEN 'CANCELLED' THEN 5
              ELSE 6
            END,
            queue_ms ASC,
            request_id ASC
          ''',
        );

        final clinicRequests = allReqRows.map((r) {
          final patientId = r['patient_id'] as String;
          final displayName = directory.displayNameFor(patientId) ?? patientId;
          return ClinicRequestView(
            requestId: r['request_id'] as String,
            patientId: patientId,
            patientDisplayName: displayName,
            status: RequestStatus.fromWire(r['status'] as String),
            queueMs: r['queue_ms'] as int,
            version: r['version'] as int,
          );
        }).toList(growable: false);

        cards.add(SlotCardModel(
          slotId: slotId,
          label: label,
          startMinute: startMinute,
          capacity: capacity,
          version: version,
          availability: availability,
          confirmedCount: confirmedCount,
          myRequest: null,
          clinicRequests: clinicRequests,
        ));
      }
    }

    return BoardProjection(actor: actor, slots: cards);
  }
}

