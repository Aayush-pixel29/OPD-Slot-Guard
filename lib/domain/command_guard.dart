// CommandGuard: the pure decision for pipeline steps 2-6 (02-HLD.md §4,
// 03-LLD.md §3 and §5).
//
// The guard does not open a database and does not decide idempotency.
// Rule for this codebase: call CommandGuard only after the transactional
// re-read, inside the authority's BEGIN IMMEDIATE transaction.
//
// Pure Dart. No Flutter, sqflite, HTTP, Firebase, Gemini, or notifications.

import 'actor_policy.dart';
import 'command_fingerprint.dart';
import 'failures.dart';
import 'request_status.dart';
import 'slot_capacity_policy.dart';
import 'transition.dart';

/// The logical fields of a command that the guard needs.
///
/// There is intentionally no `queueMs` field: the client cannot supply it.
class CommandIntent {
  const CommandIntent({
    required this.type,
    required this.actorId,
    required this.slotId,
    required this.expectedSlotVersion,
    this.requestId,
    this.patientId,
    this.expectedRequestVersion,
  });

  final CommandType type;
  final String actorId;
  final String slotId;
  final String? requestId;

  /// RequestSlot only.
  final String? patientId;
  final int expectedSlotVersion;

  /// Null for RequestSlot, required otherwise.
  final int? expectedRequestVersion;
}

/// Rows read inside the transaction, before the guard runs.
class GuardSnapshot {
  const GuardSnapshot({
    required this.slot,
    required this.target,
    required this.liveRequestsOnSlot,
    required this.nowMs,
  });

  /// Null when `slot_id` does not exist.
  final Slot? slot;

  /// The row with the command's `request_id`, or null.
  final AppointmentRequest? target;

  /// Every `REQUESTED`, `WAITLISTED`, `CONFIRMED` row on the slot.
  final List<AppointmentRequest> liveRequestsOnSlot;

  /// Authority clock read inside the transaction. Becomes `queue_ms` on insert.
  final int nowMs;

  int get confirmedCount => liveRequestsOnSlot
      .where((r) => r.status == RequestStatus.confirmed)
      .length;
}

/// A new request row the plan will insert.
class RequestInsert {
  const RequestInsert({
    required this.requestId,
    required this.patientId,
    required this.slotId,
    required this.status,
    required this.queueMs,
  });

  final String requestId;
  final String patientId;
  final String slotId;
  final RequestStatus status;
  final int queueMs;

  /// Inserted rows start at version 0 (03-LLD.md §7).
  int get version => 0;
}

/// One versioned status update: `UPDATE ... WHERE version = expectedVersion`.
class StatusChange {
  const StatusChange({
    required this.requestId,
    required this.from,
    required this.to,
    required this.expectedVersion,
    required this.queueMs,
  });

  final String requestId;
  final RequestStatus from;
  final RequestStatus to;
  final int expectedVersion;

  /// Carried for audit ordering only. Updates never write `queue_ms`.
  final int queueMs;

  int get newVersion => expectedVersion + 1;
}

sealed class GuardDecision {
  const GuardDecision();
}

final class GuardReject extends GuardDecision {
  const GuardReject(this.code);

  final RejectionCode code;
}

/// Everything the adapter must write for one command, in one transaction.
final class ApplyPlan extends GuardDecision {
  const ApplyPlan({
    required this.slotId,
    required this.expectedSlotVersion,
    required this.bumpSlotVersion,
    required this.capacity,
    required this.confirmedCountAfter,
    required this.targetRequestId,
    required this.changes,
    this.insert,
  });

  final String slotId;
  final int expectedSlotVersion;

  /// True only when the confirmed set changes (confirm, cancel confirmed).
  final bool bumpSlotVersion;
  final int capacity;
  final int confirmedCountAfter;
  final String targetRequestId;

  /// RequestSlot only.
  final RequestInsert? insert;

  /// Target change first, then side effects in `queue_ms` order.
  final List<StatusChange> changes;

  int get slotVersionAfter =>
      bumpSlotVersion ? expectedSlotVersion + 1 : expectedSlotVersion;
}

