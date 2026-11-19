# Changelog

All notable changes to Pastly are listed here.

## 0.7.1 — 2026-11-19
- Screenshots get the macOS name: a screenshot taken with ⇧⌘3, ⇧⌘4 or ⇧⌘5 now shows as "Screenshot 2026-11-19 at 2.42.59 PM" (in your Mac's 12- or 24-hour format) instead of its pixel size. Other images still show their size, and a name you gave a clip is never replaced.
- ⌘V of an image clip in Finder (or any folder) now creates the image file, named like the clip — as dragging already did. Other apps still receive the image itself; the file is only written when an app asks for it.

## 0.7.0 — 2026-11-18
- New tagline: "A beautiful, native clipboard manager for macOS." (Settings → About and the website).
- Backups use the `.pastly` file extension. Automatic backups only remove Pastly's own `.pastly` files when the keep limit is reached.
- Welcome message: corrected the shortcut hint — ⇧↩ or ⌥↩ pastes in the other format (Formatted ↔ Plain).
- Paste one by one: without Accessibility permission, the first clip is now copied to the clipboard before the warning appears, so ⌘V still pastes it.
- Website: tighter, more consistent spacing; the Download section no longer scrolls sideways on phones; the first-launch FAQ also mentions the Terminal alternative.
- Website: the Download section shows the latest GitHub release automatically — version, notes, size and SHA-256 checksum. A DMG is offered only after its published checksum matches the file; pre-releases are listed separately.
- Faster and smoother with large histories: the clip list, tab counts and Smart Lists are computed once per change instead of on every redraw; thumbnails and preview images load off the main thread; image caches are bounded by memory.
- Copies appear in the history sooner, and rapid copies are captured more reliably (the clipboard is checked every 0.15 s, and every 0.05 s right after a copy).
- File clips no longer read the disk on the main thread while scrolling.
- The search field shows its insertion point.
- Open-source project files: a complete feature guide (FEATURES.md), code of conduct, security policy, issue and pull request templates, and a rewritten README and contributing guide.

## 0.6.0 — 2026-11-17
- Drag & drop: drop clips on a list tab to add them (or move them from another list), on Pinned to pin; drag within a list to reorder; drag several selected clips at once; dragging into other apps still delivers text, images, links and files.
- Smart Lists: new rules for link domain, text pattern (regex) and first-copied date, alongside kind, app, text, age and pinned with all/any matching.
- Exclusions (Settings → Privacy): switch individual app and pattern rules on/off, keyword rules (optional match case), choose which kinds of content to save (text, links, colors, images, files, code), and a "Test your rules" box.
- Preview & edit: formatted (RTF/HTML) preview with a Plain switch, Save as New (keeps the original), Save & Copy, Copy as Plain Text.
- Colors: HEX codes inside text (#FFF, #FFFFFF, #FFFFFFFF) are recognized — swatches on the row and copyable chips in the preview; color clips can copy each format.
- Paste mode: one setting (Settings → General → Default paste format, also the Formatted/Plain menu next to Paste) now drives every paste — Paste button, ⌘V, ↩, double-click, ⌘1–9 and drag & drop — immediately, without reselecting. Clipboard history is never converted.
- Preview: the Paste button is now `[ Paste ][ Formatted ▾ ]` — choose Formatted Paste (keeps bold, italics, fonts, colors, links) or Plain Paste; it starts from Settings → General → Default paste format and also switches how rich text is shown. Fixed the Paste button being squeezed into a tall blue bar on rich-text clips, and the preview not reappearing after pasting from it.
- Drag & drop: dragging a clip now always drags exactly the clip under the pointer (pressing the lower part of a row used to drag the row below).
- Selection & ⌘V: a single click (or ↑/↓) puts the selected clip on the clipboard, so ⌘V pastes it — in Pastly or in the app you switch to. Reopening Pastly selects the clip ⌘V will paste (until you copy something new), otherwise the latest copy.
- History order: pasting or copying a clip from Pastly (click + ⌘V, ↩, double-click, ⌘1–9) no longer moves it to the top or changes its time — only a genuinely new copy does. Selected clips show a light blue background (#EAF2FF) with a blue border (#3B82F6).
- Click Behavior (Settings → General → Clipboard History): choose "Single Click to Preview" (default — the preview has a Paste button) or "Single Click to Select" (⌘V / ↩ paste the selection). Applies immediately and is remembered. Space still opens the preview and double-click still pastes in both modes.
- Keyboard: ← → switch tabs when the search is empty; Home/End and Page Up/Down move the selection.

## 0.5.0
- Settings: seven sections — General, Appearance, Shortcuts, Lists, Privacy, Backup, About — in a native toolbar window.
- Appearance: accent color, rounded corners, item spacing, list animations, preview side and width, code highlighting switch.
- Paste: choose plain text as the default format (hold ⇧/⌥ for the other); quick paste can use ⌘, ⌥ or ⌃.
- Shortcuts: blocks global shortcuts that clash with macOS (⌘C, ⌘Space, screenshots…); Space and Delete can be turned off.
- Lists: reorder lists and Smart Lists, recolor lists, move items between lists, manage pinned items.
- Privacy: optionally skip card numbers, one-time codes and API keys/tokens; clear history on quit; history files are private to your account.
- Backup: Back Up Now, automatic daily/weekly backups with a keep limit, restore by merging or replacing.
- About: version, update check (GitHub), license, changelog, credits.
- Fixed: Space and a second click on the selected item now close the preview.

## 0.4.0
- Compact menu bar window with tabs, hover preview, code detection, Smart Lists, paste queue (⌘↩), multiple global shortcuts.

## 0.3.0
- Multi-selection (⌘A, ⇧/⌘-click), delete with undo, paste the selected items with ⌘V.
- Native macOS alert sound and menu bar animation on copy.

## 0.2.0
- Reliable auto-paste (waits for the target app, layout-aware ⌘V), lists, preview, edit, OCR, drag & drop.

## 0.1.0
- First release: clipboard history, search, pins, global shortcut, local SQLite storage, privacy rules, JSON backup.
