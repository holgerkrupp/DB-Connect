# Privacy and Data Protection

Collect, access, retain, and share the minimum data required to deliver a clear
user benefit. Privacy decisions are architecture decisions, not release chores.

## Data inventory

For each feature, document what data exists, why it is needed, where it is
stored, how long it remains, who can access it, whether it leaves the device,
and how the user can delete or export it. Classify sensitive data and define the
threats that matter to it.

## Permissions and capabilities

- Request permissions in context after explaining the value, not automatically
  at first launch.
- Use purpose strings that describe the real feature in plain language.
- Handle denial, restriction, limited access, revocation, and Settings changes.
- Request the narrowest entitlement, capability, file scope, background mode,
  location precision, photo selection, and data access that works.
- Never add capabilities, App Groups, associated domains, notification modes, or
  extensions preemptively.

## Storage and transmission

- Prefer on-device processing and storage when practical.
- Protect secrets in Keychain; do not commit credentials or put them in logs,
  defaults, URLs, notifications, Handoff activities, Spotlight, widgets, or
  crash metadata.
- Use platform transport security and validate server trust and authorization.
- Define deletion, sign-out, account-switching, backup, sync, and migration
  behavior across local data, cloud data, caches, indexes, widgets, and files.
- Redact sensitive UI in screenshots, app switcher snapshots, Lock Screen
  surfaces, and shared previews where appropriate.

## Transparency and compliance

Keep privacy manifests, required-reason API declarations, App Store privacy
answers, nutrition labels, and in-app explanations consistent with actual code
and dependencies. Review third-party SDK collection before adoption.

## Verification

Test first-use prompts, denial, limited access, revocation, sign-out, deletion,
offline behavior, multiple accounts, device lock, backups, logs, exports, and
every system surface that may expose content. Security-sensitive changes require
focused review and tests.
