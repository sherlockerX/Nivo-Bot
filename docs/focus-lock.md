# Forced focus on Android

Forced focus is optional and requires Android11 or later. Ordinary focus keeps its start, pause, resume, finish, delete and back-button behavior. This feature restricts application access for a fixed duration. It cannot prevent system force-stop or guarantee recovery after a vendor freezes the process.

## Start a session {#start}

1. Open Focus and its top-right options. Complete Permissions: a connected accessibility service, display-over-apps, usage access, exact alarms and notifications. The page detects an enabled but disconnected service and explains how to turn it off and on again. Battery and autostart settings are recommended separately.
2. Choose Allowed apps before starting. Search includes installed system and background packages; packages without a launch shortcut are labeled. Phone access is always available. Settings, launchers, installers and voice assistants cannot be selected.
3. Choose a countdown, a stopwatch or a timed break, then turn on Enforce this session. The switch starts off. A forced stopwatch runs for up to 12 hours; its screen counts up and has End focus, which asks once, saves the time so far and unlocks the phone. Starting a forced session ends an existing ordinary timer using its measured duration.
4. The existing full-screen focus window shows the title, countdown, background, phone button and allowed-app launchers. There are no pause or finish controls, except End focus on a forced stopwatch. Back does not dismiss an active forced session.

Backgrounds use the existing local upload and selection feature. A manual forced session binds the chosen background before its first screen opens. Wake restoration does not keep the screen on or actively wake the phone. Input-method windows use the current system keyboard identity immediately after a keyboard switch; keyboard settings remain subject to normal app restrictions.

## Lock schedules {#schedules}

Open Lock schedules from Focus options. A plan has a name, enabled state, weekdays, several time periods, a global-whitelist switch and an optional focus title or task. Equal start and end means a full day; an earlier end crosses midnight. A period that crosses midnight belongs to the day it starts: Monday 21:00 to 06:00 ends on Tuesday at 06:00, and the phone stays unlocked until the next start. Single sessions are limited to24hours, including a25-hour daylight-saving day.

Plans can be created, edited, enabled and deleted with revision checks. A plan contributing to an active lock cannot be changed. Missing permissions prevent enabling. If permission is lost at the start, the app notifies once for that occurrence and retries every30seconds while the window remains active. It does not add missed time after a window ends.

Simultaneously active plans merge to the latest end and the most restrictive whitelist choice. A later overlap tightens access immediately without rewriting an existing fixed countdown. When the original timer expires, a still-active later period starts a new fixed segment. This segmented continuation is a deliberate adjustment to reconcile overlap with immutable in-progress deadlines. Continuous transitions remain pending phone validation.

An occurrence is identified by its plan ID, original local date and configured start/end minutes, not its converted epoch or timezone. Completed identities are kept, so clock or timezone changes do not replay them. A segment exceeding24hours is capped and its occurrence consumed; the remaining hour is not automatically locked later.

## Nivo, windows and AI controls {#chat}

During forced focus Nivo itself shows only the lock screen. Chat, settings, files, terminals, other home tabs and deep-linked pages are covered and redirect to focus; Nivo cannot be added to Allowed apps, and an entry saved by an earlier version is ignored.

Leaving for the home screen, opening an app in a small window or split screen, or reaching Settings from the notification shade is caught by window, not only by the app in front. As soon as such a window appears, a touch shield covers it, so icons cannot be long-pressed to uninstall Nivo while the lock screen comes back; the lock screen then returns without an animation. Calls, the current keyboard and allowed apps above the shielded area stay touchable. On Android 12 and later the notification shade is collapsed during forced focus, and a vendor control centre that stays open is swiped closed. The shield reads window packages, types, layers, focus and positions, and fixed control IDs of the system panel; it reads no text or input.

`FocusStore.command` checks the active lock before idempotent command receipts. During forced focus, all five timer actions return `focus_locked`; expired rows settle before this check. `FocusAgentBridge` preserves the code and tells the model not to retry or bypass it.

AI accessibility operations, Hands actions and remote screen capture are suspended throughout forced focus. Each actual action rechecks the persistent lock, including actions after an approval wait.

## Emergency exit and settings {#emergency}

Emergency exit is enabled by default. Hold its entry on the focus screen, wait10minutes, then explicitly confirm. The session stays enforced during the wait and phone access stays available. Leaving or reopening the page does not reset or skip it. The request is bound to its run ID; the final transaction rechecks the run and remaining wait.

The wait uses a monotonic clock. Its remaining amount is saved. After reboot, powered-off time does not reduce this wait, so changing the wall clock and rebooting cannot skip it. A natural focus deadline still ends the session normally. Emergency exit saves actual time and marks the record; it also consumes periods active at confirmation, preventing those overlapping periods from immediately relocking. Later scheduled periods remain enabled.

