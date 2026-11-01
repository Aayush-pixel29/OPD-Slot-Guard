// ClinicBoardController (02-HLD.md §2, 03-LLD.md §10).
//
// Single ChangeNotifier state management for the board.
// Coordinates read model refreshes, actor switches, and command dispatches.

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../application/appointment_application.dart';
import '../application/demo_actor_directory.dart';
import '../domain/actor_policy.dart';
import '../domain/command_fingerprint.dart';
import '../infrastructure/sqlite_appointment_authority.dart';
import '../ports/appointment_read_model.dart';

class DiagnosticSnapshot {
  const DiagnosticSnapshot({
    this.lastCommandId,
    this.lastIdempotencyKey,
    this.lastMachineCode,
    this.lastReplayed = false,
    this.recentAudit = const [],
  });

  final String? lastCommandId;
  final String? lastIdempotencyKey;
  final String? lastMachineCode;
  final bool lastReplayed;
  final List<Map<String, Object?>> recentAudit;
}

class ClinicBoardController extends ChangeNotifier {
  ClinicBoardController({
    required this.application,
    required this.readModel,
    required this.directory,
    required this.chaosState,
    required this.db,
    required this.onResetDatabase,
    Actor? initialActor,
  }) : _actor = initialActor ?? DemoActorDirectory.ramesh.actor;

  final AppointmentApplication application;
  final AppointmentReadModel readModel;
  final DemoActorDirectory directory;
  final ChaosState chaosState;
  final Database db;
  final Future<void> Function() onResetDatabase;

  Actor _actor;
  List<SlotCardModel> _cards = const [];
  String? _banner;
  DiagnosticSnapshot _diagnostics = const DiagnosticSnapshot();
  bool _isLoading = false;

  Actor get actor => _actor;
  List<SlotCardModel> get cards => _cards;
  String? get banner => _banner;
  DiagnosticSnapshot get diagnostics => _diagnostics;
  bool get isLoading => _isLoading;
  ChaosArm get currentChaos => chaosState.armed;
  PendingGesture? get pendingGesture => application.pendingGesture;

  Future<void> init() async {
    await refresh();
  }

  Future<void> switchActor(Actor newActor) async {
    if (_actor.id == newActor.id) return;
    _actor = newActor;
    _banner = null;
    await refresh();
  }

  void dismissBanner() {
    _banner = null;
    notifyListeners();
  }

  void armChaos(ChaosArm arm) {
    chaosState.armed = arm;
    notifyListeners();
  }

  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();
    try {
      final projection = await readModel.load(_actor);
      _cards = projection.slots;
      await _refreshDiagnostics();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshDiagnostics({
    String? machineCode,
    String? commandId,
    String? key,
    bool replayed = false,
  }) async {
    try {
      final audit = await db.query(
        'audit_events',
        orderBy: 'at_ms DESC',
        limit: 8,
      );
      _diagnostics = DiagnosticSnapshot(
        lastCommandId: commandId ?? _diagnostics.lastCommandId,
        lastIdempotencyKey: key ?? _diagnostics.lastIdempotencyKey,
        lastMachineCode: machineCode ?? _diagnostics.lastMachineCode,
        lastReplayed: replayed,
        recentAudit: audit,
      );
    } catch (_) {}
  }

  Future<void> requestSlot({
    required String slotId,
    required int expectedSlotVersion,
  }) async {
    final gesture = application.createRequestGesture(
      actorId: _actor.id,
      slotId: slotId,
      patientId: _actor.id,
      expectedSlotVersion: expectedSlotVersion,
    );
    await _execute(gesture);
  }

  Future<void> confirm({
    required String slotId,
    required String requestId,
    required int expectedSlotVersion,
    required int expectedRequestVersion,
  }) async {
    final gesture = application.createTransitionGesture(
      type: CommandType.confirmRequest,
      actorId: _actor.id,
      slotId: slotId,
      requestId: requestId,
      expectedSlotVersion: expectedSlotVersion,
      expectedRequestVersion: expectedRequestVersion,
    );
    await _execute(gesture);
  }

  Future<void> decline({
    required String slotId,
    required String requestId,
    required int expectedSlotVersion,
    required int expectedRequestVersion,
  }) async {
    final gesture = application.createTransitionGesture(
      type: CommandType.declineRequest,
      actorId: _actor.id,
      slotId: slotId,
      requestId: requestId,
      expectedSlotVersion: expectedSlotVersion,
      expectedRequestVersion: expectedRequestVersion,
    );
    await _execute(gesture);
  }

  Future<void> cancel({
    required String slotId,
    required String requestId,
    required int expectedSlotVersion,
    required int expectedRequestVersion,
  }) async {
    final gesture = application.createTransitionGesture(
      type: CommandType.cancelRequest,
      actorId: _actor.id,
      slotId: slotId,
      requestId: requestId,
      expectedSlotVersion: expectedSlotVersion,
      expectedRequestVersion: expectedRequestVersion,
    );
    await _execute(gesture);
  }

  Future<void> retryPendingGesture() async {
    final gesture = application.pendingGesture;
    if (gesture == null) return;
    await _execute(gesture);
  }

  Future<void> _execute(PendingGesture gesture) async {
    _isLoading = true;
    notifyListeners();

    try {
      final res = await application.executeGesture(gesture);
      _banner = res.banner;
      await _refreshDiagnostics(
        machineCode: res.machineCode,
        commandId: gesture.command.commandId,
        key: gesture.command.idempotencyKey,
        replayed: res.commandResult?.replayed ?? false,
      );
    } finally {
      // Authoritative read model refresh after commit/rejection
      final projection = await readModel.load(_actor);
      _cards = projection.slots;
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> resetDemo() async {
    _isLoading = true;
    _banner = null;
    notifyListeners();
    try {
      chaosState.reset();
      application.clearPendingGesture();
      await onResetDatabase();
      _diagnostics = const DiagnosticSnapshot(lastMachineCode: 'RESET');
      final projection = await readModel.load(_actor);
      _cards = projection.slots;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
