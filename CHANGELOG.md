# Changelog

## 0.3.1 — 2026-10-19

### Fixed
- Long answers no longer get cut to a few words. An answer too long for a pill gets a full-width button of its own, its words on up to two lines; short answers stay pills in a row beneath. A long question shows on two lines.

## 0.3.0 — 2026-10-19

### Added
- **Answer from the chef.** A ✋ order for a question with choices shows them as buttons; click one and the session gets your answer without you switching tabs. Whichever comes first wins: the chef's button or the card in the tab.
- **Snooze.** ⏰ on an order puts it away for 10 minutes; it comes back with a hop and a bell. The menu bar shows 💤 and a count while orders sleep; right-click → Snooze all.
- The README now shows the chef.

### Fixed
- "Kitchen's quiet" and "All caught up" no longer cut their text off.

## 0.2.0 — 2026-10-19

### Added
- **Kitchen view.** Click the menu bar chef with no orders waiting and it shows every Claude session: busy ones as rows with a colored status pill (needs you, cooking, ready) and what each is doing; resting ones folded into one line of chips, one per project with a count.
- **Empty states.** "Kitchen's quiet" with a dozing chef when no session runs; "All caught up" when every session rests.
- `open OrderUp.app --args --kitchen` starts with the chef called out (handy for screenshots and debugging).

### Fixed
- A session that started idle reported its time since 1970 ("idle 29873630m").
- Long project names no longer push a session's state off the edge; they end in "…".

## 0.1.0 — 2026-10-19

First release.

- The chef pops up when a Claude Code turn finishes, or a session needs you, in a tab you are not looking at; click an order to jump to that tab (Terminal.app, iTerm2) or app (Ghostty, Warp, VS Code, Cursor, the Claude desktop app).
- Burnt dish when a turn fails; a bill on each order (time, cost, files, commands).
- Menu bar chef: click to call the chef out, right-click for the menu; optional always-on with start at login.
- `/order-up setup` interview, `/order-up config`, `/order-up set`, and the same settings in `/config`.
