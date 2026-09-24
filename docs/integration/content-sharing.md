# Content Sharing and Transfer

Design important domain objects for native interchange instead of building
separate implementations for sharing, copy/paste, drag/drop, import, and export.

## Preferred tools

- Adopt `Transferable` for meaningful entities and representations.
- Prefer `ShareLink` and system share facilities for ordinary outbound sharing.
- Support copy/cut/paste and drag/drop with the same representations where
  practical.
- Use standard file importers/exporters and document pickers.
- Add a Share extension only when receiving content without opening the full app
  is an important workflow.

## Representation and safety

- Define accurate uniform type identifiers and choose interoperable, documented
  representations.
- Offer a lightweight common format and richer formats only when valuable.
- Preserve filenames and metadata intentionally; strip private metadata that is
  not required.
- Treat incoming content as untrusted. Validate type, size, structure, file
  access, and destination before import.
- Perform large transfers asynchronously with progress, cancellation, cleanup,
  and useful errors.
- Do not share private data by default or leave sensitive temporary files behind.
- Ensure the same operation has a keyboard/menu/button alternative when drag and
  drop is supported.

Test round trips, other apps, partial failures, security-scoped URLs, duplicate
imports, unsupported formats, multiple items, and multi-selection.
