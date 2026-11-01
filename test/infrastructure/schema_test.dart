// Schema tests for tables, indexes, constraints, triggers, and seed data.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import '../support/ffi_database.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await openTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  test('seeded slots count is 6 and primary slot-1830 exists with capacity 1', () async {
    final slots = await db.query('slots', orderBy: 'start_minute ASC');
    expect(slots, hasLength(6));
    expect(slots.map((s) => s['slot_id']), [
      'slot-1600',
      'slot-1630',
      'slot-1700',
      'slot-1730',
      'slot-1800',
      'slot-1830',
    ]);
    final slot1830 = slots.firstWhere((s) => s['slot_id'] == 'slot-1830');
    expect(slot1830['capacity'], 1);
    expect(slot1830['version'], 0);
  });

  test('slots.capacity = 1 check constraint blocks capacity != 1', () async {
    expect(
      () => db.insert('slots', {
        'slot_id': 'slot-test',
        'label': 'Test',
        'start_minute': 100,
        'capacity': 2,
        'version': 0,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('foreign keys are enforced on requests table', () async {
    expect(
      () => db.insert('requests', {
        'request_id': 'req-bad-slot',
        'patient_id': 'patient-ramesh',
        'slot_id': 'slot-nonexistent',
        'status': 'REQUESTED',
        'queue_ms': 1000,
        'version': 0,
        'created_at': 1000,
        'updated_at': 1000,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('requests status check constraint rejects invalid statuses', () async {
    expect(
      () => db.insert('requests', {
        'request_id': 'req-bad-status',
        'patient_id': 'patient-ramesh',
        'slot_id': 'slot-1830',
        'status': 'PROMOTED',
        'queue_ms': 1000,
        'version': 0,
        'created_at': 1000,
        'updated_at': 1000,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('ux_one_confirmed_per_slot index prevents two CONFIRMED rows for same slot', () async {
    await db.insert('requests', {
      'request_id': 'req-1',
      'patient_id': 'patient-ramesh',
      'slot_id': 'slot-1830',
      'status': 'CONFIRMED',
      'queue_ms': 1000,
      'version': 1,
      'created_at': 1000,
      'updated_at': 1000,
    });

    expect(
      () => db.insert('requests', {
        'request_id': 'req-2',
        'patient_id': 'patient-priya',
        'slot_id': 'slot-1830',
        'status': 'CONFIRMED',
        'queue_ms': 2000,
        'version': 1,
        'created_at': 2000,
        'updated_at': 2000,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('ux_one_live_request_per_patient_slot prevents duplicate live requests', () async {
    await db.insert('requests', {
      'request_id': 'req-1',
      'patient_id': 'patient-ramesh',
      'slot_id': 'slot-1830',
      'status': 'REQUESTED',
      'queue_ms': 1000,
      'version': 0,
      'created_at': 1000,
      'updated_at': 1000,
    });

    expect(
      () => db.insert('requests', {
        'request_id': 'req-2',
        'patient_id': 'patient-ramesh',
        'slot_id': 'slot-1830',
        'status': 'REQUESTED',
        'queue_ms': 2000,
        'version': 0,
        'created_at': 2000,
        'updated_at': 2000,
      }),
      throwsA(isA<DatabaseException>()),
    );

    // After CANCELLED (terminal), patient can request again
    await db.update(
      'requests',
      {'status': 'CANCELLED', 'version': 1},
      where: 'request_id = ?',
      whereArgs: ['req-1'],
    );

    final id = await db.insert('requests', {
      'request_id': 'req-3',
      'patient_id': 'patient-ramesh',
      'slot_id': 'slot-1830',
      'status': 'REQUESTED',
      'queue_ms': 3000,
      'version': 0,
      'created_at': 3000,
      'updated_at': 3000,
    });
    expect(id, isPositive);
  });

  test('I21 commands_no_update trigger raises abort on UPDATE', () async {
    await db.insert('commands', {
      'command_id': 'cmd-1',
      'idempotency_key': 'key-1',
      'payload_hash': 'hash-1',
      'command_type': 'ConfirmRequest',
      'actor_id': 'clinic-desk',
      'status': 'SUCCEEDED',
      'result_json': '{}',
      'created_at': 1000,
      'attempt_count': 1,
    });

    expect(
      () => db.update(
        'commands',
        {'status': 'REJECTED'},
        where: 'command_id = ?',
        whereArgs: ['cmd-1'],
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('commands_no_delete trigger raises abort on DELETE', () async {
    await db.insert('commands', {
      'command_id': 'cmd-1',
      'idempotency_key': 'key-1',
      'payload_hash': 'hash-1',
      'command_type': 'ConfirmRequest',
      'actor_id': 'clinic-desk',
      'status': 'SUCCEEDED',
      'result_json': '{}',
      'created_at': 1000,
      'attempt_count': 1,
    });

    expect(
      () => db.delete('commands', where: 'command_id = ?', whereArgs: ['cmd-1']),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('I19 audit_no_update trigger raises abort on UPDATE', () async {
    await db.insert('commands', {
      'command_id': 'cmd-1',
      'idempotency_key': 'key-1',
      'payload_hash': 'hash-1',
      'command_type': 'ConfirmRequest',
      'actor_id': 'clinic-desk',
      'status': 'SUCCEEDED',
      'result_json': '{}',
      'created_at': 1000,
      'attempt_count': 1,
    });

    await db.insert('audit_events', {
      'event_id': 'evt-1',
      'command_id': 'cmd-1',
      'entity_type': 'request',
      'entity_id': 'req-1',
      'action': 'CONFIRM',
      'from_status': 'REQUESTED',
      'to_status': 'CONFIRMED',
      'actor_id': 'clinic-desk',
      'at_ms': 1000,
      'detail_json': '{}',
    });

    expect(
      () => db.update(
        'audit_events',
        {'action': 'HACK'},
        where: 'event_id = ?',
        whereArgs: ['evt-1'],
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('I20 audit_no_delete trigger raises abort on DELETE', () async {
    await db.insert('commands', {
      'command_id': 'cmd-1',
      'idempotency_key': 'key-1',
      'payload_hash': 'hash-1',
      'command_type': 'ConfirmRequest',
      'actor_id': 'clinic-desk',
      'status': 'SUCCEEDED',
      'result_json': '{}',
      'created_at': 1000,
      'attempt_count': 1,
    });

    await db.insert('audit_events', {
      'event_id': 'evt-1',
      'command_id': 'cmd-1',
      'entity_type': 'request',
      'entity_id': 'req-1',
      'action': 'CONFIRM',
      'from_status': 'REQUESTED',
      'to_status': 'CONFIRMED',
      'actor_id': 'clinic-desk',
      'at_ms': 1000,
      'detail_json': '{}',
    });

    expect(
      () => db.delete('audit_events', where: 'event_id = ?', whereArgs: ['evt-1']),
      throwsA(isA<DatabaseException>()),
    );
  });
}
