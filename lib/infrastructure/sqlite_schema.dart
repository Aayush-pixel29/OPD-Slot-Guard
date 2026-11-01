// SQLite schema DDL and seed statements for OPD Slot Guard (03-LLD.md §2).
//
// Tables:
// - slots: bookable slots, versioned, capacity check-constrained to 1
// - requests: patient requests, status check-constrained to the five domain states
// - commands: insert-only log of decided commands and stored result_json
// - audit_events: append-only audit trail
//
// Constraints & Triggers:
// - PRAGMA foreign_keys = ON;
// - ux_one_confirmed_per_slot: partial unique index for capacity = 1
// - ux_one_live_request_per_patient_slot: prevents duplicate live requests
// - ix_requests_slot_status_queue: queue ordering index
// - ix_audit_entity: audit lookup index
// - commands_no_update / commands_no_delete: insert-only trigger
// - audit_no_update / audit_no_delete: append-only trigger

import 'package:sqflite/sqflite.dart';

class SeedSlot {
  const SeedSlot({
    required this.slotId,
    required this.label,
    required this.startMinute,
    this.capacity = 1,
    this.version = 0,
  });

  final String slotId;
  final String label;
  final int startMinute;
  final int capacity;
  final int version;
}

const List<SeedSlot> seedSlots = [
  SeedSlot(slotId: 'slot-1600', label: '4:00 PM', startMinute: 960),
  SeedSlot(slotId: 'slot-1630', label: '4:30 PM', startMinute: 990),
  SeedSlot(slotId: 'slot-1700', label: '5:00 PM', startMinute: 1020),
  SeedSlot(slotId: 'slot-1730', label: '5:30 PM', startMinute: 1050),
  SeedSlot(slotId: 'slot-1800', label: '6:00 PM', startMinute: 1080),
  SeedSlot(slotId: 'slot-1830', label: '6:30 PM', startMinute: 1110),
];

class SqliteSchema {
  const SqliteSchema._();

  static const List<String> ddlStatements = [
    '''
    CREATE TABLE slots (
      slot_id       TEXT PRIMARY KEY,
      label         TEXT NOT NULL,
      start_minute  INTEGER NOT NULL UNIQUE CHECK (start_minute >= 0 AND start_minute < 1440),
      capacity      INTEGER NOT NULL CHECK (capacity = 1),
      version       INTEGER NOT NULL CHECK (version >= 0)
    );
    ''',
    '''
    CREATE TABLE requests (
      request_id  TEXT PRIMARY KEY,
      patient_id  TEXT NOT NULL,
      slot_id     TEXT NOT NULL REFERENCES slots(slot_id),
      status      TEXT NOT NULL CHECK (status IN (
                    'REQUESTED','CONFIRMED','WAITLISTED','DECLINED','CANCELLED')),
      queue_ms    INTEGER NOT NULL,
      version     INTEGER NOT NULL CHECK (version >= 0),
      created_at  INTEGER NOT NULL,
      updated_at  INTEGER NOT NULL
    );
    ''',
    '''
    -- Prototype capacity enforcement for capacity = 1.
    -- Replaced when capacity becomes N. See ADR-03.
    CREATE UNIQUE INDEX ux_one_confirmed_per_slot
      ON requests(slot_id)
      WHERE status = 'CONFIRMED';
    ''',
    '''
    -- A second tap with a new idempotency key must not create a second live row.
    CREATE UNIQUE INDEX ux_one_live_request_per_patient_slot
      ON requests(patient_id, slot_id)
      WHERE status IN ('REQUESTED','WAITLISTED','CONFIRMED');
    ''',
    '''
    CREATE INDEX ix_requests_slot_status_queue
      ON requests(slot_id, status, queue_ms);
    ''',
    '''
    CREATE TABLE commands (
      command_id       TEXT PRIMARY KEY,
      idempotency_key  TEXT NOT NULL UNIQUE,
      payload_hash     TEXT NOT NULL,
      command_type     TEXT NOT NULL CHECK (command_type IN (
                         'RequestSlot','ConfirmRequest','DeclineRequest',
                         'CancelRequest','WaitlistRequest')),
      actor_id         TEXT NOT NULL,
      status           TEXT NOT NULL CHECK (status IN ('SUCCEEDED','REJECTED')),
      result_json      TEXT NOT NULL,
      created_at       INTEGER NOT NULL,
      attempt_count    INTEGER NOT NULL CHECK (attempt_count = 1)
    );
    ''',
    '''
    CREATE TRIGGER commands_no_update
    BEFORE UPDATE ON commands
    BEGIN
      SELECT RAISE(ABORT, 'commands are insert-only');
    END;
    ''',
    '''
    CREATE TRIGGER commands_no_delete
    BEFORE DELETE ON commands
    BEGIN
      SELECT RAISE(ABORT, 'commands are insert-only');
    END;
    ''',
    '''
    CREATE TABLE audit_events (
      event_id     TEXT PRIMARY KEY,
      command_id   TEXT NOT NULL REFERENCES commands(command_id),
      entity_type  TEXT NOT NULL CHECK (entity_type IN ('slot','request','command')),
      entity_id    TEXT NOT NULL,
      action       TEXT NOT NULL,
      from_status  TEXT,
      to_status    TEXT,
      actor_id     TEXT NOT NULL,
      at_ms        INTEGER NOT NULL,
      detail_json  TEXT NOT NULL
    );
    ''',
    '''
    CREATE INDEX ix_audit_entity ON audit_events(entity_id, at_ms);
    ''',
    '''
    CREATE TRIGGER audit_no_update
    BEFORE UPDATE ON audit_events
    BEGIN
      SELECT RAISE(ABORT, 'audit_events are append-only');
    END;
    ''',
    '''
    CREATE TRIGGER audit_no_delete
    BEFORE DELETE ON audit_events
    BEGIN
      SELECT RAISE(ABORT, 'audit_events are append-only');
    END;
    ''',
  ];

  static Future<void> createSchema(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON;');
    for (final sql in ddlStatements) {
      await db.execute(sql);
    }
  }

  static Future<void> seedInitialSlots(Database db) async {
    final batch = db.batch();
    for (final s in seedSlots) {
      batch.insert('slots', {
        'slot_id': s.slotId,
        'label': s.label,
        'start_minute': s.startMinute,
        'capacity': s.capacity,
        'version': s.version,
      });
    }
    await batch.commit(noResult: true);
  }
}

