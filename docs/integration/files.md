# Files, Documents, Finder, and Quick Look

Evaluate file integration when user content is naturally portable, document
based, previewable, importable, or exportable.

## File model

- Choose intentionally between an app-owned data store, file-based documents,
  packages, and cloud-backed documents. Do not expose implementation files as a
  user document format accidentally.
- Define correct uniform type identifiers, filename extensions, roles, icons,
  and versioning.
- Prefer standard document architecture, file importers/exporters, open/save
  panels, and document pickers over custom browsers.
- Use coordinated access, atomic writes, autosave, conflict handling, and
  migrations appropriate to the storage model.
- Respect sandboxing, security-scoped URLs, bookmarks, iCloud availability, and
  user revocation. Request only the access actually needed.

## System integration

Evaluate Open With, recent documents, drag/drop, Files/Finder, Quick Look,
sharing, revealing in Finder, Spotlight metadata, thumbnails, and restoration of
open documents. Keep file opening on the centralized route/navigation path.

Treat every imported or opened file as untrusted. Validate type, size, content,
archive paths, and resource use before parsing. Never overwrite user content
silently. Provide progress, cancellation, clear conflict choices, and recoverable
errors for long operations.

Test external edits, renames, moves, deletion, duplicate names, cloud eviction,
offline access, version skew, conflicts, read-only files, and interrupted writes.