class CommandGuard {
  const CommandGuard({
    this.capacityPolicy = const SlotCapacityPolicy(),
    this.actorPolicy = const ActorPolicy(),
  });

  final SlotCapacityPolicy capacityPolicy;
  final ActorPolicy actorPolicy;

  GuardDecision evaluate({
    required CommandIntent intent,
    required Actor? actor,
    required GuardSnapshot snapshot,
  }) {
    // Step 2. Entity existence.
    final slot = snapshot.slot;
    if (slot == null) return const GuardReject(RejectionCode.notFound);

    if (intent.type == CommandType.requestSlot) {
      return _evaluateRequestSlot(intent, actor, snapshot, slot);
    }

    final target = snapshot.target;
    if (target == null || target.slotId != intent.slotId) {
      return const GuardReject(RejectionCode.notFound);
    }

    // Step 3. Actor authorization, against the row's owner.
    if (!actorPolicy.isAllowed(
      actor: actor,
      type: intent.type,
      patientId: target.patientId,
    )) {
      return const GuardReject(RejectionCode.forbidden);
    }

    // Step 4. Legal transition.
    final to = _targetStatusFor(intent.type);
    if (legalTransition(target.status, to) ==
        TransitionVerdict.illegalTransition) {
      return const GuardReject(RejectionCode.illegalTransition);
    }

    // Step 5. Version validation against the transactional re-read.
    if (slot.version != intent.expectedSlotVersion ||
        target.version != intent.expectedRequestVersion) {
      return const GuardReject(RejectionCode.staleVersion);
    }

    // Step 6. Policy and the apply plan.
    switch (intent.type) {
      case CommandType.confirmRequest:
        return _planConfirm(slot, target, snapshot);
      case CommandType.cancelRequest:
        return _planCancel(slot, target, snapshot);
      case CommandType.declineRequest:
      case CommandType.waitlistRequest:
        return _planSingleRow(slot, target, to, snapshot);
      case CommandType.requestSlot:
        throw StateError('unreachable');
    }
  }

  GuardDecision _evaluateRequestSlot(
    CommandIntent intent,
    Actor? actor,
    GuardSnapshot snapshot,
    Slot slot,
  ) {
    final requestId = intent.requestId;
    final patientId = intent.patientId;

    // Step 3. Authorization uses the payload patient.
    if (!actorPolicy.isAllowed(
      actor: actor,
      type: CommandType.requestSlot,
      patientId: patientId,
    )) {
      return const GuardReject(RejectionCode.forbidden);
    }
    if (requestId == null || patientId == null) {
      return const GuardReject(RejectionCode.notFound);
    }

    // Step 4. Creation is not a transition. Step 5. Slot version.
    if (slot.version != intent.expectedSlotVersion) {
      return const GuardReject(RejectionCode.staleVersion);
    }

    // Step 6. One live row per patient per slot. A request id that already
    // exists (from an earlier, different gesture) is treated the same way so
    // the insert never collides with a primary key.
    final hasLive =
        snapshot.liveRequestsOnSlot.any((r) => r.patientId == patientId);
    if (hasLive || snapshot.target != null) {
      return const GuardReject(RejectionCode.alreadyActive);
    }

    final confirmedCount = snapshot.confirmedCount;
    final admit = capacityPolicy.canAdmitConfirmation(
      capacity: slot.capacity,
      confirmedCount: confirmedCount,
    );
    return ApplyPlan(
      slotId: slot.slotId,
      expectedSlotVersion: slot.version,
      bumpSlotVersion: false,
      capacity: slot.capacity,
      confirmedCountAfter: confirmedCount,
      targetRequestId: requestId,
      insert: RequestInsert(
        requestId: requestId,
        patientId: patientId,
        slotId: slot.slotId,
        status: admit ? RequestStatus.requested : RequestStatus.waitlisted,
        queueMs: snapshot.nowMs,
      ),
      changes: const [],
    );
  }

