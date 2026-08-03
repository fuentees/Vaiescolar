import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferencia de tema (sistema/claro/escuro) persistida via
/// SharedPreferences. `ValueNotifier` simples -- mesmo padrao ja usado no
/// app (`TrackingService.lastSentAt`, `LiveLocation.connected`), sem
/// introduzir uma lib de state management nova so pra isso.
class ThemeController {
  static final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);
  static const _prefsKey = 'theme_mode';

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    mode.value = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  static Future<void> setMode(ThemeMode newMode) async {
    mode.value = newMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey,
        switch (newMode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        });
  }
}
