# Project Instructions

## Engineering Philosophy — Pragmatic Solo Developer

This project is maintained by a solo developer, often as a free, open-source application with a small user base. Optimize for useful, reliable software with minimal complexity and maintenance effort. Do not apply big-company processes or engineering standards unless explicitly requested.

This section is the default decision rule for scope, testing, and implementation effort. Preserve explicit project-specific requirements, especially data safety, privacy, security, platform constraints, and documented user-visible behavior. Interpret generic checklists proportionally to the change rather than expanding every task into a major project.

### 1. Simplicity first

- Prefer the simplest implementation that solves the actual problem for realistic users.
- Follow existing architecture, patterns, and native platform APIs.
- Avoid unnecessary abstractions, protocols, layers, dependencies, configuration, and infrastructure.
- Do not build generic frameworks for one-off functionality or speculate about future use.
- Prefer small, understandable changes over large rewrites; remove obsolete code when safe.
- If a simple approach handles roughly 90–95% of realistic cases, prefer it over a much more complex approach to theoretical completeness, unless the remainder risks user data, security, or essential functionality.

### 2. Requirements and scope

- Implement the requested outcome without inventing additional requirements.
- Distinguish essential behavior from optional enhancements.
- Cover common usage and observed failures; do not chase every hypothetical edge case.
- Do not create follow-up issues or expand GitHub acceptance criteria for speculative improvements.
- Do not block a task for nice-to-have refinements, exhaustive compatibility work, or theoretical future-proofing.
- When requirements are ambiguous but low-risk, choose a reasonable default and proceed.

### 3. Proportional testing

- Testing effort must match the change's complexity and risk.
- Add focused tests for important domain logic, migrations, data integrity, and confirmed regressions where practical.
- Do not require unit tests for every function, view, or trivial code change.
- Do not introduce elaborate mocks, test harnesses, or dependencies solely for coverage.
- A successful build plus targeted checks is enough for many small changes.
- Manual validation may cover device-specific UI, hardware, and platform behavior. Clearly state what remains to be checked, but do not keep implementation issues open solely for unavailable physical-device verification.
- Never claim a build or test passed when it was not run.

### 4. Reliability without overengineering

Prioritize, in order: (1) avoiding user-data loss or corruption, (2) avoiding common crashes and freezes, (3) keeping core functionality working, and (4) recoverable, understandable failures.

- Handle likely and observed errors; avoid defensive machinery for implausible scenarios.
- Prefer graceful degradation and straightforward recovery over elaborate retry systems.
- Use non-blocking feedback for recoverable background errors; do not interrupt users unnecessarily.
- Do not silently discard data or suppress failures requiring user action.
- Security, privacy, authentication, and irreversible operations deserve extra care even in a small app.

### 5. Architecture and performance

- Refactor only what is necessary for the requested change or an evidenced problem.
- Prefer incremental improvements, existing services, and established patterns.
- Do not maintain parallel implementations without a concrete migration reason.
- Optimize reported or measured user-visible slowness; avoid speculative caches, concurrency systems, and benchmarks.
- Accept small inefficiencies when the alternative adds substantial maintenance burden.

### 6. Definition of done

A task is done when the requested behavior is implemented, the relevant build/checks have been attempted where the environment allows, important regressions have been reasonably checked, and no serious new issue is known.

The following are **not automatic release gates**: exhaustive edge-case coverage, complete unit/UI test coverage, formal benchmarks, extensive architecture documentation, future-proof abstractions, old development-schema compatibility, extra settings, or physical-device verification unavailable to the agent.

Respect any explicit, narrower project requirement that applies to the task. Do not confuse optional improvements with blockers.

### 7. Agent behavior and communication

- Favor working software and clear maintenance over theoretical perfection.
- Do the work rather than turning small requests into lengthy plans.
- Ask for clarification only when the decision materially affects functionality, user data, security, or architecture.
- Keep changes focused and summaries concise: what changed, what was verified, and any real remaining risk.
- Recommend further work only when it has clear practical value.
- Never hide limitations, invent verification results, or compromise essential user-data protection.

**Guiding principle: Good enough, reliable, understandable, and shipped is usually better than theoretically perfect but excessively complex.**

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
