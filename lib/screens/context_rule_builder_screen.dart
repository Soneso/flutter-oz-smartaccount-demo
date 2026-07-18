/// Context Rule Builder screen — create-mode form for adding a new
/// context rule to the connected smart account.
///
/// The screen owns the in-progress form state and orchestrates signer /
/// policy staging, multi-signer detection, and submission. All SDK calls
/// go through [ContextRuleFlow]; SDK types are imported via the typedefs
/// re-exported from `context_rule_builder_types.dart` so the screen never
/// pulls in `package:stellar_flutter_sdk` directly.
///
/// State machine:
/// - Not Connected:    Show "No wallet connected" card.
/// - Editing:          Show rule-config card + signers + policies + submit.
/// - Submitting:       Disable form, show spinner inside primary CTA.
/// - Multi-signer:     Open the [SignerPickerSheet] before submission.
/// - Success:          Show success card with hash and "Go Back".
/// - Failure:          Show error card; form remains for retry.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/demo_config.dart' as config;
import '../config/demo_config.dart' show PolicyInfo;
import '../flows/context_rule_builder_types.dart';
import '../flows/context_rule_flow.dart';
import '../flows/signer_info.dart' show Ed25519SignerIdentity, SignerInfo;
import '../navigation/routes.dart';
import '../state/activity_log_state.dart';
import '../state/context_rule_flow_provider.dart';
import '../state/demo_state.dart';
import '../theme/spacing.dart';
import '../util/clipboard.dart';
import '../util/context_rule_format.dart';
import '../util/error_utils.dart' show classifyError;
import '../util/format_utils.dart';
import '../util/policy_type.dart';
import '../util/semantic_colors.dart';
import '../widgets/edit_success_card.dart';
import '../widgets/empty_state_card.dart';
import '../widgets/error_card.dart';
import '../widgets/loading_button.dart';
import '../widgets/loading_label.dart';
import '../widgets/operation_summary_card.dart';
import '../widgets/policy_management_section.dart';
import '../widgets/rich_dropdown_item.dart';
import '../widgets/section_description_card.dart';
import '../widgets/signer_management_section.dart';
import '../widgets/signer_picker_sheet.dart';

part '../widgets/context_rule_builder_parts.dart';

// ---------------------------------------------------------------------------
// Context type form options
// ---------------------------------------------------------------------------

/// User-facing context-type selector entry.
enum _ContextTypeOption {
  defaultRule(
    'Default (Any Operation)',
    'Matches any operation that does not match a more specific rule',
  ),
  callContract(
    'Call Contract',
    'Matches invocations to a specific contract address',
  ),
  createContract(
    'Create Contract',
    'Matches contract deployments using a specific WASM hash',
  );

  const _ContextTypeOption(this.displayName, this.description);

  final String displayName;
  final String description;
}

/// Expiry duration preset.
///
/// A value of [offset] == null marks the `Custom` entry, which reveals a
/// numeric input bound to the form's expiry-offset state.
final class _ExpiryOption {
  const _ExpiryOption(this.label, this.offset);

  final String label;
  final int? offset;

  /// True when this entry is the user-supplied custom value.
  bool get isCustom => offset == null;
}

/// Builds the expiry-preset list. The trailing `Custom` entry
/// reveals an inline numeric field bound to the form's expiry offset.
const List<_ExpiryOption> _kExpiryOptions = <_ExpiryOption>[
  _ExpiryOption('5 min', ledgersPerHour ~/ 12),
  _ExpiryOption('30 min', ledgersPerHour ~/ 2),
  _ExpiryOption('1 hour', ledgersPerHour),
  _ExpiryOption('1 day', ledgersPerDay),
  _ExpiryOption('10 days', ledgersPerDay * 10),
  _ExpiryOption('Custom', null),
];

// ---------------------------------------------------------------------------
// ContextRuleBuilderScreen
// ---------------------------------------------------------------------------

/// Context Rule Builder screen.
///
/// Renders in create-mode by default. When [editRuleId] is non-null the
/// screen loads the matching on-chain rule, pre-populates the form, and
/// switches the submit flow into per-operation edit-mode submission.
class ContextRuleBuilderScreen extends ConsumerStatefulWidget {
  /// Constructs a builder screen.
  ///
  /// [flow] is an optional injected [ContextRuleFlow] for tests. When null,
  /// the screen resolves the flow from [contextRuleFlowProvider].
  ///
  /// [editRuleId] switches the screen into edit-mode for the rule with
  /// that on-chain identifier.
  const ContextRuleBuilderScreen({this.flow, this.editRuleId, super.key});

  /// Optional injected flow for testing.
  final ContextRuleFlow? flow;

  /// On-chain rule ID to load and edit. Null for create-mode.
  final int? editRuleId;

  @override
  ConsumerState<ContextRuleBuilderScreen> createState() =>
      _ContextRuleBuilderScreenState();
}

