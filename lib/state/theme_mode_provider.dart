/// Theme-mode preference with shared-preferences persistence.
///
/// Exposes a Riverpod notifier that reads / writes the user's chosen
/// [ThemeMode]. The initial value is restored from local storage on
/// notifier creation; subsequent toggles write back asynchronously.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage key for the persisted theme mode.
const String _kThemeModeKey = 'theme_mode';

/// Riverpod provider for the user's selected [ThemeMode].
///
/// Defaults to [ThemeMode.system] until the persisted value (if any) is
/// loaded asynchronously in the notifier's build method.
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// Notifier owning the user's chosen [ThemeMode].
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    // Schedule the restore one frame later. Calling _restore() directly here
    // would let SharedPreferences resolve inside the current frame on
    // platforms (e.g. Android) where the platform-channel reply lands in
    // the same microtask cycle as the watching widget's first build —
    // Riverpod rejects state mutations while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
    return ThemeMode.system;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kThemeModeKey);
    if (stored == null) return;
    final restored = _decode(stored);
    if (restored != null && restored != state) {
      state = restored;
    }
  }

  /// Cycles light to dark to system to light when invoked from a toggle button.
  ///
  /// Persists the new value via [SharedPreferences] so the choice survives
  /// app restarts.
  Future<void> cycle() async {
    final next = switch (state) {
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
      ThemeMode.system => ThemeMode.light,
    };
    if (next == state) return;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeModeKey, _encode(next));
  }
}

String _encode(ThemeMode mode) => switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };

ThemeMode? _decode(String value) => switch (value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
