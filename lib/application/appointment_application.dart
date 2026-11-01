// Application service coordinating commands, pending gestures, and automatic replay.
// (02-HLD.md §2, 03-LLD.md §10).

import '../domain/command_fingerprint.dart';
import '../domain/failures.dart';
import '../ports/appointment_authority.dart';
import '../ports/id_generator.dart';
import 'patient_messages.dart';

class PendingGesture {
  const PendingGesture({
    required this.command,
    required this.isRetryable,
  });

  final AppointmentCommand command;
  final bool isRetryable;

  String get idempotencyKey => command.idempotencyKey;
}

class ApplicationExecutionResult {
  const ApplicationExecutionResult({
    this.commandResult,
    this.banner,
    this.machineCode,
  });

  final CommandResult? commandResult;
  final String? banner;
  final String? machineCode;

  bool get isSuccess => commandResult?.isApplied ?? false;
}

class AppointmentApplication {
  AppointmentApplication({
    required this.authority,
    required this.idGenerator,
  });

  final AppointmentAuthority authority;
  final IdGenerator idGenerator;

  PendingGesture? pendingGesture;

  PendingGesture createRequestGesture({
    required String actorId,
    required String slotId,
    required String patientId,
    required int expectedSlotVersion,
  }) {
    final gesture = PendingGesture(
      command: AppointmentCommand.requestSlot(
        commandId: idGenerator.newId('cmd'),
        idempotencyKey: idGenerator.newId('key'),
        actorId: actorId,
        slotId: slotId,
        requestId: idGenerator.newId('req'),
        patientId: patientId,
        expectedSlotVersion: expectedSlotVersion,
      ),
      isRetryable: true,
    );
    pendingGesture = gesture;
    return gesture;
  }

  PendingGesture createTransitionGesture({
    required CommandType type,
    required String actorId,
    required String slotId,
    required String requestId,
    required int expectedSlotVersion,
    required int expectedRequestVersion,
  }) {
    final gesture = PendingGesture(
      command: AppointmentCommand.transition(
        type: type,
        commandId: idGenerator.newId('cmd'),
        idempotencyKey: idGenerator.newId('key'),
        actorId: actorId,
        slotId: slotId,
        requestId: requestId,
        expectedSlotVersion: expectedSlotVersion,
        expectedRequestVersion: expectedRequestVersion,
      ),
      isRetryable: true,
    );
    pendingGesture = gesture;
    return gesture;
  }

  Future<ApplicationExecutionResult> executeGesture(PendingGesture gesture) async {
    try {
      final result = await authority.submit(gesture.command);
      if (result.isApplied) {
        pendingGesture = null; // Decided and applied
        return ApplicationExecutionResult(
          commandResult: result,
          banner: null,
          machineCode: result.code,
        );
      } else {
        // Stored domain rejection or STALE_VERSION
        if (result.code == 'STALE_VERSION') {
          // Stale version: keep gesture so retry can refresh versions
          return ApplicationExecutionResult(
            commandResult: result,
            banner: PatientMessages.staleVersion,
            machineCode: result.code,
          );
        }

        // Terminal domain rejection clears pending gesture
        pendingGesture = null;
        return ApplicationExecutionResult(
          commandResult: result,
          banner: PatientMessages.bannerForCode(result.code),
          machineCode: result.code,
        );
      }
    } on AckLostFailure {
      // 03-LLD.md §10: Automatic retry once inside the application on ACK_LOST
      try {
        final replayResult = await authority.submit(gesture.command);
        pendingGesture = null;
        return ApplicationExecutionResult(
          commandResult: replayResult,
          banner: null,
          machineCode: 'ACK_LOST -> REPLAYED',
        );
      } catch (e) {
        // If automatic replay also fails transport, retain pending gesture
        return ApplicationExecutionResult(
          commandResult: null,
          banner: PatientMessages.ackLostChecking,
          machineCode: 'ACK_LOST',
        );
      }
    } on OfflineFailure {
      // Retain pending gesture for manual retry
      return ApplicationExecutionResult(
        commandResult: null,
        banner: PatientMessages.offline,
        machineCode: 'OFFLINE',
      );
    } on TransactionAbortFailure catch (e) {
      // Retain pending gesture for manual retry
      return ApplicationExecutionResult(
        commandResult: null,
        banner: PatientMessages.transactionAbort,
        machineCode: 'TRANSACTION_ABORT (${e.reason ?? "rollback"})',
      );
    } catch (e) {
      return ApplicationExecutionResult(
        commandResult: null,
        banner: PatientMessages.transactionAbort,
        machineCode: 'UNEXPECTED_ERROR',
      );
    }
  }

  void clearPendingGesture() {
    pendingGesture = null;
  }
}

