# Taffy

English | [日本語](README.ja.md)

A macOS menu bar app that searches the tabs open across multiple browsers and terminals (Ghostty / Terminal.app) and switches to the one you pick.

Press the hotkey (`⇧⌘Space` by default) to open the search panel and filter the tabs of every running browser by title and URL. Press `⇥` (Tab) to switch to searching terminal tabs and find the ones running Claude Code.

## Features

- Search the tabs of every running supported browser at once (title, URL, browser name)
- Space-separated keywords are ANDed. Matches substrings as well as fuzzy patterns (`gthb` → GitHub). Ignores case and full-width/half-width differences
- Activates the selected tab and brings its window to the front (restoring it if minimized)
- Close tabs from the panel
- Shows icons on tabs that are playing audio or using the camera / microphone / screen sharing, and lists them first ([see below](#tabs-using-audio-or-camera))
- Shows the previously fetched tabs immediately and updates as each browser responds
- Switch between browser and terminal search with `⇥` ([see below](#terminal-tabs)). Terminal tabs running Claude Code are marked and listed first
- Launch at login (set from the menu bar menu)

## Installation

Distributed through a Homebrew tap ([`yteraoka/homebrew-cask`](https://github.com/yteraoka/homebrew-cask)).

```sh
brew install --cask yteraoka/cask/taffy
```

- Installs the prebuilt universal build (Apple Silicon / Intel, macOS 13 or later) from GitHub Releases into `/Applications/Taffy.app`
- The app is signed with Developer ID and notarized

To uninstall, run `brew uninstall --cask yteraoka/cask/taffy` (add `--zap` to remove settings too).

To build from source, see the [developer guide](docs/development.md) (Japanese).

## Supported browsers

| Browser | Notes |
| --- | --- |
| Safari / Safari Technology Preview | |
| Google Chrome (including Beta / Dev / Canary) / Chromium | |
| Brave (including Beta) | |
| Microsoft Edge (including Beta / Dev) | |
| Vivaldi | |
| Arc | |

Firefox is not supported because it offers no way to list tabs via AppleScript. Opera is excluded because most of its AppleScript tab operations don't work.

## Supported terminals

| Terminal | Notes |
| --- | --- |
| Ghostty | Requires 1.3 or later (with AppleScript support) |
| Terminal.app | |

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `⇧⌘Space` | Open / close the panel |
| `↑` `↓` (`⌃P` `⌃N`, `⌃K` `⌃J`) | Move selection |
| `⌘↑` `⌘↓` | Jump to first / last |
| `Page Up` `Page Down` | Move by 8 items |
| `↩` | Open the selected tab |
| `⇥` (`⇧⇥`) | Toggle between browser and terminal search |
| `⌘1` / `⌘2` | Switch to browser / terminal search |
| `⌘M` | Browsers: show only tabs using audio / camera / microphone / screen sharing. Terminals: show only tabs running Claude Code (press again to clear) |
| `⌘⌫` | Close the selected tab (browsers only) |
| `esc` | Close the panel |

While an input method (IME) is composing text, `↩` and arrow keys go to the IME. You can also click a tab to open it.

You can also switch by clicking "Browsers / Terminals" at the top right of the panel. Taffy remembers which one you used last and opens with it next time.

## Terminal tabs

Terminal search lists tabs from Ghostty and Terminal.app. The second line shows the working directory (Ghostty) or the tty and running process (Terminal.app).

Tabs running Claude Code get an orange ✦ and are listed first when the query is empty. Use `⌘M`, "N running Claude Code" at the bottom of the panel, or `@claude` (or `@cl`, `@cc`) in the search field to show only those tabs. Their second line shows the directory Claude Code was started in, so you can search by project name too.

You can also set a hotkey that opens terminal search directly (none by default):

```sh
defaults write com.github.yteraoka.taffy terminalHotkey "ctrl+shift+space"
```

### Limitations

- Terminal tabs can't be closed (that would terminate the processes running in them)
- For split tabs, a tab counts if Claude Code is running in any of its panes
- In Ghostty, Claude Code is detected from the tab title (Claude Code changes the terminal title to something like `✳ …` while running). Detection doesn't work if you disable title changes with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`
- Terminal.app doesn't report per-tab titles via AppleScript, so the selected tab shows the window name and other tabs show the custom title or the running process name
- Ghostty's working directory is whatever the shell last reported (OSC 7); it is empty if shell integration is disabled
- Ghostty 1.2 and earlier don't support AppleScript, so their tabs aren't listed

## Tabs using audio or camera

Tabs playing audio or using the camera, microphone, or screen sharing (such as web meetings) get an icon on the right side of the list.

| Icon | State |
| --- | --- |
| Red video | Camera in use |
| Orange microphone | Microphone in use |
| Purple screen | Screen sharing |
| Blue speaker | Playing audio |
| Gray muted speaker | Muted |

- When the query is empty, tabs using the camera / microphone / screen sharing come first, then tabs playing audio, then muted tabs
- Click "N with audio/camera" at the bottom of the panel or press `⌘M` to show only those tabs
- You can also filter with `@media` (all), `@camera`, `@mic`, `@screen`, `@audio`, or `@muted` in the search field. Prefixes like `@cam` work, and they can be combined with other terms (e.g. `@audio youtube`)

### Enabling

Browsers don't expose this state via AppleScript, so Taffy reads the tab bar through the Accessibility API. This requires the Accessibility permission.

Choose "Enable audio/camera indicators…" at the bottom of the panel or "Audio & Camera Indicators…" in the menu bar menu to open the Accessibility pane of System Settings, then turn on Taffy. Without this permission, searching and switching tabs still works as usual.

Up to v0.3.0 the app was ad-hoc signed, so macOS treats the upgrade from those versions (or a local rebuild) as a different app, and the old permission stops applying. System Settings may still show Taffy as on, but turning it off and on again doesn't help. If icons stop appearing even though the permission looks on, quit Taffy, remove Taffy from the list with "−" (or run the command below), then start Taffy and allow it again:

```sh
tccutil reset Accessibility com.github.yteraoka.taffy
```

### Web meeting tabs (inferred)

Chromium-based browsers show only one state per tab, and during a web meeting "playing audio" wins. So in Brave and recent Chrome, a Google Meet tab can't be read as using the camera or microphone.

To cover this, Taffy asks macOS the following (no extra permission is needed, and the devices aren't opened):

- Whether any app on the Mac is using a camera
- Whether the browser itself is playing audio or recording from a microphone (macOS 14.2 or later; this covers the browser and its helper processes, per app)

If so, tabs on web meeting sites that are playing (or have muted) audio get the camera / microphone icon. Supported sites: Google Meet, Zoom, Microsoft Teams, Webex, Whereby, Jitsi Meet, and Amazon Chime (`meetingHosts` in `Sources/Taffy/CaptureInference.swift`).

Even when the tab bar can't be read (for example without the Accessibility permission), web meeting tabs of a browser that is playing or recording audio get the speaker / microphone icon. Other tabs get no icon in that case, since macOS doesn't tell which tab is making the sound.

This is a guess: if another app (such as the Zoom app) uses the camera while a meeting tab plays audio, the tab gets the camera icon too. On macOS 14.1 and earlier the microphone is also judged Mac-wide, so another app using a microphone, or just playing audio through a device that combines a microphone and speaker (AirPods, USB headsets), may count as the microphone being in use.

### Limitations

- Detection works with browsers displayed in English or Japanese. Other languages may not be detected
- Tabs in windows whose tab bar isn't visible (such as a Safari window with only one tab) or in windows on another Space can't be detected
- Arc keeps its tabs in the sidebar, so it isn't supported for now
- If icons don't appear, run `defaults write com.github.yteraoka.taffy mediaDebug -bool true` and restart Taffy; the tab information it reads and the browser's audio output / recording state as macOS sees it (`trusted=0` means the Accessibility permission isn't in effect) are logged to Console.app (search for `Taffy media`)

## Permissions

The first time Taffy fetches tabs, macOS asks for each browser or terminal, e.g. "“Taffy” wants access to control “Google Chrome”". Choose "Allow".

If you denied it, or the panel shows `not allowed to control this app` at the bottom, turn on the relevant app for Taffy under System Settings > Privacy & Security > Automation.

Up to v0.3.0 the app was ad-hoc signed, so macOS may ask for permission again after upgrading from those versions. If the permission state gets confused, reset it with:

```sh
tccutil reset AppleEvents com.github.yteraoka.taffy
```

## Changing the hotkey

```sh
defaults write com.github.yteraoka.taffy hotkey "ctrl+option+t"
```

Restart Taffy for the change to take effect. Modifiers are `cmd`, `shift`, `option` (`opt` / `alt`), and `ctrl`. Keys can be letters, digits, `space`, `return`, `tab`, `f1`–`f12`, and symbols (`,` `.` `/` `;` `'` `[` `]` `-` `=` `` ` ``). If the hotkey conflicts with another app and can't be registered, no shortcut is shown in the menu.

To restore the default:

```sh
defaults delete com.github.yteraoka.taffy hotkey
```

## Known limitations

- With multiple windows of the same browser (e.g. Chrome), the window comes to the front but keyboard focus may stay on the previous window (a quirk of the browser's AppleScript implementation)
- Whether Arc tabs on another Space are listed depends on Arc's AppleScript implementation

## Development

- [Developer guide](docs/development.md) (build, internals, adding browsers, CI) — Japanese
- [Release process](docs/release.md) — Japanese

## License

MIT
