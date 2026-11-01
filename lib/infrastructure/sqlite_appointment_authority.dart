// SqliteAppointmentAuthority: the single transactional authority for OPD Slot Guard.
// (02-HLD.md §4, 03-LLD.md §5, ADR-01, ADR-02, ADR-03).

import 'dart:convert';
import 'package:sqflite/sqflite.dart';

import '../domain/actor_policy.dart';
import '../domain/command_guard.dart';
import '../domain/failures.dart';
import '../domain/request_status.dart';
import '../domain/slot_capacity_policy.dart';
import '../ports/appointment_authority.dart';
import '../ports/clock.dart';
import '../ports/id_generator.dart';

enum ChaosArm { none, offline, abort, ackLost }

class ChaosState {
  ChaosState({this.armed = ChaosArm.none});

  ChaosArm armed;

  bool takeOffline() {
    if (armed == ChaosArm.offline) {
      armed = ChaosArm.none;
      return true;
    }
    return false;
  }

  bool takeAbort() {
    if (armed == ChaosArm.abort) {
      armed = ChaosArm.none;
      return true;
    }
    return false;
  }

  bool takeAckLost() {
    if (armed == ChaosArm.ackLost) {
      armed = ChaosArm.none;
      return true;
    }
    return false;
  }

  void reset() {
    armed = ChaosArm.none;
  }
}

class _StaleVersionRollbackException implements Exception {
  const _StaleVersionRollbackException();
}

class SqliteAppointmentAuthority implements AppointmentAuthority {
  SqliteAppointmentAuthority({
    required this.db,
    required this.clock,
    required this.idGenerator,
    required this.actorLookup,
    this.chaos,
    this.commandGuard = const CommandGuard(),
    this.capacityPolicy = const SlotCapacityPolicy(),
  });

  final Database db;
  final Clock clock;
  final IdGenerator idGenerator;
  final ActorLookup actorLookup;
  final ChaosState? chaos;
  final CommandGuard commandGuard;
  final SlotCapacityPolicy capacityPolicy;

