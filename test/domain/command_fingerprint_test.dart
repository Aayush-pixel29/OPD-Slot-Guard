// D14: the fingerprint ignores versions and changes with logical fields.

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/domain/command_fingerprint.dart';
import 'package:opd_slot_guard/ports/appointment_authority.dart';

void main() {
  AppointmentCommand confirm({
    String requestId = 'req-a',
    String actorId = 'clinic-desk',
    String commandId = 'cmd-1',
    int slotVersion = 0,
    int requestVersion = 0,
  }) =>
      AppointmentCommand.transition(
        type: CommandType.confirmRequest,
        commandId: commandId,
        idempotencyKey: 'key-1',
        actorId: actorId,
        slotId: 'slot-1830',
        requestId: requestId,
        expectedSlotVersion: slotVersion,
        expectedRequestVersion: requestVersion,
      );

  test('canonical v1 format from ADR-02', () {
    expect(confirm().fingerprint,
        'v1|ConfirmRequest|clinic-desk|slot-1830|req-a|-');
    final request = AppointmentCommand.requestSlot(
      commandId: 'cmd-2',
      idempotencyKey: 'key-2',
      actorId: 'patient-ramesh',
      slotId: 'slot-1830',
      requestId: 'req-r',
      patientId: 'patient-ramesh',
      expectedSlotVersion: 0,
    );
    expect(request.fingerprint,
        'v1|RequestSlot|patient-ramesh|slot-1830|req-r|patient-ramesh');
  });

  test('D14 versions and commandId are excluded from the fingerprint', () {
    expect(confirm(slotVersion: 7, requestVersion: 3, commandId: 'cmd-9')
            .fingerprint,
        confirm().fingerprint);
    final refreshed =
        confirm().withExpectedVersions(expectedSlotVersion: 4, expectedRequestVersion: 2);
    expect(refreshed.fingerprint, confirm().fingerprint);
    expect(refreshed.idempotencyKey, 'key-1');
    expect(refreshed.commandId, 'cmd-1');
  });

  test('D14 fingerprint changes when requestId or actor changes', () {
    expect(confirm(requestId: 'req-b').fingerprint,
        isNot(confirm().fingerprint));
    expect(confirm(actorId: 'patient-ramesh').fingerprint,
        isNot(confirm().fingerprint));
  });

  test('fingerprint changes with command type', () {
    final cancel = AppointmentCommand.transition(
      type: CommandType.cancelRequest,
      commandId: 'cmd-1',
      idempotencyKey: 'key-1',
      actorId: 'clinic-desk',
      slotId: 'slot-1830',
      requestId: 'req-a',
      expectedSlotVersion: 0,
      expectedRequestVersion: 0,
    );
    expect(cancel.fingerprint, isNot(confirm().fingerprint));
  });

  test('separator or placeholder inside an id cannot forge a fingerprint', () {
    for (final bad in ['a|b', '', '-']) {
      expect(
          () => commandFingerprint(
              type: CommandType.confirmRequest,
              actorId: 'clinic-desk',
              slotId: 'slot-1830',
              requestId: bad),
          throwsArgumentError,
          reason: bad);
    }
  });
}

