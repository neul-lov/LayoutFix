# LayoutFix

A native macOS menu bar app that fixes text typed with the wrong keyboard layout, using the
standard Korean **Dubeolsik (2-set)** layout:

| Typed | Converted |
|---|---|
| `dkssudgktpdy` | `안녕하세요` |
| `gksrmf` | `한글` |
| `안녕` | `dkssud` |

Press a global shortcut in any app. LayoutFix converts the **selected text** or, if nothing is
selected, the **word before the cursor**, and can undo it. Everything runs locally: there is
no network code, no AI, no external service, and no third-party dependency.

## Requirements

- macOS 14 Sonoma or later (built and tested on macOS 27.0.1, Apple Silicon)
- Xcode 15+ command line tools / Swift 6 toolchain to build (tested with Xcode 27.1, Swift 6.4)

## Build and launch

```bash
cd LayoutFix
Scripts/build-app.sh                 # release build for arm64 → build/LayoutFix.app (ad-hoc signed)
open build/LayoutFix.app
```

To sign with your own certificate (recommended, see *Permissions* below):

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" Scripts/build-app.sh
```

Copy `build/LayoutFix.app` to `/Applications` (`ditto build/LayoutFix.app /Applications/LayoutFix.app`) before granting
Accessibility and enabling *Launch at login*, so the grant and the login item point at a stable location.

LayoutFix has no Dock icon and no window at launch; look for the keyboard icon in the menu bar.
`open build/LayoutFix.app --args --settings` opens the settings window on launch.

## Default shortcuts

| Shortcut | Action |
|---|---|
| ⌃F (Control+F) | Convert using the default direction (menu › Default Direction). In Auto-detect, pressing it again converts the word back |
| ⌃G | Convert English keystrokes → Korean (G types ㅎ, the first key of 한글) |
| ⌃E | Convert Korean → English keystrokes |
| ⌃Z | Undo the last conversion |

Each default is one modifier plus one letter, pressed with the left hand alone. None of them is
a macOS shortcut, but global shortcuts take priority over every app, so while LayoutFix runs:
⌃F (cursor right) and ⌃E (end of line) no longer work in text fields, and ⌃Z (suspend) and ⌃G
no longer reach terminal programs. Change them in Settings if you rely on those keys.

All four can be changed or cleared in **Settings › Shortcuts**. A shortcut must include ⌃, or
⌘ together with ⌥ (or be a function key), so it can't block typing (⌥K → ˚) or app shortcuts
(⌘C). Conflicts with macOS keyboard shortcuts, with other apps that hold the same shortcut,
and duplicates within LayoutFix are detected and shown in Settings, in the menu, and in an
alert at launch.

### Conversion directions

- **Auto-detect** (default for ⌃F): Hangul becomes keystrokes. Latin letters become Hangul
  only if **all** of these hold:
  - No word is a known English word. LayoutFix checks a built-in list of about 280 common words
    (`the`, `and`, `that`, `code`, …), plus the macOS spell checker for words of 4+ letters. The
    spell checker runs locally and is only given that one word.
  - The result has the shape of real Dubeolsik typing. That means at least one complete
    syllable, no lone vowel, and no stray consonant before a syllable. After the last syllable,
    only casual runs such as `ㅋㅋ`, `ㅎㅎ`, `ㅠㅠ`, `ㅡㅡ` are allowed, and a word may open with
    `ㅋㅋ`.

  Mixed Korean/English text is refused. Some Korean words collide with English (`so`=내, `go`=해,
  `do`=애, `to`=새), so auto refuses them as ambiguous. The explicit shortcut converts them.
- **English → Korean / Korean → English**: always convert in that direction. The dedicated
  shortcuts ⌃G / ⌃E always use their own direction, whatever the default is.

## Permissions

LayoutFix needs **Accessibility** access to read the selection or the word before the cursor in
another app, replace it, and send ⌘C/⌘V for the clipboard fallback.

1. Launch LayoutFix. Without the permission it opens **Settings › Permissions & Privacy**, which
   explains why it's needed.
2. Click **Open Privacy & Security**, and under **Accessibility** turn on **LayoutFix** (use **+**
   to add `LayoutFix.app` if it's not listed).
3. The status updates on its own (menu: "Accessibility: allowed").

Without the permission, the shortcuts do nothing. No text is read, no keys are sent, and the
menu says what's missing.

**Clipboard access (macOS 15.4 and later):** the clipboard fallback (used in Safari's web fields,
VS Code and similar apps) has to read the clipboard so it can put it back afterwards. The first
time, macOS asks whether LayoutFix may paste from other apps. Choose **Allow**, or set LayoutFix
to *Always Allow* in Privacy & Security. If access is denied, or the clipboard can't be read in
full, LayoutFix refuses the clipboard fallback and never touches your clipboard. It also leaves
concealed clipboard content (password managers) alone.

**Ad-hoc signing caveat:** macOS ties the Accessibility grant to the code signature. An ad-hoc
signed build gets a new signature every time you rebuild, so after rebuilding you may have to
remove LayoutFix from the Accessibility list and add it again. Signing with a stable
certificate (`SIGN_IDENTITY`) avoids this.

## How it works

```
Sources/
  HangulLayout/       Dubeolsik tables, jamo composition automaton, decomposition, auto-direction heuristic (pure Swift)
  AccessibilityText/  AX layer: focused element, selection/caret, string-for-range, replace, secure-field detection
  ClipboardBridge/    clipboard snapshot/restore transaction, lazy transient paste item, synthetic ⌘C/⌘V/⌥⇧← keys
  HotKeys/            Carbon RegisterEventHotKey (exclusive), macOS shortcut conflict detection, key-combo model
  ConversionEngine/   orchestration: AX path → AX+paste → keyboard/clipboard path, word boundaries, undo, app policy
  LayoutFixApp/       SwiftUI MenuBarExtra, settings window, shortcut recorder, preferences, launch at login
  LayoutFixIntegration/  test harness that drives the real engine/app against real apps (not shipped)
