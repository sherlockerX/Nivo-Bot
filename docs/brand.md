# Nivo brand

## Mobile product names

The Android and iOS apps display **Nivo** in every language. The bundled companion is **十七 / Shiqi**. A personal assistant name is kept when its file is present in the app's data container.

The mobile display name appears on the launcher, in Settings, permission descriptions, notifications, sharing and file entry points. The iOS share extension, Files provider and activity widget each include their own localized `InfoPlist.strings`. Model-facing product descriptions use the same current name; commands and protocol identifiers keep their existing spelling.

Default assistant templates are recognized by their complete contents. Android and iOS migrate only untouched historical default templates to Shiqi. The same rule applies to the bundled long-term memory: an unchanged old seed can be updated, while personal facts, custom names and edited text are kept. The default memory refers to SOUL.md for the assistant's identity and directs the assistant to the available record tools instead of claiming that life records cannot be read. The existing cloud-sync entry points remain disabled.

The display rules are:

- Ordinary pages, notifications and the default assistant introduction distinguish Nivo, the app, from 十七 / Shiqi, the companion. Local storage descriptions do not advertise the removed account or cross-device sync service.
- Advanced tools lead with their purpose, such as managing app settings. Details and the terminal retain real commands, paths and formats, including `minis-config`, `/var/minis` and `.minisbak`. A historical identifier in a command or file path is not another product name.
- About names **nanoMuse** and **OpenMinis** as upstream projects. Their license notices and copyright attribution remain intact. Old conversations, imported documents and personally edited identity or memory files are not rewritten to remove historical names.

Brand generation is separate from version generation:

```sh
python scripts/rebrand.py --android-brand-only
python scripts/rebrand.py --ios-brand-only
```

These commands preserve version fields, installation identifiers, signing settings, app groups, Keychain access, database and file paths, URL schemes and the existing website address. The source namespace and asset names retain `nanomuse` for compatibility. Upstream attribution, licenses and references to disabled historical services retain their original names. This does not add a cloud service to the local mobile product.

The current Android source uses **`io.github.nivo`**. Published Android `2.0.9 (60)` uses `io.github.sherlockerx.nelan`; earlier APKs use `io.github.nanomuse.app`. All three IDs have separate storage, permissions and credentials, even with the same signing certificate. The iOS bundle ID remains `io.github.nanomuse.app`.

