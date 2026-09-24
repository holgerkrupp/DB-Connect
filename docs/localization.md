# Localization and Internationalization

Build localization-ready UI even when the first release has only one language.

## Text

- Use String Catalogs for user-facing text, including intents, widgets,
  notifications, shortcuts, accessibility strings, privacy explanations, and
  errors.
- Use stable, meaningful localization keys and developer context.
- Do not concatenate translated fragments or assume English word order.
- Use pluralization, inflection, interpolation, and attributed formatting that
  preserve translator control.
- Keep logs and developer diagnostics distinct from user-facing errors.

## Locale-aware data

Use Foundation formatting APIs for dates, times, durations, measurements,
numbers, percentages, currencies, person names, lists, and relative values.
Respect calendars, time zones, units, 12/24-hour preferences, first weekday,
decimal separators, and collation. Store canonical data, not formatted strings.

## Layout and behavior

- Allow text expansion and multiline content; avoid fixed-width assumptions.
- Support right-to-left layout and use leading/trailing semantics.
- Do not mirror directional media or controls when their meaning is absolute.
- Keep sorting and search locale-aware where users expect it.
- Localize images only when necessary and keep text out of raster assets.

## Verification

Use pseudolocalization, long strings, right-to-left mode, non-Gregorian
calendars, diverse numerals, and representative supported languages. Check
screenshots, VoiceOver speech, widgets, notifications, intents, menus, and
platform-specific compact layouts.