Tests/                Swift Testing unit tests (converter, engine with fakes, clipboard on a private pasteboard, hotkeys)
```

**Conversion** is real composition, not character substitution. Caps Lock text (`DKSSUD`) is
read as unshifted keys. Mixed case keeps Dubeolsik Shift (`dlTek` → 있다). Two lone consonants
merge into a compound as the system IME does (`rt` → ㄳ). A Dubeolsik automaton builds
syllables from initial, medial and final jamo. It merges compound vowels (ㅗ+ㅏ=ㅘ) and compound
finals (ㄹ+ㄱ=ㄺ), moves a final (or the second half of a compound final) to the next syllable
when a vowel follows (닭 + ㅏ → 달가), and never uses ㄸ/ㅃ/ㅉ as finals. The reverse direction
decomposes precomposed syllables, compatibility jamo and NFD conjoining jamo. Spaces, digits
and punctuation pass through unchanged. All 11,172 syllables round-trip.

**Replacing text, in order of preference:**

1. **Accessibility.** Read `AXSelectedTextRange` and cross-check `AXStringForRange`,
   `AXSelectedText` and `AXNumberOfCharacters`. Inconsistent answers mean the element isn't
   trusted. For the previous word, read up to 256 UTF-16 units before the caret, select the word,
   and confirm the app selected exactly that word. Then write `AXSelectedText` and **read it
   back** (text at the range and the new length).
2. **Accessibility + paste.** Some apps (Safari's WebKit fields, for example) accept the AX
   write but ignore it. If nothing changed, paste through the clipboard instead, and verify
   through Accessibility.
3. **Keyboard + clipboard.** For apps with no usable AX text (Electron apps such as VS Code are
   routed here on purpose, because their hidden IME textarea holds only part of the document):
   ⌘C detects a selection. If there is none, ⌥⇧← selects the previous word and ⌘C reads it. The
   text is validated (one word, no line break) before ⌘V replaces it.

**Safety rules:**

- **Where nothing is read:**
  - password fields (`AXSecureTextField`), or while Secure Event Input is on
  - password managers and system authentication dialogs
  - terminals, including terminals embedded in editors (VS Code's integrated terminal), where
    ⌘V would type into the shell instead of replacing
  - apps that don't answer Accessibility queries in time (busy or hung), so no keys get queued
    into them
- **Focus checks:** the target is the app that actually holds keyboard focus (Spotlight, for
  example), not just the frontmost app. That target is re-checked before every batch of
  synthetic keys. If you switch apps mid-request, it stops.
- If text can't be read and verified, it isn't changed. If the result equals the original,
  nothing is written. Text containing an embedded image or file (U+FFFC) is refused. A caret in
  the middle of a word is refused rather than converting half of the word.
- An Accessibility write that is applied late, or that times out but lands anyway, is detected,
  so the paste fallback never inserts the text twice.
- Line copies made with an empty selection (VS Code's marker; a copied single line ending in a
  line break as in JetBrains/Sublime) are not treated as selections.
- **Saving the clipboard:** the full contents (every item, every type, in order) are saved in
  memory first. If that copy would be incomplete or larger than 32 MB, nothing is touched.
- **Restoring it:** restore happens only if the clipboard's `changeCount` is still ours, so if you
  copy something new mid-operation, your new content is kept. Restores and temporary writes are
  host-only, so nothing travels over Universal Clipboard. An unchanged clipboard is not
  rewritten. Quitting mid-request puts the clipboard back.
- **The temporary item:** it is lazy, so LayoutFix knows when the target app actually read it,
  and marked `org.nspasteboard.TransientType`/`ConcealedType`, so well-behaved clipboard managers
  skip it.
- **Timing:** LayoutFix waits up to 5 s for a paste to be read, so a stalled app can't paste your
  old clipboard into the document. If a ⌘C times out in a busy app, it waits for the late copy
  before restoring.
- **Undo** keeps the original text, the replacement, the app, the field and the range, in memory
  only. A one-shot timer clears them after 2 minutes.
  - It restores only if the same app and field are focused and the replacement is still exactly
    where it was put. Your caret stays where you left it, shifted by the length change.
  - On the keyboard path it selects the replacement with ⇧← and checks it with ⌘C before
    pasting. Replacements over 300 characters are not undone that way.
- **Synthetic shortcuts** (⌘C, ⌘V, ⌥⇧←) press and release their modifier keys like a person
  does, so macOS never believes ⌘ is still held afterwards (which would turn your next click
  into a ⌘-click).
- **Idle cost:** Carbon hotkeys and an event-driven permission notification; no timers, no event
  taps, no polling. Short polls happen only during a request, for a few hundred milliseconds.
- **On quit** (menu Quit, ⌘Q, or SIGTERM), hotkeys and observers are released and undo data is
  cleared.
- **Privacy:** the log only records outcome categories ("Converted previous word to Korean
  (Accessibility)"), never text. No text is written to disk.

## Tests

```bash
swift test                                          # unit tests
Scripts/build-app.sh
.build/debug/LayoutFixIntegration safari            # real-app checks: takes focus for ~15 s
.build/debug/LayoutFixIntegration app --app build/LayoutFix.app
```

The integration harness needs Accessibility access for the process that launches it, and an
unlocked screen. Every engine call and synthetic key it sends is guarded: if focus leaves the app
under test, it stops instead of typing elsewhere.

## Test results (macOS 27.0.1, Apple Silicon, Xcode 27.1 / Swift 6.4)

**Unit tests: `swift test`, 110 test functions, all passing.** Parameterized cases count as one
function each.

- **Converter, 28:** the required examples; initials, vowels, finals and double consonants;
  compound vowels and finals; Caps Lock; NFD input; unmappable old Hangul; lone compound
  consonants; preserving spaces, digits and punctuation; all 11,172 syllables and 2,000 random
  sequences round-tripping; explicit vs auto direction; ~30 common English words refused in
  auto; casual Korean accepted.
- **Engine, 65, using fake apps:**
  - selected-text and previous-word replacement on both the Accessibility and keyboard paths
  - undo with caret/selection restoration, refused when the text changed or the field differs,
    and expiry
  - denied permission, password field, Secure Input, excluded apps, terminals and embedded
    terminals, an unresponsive app, a busy app with late ⌘C
  - focus moving to another app mid-request
  - a clipboard that can't be saved or is concealed, a clipboard changed by the user
    mid-operation, a stalled paste, quitting mid-request
  - Accessibility writes ignored, delayed or timed out
  - attachments, a caret inside a word, VS Code/JetBrains line copies, explicit direction
  - status messages never containing text
- **Clipboard, 9, on a private named `NSPasteboard`:** full restore including type order, newer
  content kept, unreadable or concealed contents refused, an unchanged clipboard not rewritten.
- **Hotkeys, 8:** registration, duplicates, invalid combos, conflicts with other registrations
  and with macOS shortcuts, reading the real macOS shortcut list.
- **Mutation check:** disabling the focus re-check or the busy-app detection makes 4 regression
  tests fail, as intended.

**Real apps, run by the integration harness** (final run after all fixes, Safari 27.0.1):

| Check | Result |
|---|---|
| Safari textarea: previous word converted (AX + paste), undo, clipboard restored | Passed |
| Safari input: selection converted and undone; clipboard intact | Passed |
| Safari contenteditable: previous word converted | Passed |
| Safari password field: refused with Secure Input detected; clipboard untouched | Passed |
| LayoutFix.app: launches with no Dock icon; Settings opens on request | Passed |
| Launch at login: Settings toggle turned on (SMAppService) without error, then off again | Passed |
| Closing the Settings window leaves the app running | Passed |
| Another process cannot take ⌃⌥⌘K while LayoutFix holds it | Passed |
| With Safari frontmost and LayoutFix in the background: ⌃⌥⌘K converts, ⌃⌥⌘Z restores, ⌃⌥⌘Space (auto) converts, ⌃⌥⌘E converts back; clipboard intact | Passed |
| Quit (SIGTERM): clean shutdown, hotkeys released (another process can register them) | Passed |
| No modifier key left "held" after synthetic shortcuts | Passed. An earlier run caught a bug here: a stuck ⌘ after ⌘V. Fixed |
| TextEdit, Notes, VS Code | **Not tested.** Not approved for automated driving in this session |

Totals: Safari suite 10/10, app suite 17/17. These runs used the earlier ⌃⌥⌘ shortcuts. After the
switch to ⌃, the four new shortcuts were confirmed registered (another process can't take them);
the end-to-end hotkey run has not been repeated with them yet.

**Idle cost:** 0.00 % average CPU over 20 s, 18 MB physical footprint, 3 threads, about 1 idle
wakeup per second as sampled by `top`.

**Privacy:** the app log captured during every real-app run contained only outcome categories, never test text.

## Known limitations

- **Compatibility is app-specific.** Verified end-to-end only in Safari's WebKit fields (see
  *Test results*). Apps with custom text engines may expose no usable Accessibility text and no
  standard ⌘C/⌘V behaviour; then LayoutFix refuses instead of guessing.
- **The keyboard/clipboard path cannot see the document:**
  - The target app's own ⌘C copy can be recorded by clipboard history apps.
  - Another program writing the clipboard in the milliseconds between LayoutFix's ⌘C and the
    app's copy would be taken as the copied text.
  - Another program reading the temporary item would make an ignored paste look accepted.
  - If the caret is inside a word, ⌥⇧← converts only the part before it (the Accessibility path
    refuses this case).
  - Undo checks the app, the field (when Accessibility identifies it) and the text right before
    the caret, but not the exact position.
  - A paste that a stalled app performs more than 5 s late is reported as a failure.
  - Turn the fallback off in Settings if you prefer Accessibility-only behaviour.
- **Previous word on the keyboard path:** if ⌘C produces nothing, LayoutFix presses → to drop
  the ⌥⇧← selection. If the caret was at the very start of the text, that moves it by one
  character.
- **Auto-detect is a guard, not a language detector.** It now refuses common English words and
  uses the spell checker, but uncommon words can still look like Korean, and short Korean words
  that are also English are refused. Use ⌃G / ⌃E when it matters.
- **IME composition:** if the Korean input method still has an uncommitted (underlined) syllable,
  apps differ in how they report it; commit it (e.g. with an arrow key) before converting.
- **Word boundaries** are whitespace-based: punctuation typed with the word converts with it
  (`dkssud,` → `안녕,`), and words longer than 256 UTF-16 units are refused.
- Ad-hoc signing means the Accessibility grant has to be renewed after each rebuild (see above).
- Only Dubeolsik is supported (no Sebeolsik or other layouts).