Focus settings can disable emergency exit after a confirmation. Settings cannot be changed while a lock is active. Without this exit, early release requires system force-stop or restarting and revoking permissions. The single-session limit remains24hours. A second setting controls wake restoration; phone calls and allowed foreground apps take priority.

The statistics page adds measured forced-focus time and emergency-exit counts for its day/week/month/year range. It counts finished, undeleted, non-break focus intervals, including actual time before emergency exit. Emergency exits are assigned by their exit timestamp. Today and history cards show the exit marker. Focus completion never completes a linked task automatically; existing life-fragment links continue to use the same focus sessions.

## Storage, time and restore {#storage}

`MosaicDatabase`version7 explicitly migrates6to7, adding `focus_lock_plans`, `focus_lock_whitelist` and `focus_lock_runs`. The original18tables and `focus_sessions`columns are unchanged. Plans, whitelist and runs are scoped by `ownerKey`, and mutations use the existing account lock plus a Room transaction. Account generation changes hide old observations. Offline accounts use an empty owner key. Removing an account's local data also clears its lock settings, emergency wait and diagnostics; pending diagnostic writes are checked against the account generation.

The fixed deadline equals the original start plus duration. In the same system boot, remaining time comes from a monotonic checkpoint; changing system time or timezone cannot shorten or extend it. Checkpoints write at most every15seconds, except at expiry and explicit settlement. Every interception checks expiry first. Stored focus intervals and lock status settle together to avoid double counting. An observed natural completion is notified by its run identity, including after wall-clock changes and at an overlapping schedule transition.

After reboot or an unknown boot, recovery is capped by both the saved remainder and the fixed wall-clock deadline, then rebaselined. Without a trusted clock surviving reboot, simultaneous wall-clock tampering and reboot cannot be proven equivalent to elapsed real time. Phone shutdown time therefore has a platform limitation; this is not a full anti-tamper guarantee.

Focus JSON exports add a versioned `lock` configuration with plans and allowed apps. Configuration restore merges into the current account, does not import timers, runs or measured time, and leaves all restored plans disabled for review. Active locks reject imports and whitelist expansion. The general `.minisbak`format is unchanged.

## Diagnostics and development {#diagnostics}

Focus settings can copy or clear local diagnostics while idle. At most400entries and64KiB are retained. Records contain action codes, times, package names and window types. The guard never reads node text, control descriptions or typed content and does not upload diagnostics. The existing accessibility service has one metadata-only forwarding line, protected by an integration contract test.

Debug builds retain an ADB safety exit for development. Release source sets have neither its class nor its manifest declaration. Both build types now use the24-hour maximum. The debug exit is not an accepted emergency-exit test and its test records must not be treated as real user evidence.

## Verification and device acceptance {#verification}

P1toP7code is integrated. Stage logs and immutable test-result snapshots establish compilation and logic evidence only. The final report records actual test counts and APK identity. Room instrumentation tests are provided but have not run on a connected device. SQLite migration/schema checks are supplemental evidence and do not replace Android Room execution.

Run the repository checks from `android/src/android/`:

```sh
./gradlew :app:testDebugUnitTest --tests 'io.github.nanomuse.*' --tests 'com.openminis.app.provider.*' --tests 'com.openminis.app.sandbox.*' --console=plain --no-daemon
./gradlew :app:assembleDebug --console=plain --no-daemon
```

P8phone acceptance remains pending. Use two manufacturers, start with2-minute sessions, then test a session longer than1hour:

- Ordinary focus: start, pause, resume, finish, delete and minimize by Back.
- Forced focus: Home, Back, Recents, app notifications and lock-screen shortcuts return to focus; allowed apps and their input method remain usable.
- Open the phone without dialing emergency numbers. Receive, answer and end a normal test call; confirm focus returns afterward.
- Settings, launchers, installers and assistants stay blocked even if old configuration contains them.
- Natural expiry releases access once, notifies and saves accurate time. Swipe away the task, freeze the background process, restart and cover-install to assess vendor recovery and stale accessibility grants.
- Create a plan3minutes ahead for2minutes, wait with the screen off, then test overlap, midnight and missing permissions. Completed occurrences must not replay after clock/timezone changes.
- Ask AI to finish focus and operate Settings. Both must refuse with `focus_locked`.
- In a session longer than10minutes, hold emergency exit, reopen the screen, change the clock and restart. Confirm no early exit is allowed, then finish the wait and check the exit marker and actual time.
- Switch accounts after the session and verify plans, allowed apps, runs and settings remain separate.

Return speed, the touch shield over the home screen and small windows, vendor control centres, vendor background freezes, call handling, accessibility stalls and reboot recovery are all pending real-phone validation. After updating Nivo, turn its accessibility service off and on once so the new settings take effect. This task makes no iOS changes.
