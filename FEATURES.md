# Pastly Features

This document describes every feature in the current version of Pastly (0.7.1): what it does, how it works and how to use it. It is written for users and contributors, and every behavior described here is taken from the source code. Source files are listed at the end of each section for contributors who want to read further.

Features that are planned but **not built yet** are listed separately in [Not available yet](#not-available-yet).

## Contents

1. [Introduction](#1-introduction)
2. [Clipboard History Management](#2-clipboard-history-management)
3. [Clipboard Content Types](#3-clipboard-content-types)
4. [Preview System](#4-preview-system)
5. [Copy and Paste](#5-copy-and-paste)
6. [Formatted and Plain Paste Modes](#6-formatted-and-plain-paste-modes)
7. [Default Paste Format Setting](#7-default-paste-format-setting)
8. [Keyboard Shortcuts](#8-keyboard-shortcuts)
9. [Click Behavior](#9-click-behavior)
10. [Search and Filtering](#10-search-and-filtering)
11. [Lists and Smart Lists](#11-lists-and-smart-lists)
12. [Pinning](#12-pinning)
13. [Drag and Drop](#13-drag-and-drop)
14. [Image and Media Support](#14-image-and-media-support)
15. [Code, URL and Color Handling](#15-code-url-and-color-handling)
16. [Settings and Preferences](#16-settings-and-preferences)
17. [Clipboard Monitoring](#17-clipboard-monitoring)
18. [Privacy and Local Data Storage](#18-privacy-and-local-data-storage)
19. [User Interface and Navigation](#19-user-interface-and-navigation)
20. [Accessibility and macOS Integration](#20-accessibility-and-macos-integration)
21. [Backups](#21-backups)
22. [Limits](#22-limits)
23. [Not available yet](#not-available-yet)

---

## 1. Introduction

Pastly is a clipboard manager for macOS. It runs in the menu bar, saves everything you copy, and lets you find it and paste it again with one shortcut (**⇧⌘V** by default).

- **Native:** written in Swift with SwiftUI and AppKit, using only Apple's frameworks. No third-party code.
- **Local:** your history is stored only on your Mac. There are no accounts, no sync and no analytics. The only network request Pastly can make is an optional check for new versions on GitHub (see [Privacy](#18-privacy-and-local-data-storage)).
- **Requirements:** an Apple silicon Mac (M1 or newer) with macOS 14 Sonoma or newer.
- **License:** free and open source under the MIT License.

A typical session:

1. Copy things as usual with ⌘C in any app.
2. Press **⇧⌘V**. The Pastly window opens with your history, newest first.
3. Type a few letters to filter, use ↑/↓ to pick a clip, and press **↩**. Pastly pastes it into the app you were using.

---

## 2. Clipboard History Management

### What is saved

Every time the clipboard changes, Pastly saves a **clip**. A clip records:

- the content, in every useful format (for example plain text plus RTF/HTML for rich text, or the original image bytes);
- the app that was in front when you copied (name and icon);
- when it was **first copied** and **last copied**;
- how many times it was copied and how many times you pasted it from Pastly;
- an optional custom title, a pin flag and the lists it belongs to.

### Order and duplicates

- The history is sorted by **last copied**, newest first.
- Copying the same content again does **not** add a duplicate. The existing clip moves to the top, its "last copied" time and source app are updated, and its copy count goes up.
- Duplicates are detected by content, not by exact bytes:
  - **Text:** Unicode-normalized, with Windows/old-Mac line endings treated as normal line breaks. Leading and trailing spaces count as different text unless you turn on *Treat leading/trailing whitespace as the same item* (Settings → General).
  - **Links:** the scheme and host are case-insensitive, and a trailing `/` is ignored (`HTTPS://Example.com/` equals `https://example.com`).
  - **Colors:** `#fff`, `#FFFFFF` and `rgb(255,255,255)` are the same clip.
  - **Images:** compared by their pixels, so the same picture copied as PNG and as TIFF is one clip.
  - **Files:** compared by their paths.
- **Pasting or copying a clip from Pastly does not reorder the history.** It only increases the clip's paste/use count. Only a genuinely new copy moves a clip to the top.

### Limits and clean-up

| Setting | Options | Default |
|---|---|---|
| Keep up to | 100, 250, 500, 1,000, 5,000 items, or Unlimited | 500 |
| Delete items not used for | Never, 1 day, 7 days, 30 days, 90 days | Never |
| Clear history when Pastly quits | on / off | off |

- **Pinned clips and clips in a list are never removed** by the item limit, automatic deletion, *Clear History* or *Clear history when Pastly quits*.
- Limits are applied at launch, every hour, after each new copy and whenever you change them.
- **Clear History…** (menu bar menu or Settings → Privacy) deletes everything except pinned and listed clips, after a confirmation.
- **Delete Everything…** (Settings → Privacy) deletes every clip, including pinned and listed ones. Your lists are kept but emptied.

### Deleting and undo

- Select one or more clips and press **⌫** (or **⌦**, or **⌘⌫**), or use the trash button or the *Delete* context-menu item.
- **⌘Z** restores the last deletion, for up to 5 minutes. A toast confirms both ("Item deleted — ⌘Z to undo", "Item restored").
- *Clear History* and *Delete Everything* cannot be undone.

*Sources:* `Sources/Pastly/Data/ClipStore.swift`, `Sources/Pastly/Core/ContentHasher.swift`, `Sources/Pastly/Data/Models.swift`

---

## 3. Clipboard Content Types

Pastly sorts every clip into one of five kinds. **Code** is shown as its own tab, but it's a text clip that looks like code.

| Kind | What is detected | What is kept |
|---|---|---|
| **Text** | Any text that isn't a single link or a single color | Plain text, plus RTF and/or HTML when the source app provides it (rich text) |
| **Links** | The whole clip is one URL: `http`, `https` or `ftp` with a host, or a `mailto:` address, with no spaces and fewer than 4,000 characters | The URL |
| **Colors** | The whole clip is one color: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb(r, g, b)` or `rgba(r, g, b, a)` | The color as uppercase HEX |
| **Images** | Image data on the clipboard (screenshots, "Copy Image" in browsers and apps) | The original bytes for PNG, JPEG, HEIC, GIF and WebP; other formats (such as TIFF) are converted to PNG |
| **Files** | Files copied in Finder (⌘C) or other apps | References to the files (not copies of them); for image files also the image, for videos and audio a thumbnail |
| **Code** (tab) | Text that scores as code: valid JSON, typical keywords, lines ending in `;` `{` `}`, indentation; prose lowers the score | Same as Text |

**Screenshots** taken with ⇧⌘3, ⇧⌘4 or ⇧⌘5 are recognized by the tag macOS puts in them and get the macOS name, such as *Screenshot 2026-11-19 at 2.42.59 PM*; other images show their size (for example *1600×900*). A name you give a clip yourself is never replaced.

Examples:

- Copying `https://example.com/docs` gives a **link**. Copying `See https://example.com/docs` gives **text** (it contains a link but isn't one).
- Copying `#3B82F6` gives a **color**. Copying `Primary: #3B82F6, accent: #F97316` gives **text** that shows two color swatches.
- Copying a paragraph from a web page keeps its formatting (bold, links, fonts) alongside the plain text.
- When a browser puts both an image and its URL on the clipboard ("Copy Image"), Pastly saves the **image**.

Not captured: empty or whitespace-only text, and clipboard contents with no text, image or file.

*Sources:* `Sources/Pastly/Core/ClipItemParser.swift`, `Sources/Pastly/Core/ContentHasher.swift`, `Sources/Pastly/Data/Models.swift`

---

## 4. Preview System

The preview is a panel beside the clip list that shows a clip in full.

### Opening and closing

- **Open:** click a clip (in *Single Click to Preview* mode), or select it and press **Space**.
- **Close:** press **Space** or **Esc**, or click the same clip again.
- The preview opens **only on purpose**. Hovering over a clip never opens it.
- While the preview is open, it follows the selection: moving with ↑/↓ shows the next clip.

### What it shows

| Kind | Preview content |
|---|---|
| Text | The full text (very long text is shortened to the first 30,000 characters, with a note). Rich text is shown with its formatting in Formatted mode and as plain text in Plain mode |
| Code | Monospaced text with syntax highlighting (if enabled) |
| Link | The URL and an **Open in Browser** button |
| Color | A large swatch, the HEX value, and copyable `rgb()`/`rgba()`, `hsl()` and SwiftUI `Color(red:green:blue:)` values |
| Text with colors | A **Colors in this clip** row; click a chip to copy that color |
| Image | The full image and a **Copy Text from Image (OCR)** button |
| File | A thumbnail or icon and **Reveal in Finder** |
| Video | A player with inline controls and a full-screen button |
| Audio | Cover art, title/artist/album, and a Play/Pause button |

Below the content is a details area: source **App**, **Length** (characters, lines, words), **Dimensions**, **Duration**, **Format**, **First copied**, **Last copied**, **Copies / pastes** and **Size**, where applicable. The footer reads "Space closes the preview · ⌘E to edit".

### Header actions

The preview header has: **[ Paste ][ Formatted ▾ ]** (images and files show only **Paste**), **Pin**, **Copy**, **Edit/Rename** and **Delete**. See [Formatted and Plain Paste Modes](#6-formatted-and-plain-paste-modes) for the Paste control.

### Position and size

In Settings → Appearance → Preview: *Show the preview* "Where there's room" (default), "On the left" or "On the right", and *Preview width* from 300 to 640 points (default 400).

### Editing a clip

Press **⌘E** (or use *Edit…* / *Rename…*) to open the editor:

- **Title (optional, searchable):** give any clip a name you can search for.
- **Text** (text clips only): change the content.
- Buttons: **Cancel**, **Save as New** (keeps the original and adds the edited version at the top), **Save & Copy** (text only) and **Save**.
- **Esc** cancels and **⌘↩** saves. If your edit matches text that is already in the history, Pastly offers to **Merge** or **Keep Editing**.

*Sources:* `Sources/Pastly/UI/ItemViews.swift`, `Sources/Pastly/UI/PanelController.swift`, `Sources/Pastly/Core/MediaSupport.swift`

---

## 5. Copy and Paste

### Ways to paste

| Action | What it pastes |
|---|---|
| **↩** or **⌘V** in the Pastly window | The selected clip(s) |
| **Double-click** a clip | That clip |
| **⌘1 – ⌘9** | The 1st – 9th clip in the current tab |
| **Paste** button in the preview | The previewed clip |
| Context menu → **Paste** | The selected clip(s) |
| Menu bar menu → **Recent Clips** | The chosen recent clip (the 10 newest are listed) |
| **⌘↩** | The selection, one clip per ⌘V (see below) |

All of these use the same paste format: see [Formatted and Plain Paste Modes](#6-formatted-and-plain-paste-modes).

### How a paste reaches your app

1. Pastly puts the clip on the clipboard and hides its window.
2. It switches back to the app you were using and waits until that app is in front and you've released all modifier keys.
3. It presses ⌘V for you (using the right key for your keyboard layout).

If that isn't possible, the clip stays on the clipboard and a short message tells you to press ⌘V yourself, for example when:
- **Accessibility permission** is not granted (an alert explains how to turn it on; see [Accessibility](#20-accessibility-and-macos-integration));
- the target app has **secure input** active (for example a password field);
- Settings → General → *When you press ↩ or double-click* is set to **Copy to the clipboard only**.

### Selecting puts the clip on the clipboard

When you select a clip with a click (in either click mode), ↑/↓ or ⌘/⇧-click, Pastly puts it on the clipboard shortly afterwards, in the current paste format. So **⌘V pastes your selection** both inside Pastly and in the app you switch to.

When you reopen Pastly, it selects the clip that is on the clipboard, if Pastly put it there and nothing newer has been copied since. Otherwise it selects the newest clip.

**Images paste as files where files are expected.** An image clip on the clipboard also offers a real image file, named like the clip. So ⌘V in Finder or any folder creates the file (for example `Screenshot 2026-11-19 at 2.42.59 PM.png`), while apps that take pictures still receive the image itself. The file is only written when an app asks for it.

### Pasting several clips

- Select several **text, link or color** clips and paste: they are joined into **one plain-text paste**, one clip per line.
- A selection that includes **images or files** is pasted as several separate items (apps such as Finder, Mail and Notes accept these).

### Paste one by one (paste queue)

Select several clips and press **⌘↩** (or choose *Paste One by One*):

1. Pastly pastes the first clip and shows a counter on the menu bar icon.
2. Each time you press **⌘V** in any app, the next clip is pasted. A toast shows "Next: 2 of 5 — press ⌘V".
3. After the last clip you see "Pasted all N clips".

Stop it early with **Esc** in any app, the counter pill in the Pastly window, *Stop Paste Queue* in the menu bar menu, or the *Stop the paste queue* global shortcut. The paste queue needs Accessibility permission.

### Copying without pasting

- **⌘C** or **Copy** puts the selected clip(s) on the clipboard **with their formatting** and closes the window. This does not follow the paste format setting.
- **Copy as Plain Text** (context menu, shown for clips with rich formatting) copies plain text only.

### Paste Transformed

Context menu → **Paste Transformed** pastes the text after converting it: **UPPERCASE**, **lowercase**, **Title Case**, **Trim Whitespace**, **Join Into One Line**, **URL-Encode**, **URL-Decode** or **Pretty-Print JSON**. The stored clip is not changed.

*Sources:* `Sources/Pastly/Core/ClipboardCore.swift`, `Sources/Pastly/Core/PasteQueue.swift`, `Sources/Pastly/UI/PanelController.swift`, `Sources/Pastly/App/AppDelegate.swift`

---

## 6. Formatted and Plain Paste Modes

Pastly has two paste formats:

- **Formatted** keeps the clip's original formatting: bold, italics, fonts, colors and links from RTF/HTML.
- **Plain** pastes only the text, which then takes on the style of the place you paste into.

### One setting for every paste

There is **one** paste-format setting, and every paste method reads it at the moment you paste:

| Paste method | Uses the paste format | Other format for one paste |
|---|---|---|
| ↩ | Yes | ⇧↩ or ⌥↩ |
| ⌘V in the Pastly window | Yes | ⌥⌘V |
| Double-click | Yes | — |
| ⌘1 – ⌘9 | Yes | Add ⇧ (or ⌥ together with ⌘) |
| Preview **Paste** button | Yes | — |
| ⌘↩ paste one by one | Yes | ⇧⌘↩ or ⌥⌘↩ |
| Drag and drop | Yes | — |
| Menu bar **Recent Clips** | Yes | — |
| Selecting a clip (clipboard sync) | Yes | — |

### The Formatted ▾ / Plain ▾ menu

In the preview, the Paste control has a menu with **Formatted Paste** and **Plain Paste**:

- It is the **same setting** as Settings → General → *Default paste format*. Changing it in either place changes it everywhere, right away.
- It also switches how rich text is shown in the preview (formatted or plain).
- It appears for text, links and colors. **Images and files** show only a **Paste** button, because they have no text formatting.

### What doesn't change

- **Your history is never converted.** Rich text keeps its RTF/HTML whichever mode you choose, so you can switch back to Formatted at any time.
- If a clip that Pastly put on the clipboard is still there when you change the mode, Pastly rewrites it in the new mode, so the next ⌘V matches your choice. Clips copied in other apps are never touched.
- Links, colors and plain text paste the same in both modes; the difference only shows for rich text.

Example: you copied a heading from a web page. In **Formatted** mode, ↩ pastes it bold and large into Pages; **⇧↩** pastes just the words. Switch the menu to **Plain**, and ↩ now pastes just the words while **⇧↩** pastes the formatted version.

*Sources:* `Sources/Pastly/Core/Preferences.swift` (`pastePlainByDefault`), `Sources/Pastly/UI/PanelController.swift`, `Sources/Pastly/UI/ItemViews.swift`, `Sources/Pastly/UI/PanelView.swift` (drag)

---

## 7. Default Paste Format Setting

Settings → General → **Default paste format**:

| Option | Meaning |
|---|---|
| **Keep original formatting** (default) | Formatted paste |
| **Plain text** | Plain paste |

The hint below it reminds you that holding **⇧** or **⌥** while pasting uses the other format. The preview's **Formatted ▾ / Plain ▾** menu changes this same setting.

---

## 8. Keyboard Shortcuts

### Global shortcuts (work in any app)

Set or change them in Settings → Shortcuts.

| Action | Default |
|---|---|
| Open clipboard history | **⇧⌘V** |
| Paste latest clip as plain text | — (not set) |
| Pause / resume saving | — (not set) |
| Ignore the next copy | — (not set) |
| Stop the paste queue | — (not set) |

When you record a shortcut, Pastly:
- requires at least one modifier key besides ⇧;
- refuses shortcuts that macOS or common apps already use: ⌘C, ⌘V, ⌘X, ⌘Z, ⌘A, ⌘Q, ⌘W, ⌘⇥, ⌘Space, ⌃Space, ⇧⌘3, ⇧⌘4, ⇧⌘5, ⌥⌘Space and ⌥⌘Esc;
- refuses a shortcut that another Pastly action already uses;
- reports "In use by another app" if macOS can't register it.

### In the Pastly window

"Search is empty" means you haven't typed anything in the search field. These shortcuts work regardless of keyboard layout.

| Keys | Action |
|---|---|
| Type any text | Search |
| **↑ / ↓** | Move the selection (**⇧** extends it) |
| **⌘↑ / ⌘↓**, **Home / End** | Jump to the first / last clip (**⇧** extends) |
| **Page Up / Page Down** | Move 10 clips (**⇧** extends) |
| **← / →** | Previous / next tab (when the search is empty) |
| **⇥ / ⇧⇥** | Next / previous tab |
| **↩** or **⌘V** | Paste the selection |
| **⇧↩**, **⌥↩** or **⌥⌘V** | Paste in the other format |
| **⌘↩** | Paste the selection one by one (**⇧** or **⌥** for the other format) |
| **⌘1 – ⌘9** | Paste clip 1–9 of the current tab (modifier configurable) |
| **Space** | Open or close the preview (when the search is empty; can be turned off) |
| **⌘A** | Select all clips in the current tab |
| **⌘C** | Copy the selection without pasting |
| **⌘P** | Pin or unpin the selection |
| **⌘E** | Edit or rename the selected clip |
| **⌫ / ⌦** | Delete the selection (when the search is empty or several clips are selected; can be turned off) |
| **⌘⌫** | Delete the selection (always) |
| **⌘Z** | Undo the last deletion |
| **⌘N** | New list |
| **⌘F** | Focus the search field |
| **⌘,** | Open Settings |
| **Esc** | Close the preview → reduce a multi-selection to one clip → clear the search → close the window |
| **⌘W** | Close the window |

### While editing a clip

| Keys | Action |
|---|---|
| **⌘↩** | Save |
| **Esc** | Cancel |

### While the paste queue is running (any app)

| Keys | Action |
|---|---|
| **⌘V** | Paste the next clip |
| **Esc** | Stop the queue |

### Mouse

| Action | Result |
|---|---|
| Click | Preview or select, depending on [Click Behavior](#9-click-behavior) |
| Double-click | Paste that clip |
| ⌘-click | Add or remove a clip from the selection |
| ⇧-click | Select a range |
| Right-click | Context menu for the clip (or the selection) |
| Drag | Drag the clip, or all selected clips |
| Menu bar icon: click / right-click / ⌥-click | Open the window / open the menu / pause or resume saving |

### Shortcut options (Settings → Shortcuts)

- **Paste items 1–9 with a number key:** on by default. **Hold:** ⌘ Command (default), ⌥ Option or ⌃ Control. With ⌥, add ⇧ for the other format; with ⌘ or ⌃, add ⇧ or ⌥. (⌃1–9 may be used by macOS to switch Spaces.)
- **Delete selected items with ⌫ / ⌦:** on by default.
- **Space opens and closes the preview:** on by default.

*Sources:* `Sources/Pastly/UI/PanelController.swift` (`handleKey`), `Sources/Pastly/Core/Services.swift` (global hotkeys), `Sources/Pastly/Core/SettingsServices.swift` (reserved shortcuts), `Sources/Pastly/UI/SettingsView.swift` (shortcut recorder)

---

## 9. Click Behavior

Settings → General → Clipboard History → **Click Behavior**:

| Mode | Single click | Space | Double-click |
|---|---|---|---|
| **Single Click to Preview** (default) | Selects the clip and opens its preview. Clicking it again closes the preview | Opens / closes the preview | Pastes |
| **Single Click to Select** | Selects the clip (blue highlight); ⌘V or ↩ pastes it | Opens / closes the preview | Pastes |

In both modes, ⌘-click and ⇧-click build a multi-selection, and Esc closes the preview. The change applies immediately and is remembered.

The selected clip is shown with a light blue background and a blue border.

*Sources:* `Sources/Pastly/UI/PanelController.swift` (`clickRow`), `Sources/Pastly/UI/PanelView.swift`

---

## 10. Search and Filtering

- **Just start typing** when the window is open; the search field is focused automatically. **⌘F** focuses it again.
- Search looks in: the clip's **text** (first 20,000 characters), its **custom title**, a color's **HEX value**, **file paths**, the **source app name**, and the **kind name** (typing `links` finds link clips).
- Matching ignores case and accents. Several words must **all** match, in any order: `invoice march` finds "March invoice for Acme".
- Search works **within the current tab**, so you can search inside a list or a Smart List.
- The footer shows the number of matching clips.
- Not searched: text recognized by OCR (unless you saved it as a clip) and formatting-only content.

### Tabs

The tab bar under the search field, in order:

1. **History**: every clip.
2. **Pinned**: pinned clips.
3. **Kind tabs**: Text, Links, Images, Colors, Files, Code. A kind tab is hidden while it has no clips. All kind tabs can be turned off (Settings → Appearance → *Show tabs for kinds*).
4. Your **Smart Lists**.
5. Your **Lists**.

Switch tabs with **⇥ / ⇧⇥**, **← / →** (when the search is empty), a click, or the **Lists and filters** menu in the toolbar. That menu lists every tab with its clip count, plus *New Smart List…* and *New List…*.

*Sources:* `Sources/Pastly/Data/Models.swift` (`searchBlob`), `Sources/Pastly/Data/ClipStore.swift`, `Sources/Pastly/UI/PanelController.swift`, `Sources/Pastly/UI/PanelView.swift`

---

## 11. Lists and Smart Lists

### Lists (filled by hand)

A list is a named collection of clips that you choose.

- **Create:** ⌘N, *New List…* in the toolbar menu or a tab's context menu, or *Add to List ▸ New List…* on a clip.
- **Add clips:** drag them onto the list's tab, or use *Add to List ▸* in the context menu. A clip can be in several lists.
- **Move:** drag clips from one list's tab onto another list's tab, or use *Move to List ▸* inside a list.
- **Reorder:** drag clips within a list, or use the up/down buttons in Settings → Lists.
- **Remove:** *Remove from List* (the clip stays in History).
- **Rename / delete:** right-click the tab, or use Settings → Lists. Deleting a list never deletes its clips.
- Each list has a color, which you can change in Settings → Lists.
- **Clips in a list are protected** from the history limit, automatic deletion and *Clear History*.

### Smart Lists (filled by rules)

A Smart List shows every clip that matches its rules. It is updated live: new clips appear in it as soon as you copy them, and nothing is copied or moved.

**How it differs from a list:**

| | List | Smart List |
|---|---|---|
| Contents | Clips you add by hand | Clips that match rules |
| Updates | Only when you add or remove clips | Automatically, all the time |
| Protects its clips from clean-up | Yes | No (only pins and lists do) |
| Drop clips onto its tab | Yes | No |

**Rules.** Each rule has a field, a condition and a value:

| Field | Conditions | Value |
|---|---|---|
| **Kind** | is, is not | Text, Links, Colors, Images, Files or Code |
| **Copied from app** | is, is not | An app |
| **Text** | contains, does not contain | Any text (case- and accent-insensitive) |
| **Last used** | within the last, more than | A number of days |
| **Pinned** | is, is not | yes / no |
| **Link domain** | is, contains, is not | A domain such as `github.com` (links and links inside text; "is" also matches subdomains) |
| **Text pattern** | matches, does not match | A regular expression (case-insensitive) |
| **First copied** | on or after, before | A date |

Choose whether a clip must match **all rules** or **any rule**. A Smart List with no rules shows every clip.

**Defaults.** Pastly includes two Smart Lists: **Today** (*Last used within the last 1 day*, a rolling 24 hours) and **This Week** (*within the last 7 days*). You can edit or delete them.

**Create and edit:**
- *New Smart List…* (toolbar menu, a tab's context menu, or Settings → Lists → **+**). A new Smart List starts with the rule *Kind is Links*.
- *New Smart List: From \<App\>* in a clip's context menu creates one for that clip's source app.
- *Edit Smart List…* (right-click its tab) opens it in Settings → Lists. There you set the name, an icon (15 to choose from), all/any matching and the rules, and see a live **Matching clips** count. Changes are saved immediately.

Examples:
- **Work links:** *Kind is Links* **and** *Link domain contains `atlassian.net`*.
- **Terminal commands this week:** *Copied from app is Terminal* **and** *Last used within the last 7 days*.
- **Ticket numbers:** *Text pattern matches `^[A-Z]+-\d+$`*.

*Sources:* `Sources/Pastly/Data/Models.swift` (`SmartList`, `SmartRule`), `Sources/Pastly/Data/ClipStore.swift`, `Sources/Pastly/UI/SettingsView.swift` (Smart List editor), `Sources/Pastly/UI/SettingsTabs.swift` (Lists tab)

---

## 12. Pinning

Pin the clips you reuse often (email signatures, addresses, code snippets):

- **⌘P**, the pin button in the toolbar or preview, *Pin* in the context menu, or drag clips onto the **Pinned** tab. ⌘P again unpins.
- Pinned clips show a pin icon and appear in the **Pinned** tab, in history order.
- **Pinned clips are protected** from the history limit, automatic deletion, *Clear History* and *Clear history when Pastly quits*. Only *Delete Everything* or deleting them yourself removes them.
- Settings → Lists → **Pinned** lists them with *Add to List* and *Unpin* buttons.

Pastly has no separate "favorites" feature; pins and lists serve that purpose.

*Sources:* `Sources/Pastly/Data/ClipStore.swift`, `Sources/Pastly/UI/PanelController.swift`

---

## 13. Drag and Drop

### Into other apps

Drag a clip, or several selected clips, out of the Pastly window into any app. The receiving app gets real content, not a reference:

| Clip | Arrives as |
|---|---|
| Text, link, color | Text, following the paste format (formatted or plain) |
| Rich text | Formatted in Formatted mode, plain in Plain mode |
| Image | The image itself, plus a temporary image file for web upload areas |
| File | The file (image files also carry the image) |

Examples: drop text into a search box, an image into a web upload area, or a file into Finder or a Mail attachment field.

While dragging, Pastly shows a drag card with a preview of the clip (or a count for several clips). The clip you grab is always the one that's dragged.

### Inside Pastly

- Drop clips on a **list tab** to add them to the list (or move them, if you dragged them from another list).
- Drop clips on **Pinned** to pin them.
- Drag within a list to **reorder** it.

Toasts confirm the result ("Added 2 clips", "Pinned 1 clip").

*Sources:* `Sources/Pastly/UI/PanelView.swift` (`DragProvider`, `DragFiles`), `Sources/Pastly/UI/PanelController.swift`

---

## 14. Image and Media Support

### Images

- Formats kept as-is: **PNG, JPEG, HEIC, GIF, WebP**. Other image data (such as TIFF) is stored as PNG.
- Rows show a thumbnail and the dimensions (for example `1600×900`); the preview shows the full image, its format and size.
- Pasting an image provides its original format plus TIFF, so most apps accept it.

### Finder image files

Copying an image file in Finder (⌘C) saves a **file** clip with a real thumbnail. Pastly also stores the image itself, so it can be previewed and pasted into apps that accept pictures but not files. Very large image files (over 50 MB) are stored as a PNG of at most 2048 pixels.

### Video and audio files

Copied video and audio files are **file** clips with extras:
- **Video:** a poster frame as the thumbnail with a play badge; the preview has a player with controls and full screen; duration and resolution are shown.
- **Audio:** cover art (if the file has it) with a music badge; the preview shows title, artist and album and a Play/Pause button.

### Text recognition (OCR)

For an image clip, choose **Copy Text from Image (OCR)** (context menu or preview button). Pastly recognizes the text on your Mac with Apple's Vision framework (accurate mode, automatic language detection), saves it as a new text clip from "Pastly OCR", and puts it on the clipboard. If no text is found, an alert says so.

*Sources:* `Sources/Pastly/Core/ClipItemParser.swift`, `Sources/Pastly/Core/MediaSupport.swift`, `Sources/Pastly/Core/Services.swift` (OCR), `Sources/Pastly/UI/ItemViews.swift`

---

## 15. Code, URL and Color Handling

### Code

- Text is recognized as code by a heuristic: valid JSON, common keywords (`func`, `let`, `def`, `class`, `SELECT`…), lines ending in `;`, `{` or `}`, and indentation. Prose (sentences) lowers the score.
- Code clips appear in the **Code** tab and are shown in a monospaced font.
- **Syntax highlighting** (Settings → Appearance → *Highlight code syntax*, on by default) colors comments, strings, keywords, type names and numbers. It is language-agnostic and covers common keywords of Swift, JavaScript, Python, Rust, SQL and similar languages.

### Links

- A clip is a **link** when the whole clip is one URL (see [Content Types](#3-clipboard-content-types)).
- Links have their own tab, can be opened with **Open in Browser** (preview) or **Open Link** (context menu), and can be filtered by domain in Smart Lists.

### Colors

- A clip that is exactly a color becomes a **color** clip with a swatch. The preview offers HEX, `rgb()`/`rgba()`, `hsl()` and SwiftUI `Color(...)` values, each with a copy button.
- **HEX codes inside text** (`#FFF`, `#FFFFFF`, `#FFFFFFFF`, up to 24 per clip) are recognized too. Rows show up to three swatches, and the preview lists them as copyable chips.
- Input formats recognized: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb()` and `rgba()`. Named colors and `hsl()` input are not recognized.

*Sources:* `Sources/Pastly/Data/Models.swift` (`CodeDetector`), `Sources/Pastly/Core/ContentHasher.swift` (`ColorParser`), `Sources/Pastly/UI/ItemViews.swift`

---

## 16. Settings and Preferences

Open Settings with **⌘,**, the gear button, or the menu bar menu. The window has seven sections. Every setting is saved immediately and kept across restarts.

### General

| Setting | Options (default first) |
|---|---|
| Launch Pastly at login | off / on |
| Monitor the clipboard | on / off (same as *Pause Saving*) |
| Ignore the next copy | one-time switch |
| Treat leading/trailing whitespace as the same item | off / on |
| When you press ↩ or double-click | Paste into the active app / Copy to the clipboard only |
| Default paste format | Keep original formatting / Plain text |
| Open clipboard history | Below the menu bar icon / In the center of the screen / At the mouse pointer |
| Click Behavior | Single Click to Preview / Single Click to Select |
| Keep up to | 500 / 100, 250, 1,000, 5,000, Unlimited |
| Delete items not used for | Never / 1, 7, 30, 90 days |
| Accessibility | Shows *Granted* or *Not granted*, with a **Grant…** button |

### Appearance

| Setting | Options (default first) |
|---|---|
| Appearance | System / Light / Dark |
| Accent color | System, Blue, Purple, Pink, Red, Orange, Yellow, Green, Teal, Graphite |
| Translucent background | on / off |
| Text size | Medium / Small / Large |
| Layout | Compact / Comfortable (shows source app) |
| Rounded corners | 0–12 pt (7) |
| Spacing between items | 0–8 pt (2) |
| Show source app icons | on / off |
| Show quick-paste numbers (⌘1–⌘9) | on / off |
| Show tabs for kinds | on / off |
| Animate the menu bar icon when copying or pasting | on / off |
| Animate new items in the list | on / off |
| Play sound when copying | on / off |
| Play sound when pasting from Pastly | off / on |
| Sound | macOS Alert Sound / any built-in macOS sound |
| Volume | 0–100% (50%), for non-alert sounds |
| Test Feedback | Plays the sound and the icon animation |
| Show the preview | Where there's room / On the left / On the right |
| Preview width | 300–640 pt (400) |
| Highlight code syntax | on / off |

A live sample shows your appearance choices as you change them.

### Shortcuts

Global shortcut recorders, quick-paste options, the ⌫/⌦ and Space options, and a reference list of the window shortcuts. See [Keyboard Shortcuts](#8-keyboard-shortcuts).

### Lists

A manager for **Pinned** clips, **Smart Lists** and **Lists**: create (**+**), delete (**−**), reorder by dragging, rename, recolor, reorder and move items, and the Smart List editor. See [Lists and Smart Lists](#11-lists-and-smart-lists).

### Privacy

See [Privacy and Local Data Storage](#18-privacy-and-local-data-storage) for details.

- Monitor the clipboard.
- **Never save copies from these apps:** a list of apps with on/off switches. Add apps with *Add Running App* or *Choose App…*.
- **Sensitive content:** *Skip card numbers*, *Skip one-time codes*, *Skip API keys, tokens and private keys* (all off by default).
- **Never save text containing:** keywords, each with *Match case* and an on/off switch.
- **Content kinds:** Save text, links, colors, images, files and code (all on).
- **Never save text that matches:** regular expressions with on/off switches, plus *Add Credit-Card Number Rule*.
- **Test your rules:** type sample text, pick the app it would come from, and see "Will be saved" or "Won't be saved — reason".
- Data retention: the item limit, automatic deletion and *Clear history when Pastly quits*.
- Storage location with an access check (*Only your account can read it* or a **Fix** button) and **Show in Finder**.
- **Clear History…** and **Delete Everything…**

### Backup

Export, import, *Back Up Now*, automatic backups and restore. See [Backups](#21-backups).

### About

- Version and build.
- **Check for Updates** and *Check automatically every week* (off by default). See [Privacy](#18-privacy-and-local-data-storage).
- Links to the GitHub repository and release notes.
- The license (MIT) and changelog, viewable in the app.
- Credits: Apple frameworks only, no third-party code.

The Settings window has a fixed size and its own tab bar.

*Sources:* `Sources/Pastly/UI/SettingsTabs.swift`, `Sources/Pastly/UI/SettingsView.swift`, `Sources/Pastly/Core/Preferences.swift`

---

## 17. Clipboard Monitoring

- macOS has no public "clipboard changed" notification and keeps only the latest clipboard contents, so Pastly checks the system clipboard's change counter on a timer: about **every 0.15 s**, and **every 0.05 s for 2 seconds after a copy** (copies tend to come in bursts). It reads the clipboard only when something has changed, so idle CPU use stays near zero.
- **Rapid copying:** copies at least about 75 ms apart are all saved, in order. A copy that is replaced within a few tens of milliseconds — before the next check — is never visible to Pastly or any other app, so the fastest bursts can skip intermediate copies; the last copy is always saved, and order is never mixed up.
- The **source app** is the app that is in front at that moment.
- These copies are **skipped**:
  - Pastly's own clipboard writes (when you select or paste a clip), so using Pastly never creates duplicates;
  - everything while saving is **paused**;
  - the next copy after **Ignore Next Copy**;
  - content marked **concealed or temporary** by password managers and similar apps (the `org.nspasteboard.ConcealedType`, `TransientType` and `AutoGeneratedType` conventions, plus 1Password, KeeWeb, TypeIt4Me and other known markers);
  - copies from **ignored apps**;
  - content excluded by your **privacy rules** (content kinds, keywords, patterns, card numbers, one-time codes, secrets).
- **Pause and resume saving:** Settings → General or Privacy (*Monitor the clipboard*), *Pause Saving* in the menu bar menu, **⌥-click** the menu bar icon, or a global shortcut. While paused, the menu bar icon is dimmed and the window shows a pause indicator (click it to resume).
- **Ignore Next Copy:** menu bar menu, Settings → General, or a global shortcut. Useful right before copying something private.

*Sources:* `Sources/Pastly/Core/ClipboardCore.swift` (`ClipboardMonitor`), `Sources/Pastly/Core/CaptureFilter.swift`

---

## 18. Privacy and Local Data Storage

### Where your data lives

- Everything is stored in **`~/Library/Application Support/Pastly/`**: a SQLite database (`history.sqlite`) and an `Images/` folder.
- The folder is readable only by your macOS user account (folder `0700`, files `0600`). Settings → Privacy shows this and offers a **Fix** button if the permissions have changed.
- Preferences are stored in the standard macOS preferences for Pastly.
- **To erase everything:** quit Pastly and delete that folder, or use **Delete Everything…** in Settings → Privacy.

### Network use

- **Clipboard content is never sent anywhere.** There is no sync, no account, no telemetry, no analytics and no crash reporting.
- The **only network request** is the update check: it asks GitHub's public API for the latest release of the Pastly repository and reads its version number, link and notes. It sends only a standard request with a `Pastly/<version>` user agent.
- It runs when you click **Check for Updates**, and automatically at most once a week **only if** you turn on *Check automatically every week* (off by default).

### What is never saved

- **Password managers:** content they mark as concealed or temporary is ignored automatically, and these apps are on the ignore list by default: 1Password (7 and 8), Bitwarden, Keychain Access, Passwords, KeePassXC and Dashlane.
- **Ignored apps:** any app you add. Each rule can be switched off without removing it.
- **Optional detectors** (Settings → Privacy → Sensitive content, all off by default):
  - **Card numbers:** 13–19 digits (spaces or dashes allowed) that pass the Luhn checksum.
  - **One-time codes:** a clip that is just a 4–8 digit code.
  - **API keys, tokens and private keys:** common formats such as AWS (`AKIA…`), GitHub (`ghp_…`, `github_pat_…`), `sk-…` keys, Stripe, Slack (`xox…`), Google (`AIza…`), JSON Web Tokens, and `-----BEGIN … PRIVATE KEY-----` blocks.
- **Your own rules:** keywords (optionally case-sensitive), regular expressions, and whole content kinds.

### Limitations

- Detection is rule-based: text that doesn't match a rule is saved. Use *Pause Saving* or *Ignore Next Copy* when you copy something sensitive.
- The source app is the app in front when the copy is detected. Copies made by background apps are attributed to the frontmost app.
- The database is not encrypted beyond macOS's own protections (such as FileVault).

*Sources:* `Sources/Pastly/Core/SettingsServices.swift` (`SensitiveDetector`, `SecureStorage`, `UpdateChecker`), `Sources/Pastly/Core/CaptureFilter.swift`, `Sources/Pastly/Core/Preferences.swift`

---

## 19. User Interface and Navigation

### The Pastly window

A compact floating window that opens over any app, including full-screen apps, and closes when you click elsewhere. It can be resized (minimum 380×340).

- **Header:** the search field, a paste-queue counter and a pause indicator when active, the **Lists and filters** menu, and buttons for **Delete selected**, **Pin or unpin selected**, **Settings** and **Quit Pastly**.
- **Tabs:** History, Pinned, kind tabs, Smart Lists and Lists (see [Search and Filtering](#10-search-and-filtering)). Right-click a tab for rename, edit or delete options.
- **Rows:** an icon or thumbnail, a one-line title (images show their size, several files show "N files: …"), up to three color swatches, a pin icon, the source app's icon (or name in the Comfortable layout), the time since you last copied it ("now", "5m ago"…) and its ⌘1–⌘9 number.
- **Footer:** `⌘P Pin` · `Space Preview` and the number of clips.
- **Toasts:** short messages confirm actions such as copies, deletes, drops and the paste queue.

### Context menu

Right-click a clip (or a selection) for: **Paste**, **Paste … with Formatting** or **Paste … as Plain Text** (the opposite of your current format), **Paste One by One**, **Paste Transformed ▸**, **Copy**, **Copy as Plain Text**, **Preview**, **Edit…** / **Rename…**, **Copy Text from Image (OCR)**, **Open Link**, **Reveal in Finder**, **Pin / Unpin**, **Add to List ▸**, **Move to List ▸**, **Remove from List**, **New Smart List: From \<App\>** and **Delete**. Items appear only when they apply to the clip.

### Menu bar icon

- **Click:** open or close the window (it opens under the icon).
- **Right-click** (or ⌃-click): the menu, which has:
  - **Open Pastly** (with your shortcut)
  - **Recent Clips ▸** (the 10 newest)
  - **Stop Paste Queue** (only while one is running)
  - **Pause Saving** and **Ignore Next Copy** (with checkmarks)
  - **Clear History…**
  - **Export Backup…** and **Import Backup…**
  - **Settings…** and **Quit Pastly**
- **⌥-click:** pause or resume saving.
- The icon briefly changes into a symbol for the copied kind when you copy or paste (if enabled), dims while saving is paused, and shows a counter during the paste queue.

### Feedback

When you copy (anywhere) or paste from Pastly, Pastly can play a sound (the macOS alert sound by default, or another built-in sound) and animate the menu bar icon. Both are configurable in Settings → Appearance. The animation respects *Reduce motion*.

*Sources:* `Sources/Pastly/UI/PanelView.swift`, `Sources/Pastly/UI/ItemViews.swift`, `Sources/Pastly/UI/Feedback.swift`, `Sources/Pastly/App/AppDelegate.swift`

---

## 20. Accessibility and macOS Integration

### Accessibility permission

macOS requires the **Accessibility** permission for one app to press keys in another. Pastly uses it to:
- press ⌘V in the app you were using after you choose a clip;
- watch for your ⌘V and Esc during the paste queue.

**Grant it** when Pastly asks (*Grant Accessibility…*), from Settings → General → **Grant…**, or in **System Settings → Privacy & Security → Accessibility**.

**Without it**, Pastly still saves your history. Choosing a clip copies it, and you press ⌘V yourself. The first time this happens in a session, an alert explains how to enable pasting; afterwards a short message appears. If pasting still only copies after an update, remove Pastly from the Accessibility list and add it again.

### Other integration

- **Menu bar app:** Pastly has no Dock icon; it lives in the menu bar.
- **Launch at login:** uses the standard macOS login item (Settings → General).
- **Light and Dark Mode:** follows the system, or force Light or Dark (Settings → Appearance). The accent color can follow the system accent.
- **Spaces and full screen:** the window opens on the current Space, including over full-screen apps.
- **Keyboard layouts:** shortcuts and the automatic ⌘V use your current layout.
- **Secure input:** when a password field or similar has secure input active, Pastly doesn't send keystrokes; it copies the clip and tells you to press ⌘V.
- **On-device OCR** with Apple's Vision framework.
- **First launch:** a welcome alert explains the shortcut and the Accessibility permission.

*Sources:* `Sources/Pastly/Core/Services.swift`, `Sources/Pastly/Core/ClipboardCore.swift`, `Resources/Info.plist`

---

## 21. Backups

All backups are single JSON files that you keep wherever you like. No cloud is involved.

- **Export…** saves your whole history to a `.pastly` file (named like `Pastly Backup 2026-11-18.pastly`), with images embedded.
- **Import…** adds the clips from a backup, skipping clips you already have. It accepts `.pastly` and `.json` backup files, including backups made by earlier versions.
- **Back Up Now** writes a backup into the backup folder; **Show Backups in Finder** opens it.
- **Automatic backups** (off by default): *Every day* or *Every week*, keeping the latest 1–60 backups (default 7), in a folder you choose (default `~/Documents/Pastly Backups`). Only `.pastly` files are removed when the keep limit is reached; backup files from earlier versions are never deleted.
- **Restore:** pick one of the 10 newest backups or *Restore from File…*, then choose **Merge** (add missing clips) or **Replace History** (remove current clips first; your lists are kept).
- **Included:** text, rich text (RTF/HTML), links, colors, images, file references (not the files themselves), titles, pins, use counts, lists and Smart Lists.
- Backup and export are also available from the menu bar menu (*Export Backup…*, *Import Backup…*).

*Sources:* `Sources/Pastly/Data/BackupService.swift`, `Sources/Pastly/Core/SettingsServices.swift` (`AutoBackup`), `Sources/Pastly/UI/SettingsTabs.swift`

---

## 22. Limits

| What | Limit |
|---|---|
| Rich text (RTF or HTML) captured | Up to 2 MB each; larger formatting is dropped (the plain text is still saved) |
| Image on the clipboard | Up to 50 MB |
| Finder image file stored at full size | Up to 50 MB; larger files are stored as a 2048-pixel PNG |
| Link detection | URLs shorter than 4,000 characters, without spaces |
| Text shown in the preview | First 30,000 characters (the full text is kept and pasted) |
| Formatted preview | Rich text under 400 KB |
| Search | First 20,000 characters of each clip |
| Colors found inside text | Up to 24 per clip |
| Undo delete | The last deletion, within 5 minutes |
| Menu bar Recent Clips | 10 newest |
| Quick paste | Clips 1–9 of the current tab |

---

## Not available yet

These are **planned or under consideration** and are **not** part of the current app:

- Snippets with placeholders
- Link previews (page titles and icons)
- Cropping and rotating images
- Automatic in-app updates (today Pastly only checks for and links to new releases)
- Shortcuts app actions
- Developer ID signing and notarization (today the first launch needs *Open Anyway*)
- Optional database encryption
- Scheduled export beyond automatic backups
- Sync between Macs (not planned: history stays on each Mac by design)

---

*This document describes Pastly 0.7.1. If you find a difference between this document and the app, please [open an issue](https://github.com/sp201004/Pastly/issues).*
