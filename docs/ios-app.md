# ousage for iPhone

A native iPhone app and home screen widget that show the usage ousage collects on the Mac.

## Decisions so far

- iPhone only (no Android).
- Native Swift/SwiftUI, in the existing Xcode project.
- Data moves from Mac to iPhone through iCloud (CloudKit, private database). No server.
- The app shows usage too, not just the widget.

## Why the Mac does the fetching

The phone can't fetch usage itself. Every provider depends on something only on the Mac:

| Provider | Source on the Mac |
| --- | --- |
| Claude | Claude Code login (Keychain or `~/.claude/.credentials.json`) |
| Codex | `codex` binary or `~/.codex/auth.json` |
| Cursor | Cursor's local database or Keychain |
| Grok | Firefox cookies, Grok CLI login (`~/.grok/auth.json`) |
| OpenCode, OpenRouter | API keys in Keychain or local files |

Copying OAuth logins to the phone is ruled out: if the phone refreshes a token, it can sign the CLI out on the Mac.

## How it works

```
Mac (ousage) ── fetches usage ──► uploads summary to iCloud
                                        │
iPhone app + widget ◄── read summary ───┘
```

1. **Mac uploads.** After each refresh, ousage saves one record per provider to iCloud: percent used, reset time, last-updated time.
2. **Widget reads.** The widget fetches the latest records from iCloud and draws them, without the app being open.
3. **App reads.** The app shows the full list, like the Mac popover, with pull-to-refresh.
4. **Shared code.** Models, icons and the list design are shared between the Mac and iPhone targets where possible.

## Keeping the widget current

iOS decides how often a widget refreshes in the background (roughly every 15–60 minutes, at Apple's discretion). Ways to update it sooner:

| Method | How | Notes |
| --- | --- | --- |
| Open the app / pull to refresh | App fetches from iCloud, then reloads the widget | Core feature |
| Refresh button on the widget | Interactive widget button (iOS 17+) | Core feature |
| Automatic push | iCloud notifies the phone when the Mac uploads | Later. iOS limits these; not guaranteed |
| Ask the Mac to refresh | Phone requests a fresh fetch from the Mac | Later. Only works if the Mac is awake |

The widget shows "updated X ago" and counts down to reset times on the device, so it stays useful while the Mac is asleep.

## Limits

- Data is only as fresh as the Mac's last upload. If the Mac is asleep, the phone shows the last numbers it uploaded.
- Refreshing on the phone does not make the Mac fetch new data (unless "ask the Mac to refresh" is built).

## Requirements

- **Paid Apple Developer account.** Needed for iCloud, and for an install on the phone that lasts more than 7 days.
- **Signing.** The Mac app must be signed with the team and an iCloud container for iCloud to work.
- **No sandbox.** The Mac app is currently unsandboxed (`ENABLE_APP_SANDBOX = NO`) and must stay that way to read the CLI logins.

## To confirm before building

- [ ] Is team `36D6XL42WL` a paid developer account?
- [ ] Does CloudKit work in the unsandboxed Mac app as it's built and installed today? Test this first.
- [ ] Which providers should appear on the phone? All of them, or a chosen subset?
- [ ] Which widget sizes? Small, medium, Lock Screen?
- [ ] What fields does each record need beyond percent used, reset time and last updated (for example, OpenRouter's balance, or several limits per provider)?
- [ ] Minimum iOS version (the widget refresh button needs iOS 17+).

## Build order

1. Mac: upload usage records to iCloud.
2. iPhone app: read and show the records, with pull-to-refresh.
3. Widget: read the records, with a refresh button.
4. Optional: automatic push updates, "ask the Mac to refresh".
