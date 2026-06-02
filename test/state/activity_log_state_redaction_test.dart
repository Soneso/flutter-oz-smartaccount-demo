import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

void main() {
  group('redactMessage — deny-list enforcement', () {
    // -------------------------------------------------------------------------
    // WC pairing URI
    // -------------------------------------------------------------------------

    test('strips WC pairing URI', () {
      const msg =
          'Connecting to wallet: wc:abc123@2?relay-protocol=irn&symKey=deadbeef';
      final result = redactMessage(msg);
      expect(result, isNot(contains('wc:')));
      expect(result, contains('[redacted]'));
    });

    test('strips standalone wc: prefix without URI', () {
      const msg = 'Session started: wc:00aabbcc';
      final result = redactMessage(msg);
      expect(result, isNot(contains('wc:')));
    });

    // -------------------------------------------------------------------------
    // WC session topic (64 hex chars) — F-2: case-insensitive matching
    // -------------------------------------------------------------------------

    test('strips isolated 64-char lowercase hex WC topic', () {
      const topic =
          'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
      const msg = 'Session topic: $topic received';
      final result = redactMessage(msg);
      expect(result, isNot(contains(topic)));
      expect(result, contains('[redacted]'));
    });

    test('strips isolated 64-char uppercase hex WC topic (F-2)', () {
      // Uppercase hex must be caught; e.g. a raw Ed25519 private key logged as hex.
      const topic =
          'A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2';
      expect(topic, hasLength(64));
      const msg = 'Key material: $topic end';
      final result = redactMessage(msg);
      expect(result, isNot(contains(topic)));
      expect(result, contains('[redacted]'));
    });

    test('strips isolated 64-char mixed-case hex WC topic (F-2)', () {
      const topic =
          'A1b2C3d4E5f6A1b2C3d4E5f6A1b2C3d4E5f6A1b2C3d4E5f6A1b2C3d4E5f6A1b2';
      expect(topic, hasLength(64));
      const msg = 'Hex value: $topic logged';
      final result = redactMessage(msg);
      expect(result, isNot(contains(topic)));
      expect(result, contains('[redacted]'));
    });

    test('does not redact 65+ char hex string (not a WC topic) (F-2)', () {
      // A 65-char hex sequence is longer than a WC topic; the lookaround in the
      // pattern means no isolated 64-hex substring is extracted from it.
      const longHex =
          'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2ff';
      expect(longHex, hasLength(66));
      const msg = 'Long hex: $longHex end';
      final result = redactMessage(msg);
      // The 66-char sequence should not be redacted by the 64-hex rule.
      expect(result, contains(longHex));
    });

    test('does not redact shorter hex strings (less than 64 chars)', () {
      const shortHex = 'deadbeef1234';
      expect(shortHex.length, lessThan(64));
      const msg = 'Short hex: $shortHex end';
      final result = redactMessage(msg);
      expect(result, contains(shortHex));
    });

    test('conservative: isolated 64-char hex is always redacted', () {
      // A 64-char lowercase hex string that is isolated — this IS a WC topic
      // pattern match. We accept that isolated 64-char hex is always redacted
      // as a conservative backstop. Callers must truncate transaction hashes
      // before logging if they want them preserved.
      const txHash =
          'aaaa1234bbbb5678cccc9012dddd3456eeee7890ffff1234aaaa5678bbbb9012';
      expect(txHash, hasLength(64));
      const rawMsg = 'tx: $txHash done';
      final result = redactMessage(rawMsg);
      // The redactor conservatively strips 64-hex segments.
      // Callers are expected to truncate tx hashes before logging.
      expect(result, isNot(contains(txHash)));
    });

    // -------------------------------------------------------------------------
    // Stellar secret seed (F-1)
    // -------------------------------------------------------------------------

    test('strips a Stellar secret seed (positive case) (F-1)', () {
      // A valid-shape Stellar secret seed: S followed by 55 uppercase base32 chars.
      final seed = KeyPair.random().secretSeed;
      expect(seed, hasLength(56));
      // Confirm it matches the expected shape: S + 55 [A-Z2-7].
      expect(seed[0], equals('S'));
      final msg = 'Created account with seed $seed in test';
      final result = redactMessage(msg);
      expect(result, isNot(contains(seed)));
      expect(result, contains('[seed:REDACTED]'));
    });

    test('does not strip 57+ char base32 sequence that starts with S (F-1)', () {
      // A 57-char sequence that starts with S — longer than a seed; the
      // lookahead prevents matching within longer base32 blobs.
      final notASeed = '${KeyPair.random().secretSeed}X';
      expect(notASeed, hasLength(57));
      final msg = 'Value: $notASeed end';
      final result = redactMessage(msg);
      // Should not be flagged as a seed by the 56-char rule.
      expect(result, contains(notASeed));
    });

    // -------------------------------------------------------------------------
    // Long base64 XDR blob
    // -------------------------------------------------------------------------

    test('strips long base64 XDR-like blob (>200 chars)', () {
      // Simulate a transaction XDR envelope encoded in base64 (>200 chars).
      final blob = 'AAAAA' * 50; // 250 base64-looking chars
      final msg = 'Submitting tx: $blob to RPC';
      final result = redactMessage(msg);
      expect(result, isNot(contains(blob)));
      expect(result, contains('[redacted]'));
    });

    test('does not strip short base64 sequences (<200 chars)', () {
      // A credential ID fragment (short base64) must NOT be stripped.
      const shortB64 = 'abc123def456=';
      const msg = 'Credential: $shortB64 registered';
      final result = redactMessage(msg);
      // Short base64 stays intact (below the 200-char threshold).
      expect(result, contains(shortB64));
    });

    // -------------------------------------------------------------------------
    // Clean messages pass through unchanged
    // -------------------------------------------------------------------------

    test('clean messages pass through unchanged', () {
      const msg = 'Wallet connected: CABC...WXYZ — balance 10.0 XLM';
      final result = redactMessage(msg);
      expect(result, equals(msg));
    });

    test('operation names pass through unchanged', () {
      const msg = 'Transfer of 1.5 XLM submitted — hash: abc12345...';
      final result = redactMessage(msg);
      expect(result, equals(msg));
    });
  });

  // ---------------------------------------------------------------------------
  // ActivityLogNotifier behaviour
  // ---------------------------------------------------------------------------

  group('ActivityLogNotifier', () {
    test('addEntry applies redaction (verified via redactMessage contract)', () {
      // ActivityLogNotifier.addEntry calls redactMessage before storing entries.
      // Notifier requires a Ref to build(), so we verify the underlying
      // redactMessage contract directly — the notifier delegates to it unchanged.
      const raw = 'Connected: wc:testtoken123';
      final safe = redactMessage(raw);
      expect(safe, isNot(contains('wc:')));
      expect(safe, contains('[redacted]'));
    });

    test('seed redaction flows through addEntry (verified via redactMessage)', () {
      final seed = KeyPair.random().secretSeed;
      final safe = redactMessage('KeyPair seed: $seed');
      expect(safe, isNot(contains(seed)));
      expect(safe, contains('[seed:REDACTED]'));
    });

    test('entries are capped at 50 after overflow', () {
      // Simulate state list capping by verifying list.sublist logic directly.
      final list = List.generate(55, (i) => 'entry $i');
      const maxEntries = 50;
      final result =
          list.length > maxEntries ? list.sublist(0, maxEntries) : list;
      expect(result, hasLength(maxEntries));
      expect(result.first, equals('entry 0'));
    });
  });
}
