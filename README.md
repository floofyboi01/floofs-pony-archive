# Ember's Pony Archive â€” Roku channel

A sideloaded Roku channel that plays **My Little Pony: Friendship is Magic** and
**Equestria Girls** straight from the static MP4s behind
`fim.heartshine.gay` / `eqg.heartshine.gay`.

262 FiM episodes across 14 seasons, 12 EqG entries across 3, with English
subtitles where the archive has them.

> This repository contains only client code. It hosts, bundles, and
> redistributes no video, audio, or subtitle content — everything is streamed
> live from the archive, and it reads that archive's own `db.json` rather than
> embedding any of it. It is a personal tool and is not affiliated with or
> endorsed by the archive's author, Hasbro, or Roku.

## Why a channel and not "just open the website"

Roku has no web browser and no way to render HTML or run JavaScript. Nothing
can "load a page" on it. The so-called browser channels in the Roku store are
image slideshows, not browsers.

That turns out not to matter here. `mlp.heartshine.gay` and its siblings are a
thin JavaScript wrapper around plain, unprotected, directly-addressable MP4
files:

```
https://static.heartshine.gay/g4-fim/s01e01-1080p.mp4
https://static.heartshine.gay/g4-fim/vtt/s01e01-en.vtt
```

A native channel hits exactly those URLs, so it gets a better result than the
website would: real remote navigation, trick play, resume, and no browser
overhead.

### Verified compatibility

Probed directly from the MP4 container before writing any code:

| Property | Value |
|---|---|
| Video | H.264 **Main profile, Level 4.0** (`avc1`) |
| Audio | AAC-LC stereo (`mp4a`) |
| Container | `mp42`, `Accept-Ranges: bytes` |
| DRM | none |

That is the single most broadly supported combination on the platform â€” it
plays on every Roku model ever shipped. FiM's files put `moov` *after* `mdat`
(not fast-start), so startup costs one extra range request; harmless.

### The one real snag: subtitles

The archive publishes WebVTT. Per Roku's own docs, **Roku only accepts WebVTT
embedded in HLS or DASH manifests â€” never as a sideloaded file alongside a
progressive MP4.** Sideloaded captions must be SRT, TTML, or DFXP.

So `SubtitleTask` downloads the `.vtt`, rewrites it as SRT in `tmp:/`, and
hands the player a local path. The transform fixes the `.` â†’ `,` decimal
separator, expands `MM:SS.mmm` to `HH:MM:SS,mmm`, adds the sequential cue
numbers SRT requires, strips WebVTT-only markup (`<c.loud>`, `<v Name>`) while
keeping `<i>`, and drops cue settings and cue identifiers.

A survey of 50 real subtitle files found the corpus uniform (LF endings, no
BOM, no cue IDs, no cue settings, full timestamps, `<i>` the only tag), and
`tools/test-vtt2srt.js` validates the conversion over 10,288 real cues plus
synthetic edge cases.

Some shorts ship stub tracks reading `[Subtitles under construction]`;
`db.json` omits those from `epSubs`, and the task skips them regardless.

## Enable developer mode

On the Roku remote, from the home screen:

> **Home Ã—3, Up Ã—2, Right, Left, Right, Left, Right**

Then *Enable installer and restart*, accept the agreement, and set a password.
After the reboot, find the IP under **Settings â†’ Network â†’ About**.

## Deploy

```powershell
# Build and install
.\deploy.ps1 -RokuIp 192.168.1.42 -Password yourpassword

# Build, install, and launch it immediately
.\deploy.ps1 -RokuIp 192.168.1.42 -Password yourpassword -Launch

# Just build the zip
.\deploy.ps1 -PackageOnly
```

`deploy.ps1` verifies the project layout, regenerates any missing artwork,
builds the zip with spec-correct forward-slash entry names, probes the dev
server before uploading, and translates Roku's HTML response into a readable
result.

Live log: `telnet 192.168.1.42 8085`

## Controls

| Key | Action |
|---|---|
| Left / Right | move between the archive, season, and episode columns |
| Up / Down | move within a column |
| OK | drill in, or play the focused episode |
| `*` | options (quality, subtitles, autoplay, clear resume history) |
| Back | up a column, or leave playback |

