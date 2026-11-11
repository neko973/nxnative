# Ocarina of Time (Switch 2) on Apple silicon: the 60 fps branch

This branch is [seedds/nxnative](https://github.com/seedds/nxnative) at `adaff735` (2026-11-10) plus a set of changes aimed at one thing: The Legend of Zelda: Ocarina of Time (title ID `0400486024DEC000`, update v131072) at its full docked resolution (main passes 1536x864, picture 2048x1152) as close to a steady 60 fps as a mid-range Apple GPU allows, with the game at its real speed whatever the frame rate.

It contains no game files. You build the app from your own dump of the game, exactly as with upstream.

## What you get

Measured on a MacBook Pro with an M3 Pro (14-core GPU, 18 GB), fullscreen, full resolution, MetalFX upscale, the settings below:

| Area | Before this work (uncapped, window) | This branch (fullscreen, 60 fps setting) |
|---|---|---|
| Kokiri village, 20 minutes of roaming around its middle | 37.5 fps, GPU 22.4 ms, 92 frames over 40 ms per 96 s walk | 59.9 fps, 99.6 % of the time at 60, frame p95 17.8 / p99 18.6 ms, GPU p50 15.0 ms, 21 of 70,713 frames over 40 ms (none over 100 ms) |
| Kokiri village, the walk from Link's house (the heaviest view tested) | | 59.9 fps, 100 % of frames at 60, GPU p50 15.8 ms |
| Hyrule Field | 42 fps, GPU 20.3 ms | 59.7 fps, 99 % of frames at 60 |
| Link's house | not measured | 59.9 fps, 100 % |
| Hyrule Castle courtyard | not measured | 59.9 fps, 99 % |
| Kakariko | not measured | 59.7 fps, 99 % |
| Zora's Domain | not measured | 60.0 fps, 100 % |
| Water Temple | not measured | 60.0 fps, 99 % |
| Inside Jabu-Jabu | not measured | 59.0 fps, 99 % |
| Gerudo Valley | not measured | 59.1 fps, 99 % |
| Zora's Fountain, facing the water | not measured | 58.6 fps, 100 % |

Each row but the first is a 48 s walk from a save's starting point. In a window the picture is composited by the window server, which costs about 1.4 ms of GPU a frame here: the village runs about 54 fps windowed. Play fullscreen.

The 20-minute run held the memory footprint flat (11.0-11.4 GB). Its long frames had no pipeline build or upload in them; macOS was indexing files on three cores during that run, and the same roam on the build before the last two shader changes, on a quiet machine, had 3. Slower GPUs than the one above will sit at 40 in the heavy areas; the frame step then keeps frames even (see below).

The picture is the one the game draws docked with graphics scale tier 1: 3D passes at 1536x864, the picture at 2048x1152, as upstream drew it until `084f5aa5`. Upstream now answers tier 0 (1920x1080 and 2560x1440, about 56 % more pixels); here that is `DM_GFX_SCALE=0`, and this GPU does not hold 60 with it.

## What changed

Host (Metal renderer and frame pacing), in the order of their effect:

- **Event gate** (`DM_NVN_EVENT_GATE=1`). Each frame the game queues its second large command list behind a wait for an event that its CPU signals once the first list's fence has passed. The host used to translate that list only when the wait was satisfied, and the GPU sat idle about 2.6 ms of every frame meanwhile. The wait is now put on the Metal queue itself (`waitForEvent`), and the commands behind it are translated and committed ahead of time; a watcher thread opens the gate within 50 µs of the game's signal. Only events that no command list ever signals, and whose waits were seen to block and pass 30 times within 40 ms, are gated; a gate that is not opened within 100 ms is forced open, that event is never gated again, and three forced gates turn the feature off for the run.
- **Pool-table buffers are reused** (96 spares instead of 16). The game patches 10-15 pool tables a frame; with 16 spares about four new 312 KB buffers were made every frame, each a residency-set add and remove. This removed most of the frames whose GPU time doubled (75 → 13 per walk).
- **MetalFX takes the upscale of `agl_ndsr_vr` again** (`DM_UPSCALER=metalfx`). Without it the game's own temporal upscaler ran every frame (about 1.6 ms of GPU) and ghosted the player character while turning.
- **The 60 fps hold stays put** (ticks mode). Three things kept a scene that runs at 57 fps at 40 instead: three slightly late frames in a row moved the hold up; at the 40 fps hold the GPU idles a third of each frame, macOS lowers its clock (1380 → about 1200 MHz) and the same frames then take 21.8 ms instead of 15.5; and the way back asked for a cost under 14.2 ms. Now the hold moves up only when 16 of the last 24 frames were late (`DM_FPS_STICKY`), a frame fits the shorter hold within 1.7 ms of it, and the GPU clock keeper has a mode that runs only while the game is held below its target (`DM_GPU_KEEP=hold`). Kokiri village in fullscreen: 44 → 56-58 fps.
- **Presentation without the display link** (`DM_PRESENT_LINK=0`). The present thread takes the screen's textures itself instead of waiting for a 120 Hz display link callback, and the frame step paces by the time of the texture's slot. Measured against the link in the fullscreen village, two walks each: 58.3 / 58.5 against 57.9 / 58.3 fps, and frames over 40 ms 3 / 1 against 23 / 18 (longest frame 30 ms against 140 ms); in the 20-minute run, frames over 40 ms fell from 163 to 3.
- **Frame step in ticks of 1/120 s for 60 fps** (`DM_FPS_TARGET=60` with `DM_FPS_TICKS=1`): on a 120 Hz screen a scene that cannot hold 60 runs at an even 40 before it falls to 30, and the game steps by the ticks, so its speed is right at every rate. Late-frame tolerance of 3.3 ms at every hold (`DM_FPS_LATE_TICKS`), and failed attempts at a shorter hold back off to once a minute, so a scene that holds 40 is not probed back to 60 every few seconds.
- `DM_FPS_TARGET=40` (hold 3 ticks), inherited from the base of this branch.
- A frame timeline trace (`DM_NVN_SEQ=<frame>`): the game's submits, fences and waits, the host's commits and every command buffer's GPU start and end for four frames. This is what found the idle GPU time.

Shader chain (needs the shader library rebuilt, which the packing script does): a float add to storage memory as one native atomic add, unused border corrections compiled out, game barrier bits, and a seven-word cache for raw global memory lookups. Together about 4 ms of GPU a frame in the village on the machine above.

Two more shader changes from open upstream pull requests, both by people measuring on this same GPU, took the last heavy views to 60: raw loads through one pointer resolve their pool once instead of once per word (#1752, in its port onto vector loads, merged here with the seven-word cache, which stays for the fallback lookup), and mesh shaders with 6-16 KB of stage memory take it from a device buffer instead of threadgroup memory (#2308). Against the same build without them, interleaved runs: the village walk 58.7 → 59.9 fps (GPU p50 16.6 → 15.8 ms, in an earlier run of the old build 54.6 fps with 17 % of frames at 40), Zora's Fountain facing the water 51.5 → 58.6 fps (60 % → 100 % of frames at 60). The picture was compared at the same camera positions in the village, the field and the fountain.

Taken from other people's work, with thanks: upstream pull requests #1752 (deanpektas27 and seedds; port by AmateurWizrd), #2308 (AmateurWizrd), #1952 (compute hoist, AdyaGMD), #2226 and #2030 (humanperzeus), #2193 (Know-It-All-Brother), the clock keeper of #1847 (seedds, off here), the FeReuss/nxnative-oot fork (float add, border corrections, barrier bits, render-scale stub) and the cheemu/kid-with-sword-remake fork (raw lookup cache). Their commits keep their authors.

Also taken from upstream after the base: `1d090a66` (uniform slots bounded at 256-byte multiples: white streaks and one-frame dropouts), `6a6a018d` (no stand-in pipelines for predicted keys whose base is made), `1e69c180` (a write to a page two pools share is no longer missed), and the open pull requests #2260 (texture views cached by Metal texture) and #2263 (partial texture re-uploads). #2260's `enc_thread on` for this game is not taken: the event gate does not run with the encode thread.

Tried and not kept as defaults, because they gave nothing on this machine: `DM_NVN_TBDR=1` (pass merging), the compute hoist (`DM_NVN_CS_HOIST`, set to 0 below), smaller or no segment cuts without the gate, and the GPU clock keeper at full or automatic duty (its own work costs up to 1 ms a frame while the game is at its shortest hold; `hold` mode avoids that).

## Build it with your own copy of the game

You need what upstream needs: an Apple silicon Mac with macOS 26.6 or later, Xcode 27.2, Homebrew, Python 3.12 or newer, and your own dump of the game as a `.nup` file or a folder (see the main [README](../README.md#switch-2-games)). The build takes about 1 h 15 min to 1 h 45 min on an M3 Pro (50-65 minutes of shader compiling, 12-27 of pipeline prebuild) and about 50 GB of free disk while it runs.

```
git clone -b ocarina-mac-60fps https://github.com/neko973/nxnative.git
cd nxnative
python3 scripts/build_ipa_from_nsp.py ~/Games/OcarinaOfTime.nup --platform mac-app
```

The script prints where it put the app. If it stops and names a flag (`--allow-other-metal` for another Metal toolchain version, `--allow-damaged` for a dump with damaged files), read its message and decide; this branch was built with both.

## Settings

The frame rate is chosen in the app's settings window (30, 40 or 60). The rest goes into the app's settings file, `~/Library/Application Support/nxnative/0400486024DEC000/env.txt`, one `KEY=VALUE` per line (create the folder and file if they are not there; delete a line to get its default back):

```
DM_OPMODE=1
DM_UPSCALER=metalfx
DM_PRESENT_INTERVAL=display
DM_NVN_DISPATCH_BARRIER=game
DM_FULLSCREEN=1
DM_SCREEN_MATCH=0
DM_FPS_TICKS=1
DM_NVN_EVENT_GATE=1
DM_NVN_CUT=0
DM_NVN_CS_HOIST=0
DM_GPU_KEEP=hold
DM_PRESENT_LINK=0
DM_FOCUS_KEEP=1
DM_METAL_HUD=1
```

- `DM_FPS_TICKS=1` makes the settings window's **60 fps** mean "60 where the scene holds it, an even 40 where it does not, 30 last". For frames that never change rate, choose **40 fps** there instead.
- `DM_SCREEN_MATCH=0` keeps a ProMotion screen at 120 Hz in fullscreen, which the 40 fps step needs.
- `DM_METAL_HUD=1` shows Apple's performance HUD. Its frame interval line is blue only for frames within 16.7 ms and red for anything longer, so 40 fps is red however even it is.

## Check that it works

The log is `~/Library/Logs/nxnative/0400486024DEC000.log`. After a minute of play it should contain:

- `event gate on (DM_NVN_EVENT_GATE)` and, every 1,800 gated waits, `event gate: N waits put on the Metal queue so far, open after X ms on average`. A line `[RED] ... event gate: the game's event ... did not come within 100 ms` means a gate was forced open; three of them turn the gate off for that run. Please report where it happened.
- `60 fps in ticks: the screen shows 120 Hz` (with `DM_FPS_TICKS=1` on a 120 Hz screen).
- `upscaler: first dispatch of fa3033d05c0a41d6_b drawn by MetalFX`.
- `frame step: game time X s in Y s (1.000 of real time); held 2 / 3 / 4 ticks a / b / c frames`: the share of frames at 60, 40 and 30 fps, and the game's speed.

Useful numbers to report with a result: the Mac and its GPU core count, fullscreen or window, the area, and a few of the `timing up to frame` lines (frame time and GPU p50 / p95).

## Known limits

- The heaviest views are on the edge on this GPU: the view from Link's house over the whole village and Zora's Fountain facing the water run 15.7-16.1 ms of GPU work a frame in fullscreen, so there is under 1 ms to spare there and a few percent of their frames show one refresh late. Smaller GPUs will not hold 60 in the village; the frame step then settles at an even 40.
- A pipeline that no list names is compiled at its first draw and kept; such a first draw can stall for 0.1-0.7 s once. The lists here cover ten areas. For the rest, the open upstream pull request #2307 (AmateurWizrd) is included: on a Mac with more than 16 GB, task / mesh pipelines are built in the background when the game makes their program (`DM_NVN_MESH_PREDICT=0` turns it off). In a room no list or archive had seen (the Water Temple's Dark Link room) frames over 40 ms fell from 10 to 1 and the compile time inside frames from 836 to 175 ms, for about 45 MB of memory; three other unseen areas ran the same with and without it.
- Anything else that uses the GPU or the video encoder while you play (screen recording, screen sharing, AirPlay) costs frames: with the screen being streamed, identical runs here varied between 41 and 56 fps.
- The event gate changes when part of each frame is translated. It was run through nine areas and a 4,800-frame video check per configuration without a picture fault, a forced gate or a crash, but it is new: `DM_NVN_EVENT_GATE=0` (or deleting the line) restores the old behaviour.
- Tested on one Mac only. Macs with 16 GB are tight: the game's footprint is about 11 GB.
- The first start after a build prepares pipelines for several minutes behind a progress screen.
