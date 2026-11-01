// AppointmentAuthority: the only mutation port (02-HLD.md §3, ADR-01).
//
// Prototype implementation: SqliteAppointmentAuthority.
// Production intent: a remote coordination service behind the same method.

import 'dart:convert';

import '../domain/command_fingerprint.dart';
import '../domain/command_guard.dart';
import '../domain/failures.dart';
import '../domain/request_status.dart';

abstract interface class AppointmentAuthority {
  /// Runs the pipeline for one command in one transaction.
  ///
  /// Returns a [CommandResult] for every decided outcome (applied, stored
  /// rejection, replay, payload mismatch, stale version).
  /// Throws a [TransportFailure] for OFFLINE, TRANSACTION_ABORT, ACK_LOST.
  Future<CommandResult> submit(AppointmentCommand command);
}

/// One logical user gesture sent to the authority (03-LLD.md §4).
///
/// There is no `queueMs` field and no free-text payload field: the client
/// cannot choose its queue position and cannot store notes.
class AppointmentCommand {
  const AppointmentCommand._({
    required this.commandId,
    required this.idempotencyKey,
    required this.type,
    required this.actorId,
    required this.slotId,
    required this.expectedSlotVersion,
    required this.requestId,
    this.patientId,
    this.expectedRequestVersion,
  });

  /// Patient files a request. The application mints [requestId] before the
  /// first submit and keeps it for retries of this gesture.
  factory AppointmentCommand.requestSlot({
    required String commandId,
    required String idempotencyKey,
    required String actorId,
    required String slotId,
    required String requestId,
    required String patientId,
    required int expectedSlotVersion,
  }) {
    return AppointmentCommand._(
      commandId: commandId,
      idempotencyKey: idempotencyKey,
      type: CommandType.requestSlot,
      actorId: actorId,
      slotId: slotId,
      requestId: requestId,
      patientId: patientId,
      expectedSlotVersion: expectedSlotVersion,
    );
  }

  /// Confirm, decline, cancel, or waitlist an existing request.
  factory AppointmentCommand.transition({
    required CommandType type,
    required String commandId,
    required String idempotencyKey,
    required String actorId,
    required String slotId,
    required String requestId,
    required int expectedSlotVersion,
    required int expectedRequestVersion,
  }) {
    if (type == CommandType.requestSlot) {
      throw ArgumentError.value(type, 'type', 'use AppointmentCommand.requestSlot');
    }
    return AppointmentCommand._(
      commandId: commandId,
      idempotencyKey: idempotencyKey,
      type: type,
      actorId: actorId,
      slotId: slotId,
      requestId: requestId,
      expectedSlotVersion: expectedSlotVersion,
      expectedRequestVersion: expectedRequestVersion,
    );
  }

  final String commandId;
  final String idempotencyKey;
  final CommandType type;
  final String actorId;
  final String slotId;
  final String requestId;
  final String? patientId;
  final int expectedSlotVersion;
  final int? expectedRequestVersion;

  /// Canonical fingerprint stored as `commands.payload_hash`.
  String get fingerprint => commandFingerprint(
        type: type,
        actorId: actorId,
        slotId: slotId,
        requestId: requestId,
        patientId: patientId,
      );

  CommandIntent get intent => CommandIntent(
        type: type,
        actorId: actorId,
        slotId: slotId,
        requestId: requestId,
        patientId: patientId,
        expectedSlotVersion: expectedSlotVersion,
        expectedRequestVersion: expectedRequestVersion,
      );

  /// Same gesture, refreshed versions. Keeps key, command id, and fingerprint.
  AppointmentCommand withExpectedVersions({
    required int expectedSlotVersion,
    int? expectedRequestVersion,
  }) {
    return AppointmentCommand._(
      commandId: commandId,
      idempotencyKey: idempotencyKey,
      type: type,
      actorId: actorId,
      slotId: slotId,
      requestId: requestId,
      patientId: patientId,
      expectedSlotVersion: expectedSlotVersion,
      expectedRequestVersion:
          type == CommandType.requestSlot ? null : expectedRequestVersion,
    );
  }
}

enum CommandOutcome {
  applied('APPLIED'),
  rejected('REJECTED');

  const CommandOutcome(this.wire);

  final String wire;

  static CommandOutcome fromWire(String value) =>
      CommandOutcome.values.firstWhere((o) => o.wire == value,
          orElse: () => throw FormatException('Unknown outcome', value));
}

class SlotSnapshot {
  const SlotSnapshot({
    required this.slotId,
    required this.version,
    required this.capacity,
    required this.confirmedCount,
    required this.availability,
  });

