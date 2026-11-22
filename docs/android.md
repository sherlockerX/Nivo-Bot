# The Android app

## Local mode

This Android build runs without a nanoMuse account. Built-in sign-in and account verification, the nanoMuse Cloud model relay, remote-device hub and conversation/profile sync are disabled. Add your own API endpoint or supported provider OAuth account under Settings → Models. Your own MCP servers, connectors, network proxy and other third-party services remain available and connect to their configured services.

First-run setup can be skipped in both Debug and Release builds, and that choice survives a restart. The app removes fixed project website, GitHub, Star, issue-report and GitHub skill-directory entry points. Skill import from a file or a URL you provide remains available. The About page keeps its GPL license information.

Built-in provider lists exclude catalogue entries marked `is_relay`, including OpenRouter, SiliconFlow, OpenCode, Standard Compute and CheaperInference. Existing configurations and OAuth credentials remain usable; you can still configure your own compatible endpoint. Old allowance messages now lead to provider settings without invitations, project links or relay recommendations.

Within an existing app data container, local mode preserves the current data owner, chats, task records, files and provider configuration. Existing built-in Cloud providers are disabled and hidden from provider settings; their IDs, keys, models and group bindings are retained so old records are not deleted or reassigned. If a chat still refers to an old Cloud model, select your own provider before sending. Existing account archives remain stored without being merged into the current workspace. Fresh installations use the local owner.

