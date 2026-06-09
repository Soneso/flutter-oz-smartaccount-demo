/// Reusable signer identity chip used across staged, on-chain-edit, and
/// weighted-threshold signer rows.
///
/// The chip is a colored rounded container that holds a type [Pill] badge and
/// a monospace identifier value, both wrapped in a single [Semantics] node so
/// assistive technology reads them as one unit. An optional [inlineTrailing]
/// widget is appended to the right of the value inside the chip (e.g. an
/// "(on-chain)" text badge). Call-site trailing widgets such as remove buttons
/// or weight fields are Row siblings outside of this widget.
///
/// Usage: wrap this widget in an [Expanded] so it fills the available width
/// of the parent [Row].
library;

import 'package:flutter/material.dart';

import 'pill.dart';

/// Colored rounded chip displaying a signer type badge and a monospace value.
///
/// Parameters are all primitives so the widget works with every signer data
/// model in the app (staged signers, edit entries, weighted-threshold entries).
///
/// The semantic label defaults to `'$typeLabel signer: $displayValue'`. Pass
/// [semanticsSuffix] to append extra context (e.g. `', on-chain'`, `', you'`)
/// without changing the visual layout.
///
/// [padding] controls the insets of the chip container. Defaults to
/// `fromLTRB(10, 8, 6, 8)` to match the signer-row sites. Pass a different
/// value when the site requires tighter/looser insets.
///
/// [inlineTrailing] renders to the right of [displayValue] inside a [Wrap],
/// useful for small annotation badges such as `(on-chain)`. When null,
/// [displayValue] renders in a plain [Text] with tabular-figure font features.
class SignerIdentityChip extends StatelessWidget {
  /// Creates a [SignerIdentityChip].
  const SignerIdentityChip({
    required this.typeLabel,
    required this.displayValue,
    required this.chipColor,
    this.semanticsSuffix,
    this.inlineTrailing,
    this.padding = const EdgeInsets.fromLTRB(10, 8, 6, 8),
    super.key,
  });

  /// Short label for the signer type, shown in the [Pill] badge (e.g.
  /// `'Passkey'`, `'G-Address'`, `'Ed25519'`).
  final String typeLabel;

  /// The identifier string displayed in monospace after the badge.
  final String displayValue;

  /// Resolved background tint for the chip. Callers compute this with their
  /// site-appropriate color helper (`signerTypeColor`,
  /// `signerTypeColorForDisplayLabel`). The container fill uses
  /// `chipColor.withAlpha(20)`; the [Pill] background uses `chipColor`.
  final Color chipColor;

  /// Optional suffix appended to the base semantic label
  /// `'$typeLabel signer: $displayValue'`. Include any leading separator,
  /// e.g. `', on-chain'` or `', you'`.
  final String? semanticsSuffix;

  /// Optional widget rendered to the right of [displayValue] inside a [Wrap].
  /// When null, [displayValue] renders in a plain [Text] without a [Wrap].
  final Widget? inlineTrailing;

  /// Internal padding of the chip container. Defaults to
  /// `EdgeInsets.fromLTRB(10, 8, 6, 8)`. The weighted-signer-row site uses
  /// `fromLTRB(10, 6, 10, 6)` and passes that value explicitly.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final String semanticsLabel =
        '$typeLabel signer: $displayValue${semanticsSuffix ?? ''}';

    final Widget valueContent;
    if (inlineTrailing != null) {
      // Wrap so the inline trailing badge can flow to the next line on narrow
      // screens without being clipped.
      valueContent = Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Text(
            displayValue,
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface,
              fontFamily: 'monospace',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          inlineTrailing!,
        ],
      );
    } else {
      valueContent = Text(
        displayValue,
        style: textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurface,
          fontFeatures: const [FontFeature.tabularFigures()],
          fontFamily: 'monospace',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: chipColor.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Semantics(
        container: true,
        label: semanticsLabel,
        excludeSemantics: true,
        child: Row(
          children: [
            Pill(
              label: typeLabel,
              background: chipColor,
              foreground: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            ),
            const SizedBox(width: 8),
            Expanded(child: valueContent),
          ],
        ),
      ),
    );
  }
}
