# Working while the Mac is locked (not built)

Agents can't use BCU while the Mac is locked. We decided on Nov 2 2026 to leave this out for now. This note is how we'd do it later.

## What breaks while locked

Seen on macOS 26.6.2 with the screen locked and the displays asleep:

- Some apps report no windows to Accessibility. Windows App's `AXWindows` was empty even though CGWindowList showed its session window on screen. T3 Code's window was still listed.
- `open_window` failed for Finder (an AX menu press) and Windows App (cmd+N). No new window appeared.
- `screencapture -l <window>` failed. BCU's own capture path (`SLSHWCaptureWindowList`, then ScreenCaptureKit) wasn't tested.
- The virtual display could be created, but `CGConfigureDisplayOrigin` failed with CGError 1014. Displays released while the screens slept weren't removed until they woke.

Not measured yet: whether posted events (`CGEventPostToPid`, `SLEventPostToPid`) and AX actions reach apps while locked.

## How Codex does it

Codex doesn't work through the lock. It unlocks the Mac for a moment, covers every screen while it works, and locks again on any keyboard or mouse input. ([docs](https://learn.chatgpt.com/docs/computer-use#locked-use))

- Turning on "locked use" installs an Apple authorization plug-in, `CodexComputerUseAuthorizationPlugin.bundle`, in `/Library/Security/SecurityAgentPlugins/`. During a computer-use turn, it authorizes one short unlock.
- `CUALockScreenGuardian.app` covers the screens and relocks the Mac. Both ship inside `ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/`.
- Known problems: it broke manual Touch ID unlock ([openai/codex#39534](https://github.com/openai/codex/issues/39534)) and sometimes failed to relock ([#26415](https://github.com/openai/codex/issues/26415)).

## How we'd build it

1. **Measure first, on the test Mac.** Use a test app of our own that counts the events and AX actions it receives. Try each BCU operation unlocked, locked with the screens on, and locked with the screens asleep: AX reads and actions, both event-posting paths, each capture path, and opening windows. If enough works through the lock, we may not need to unlock at all.
2. **Authorization plug-in.** An Apple authorization plug-in ([Apple docs](https://developer.apple.com/documentation/security/extending-authorization-services-with-plug-ins)), signed with our Developer ID and installed once with an admin password. It grants one short unlock per agent request.
3. **Cover screen before unlocking.** A full-screen cover on every display goes up before the unlock, including displays plugged in mid-task. Any keyboard or mouse input, a timeout, a cancelled task or a crashed helper locks the Mac again right away. Check that the Mac actually relocked; don't assume it did because the helper exited.
4. **Only real agent actions can unlock.** Each unlock is tied to one short request from an agent action. Any program that can talk to the BCU socket must not be able to unlock the Mac.
5. **Rerun the normal checks after unlocking:** where the virtual display is, fresh captures, AX access, and input actually arriving.

## Risks

- The desktop is reachable for a moment while the user is away.
- Breaking the user's own unlock (Touch ID, password).
- Failing to relock. Codex has had this.
- Changes to the login authorization flow in new macOS versions.
