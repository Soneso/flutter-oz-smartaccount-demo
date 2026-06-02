/// Read-only Account Signers screen.
///
/// Displays every unique signer registered across all context rules on the
/// connected smart account, grouped by signer identity. Each row shows the
/// signer's type badge, an identifier (truncated address or credential ID),
/// and the rules in which the signer participates.
///
/// Screens-never-call-SDK rule:
/// This screen interacts only with [AccountSignersFlow] and the Riverpod
/// state notifiers. It never references the smart account kit or any of
/// its managers directly.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/account_signers_flow.dart';
import '../flows/context_rule_builder_types.dart' show ParsedContextRule;
import '../navigation/routes.dart';
import '../state/account_signers_flow_provider.dart';
import '../state/demo_state.dart';
import '../theme/spacing.dart';
import '../util/context_rule_format.dart';
import '../util/error_utils.dart';
import '../util/format_utils.dart' show redactId;
import '../util/signer_colors.dart';
import '../util/signer_type_label.dart';
import '../widgets/empty_state_card.dart';
import '../widgets/error_card.dart';
import '../widgets/loading_button.dart';
import '../widgets/section_description_card.dart';

// ---------------------------------------------------------------------------
// KnownSignersScreen
// ---------------------------------------------------------------------------

/// Read-only Account Signers screen.
///
/// Dependencies are injected via the constructor so widget tests can
/// substitute a mock flow. In production the flow is resolved from the kit
/// via [accountSignersFlowProvider].
class KnownSignersScreen extends ConsumerStatefulWidget {
  /// Creates a [KnownSignersScreen].
  ///
  /// [flow] is the optional injected [AccountSignersFlow] for tests. When
  /// null (production), the screen resolves the flow from the provider.
  const KnownSignersScreen({this.flow, super.key});

  /// Optional injected [AccountSignersFlow] for testing.
  final AccountSignersFlow? flow;

  @override
  ConsumerState<KnownSignersScreen> createState() =>
      _KnownSignersScreenState();
}

class _KnownSignersScreenState extends ConsumerState<KnownSignersScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  List<SignerEntry> _entries = const <SignerEntry>[];
  bool _hasLoadedOnce = false;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadSigners(announce: false));
    });
  }

  /// Resolves the flow at action time so a kit that becomes available after
  /// this screen mounts is picked up on the next call. Tests inject the flow
  /// via [widget.flow] and bypass the provider lookup entirely.
  AccountSignersFlow? _resolveFlow() {
    return widget.flow ?? ref.read(accountSignersFlowProvider);
  }

  Future<void> _loadSigners({bool announce = true}) async {
    final flow = _resolveFlow();
    if (flow == null) return;
    if (!ref.read(demoStateProvider).isConnected) return;
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final entries = await flow.loadAccountSigners();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _isLoading = false;
        _hasLoadedOnce = true;
      });
      if (announce) {
        final count = entries.length;
        unawaited(SemanticsService.announce(
          'Loaded $count unique ${count == 1 ? 'signer' : 'signers'}',
          Directionality.of(context),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      final classified = classifyError(e);
      setState(() {
        _errorMessage = 'Failed to load signers: ${classified.message}';
        _isLoading = false;
        _hasLoadedOnce = true;
      });
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(demoStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Account Signers'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => popOrGoMain(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: kCardPadding,
          children: [
            const SectionDescriptionCard(
              title: 'Account Signers',
              message:
                  'All signers registered on this smart account across all '
                  'context rules.',
            ),
            const SizedBox(height: 12),
            if (!state.isConnected) ...[
              const EmptyStateCard(
                title: 'Not connected',
                message: 'Connect a wallet to view account signers',
              ),
              const SizedBox(height: 12),
            ] else ...[
              _buildRefreshButton(),
              const SizedBox(height: 12),
              if (_errorMessage != null) ...[
                ErrorCard(message: _errorMessage!),
                const SizedBox(height: 12),
              ],
              if (_isLoading && _entries.isEmpty) ...[
                const _LoadingCard(),
                const SizedBox(height: 12),
              ] else if (_hasLoadedOnce &&
                  _entries.isEmpty &&
                  _errorMessage == null) ...[
                const EmptyStateCard(
                  title: 'No signers',
                  message: 'No signers found on this account',
                ),
                const SizedBox(height: 12),
              ] else if (_entries.isNotEmpty) ...[
                _SignersListCard(entries: _entries),
                const SizedBox(height: 12),
              ],
            ],
            _buildGoBackButton(context),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildRefreshButton() {
    return LoadingButton(
      label: 'Refresh',
      loadingLabel: 'Loading...',
      style: LoadingButtonStyle.outlined,
      enabled: !_isLoading,
      disabledHint: 'Loading signers. Please wait.',
      // The closure is required: [_loadSigners] takes a named parameter and
      // cannot be torn off into the parameterless `Future<void> Function()`
      // signature expected by [LoadingButton.action].
      // ignore: unnecessary_lambdas
      action: () => _loadSigners(),
    );
  }

  Widget _buildGoBackButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Go Back'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _LoadingCard
// ---------------------------------------------------------------------------

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Card(
        elevation: 0,
        color: colorScheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 12),
              Text(
                'Loading signers...',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SignersListCard
// ---------------------------------------------------------------------------

class _SignersListCard extends StatelessWidget {
  const _SignersListCard({required this.entries});

  final List<SignerEntry> entries;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final count = entries.length;
    final countLabel = '$count ${count == 1 ? 'signer' : 'signers'}';

    return Card(
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                countLabel,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 8),
            ...List.generate(entries.length, (index) {
              final entry = entries[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (index > 0) const Divider(height: 16),
                  _SignerRow(entry: entry),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SignerRow
// ---------------------------------------------------------------------------

class _SignerRow extends StatelessWidget {
  const _SignerRow({required this.entry});

  final SignerEntry entry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final display = formatSignerForDisplay(entry.signer);
    final badgeColor = signerTypeColorForDisplayLabel(display.typeLabel);

    final ruleSummary = entry.contextRules
        .map((r) => '#${r.id} ${_ruleName(r)} ${formatContextType(r.contextType)}')
        .join(', ');

    // For Passkey rows the visible label is the formatter's
    // truncated credential ID; the assistive-technology label uses the
    // shorter [redactId] form so the credential ID is not read aloud in
    // its longer truncated form.
    final accessibilityValue = display.typeLabel == SignerTypeLabel.passkeyShort
        ? redactId(display.displayValue)
        : display.displayValue;

    return Semantics(
      excludeSemantics: true,
      label:
          '${display.typeLabel} signer $accessibilityValue, '
          'in rules: $ruleSummary',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  display.typeLabel,
                  style: textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  display.displayValue,
                  style: textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final rule in entry.contextRules)
                _RuleChip(rule: rule),
            ],
          ),
        ],
      ),
    );
  }

  String _ruleName(ParsedContextRule rule) =>
      rule.name.trim().isEmpty ? 'Unnamed Rule' : rule.name;
}

// ---------------------------------------------------------------------------
// _RuleChip
// ---------------------------------------------------------------------------

class _RuleChip extends StatelessWidget {
  const _RuleChip({required this.rule});

  final ParsedContextRule rule;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final ruleName = rule.name.trim().isEmpty ? 'Unnamed Rule' : rule.name;
    final contextLabel = formatContextType(rule.contextType);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.primary.withAlpha(38),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Text(
            '#${rule.id}',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            ruleName,
            style: textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 6),
          // Flexible + ellipsis so a long contextLabel can never overflow
          // the chip's available width.
          Flexible(
            child: Text(
              contextLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
