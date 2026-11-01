// D6, D7, D8 and the full ActorPolicy table from 03-LLD.md §3.

import 'package:flutter_test/flutter_test.dart';
import 'package:opd_slot_guard/domain/actor_policy.dart';
import 'package:opd_slot_guard/domain/command_fingerprint.dart';

void main() {
  const policy = ActorPolicy();
  const ramesh = Actor(id: 'patient-ramesh', role: ActorRole.patient);
  const desk = Actor(id: 'clinic-desk', role: ActorRole.clinic);

  bool allowed(Actor? actor, CommandType type, String? patientId) =>
      policy.isAllowed(actor: actor, type: type, patientId: patientId);

  test('D6 patient confirm is forbidden, even on own row', () {
    expect(allowed(ramesh, CommandType.confirmRequest, 'patient-ramesh'),
        isFalse);
  });

  test('D7 patient cancel of another patient request is forbidden', () {
    expect(
        allowed(ramesh, CommandType.cancelRequest, 'patient-priya'), isFalse);
  });

  test('D8 clinic RequestSlot is forbidden', () {
    expect(allowed(desk, CommandType.requestSlot, 'clinic-desk'), isFalse);
    expect(allowed(desk, CommandType.requestSlot, 'patient-ramesh'), isFalse);
  });

  test('patient may request and cancel only for own id', () {
    expect(allowed(ramesh, CommandType.requestSlot, 'patient-ramesh'), isTrue);
    expect(allowed(ramesh, CommandType.requestSlot, 'patient-priya'), isFalse);
    expect(allowed(ramesh, CommandType.cancelRequest, 'patient-ramesh'), isTrue);
  });

  test('patient may never decline or waitlist', () {
    for (final type in [
      CommandType.declineRequest,
      CommandType.waitlistRequest,
    ]) {
      expect(allowed(ramesh, type, 'patient-ramesh'), isFalse);
    }
  });

  test('clinic may confirm, decline, waitlist, cancel any row', () {
    for (final type in [
      CommandType.confirmRequest,
      CommandType.declineRequest,
      CommandType.waitlistRequest,
      CommandType.cancelRequest,
    ]) {
      expect(allowed(desk, type, 'patient-priya'), isTrue);
    }
  });

  test('unknown actor (null lookup) is forbidden for every command', () {
    for (final type in CommandType.values) {
      expect(allowed(null, type, 'patient-ramesh'), isFalse);
    }
  });
}