During playback the Video node owns the remote, so fast-forward, rewind,
instant replay, and the system caption dialog on `*` all behave natively.

Episodes you stopped partway show `- resume 12:34` and pick up where you left
off. The last 60 seconds counts as finished.

### Autoplay

When an episode plays to its end the next one starts automatically, rolling
from the end of a season into the start of the next (S01E26 to S02E01). It
stops at the end of an archive rather than crossing from FiM into EqG, and
each new episode fetches and converts its own subtitles on the way in.

Only a natural end triggers it â€” pressing Back always just exits. Turn it off
under `*` if you would rather not.

## Layout

```
manifest                      channel metadata, splash, icons
source/main.brs               entry point, deep-link handoff
source/Util.brs               registry, resolution picking, VTT->SRT
components/MainScene.*        three-column browser, playback, options
components/DbTask.*           fetches + flattens db.json off-thread
components/SubtitleTask.*     VTT download and SRT rewrite
tools/make-images.js          procedural icon/splash generation
tools/test-vtt2srt.js         converter tests against the live archive
tools/validate.js             static BrightScript/XML checks
deploy.ps1                    package and sideload
```

Episode data is fetched from `db.json` at launch, never hardcoded, so new
episodes appear without touching the channel.

## Changing the name and icon

### Name

There are two, and they are independent:

| What | Where |
|---|---|
| Home screen tile | `title=` in `manifest` |
| Heading inside the app | `titleLabel` in `components/MainScene.xml` |

```
title=Pony Time
```

```xml
<Label id="titleLabel" text="Pony Time" translation="[90,40]" ... />
```

Then redeploy. The home screen tile updates on install.

### Icon

Two sizes are required, and Roku is strict about the dimensions:

| File | Size | Manifest key |
|---|---|---|
| `images/icon_focus_fhd.png` | 540x405 | `mm_icon_focus_fhd` |
| `images/icon_focus_hd.png` | 290x218 | `mm_icon_focus_hd` |

`mm_icon_focus_sd` and `mm_icon_side_*` are deprecated and deliberately not
used here.

Either drop your own PNGs in at those exact sizes, or edit the generator and
re-run it:

```powershell
node tools\make-images.js
```

The palette and shape live at the top of `tools/make-images.js` â€”
`BG_TOP`, `BG_BOTTOM`, `MINT`, `MAGENTA`, and `STAR_POINTS` (change `6` to `5`
for a five-pointed star, `STAR_INNER` for how fat the points are).

**If you hand-draw your own icons, do not run `make-images.js` again** â€” it
overwrites every file it manages. `deploy.ps1` only invokes it when an image
referenced by the manifest is missing, so custom art is safe during a normal
deploy.

Splash screens follow the same pattern: `splash_sd` 720x480, `splash_hd`
1280x720, `splash_fhd` 1920x1080, with `splash_color` filling any gap.

## Checks

```powershell
node tools\validate.js        # blocks, observers, findNode ids, interfaces
node tools\test-vtt2srt.js    # subtitle conversion vs. the live archive
node tools\make-images.js     # regenerate artwork
```

## Adding the other archives

The same schema backs all eight of Ember's sites. To add G5, G1, G3, Pony
Life, and the rest, extend `seriesSpec` in `MainScene.brs`:

```brightscript
m.dbTask.seriesSpec = [
    { key: "fim", host: "fim", label: "Friendship is Magic" },
    { key: "eqg", host: "eqg", label: "Equestria Girls" },
    { key: "mlp", host: "mlp", label: "G5" },
    { key: "pl",  host: "pl",  label: "Pony Life" }
]
```

Note that G5 carries 23 subtitle languages; the UI is currently English-only
and would need its language picker restored.

## Notes from bring-up

Four BrightScript/SceneGraph traps cost real debugging time here. Each now has
a matching rule in `tools/validate.js`, so `node tools\validate.js` catches
them before a deploy instead of a blank screen catching them after.

1. **`rem` and `pos` are reserved words.** `rem` is BASIC's comment keyword, so
   `rem = x` silently swallows the rest of the line â€” and the compiler reports
   the syntax error on a *later* line, which sends you looking in the wrong
   place.
