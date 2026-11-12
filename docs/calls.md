# Voice calls

The local Nicholasx iOS build provides foreground voice calls from the main chat
and side-chat menus. Add an Alibaba Cloud Model Studio provider and key, then
open **Voice call**. The call settings select the provider, recognition model,
synthesis model, voice and pause length. An empty WebSocket address follows the
selected provider's region. A custom address must use that provider's host.

The defaults are `fun-asr-realtime`, `cosyvoice-v3-flash`, `longanyang` and an
800ms pause. A CosyVoice v3.5 model requires a cloned or designed voice. Speech
recognition stays active while the answer plays, allowing interruption; the
screen also has mute, speaker routing and an explicit Interrupt button.

Recognized speech and replies use the current chat's normal history and model.
Thinking is disabled for call requests without changing the saved chat setting.
Only the confirmed final answer is synthesized. Reasoning, tool output and
intermediate narration are silent. This means speech starts after the final
answer is confirmed, rather than at its first generated token. Keep the call in
the foreground; leaving for the background, hanging up or an audio interruption
releases the microphone and ends the call.

**Models** also exposes **Speech to text** and **Text to speech** for ordinary
voice input, read-aloud and quick tests. These selections survive app restarts.
An unavailable selection falls back to a configured voice group, then the phone's
system voice. Call models are configured separately on the call screen.

This migration has static source checks on Windows. The unsigned macOS device
build, XCTest cases, microphone routes, echo cancellation and real Model Studio
requests still require validation on the appropriate platform.

## Earlier realtime calls

Versions 0.1.20 and 0.1.21 could place a voice or video call with the agent
through Qwen Omni's real-time socket. It was expensive to run for everyone and
out of the project's way (a personal agent that *does things*), so 0.1.22 took
it out of every app and the relay. Older ledger rows of kind `realtime` and
messages marked "said on a call" still display.

What remains is voice **input**: on the phone the microphone button in the
composer (the system's or a provider's speech recognition, as in OpenMinis);
in nanoMuse Web and the desktop app a microphone button next to *Send* that
uses the browser's own speech recognition where it exists (Chrome, Edge,
Safari); nothing is sent anywhere by nanoMuse, no model is involved, and the
words land in the box for you to send.

The design and the code of the calls live in the history of the repository
(`git show v0.1.21:docs/calls.md`).
