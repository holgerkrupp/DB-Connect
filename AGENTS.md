# Project Instructions

Build a native, dependable Apple-platform application that participates in the
system rather than behaving as an isolated screen.

## Source of truth for platform support

`README.md` and the Xcode targets are the source of truth for supported
platforms. The presence of a platform guidance file does **not** mean that the
project supports that platform.

Before platform-specific work:

1. Confirm the supported targets in `README.md` and the Xcode project.
2. Read the corresponding file under `docs/platforms/`.
3. Do not add or broaden a target without an explicit project decision.
4. Do not add a widget, extension, entitlement, capability, App Group, URL
   scheme, background mode, or permission merely because guidance exists.

## Engineering baseline

- Prefer Swift 6, strict concurrency, SwiftUI, and native Apple frameworks.
- Use structured concurrency and keep UI state on the main actor where needed.
- Make ownership, cancellation, isolation, and error paths explicit.
- Keep domain and data logic independent of presentation when practical.
- Share business logic; shared UI is not a goal in itself.
- AppKit is appropriate when it materially improves a Mac experience.
- Avoid third-party dependencies unless their value and maintenance cost are
  documented.
- Preserve user data and provide migrations for persisted schema changes.
- Add focused unit tests for domain logic and UI tests for critical journeys.

## Required quality work

Accessibility, localization readiness, and privacy are requirements for every
feature, not optional finishing passes. Read:

- `docs/accessibility.md`
- `docs/localization.md`
- `docs/privacy.md`

Restore useful user state where the platform and product make it reasonable:
navigation, selection, open documents, filters, window placement, and in-progress
work. Never persist secrets or sensitive transient state without a clear need.

## Apple platform integration review

For each major feature or new domain entity, evaluate all of the following. An
integration must provide genuine user value; if it does not, document the
decision briefly instead of adding a token implementation.

- Spotlight and system search
- App Intents, Shortcuts, Siri, and system suggestions
- Widgets, complications, and controls on supported platforms
- Stable deep links and Universal Links when a web domain exists
- `Transferable`, `ShareLink`, copy/paste, drag and drop, import, and export
- Handoff for useful cross-device continuity
- Notifications, actions, and Live Activities for time-sensitive or ongoing work
- Files, document types, Quick Look, and Finder/Files integration
- State restoration
- Accessibility, localization, and privacy implications

Read the relevant file under `docs/integration/` before implementing one of
these capabilities.

## Integration architecture

Main UI, Spotlight, widgets, App Intents, notifications, Handoff, and file
opening should converge on:

- one domain model and data layer;
- stable, durable entity identifiers;
- centralized, testable routes;
- one authorization and privacy policy;
- intentional shared storage, such as an App Group only when an extension needs
  it.

Do not create unrelated copies of app state for individual integrations. Treat
external input as untrusted: validate routes, identifiers, imported data, and
intent parameters before acting.

## Native behavior

Use standard controls, commands, menus, sheets, panels, sharing facilities,
formatters, and accessibility APIs before custom replacements. Respect platform
conventions even when that requires platform-specific presentation code.

Editing features must evaluate undo/redo. Destructive actions must be clear,
recoverable where practical, and safe for multi-selection. Important actions
must remain discoverable without relying only on gestures or context menus.

## Definition of done

- The project builds with warnings reviewed, not ignored.
- Tests cover changed behavior and important failure paths.
- Concurrency diagnostics and data-race risks have been considered.
- The feature works with accessibility technologies and keyboard input where
  applicable.
- User-facing text is localizable and locale-aware.
- Permissions are contextual, minimal, and explained.
- Deep links and system entry points open a valid, useful destination.
- State stays synchronized across every enabled integration.
- Deleted or inaccessible content is removed from indexes, widgets, and caches.
- Only explicitly supported platforms and capabilities were added.
