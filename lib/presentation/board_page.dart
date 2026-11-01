// BoardPage: The primary single-device mobile shell for OPD Slot Guard.
// (02-HLD.md §7, 03-LLD.md §10).

import 'package:flutter/material.dart';

import '../application/demo_actor_directory.dart';
import '../domain/actor_policy.dart';
import '../domain/request_status.dart';
import '../infrastructure/sqlite_appointment_authority.dart';
import '../ports/appointment_read_model.dart';
import 'clinic_board_controller.dart';

class BoardPage extends StatelessWidget {
  const BoardPage({required this.controller, super.key});

  final ClinicBoardController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final actor = controller.actor;
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'OPD Slot Guard',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            actions: [
              IconButton(
                icon: Badge(
                  isLabelVisible: controller.currentChaos != ChaosArm.none,
                  label: Text(controller.currentChaos.name.toUpperCase()),
                  child: const Icon(Icons.bug_report_outlined),
                ),
                tooltip: 'Diagnostics & Chaos',
                onPressed: () => _showDiagnosticsSheet(context),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: controller.isLoading ? null : controller.refresh,
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(56),
              child: _RoleSwitcher(
                currentActor: actor,
                onSelect: controller.switchActor,
              ),
            ),
          ),
          body: controller.isLoading && controller.cards.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (controller.banner != null)
                      _BannerView(
                        bannerText: controller.banner!,
                        hasPendingRetry: controller.pendingGesture != null,
                        onDismiss: controller.dismissBanner,
                        onRetry: controller.retryPendingGesture,
                      ),
                    _IdentityCard(actor: actor),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        itemCount: controller.cards.length,
                        itemBuilder: (context, index) {
                          final card = controller.cards[index];
                          return _SlotCardItem(
                            card: card,
                            actor: actor,
                            isPrimary: card.slotId == 'slot-1830',
                            onTap: () => _showSlotDetails(context, card),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  void _showSlotDetails(BuildContext context, SlotCardModel card) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _SlotDetailSheet(
        card: card,
        controller: controller,
      ),
    );
  }

  void _showDiagnosticsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _DiagnosticsSheet(controller: controller),
    );
  }
}

class _RoleSwitcher extends StatelessWidget {
  const _RoleSwitcher({
    required this.currentActor,
    required this.onSelect,
  });

  final Actor currentActor;
  final ValueChanged<Actor> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: DemoActorDirectory.all.map((entry) {
          final isSelected = entry.actor.id == currentActor.id;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(entry.displayName),
              selected: isSelected,
              avatar: Icon(
                entry.actor.isClinic ? Icons.local_hospital : Icons.person,
                size: 16,
              ),
              onSelected: (_) => onSelect(entry.actor),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.actor});

