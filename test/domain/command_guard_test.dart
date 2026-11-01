// D9-D13 and the guard's pipeline steps 2-6, with no database.

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/domain/actor_policy.dart';
import 'package:opd_slot_guard/domain/command_fingerprint.dart';
import 'package:opd_slot_guard/domain/command_guard.dart';
import 'package:opd_slot_guard/domain/failures.dart';
import 'package:opd_slot_guard/domain/request_status.dart';

const ramesh = Actor(id: 'patient-ramesh', role: ActorRole.patient);
const priya = Actor(id: 'patient-priya', role: ActorRole.patient);
const desk = Actor(id: 'clinic-desk', role: ActorRole.clinic);

const slotId = 'slot-1830';

Slot slot({int version = 0, int capacity = 1}) => Slot(
      slotId: slotId,
      label: '6:30 PM',
      startMinute: 1110,
      capacity: capacity,
      version: version,
    );

AppointmentRequest row(
  String id,
  String patient,
  RequestStatus status, {
  int queueMs = 1000,
  int version = 0,
  String onSlot = slotId,
}) =>
    AppointmentRequest(
      requestId: id,
      patientId: patient,
      slotId: onSlot,
      status: status,
      queueMs: queueMs,
      version: version,
    );

CommandIntent transition(
  CommandType type,
  String requestId, {
  String actorId = 'clinic-desk',
  int slotVersion = 0,
  int requestVersion = 0,
}) =>
    CommandIntent(
      type: type,
      actorId: actorId,
      slotId: slotId,
      requestId: requestId,
      expectedSlotVersion: slotVersion,
      expectedRequestVersion: requestVersion,
    );

CommandIntent requestSlot(String patient,
        {String requestId = 'req-new', int slotVersion = 0}) =>
    CommandIntent(
      type: CommandType.requestSlot,
      actorId: patient,
      slotId: slotId,
      requestId: requestId,
      patientId: patient,
      expectedSlotVersion: slotVersion,
    );

GuardDecision run(
  CommandIntent intent,
  Actor? actor, {
  Slot? onSlot,
  bool slotMissing = false,
  List<AppointmentRequest> live = const [],
  AppointmentRequest? target,
  int nowMs = 5000,
}) {
  final resolvedTarget = target ??
      live.where((r) => r.requestId == intent.requestId).firstOrNull;
  return const CommandGuard().evaluate(
    intent: intent,
    actor: actor,
    snapshot: GuardSnapshot(
      slot: slotMissing ? null : (onSlot ?? slot()),
      target: resolvedTarget,
      liveRequestsOnSlot: live,
      nowMs: nowMs,
    ),
  );
}

RejectionCode rejected(GuardDecision d) {
  expect(d, isA<GuardReject>());
  return (d as GuardReject).code;
}

ApplyPlan plan(GuardDecision d) {
  expect(d, isA<ApplyPlan>(),
      reason: d is GuardReject ? 'rejected ${d.code.wire}' : null);
  return d as ApplyPlan;
}

List<(String, RequestStatus, RequestStatus)> effects(ApplyPlan p) =>
    [for (final c in p.changes) (c.requestId, c.from, c.to)];