  GuardDecision _planConfirm(
    Slot slot,
    AppointmentRequest target,
    GuardSnapshot snapshot,
  ) {
    final confirmedCount = snapshot.confirmedCount;
    if (!capacityPolicy.canAdmitConfirmation(
      capacity: slot.capacity,
      confirmedCount: confirmedCount,
    )) {
      return const GuardReject(RejectionCode.capacityExceeded);
    }

    final confirmedAfter = confirmedCount + 1;
    final changes = <StatusChange>[
      _change(target, RequestStatus.confirmed),
    ];

    // When this confirm reaches capacity, park every other REQUESTED row.
    // The loop does not encode the number 1 (ADR-03).
    final reachesCapacity = !capacityPolicy.canAdmitConfirmation(
      capacity: slot.capacity,
      confirmedCount: confirmedAfter,
    );
    if (reachesCapacity) {
      final siblings = _ordered(snapshot.liveRequestsOnSlot.where(
        (r) =>
            r.requestId != target.requestId &&
            r.status == RequestStatus.requested,
      ));
      for (final sibling in siblings) {
        changes.add(_change(sibling, RequestStatus.waitlisted));
      }
    }

    return ApplyPlan(
      slotId: slot.slotId,
      expectedSlotVersion: slot.version,
      bumpSlotVersion: true,
      capacity: slot.capacity,
      confirmedCountAfter: confirmedAfter,
      targetRequestId: target.requestId,
      changes: changes,
    );
  }

  GuardDecision _planCancel(
    Slot slot,
    AppointmentRequest target,
    GuardSnapshot snapshot,
  ) {
    if (target.status != RequestStatus.confirmed) {
      // Cancel REQUESTED or WAITLISTED: only that row, availability untouched.
      return _planSingleRow(slot, target, RequestStatus.cancelled, snapshot);
    }

    // Golden reopen: CONFIRMED -> CANCELLED reopens capacity, then every
    // WAITLISTED row on the slot returns to REQUESTED in queue order
    // (01-SOLUTION-BRIEF invariant 5, 02-HLD §5). Nobody is confirmed.
    final changes = <StatusChange>[
      _change(target, RequestStatus.cancelled),
    ];
    final waitlisted = _ordered(snapshot.liveRequestsOnSlot.where(
      (r) =>
          r.requestId != target.requestId &&
          r.status == RequestStatus.waitlisted,
    ));
    for (final row in waitlisted) {
      changes.add(_change(row, RequestStatus.requested));
    }

    return ApplyPlan(
      slotId: slot.slotId,
      expectedSlotVersion: slot.version,
      bumpSlotVersion: true,
      capacity: slot.capacity,
      confirmedCountAfter: snapshot.confirmedCount - 1,
      targetRequestId: target.requestId,
      changes: changes,
    );
  }

  ApplyPlan _planSingleRow(
    Slot slot,
    AppointmentRequest target,
    RequestStatus to,
    GuardSnapshot snapshot,
  ) {
    return ApplyPlan(
      slotId: slot.slotId,
      expectedSlotVersion: slot.version,
      bumpSlotVersion: false,
      capacity: slot.capacity,
      confirmedCountAfter: snapshot.confirmedCount,
      targetRequestId: target.requestId,
      changes: [_change(target, to)],
    );
  }

  static RequestStatus _targetStatusFor(CommandType type) {
    switch (type) {
      case CommandType.confirmRequest:
        return RequestStatus.confirmed;
      case CommandType.declineRequest:
        return RequestStatus.declined;
      case CommandType.cancelRequest:
        return RequestStatus.cancelled;
      case CommandType.waitlistRequest:
        return RequestStatus.waitlisted;
      case CommandType.requestSlot:
        throw StateError('RequestSlot is a creation, not a transition');
    }
  }

  static StatusChange _change(AppointmentRequest row, RequestStatus to) {
    // Side effects obey the same table as the target change.
    if (legalTransition(row.status, to) != TransitionVerdict.allowed) {
      throw StateError(
          'plan built an illegal transition ${row.status.wire} -> ${to.wire}');
    }
    return StatusChange(
      requestId: row.requestId,
      from: row.status,
      to: to,
      expectedVersion: row.version,
      queueMs: row.queueMs,
    );
  }

  static List<AppointmentRequest> _ordered(
    Iterable<AppointmentRequest> rows,
  ) {
    return rows.toList()..sort(compareQueueOrder);
  }
}