  final Actor actor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isClinic = actor.isClinic;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isClinic
            ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.6)
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            isClinic ? Icons.medical_services_outlined : Icons.shield_outlined,
            color: isClinic
                ? theme.colorScheme.onTertiaryContainer
                : theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isClinic
                      ? 'Clinic Desk (Confirmed authority)'
                      : 'Patient View: ${actor.id == "patient-ramesh" ? "Ramesh" : "Priya"}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  isClinic
                      ? 'Review queue orders, confirm or decline appointments.'
                      : 'Privacy protected: Only your own requests are visible.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BannerView extends StatelessWidget {
  const _BannerView({
    required this.bannerText,
    required this.hasPendingRetry,
    required this.onDismiss,
    required this.onRetry,
  });

  final String bannerText;
  final bool hasPendingRetry;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        border: Border.all(color: Colors.amber.shade800),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.amber.shade900),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              bannerText,
              style: TextStyle(
                color: Colors.amber.shade900,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (hasPendingRetry)
            TextButton(
              onPressed: onRetry,
              child: const Text('RETRY'),
            ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _SlotCardItem extends StatelessWidget {
  const _SlotCardItem({
    required this.card,
    required this.actor,
    required this.isPrimary,
    required this.onTap,
  });

  final SlotCardModel card;
  final Actor actor;
  final bool isPrimary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBooked = card.isBooked;

    return Card(
      elevation: isPrimary ? 3 : 1,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isPrimary
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text(
                        card.label,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (isPrimary) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'DEMO PRIMARY',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isBooked
                          ? Colors.orange.shade100
                          : Colors.green.shade100,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      card.availability.wire,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: isBooked
                            ? Colors.orange.shade900
                            : Colors.green.shade900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (actor.isPatient) ...[
                if (card.myRequest != null)
                  Row(
                    children: [
                      const Text(
                        'Your Status: ',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                      Text(
                        card.myRequest!.status.wire,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: _statusColor(card.myRequest!.status),
                        ),
                      ),
                    ],
                  )
                else
                  const Text(
                    'No booking request yet',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
              ] else ...[
                Text(
                  'Requests in Queue: ${card.clinicRequests.length}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                if (card.clinicRequests.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: card.clinicRequests.map((r) {
                      return Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          '${r.patientDisplayName}: ${r.status.wire}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        backgroundColor: _statusColor(r.status).withValues(alpha: 0.15),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Color _statusColor(RequestStatus status) {
    switch (status) {
      case RequestStatus.confirmed:
        return Colors.green.shade700;
      case RequestStatus.waitlisted:
        return Colors.orange.shade700;
      case RequestStatus.requested:
        return Colors.blue.shade700;
      case RequestStatus.declined:
        return Colors.red.shade700;
      case RequestStatus.cancelled:
        return Colors.grey.shade700;
    }
  }
}

class _SlotDetailSheet extends StatelessWidget {
  const _SlotDetailSheet({
    required this.card,
    required this.controller,
  });

  final SlotCardModel card;
  final ClinicBoardController controller;

  @override
  Widget build(BuildContext context) {
    final actor = controller.actor;
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Slot: ${card.label}',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              Text(
                card.availability.wire,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: card.isBooked ? Colors.orange : Colors.green,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Slot Version: ${card.version} | Capacity: ${card.capacity}'),
          const Divider(height: 24),
          if (actor.isPatient) ...[
            if (card.myRequest == null) ...[
              const Text('You do not have a booking for this slot.'),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await controller.requestSlot(
                      slotId: card.slotId,
                      expectedSlotVersion: card.version,
                    );
                  },
                  child: const Text('Request Slot'),
                ),
              ),
            ] else ...[
              Text(
                'Your Request Status: ${card.myRequest!.status.wire}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              Text('Queue Position Timestamp: ${card.myRequest!.queueMs} ms'),
              Text('Request Version: ${card.myRequest!.version}'),
              const SizedBox(height: 16),
              if (card.myRequest!.status.isLive)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                    onPressed: () async {
                      Navigator.pop(context);
                      await controller.cancel(
                        slotId: card.slotId,
                        requestId: card.myRequest!.requestId,
                        expectedSlotVersion: card.version,
                        expectedRequestVersion: card.myRequest!.version,
                      );
                    },
                    child: const Text('Cancel My Appointment'),
                  ),
                ),
            ],
          ] else ...[
            const Text(
              'Patient Requests Queue (Authority View):',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 10),
            if (card.clinicRequests.isEmpty)
              const Text('No requests received for this slot yet.')
            else
              ...card.clinicRequests.map((req) {
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    title: Text(
                      '${req.patientDisplayName} (${req.status.wire})',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      'Queue: ${req.queueMs} ms | Version: ${req.version}',
                    ),
                    trailing: req.status == RequestStatus.requested
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FilledButton(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await controller.confirm(
                                    slotId: card.slotId,
                                    requestId: req.requestId,
                                    expectedSlotVersion: card.version,
                                    expectedRequestVersion: req.version,
                                  );
                                },
                                child: const Text('Confirm'),
                              ),
                              const SizedBox(width: 6),
                              OutlinedButton(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await controller.decline(
                                    slotId: card.slotId,
                                    requestId: req.requestId,
                                    expectedSlotVersion: card.version,
                                    expectedRequestVersion: req.version,
                                  );
                                },
                                child: const Text('Decline'),
                              ),
                            ],
                          )
                        : req.status == RequestStatus.confirmed
                            ? OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.red),
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await controller.cancel(
                                    slotId: card.slotId,
                                    requestId: req.requestId,
                                    expectedSlotVersion: card.version,
                                    expectedRequestVersion: req.version,
                                  );
                                },
                                child: const Text('Cancel Confirmed'),
                              )
                            : null,
                  ),
                );
              }),
          ],
        ],
      ),
    );
  }
}

class _DiagnosticsSheet extends StatelessWidget {
  const _DiagnosticsSheet({required this.controller});

  final ClinicBoardController controller;

  @override
  Widget build(BuildContext context) {
    final diag = controller.diagnostics;
    final currentChaos = controller.currentChaos;

    return Container(
      padding: const EdgeInsets.all(20),
      height: MediaQuery.of(context).size.height * 0.75,
      child: ListView(
        children: [
          const Text(
            'Engineering Diagnostics & Chaos Dock',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'Inject Failure (One-Shot):',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('None'),
                selected: currentChaos == ChaosArm.none,
                onSelected: (_) => controller.armChaos(ChaosArm.none),
              ),
              ChoiceChip(
                label: const Text('OFFLINE'),
                selected: currentChaos == ChaosArm.offline,
                onSelected: (_) => controller.armChaos(ChaosArm.offline),
              ),
              ChoiceChip(
                label: const Text('TRANSACTION_ABORT'),
                selected: currentChaos == ChaosArm.abort,
                onSelected: (_) => controller.armChaos(ChaosArm.abort),
              ),
              ChoiceChip(
                label: const Text('ACK_LOST'),
                selected: currentChaos == ChaosArm.ackLost,
                onSelected: (_) => controller.armChaos(ChaosArm.ackLost),
              ),
            ],
          ),
          const Divider(height: 24),
          const Text(
            'Last Command Diagnostic:',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text('Command ID: ${diag.lastCommandId ?? "None"}'),
          Text('Idempotency Key: ${diag.lastIdempotencyKey ?? "None"}'),
          Text('Machine Code: ${diag.lastMachineCode ?? "None"}'),
          Text('Replayed Stored Result: ${diag.lastReplayed ? "YES (True)" : "No"}'),
          const Divider(height: 24),
          const Text(
            'Recent Audit Log Tail (Append-Only):',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          if (diag.recentAudit.isEmpty)
            const Text('No audit events yet.')
          else
            ...diag.recentAudit.map((a) {
              return Text(
                '${a["action"]} on ${a["entity_id"]} by ${a["actor_id"]} (${a["from_status"] ?? "-"} -> ${a["to_status"] ?? "-"})',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              );
            }),
          const Divider(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: const Icon(Icons.restore),
            label: const Text('RESET DEMO DATA'),
            onPressed: () async {
              Navigator.pop(context);
              await controller.resetDemo();
            },
          ),
        ],
      ),
    );
  }
}