2. **`source/` is not global to components.** Scripts under `source/` are in
   scope for the main thread only. Every component must `<script>` in the
   helpers it calls, or it dies at runtime with *"Function is not defined in
   component's namespace (&h91)"* â€” and only on the code path that runs.
3. **A `<Font>` node's `uri` only accepts a packaged font file.**
   `font:SystemFontFile` happens to work, `font:SystemBoldFontFile` does not,
   and the failure mode is text that renders completely invisibly rather than
   any error. Use the `font="font:MediumBoldSystemFont"` shorthand.
4. **`Trim()` is not a global function.** BrightScript has global `Mid`,
   `Left`, `Len`, `Instr`, `UCase` and friends, but `Trim`, `Replace` and
   `Split` exist only as methods on the value. `Trim(x)` raises *"Function
   Call Operator ( ) attempted on non-function (&he0)"*.

### Driving the device from a PC

Roku OS 14+ rejects unauthenticated ECP *input* with HTTP 403 while still
allowing `/launch` and `/query`. To script keypresses, set **Settings â†’ System
â†’ Advanced system settings â†’ Control by mobile apps â†’ Network access** to
*Permissive*.

Useful during development:

```powershell
# Launch straight into an episode, no navigation required
curl.exe -s -X POST "http://192.168.1.42:8060/launch/dev?contentId=fim_s01e01"

# Grab a screenshot of the running channel
curl.exe -s --digest -u "rokudev:PASSWORD" -F "mysubmit=Screenshot" -F "archive=" `
    "http://192.168.1.42/plugin_inspect"
curl.exe -s --digest -u "rokudev:PASSWORD" "http://192.168.1.42/pkgs/dev.jpg" -o shot.jpg
```

Note that a dev screenshot captures the graphics plane only â€” during playback
the video itself reads as black, though rendered subtitles do show up.

## Verified on device

Roku TV 4 Series-40 (K207X), Roku OS 15.3.4:

* both archives load from `db.json` (14 + 3 seasons, 274 entries)
* three-column navigation, dimming, and the options overlay render correctly
* playback confirmed on multiple episodes at 1080p
* WebVTT converted to SRT on-device (265 / 322 / 360 cues), accepted by the
  player, and visibly rendering
* resume markers persist and redisplay (`- resume 0:55`)
* autoplay rolls S01E26 into S02E01, and stops at the end of an archive
  instead of crossing into the next one
* preferences survive a relaunch via the registry
* this panel renders its UI at 720p but reports a 1080p display, so the
  adaptive default correctly selects 1080p streams

## Troubleshooting

### Does it stay installed?

Yes. It is a real installed app â€” it shows up in `/query/apps` next to Netflix
and lives on the home screen (sideloaded apps land in the bottom row). It
survives reboots and power cycles, and there is **no time limit**: Roku has no
equivalent of iOS's 7-day sideloading expiry.

Four things remove it, all of them deliberate:

| Cause | Effect |
|---|---|
| Sideloading a different app | Replaces it â€” there is only one dev slot |
| Turning off developer mode | Removes it |
| Factory reset | Removes it |
| Some major Roku OS updates | Occasionally clears the dev slot |

Recovery is one command, and `pa_prefs` / `pa_resume` registry data survives a
reinstall, so resume points and settings come back with it:

```powershell
.\deploy.ps1 -RokuIp 192.168.1.42 -Password yourpassword
```

## Troubleshooting

**Channel installs but shows a blank screen** â€” `telnet <ip> 8085` and look for
a compile error naming a file and line.

**"No Roku developer web server answered"** â€” dev mode needs the reboot to take
effect, the IP may have changed via DHCP, and the PC must be on the same
network (guest/IoT VLANs block this).

**Video fails instantly** â€” confirm the URL from a browser. The archive
occasionally reshuffles files between `static`, `static2`, and `static3`, and
`db.json` is the source of truth for which host holds what.

**Subtitles never appear** â€” they are off by default. Turn them on with `*`.
Roku's caption mode is a *system* setting, so toggling it here affects the
whole device, which is the behaviour Roku's guidelines require.

**The channel vanished from the home screen** â€” see
[Does it stay installed?](#does-it-stay-installed) above; re-run `deploy.ps1`.
