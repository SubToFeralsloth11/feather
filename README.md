# Feather

A lightweight macOS web browser, Chrome-style, built to use far less memory.

## Why it uses less RAM

- **Uses macOS's built-in WebKit engine** (the same one Safari uses) instead of shipping its own copy
  of Chromium. The engine code is shared with the system, so it isn't loaded a second time.
- **Tabs sleep.** A background tab you haven't looked at for 10 minutes (adjustable) is unloaded
  completely, and its page process exits. Click the tab and it comes back on the same page with its
  back/forward history and scroll position. Sleeping tabs show a moon icon.
- **Instant sleep under memory pressure.** When macOS reports low memory, every background tab
  sleeps at once instead of the Mac starting to swap.
- **Lazy tabs.** New tabs, and tabs restored after you relaunch, don't start a page process until you
  look at them.
- **Built-in ad and tracker blocking.** Ad scripts and trackers are a large share of the memory a
  typical page uses. They're blocked natively by WebKit, so blocking itself costs nothing.
- Tabs playing sound, or using the camera or microphone, are never put to sleep. Muted autoplay
  videos don't count.

## Features

Tabs (drag them between windows), address bar that searches or opens URLs, back/forward
(including trackpad swipes), reload, bookmarks (⌘D), history menu, reopen closed tab (⇧⌘T),
private windows (⇧⌘N, nothing saved), find in page (⌘F), zoom (⌘= / ⌘- / ⌘0),
downloads to ~/Downloads, full-screen video, file uploads, camera and microphone prompts,
right-click → Inspect Element, ⌘-click opens a link in a background tab, session restore,
and it can be set as the default browser.

Settings live in the **Feather** menu: ad blocking, autoplay blocking, how long before background
tabs sleep, search engine (Google, DuckDuckGo, Bing), "Sleep Background Tabs Now" (⌥⌘S),
a memory report and Clear Browsing Data.

### Chrome bookmarks

On first launch Feather copies every Chrome bookmark (all profiles, including bookmarks stored in
your Google account) into the Bookmarks menu, keeping Chrome's folders. Run
**Bookmarks ▸ Import Bookmarks from Chrome** any time to pick up new ones; nothing is duplicated.

### 1Password

Click the key button in the toolbar (or ⌥⌘\\) to fill the login for the current site from 1Password.
If the login has a one-time code, the code is copied to the clipboard ready for the next page;
**Edit ▸ Copy One-Time Code from 1Password** (⇧⌥⌘\\) copies it on its own. If several logins match, pick one
from the menu that appears. Feather only fills logins saved for the site you're on, and only in the page's
main frame.

One-time setup:

1. Install the 1Password CLI: `brew install --cask 1password-cli`
2. In 1Password, open **Settings ▸ Developer** and turn on **Integrate with 1Password CLI**.

1Password then asks for Touch ID or your password the first time Feather uses it.

### Shortcuts

| Shortcut | Action |
|---|---|
| ⌘T / ⌘W | New tab / close tab |
| ⌘N / ⇧⌘N | New window / new private window |
| ⌘L | Focus address bar |
| ⌘R / ⇧⌘R | Reload / reload ignoring cache |
| ⌘[ / ⌘] | Back / forward |
| ⌘1–⌘8, ⌘9 | Go to tab N, last tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘D | Bookmark page |
| ⌥⌘S | Sleep all background tabs now |
| ⌥⌘\\ | Fill login from 1Password |

## Build and install

Needs macOS 13 or later and the Xcode command line tools.

```sh
./build.sh            # builds build/Feather.app
./build.sh --install  # also copies it to /Applications
```

To regenerate the icon: `swift Resources/make-icon.swift`.

## Self-test

```sh
build/Feather.app/Contents/MacOS/Feather --self-test [url ...]
```

This runs entirely off-screen: no Dock icon, invisible windows, and a throwaway data folder, so it
doesn't touch your real history or session. It checks address-bar parsing and ad blocking, loads
real sites in tabs, measures memory, puts background tabs to sleep, measures again, wakes a tab and
checks that it comes back on the same page, and checks that private windows aren't saved.
The exit code is 0 on pass.

## Limits

- Chrome extensions don't work (WebKit can't run them).
- A few sites that only test against Chrome may behave slightly differently, just as they would in
  Safari. Feather identifies itself as Safari so sites serve their normal desktop pages.
- Logins and cookies are separate from Chrome and Safari; sign in again once.