  final String slotId;
  final int version;
  final int capacity;
  final int confirmedCount;
  final SlotAvailability availability;

  Map<String, Object?> toJson() => {
        'slotId': slotId,
        'version': version,
        'capacity': capacity,
        'confirmedCount': confirmedCount,
        'availability': availability.wire,
      };

  factory SlotSnapshot.fromJson(Map<String, Object?> json) => SlotSnapshot(
        slotId: json['slotId']! as String,
        version: json['version']! as int,
        capacity: json['capacity']! as int,
        confirmedCount: json['confirmedCount']! as int,
        availability: SlotAvailability.fromWire(json['availability']! as String),
      );
}

class RequestSnapshot {
  const RequestSnapshot({
    required this.requestId,
    required this.patientId,
    required this.status,
    required this.version,
    required this.queueMs,
  });

  final String requestId;
  final String patientId;
  final RequestStatus status;
  final int version;
  final int queueMs;

  Map<String, Object?> toJson() => {
        'requestId': requestId,
        'patientId': patientId,
        'status': status.wire,
        'version': version,
        'queueMs': queueMs,
      };

  factory RequestSnapshot.fromJson(Map<String, Object?> json) =>
      RequestSnapshot(
        requestId: json['requestId']! as String,
        patientId: json['patientId']! as String,
        status: RequestStatus.fromWire(json['status']! as String),
        version: json['version']! as int,
        queueMs: json['queueMs']! as int,
      );
}

/// One status change applied by a command. Ids and statuses only.
class CommandEffect {
  const CommandEffect({
    required this.requestId,
    required this.from,
    required this.to,
  });

  final String requestId;
  final RequestStatus from;
  final RequestStatus to;

  Map<String, Object?> toJson() => {
        'requestId': requestId,
        'from': from.wire,
        'to': to.wire,
      };

  factory CommandEffect.fromJson(Map<String, Object?> json) => CommandEffect(
        requestId: json['requestId']! as String,
        from: RequestStatus.fromWire(json['from']! as String),
        to: RequestStatus.fromWire(json['to']! as String),
      );
}

/// The decided outcome of a command (03-LLD.md §6).
///
/// [toJson] is the stored `result_json` document. [replayed] is a runtime
/// flag only and is never part of the stored document.
class CommandResult {
  const CommandResult({
    required this.outcome,
    required this.code,
    required this.commandId,
    required this.commandType,
    required this.slot,
    required this.request,
    required this.effects,
    this.replayed = false,
  });

  final CommandOutcome outcome;

  /// `OK` or a [RejectionCode] wire value.
  final String code;
  final String commandId;
  final CommandType commandType;
  final SlotSnapshot? slot;
  final RequestSnapshot? request;
  final List<CommandEffect> effects;
  final bool replayed;

  bool get isApplied => outcome == CommandOutcome.applied;

  RejectionCode? get rejectionCode =>
      isApplied ? null : RejectionCode.fromWire(code);

  CommandResult asReplay() => CommandResult(
        outcome: outcome,
        code: code,
        commandId: commandId,
        commandType: commandType,
        slot: slot,
        request: request,
        effects: effects,
        replayed: true,
      );

  Map<String, Object?> toJson() => {
        'outcome': outcome.wire,
        'code': code,
        'commandId': commandId,
        'commandType': commandType.wire,
        'slot': slot?.toJson(),
        'request': request?.toJson(),
        'effects': [for (final e in effects) e.toJson()],
      };

  String encode() => jsonEncode(toJson());

  factory CommandResult.fromJson(Map<String, Object?> json,
      {bool replayed = false}) {
    final slot = json['slot'] as Map<String, Object?>?;
    final request = json['request'] as Map<String, Object?>?;
    final effects = (json['effects']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(CommandEffect.fromJson)
        .toList(growable: false);
    return CommandResult(
      outcome: CommandOutcome.fromWire(json['outcome']! as String),
      code: json['code']! as String,
      commandId: json['commandId']! as String,
      commandType: CommandType.fromWire(json['commandType']! as String),
      slot: slot == null ? null : SlotSnapshot.fromJson(slot),
      request: request == null ? null : RequestSnapshot.fromJson(request),
      effects: effects,
      replayed: replayed,
    );
  }

  factory CommandResult.decode(String resultJson, {bool replayed = false}) =>
      CommandResult.fromJson(
        (jsonDecode(resultJson) as Map).cast<String, Object?>(),
        replayed: replayed,
      );
}