void main() {
  group('RequestSlot', () {
    test('D9 patient RequestSlot for own id plans an insert as REQUESTED', () {
      final p = plan(run(requestSlot('patient-ramesh'), ramesh, nowMs: 1000));
      expect(p.insert, isNotNull);
      expect(p.insert!.status, RequestStatus.requested);
      expect(p.insert!.patientId, 'patient-ramesh');
      expect(p.insert!.queueMs, 1000, reason: 'queue_ms is the authority clock');
      expect(p.insert!.version, 0);
      expect(p.bumpSlotVersion, isFalse,
          reason: 'occupancy does not change on request');
      expect(p.changes, isEmpty);
    });

    test('I8 (domain) request while BOOKED inserts WAITLISTED, not REQUESTED',
        () {
      final p = plan(run(requestSlot('patient-priya', slotVersion: 1), priya,
          onSlot: slot(version: 1),
          live: [
            row('req-r', 'patient-ramesh', RequestStatus.confirmed, version: 1)
          ]));
      expect(p.insert!.status, RequestStatus.waitlisted);
    });

    test('D8 clinic cannot file a patient request', () {
      final intent = CommandIntent(
        type: CommandType.requestSlot,
        actorId: 'clinic-desk',
        slotId: slotId,
        requestId: 'req-new',
        patientId: 'patient-ramesh',
        expectedSlotVersion: 0,
      );
      expect(rejected(run(intent, desk)), RejectionCode.forbidden);
    });

    test('patient cannot request on behalf of another patient', () {
      final intent = CommandIntent(
        type: CommandType.requestSlot,
        actorId: 'patient-ramesh',
        slotId: slotId,
        requestId: 'req-new',
        patientId: 'patient-priya',
        expectedSlotVersion: 0,
      );
      expect(rejected(run(intent, ramesh)), RejectionCode.forbidden);
    });

    test('second live request for same patient and slot is ALREADY_ACTIVE', () {
      for (final status in [
        RequestStatus.requested,
        RequestStatus.waitlisted,
        RequestStatus.confirmed,
      ]) {
        expect(
            rejected(run(requestSlot('patient-ramesh'), ramesh,
                live: [row('req-old', 'patient-ramesh', status)])),
            RejectionCode.alreadyActive,
            reason: status.wire);
      }
    });

    test('request again after own CANCELLED row is allowed (new row)', () {
      // Terminal rows are not live and are not in liveRequestsOnSlot.
      final p = plan(run(requestSlot('patient-ramesh', requestId: 'req-2'),
          ramesh));
      expect(p.insert!.requestId, 'req-2');
    });

    test('unknown slot is NOT_FOUND', () {
      expect(rejected(run(requestSlot('patient-ramesh'), ramesh, slotMissing: true)),
          RejectionCode.notFound);
    });

    test('stale slot version is STALE_VERSION', () {
      expect(
          rejected(run(requestSlot('patient-ramesh', slotVersion: 0), ramesh,
              onSlot: slot(version: 2))),
          RejectionCode.staleVersion);
    });
  });

  group('ConfirmRequest', () {
    test('D10 confirm parks the REQUESTED sibling and bumps slot version', () {
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.requested, queueMs: 1000),
        row('req-p', 'patient-priya', RequestStatus.requested, queueMs: 2000),
      ];
      final p = plan(run(transition(CommandType.confirmRequest, 'req-r'), desk,
          live: live));
      expect(effects(p), [
        ('req-r', RequestStatus.requested, RequestStatus.confirmed),
        ('req-p', RequestStatus.requested, RequestStatus.waitlisted),
      ]);
      expect(p.bumpSlotVersion, isTrue);
      expect(p.slotVersionAfter, 1);
      expect(p.confirmedCountAfter, 1);
      expect(
          p.changes.where((c) => c.to == RequestStatus.confirmed).length, 1,
          reason: 'nobody else CONFIRMED');
      for (final c in p.changes) {
        expect(c.newVersion, c.expectedVersion + 1);
      }
    });

    test('confirm parks multiple siblings in queue_ms then request_id order', () {
      final live = [
        row('req-t', 'patient-t', RequestStatus.requested, queueMs: 9000),
        row('req-b', 'patient-b', RequestStatus.requested, queueMs: 3000),
        row('req-a', 'patient-a', RequestStatus.requested, queueMs: 3000),
        row('req-x', 'patient-x', RequestStatus.requested, queueMs: 1000),
      ];
      final p = plan(run(transition(CommandType.confirmRequest, 'req-t'), desk,
          live: live));
      expect(p.changes.map((c) => c.requestId),
          ['req-t', 'req-x', 'req-a', 'req-b']);
    });

    test('confirm does not touch already WAITLISTED rows', () {
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.requested),
        row('req-w', 'patient-w', RequestStatus.waitlisted),
      ];
      final p = plan(run(transition(CommandType.confirmRequest, 'req-r'), desk,
          live: live));
      expect(p.changes.map((c) => c.requestId), ['req-r']);
    });

    test('I1 (domain) second confirm on a full slot is CAPACITY_EXCEEDED', () {
      // A REQUESTED row on a full slot cannot exist after a correct confirm,
      // but the policy must still refuse if one is presented.
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.confirmed, version: 1),
        row('req-p', 'patient-priya', RequestStatus.requested),
      ];
      expect(
          rejected(run(transition(CommandType.confirmRequest, 'req-p',
                  slotVersion: 1),
              desk, onSlot: slot(version: 1), live: live)),
          RejectionCode.capacityExceeded);
    });

    test('I5 (domain) WAITLISTED -> CONFIRMED is ILLEGAL_TRANSITION', () {
      final live = [row('req-p', 'patient-priya', RequestStatus.waitlisted)];
      expect(
          rejected(run(transition(CommandType.confirmRequest, 'req-p'), desk,
              live: live)),
          RejectionCode.illegalTransition);
    });

    test('D6 patient confirm is FORBIDDEN, even of own row', () {
      final live = [row('req-r', 'patient-ramesh', RequestStatus.requested)];
      expect(
          rejected(run(
              transition(CommandType.confirmRequest, 'req-r',
                  actorId: 'patient-ramesh'),
              ramesh,
              live: live)),
          RejectionCode.forbidden);
    });

    test('unknown actor is FORBIDDEN', () {
      final live = [row('req-r', 'patient-ramesh', RequestStatus.requested)];
      expect(
          rejected(run(
              transition(CommandType.confirmRequest, 'req-r',
                  actorId: 'patient-mallory'),
              null,
              live: live)),
          RejectionCode.forbidden);
    });

    test('missing request is NOT_FOUND', () {
      expect(
          rejected(run(transition(CommandType.confirmRequest, 'req-none'), desk)),
          RejectionCode.notFound);
    });

    test('request on a different slot is NOT_FOUND', () {
      final other = row('req-r', 'patient-ramesh', RequestStatus.requested,
          onSlot: 'slot-1600');
      expect(
          rejected(run(transition(CommandType.confirmRequest, 'req-r'), desk,
              target: other)),
          RejectionCode.notFound);
    });

    test('stale slot version is STALE_VERSION', () {
      final live = [row('req-r', 'patient-ramesh', RequestStatus.requested)];
      expect(
          rejected(run(transition(CommandType.confirmRequest, 'req-r'), desk,
              onSlot: slot(version: 3), live: live)),
          RejectionCode.staleVersion);
    });

    test('stale request version is STALE_VERSION', () {
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.requested, version: 2)
      ];
      expect(
          rejected(run(
              transition(CommandType.confirmRequest, 'req-r', requestVersion: 1),
              desk,
              live: live)),
          RejectionCode.staleVersion);
    });

    test('pipeline order: transition is checked before version', () {
      // Stale screen tries to confirm a row that is already CONFIRMED.
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.confirmed, version: 1)
      ];
      expect(
          rejected(run(transition(CommandType.confirmRequest, 'req-r'), desk,
              onSlot: slot(version: 1), live: live)),
          RejectionCode.illegalTransition);
    });

    test('pipeline order: authorization is checked before transition', () {
      final live = [row('req-p', 'patient-priya', RequestStatus.declined)];
      expect(
          rejected(run(
              transition(CommandType.cancelRequest, 'req-p',
                  actorId: 'patient-ramesh'),
              ramesh,
              target: live.single)),
          RejectionCode.forbidden);
    });
  });

  group('CancelRequest', () {
    test('D11 cancel CONFIRMED restores every WAITLISTED in queue order, '
        'confirms nobody', () {
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.confirmed,
            queueMs: 1000, version: 1),
        row('req-late', 'patient-late', RequestStatus.waitlisted,
            queueMs: 3000, version: 1),
        row('req-p', 'patient-priya', RequestStatus.waitlisted,
            queueMs: 2000, version: 1),
      ];
      final p = plan(run(
          transition(CommandType.cancelRequest, 'req-r',
              actorId: 'patient-ramesh', slotVersion: 1, requestVersion: 1),
          ramesh,
          onSlot: slot(version: 1),
          live: live));
      expect(effects(p), [
        ('req-r', RequestStatus.confirmed, RequestStatus.cancelled),
        ('req-p', RequestStatus.waitlisted, RequestStatus.requested),
        ('req-late', RequestStatus.waitlisted, RequestStatus.requested),
      ]);
      expect(p.changes.any((c) => c.to == RequestStatus.confirmed), isFalse,
          reason: 'reopen never auto-confirms');
      expect(p.bumpSlotVersion, isTrue);
      expect(p.slotVersionAfter, 2);
      expect(p.confirmedCountAfter, 0);
    });

    test('D12 cancel REQUESTED changes only that row, slot version unchanged',
        () {
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.requested),
        row('req-p', 'patient-priya', RequestStatus.requested),
      ];
      final p = plan(run(
          transition(CommandType.cancelRequest, 'req-r',
              actorId: 'patient-ramesh'),
          ramesh,
          live: live));
      expect(effects(p),
          [('req-r', RequestStatus.requested, RequestStatus.cancelled)]);
      expect(p.bumpSlotVersion, isFalse);
    });

    test('D13 cancel WAITLISTED changes only that row, slot version unchanged',
        () {
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.confirmed, version: 1),
        row('req-p', 'patient-priya', RequestStatus.waitlisted, version: 1),
        row('req-q', 'patient-q', RequestStatus.waitlisted, version: 1),
      ];
      final p = plan(run(
          transition(CommandType.cancelRequest, 'req-p',
              actorId: 'patient-priya', slotVersion: 1, requestVersion: 1),
          priya,
          onSlot: slot(version: 1),
          live: live));
      expect(effects(p),
          [('req-p', RequestStatus.waitlisted, RequestStatus.cancelled)]);
      expect(p.bumpSlotVersion, isFalse);
      expect(p.confirmedCountAfter, 1);
    });

    test('D7 patient cancel of another patient row is FORBIDDEN', () {
      final live = [row('req-p', 'patient-priya', RequestStatus.requested)];
      expect(
          rejected(run(
              transition(CommandType.cancelRequest, 'req-p',
                  actorId: 'patient-ramesh'),
              ramesh,
              live: live)),
          RejectionCode.forbidden);
    });

    test('clinic may cancel a confirmed row; reopen still does not confirm', () {
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.confirmed, version: 1),
        row('req-p', 'patient-priya', RequestStatus.waitlisted, version: 1),
      ];
      final p = plan(run(
          transition(CommandType.cancelRequest, 'req-r',
              slotVersion: 1, requestVersion: 1),
          desk,
          onSlot: slot(version: 1),
          live: live));
      expect(effects(p).last,
          ('req-p', RequestStatus.waitlisted, RequestStatus.requested));
    });

    test('cancel of a terminal row is ILLEGAL_TRANSITION', () {
      final cancelled = row('req-r', 'patient-ramesh', RequestStatus.cancelled);
      expect(
          rejected(run(
              transition(CommandType.cancelRequest, 'req-r',
                  actorId: 'patient-ramesh'),
              ramesh,
              target: cancelled)),
          RejectionCode.illegalTransition);
    });
  });

  group('DeclineRequest and WaitlistRequest', () {
    test('I7 (domain) decline REQUESTED changes only that row', () {
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.requested),
        row('req-p', 'patient-priya', RequestStatus.requested),
      ];
      final p = plan(run(transition(CommandType.declineRequest, 'req-p'), desk,
          live: live));
      expect(effects(p),
          [('req-p', RequestStatus.requested, RequestStatus.declined)]);
      expect(p.bumpSlotVersion, isFalse);
    });

    test('decline WAITLISTED is allowed', () {
      final live = [row('req-p', 'patient-priya', RequestStatus.waitlisted)];
      plan(run(transition(CommandType.declineRequest, 'req-p'), desk,
          live: live));
    });

    test('I6 (domain) decline CONFIRMED is ILLEGAL_TRANSITION', () {
      final live = [
        row('req-r', 'patient-ramesh', RequestStatus.confirmed, version: 1)
      ];
      expect(
          rejected(run(
              transition(CommandType.declineRequest, 'req-r',
                  slotVersion: 1, requestVersion: 1),
              desk,
              onSlot: slot(version: 1),
              live: live)),
          RejectionCode.illegalTransition);
    });

    test('explicit waitlist REQUESTED -> WAITLISTED, occupancy unchanged', () {
      final live = [row('req-p', 'patient-priya', RequestStatus.requested)];
      final p = plan(run(transition(CommandType.waitlistRequest, 'req-p'), desk,
          live: live));
      expect(effects(p),
          [('req-p', RequestStatus.requested, RequestStatus.waitlisted)]);
      expect(p.bumpSlotVersion, isFalse);
    });

    test('waitlist of WAITLISTED is a self-transition: ILLEGAL_TRANSITION', () {
      final live = [row('req-p', 'patient-priya', RequestStatus.waitlisted)];
      expect(
          rejected(run(transition(CommandType.waitlistRequest, 'req-p'), desk,
              live: live)),
          RejectionCode.illegalTransition);
    });

    test('patient decline or waitlist is FORBIDDEN', () {
      final live = [row('req-r', 'patient-ramesh', RequestStatus.requested)];
      for (final type in [
        CommandType.declineRequest,
        CommandType.waitlistRequest,
      ]) {
        expect(
            rejected(run(transition(type, 'req-r', actorId: 'patient-ramesh'),
                ramesh,
                live: live)),
            RejectionCode.forbidden);
      }
    });
  });

  test('capacity other than 1 fails closed inside the guard', () {
    final live = [row('req-r', 'patient-ramesh', RequestStatus.requested)];
    expect(
        () => run(transition(CommandType.confirmRequest, 'req-r'), desk,
            onSlot: slot(capacity: 2), live: live),
        throwsA(isA<CapacitySeamException>()));
  });
}
