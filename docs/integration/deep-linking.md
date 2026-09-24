# Deep Linking

Deep links are shared navigation infrastructure for Spotlight, widgets, App
Intents, notifications, Handoff, shared URLs, file opening, and Universal Links.

## Route design

- Define a centralized, typed route model for important destinations and
  actions.
- Use stable external identifiers, explicit versions when needed, and canonical
  URLs. Do not expose database implementation details.
- Separate navigation from privileged actions; opening a URL should not silently
  perform destructive or sensitive work.
- Prefer Universal Links when the product has a verified web domain. Use a custom
  scheme only where it adds value, and treat it as public input.
- Preserve a useful pending route through launch, authentication, onboarding,
  scene creation, or data loading.
- Decide which scene/window receives a route and avoid accidental duplicate
  navigation.

## Validation and fallback

Parse strictly, reject malformed or oversized input, and re-check permissions
and entity existence. Define humane fallbacks for deleted content, old versions,
unavailable accounts, unsupported platforms, and offline operation.

Round-trip test URL generation and parsing. Test cold/warm launch, every system
entry point, malformed data, unauthorized entities, and migration from older
route versions.
