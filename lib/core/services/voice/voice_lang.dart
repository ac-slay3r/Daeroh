// Idioma de voz efectivo (spec 031): único punto de verdad que decide en qué
// idioma trabajan dictado (Whisper/reconocedor del sistema), lectura en voz
// alta y defaults de voz. Deriva SIEMPRE del ajuste de idioma de la app
// (`app_locale`, ver AppLocales en main.dart) — no existe un selector de
// idioma de voz separado ni se persiste nada nuevo.
//
// Replica exactamente la resolución de la UI: 'es'/'en' explícitos se
// respetan; 'system' (el default) mira el idioma del dispositivo y cae a
// inglés para cualquier idioma no soportado (mismo fallback que MaterialApp).
// Contrato completo en
// docs/UPSTREAM_CONTRACT.md.
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

/// Clave del ajuste de idioma de la app. Duplicada de `AppLocales.prefKey`
/// (main.dart) a propósito: main.dart importa medio árbol de la app y este
/// módulo debe seguir siendo importable desde servicios puros y tests ligeros.
/// Hay un test que ancla que ambas no diverjan.
const String kAppLocalePrefKey = 'app_locale';

/// Idioma de voz efectivo: `'es'` o `'en'` (exactamente los idiomas de la UI).
///
/// - `app_locale == 'es' | 'en'` → tal cual, el dispositivo es irrelevante.
/// - `'system'`, clave ausente o valor desconocido → según el idioma del
///   dispositivo: español → `'es'`; cualquier otro (en, fr, de…) → `'en'`.
///
/// [deviceLocale] existe solo para tests; en producción se usa el locale real
/// del dispositivo.
String effectiveVoiceLang(SharedPreferences prefs, {Locale? deviceLocale}) {
  final pref = prefs.getString(kAppLocalePrefKey);
  if (pref == 'es' || pref == 'en') return pref!;
  final device = deviceLocale ?? PlatformDispatcher.instance.locale;
  return device.languageCode.toLowerCase() == 'es' ? 'es' : 'en';
}
