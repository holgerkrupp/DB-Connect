# Spotlight

Evaluate Spotlight for every app, but implement it only when exposing meaningful
user content is useful and appropriate for the supported platforms.

## Good candidates

Documents, projects, episodes, bookmarks, locations, trips, collections,
recipes, tasks, and other durable user-recognizable entities can be good
candidates. Settings, implementation details, secrets, health information, and
ephemeral state usually are not.

## Requirements

- Prefer Core Spotlight and App Intents/App Entities as appropriate.
- Use stable unique identifiers and domains tied to the real data model.
- Provide useful titles, descriptions, keywords, thumbnails, dates, and content
  types without leaking private data.
- Keep the index synchronized after create, update, delete, sign-out, account
  switch, permission changes, and migration.
- Make indexing repeatable and recoverable after an interrupted rebuild.
- Deep-link results through the centralized route parser to a valid destination.
- Revalidate access when a result opens; an old index entry grants no authority.
- Delete stale or no-longer-authorized entries promptly.
- Measure scale and update in batches rather than blocking UI work.

## Decision record

If the app has no valuable, safe searchable content, state that briefly in the
project README or architecture notes. Do not publish meaningless results merely
to satisfy this review.
