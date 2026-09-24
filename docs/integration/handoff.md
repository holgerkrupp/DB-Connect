# Handoff

Evaluate Handoff when a meaningful activity can continue on another supported
Apple device. Handoff is not a substitute for data sync, and the existence of
this file does not authorize another platform target.

## Activity design

- Represent a focused user activity, such as editing one trip or viewing one
  episode—not the app in general.
- Use stable identifiers and the same typed route model as other entry points.
- Provide a clear title and minimal metadata. Never put secrets or unnecessary
  private data in an activity or URL.
- Mark activities current only while relevant, invalidate them promptly, and
  avoid advertising background noise.
- Decide whether continuation needs synced data, an authenticated account, or a
  web fallback.

## Continuation

Validate the incoming activity as untrusted input. Restore the closest useful
destination after launch, authentication, loading, or migration. Handle missing,
deleted, unsynced, unauthorized, or offline content gracefully.

Test both device directions, cold and warm launch, different accounts, delayed
sync, version skew, revoked access, and more than one open scene/window.
