# Apple Watch Platform Guidance

This file does not declare watchOS support. Add a Watch app or extension only
after an explicit product decision.

## Principle

The Watch experience should deliver a small number of immediate, glanceable,
contextual tasks. It should not be a compressed copy of the phone app.

## Experience

- Optimize for brief sessions, minimal input, clear hierarchy, and large
  targets.
- Put the highest-value action or status first.
- Keep navigation shallow and avoid dense settings or data-entry workflows.
- Use the Digital Crown, haptics, system controls, and always-on behavior
  appropriately.
- Design independent value and graceful offline behavior; do not assume the
  paired phone is currently reachable.

## Integrations

- Evaluate WidgetKit complications and Smart Stack relevance.
- Use App Intents for useful actions and configuration.
- Use notifications sparingly, with clear actions and deep links.
- Share data through an intentional sync model; avoid conflicting copies.
- Consider workout, health, location, motion, and background APIs only when
  central to the product and with the required privacy treatment.

## Review checklist

- The core task can be understood and completed quickly.
- Content remains readable with accessibility text settings.
- VoiceOver labels, order, and actions are useful.
- Empty, offline, delayed-sync, and complication states are designed.
- Energy use, refresh budgets, and background work are conservative.
- The Watch target exists only because the product explicitly supports it.
