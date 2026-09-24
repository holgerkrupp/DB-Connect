# Accessibility

Accessibility is required for every feature and supported platform. Prefer
standard controls because they carry semantics, input behavior, and system
settings correctly; verify rather than assume.

## Semantics and navigation

- Give controls and meaningful content accurate labels, values, traits, hints,
  actions, headings, and grouping. Do not encode the control type redundantly in
  its label.
- Keep VoiceOver order logical and focus stable after navigation, insertion,
  deletion, validation, and asynchronous updates.
- Make custom controls expose complete semantics and adjustable/custom actions.
- Announce important state changes without producing repetitive noise.
- Never convey status through color, shape, sound, location, or motion alone.

## Layout and perception

- Support Dynamic Type and accessibility sizes without clipping, overlap, or
  loss of actions. Reflow instead of shrinking essential text.
- Meet contrast needs and respect Increase Contrast, Reduce Transparency,
  Differentiate Without Color, Button Shapes, and appearance settings.
- Respect Reduce Motion and avoid flashing, disorienting parallax, and
  unnecessary continuous animation.
- Provide captions, transcripts, audio descriptions, and accessible media
  controls when the product contains media.
- Use sufficiently large targets and adequate spacing without preventing precise
  keyboard or pointer workflows.

## Input

Support VoiceOver, Switch Control, Voice Control, keyboard navigation, Full
Keyboard Access on relevant platforms, pointer input, and external keyboards.
Avoid time limits and gesture-only actions; provide alternatives for drag/drop,
swipe actions, hover, and multi-touch.

## Verification

Test critical journeys on real supported devices with accessibility settings
enabled. Include empty, loading, error, disabled, selection, modal, and
notification states. Accessibility regressions block completion just like
functional regressions.