  @override
  Future<CommandResult> submit(AppointmentCommand command) async {
    // Pipeline Step 0: Chaos offline check before BEGIN IMMEDIATE
    if (chaos?.takeOffline() ?? false) {
      throw const OfflineFailure();
    }

    try {
      return await db.transaction<CommandResult>((txn) async {
        // Step 1. Idempotency replay lookup
        final existingCommands = await txn.query(
          'commands',
          where: 'idempotency_key = ?',
          whereArgs: [command.idempotencyKey],
          limit: 1,
        );

        if (existingCommands.isNotEmpty) {
          final row = existingCommands.first;
          final existingHash = row['payload_hash'] as String;
          final existingCommandId = row['command_id'] as String;

          if (existingHash != command.fingerprint) {
            // Mismatch: append audit event referencing row.command_id
            await txn.insert('audit_events', {
              'event_id': idGenerator.newId('evt'),
              'command_id': existingCommandId,
              'entity_type': 'command',
              'entity_id': existingCommandId,
              'action': 'IDEMPOTENCY_PAYLOAD_MISMATCH',
              'from_status': null,
              'to_status': null,
              'actor_id': command.actorId,
              'at_ms': clock.nowMs(),
              'detail_json': jsonEncode({
                'receivedFingerprint': command.fingerprint,
                'storedFingerprint': existingHash,
              }),
            });

            return CommandResult(
              outcome: CommandOutcome.rejected,
              code: RejectionCode.idempotencyPayloadMismatch.wire,
              commandId: command.commandId,
              commandType: command.type,
              slot: null,
              request: null,
              effects: const [],
            );
          }

          // Exact matching key + payload hash: return stored result_json
          final storedResult = CommandResult.decode(
            row['result_json'] as String,
            replayed: true,
          );
          return storedResult;
        }

        // Re-read snapshot transactionally
        final nowMs = clock.nowMs();
        final slotRows = await txn.query(
          'slots',
          where: 'slot_id = ?',
          whereArgs: [command.slotId],
          limit: 1,
        );

        final Slot? currentSlot = slotRows.isEmpty
            ? null
            : Slot(
                slotId: slotRows.first['slot_id'] as String,
                label: slotRows.first['label'] as String,
                startMinute: slotRows.first['start_minute'] as int,
                capacity: slotRows.first['capacity'] as int,
                version: slotRows.first['version'] as int,
              );

        final requestRows = command.requestId.isEmpty
            ? <Map<String, Object?>>[]
            : await txn.query(
                'requests',
                where: 'request_id = ?',
                whereArgs: [command.requestId],
                limit: 1,
              );

        final AppointmentRequest? currentTarget = requestRows.isEmpty
            ? null
            : _mapRequest(requestRows.first);

        final liveRows = await txn.query(
          'requests',
          where: "slot_id = ? AND status IN ('REQUESTED', 'WAITLISTED', 'CONFIRMED')",
          whereArgs: [command.slotId],
          orderBy: 'queue_ms ASC, request_id ASC',
        );

        final liveRequests = liveRows.map(_mapRequest).toList(growable: false);

        final snapshot = GuardSnapshot(
          slot: currentSlot,
          target: currentTarget,
          liveRequestsOnSlot: liveRequests,
          nowMs: nowMs,
        );

        // Steps 2-6: Pure evaluation by CommandGuard
        final decision = commandGuard.evaluate(
          intent: command.intent,
          actor: actorLookup(command.actorId),
          snapshot: snapshot,
        );

        if (decision is GuardReject) {
          // If stale version: roll back and do NOT store a command row (ADR-02 §9)
          if (decision.code == RejectionCode.staleVersion) {
            throw const _StaleVersionRollbackException();
          }

          // Stored rejection for completed decisions
          final rejectionResult = CommandResult(
            outcome: CommandOutcome.rejected,
            code: decision.code.wire,
            commandId: command.commandId,
            commandType: command.type,
            slot: currentSlot == null
                ? null
                : SlotSnapshot(
                    slotId: currentSlot.slotId,
                    version: currentSlot.version,
                    capacity: currentSlot.capacity,
                    confirmedCount: snapshot.confirmedCount,
                    availability: capacityPolicy.availabilityOf(
                      capacity: currentSlot.capacity,
                      confirmedCount: snapshot.confirmedCount,
                    ),
                  ),
            request: currentTarget == null
                ? null
                : RequestSnapshot(
                    requestId: currentTarget.requestId,
                    patientId: currentTarget.patientId,
                    status: currentTarget.status,
                    version: currentTarget.version,
                    queueMs: currentTarget.queueMs,
                  ),
            effects: const [],
          );

          await txn.insert('commands', {
            'command_id': command.commandId,
            'idempotency_key': command.idempotencyKey,
            'payload_hash': command.fingerprint,
            'command_type': command.type.wire,
            'actor_id': command.actorId,
            'status': 'REJECTED',
            'result_json': rejectionResult.encode(),
            'created_at': nowMs,
            'attempt_count': 1,
          });

          await txn.insert('audit_events', {
            'event_id': idGenerator.newId('evt'),
            'command_id': command.commandId,
            'entity_type': 'command',
            'entity_id': command.commandId,
            'action': 'COMMAND_REJECTED',
            'from_status': null,
            'to_status': null,
            'actor_id': command.actorId,
            'at_ms': nowMs,
            'detail_json': jsonEncode({'code': decision.code.wire}),
          });

          if (chaos?.takeAbort() ?? false) {
            throw const TransactionAbortFailure('injected abort');
          }

          return rejectionResult;
        }

        final plan = decision as ApplyPlan;

        // Step 7: Atomic Apply with UPDATE ... WHERE version = expected
        if (plan.insert != null) {
          final ins = plan.insert!;
          await txn.insert('requests', {
            'request_id': ins.requestId,
            'patient_id': ins.patientId,
            'slot_id': ins.slotId,
            'status': ins.status.wire,
            'queue_ms': ins.queueMs,
            'version': ins.version,
            'created_at': nowMs,
            'updated_at': nowMs,
          });
        }

        for (final change in plan.changes) {
          final count = await txn.rawUpdate(
            'UPDATE requests SET status = ?, version = version + 1, updated_at = ? '
            'WHERE request_id = ? AND version = ?',
            [change.to.wire, nowMs, change.requestId, change.expectedVersion],
          );

          if (count != 1) {
            throw const _StaleVersionRollbackException();
          }
        }

        if (plan.bumpSlotVersion) {
          final count = await txn.rawUpdate(
            'UPDATE slots SET version = version + 1 WHERE slot_id = ? AND version = ?',
            [plan.slotId, plan.expectedSlotVersion],
          );

          if (count != 1) {
            throw const _StaleVersionRollbackException();
          }
        }

        // Integrity verification inside transaction (03-LLD.md §5 lines 312-316)
        final confirmedRows = await txn.rawQuery(
          "SELECT COUNT(*) as c FROM requests WHERE slot_id = ? AND status = 'CONFIRMED'",
          [plan.slotId],
        );
        final confirmedCount = Sqflite.firstIntValue(confirmedRows) ?? 0;

        final requestedRows = await txn.rawQuery(
          "SELECT COUNT(*) as c FROM requests WHERE slot_id = ? AND status = 'REQUESTED'",
          [plan.slotId],
        );
        final requestedCount = Sqflite.firstIntValue(requestedRows) ?? 0;

        if (confirmedCount > plan.capacity ||
            (confirmedCount >= plan.capacity && requestedCount > 0)) {
          throw const TransactionAbortFailure('capacity invariant violated');
        }

        // Build target request snapshot
        final targetRequest = plan.insert != null
            ? RequestSnapshot(
                requestId: plan.insert!.requestId,
                patientId: plan.insert!.patientId,
                status: plan.insert!.status,
                version: plan.insert!.version,
                queueMs: plan.insert!.queueMs,
              )
            : RequestSnapshot(
                requestId: currentTarget!.requestId,
                patientId: currentTarget.patientId,
                status: plan.changes
                    .firstWhere((c) => c.requestId == currentTarget.requestId)
                    .to,
                version: currentTarget.version + 1,
                queueMs: currentTarget.queueMs,
              );

        final successResult = CommandResult(
          outcome: CommandOutcome.applied,
          code: okCode,
          commandId: command.commandId,
          commandType: command.type,
          slot: SlotSnapshot(
            slotId: plan.slotId,
            version: plan.slotVersionAfter,
            capacity: plan.capacity,
            confirmedCount: confirmedCount,
            availability: capacityPolicy.availabilityOf(
              capacity: plan.capacity,
              confirmedCount: confirmedCount,
            ),
          ),
          request: targetRequest,
          effects: [
            for (final c in plan.changes)
              CommandEffect(
                requestId: c.requestId,
                from: c.from,
                to: c.to,
              ),
          ],
        );

        // Step 7a: Insert commands status=SUCCEEDED before audit_events (FK constraint)
        await txn.insert('commands', {
          'command_id': command.commandId,
          'idempotency_key': command.idempotencyKey,
          'payload_hash': command.fingerprint,
          'command_type': command.type.wire,
          'actor_id': command.actorId,
          'status': 'SUCCEEDED',
          'result_json': successResult.encode(),
          'created_at': nowMs,
          'attempt_count': 1,
        });

        // Step 7b: Insert audit events referencing command_id
        if (plan.insert != null) {
          final ins = plan.insert!;
          await txn.insert('audit_events', {
            'event_id': idGenerator.newId('evt'),
            'command_id': command.commandId,
            'entity_type': 'request',
            'entity_id': ins.requestId,
            'action': 'REQUEST_SLOT',
            'from_status': null,
            'to_status': ins.status.wire,
            'actor_id': command.actorId,
            'at_ms': nowMs,
            'detail_json': jsonEncode({
              'slotId': ins.slotId,
              'patientId': ins.patientId,
              'queueMs': ins.queueMs,
            }),
          });
        }

        for (final change in plan.changes) {
          final action = change.to == RequestStatus.confirmed
              ? 'CONFIRM_REQUEST'
              : change.to == RequestStatus.waitlisted
                  ? 'PARK_WAITLIST'
                  : change.to == RequestStatus.requested
                      ? 'RESTORE_REQUEST'
                      : change.to == RequestStatus.declined
                          ? 'DECLINE_REQUEST'
                          : 'CANCEL_REQUEST';

          await txn.insert('audit_events', {
            'event_id': idGenerator.newId('evt'),
            'command_id': command.commandId,
            'entity_type': 'request',
            'entity_id': change.requestId,
            'action': action,
            'from_status': change.from.wire,
            'to_status': change.to.wire,
            'actor_id': command.actorId,
            'at_ms': nowMs,
            'detail_json': jsonEncode({
              'slotId': plan.slotId,
              'fromVersion': change.expectedVersion,
              'toVersion': change.newVersion,
            }),
          });
        }

        if (plan.bumpSlotVersion) {
          await txn.insert('audit_events', {
            'event_id': idGenerator.newId('evt'),
            'command_id': command.commandId,
            'entity_type': 'slot',
            'entity_id': plan.slotId,
            'action': 'SLOT_VERSION_BUMP',
            'from_status': null,
            'to_status': null,
            'actor_id': command.actorId,
            'at_ms': nowMs,
            'detail_json': jsonEncode({
              'fromVersion': plan.expectedSlotVersion,
              'toVersion': plan.slotVersionAfter,
            }),
          });
        }

        if (chaos?.takeAbort() ?? false) {
          throw const TransactionAbortFailure('injected abort');
        }

        return successResult;
      }, exclusive: true);
    } on _StaleVersionRollbackException {
      return CommandResult(
        outcome: CommandOutcome.rejected,
        code: RejectionCode.staleVersion.wire,
        commandId: command.commandId,
        commandType: command.type,
        slot: null,
        request: null,
        effects: const [],
      );
    } finally {
      // Step 8: Chaos ACK_LOST injection after commit returns
      if (chaos?.takeAckLost() ?? false) {
        throw const AckLostFailure();
      }
    }
  }

  static AppointmentRequest _mapRequest(Map<String, Object?> map) {
    return AppointmentRequest(
      requestId: map['request_id'] as String,
      patientId: map['patient_id'] as String,
      slotId: map['slot_id'] as String,
      status: RequestStatus.fromWire(map['status'] as String),
      queueMs: map['queue_ms'] as int,
      version: map['version'] as int,
    );
  }
}
