Pastly {{VERSION}} — Setup Guide
================================

Pastly saves the things you copy and gives them back with one shortcut.
It lives in the menu bar, keeps everything on this Mac, and is free and
open source (MIT License).

What you need
  • A Mac with Apple silicon (M1, M2, M3, M4 or newer)
  • macOS 14 Sonoma or newer


STEP 1 — Copy Pastly to Applications
------------------------------------
In this window, drag the Pastly icon onto the Applications folder.
Then you can eject the "Pastly" disk (drag it to the Trash or press ⌘E).


STEP 2 — Allow the first launch
-------------------------------
This copy of Pastly isn't notarized by Apple yet, so macOS asks you to
confirm it once:

  1. Open Applications and double-click Pastly.
     macOS shows a warning that it can't check the app. Click "Done".
  2. Choose Apple menu  > System Settings, then select Privacy & Security
     in the sidebar.
  3. Scroll to the Security section. Beside the note about Pastly,
     click "Open Anyway" and approve with Touch ID or your login password.
  4. Launch Pastly once more and choose "Open" when macOS asks.

  On macOS 14 Sonoma you can also right-click (or Control-click) Pastly
  in Applications, choose "Open", then click "Open".

You only need to do this the first time.


STEP 3 — Turn on pasting (recommended)
--------------------------------------
To paste straight into the app you're working in, Pastly needs
Accessibility permission. When it asks, choose "Grant Accessibility…", or
go to System Settings, select Privacy & Security, then Accessibility, and
switch Pastly on.

Without it, Pastly still saves your history. When you pick a clip, it is
copied and you press ⌘V yourself.


STEP 4 — Everyday use
---------------------
  Open your history ........ ⇧⌘V from any app, or click Pastly's
                             clipboard icon at the top right of the screen
  Paste a clip ............. double-click it, or select it and press ↩
  Paste as plain text ...... ⇧↩
  Quick paste .............. ⌘1 to ⌘9 for the first nine clips
  Preview .................. click a clip or press Space (Space again closes)
  Select several ........... ⌘-click, ⇧-click, or ⌘A for all
  Paste one by one ......... ⌘↩, then each ⌘V in any app pastes the next clip
  Pin / edit / delete ...... ⌘P / ⌘E / ⌫  (⌘Z brings deleted clips back)
  Search ................... just start typing
  Switch lists ............. ⇥ (Tab)
  Close .................... esc

  Pastly's icon at the top of the screen: click to open your history,
  Control-click for its menu (Recent Clips, Pause Saving, Ignore Next Copy,
  Settings…, Quit), Option-click to pause saving.

  Start at login: Settings > General > "Launch Pastly at login".
  Settings also has Appearance, Shortcuts, Lists, Privacy, Backup and About.


Privacy
-------
  • Your clips are stored only on this Mac, in
    ~/Library/Application Support/Pastly (readable only by your account).
  • Anything a password manager puts on the clipboard (1Password,
    Bitwarden, Apple Passwords and others) is skipped automatically.
  • Settings > Privacy lets you ignore apps, skip text by keyword or pattern,
    and limit or automatically delete history.
  • Pastly doesn't sync and doesn't send your clips anywhere.


Troubleshooting
---------------
  Double-click or ↩ only copies, nothing is pasted
    → Accessibility isn't on (Step 3). If Pastly is already listed there,
      select it, click "–" to remove it, then add Pastly again.

  Nothing happens when I press ⇧⌘V
    → Another app may use the same shortcut. Pick a different one in
      Settings > Shortcuts, or click Pastly's icon at the top of
      the screen instead.

  macOS says Pastly "is damaged" or "can't be opened"
    → Make sure you copied it to Applications (Step 1) and followed Step 2.
      This build is for Apple silicon Macs with macOS 14 or newer only.


Uninstall
---------
  1. Control-click Pastly's icon at the top of the screen and choose
     "Quit Pastly".
  2. Move Pastly from Applications to the Trash.
  3. To also delete your saved history, remove the folder
     ~/Library/Application Support/Pastly


More help, source code and releases: https://github.com/sp201004/Pastly
