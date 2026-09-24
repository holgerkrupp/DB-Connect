# iPhone and iPad Platform Guidance

This file does not declare iPhone or iPad support. Apply it only to targets the
project explicitly supports, and decide independently whether the app supports
one or both device families.

## Adaptive structure

- Design for size classes, multitasking, Stage Manager, rotation, external
  displays, and accessibility text sizes; do not infer device from screen size.
- Preserve navigation, selection, drafts, filters, scroll position, and other
  useful state across scene and process changes.
- Use appropriate navigation stacks, split views, sheets, popovers, inspectors,
  tabs, toolbars, and search placement.
- Let iPad take advantage of space and multiwindow workflows instead of merely
  centering a wider iPhone layout.

## Input

- Support touch with comfortable targets and clear feedback.
- On iPad, evaluate keyboard shortcuts, focus navigation, pointer hover,
  context menus, multi-selection, drag and drop, and Apple Pencil when the
  product benefits.
- Never make a critical action available only through a hidden gesture.
- Use standard edit menus, copy/paste, undo/redo, and selection behavior.

## System participation

Evaluate Spotlight, App Intents, widgets, controls, sharing, Handoff,
notifications, Live Activities, Universal Links, Files, document browsing, and
state restoration for each major feature. Use stable deep links so every system
entry point reaches the same navigation model.

## Review checklist

- Layout survives all supported window sizes and accessibility text sizes.
- iPad supports effective keyboard and pointer use where appropriate.
- Multiple scenes restore meaningful independent state.
- Sheets and popovers adapt correctly between compact and regular layouts.
- Safe areas, software/hardware keyboards, rotation, and multitasking work.
- VoiceOver order, labels, actions, and focus are intentional.
- Only the explicitly chosen device families are enabled.