The current Nivo Android source uses `io.github.nivo`. Published Android `2.0.9 (60)` uses `io.github.sherlockerx.nelan`; earlier releases use `io.github.nanomuse.app`. Android gives each ID separate storage, credentials and permissions. Keep your existing installation when trying a different ID. The [migration notes](releases/v2.0.9.md#moving-from-the-old-android-package) list the supported transfers: the general backup does not transfer daily fragments/photos, Coach progress, focus history or custom pets.

In chat, three stars pulse while waiting for a reply and beside active reasoning. A running tool has its own status. When the reply arrives the stars disappear; with system animations disabled they remain still.

The process summary sits above the answer, aligned with it on the left and only as wide as its text: a thin outlined card with an icon, the title (Thinking or Thought process when only thinking happened, Thinking and working or Thinking and execution when tools ran), the number of tools and an arrow; while it runs, a second line names the current step. Tapping it opens the steps as a timeline: each step has a node (a light bulb for thinking, a dot for notes, and for tools a spinner, a tick, a cross or a dash for running, done, failed or cancelled) joined by a thin line, and tool details, Stop and the first/latest-step controls remain. Long thinking steps in the timeline show their first three lines with *Show all*; the thinking being written stays open and folds when it ends, and an expanded one folds again with *Show less* (on iPhone, with the chevron on its title). Expanded thinking has a plain left-aligned title and a thin rule beside its text, and the waiting indicator shows only the stars and its text. Text uses the theme's secondary colour and only running icons use the accent colour, in light and dark mode alike.

Android automatic cloud backup is disabled with `allowBackup="false"`. User-initiated export/import and user-configured backup destinations remain available. Reinstalling does not restore chats from the former account service; keep a manual backup before uninstalling.

## Personal tasks

Open **Tasks** below **Ideas** in the chat drawer. The upper-right menu opens Calendar, Priority matrix, Groups, Status and Completion statistics. Create a task with a title, then optionally add notes, a planned date, a due date, one group and multiple tags. Important and urgent are explicit choices. A due date does not create a reminder or scheduled AI run.

Tasks use a shared light/dark palette, status summaries and compact search. The floating quick-add capsule uses the same canvas and bottom fade as Ideas; the list reserves its measured height, including multi-line input and the keyboard. Tap the task's status control to complete or reopen it, or the capsule's options icon to open the full editor. Calendar dates are selectable and clearable; large text uses a scrollable date strip. The priority matrix opens each quadrant's task list. Task details and editing use scrollable bottom sheets.

Groups and tags now have a saved directory. In the editor, tap Group for a single choice or Tags for multiple choices, search existing names, or explicitly create a new name. Created names stay available even when you cancel the task editor or delete the task. The upper-right **Groups and tags** module lets you create categories before using them. Empty groups also appear in the Groups view. Existing task categories are collected during the database upgrade; model-created tasks use the same directory.

Local task backups now use format version 2 and include unused groups and tags. Import still reads version 1 and rebuilds its categories from imported tasks. Directory names belong to the current account and are cleared when that account’s local data is discarded. Task completion tag snapshots remain unchanged. Native chat tools can query `kind: "categories"` with search and pagination before reusing a name.

The main chat can query, create and update these same tasks through native tools. Completion requires an explicit report in the current user turn. A tool reports success after persistence; ordinary generated text does not create a task. Task management also works directly in the app without a model.

Mutations check `expectedRevision` both at the tool boundary and inside the database transaction. A mismatch returns `code: "stale_revision"`, the task ID and the expected/current revisions without changing the task or its history. Query the latest task before applying an updated request. An exact retry of an already successful `operationId` returns its original result; it does not write again or replace later edits. Reusing that ID for different content is refused. Search matches current content and task IDs; `dateField: "created"` filters the creation date in the device's local timezone. Old titles are not indexed.

External prompts from Ideas, profile and device actions preserve an occupied chat composer, including edits, attachments and pasted text. They open the chat for review rather than sending or replacing the draft. Tapping an idea inside the chat explicitly appends it and leaves sending to you. Hidden chats pause streaming presentation work and resume from the latest state when shown; model execution and saving continue.

In a daily fragment, choose linked tasks and select Link only, In progress or Completed. Completion has its own date, which can be backdated when recording an earlier activity. The draft keeps the selection. Saving the fragment and changing the tasks happen in one transaction; a conflict keeps the draft for review. Reopening a fragment does not replay its old status changes. Deleting a fragment keeps the task; deleting a task preserves existing fragment snapshots.

Completion statistics show day, week, month and year distributions using completion dates and tag snapshots saved at completion. Each task has weight one, split equally among its tags; untagged tasks form their own slice. The chart shows tag share and the number of related tasks. It measures completed items, not time or effort. Reopening or deleting a task removes its contribution, including from past periods. Tap a slice or legend to review its tasks and linked fragments.

Tasks and their links belong to the current local account. Existing daily fragments retain their device-local storage behavior. The upper-right menu exports and imports a versioned local JSON backup including tasks, state history and replay records. Existing IDs keep local edits; the result reports missing fragment links. Photos are not included. This is separate from the general app backup and does not enable cloud task sync.


## Coach exploration

The Coach page uses the chat canvas and compact upper-right actions; course and practice pages show themed vector scenes: bamboo for principles and judgment, a round-table debate for perspectives, an exchange window for English, a speaking stage for expression, a shared workbench for leadership and a trail for execution. Custom courses use a compass. The illustrations are drawn locally and do not animate continuously.

The Coach page opens on a list of your skills. When a lesson is unfinished, a card at the top continues it. Each skill card shows the current unit, how many units are demonstrated and today's status (in progress, done today, unfinished, paused, needs review); *Add a skill* opens the course library, where you design a new skill with AI and review drafts and sources. Tapping a skill opens its profile: progress and the pause or review actions, today's training, the units to learn as a checklist (a tick for each demonstrated unit, a marker on the current one; tapping a unit shows its focus, method and criteria, and on the current unit the reason for the next step and the plan's concepts and material), current performance and past lessons by date. The header holds two actions on the list, the training calendar and Coach settings; every other page shows a back arrow. Only the training button opens a conversation. Progress comes from saved evidence; viewing the page never marks a unit complete.

*Coach settings* says what the lesson-preparation agent does and what it cannot do, turns it on or off (off means lessons use the course's basic exercise without a model call), chooses its model (the chat's default unless you pick another text model) and sets the default lesson length. It also lists the skills each course loads with their versions, the last five preparations with the model, number of calls, time taken or the reason the basic exercise was used, and links to the course library, the training calendar and the legacy training settings.

Local Nicholasx builds: [provider setup, timing, sandbox and CLI fixes](android-local-fixes.md).

`android/` is nanoMuse for the phone: [OpenMinis](https://github.com/OpenMinis/OpenMinis)
1.13 (GPL-3.0): a native app whose agent runs **on the phone**, with a Linux shell, a
browser, MCP servers, skills and scheduled tasks inside the APK, with nanoMuse's own
identity, design and features on top. Everything of nanoMuse's lives in
`io.github.nanomuse.*`; edits inside OpenMinis files are marked `// nanoMuse:`. The
application ID is `io.github.nivo` and the URL scheme the system knows the app by remains
`nanomuse://`, distinct from OpenMinis. Older packages also handle this external scheme;
the system may ask which installation should open a link.
Inside the app, links stay `minis://…` (upstream's vocabulary, shared with the sandbox,
the system prompt and the model), a `nanomuse://` link arriving from the system is read as its
`minis://` form, and every link of the app's own that the app opens itself is addressed to
`MainActivity` by name, never resolved by the system
(`io.github.nanomuse.deeplink.OwnScheme`). The sandbox's offload socket, the abstract socket
proot talks to the app through, is the app's own too: `io.github.nivo.native-offload`
rather than upstream's `native-offload`, since abstract sockets are one namespace for every
app on the device and whichever app bound the shared name second would die at start; when
even that name is still held by a previous process of ours, the server binds a per-process
name and tells proot that one (`io.github.nanomuse.sandbox.OffloadSocketName`). The
history of this choice is in [roadmap.md](roadmap.md); what came before it (a WebView
around a Python server, two APK flavours) is kept as a design record in
[archive/android-python-line.md](archive/android-python-line.md) and is not what you
download today.

The release targets arm64-v8a, Android 8.0 / API 26 or newer, with `targetSdk` 35.
The [2.0.10 (61) release notes](releases/v2.0.10.md) identify the current APK. Android installs it alongside older packages.

The task interface shares light and dark cards, status summaries and compact search. Capture a task from the fixed list composer, or complete and reopen it from its status control; unfinished tasks appear first. Other views use a compact add action. Details and editing use a scrolling bottom panel with calendar date selection and clearing. Large text uses a scrolling date strip, quadrants select one readable result list, and the chart places the completed count at its centre with selectable tag rows.

## Install

1. Use this branch's [release page](https://github.com/sherlockerX/Nivo-Bot/releases) and
   verify the APK against that release's checksum file. Check the
   [migration guide](https://nivo.8666886.xyz/install.html#android-migration) before removing an older installation.
2. Open it. Android asks once to allow installs from your browser or file manager.
3. **Add your own model.** Open **Settings → Models** and add an API key, a compatible endpoint or a supported provider OAuth account. Configure **Chat**, **Operating the screen**, **Making pictures** and **Making clips** according to the provider's capabilities. A provider group shows eight models until you tap *Show N more*; the search field filters larger lists by model ID or name. Choosing a chat model applies to the main chat and new chats; existing side chats keep their selection. The other three pickers offer *Automatic*. If no usable provider is configured, the app asks you to choose one before sending.

4. Optional: the two permissions that let the agent use your phone's apps (skippable and
   revocable). *Settings → Hands* keeps its row for the screen model, which opens the same
   picker; *More picture and clip options* at the foot of the Models page is the old *Image &
   video models* page (typing a model name, what stops without each model, re-checking which
   video models a key can use), also at `minis://settings/media`.

**Use it for.** When a provider of your own is saved, a new one or a key added to one that
had none, a card asks what this key should handle: one switch per capability the catalogue
gives the vendor (chat, operating the screen, making pictures, making clips), all on. *Use
it* switches the ticked rows to this provider, each on the catalogue's default for that job
(`defaults.chat` and friends in `providers.json`), or on the first model of its list that
fits when the default is not there; *Not now* changes nothing, and so does an unticked switch.
The other model choices stay as they are. The page is the place to change it later.

**When you have not chosen.** Chat uses the first usable provider of your own. The screen, pictures and clips follow that provider when it supports the required capability, otherwise another configured provider that does. Explicit choices take precedence. Built-in Cloud is excluded from these choices and cannot be used to retry a failed request. Configure a local model server or a third-party gateway as your own provider when needed.

## What the phone does

Shell progress updates preserve text beyond a shorter rewrite. Terminal color and title codes are removed before those updates, so they cannot leave escape fragments in the output.

The agent's system prompt keeps its safety, tool and phone-operation instructions in a stable
prefix. Session-dependent material—skills and MCP metadata, model/device state,
conversation-specific steering, memory and `USER.md`—is appended in a deterministic suffix, with
the date, language and available-model count in its final runtime-context section. Updating memory
or crossing into a new day therefore leaves the static prefix available to providers that support
prefix caching.

| | |
| --- | --- |
| **The agent, on the phone** | A sandboxed Alpine Linux, a real shell, files, a browser, MCP servers, skills in the Agent Skills format, memory, scheduled tasks; approvals before deleting, sending or paying. Models use your configured providers; the built-in project relay is disabled. |
| **Hands** (`hands/`) | With *Hands* on and the accessibility service enabled, the agent looks at the phone's screen and taps, types and swipes in its apps: the last rung after APIs, fetches and the browser. A stage over the app shows where it is about to tap and a capsule with the step and **Stop**; a glow breathes along the screen's edges (blue working, amber waiting; 2.4 s in, 2.4 s out, like every working light on every client since round 9: nothing runs round the rim or slides down the screen, and the capsule's ring and bars breathe at the same pace; everything holds still under the system's reduce-motion setting); when a tap would send, post or delete, the capsule itself asks (**Allow** / **Deny**, the same request the chat card and the notification show), so you are not pulled back into nanoMuse (money is confirmed with the screen lock in the chat card; the capsule offers *Open* for that one); the capsule only ever answers its own request, never a shell or browser card of another conversation, and **Stop** while a card is waiting denies it and ends the run at once. Passwords and codes are always yours to type. The same action a third time on a screen that did not change gets a line in the history so the model changes tack, and a sixth ends the run as *infeasible* with the action named (`HandsLoopWatch`, the floor the runtime has too), instead of one model call per step until the thirty-minute limit. Every step's screenshot is written next to the run's trace under the session's `attachments/hands/<run>/`; the ten newest runs keep all of theirs, an older run keeps its trace and the last screen (the one the chat shows), and past 200 runs the oldest is removed (`HandsTraces`). [gui.md](gui.md) is the design record; the app's own hands are in `io.github.nanomuse.hands`. |
| **The browser handed over** (`browser/`) | A page that needs you (a login, a verification code, a payment, a CAPTCHA) is handed over instead of described: `browser_use`'s `hand_over` action opens the agent's own tab (same WebView, same session) in the browser sheet with the agent's hold released, a **Your turn** card above the composer says what the page asks of you with *Open the page* and *Done, continue*, the sheet carries the same line and button, and the tool call waits for *Done* (fifteen minutes at most) before the agent goes on from the page as it is. `io.github.nanomuse.browser.BrowserHandOver`. |
| **Connectors** (`connectors/`, `ui/connectors/`) | The services the agent can be let into: the desktop's catalogue of 75 remote MCP servers (Notion, Linear, GitHub, GitLab, Slack, Stripe, Miro, …), shipped as `assets/nanomuse/connectors.json`. The only Settings row for all of this is *Connectors*; the upstream MCP editor (by address, by command, imported JSON) is *Your own servers* at the end of the page. Open servers add with a tap; a key service takes the key; an OAuth service runs the MCP authorization flow (discovery, dynamic client registration, PKCE in a Custom Tab) and the token goes into the entry's `Authorization` header for the in-guest MCP client, refreshed at app start; a service whose authorization server registers no clients (`clientIdRequired`: GitHub, Slack, Discord, HubSpot, Render, Bitrise, PagerDuty, Box) asks for an OAuth client id and secret made at the vendor's developer page with the app's callback address, which the sheet shows and copies. A connected service is an MCP server entry under the same id; *Your own servers* manages it too. Connections are managed on this phone. Built-in profile sharing and the list of connections from other devices are disabled. |
| **The chat, plain** | While the agent works, the line under its avatar names the step under way (*nanoMuse is using Shell*, *Writing the reply*, *On it: book the table*), never a state of mind. The tool pills, the Computer sheet and the floating step bar are **on by default** since 0.1.37; *Settings → Appearance → Show the agent's steps* turns them off. With them on, a finished step reads *nanoMuse used Shell · Done*, and its sheet closes on ×, swipe or Back. |

The chat sits on the same canvas as the pill bar, the menus and the drawer: pure black in the
dark theme, pure white in the light one. Your messages are white pills with black text (black
pills with white text in light), the agent's replies sit in a pill a shade off the canvas
(`#1C1C1E` / `#F2F2F7`), and the send button and the scroll-to-latest disc are white with a
black arrow (inverted in light); there is no blue in the conversation apart from links. The
header is not a bar but a scrim: the conversation scrolls under it and dissolves into the
canvas, and a second fade appears at the top edge while you read older messages. The palette
is upstream's `com/openminis/app/ui/theme/ChatColors.kt`, written by `scripts/rebrand.py`.

The message composer stays above the floating navigation pill, and the pill is as wide as the
composer (the same 16 dp margins; 420 dp at most, centred on a wider screen), so the two
capsules stack with one edge. While the agent uses tools,
the step bar sits above the composer; the latest message and tool pills can scroll fully
above both. The conversation still scrolls behind the navigation pill for its frosted blur.
The spacing follows the actual footer height when the composer expands or a tool preview
or approval card appears. The approval card itself takes at most two thirds of the screen:
a command longer than six lines is folded behind *Show all*, the description and the
preview scroll in the middle, and Allow and Deny stay in view at the bottom. When reading
older messages, a slightly lighter fade follows
the composer's rounded outline. Live browser controls hide it; historical tool pills and
other tools keep it. In dark-mode home and side chats, pure black surrounds the navigation
pill and fills the gap below the composer. Its glass stays open to the scrolling content
for live frosted blur. Other tabs keep their navigation appearance. With the keyboard
open the composer sits on the keyboard and the pill is behind it. The Feed, Ideas, Goals and
Library lists end above the pill as well, so their last row is never under it.

The desktop and web products are documented separately in [desktop.md](desktop.md) and [brand.md](brand.md). This local mobile build does not join their account or device hub.

Under **Settings → Appearance**, the font-size labels for **Chat Input**, **Message Text** and **App Base** follow the app's language.

## Your own key

The vendors the app knows are one file, `assets/nanomuse/providers.json`, a copy of the
runtime's `nanomuse/llm/providers.json` written by `node scripts/providers-json.mjs`, the same
catalogue every client reads ([own-key.md](own-key.md)). Each entry says where the endpoint is,
where a key is made, which sign-ins it has, where it signs people up (`cn`, `global`) and what
its models can do: `chat`, `vision` (the hands' screen), `image` (pictures), `video` (clips).

**Adding a provider.** Settings → Models → Add a provider opens the supported provider forms. Configure your API key and endpoint or use an available provider OAuth flow. Provider presets supply their name, endpoint and `/v1` setting (`minis://settings/providers/add?preset=<id>`). OpenMinis' `OpenAIOAuthManager`, `ClaudeOAuthManager`, `KimiOAuthManager` and `OpenRouterOAuthManager` remain the provider authentication adapters. Their availability depends on the provider and build configuration. Anthropic and Gemini use their own provider types; other compatible endpoints use the OpenAI form.

The Claude sign-in needs an identifier Anthropic expects at the start
of every request; it is read at build time from `app/provider-customization.properties`, which
is not in this repository, so the published APK does not have it. A build without it does not
list the Claude sign-in (not on this card, not under *Add a provider*, and `?preset=anthropic:oauth`
opens the API key form), and a Claude sign-in saved by an earlier build answers each send with
*This build cannot use a Claude sign-in. Add Anthropic with an API key instead.* rather than
closing the app (`io.github.nanomuse.cloud.ClaudeSignIn`).

**Where the list comes from.** Provider presets use the bundled `assets/nanomuse/providers.json` catalogue. The app does not refresh account guidance from the retired relay.

**What each covers.** The capabilities decide what the app offers (`cloud/Capabilities.kt`):
pictures (Settings → Models → Making pictures, the avatar studio, `nanomuse-media image`) pick a
provider only among those whose vendor has `image`; clips among those with `video` that the
app can drive (Bailian's video API); the screen's model and its picker list only models of
vendors with `vision`. A ChatGPT plan signed in through Codex is chat and vision (the Codex
backend has no image or video endpoints), so it is never offered for pictures. A vendor the
catalogue does not know (a gateway or a model server of your own) is taken at its
models' word, as before. When no configured provider has a capability, the page says so in one
sentence (*Pictures need a provider with image models: Bailian, OpenAI, Gemini or
OpenRouter.*) instead of failing.

In the avatar studio, asking for a new set of candidates replaces the previous set. A picture
or failure that finishes from the previous request cannot change the new set's tiles or files.
Again starts the new request without waiting for the old picture to finish saving.

**When the provider cannot be reached** (`net/ProviderReach.kt`, `ui/chat/ProviderReachCard.kt`).
A failed turn whose error is the transport's (OkHttp's *failed to connect to chatgpt.com/… (port
443)*, *Unable to resolve host*, a TLS or timeout line) or OpenAI's *region not supported* is
shown as a card instead of the red banner: what happened, what helps (a VPN on this phone, the
proxy under *Settings → Network*, another provider with a key of your own), *Try again*, and the
raw line behind *Details*. The 401/403/429 whose bodies upstream's `mapHttpError` drops are
kept for a few seconds by `ReachSignal` (one `// nanoMuse:` spot in `OpenAIProvider`) and
written into the message as a canonical `nm_reach:` line, so an expired ChatGPT sign-in reads
*Sign in again* and a spent plan window reads *The ChatGPT plan has nothing left for now* with
OpenAI's own sentence and the reset time; a plain *Invalid API key* on a key provider stays
upstream's.

**Provider refusals.** The app retains local error formatting and stored error messages from older chats. A provider's content check is reported as such and is not retried by splitting the same content into smaller requests. The former built-in relay cannot accept new requests, and its sign-in or Cloud retry actions are unavailable.

Before any of these reaches the chat, a failed model request is retried on the same model up to six times, waiting 1, 2, 4, 8, 15 and 20 seconds, and the reply shows *retrying (n/6)* meanwhile. This covers dropped connections, timeouts, 5xx, 429, streams that stop with nothing in them and other provider errors, at every step of a task, including the steps between tool calls. It does not retry what another try cannot change: a stop by the person, a rejected key (401, 403), a content check, a model that does not exist and other 4xx answers about the request itself. Only then does a model group move to its next model, or the chat show the error. The rule is `ModelRetryPolicy`; unit test `ModelRetryPolicyTest`.

**Settings → Network** (`net/OwnProviderProxy.kt`, `ui/net/NetworkScreen.kt`,
`minis://settings/network`). The HTTP proxy for own providers: host, port, optional user name
and password, off by default, on this phone only: the settings in `SharedPreferences`, the
password in an `EncryptedSharedPreferences` file of its own (`nanomuse_proxy_secrets`, the way
the provider keys are kept; a password a 1.0.3 phone saved in the plain file is moved over on
the first read). It is installed in
`MinisApp.onCreate` as the process's default `ProxySelector`, so every OkHttp client asks it per
request; it answers the proxy for the catalogue's hosts, `chatgpt.com`, `auth.openai.com` and
the custom base URLs of the provider instances (never the relay's, never a LAN address), and the
system's answer for every other host, including sandbox mirrors.
Provider clients carry `OwnProviderProxy.authenticator` for a proxy that asks for a password.
*Test* fetches `https://chatgpt.com/` through the proxy as entered and reports the status and the
milliseconds. Unit tests: `ProviderReachTest`, `OwnProviderProxyTest`.

Leaving the Network page ends its pending request, even if the server has
started to answer but has not finished sending the response.

## Voice input

On Android 13 and later, continuous system dictation keeps feeding audio when the recognizer
starts its next segment. A write that fails on the previous segment's closed pipe cannot
disable the new segment's audio stream.

Provider voice input returns to idle when a silent session reaches its limit or a very short
utterance expires without enough speech to transcribe. A transcription already in progress
still delivers its result before the session finishes.

System voice input can prefer on-device recognition. If the phone has no usable on-device
service, it falls back to the default recognition service. A language error from that
default service is shown in the voice panel. A running on-device recognizer whose language
pack is unavailable still falls back once to the default service.

The voice detector releases its allocated recorder if recording cannot start or is cancelled
before capture begins. You can retry voice input without leaving that recorder allocated.

## Privacy and permissions

Chats, memories and local records stay in the app's storage. Model requests and connector actions still send the necessary content to the services you configure. Provider keys and the Network proxy password use encrypted preferences. The app disables Android automatic cloud backup with `allowBackup="false"`; user-initiated backup and restore remain available. A reinstall starts without the former account's cloud restore.

Hands requires the optional accessibility and overlay permissions, which can be revoked. Actions that send content require approval, and approvals scoped to a chat remain tied to the app or address you approved. Agent file paths are resolved within the sandbox (`io.github.nanomuse.sandbox.SandboxPaths`), rejecting traversal or symlinks outside its root.

The app allows plain `http://` only for addresses on your own network (the private ranges
`10/8`, `172.16/12`, `192.168/16`, the carrier-grade `100.64/10` Tailscale hands out, link-local,
IPv6 ULA, `localhost`, a name without a dot, and the suffixes `.local`, `.lan`, `.home`,
`.internal`, `.home.arpa`, `.localdomain`, `.ts.net`), a model server or a computer of your own,
and refuses it at the provider URL field for anything else (`io.github.nanomuse.net.LanOnly`).
The address is parsed before it is judged, so a public name such as `10.foo.example.com` is
not taken for a private address. The in-app web view is not exported
to other apps. Voice input through a provider's speech model keeps the microphone open only
while a recording is on: stopping or cancelling the recording closes the recorder at once, and a
cancelled recording's audio is dropped, never sent to the provider.

## Building it yourself

JDK 17 or 21 (CI uses 21) and the Android SDK (Android Studio installs both); `scripts/android/env.sh` sets
the environment on a bare machine. The project is under `android/src/android`:

```bash
bash scripts/android/build-natives.sh   # once: proot, the Alpine rootfs and rclone.aar (NDK r27c, Go 1.25+)
cd android/src/android
./gradlew :app:assembleDebug        # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assembleRelease      # signed with android/keystore.properties when present
./gradlew :app:testDebugUnitTest --tests 'io.github.nanomuse.*'   # our unit tests
./gradlew :app:lintDebug            # Android lint; the report is app/build/reports/lint-results-debug.html
```

Lint runs on a newer lint than AGP 8.7.3 bundles (`android.experimental.lint.version` in
`gradle.properties`): the Compose and lifecycle libraries ship checks the bundled one cannot
load. The upstream tree carries lint findings of its own; read the report for `io.github.nanomuse`.

`rclone.aar` is built with Go, which fetches its modules through Go's default proxy
(`https://proxy.golang.org,direct`); on a mainland-China network set
`export GOPROXY=https://goproxy.cn,direct` first, and `env.sh` keeps whatever you exported.

`scripts/rebrand.py` carries the version (`VERSION_NAME`, `VERSION_CODE`) and applies
nanoMuse's naming to the OpenMinis tree; `android/BUILDING.md` covers the native pieces.
Without a signing key the release build is signed with the debug key, which installs but
cannot update a properly signed build. To sign, create a key once and keep it outside the
repository:

```bash
keytool -genkeypair -keystore ~/.nanomuse-release/nanomuse.jks -alias nanomuse \
        -keyalg RSA -keysize 4096 -validity 10950
```

and put its four values in `android/keystore.properties` (git-ignored: `storeFile`,
`storePassword`, `keyAlias`, `keyPassword`).

The chat-only emulator build (`-Pnm.abi=x86_64`) excludes cached arm64 proot and Alpine root filesystem assets. Switching back to the default arm64 build includes those assets again; no cache deletion is needed.

## Releases

`.github/workflows/android.yml` builds the debug APK on every change under `android/`
(the "debug APK · arm64-v8a" check). A release is made from a tag by
`scripts/release-apk.sh <version>`: it checks the version against `rebrand.py` and
Gradle, builds `:app:assembleRelease` with the release key, writes
`dist/nanoMuse-<version>-arm64.apk` and its `.sha256`, and with `--publish` tags
`v<version>` and attaches both to the GitHub release with the notes from
`docs/releases/v<version>.md`. Publishing refuses a working tree with uncommitted changes
and a commit that is not on `main`. A debug-signed APK never goes on a release, because it
could not be updated by a properly signed one. The `versionName` must match the tag,
like the Python package's version does.

## Where things are

| Path (`android/src/android/app/src/main/java/io/github/nanomuse/`) | Does |
| --- | --- |
| `cloud/NanoMuseCloud.kt` | Compatibility data shapes and local error formatting; built-in account requests fail locally without networking |
| `cloud/Region.kt`, `cloud/ProviderCatalogue.kt`, `cloud/Capabilities.kt`, `cloud/OwnKeyPresets.kt`, `cloud/ProfileSync.kt` | Own-provider catalogue, capabilities and preset forms; profile sync initialization and pulls are disabled |
| `sync/` | Retains local chat ownership and migration metadata; `ConversationSync` does not create a network engine or lifecycle polling |
| `account/`, `local/` | Existing ownership and archive safeguards; `LocalOnlyMode` saves a stable local owner and freezes the former built-in Cloud provider without deleting its records |
| `hub/` | Compatibility types retained; automatic startup and connections are disabled, and `HubService` is no longer registered in the manifest |
| `reach/` | Legacy remote-computer code retained for compatibility; the device hub and computer routes are disabled |
| `models/` | Settings → Models behind the screens: `ModelSlots` (the four slots, what each is set to and where that is kept, the groups a picker shows, `followPick` for the chat default, `applyProvider` for the *Use it for* card), `SlotOrder` (the resolution order and the catalogue default, pure Kotlin, unit-tested), `PickerList` (the picker's eight-row groups, their order and the search filter, pure Kotlin, unit-tested) |
| `ui/models/` | The Models page, the picker behind each row, the *Use it for* card (`minis://settings/models`) |
| `chat/CloudRetry.kt` | Legacy error support; built-in Cloud retries are unavailable because the app never signs into that service |
| `chat/RoutineWakes.kt`, `ui/chat/NmRoutineWakeRow.kt` | A scheduled task's turn is the routine's, not the person's: `ScheduledAgentRunner` arms a wake before the prompt goes out, `ChatViewModel` binds it to the persisted row, and the chat draws that row as one quiet line, *Routine · 〈label〉 · 08:00*, instead of a bubble in the person's voice; the model gets a one-turn `SessionAddenda` saying so, so it opens with the result rather than thanking anyone for asking. Up to 1.0.4 the prompt stood in the chat as if the person had typed it |
| `feed/` | The Feed: `FeedFlow` keeps the daily scheduled task and the conversation it writes in, which is the agent's working room and stays out of the drawer, the chat list and the main-chat fallback (`FeedFlow.hidden`, read by `ChatRepository.observeSessions()`, `MainChat` and the move-to sheet); `FeedStore` holds the posts, newest day first and, inside a day, the newest batch first with each batch in the model's order (a batch shares its `created` time; `FeedStore.DAY_ORDER`, unit-tested). The agent reads the posts, with `liked: true` on the ones you tapped, at `/var/minis/feed/YYYY-MM-DD/NN.md`: a read-only copy (`FeedSandboxScope`, refreshed before each shell command and on every like) rather than the app's own directory, since PRoot cannot bind a folder read-only and a like is the person's, not the agent's to change; a post without `liked` is one not reacted to, which the prompt says is not a dislike. When the task has written posts while the app is in the background, one notification names them and opens the Feed tab (`minis://feed`), in place of the generic "task done" notice with the model's text that up to 1.0.4 opened the conversation |
| `hands/` | Accessibility service, stage, capsule and screen reader; screen models resolve from enabled own providers and their vision capabilities |
| `ui/coding/` | The coding agents of your computers |
| `backup/` | What nanoMuse adds to the upstream backup (*Settings → Backup and restore*, `minis://settings/backup`): under *Chats*, *Files in the chats* (on by default) can be turned off so the chats travel as messages only, each session's files listed in the package as tombstones and the other categories unchanged, which keeps a 1.5 GB package down to a few MB for a server that refuses large uploads ([#561](https://github.com/nano-muse/nanoMuse/issues/561)); a `413` from a destination names the server's upload limit (`BackupHints`); and `nanomuse-backup run` in the sandbox makes one backup with the page's saved choices and every enabled destination, recorded in the page's history (`BackupRun`; `status`, `history`, `choices` read it), so a scheduled task can keep the phone backed up. It refuses when encryption is on, since the passphrase is typed on the page and never reaches the shell, and when no destination is enabled ([#560](https://github.com/nano-muse/nanoMuse/issues/560)) |
| `connectors/`, `ui/connectors/` | The connectors catalogue (`ConnectorsCatalogue` reads the asset), MCP authorization discovery + registration (`McpAuthDiscovery`), connecting and token refresh (`Connectors`), what this phone connected as published to the profile and what the other devices did (`SharedConnectors`), the Settings → Connectors page |
| `ui/cloud/` | Legacy sign-in, account and device screens retained in source; their navigation routes are removed |
| `res/values*/nm_strings.xml` | Every nanoMuse string in the seventeen languages the app has (English, 简体中文, 繁體中文, German, Spanish, Filipino, French, Indonesian, Japanese, Korean, Malay, Polish, Brazilian Portuguese, Romanian, Russian, Thai, Turkish); every file carries the same keys, apart from the two the English file marks `translatable="false"` (the relay address example and the product name `nanoMuse Cloud`), and a missing one falls back to English |


## Local Nicholasx interaction updates

In this local build, open the drawer and use Search beside **Side chats**. Its keyboard belongs to the drawer; it does not resize the underlying chat composer. Tap the group icon beside Search to create a group. Long-press a conversation for pinning, title/category editing, title regeneration, duplication, export, grouping, selection and deletion. A pulsing yellow dot marks running work. Green and red mark unread results and disappear when that chat is opened; a visible chat is already read when it finishes.

Thinking, tool calls and the notes preceding a tool call appear in a collapsed **Thinking and execution** row. Tap to inspect the process. Final answer text and errors remain outside it. In a provider, either connection Save button submits the address, URL suffix, user-agent setting and the API key currently being edited together. A save failure keeps the draft and shows a message. Video-capable models have a Video output switch; the provider's Video generation section chooses the relay API format.

Enable **Read replies aloud** in the chat menu to hear only the final answer. Playback starts after the model's normal completion signal. This avoids speaking intermediate narration that later turns into a tool call; interrupted, cancelled and truncated replies are not read automatically. The voice input panel follows the same rule. The dedicated call screen retains its streaming call behaviour.

The agent uses `minis-jigsaw-cli` to read complete life-log text, timestamps, per-record mood/energy and historical habit states for weekly, monthly, quarterly and yearly reviews. It does not read picture tables or files, or return picture information. The older `nanomuse-mosaic records` command remains available; use the commands below for complete structured data.

A compensating heartbeat aims to check overdue routines every ten minutes, alongside the existing task alarms. Both use the same persisted claim so they do not dispatch the same time slot concurrently. Pending starts survive process restarts; missed repetitions are coalesced. Android may defer alarms in idle mode, and force-stopping the app prevents background execution until it is opened again. Exact alarms and the phone's background permissions still matter. See [Android AlarmManager](https://developer.android.com/reference/android/app/AlarmManager). The heartbeat makes no model request when no routine is due.

Notification large icons follow the selected pet or imported clip poster and refresh an existing ongoing notification when the pet changes. Initialization and thumbnail scaling run in the background. The Android small status-bar icon remains the app's monochrome icon.


## Mosaic record markers and read-only queries {#mosaic-records-agent-access}

Week, month, quarter and year calendars circle date numbers in green when a saved life record exists, and red for today or earlier dates without one. Future dates and dates whose data is still loading have no status ring. Drafts and habit checkmarks alone do not count as diary records; a saved picture-only record does count. Today and selection outlines remain visible.

The phone agent can run these commands in the sandbox:

```sh
minis-jigsaw-cli list --start 2026-10-21 --end 2026-10-27
minis-jigsaw-cli get --date 2026-10-27
minis-jigsaw-cli stats --start 2026-10-01 --end 2026-10-31
minis-jigsaw-cli export --start 2026-10-01 --end 2026-10-31 --format md
```

Ranges include both endpoints, cover at most 366 days and accept --from/--to aliases. Defaults are today in the phone's time zone and the preceding six days. The diary date is the calendar date chosen in the app, including a manually changed date; it is not reconstructed from creation time. Creation and update timestamps use ISO format in the phone's time zone, which the output names in `timezone`.

JSON returns an ascending `days` array including empty dates. Every day includes `text`, `mood`, `mood_label`, `mood_score`, `habits`, `created_at`, `updated_at` and `records`. Missing values are explicit nulls. `records` preserves each entry and its complete text, timestamps and mood; day-level text joins the entries with newlines. Day-level mood preserves the daily setting, including a cleared value, or uses the last record when no daily setting exists. Raw moods retain the app scale of 1 (great) to 5 (bad); energy reverses that scale, with 5 highest. Habits distinguish done, skipped and unmarked states using the schedule in effect on that date.

List and export page whole days, default 31, with --limit 1..366 and --offset. Read `next_offset` until null, using `has_more` to identify unfinished ranges; Markdown includes a next-page hint. Quarterly and yearly reviews must consume all pages. Stats always covers the entire range and reports future_days separately from missing diary days. Text is never silently shortened; an oversized result returns an error asking for a smaller range or page.

Commands are read-only, support no mutation or deletion, and reject --out or implicit file export. Results go to stdout. The command makes no network requests and does not log record contents. It does not query pictures, paths or EXIF. Ask the agent to review a period of life records using text and mood only.


## Conversation anchors and running tasks {#conversation-anchors-and-running-tasks}

Every main, side and archive-opened chat has Conversation anchors in its top-right menu. Questions automatically lists prompts and bookmarked replies; Bookmarks lists saved messages. Search examines text in the current conversation. Selecting a result jumps to its original message or matching reply block and briefly highlights it. The bookmark button below a reply and the buttons in the directory toggle the same local state.

Bookmarks store message identities locally, not duplicate text or model context. Database source IDs preserve targets across merged assistant messages and reloads. Jumping to older content expands only the needed history window. Indexing makes no model requests. The search sheet handles its own keyboard without shifting the underlying composer.

Completion dots represent unread results and disappear on entering that chat. A visible, resumed chat is already read when its task finishes; hidden and background chats are not. Conversations without a valid group appear under Ungrouped, including pinned conversations in the archive list.

The running notification has no loading bar. Its collapsed form shows the task count and a compact preview; expanded text lists each running conversation with its request preview and independently measured duration. Starting another task does not reset existing clocks, and finished tasks stop timing. The current pet remains visible. Updates reuse one notification silently; Android 16 promotion uses standard BigTextStyle rather than a progress style. Available display space depends on the OS and device.

The diary toolbar calendar and record-date editor use the same green/red recording rings as the other calendar views. They support month navigation, date input and Today. Future dates have no ring, and editing still prevents future dates. The picker queries daily saved-record counts without loading pictures or record text.

## Local Coach practice

The Coach tab is the skill profile and archive. Its upper-right controls open evidence, course records and course management. Each skill has one long-term training conversation in the Daily practice group: moving to the next unit or a new case keeps the same conversation, and the unit and case are recorded on each lesson. Each explicitly started lesson has a separate record. Ending a lesson closes that record; greetings, corrections and follow-up questions do not automatically start another lesson. Existing scores and legacy exercises remain available without conversion to new mastery.

Teaching supports connected explanations, mechanisms, examples, competing theories, counterexamples and free questions before practice. Psychology, psychoanalysis and philosophy have distinct evidence boundaries: interpretations of a case are hypotheses, not proof of another person's hidden motives. The app supplies this protocol to the user's model; teaching quality still depends on that model and needs real-provider evaluation.

Understanding and application are checked separately using exact saved user quotations. A formal independent attempt needs a question saved before the answer. Hinted answers, simulated responses, reported real actions and delayed reviews remain distinguishable. Final demonstrated status requires both dimensions and a valid review at least 24 hours later, timed by the host. Ending a lesson does not certify mastery or automatically advance the unit.

### Daily lessons and lesson plans {#coach-daily-lessons}

Each lesson keeps the local date and time zone it started in; midnight and a time-zone change do not split a lesson that has started. The opening message of each lesson carries its date, so the long conversation reads as one section per day. Today's training offers one button: *Start today's training*, *Continue training*, or *View today's result* with *Practise more today*. When an earlier day's lesson is unfinished, the page offers *Continue that lesson* or *Start today*; starting today sets the earlier lesson aside with its draft and any answer still waiting for feedback, and it stays readable in past lessons. A real-life action keeps waiting across days. Tapping a button again, retrying or reopening the app continues the same lesson.

Before a new lesson the coach prepares a lesson plan with a separate model call: a preparation role that has no tools and sees only this skill's goal, unit criteria, recent answers, lesson summaries and waiting actions, plus the course's skill and the learning-coach skill. It returns the task, the reason, what to observe, concepts, material, hints, at least one path that changes with the answer, an independent check, the criteria it covers, when to re-check, and notes for the coach only. The app checks every field, the criteria IDs and that each cited answer is an exact quote of a saved answer, asks for one correction if a check fails, and otherwise uses the course's basic exercise and says why. A plan that arrives after a newer one for the same day is discarded. The lesson keeps the plan it started with. You can shorten the time or describe today's real need or material before starting; changing them prepares a new plan.

Current performance lists understanding, application and the delayed check for the current unit, each with its latest supporting answer, date, hint use and whether it was a simulation or a reported real event. *Next time* follows fixed rules: done on your own leads to a new situation or, after 24 hours, a delayed check; done with hints leads to a smaller task without help; no answers yet leads to a diagnosis; a waiting real action or a disputed assessment comes first. Earlier plans stay listed with their status.

The main chat does not display the Coach archive bar. Open archives from Coach or from a Daily practice topic.

The main chat manages course discovery, proposals, explicit version-bound confirmation, pausing and real-action reports. Bound practice chats may access only their own topic. Ordinary side chats, scheduled work and delegated requests cannot change Coach records. Records link back to their original chat messages; editing or deleting a source invalidates dependent evidence. Conversation deletion offers keeping read-only excerpts or removing associated topic archives.

Ordinary teaching text and real user messages are archived without requiring a tool call on every turn. Archive work has a persistent retry queue: retrying organization does not resend a model request. The chat remains usable after a model error or archive failure. Changing lessons requires pending organization to finish. The keyboard remains the input method. Completed Coach replies use Android system TTS; this is sentence playback after final completion, not token-streaming speech.

Local records use schema 3 in `minis-global/nanomuse/growth/coach-v2/`, with atomic snapshots and a previous valid backup. Schema 2 history remains readable. This implementation is Android-only; it does not update iOS or synchronize Coach archives between devices.

## Daily chat ideas

The main chat offers Ideas, Work, Life, Learning, Family and relationships, Content creation, and More ideas. Each category has 14 built-in suggestions in Chinese and English; two rotate by the device's local date, with no repeat within a seven-day cycle. Suggestions stay stable during the same day and after restart; foreground resume and date checks refresh them after midnight or a time-zone change. This is a local seven-day rotation, not an automatic daily online content-generation service.

Selecting a card adds its prompt to the composer without replacing an existing draft or sending automatically. The strip collapses while typing or while a reply is being generated. The full Ideas page retains its confirmation flow. Content creation also has a daily visible Check today's filmable topics entry: sending it asks the model to verify dates and sources online and produce a practical filming plan. If verification is unavailable, it must say so and offer evergreen topics instead of presenting invented trends. It does not publish content or create reminders.

## Local Android quality updates

The Android application references the generated `app/libs/rclone.aar` directly as a local file. This keeps the same backup library and avoids a Windows Lint parser failure on its former named-argument dependency declaration. Dependency checks remain enabled; the existing AGP and Lint versions are unchanged.

The API-key provider and model forms keep their inputs when storage fails and only return after the save succeeds. A progress indicator appears inside the save button, and repeat taps and back navigation are blocked during the write. The model editor rejects duplicate IDs within a provider and rejects an edit if its original model snapshot has changed, including changes from a background refresh. Reopen the editor to review that newer configuration before editing again. Editing a name or a visible capability preserves unedited reasoning limits, text support and other media capabilities. Renaming a custom model returns one page.

Provider configuration is committed to the database first. A persistent marker records an unfinished write to the JSON compatibility mirror, so a failed mirror write or interrupted process cannot make a previous mirror overwrite the newer database on the next launch. This also applies to an intentionally empty provider list. New API-key providers confirm the encrypted credential write before publishing their configuration; a failed attempt keeps the same pending provider ID for retries. A recreated form recognizes an already committed ID and returns without overwriting that configuration or its key. Model discovery continues in the repository after leaving the form, and discards results if the provider was deleted or its configuration or credential changed while the request was running.

Todo editors restore the original task revision and last submission snapshot after recreation. An identical retry reuses its operation ID; changed input uses a new one. AI task mutations recheck the active chat authorization after obtaining the database transaction and before committing, so revoked operations roll back their task, category, event and retry records together. These checks also protect writes that had to wait for another database operation.

Focus setup retains the selected task, mode, duration and forced-focus option when visiting lock permissions, whitelist, settings or schedules. Finishing a paused session uses its pause time, including when a lock schedule takes over the next day. Moving the wall clock backwards cannot create an invalid end-time range. Mosaic disables photo removal while an import, save or date change is running, and only removes a staged image after the draft accepts the change.

Coach evidence removal recalculates the affected earlier units as well as the current unit. Purging a conversation removes its topics, lessons, actions, derived lesson plans and related retry records; other valid evidence can still support an achieved unit. A later lesson is prepared again instead of reusing a plan derived from removed material.

Coach navigation keeps its scroll position on return and shows progress while opening a practice conversation. Stable list keys keep loading and error rows from changing the identity of the content below them. The conversation-deletion dialog reads Coach links in the background and waits for that lookup; a loading failure or account change leaves deletion disabled. The daily idea strip reserves the card row's height before its first catalogue load, scales that space with text and starts a separate loading state after a language change.

Drawer search uses a compact header when space is short, with secondary actions in its menu; entering selection closes the keyboard. Coach course actions wrap, the home/chat name pill can grow with text, and shared top bars measure their navigation and action controls before allocating the title width. Mosaic editor subtitles use a single ellipsized line. Chat menus, sheets, previews and menu-related back handling follow the chat's visibility when another tab or the drawer is open.

Conversation creation records its account owner before inserting the chat and shares a migration boundary with account changes. A transition invalidates old Coach services before moving their files and keeps the space closed if restoration fails. Preferences, routines and target backups remain available for a retry in the same process; the restored identity is published before the feed refresh. Removing account chats clears each owner only after that chat's data and files have been removed, so a failed deletion stops migration with the remaining owners intact.

Ordinary chat ViewModels from the previous account cancel their work when migration begins. Direct memory and file tools, memory-context loading, Room message appends and asynchronous event-log writes retain and check the account generation captured when the operation began. Late operations therefore fail the generation check instead of adopting the newly active account. Migration retry tracking is held in memory: retrying within the same process does not provide automatic recovery after that process is killed. These protections cover the listed app entry points; external shell processes and other background services still require separate isolation checks.

Scheduled-task target and message pickers use the current account's owned conversations, and dispatch rechecks ownership and the account-transition generation. Account changes cancel old scheduled work; an ordinary Coach cache refresh does not. A task-level lease prevents overlapping first runs from creating separate dedicated chats. Reused task chats apply the task's current model binding to both the loaded chat and storage, including a return to the current default; an unsuccessful change restores the previous model without changing the app-wide default.

Large pasted text becomes an attachment while its file is written in the background. Sending waits for preparation; failed or cancelled preparation preserves queued content, and restoring an ordinary failed send keeps both its original text/attachments and the next draft. Queued batches consume only their successfully persisted IDs. Local Markdown media resolves full paths for the specified conversation or declared shared directories, without scanning other conversations for matching filenames. Audio prepares asynchronously with explicit cleanup on failure, cancellation and disposal. Markdown renders immutable snapshots prepared for the current palette, including the incremental streaming tail, and chat ViewModels unregister their safe-mode listener when released.

Search results omit group headings while a query is active so the landscape keyboard leaves more room for conversations. Android service-start restrictions are handled at both launch and foreground promotion: a denied promotion stops the service without restarting it or changing its declared type. This prevents the denial from crashing the app; it does not guarantee background execution when Android disallows it.

### Translucent pet header

The home chat pet header uses a single 4dp backdrop blur with a fading lower edge. Messages scroll behind it, while their top content inset still lets the oldest message move fully clear of the header. The blur samples only the message list, excluding the pet animation and header controls. Name and round-button surfaces are translucent; the pet image or video remains sharp, including any background already present in that asset. Android versions below 12 use a translucent tint fallback.

## Focus and reusable categories

Starting a session opens an immersive screen with the task, a large timer and pause/resume controls. Ending asks for confirmation and saves only measured time. Minimize returns to the app without stopping the timer. Screen-on is optional. Screen unlock and process recreation restore the same active session; the app does not bypass the system lock screen.

Choose a background before starting. The default mountain landscape is drawn with vectors. **Import background** opens the system file picker and stores an app-private copy of each chosen file, up to 24 files and 20MB per file. Select from saved backgrounds for later sessions. Removing a background deletes only the app copy. Backgrounds are isolated by account and are not sent to AI tools; invalid or missing files fall back to the landscape.

Focus tool responses include `view_url`, `sampledAt`, `currentElapsedMs` and `remainingMs`. Command retries preserve the original receipt. If `isReplaySnapshot` is true, read `currentState` for the current timer instead of treating the old receipt as live. `deadline_reached` distinguishes a pause requested after expiry from an early pause. Notifications and `minis://views/focus` open Focus.

Task tools support `create_category` and `delete_category` for reusable groups and tags. Deletion requires the exact category name, kind and `expectedCreatedAt` from a fresh category query. It removes current category assignments, increments affected task revisions and preserves tasks and completed history. Exact retries cannot delete a subsequently recreated category. Category command receipts use an additional backup field compatible with older task backups.

Open **Focus** below Tasks in the sidebar. Choose a task or name what you are working on, then start a countdown, stopwatch or break. Pause time is excluded. The stopwatch has a 12-hour limit; countdowns accept 1–180 minutes. The timer survives page changes and process recreation within the same boot. After a device reboot, an unfinished timer pauses conservatively. System power saving may delay alerts; elapsed countdown time is still capped. When a focus ends, the full-screen timer offers a 5-minute break, 15 minutes after every fourth focus of the day; when the break ends, it offers to focus again on the same task for the same length. The stopwatch shows the time it started instead of a progress bar.

The top-right controls open records, day/week/month/year statistics, and JSON export. Statistics count finished focus intervals, split across local calendar boundaries, and exclude breaks and deleted records. The share of time can be viewed by task group or by tag; a session with several tags is split evenly among them, as in task statistics. Leaving the full-screen timer always returns to the Focus page. A finished timer never marks a task done. Task details also show related focus time.

In a daily record, choose finished focus sessions to describe what the time was spent on. Selections survive drafts and are committed atomically with the record. Diary snapshots remain available after deleting a focus record.

Ordinary chats, including a newly created chat, can use `focus_query` and `todo_query` to review saved records for the current account. The main chat also offers `focus_command` and task commands. Commands start, pause, resume, finish or delete actual timers; callers cannot fabricate past duration. Focus JSON export includes history, but import restores only disabled lock plans and the whitelist; it does not restore that history or active timers.

In **Tasks → Groups and tags → Browse and create**, delete a group or tag after reviewing the confirmation. Tasks remain; group deletion moves them to Ungrouped, and tag deletion removes current associations. Historical completion snapshots remain unchanged.

### Reflect after focus {#focus-reflections}

After a countdown ends or you finish a session, choose **Record reflection** on the immersive screen or a recent/history card. The daily-record editor opens with that completed focus session and its existing linked task selected. The initial date is the session's local end date. Linking the task does not mark it done; task status changes remain an explicit choice in the editor. Breaks have no reflection shortcut.

Long immersive titles use at most two lines. The screen-resume hint disappears after completion, leaving more room for the reflection and return actions.

Each focus session has its own recoverable draft. Opening it again keeps the text, date and associations you changed, including a focus or task you deselected. It does not replace a separate diary draft for the same day. Saving commits the reflection and associations together. Going back or recreating the screen does not repeat the navigation or reopen the immersive timer.

The daily-record text action and editor now use **Reflection**. A record can retain text, mood, habits, selected tasks and measured focus intervals. Saved association snapshots preserve their original title/status/timing when a task is later renamed or a focus record is deleted.

### Review records from any ordinary chat {#personal-record-queries}

Ask a new chat to review recent focus time, compare it with task progress or summarize saved reflections. The model receives read-only tools for the authorized user turn. Reading does not require moving the chat into the main group. Mutating tasks or timers still requires the main conversation and the existing explicit-user-request checks; Coach writes retain their main/topic scope.

`personal_records_query` exposes a catalogue, reflection date-range discovery, reflection text and statistics, Coach history, goals and scheduled-task history. Queries are bounded and paginated. Coach, goals and routines support exact-ID detail; reflection pages preserve complete days and full saved text. The model must follow pagination for a complete review and distinguish a failed query from an empty result. Focus and tasks continue to use their dedicated query tools.

Diary text and habits retain the existing device-local storage model. Their linked task/focus snapshots, focus and task records, Coach, goals and routines use the current account. A query does not read photo files or metadata, credentials or unsaved diary drafts. Changing accounts or cancelling a turn invalidates the request. Recorded time is not proof of task completion or attention quality, and a saved reflection is the user's report. Model analysis quality still depends on the selected provider.

For Windows debug builds, `-Pnm.bash=<absolute-path-to-Git-Bash>` selects the Bash executable used to stage debug assets. This avoids the Windows WSL launcher on machines without a Linux distribution. The default remains `bash`.
