# macOS Platform Guidance

This file describes the baseline for a native Mac experience. Its presence does
not imply that this project supports macOS. Apply it only to an explicitly
supported Mac target.

## Principle

A Mac app must behave like a Mac app, not like an enlarged touch interface.
Prefer SwiftUI and native frameworks, and use AppKit whenever it supplies better
desktop behavior. Platform-specific UI is preferable to compromised source-code
sharing.

## Windows and restoration

- Support normal resizing, appropriate minimum sizes, full screen, window
  titles, represented content, and multiple windows when useful.
- Restore meaningful window size, placement, sidebar state, navigation,
  selection, open documents, filters, and in-progress work.
- Closing the last window need not quit the app, but it must never strand the
  user. Clicking the Dock icon, choosing an appropriate File/Window command, or
  activating the app must create or reopen a useful window.
- Provide New, Open, and reopen-recent behavior that matches the product.
- Test launch, relaunch, reopen, Dock activation, and restoration with zero,
  one, and multiple windows.

## Menu bar and commands

Provide conventional App, File, Edit, View, Window, and Help menus. Put
application commands in logical menus rather than exposing them only as view
buttons. Use standard names, validation, disabled states, and shortcuts:

- Command-N — New
- Command-O — Open
- Command-W — Close Window
- Command-S / Shift-Command-S — Save / Save As when applicable
- Command-Z / Shift-Command-Z — Undo / Redo
- Command-X/C/V/A — Cut / Copy / Paste / Select All
- Command-F — Find
- Command-, — Settings

Do not repurpose established shortcuts. Menu items should reflect the current
selection and name undoable work, such as “Undo Delete Item.”

## Keyboard, mouse, and trackpad

All important workflows should be efficient with a keyboard. Support focus
movement, Full Keyboard Access, Return/Enter, Escape, Delete, arrow navigation,
and conventional modifier behavior where appropriate.

Design for a precise pointer: useful hover feedback, secondary click,
double-click, cursor affordances, and trackpad gestures that supplement rather
than hide commands. Avoid touch-only assumptions and gesture-only features.

## Context menus and selection

Provide context menus for rows, files, documents, sidebar items, table rows, and
other objects where users expect them. Keep essential commands available in a
menu, toolbar, or visible UI as well.

Where the model supports batch work, implement standard single selection,
Shift-click ranges, Command-click discontiguous selection, Select All, and
selection-wide actions. Confirm or safely undo destructive batch operations.

## Drag and drop

Use drag and drop for natural operations such as rearranging, moving between
collections, importing Finder files, exporting content, or opening documents.
Support promised files and `Transferable` when useful. Always provide a
discoverable non-drag alternative.

## Files, Open panels, and Finder

- Use `NSOpenPanel`, `NSSavePanel`, SwiftUI file import/export APIs, or the
  standard document architecture; never build a substitute file browser for a
  normal Open workflow.
- Support File > Open, Command-O, Open With, file associations, recent items,
  dragging files to the app/Dock icon, and reopening documents when relevant.
- Use security-scoped access correctly in sandboxed apps and persist bookmarks
  only when continued access is justified.
- Evaluate Quick Look, Share, Services, Reveal in Finder, document icons, and
  correct uniform type identifiers.

## Toolbars, sidebars, tables, and inspectors

Use native toolbars for frequent commands; do not substitute an oversized
mobile navigation bar. Consider customization for complex products.

Use native sidebars, split views, inspectors, and their standard collapse,
keyboard, selection, context-menu, and drag behavior. For data-heavy UI,
consider SwiftUI `Table`; use `NSTableView`, `NSOutlineView`, or other AppKit
views when advanced desktop behavior warrants it. Tables should evaluate
sorting, resizable columns, alignment, multi-selection, copy/paste, keyboard
navigation, and double-click actions.

## Settings, editing, and system integration

- Use the standard Settings scene/window and Command-,.
- Integrate editing with `UndoManager`, copy/paste, Find, text services, and
  spelling where relevant.
- Evaluate Spotlight, App Intents, widgets, notifications, Handoff, Universal
  Links, Quick Look, Dock menus, menu bar extras, and iCloud/CloudKit based on
  product value—not as check-box features.
- Respect appearance, accent color, increased contrast, reduced motion,
  reduced transparency, VoiceOver, and keyboard accessibility.

## Review checklist

- Menus and shortcuts are conventional and correctly enabled.
- Keyboard, pointer, secondary-click, context-menu, and hover behavior work.
- Multi-selection and batch actions behave safely where useful.
- Drag and drop works where useful and is not the only path.
- Windows resize and restore correctly.
- Closing the last window does not strand the user.
- Dock activation or a command creates/reopens a useful window.
- Open and Save use standard system panels.
- Finder and document integration work where relevant.
- Undo/redo, copy/paste, Settings, toolbars, sidebars, and tables feel native.
- Accessibility works with VoiceOver and Full Keyboard Access.
- The app does not feel like a stretched iPhone or iPad interface.
