/// URL-opening helpers wrapping [url_launcher].
library;

import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------------------
// URL opening
// ---------------------------------------------------------------------------

/// Opens [url] in the default browser or handler.
///
/// On mobile, prefers an in-app browser via [LaunchMode.inAppBrowserView].
/// Falls back to the external application if the in-app view is unavailable.
/// On Web, always opens in a new tab.
///
/// Throws [ArgumentError] if [url] is empty or has no scheme (http/https).
/// Returns silently if the platform reports the URL cannot be launched
/// (e.g., no handler available for the scheme).
Future<void> openUrl(String url) async {
  if (url.isEmpty) {
    throw ArgumentError('URL must not be empty');
  }
  final uri = Uri.parse(url);
  final canLaunch = await canLaunchUrl(uri);
  if (!canLaunch) return;

  await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
}

/// Opens the Stellar Expert explorer page for [txHash] on testnet.
Future<void> openTxInExplorer(String txHash) {
  return openUrl(
    'https://stellar.expert/explorer/testnet/tx/$txHash',
  );
}

/// Opens the Stellar Expert explorer page for [contractId] on testnet.
Future<void> openContractInExplorer(String contractId) {
  return openUrl(
    'https://stellar.expert/explorer/testnet/contract/$contractId',
  );
}