Use the old app's export tools and the new app's import tools only for the categories they support. The general `.minisbak` does not include life-log records/photos, Coach progress, focus history or custom-pet settings. Todo has a separate JSON export/import. Focus can export history, but its importer restores only disabled lock plans and the whitelist. Follow the [Android migration guide](https://nivo.8666886.xyz/install.html#android-migration); the [detailed release notes](releases/v2.0.9.md#moving-from-the-old-android-package) list the reviewed scope. Keep the old installation and its data until the retained records and supported transfers have been checked.

The final `Nelan-v2.0.9-arm64.apk`, source archive and checksum file have passed local verification and replace the obsolete old-ID candidates. The APK's new package identity and original release certificate were verified. The source archive remains fixed to APK source commit `905f9f23cba0017083a3fc50f3d443a7ade55f9b`; final verification documentation belongs to the subsequent publication commit. The [public release page](https://nivo.8666886.xyz/releases/android-2.0.9.html) is deployed. All 54 static-file HTTP checks passed with CDN additions recorded separately, and all three complete artifact downloads match the local sizes and SHA256 hashes. These checks do not establish browser or phone acceptance. The iOS source has the matching brand and companion changes, but this round has no Xcode build or iPhone validation and publishes no new IPA. The retained iOS download is `2.0.8 (59)`, which does not contain these new source changes.

Phone acceptance must check both apps can coexist, the supported backup transfers, new-package permissions, and Chinese and English system surfaces. Runtime permissions, accessibility, overlay, usage access, alarms and file grants must be checked or granted for the new app. Device Owner authority does not transfer through a backup. Windows portable tests and Swift syntax parsing cannot replace an Xcode build or phone verification.

## Existing visual identity

Decided 2026-09-24. The app icon and the in-app colour system are one decision: the palette
is derived from the icon so the whole app matches the tile on the home screen.

## The mark

One continuous pen stroke that reads as an **N**: a hooked entry, one rounded peak, a long
diagonal, a tight valley, and an upward exit: an N with one arch, drawn without lifting the
pen. The mark is abstract on purpose: it is a gesture first and a letter second.

- Source of truth: `assets/brand/nanomuse-icon-source-1024.png` (final render, white squircle on
  brand blue). Everything else is derived from it.
- `assets/brand/nanomuse-mark.svg`: the stroke alone, traced as a single filled path, viewBox
  `0 0 100 100` in tile coordinates, gradient fill.
- `assets/brand/nanomuse-icon.svg`: white squircle tile (`rx=27`) + mark. This is the app icon.
- `assets/brand/nanomuse-icon-on-blue.svg`: the icon on the brand-blue backdrop, for
  store listings and the splash only. Wherever the icon stands for the app (README, site,
  social card, favicon) it is the plain tile: white, the mark, a hairline edge, no backdrop.
- `assets/brand/nanomuse-mark-rgba-688.png`: the stroke with alpha, 688 px, raster fallback.
- `docs/app-icon.png`: the tile rendered with rounded corners (27 % radius, transparent
  outside, a hairline `#D9D9DE` edge so it keeps its shape on white), 512 px: the icon as it
  sits on a home screen. This is the README hero and the picture to use wherever
  the app is shown as an app.

The icon is **not** the companion. The mobile apps bundle **Shiqi**, with the animation states described in [Avatar](avatar.md). Existing custom faces and clips remain selectable. The resource name `dragon` is retained for compatibility. Never put the companion on the launcher icon or use the N mark as the assistant's face.

## Colour

Measured from the icon.

| Token | Value | Use |
|---|---|---|
| `brand.stroke.start` | `#015CFB` | left end of the mark's gradient |
| `brand.stroke.end` | `#0186FB` | right end of the mark's gradient |
| `brand.blue` | `#0078FD` | backdrop behind the tile; splash; hero backgrounds |
| `tile` | `#FFFFFF` | icon tile |

### Light theme

| Token | Value | Contrast | Use |
|---|---|---|---|
| `primary` | `#015CFB` | 5.35 on white | links, primary buttons (white text), status line |
| `primary.container` | `#E5F0FF` | — | selected rows, chips |
| `ink` | `#000000` | 21 on white | your message pill (white text), the send button and the scroll-to-latest disc (white arrow), the selected tab's disc |
| `pill` | `#F2F2F7` |  | the agent's message pill |
| `primary.tint` | `#EEF5FF` | — | subtle highlighted surfaces |
| `bg` | `#FFFFFF` |  | the chat, the pill bar, the menus and the drawer |
| `bg.grouped` | `#F2F2F7` | — | the settings pages (unchanged from OpenMinis) |
| `surface` | `#FFFFFF` | — | cards, input |

### Dark theme

| Token | Value | Contrast | Use |
|---|---|---|---|
| `primary` | `#58A6FF` | 8.3 on `#000`, 6.7 on `#1C1C1E` | links, buttons (black text), status line |
| `primary.container` | `#1A2B4A` | — | selected rows, chips |
| `ink` | `#FFFFFF` | 21 on `#000` | your message pill (black text), the send button and the scroll-to-latest disc (black arrow), the selected tab's disc |
| `pill` | `#1C1C1E` |  | the agent's message pill |
| `bg` / `surface` / `surface.2` | `#000000` / `#1C1C1E` / `#2C2C2E` | — | unchanged from OpenMinis |

Rules: one accent hue only. Code blocks, thinking text and links that OpenMinis coloured with
iOS blue, orange and green become `primary` plus neutrals. The conversation itself is
monochrome: your pill, the send button and the selected tab are the ink colour on the
canvas, and the blue is left to links and the status line (`ChatColors.kt`, written by
`scripts/rebrand.py`). The companion's own colours stay inside the avatar; they are not UI
colours.

## Android mapping (done in S1)

- Adaptive icon: background layer = solid `#FFFFFF`; foreground layer = the mark as a
  `VectorDrawable` whose `fillColor` is the two-stop linear gradient above; monochrome layer =
  the same path with a flat fill (Android tints it).
- Icon skins (activity aliases kept from OpenMinis): *Auto* = white tile; *Light* = white tile;
  *Dark* = `#0F1B33` tile with a white mark.
- Notification small icon: the mark, flat white, 24 dp.
- Never ship the old OpenMinis icon, name or the letter-n drafts.

## Don'ts

- Don't recolour the mark outside the blue gradient / flat white / flat black.
- Don't rotate, outline, or add a shadow to the stroke.
- Don't place the mark on the brand blue without the white tile (contrast).
- Don't use another product's mark, name or blue as an asset; the only mark is ours.