class _ContextRuleBuilderScreenState
    extends ConsumerState<ContextRuleBuilderScreen> {
  // ---- Flow ----

  ContextRuleFlow? _flow;

  // ---- Form state ----

  final TextEditingController _nameController = TextEditingController();
  _ContextTypeOption _contextType = _ContextTypeOption.defaultRule;
  String _contractAddress = config.nativeTokenContract;
  final TextEditingController _wasmHashController = TextEditingController();
  bool _hasExpiry = false;
  bool _isCustomExpiry = false;
  int? _expiryOffset;
  bool _expiryModified = false;
  int? _existingExpiryLedger;
  final TextEditingController _customExpiryController =
      TextEditingController();

  // [_signers] is the authoritative create-mode signer list. In edit-mode
  // it is also populated from the loaded on-chain rule so the policy
  // section's weighted-threshold add form can render per-signer weight
  // inputs against the current signer set. [SignerManagementSection]
  // itself does not consume this list in edit mode; it derives its view
  // from [_editSignerEntries].
  final List<StagedSigner> _signers = <StagedSigner>[];
  final List<StagedPolicy> _policies = <StagedPolicy>[];

  // Decimal scale of the rule's guarded token, used by the policy section to
  // convert a spending-limit amount to base units. Resolved whenever the
  // context type / guarded contract changes; native and non-token rules use
  // [nativeTokenDecimals] without a network call.
  int _spendingLimitDecimals = nativeTokenDecimals;
  String? _spendingLimitDecimalsError;
  int _spendingLimitDecimalsToken = 0;

  // Placeholder install params used only when adapting an unchanged original
  // policy into the display/removal [StagedPolicy] shape; the value is never
  // read on the removal path.
  static const OZPolicyInstallParams _removalPlaceholderParams =
      OZSimpleThresholdPolicyParams(threshold: 1);

  // ---- Edit-mode state ----

  String _originalName = '';
  List<EditSignerEntry> _editSignerEntries = const <EditSignerEntry>[];
  List<EditSignerEntry> _originalSignerEntries = const <EditSignerEntry>[];
  List<EditPolicyEntry> _editPolicyEntries = const <EditPolicyEntry>[];
  List<EditPolicyEntry> _originalPolicyEntries = const <EditPolicyEntry>[];
  List<OZExternalSigner> _availableExistingPasskeys =
      const <OZExternalSigner>[];

  /// Existing on-chain signers across all rules. The `add_context_rule`
  /// op is authorised by these (not by the staged new signers, which do
  /// not yet exist on-chain).
  List<SignerInfo> _createAvailableSigners = const <SignerInfo>[];
  bool _createSignersLoaded = false;

  bool _isLoadingRule = false;
  String? _loadError;
  String _editProgressMessage = '';
  ContextRuleEditResult? _editResult;

  bool get _isEditMode => widget.editRuleId != null;

  // ---- Field errors ----

  final Map<String, String> _fieldErrors = <String, String>{};
  String? _formError;

  // ---- Submission state ----

  bool _isSubmitting = false;
  String? _resultHash;
  String? _resultError;

  // ---- Lifecycle ----

  @override
  void initState() {
    super.initState();
    _flow = widget.flow ?? ref.read(contextRuleFlowProvider);
    if (_isEditMode && _flow != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Announce the edit-mode title once the first frame has been
        // composed. Without this, switching from the prior "Add Context
        // Rule" route to "Edit Context Rule" only changes the visible
        // AppBar text and is silent for assistive technology.
        unawaited(
          SemanticsService.announce(
            'Edit Context Rule',
            Directionality.of(context),
          ),
        );
        unawaited(_loadEditRule());
        unawaited(_loadCreateAvailableSigners());
      });
    } else if (!_isEditMode && _flow != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_loadCreateAvailableSigners());
        unawaited(_resolveSpendingLimitDecimals());
      });
    }
  }

  Future<void> _loadCreateAvailableSigners() async {
    final flow = _flow;
    if (flow == null) return;
    final result = await flow.loadAvailableSigners();
    if (!mounted) return;
    setState(() {
      _createSignersLoaded = true;
      if (result.isSuccess) {
        _createAvailableSigners = result.signers;
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _wasmHashController.dispose();
    _customExpiryController.dispose();
    super.dispose();
  }

  // ---- Edit-mode helpers ----

  Future<void> _loadEditRule() async {
    final flow = _flow;
    final ruleId = widget.editRuleId;
    if (flow == null || ruleId == null) return;

    setState(() {
      _isLoadingRule = true;
      _loadError = null;
    });

    try {
      final parsed = await flow.loadParsedContextRule(ruleId);
      await _populateFromParsed(parsed, flow);
    } catch (e) {
      if (!mounted) return;
      // Sanitize the error for display while keeping the rule ID in the
      // header text so the user can correlate failure to action.
      final classified = classifyError(e);
      setState(() {
        _loadError = 'Failed to load rule #$ruleId: ${classified.message}';
        _isLoadingRule = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _isLoadingRule = false;
    });

    // The loaded rule's context type / guarded contract is now in place;
    // resolve the spending-limit decimals for the inline policy editor.
    unawaited(_resolveSpendingLimitDecimals());
  }

  Future<void> _populateFromParsed(
    OZParsedContextRule parsed,
    ContextRuleFlow flow,
  ) async {
    _nameController.text = parsed.name;
    _originalName = parsed.name;

    if (parsed.contextType is OZContextRuleTypeCallContract) {
      _contextType = _ContextTypeOption.callContract;
      _contractAddress =
          (parsed.contextType as OZContextRuleTypeCallContract).contractAddress;
    } else if (parsed.contextType is OZContextRuleTypeCreateContract) {
      _contextType = _ContextTypeOption.createContract;
      final wasm =
          (parsed.contextType as OZContextRuleTypeCreateContract).wasmHash;
      _wasmHashController.text = bytesToHex(wasm);
    } else {
      _contextType = _ContextTypeOption.defaultRule;
    }

    _existingExpiryLedger = parsed.validUntil;
    _hasExpiry = parsed.validUntil != null;
    _isCustomExpiry = false;
    _expiryOffset = null;
    _expiryModified = false;
    _customExpiryController.clear();

    // Signer entries: positionally aligned with signerIds.
    final loadedSignerEntries = <EditSignerEntry>[];
    for (var i = 0; i < parsed.signers.length; i++) {
      loadedSignerEntries.add(EditSignerEntry(
        signer: parsed.signers[i],
        onChainId:
            i < parsed.signerIds.length ? parsed.signerIds[i] : null,
        isOriginal: true,
      ));
    }
    _editSignerEntries = loadedSignerEntries;
    _originalSignerEntries = List<EditSignerEntry>.from(loadedSignerEntries);
    _signers
      ..clear()
      ..addAll(_stagedAdapter(loadedSignerEntries));

    // Policy entries: positionally aligned with policyIds. Load on-chain
    // params for each known policy. Re-check [mounted] after each await so
    // a screen pop mid-load does not push state through `_nameController`
    // or `_editPolicyEntries` after disposal.
    final loadedPolicyEntries = <EditPolicyEntry>[];
    for (var i = 0; i < parsed.policies.length; i++) {
      final addr = parsed.policies[i];
      final known = config.knownPolicies
          .where((p) => p.address == addr)
          .cast<PolicyInfo?>()
          .firstWhere(
            (_) => true,
            orElse: () => null,
          );
      PolicyParams? params;
      if (known != null) {
        // Derive the guarded token for spending-limit decimal resolution:
        // the call-contract target, or null for default / create-contract rules.
        String? guardedToken;
        final ct = parsed.contextType;
        if (ct is OZContextRuleTypeCallContract) {
          final trimmed = ct.contractAddress.trim();
          if (trimmed.isNotEmpty) guardedToken = trimmed;
        }
        params = await flow.readPolicyParams(
          policyAddress: addr,
          ruleId: parsed.id,
          guardedToken: guardedToken,
        );
        if (!mounted) return;
      }
      loadedPolicyEntries.add(EditPolicyEntry(
        info: known,
        label: known?.name ?? 'Unknown Policy',
        address: addr,
        onChainId:
            i < parsed.policyIds.length ? parsed.policyIds[i] : null,
        isOriginal: true,
        originalParams: params,
      ));
    }
    _editPolicyEntries = loadedPolicyEntries;
    _originalPolicyEntries = List<EditPolicyEntry>.from(loadedPolicyEntries);
    _policies
      ..clear()
      ..addAll(_stagedPolicyAdapter(loadedPolicyEntries));

    // Pre-load existing passkey signers so the reuse section can render
    // immediately in the passkey add form. Read the connected credential
    // ID before the await so the post-await branch never touches the
    // [Ref] after disposal.
    final excludeCredentialId = ref.read(demoStateProvider).credentialId;
    try {
      final passkeys = await flow.loadAvailablePasskeySigners(
        excludeCredentialId: excludeCredentialId,
      );
      if (!mounted) return;
      setState(() {
        _availableExistingPasskeys = passkeys;
      });
    } catch (_) {
      if (!mounted) return;
      // Loading failures are non-fatal; the reuse list stays empty. Log
      // the failure so a developer following the activity log can
      // correlate the empty reuse section with the SDK call that failed.
      ref
          .read(activityLogProvider.notifier)
          .info('Could not preload reusable passkey signers');
    }
  }

  List<StagedSigner> _stagedAdapter(List<EditSignerEntry> entries) {
    final result = <StagedSigner>[];
    for (final entry in entries) {
      final info = formatSignerForDisplay(entry.signer);
      result.add(StagedSigner(
        type: _stagedTypeForSigner(entry.signer),
        identifier: info.displayValue,
        signer: entry.signer,
      ));
    }
    return result;
  }

  StagedSignerType _stagedTypeForSigner(OZSmartAccountSigner signer) {
    if (signer is OZDelegatedSigner) return StagedSignerType.delegated;
    if (signer is OZExternalSigner) {
      final credId = getCredentialIdStringFromSigner(signer);
      if (credId != null) return StagedSignerType.passkey;
      return StagedSignerType.ed25519;
    }
    return StagedSignerType.delegated;
  }

  List<StagedPolicy> _stagedPolicyAdapter(List<EditPolicyEntry> entries) {
    final result = <StagedPolicy>[];
    for (final entry in entries) {
      final info = entry.info ??
          PolicyInfo(
            type: PolicyType.unknown,
            name: 'Unknown',
            description: '',
            address: entry.address,
          );
      result.add(StagedPolicy(
        info: info,
        label: entry.label,
        // This adapter feeds the removal/display row only. The installParams
        // field is never read on that path; a benign placeholder satisfies
        // the required non-null contract.
        installParams: _removalPlaceholderParams,
      ));
    }
    return result;
  }

  /// Computes the diff between the original on-chain rule and the current
  /// edit-mode form state. Returns null when not in edit mode.
  ContextRuleEditDiff? _computeEditDiff() {
    if (!_isEditMode) return null;
    final ruleId = widget.editRuleId;
    if (ruleId == null) return null;

    final nameChanged = _nameController.text.trim() != _originalName;

    final removedSigners = <EditSignerEntry>[];
    for (final original in _originalSignerEntries) {
      // Only an original entry keeps the signer present. A newly added entry for
      // the same signer does not — otherwise removing a signer and adding the
      // same signer back in one edit would drop the remove, and the on-chain add
      // would fail with DuplicateSigner.
      final stillPresent = _editSignerEntries.any(
        (e) => e.isOriginal && signersEqual(e.signer, original.signer),
      );
      if (!stillPresent) removedSigners.add(original);
    }
    final newSigners = <EditSignerEntry>[
      for (final e in _editSignerEntries)
        if (!e.isOriginal) e,
    ];

    final removedPolicies = <EditPolicyEntry>[];
    for (final original in _originalPolicyEntries) {
      // Only an original entry keeps the policy present. A newly added policy
      // of the same type (same contract address) does not — otherwise removing
      // a policy and adding a fresh one of the same type would drop the remove,
      // and the on-chain add would fail with DuplicatePolicy.
      final stillPresent = _editPolicyEntries
          .any((e) => e.isOriginal && e.address == original.address);
      if (!stillPresent) removedPolicies.add(original);
    }
    final newPolicies = <EditPolicyEntry>[
      for (final e in _editPolicyEntries)
        if (!e.isOriginal) e,
    ];
    final modifiedPolicies = <EditPolicyEntry>[
      for (final e in _editPolicyEntries)
        if (e.isOriginal && e.modified) e,
    ];

    int? newExpiry;
    if (_expiryModified) {
      if (_hasExpiry) {
        newExpiry = _expiryOffset;
      } else {
        newExpiry = null;
      }
    }

    return ContextRuleEditDiff(
      ruleId: ruleId,
      nameChanged: nameChanged,
      newName: nameChanged ? _nameController.text.trim() : null,
      newSigners: newSigners,
      removedSigners: removedSigners,
      newPolicies: newPolicies,
      removedPolicies: removedPolicies,
      modifiedPolicies: modifiedPolicies,
      expiryChanged: _expiryModified,
      newExpiry: newExpiry,
    );
  }

  // ---- Signer staging helpers ----

  String? _addSigner(StagedSigner signer) {
    final currentCount =
        _isEditMode ? _editSignerEntries.length : _signers.length;
    if (currentCount >= ContextRuleBuilderLimits.maxSigners) {
      return 'Maximum ${ContextRuleBuilderLimits.maxSigners} signers allowed';
    }
    final isDup = _isEditMode
        ? _editSignerEntries.any((e) => signersEqual(e.signer, signer.signer))
        : _signers.any((s) => signersEqual(s.signer, signer.signer));
    if (isDup) {
      return 'This signer is already added';
    }
    setState(() {
      _signers.add(signer);
      if (_isEditMode) {
        _editSignerEntries = [
          ..._editSignerEntries,
          EditSignerEntry(
            signer: signer.signer,
            onChainId: null,
            isOriginal: false,
          ),
        ];
      }
      _fieldErrors.remove('signers');
    });
    return null;
  }

  void _removeSigner(StagedSigner signer) {
    setState(() {
      _signers.removeWhere((s) => s.uniqueKey == signer.uniqueKey);
      if (_isEditMode) {
        _editSignerEntries = [
          for (final e in _editSignerEntries)
            if (!signersEqual(e.signer, signer.signer)) e,
        ];
      }
    });
  }

  /// The token contract a spending-limit policy on this rule would guard:
  /// the call-contract target, or null for default / create-contract rules.
  String? get _spendingLimitGuardedToken {
    if (_contextType != _ContextTypeOption.callContract) return null;
    final trimmed = _contractAddress.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Resolves [_spendingLimitDecimals] for the current guarded token.
  ///
  /// Native XLM and non-token rules resolve to [nativeTokenDecimals] without
  /// a network call. A custom guarded token's `decimals()` value is fetched
  /// via the flow. A fetch failure is surfaced through
  /// [_spendingLimitDecimalsError] and leaves the stored decimals unchanged
  /// so the gated Add button prevents converting an amount with the wrong
  /// scale. A monotonic token guards against a stale late response
  /// overwriting a newer resolution.
  Future<void> _resolveSpendingLimitDecimals() async {
    final flow = _flow;
    if (flow == null) return;
    final guardedToken = _spendingLimitGuardedToken;
    final requestToken = ++_spendingLimitDecimalsToken;
    setState(() => _spendingLimitDecimalsError = null);
    try {
      final resolved = await flow.resolveSpendingLimitDecimals(guardedToken);
      if (!mounted || requestToken != _spendingLimitDecimalsToken) return;
      setState(() => _spendingLimitDecimals = resolved);
    } catch (e) {
      if (!mounted || requestToken != _spendingLimitDecimalsToken) return;
      final message = classifyError(e).message;
      setState(() => _spendingLimitDecimalsError =
          'Could not read token decimals for the guarded contract: $message');
    }
  }

  String? _addPolicy(StagedPolicy policy) {
    final currentCount =
        _isEditMode ? _editPolicyEntries.length : _policies.length;
    if (currentCount >= ContextRuleBuilderLimits.maxPolicies) {
      return 'Maximum ${ContextRuleBuilderLimits.maxPolicies} policies allowed';
    }
    final dup = _isEditMode
        ? _editPolicyEntries.any((e) => e.address == policy.address)
        : _policies.any((p) => p.address == policy.address);
    if (dup) {
      return 'This policy type is already added';
    }
    setState(() {
      _policies.add(policy);
      if (_isEditMode) {
        // Convert the create-path typed params to an edit-path PolicyInstallSpec
        // so the flow can call the correct SDK convenience method at submit.
        final spec = _installParamsToSpec(
          policy.installParams,
          decimals: _spendingLimitDecimals,
        );
        _editPolicyEntries = [
          ..._editPolicyEntries,
          EditPolicyEntry(
            info: policy.info,
            label: policy.label,
            address: policy.address,
            installSpec: spec,
            onChainId: null,
            isOriginal: false,
          ),
        ];
      }
    });
    return null;
  }

  void _removePolicy(StagedPolicy policy) {
    setState(() {
      _policies.removeWhere((p) => p.address == policy.address);
      if (_isEditMode) {
        _editPolicyEntries = [
          for (final e in _editPolicyEntries)
            if (e.address != policy.address) e,
        ];
      }
    });
  }

  /// Converts a CREATE-path [OZPolicyInstallParams] to an edit-path
  /// [PolicyInstallSpec] so the orchestrator can call the correct SDK
  /// convenience method without going through [OZPolicyInstallParams.toScVal].
  ///
  /// Spending-limit conversion uses [decimals] as the token scale; the caller
  /// should pass the currently resolved [_spendingLimitDecimals]. Returns null
  /// when [params] is null or an unrecognised subtype.
  PolicyInstallSpec? _installParamsToSpec(
    OZPolicyInstallParams? params, {
    required int decimals,
  }) {
    if (params == null) return null;
    if (params is OZSimpleThresholdPolicyParams) {
      return PolicyInstallSpecSimpleThreshold(threshold: params.threshold);
    }
    if (params is OZWeightedThresholdPolicyParams) {
      final entries = params.signerWeights.entries
          .map((e) => PolicyWeightedEntry(signer: e.key, weight: e.value))
          .toList();
      return PolicyInstallSpecWeightedThreshold(
        entries: entries,
        threshold: params.threshold,
      );
    }
    if (params is OZSpendingLimitPolicyParams) {
      // Reverse the base-units amount to a decimal string at the current
      // guarded-token scale so the flow can forward it to addSpendingLimit.
      final amountStr = formatBaseUnitsAsDecimal(
        params.spendingLimit,
        decimals: decimals,
      );
      return PolicyInstallSpecSpendingLimit(
        amount: amountStr,
        decimals: decimals,
        periodLedgers: params.periodLedgers,
      );
    }
    return null;
  }

  /// Replaces an existing edit-mode policy entry by address. Used by the
  /// inline policy params form to record parameter modifications.
  void _onEditPolicyEntryUpdated(EditPolicyEntry updated) {
    setState(() {
      _editPolicyEntries = [
        for (final e in _editPolicyEntries)
          if (e.address == updated.address) updated else e,
      ];
    });
  }

  // ---- Validation ----

  Map<String, String> _validate() {
    final errors = <String, String>{};
    final trimmedName = _nameController.text.trim();
    if (trimmedName.isEmpty) {
      errors['ruleName'] = 'Rule name is required';
    } else if (utf8.encode(trimmedName).length >
        ContextRuleBuilderLimits.maxRuleNameBytes) {
      errors['ruleName'] =
          'Rule name must be ${ContextRuleBuilderLimits.maxRuleNameBytes} bytes or less';
    }
    if (!_isEditMode) {
      switch (_contextType) {
        case _ContextTypeOption.defaultRule:
          break;
        case _ContextTypeOption.callContract:
          if (_contractAddress.trim().isEmpty) {
            errors['contractAddress'] = 'A contract must be selected';
          }
        case _ContextTypeOption.createContract:
          final hex = _wasmHashController.text.trim().toLowerCase();
          if (hex.isEmpty) {
            errors['wasmHash'] = 'WASM hash is required';
          } else if (hex.length != 64) {
            errors['wasmHash'] =
                'Must be 64 hex characters (32 bytes), got ${hex.length}';
          } else if (!isValidHex(hex)) {
            errors['wasmHash'] = 'Invalid hex characters';
          }
      }
    }
    if (_hasExpiry && _expiryModified) {
      final offset = _expiryOffset;
      if (offset == null) {
        errors['expiry'] = 'Please select an expiry duration';
      } else if (offset <= 0) {
        errors['expiry'] = 'Must be a positive integer';
      }
    }
    if (_isEditMode) {
      if (_editSignerEntries.isEmpty && _editPolicyEntries.isEmpty) {
        errors['signers'] = 'At least one signer or policy must remain';
      }
      if (_editSignerEntries.length > ContextRuleBuilderLimits.maxSigners) {
        errors['signers'] =
            'Maximum ${ContextRuleBuilderLimits.maxSigners} signers allowed';
      }
      if (_editPolicyEntries.length > ContextRuleBuilderLimits.maxPolicies) {
        errors['policies'] =
            'Maximum ${ContextRuleBuilderLimits.maxPolicies} policies allowed';
      }
    } else {
      if (_signers.isEmpty) {
        errors['signers'] = 'At least one signer is required';
      }
    }
    return errors;
  }

  OZContextRuleType _buildContextType(ContextRuleFlow flow) {
    switch (_contextType) {
      case _ContextTypeOption.defaultRule:
        return flow.buildDefaultContextType();
      case _ContextTypeOption.callContract:
        return flow.buildCallContractContextType(_contractAddress.trim());
      case _ContextTypeOption.createContract:
        final hex = _wasmHashController.text.trim().toLowerCase();
        return flow.buildCreateContractContextType(hexToBytes(hex));
    }
  }

  // ---- Submit ----

  Future<void> _onSubmit() async {
    final flow = _flow;
    if (flow == null || _isSubmitting) return;

    final errors = _validate();
    if (errors.isNotEmpty) {
      setState(() {
        _fieldErrors
          ..clear()
          ..addAll(errors);
        _formError = 'Please fix the validation errors above.';
      });
      return;
    }

    setState(() {
      _fieldErrors.clear();
      _formError = null;
      _resultError = null;
      _editResult = null;
    });

    if (_isEditMode) {
      final diff = _computeEditDiff();
      if (diff == null || diff.isEmpty) {
        setState(() => _formError = 'No changes to apply');
        return;
      }
      // Multi-signer detection: edit-mode uses the original on-chain signer
      // set (not the diff) to determine multi-signer routing — the rule's
      // current authorization context is what authorises the per-op
      // transactions. Count is the only criterion: a rule without a
      // threshold policy requires all of its signers, so a multi-signer
      // rule needs the picker even when every signer is a passkey.
      final onChainSigners = _originalSignerEntries.map((e) => e.signer).toList();
      final needsMultiSigner = onChainSigners.length > 1;

      if (needsMultiSigner) {
        await _openMultiSignerPickerForEdit(flow: flow, diff: diff);
        return;
      }
      await _submitEditDirect(
        flow: flow,
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
      );
      return;
    }

    // While the existing-signers fetch is in flight, take the single-signer
    // fast path; the SDK rejects the submission with an actionable error
    // if the picker would actually have been required.
    final needsMultiSigner =
        _createSignersLoaded && _createAvailableSigners.length > 1;

    if (needsMultiSigner) {
      await _openMultiSignerPicker(flow: flow);
      return;
    }

    await _submitDirect(flow: flow, selectedSigners: const <OZSelectedSigner>[]);
  }

  Future<void> _openMultiSignerPicker({
    required ContextRuleFlow flow,
  }) async {
    final credentialId = ref.read(demoStateProvider).credentialId;
    await SignerPickerSheet.show(
      context: context,
      availableSigners: _createAvailableSigners,
      connectedCredentialId: credentialId,
      validateDelegatedSecret: flow.validateDelegatedSecret,
      validateEd25519Secret: ContextRuleFlow.validateEd25519Secret,
      walletConnector: ref.read(demoStateProvider.notifier).walletConnectorForUi,
      ed25519SigningEnabled: true,
      title: 'Select Signers',
      description: 'Choose which signers co-authorize creating this context '
          'rule. For Stellar account signers, enter the secret key to '
          'enable signing.',
      onConfirm: (selectedSigners, delegatedKeyPairs, ed25519Secrets) {
        unawaited(_onPickerConfirmWith(
          flow: flow,
          selectedSigners: selectedSigners,
          delegatedKeyPairs: delegatedKeyPairs,
          ed25519Secrets: ed25519Secrets,
          submitTarget: (selected) => _submitDirect(
            flow: flow,
            selectedSigners: selected,
          ),
          classifyError: flow.classifyAddRuleError,
        ));
      },
    );
  }

  Future<void> _openMultiSignerPickerForEdit({
    required ContextRuleFlow flow,
    required ContextRuleEditDiff diff,
  }) async {
    final credentialId = ref.read(demoStateProvider).credentialId;

    await SignerPickerSheet.show(
      context: context,
      availableSigners: _createAvailableSigners,
      connectedCredentialId: credentialId,
      validateDelegatedSecret: flow.validateDelegatedSecret,
      validateEd25519Secret: ContextRuleFlow.validateEd25519Secret,
      walletConnector: ref.read(demoStateProvider.notifier).walletConnectorForUi,
      ed25519SigningEnabled: true,
      title: 'Select Signers',
      description: 'Choose which signers co-authorize editing this context '
          'rule. For Stellar account signers, enter the secret key to '
          'enable signing.',
      onConfirm: (selectedSigners, delegatedKeyPairs, ed25519Secrets) {
        unawaited(_onPickerConfirmWith(
          flow: flow,
          selectedSigners: selectedSigners,
          delegatedKeyPairs: delegatedKeyPairs,
          ed25519Secrets: ed25519Secrets,
          submitTarget: (selected) => _submitEditDirect(
            flow: flow,
            diff: diff,
            selectedSigners: selected,
          ),
          classifyError: flow.classifyEditError,
        ));
      },
    );
  }

  /// Shared picker-confirm handler.
  ///
  /// Invariant: always runs in the order
  /// `register delegated keys → register Ed25519 keys → submit →
  /// clear delegated keys`. [ContextRuleFlow.withMultiSignerRegistration]
  /// owns that order: it registers both key sets inside a guarded region and
  /// guarantees [ContextRuleFlow.clearDelegatedKeypairs] always runs (even when
  /// registration or submission throws or the screen unmounts mid-flight), so
  /// key material never persists across screens.
  ///
  /// [submitTarget] is invoked with the resolved [OZSelectedSigner] list.
  /// [classifyError] maps any thrown error to a user-facing message for display
  /// in the result-error slot.
  Future<void> _onPickerConfirmWith({
    required ContextRuleFlow flow,
    required List<SignerInfo> selectedSigners,
    required Map<String, String> delegatedKeyPairs,
    required Map<Ed25519SignerIdentity, Uint8List> ed25519Secrets,
    required Future<void> Function(List<OZSelectedSigner>) submitTarget,
    required String Function(Object) classifyError,
  }) async {
    // Block the form before any awaitable runs so the primary CTA
    // and form fields all read as disabled while the keypair
    // registration is in-flight.
    if (mounted) {
      setState(() {
        _isSubmitting = true;
      });
    }

    try {
      await flow.withMultiSignerRegistration(
        delegatedKeyPairs: delegatedKeyPairs,
        ed25519Secrets: ed25519Secrets,
        body: () async {
          if (!mounted) return;
          final selected = await flow.buildSelectedSigners(selectedSigners);
          await submitTarget(
            flow.isSinglePasskeyRemoval(selected)
                ? const <OZSelectedSigner>[]
                : selected,
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _resultError = classifyError(e);
      });
    }
  }

  Future<void> _submitEditDirect({
    required ContextRuleFlow flow,
    required ContextRuleEditDiff diff,
    required List<OZSelectedSigner> selectedSigners,
  }) async {
    setState(() {
      _isSubmitting = true;
      _resultError = null;
      _editProgressMessage = '';
    });

    ContextRuleEditResult? result;
    try {
      final resolved = await flow.resolveEditDiffExpiry(diff);
      result = await flow.submitContextRuleEdits(
        diff: resolved,
        selectedSigners: selectedSigners,
        onProgress: (msg) {
          if (!mounted) return;
          setState(() {
            _editProgressMessage = msg;
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _resultError = flow.classifyEditError(e);
      });
      return;
    }

    if (!mounted) return;
    final editResult = result;
    setState(() {
      _isSubmitting = false;
      _editResult = editResult;
    });

    // Refresh form state on partial success or failure so a retry sees
    // the current on-chain state.
    if (editResult.partialDueToAuthGuard || !editResult.success) {
      await _loadEditRule();
    }
  }

  Future<void> _submitDirect({
    required ContextRuleFlow flow,
    required List<OZSelectedSigner> selectedSigners,
  }) async {
    setState(() {
      _isSubmitting = true;
      _resultError = null;
    });

    try {
      final contextType = _buildContextType(flow);
      // Capture into a local non-null binding so the await + bang pair
      // isn't dependent on a getter that might return null if the field
      // were mutated mid-flight.
      final expiryOffset = _expiryOffset;
      final validUntil = _hasExpiry && expiryOffset != null
          ? await flow.resolveAbsoluteLedger(expiryOffset)
          : null;

      final flowPolicies = [
        for (final p in _policies)
          FlowPolicyEntry(address: p.address, installParams: p.installParams),
      ];
      final flowSigners = <OZSmartAccountSigner>[
        for (final s in _signers) s.signer,
      ];

      final result = await flow.addContextRule(
        contextType: contextType,
        name: _nameController.text.trim(),
        validUntil: validUntil,
        signers: flowSigners,
        policies: flowPolicies,
        selectedSigners: selectedSigners,
      );

      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        if (result.success) {
          _resultHash = result.hash;
          _resultError = null;
        } else {
          _resultError = result.error ?? 'Transaction failed';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _resultError = flow.classifyAddRuleError(e);
      });
    }
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(demoStateProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditMode ? 'Edit Context Rule' : 'Add Context Rule'),
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => popOrGoMain(context),
        ),
      ),
      body: ListView(
        padding: kCardPadding,
        children: _buildBody(context, connectionState),
      ),
    );
  }

  List<Widget> _buildBody(
    BuildContext context,
    WalletConnectionState state,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (!state.isConnected || _flow == null) {
      return const [
        EmptyStateCard(
          icon: Icons.account_balance_wallet_outlined,
          title: 'No wallet connected',
          message: 'Connect a wallet to create or edit context rules.',
        ),
      ];
    }

    // Edit-mode loading state.
    if (_isLoadingRule) {
      return [
        const SectionDescriptionCard(
          title: 'Rule Configuration',
          message: 'Define the context type and basic settings for this rule.',
        ),
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: LoadingLabel(
            label: 'Loading rule...',
            color: colorScheme.primary,
            size: 18,
            gap: 10,
            textStyle: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ];
    }

    // Edit-mode load failure.
    if (_loadError != null) {
      return [
        ErrorCard(
          message: _loadError!,
          actionLabel: 'Retry',
          onAction: _loadEditRule,
        ),
      ];
    }

    // Edit-mode full-success card — replaces the entire form so the user
    // can confirm completion and navigate back.
    final editResult = _editResult;
    final isEditFullSuccess = _isEditMode &&
        editResult != null &&
        editResult.success &&
        !editResult.partialDueToAuthGuard;

    final children = <Widget>[
      const SectionDescriptionCard(
        title: 'Rule Configuration',
        message: 'Define the context type and basic settings for this rule.',
      ),
      const SizedBox(height: 16),
      // Create-mode success card.
      if (!_isEditMode && _resultHash != null) ...[
        _SuccessCard(
          hash: _resultHash!,
          colorScheme: colorScheme,
          textTheme: textTheme,
        ),
        const SizedBox(height: 16),
      ],
      // Edit-mode result card.
      if (_isEditMode && editResult != null) ...[
        EditSuccessCard(
          result: editResult,
          onDone: () => Navigator.of(context).maybePop(true),
        ),
        const SizedBox(height: 16),
      ],
      if (_resultError != null) ...[
        ErrorCard(message: _resultError!),
        const SizedBox(height: 16),
      ],
      if (_formError != null) ...[
        ErrorCard(message: _formError!),
        const SizedBox(height: 16),
      ],
      if (!isEditFullSuccess && _resultHash == null) ...[
        _RuleNameField(
          controller: _nameController,
          error: _fieldErrors['ruleName'],
          enabled: !_isSubmitting,
          onChanged: () {
            if (_fieldErrors.containsKey('ruleName')) {
              setState(() => _fieldErrors.remove('ruleName'));
            }
            setState(() {});
          },
        ),
        const SizedBox(height: 12),
        _ContextTypeSection(
          option: _contextType,
          contractAddress: _contractAddress,
          wasmHashController: _wasmHashController,
          contractError: _fieldErrors['contractAddress'],
          wasmError: _fieldErrors['wasmHash'],
          enabled: !_isSubmitting && !_isEditMode,
          showEditHelper: _isEditMode,
          onOptionChanged: (opt) {
            setState(() {
              _contextType = opt;
              _fieldErrors
                ..remove('contractAddress')
                ..remove('wasmHash');
              if (opt == _ContextTypeOption.callContract &&
                  _contractAddress.isEmpty) {
                _contractAddress = config.nativeTokenContract;
              }
            });
            unawaited(_resolveSpendingLimitDecimals());
          },
          onContractChanged: (addr) {
            setState(() {
              _contractAddress = addr;
              _fieldErrors.remove('contractAddress');
            });
            unawaited(_resolveSpendingLimitDecimals());
          },
          onWasmChanged: () {
            if (_fieldErrors.containsKey('wasmHash')) {
              setState(() => _fieldErrors.remove('wasmHash'));
            }
          },
        ),
        const SizedBox(height: 12),
        _ExpirySection(
          hasExpiry: _hasExpiry,
          offset: _expiryOffset,
          isCustom: _isCustomExpiry,
          customController: _customExpiryController,
          error: _fieldErrors['expiry'],
          enabled: !_isSubmitting,
          existingExpiryLedger: _existingExpiryLedger,
          onChanged: (hasExpiry, offset, isCustom) {
            setState(() {
              final wasExpiry = _hasExpiry;
              final wasOffset = _expiryOffset;
              _hasExpiry = hasExpiry;
              _expiryOffset = offset;
              _isCustomExpiry = isCustom;
              if (_isEditMode) {
                final changed =
                    hasExpiry != wasExpiry || offset != wasOffset;
                if (changed) _expiryModified = true;
              }
              _fieldErrors.remove('expiry');
            });
          },
        ),
        const SizedBox(height: 16),
        SignerManagementSection(
          signers: _signers,
          fieldError: _fieldErrors['signers'],
          isSubmitting: _isSubmitting,
          maxSigners: ContextRuleBuilderLimits.maxSigners,
          ed25519VerifierAddress: _flow?.ed25519VerifierAddress,
          buildDelegatedSigner: (address) =>
              _flow!.buildDelegatedSigner(address),
          buildEd25519Signer: (publicKey) =>
              _flow!.buildEd25519Signer(publicKey),
          onAddSigner: _addSigner,
          onRemoveSigner: _removeSigner,
          loadPasskeySigners: () => _flow!.loadAvailablePasskeySigners(
            excludeCredentialId: ref.read(demoStateProvider).credentialId,
          ),
          registerPasskeySigner: (name) => _flow!.registerPasskeySigner(name),
          editEntries: _isEditMode ? _editSignerEntries : null,
          connectedCredentialId:
              _isEditMode ? ref.read(demoStateProvider).credentialId : null,
          availableExistingPasskeys:
              _isEditMode ? _availableExistingPasskeys : null,
        ),
        const SizedBox(height: 16),
        PolicyManagementSection(
          policies: _policies,
          signers: _signers,
          fieldError: _fieldErrors['policies'],
          isSubmitting: _isSubmitting,
          maxPolicies: ContextRuleBuilderLimits.maxPolicies,
          spendingLimitDecimals: _spendingLimitDecimals,
          spendingLimitDecimalsError: _spendingLimitDecimalsError,
          onAddPolicy: _addPolicy,
          onRemovePolicy: _removePolicy,
          editEntries: _isEditMode ? _editPolicyEntries : null,
          onEditEntryUpdated:
              _isEditMode ? _onEditPolicyEntryUpdated : null,
        ),
        const SizedBox(height: 24),
        if (_isEditMode) ...[
          Builder(builder: (_) {
            final diff = _computeEditDiff() ??
                ContextRuleEditDiff(
                  ruleId: widget.editRuleId ?? 0,
                  nameChanged: false,
                  newName: null,
                  newSigners: const <EditSignerEntry>[],
                  removedSigners: const <EditSignerEntry>[],
                  newPolicies: const <EditPolicyEntry>[],
                  removedPolicies: const <EditPolicyEntry>[],
                  modifiedPolicies: const <EditPolicyEntry>[],
                  expiryChanged: false,
                  newExpiry: null,
                );
            return OperationSummaryCard(diff: diff);
          }),
          const SizedBox(height: 12),
        ],
        if (_isEditMode && _editProgressMessage.isNotEmpty) ...[
          // Live-region wrapper announces each on-chain operation as the
          // edit flow progresses. The loading-button [loadingLabel] alone
          // would not refresh because assistive technology only re-reads
          // the label when the loading state toggles, not when the label
          // value mutates underneath.
          Semantics(
            liveRegion: true,
            child: Text(
              _editProgressMessage,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        _SubmitButton(
          isEditMode: _isEditMode,
          isSubmitting: _isSubmitting,
          progressMessage: _editProgressMessage,
          enabled: _canSubmit(state),
          disabledHint: _disabledHint(state),
          onSubmit: _onSubmit,
        ),
        const SizedBox(height: 40),
      ],
    ];
    return children;
  }

  bool _canSubmit(WalletConnectionState state) {
    if (!state.isConnected) return false;
    if (_isSubmitting) return false;
    // Close the reload race: while [_loadEditRule] is fetching the on-chain
    // rule, the diff is computed against transient state and would either
    // be empty or compare against stale fields.
    if (_isEditMode && _isLoadingRule) return false;
    final trimmedName = _nameController.text.trim();
    if (trimmedName.isEmpty) return false;
    if (utf8.encode(trimmedName).length >
        ContextRuleBuilderLimits.maxRuleNameBytes) {
      return false;
    }
    if (_isEditMode) {
      final diff = _computeEditDiff();
      if (diff == null || diff.isEmpty) return false;
      return true;
    }
    if (_signers.isEmpty) return false;
    if (_resultHash != null) return false;
    return true;
  }

  String? _disabledHint(WalletConnectionState state) {
    if (!state.isConnected) return 'Wallet not connected';
    if (_isSubmitting) return 'Submission in progress';
    if (_isEditMode && _isLoadingRule) return 'Loading rule...';
    final trimmedName = _nameController.text.trim();
    final nameTooLong = utf8.encode(trimmedName).length >
        ContextRuleBuilderLimits.maxRuleNameBytes;
    if (_isEditMode) {
      if (trimmedName.isEmpty) return 'Form is incomplete';
      if (nameTooLong) {
        return 'Rule name exceeds ${ContextRuleBuilderLimits.maxRuleNameBytes} '
            'bytes';
      }
      final diff = _computeEditDiff();
      if (diff == null || diff.isEmpty) return 'No changes to apply';
      return null;
    }
    if (trimmedName.isEmpty || _signers.isEmpty) {
      return 'Form is incomplete';
    }
    if (nameTooLong) {
      return 'Rule name exceeds ${ContextRuleBuilderLimits.maxRuleNameBytes} '
          'bytes';
    }
    return null;
  }
}

