/// Edit-mode result card.
///
/// Renders one of three variants based on the [ContextRuleEditResult]:
///
/// - Full success — `successBackground` container, `All Changes Applied`
///   title, per-hash copy rows, a `Done` button that pops the route.
/// - Partial success (auth-guard pause) — `partialBackground` container,
///   `Partial Update` title, hash rows, and the auth-guard message. No
///   `Done` button — the user resubmits the remaining diff on the same
///   screen.
/// - Failure — error container, `Update Failed` title, sanitised error
///   message, and the failed-step description. No `Done` button.
///
/// The hash rows expose a per-hash `Copy` button that copies the full
/// hash and posts a `Hash copied` snackbar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../flows/context_rule_edit_types.dart';
import '../theme/spacing.dart';
import '../util/clipboard.dart';
import '../util/semantic_colors.dart';

// ---------------------------------------------------------------------------
// EditSuccessCard
// ---------------------------------------------------------------------------

/// Edit-mode result card.
class EditSuccessCard extends StatelessWidget {
  /// Creates an edit result card.
  const EditSuccessCard({
    required this.result,
    required this.onDone,
    super.key,
  });

  /// The result to render.
  final ContextRuleEditResult result;

  /// Called when the user taps `Done` (full-success variant only).
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isFullSuccess = result.success && !result.partialDueToAuthGuard;
    final isPartial = result.success && result.partialDueToAuthGuard;

    final Color background;
    final Color titleColor;
    final Color bodyColor;
    final String title;

    if (isFullSuccess) {
      background = colorScheme.successBackground;
      titleColor = colorScheme.successForeground;
      bodyColor = colorScheme.successForeground;
      title = 'All Changes Applied';
    } else if (isPartial) {
      background = colorScheme.partialBackground;
      titleColor = colorScheme.partialForeground;
      bodyColor = colorScheme.partialForeground;
      title = 'Partial Update';
    } else {
      background = colorScheme.errorContainer;
      titleColor = colorScheme.onErrorContainer;
      bodyColor = colorScheme.onErrorContainer;
      title = 'Update Failed';
    }

    return Container(
      width: double.infinity,
      padding: kCardPadding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      // The outer Semantics is a [liveRegion] so the card content is announced
      // as soon as it appears after the edit submission resolves.
      child: Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${result.completedOperations} of ${result.totalOperations} '
              'operation(s) completed',
              style: textTheme.bodySmall?.copyWith(color: bodyColor),
            ),
            if (result.transactionHashes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Transaction Hashes',
                style: textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: bodyColor,
                ),
              ),
              const SizedBox(height: 6),
              for (final hash in result.transactionHashes)
                _HashRow(hash: hash, color: bodyColor, textTheme: textTheme),
            ],
            if (result.authGuardMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                result.authGuardMessage!,
                style: textTheme.bodySmall?.copyWith(color: bodyColor),
              ),
            ],
            if (result.error != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                result.error!,
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onErrorContainer),
              ),
            ],
            if (result.failedStep != null) ...[
              const SizedBox(height: 6),
              Text(
                'Failed at: ${result.failedStep}',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onErrorContainer),
              ),
            ],
            if (isFullSuccess) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: Semantics(
                  button: true,
                  label: 'Done. Close edit context rule screen.',
                  excludeSemantics: true,
                  child: FilledButton(
                    onPressed: onDone,
                    child: const Text('Done'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HashRow extends StatelessWidget {
  const _HashRow({
    required this.hash,
    required this.color,
    required this.textTheme,
  });

  final String hash;
  final Color color;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hash,
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: 'Copy transaction hash',
            excludeSemantics: true,
            child: OutlinedButton(
              onPressed: () {
                unawaited(_copyHash(context, hash));
              },
              child: const Text('Copy'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyHash(BuildContext context, String hash) async {
    await copyTxHash(hash);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Hash copied')),
    );
    await SemanticsService.announce(
      'Hash copied',
      Directionality.of(context),
    );
  }
}
