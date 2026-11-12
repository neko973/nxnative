# Ocarina of Time (Switch 2) on Apple silicon: the 60 fps branch

This branch is [seedds/nxnative](https://github.com/seedds/nxnative) at `adaff735` (2026-11-10) plus a set of changes aimed at one thing: The Legend of Zelda: Ocarina of Time (title ID `0400486024DEC000`, update v131072) at its full docked resolution (main passes 1536x864, picture 2048x1152) as close to a steady 60 fps as a mid-range Apple GPU allows, with the game at its real speed whatever the frame rate.

It contains no game files. You build the app from your own dump of the game, exactly as with upstream.

## What you get

Measured on a MacBook Pro with an M3 Pro (14-core GPU, 18 GB), fullscreen with the screen on, the built-in settings, by the intervals between the frames the screen actually showed (`@presented_ms`). "Late" is the share of frames shown more than 17.5 ms after the one before, the ones Apple's performance HUD draws in red:

| Area | Frame rate | Late frames |
|---|---|---|
| Kokiri village, 11 minutes of roaming around its middle | 60.0 fps | 0.1 % (longest interval 33 ms) |
| Kokiri village, the walk from Link's house (the heaviest view tested) | 59.8-60.0 fps | 0.1-0.6 % |
| Hyrule Field, walking | 60.0 fps | 0.1 % |
| Hyrule Field, running, rolling, sword, camera sweeps | 60.0 fps | 0.2 % |
| Kakariko | 60.0 fps | 0.0-0.1 % |
| Hyrule Castle courtyard | 59.8-59.9 fps | 0.2-0.5 % |
| Zora's Fountain, facing the water | 59.2 fps | 2.9 % (99th percentile 25 ms) |

The rows are 48 s walks from a save's starting point unless they say otherwise. Before this work the village ran 37.5 fps (GPU 22.4 ms a frame) and the field 42 fps in a window. Zora's Domain, the Water Temple, Jabu-Jabu, Gerudo Valley and Link's house ran at 59.7-60.0 fps in the same sweep.

One hour of ordinary play on the same Mac (222,600 frames, the game's own log) is the honest picture next to that table: 78 % of the time at 60, 17 % at 50-59 in views that need 16-17.7 ms of GPU work a frame, and 5 % at 40. The 40 fps time was the frame step staying down after short bursts (fixed: see the frame step entries below), and the session's ten longest frames were task / mesh pipelines built at their first draw (now built in the background). The GPU work itself is the game's: in a frame of the village, grass and foliage take about 3 ms, the froxel fog about 0.8 ms, and no load or store in the frame is avoidable. On this GPU a view needs to stay under about 15 ms of GPU work to hold 60.

In a window the picture is composited by the window server, which costs about 1.4 ms of GPU a frame here. Play fullscreen. The memory footprint stayed flat over the roam (11.1-11.3 GB). Slower GPUs than the one above will sit at 40 in the heavy areas; the frame step then keeps frames even (see below).

An earlier version of this page gave sweep numbers that were taken while the display was asleep (the runs' logs show a 2560x1440 drawable and no fullscreen switch); they are replaced by the screen-on numbers above.

The picture is the one the game draws docked with graphics scale tier 1: 3D passes at 1536x864, the picture at 2048x1152, as upstream drew it until `084f5aa5`. Upstream now answers tier 0 (1920x1080 and 2560x1440, about 56 % more pixels); here that is `DM_GFX_SCALE=0`. On this GPU the village then runs at an even 40 fps (52 fps unpaced) and the field at about 59.

## What changed

The numbers in this list are the before / after comparisons that led to each change. Several were taken at night with the display asleep, so read them as differences, not as what the screen shows; the table above is the screen-on result.

Host (Metal renderer and frame pacing), in the order of their effect:

- **Light passes drawn as one** (`DM_NVN_DEFER_LOAD=1`). The game draws each shadow-casting light as a small depth-only shadow map and then one light volume (a box of 36 vertices) into a full-size mask that it loads: eleven one-draw passes a frame in Kokiri village, each loading colour and depth and storing colour for one box. The renderer's pass deferral took only passes that start with a clear; with the switch a loading pass is deferred past the depth-only passes to its next pass on the same targets, so the eleven boxes are one pass after the eleven shadow maps. It runs without the rest of TBDR mode (which costs this game about 1 ms a frame) and only in that narrow shape. With the screen on, interleaved runs: late frames in the village walk 1.6 % without it and 0.1-0.6 % with it, GPU p50 in Kakariko 13.4-13.5 → 12.3-12.5 ms, in the heaviest village stretch 17.9 → 16.8-17.1 ms; an 11-minute village roam with it: 60.0 fps, 0.1 % late, longest interval 33 ms. The picture was compared in seven areas inside one run each (`DM_NVN_DEFER_AB=1` turns the deferral on after the second screenshot).
- **Event gate** (`DM_NVN_EVENT_GATE=1`). Each frame the game queues its second large command list behind a wait for an event that its CPU signals once the first list's fence has passed. The host used to translate that list only when the wait was satisfied, and the GPU sat idle about 2.6 ms of every frame meanwhile. The wait is now put on the Metal queue itself (`waitForEvent`), and the commands behind it are translated and committed ahead of time; a watcher thread opens the gate within 50 µs of the game's signal. Only events that no command list ever signals, and whose waits were seen to block and pass 30 times within 40 ms, are gated; a gate that is not opened within 100 ms is forced open, that event is never gated again, and three forced gates turn the feature off for the run.
- **Pool-table buffers are reused** (96 spares instead of 16). The game patches 10-15 pool tables a frame; with 16 spares about four new 312 KB buffers were made every frame, each a residency-set add and remove. This removed most of the frames whose GPU time doubled (75 → 13 per walk).
- **MetalFX takes the upscale of `agl_ndsr_vr` again** (`DM_UPSCALER=metalfx`). Without it the game's own temporal upscaler ran every frame (about 1.6 ms of GPU) and ghosted the player character while turning.
- **The 60 fps hold stays put** (ticks mode). Three things kept a scene that runs at 57 fps at 40 instead: three slightly late frames in a row moved the hold up; at the 40 fps hold the GPU idles a third of each frame, macOS lowers its clock (1380 → about 1200 MHz) and the same frames then take 21.8 ms instead of 15.5; and the way back asked for a cost under 14.2 ms. Now the hold moves up only when 36 of the last 48 frames were late, about a second of it, or 8 in a row by a whole tick (`DM_FPS_STICKY`; it was 16 of 24 and 3 until an hour of play showed 14 of 17 steps to 40 fps were for bursts already over), a frame fits the shorter hold within 1.7 ms of it, and the GPU clock keeper has a mode that runs only while the game is held below its target (`DM_GPU_KEEP=hold`). Kokiri village in fullscreen: 44 → 56-58 fps.
- **Presentation without the display link** (`DM_PRESENT_LINK=0`). The present thread takes the screen's textures itself instead of waiting for a 120 Hz display link callback, and the frame step paces by the time of the texture's slot. With the screen on, late frames with it and with the 120 Hz link: castle 0.2-0.5 % against 1.0-1.8 %, Kakariko 0.1 % against 8.1 %, the village walk 0.5 % against 5.0 %.
- **Frame step in ticks of 1/120 s for 60 fps** (`DM_FPS_TARGET=60` with `DM_FPS_TICKS=1`): on a 120 Hz screen a scene that cannot hold 60 runs at an even 40 before it falls to 30, and the game steps by the ticks, so its speed is right at every rate. Late-frame tolerance of 3.3 ms at every hold (`DM_FPS_LATE_TICKS`), and failed attempts at a shorter hold back off to once a minute, so a scene that holds 40 is not probed back to 60 every few seconds.
- **The way back from 40 fps takes a second** (`DM_FPS_IDLE`, on by default in ticks mode with direct presents). The frame step judged a frame's cost by the time between two frames' starts minus the pacing wait, but the game also waits for its texture's present and for its sync objects; at the 40 fps hold a frame with 11-13 ms of GPU work could cost 16-21 ms, never fitted 60 for thirty frames in a row, and only a probe brought 60 back: 89, 17 and 100 s at 40 fps in one hour of play. Those waits now count as idle time.
- **No pause at an autosave** (`DM_NVN_FINISH_PRESENT=0`). The game's autosave calls `nvnQueueFinish` on a low-priority thread that holds the mutex its presentation thread needs. The host waited there for the GPU and then for the queue's last present to reach the screen, one or two refreshes later, and the next frame waited with it: a frame of 36-45 ms at every autosave, 45 times in an hour of play. With the switch the call waits for the GPU only (the next acquire of a window texture still waits for that texture's own present). House to Kokiri Forest, the frame at the autosave: 36-45 ms in six runs without, no frame over 24 ms in two runs with.
- `DM_FPS_TARGET=40` (hold 3 ticks), inherited from the base of this branch.
- A frame timeline trace (`DM_NVN_SEQ=<frame>`): the game's submits, fences and waits, the host's commits and every command buffer's GPU start and end for four frames. This is what found the idle GPU time.

Shader chain (needs the shader library rebuilt, which the packing script does): a float add to storage memory as one native atomic add, unused border corrections compiled out, game barrier bits, and a seven-word cache for raw global memory lookups. Together about 4 ms of GPU a frame in the village on the machine above.

Two more shader changes from open upstream pull requests, both by people measuring on this same GPU, took the last heavy views to 60: raw loads through one pointer resolve their pool once instead of once per word (#1752, in its port onto vector loads, merged here with the seven-word cache, which stays for the fallback lookup), and mesh shaders with 6-16 KB of stage memory take it from a device buffer instead of threadgroup memory (#2308). Against the same build without them, interleaved runs: the village walk 58.7 → 59.9 fps (GPU p50 16.6 → 15.8 ms, in an earlier run of the old build 54.6 fps with 17 % of frames at 40), Zora's Fountain facing the water 51.5 → 58.6 fps (60 % → 100 % of frames at 60). The picture was compared at the same camera positions in the village, the field and the fountain.

Taken from other people's work, with thanks: upstream pull requests #1752 (deanpektas27 and seedds; port by AmateurWizrd), #2308 (AmateurWizrd), #1952 (compute hoist, AdyaGMD), #2226 and #2030 (humanperzeus), #2193 (Know-It-All-Brother), the clock keeper of #1847 (seedds, off here), the FeReuss/nxnative-oot fork (float add, border corrections, barrier bits, render-scale stub) and the cheemu/kid-with-sword-remake fork (raw lookup cache). Their commits keep their authors.

Also taken from upstream after the base: `1d090a66` (uniform slots bounded at 256-byte multiples: white streaks and one-frame dropouts), `6a6a018d` (no stand-in pipelines for predicted keys whose base is made), `1e69c180` (a write to a page two pools share is no longer missed), and the open pull requests #2344 (a texture ID's read mark is dropped after 600 frames unread, so area loads no longer freeze an hour into a session), #2260 (texture views cached by Metal texture) and #2263 (partial texture re-uploads). #2260's `enc_thread on` for this game is not taken: the event gate does not run with the encode thread.

Tried and not kept as defaults, because they gave nothing on this machine: `DM_NVN_TBDR=1` (pass merging), the compute hoist (`DM_NVN_CS_HOIST`, set to 0 below), smaller or no segment cuts without the gate, and the GPU clock keeper at full or automatic duty (its own work costs up to 1 ms a frame while the game is at its shortest hold; `hold` mode avoids that).

## Install it with your own copy of the game

You need an Apple silicon Mac with macOS 26.6 or later, Xcode from the App Store (opened once), [Homebrew](https://brew.sh), about 60 GB of free disk while it builds, and your own dump of the game as a `.nup` file or a folder (see the main [README](../README.md#switch-2-games)). Then:

```
git clone -b ocarina-mac-60fps https://github.com/neko973/nxnative.git
cd nxnative
./install-ocarina-mac.sh /path/to/your/OcarinaOfTime.nup
```

The script checks the Mac, installs what is missing after asking (the Homebrew packages `zstd` and `glslang`, a Python 3.12 or later if there is none, the Metal compiler; the Python modules `lz4`, `capstone` 5, `fonttools` and `zbic` go into a folder of their own, `.oot-venv`), builds the app and prints where it put it: next to your dump, named after the game. The build takes 1 h 15 min to 1 h 45 min on an M3 Pro (50-65 minutes of shader compiling, 12-27 of pipeline prebuild). The settings below are built into the app (`dm/games/0400486024DEC000/mac-60fps.env`), so there is nothing to set up. `./install-ocarina-mac.sh --check` only checks the Mac and builds nothing.

This was checked from a fresh clone of this branch on 2026-11-11: the three commands above gave a working app in 1 h 31 min (unpack 1.5 min, shaders 57 min, pipeline archive 27 min, packing and signing 3.5 min), with all 42,848 shaders built and the settings and the 43,900-row pipeline list inside the app. The work folder peaks at about 53 GB; once the app runs, deleting `shader/cache/cas.db` in it gives 10 GB back, and the whole work folder can go if you do not plan to rebuild.

The first start of the app prepares pipelines for several minutes behind a progress screen; later starts take seconds.

### Update to the newest version

```
cd nxnative
git pull
./install-ocarina-mac.sh /path/to/your/OcarinaOfTime.nup
```

Finished steps are reused: the unpacked game is kept in the work folder beside your dump (`0400486024DEC000_build`), so leave that folder and the dump where they are. Shaders are rebuilt when the update changed the shader tools, as the one of 2026-11-12 did.

If your folder came from GitHub's "Download ZIP" (it is then named `nxnative-ocarina-mac-60fps` and `git pull` says `not a git repository`), get a clone instead, which can be updated from then on, and run the script from it:

```
cd ~
git clone -b ocarina-mac-60fps https://github.com/neko973/nxnative.git
cd nxnative
./install-ocarina-mac.sh /path/to/your/OcarinaOfTime.nup
```

The old ZIP folder can go to the Trash afterwards.

### If it stops

The script says what is missing and the command that fixes it. The cases seen so far:

| Message | What to do |
|---|---|
| `the Command Line Tools are selected` or `Xcode is not installed` | Install Xcode from the App Store, open it once, then `sudo xcode-select -s /Applications/Xcode.app` |
| `The Metal compiler ... is not installed` | Answer `y`, or run `xcodebuild -downloadComponent MetalToolchain` |
| `Homebrew is not installed` | Install it from https://brew.sh, open a new Terminal window, run the script again |
| `the current Python ... is missing modules` | You ran `scripts/build_ipa_from_nsp.py` yourself with a Python that lacks them. Use `./install-ocarina-mac.sh`, which brings its own |
| `Capstone 6 ... is unsupported` | The same: the script's own Python folder has Capstone 5 |
| files `whose bytes do not start as their names promise` | Your dump has damaged files. Dump again, or add `--allow-damaged` to pack them as they are (three damaged textures did no visible harm here) |
| `built only with the Metal compiler they were tested with` | The script already passes `--allow-other-metal`; you see this only when you call the packing script yourself with another Xcode |
| `the shader translator does not run (exit code -11)` | The translator crashed when it was started (signal 11); your copy is not damaged. The translator this branch had until 2026-11-12 was built on macOS 27 and called a system function, `pipe2`, that macOS 26 does not have. The branch now has one built with Microsoft's .NET that does not use it, confirmed by a user on macOS 26.6.2: update as described above and run the script again. If it stops the same way after the update, run `dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate --source-sha; echo "exit $?"` in the `nxnative` folder, then `ls -t ~/Library/Logs/DiagnosticReports/dmsh_xlate* \| head -1`, and report the output and the first 60 lines of that file |
| `zsh: no matches found:` followed by your dump's path | The path has square brackets (or other characters the shell reads as a pattern), as in `[0400486024DEC000].nup`. Put it in single quotes, `./install-ocarina-mac.sh '/Volumes/Disk/[0400486024DEC000].nup'`, or type `./install-ocarina-mac.sh ` and drag the file into the Terminal window, which writes the path safely |
| the disk fills up | Free space and run the same command again: finished steps are reused |
| `this Python ... is an Intel one running under Rosetta` | Turn off "Open using Rosetta" for the Terminal app, or use `/opt/homebrew/bin/python3` |

To build by hand instead, what the script runs is `python3 scripts/build_ipa_from_nsp.py <dump> --platform mac-app --env-file dm/games/0400486024DEC000/mac-60fps.env --allow-other-metal --allow-shader-regressions` with a Python 3.12 or later that has the modules above.

## Settings

The frame rate is chosen in the app's settings window (30, 40 or 60). An app built with `install-ocarina-mac.sh` has the rest built in. To change one for yourself, or for an app built without the script, put it in `~/Library/Application Support/nxnative/0400486024DEC000/env.txt`, one `KEY=VALUE` per line (create the folder and file if they are not there; a line there wins over the built-in one):

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
DM_NVN_DEFER_LOAD=1
DM_FOCUS_KEEP=1
DM_METAL_HUD=1
```

- The settings window's **Texture filtering** is 16x for this game: the game itself asks for 1x and 2x, which blurs the ground and walls where the camera looks along them. It cost no measurable GPU time on an M3 Pro; **Game's own** gives the original back. **Texture size** is for Macs short of memory (see Known limits).
- `DM_FPS_TICKS=1` makes the settings window's **60 fps** mean "60 where the scene holds it, an even 40 where it does not, 30 last". For frames that never change rate, choose **40 fps** there instead.
- `DM_SCREEN_MATCH=0` keeps a ProMotion screen at 120 Hz in fullscreen, which the 40 fps step needs.
- `DM_METAL_HUD=1` shows Apple's performance HUD. Its frame interval line is blue only for frames within 16.7 ms and red for anything longer, so 40 fps is red however even it is.

## Check that it works

The log is `~/Library/Logs/nxnative/0400486024DEC000.log`. After a minute of play it should contain:

- `event gate on (DM_NVN_EVENT_GATE)` and, every 1,800 gated waits, `event gate: N waits put on the Metal queue so far, open after X ms on average`. A line `[RED] ... event gate: the game's event ... did not come within 100 ms` means a gate was forced open; three of them turn the gate off for that run. Please report where it happened.
- `60 fps in ticks: the screen shows 120 Hz` (with `DM_FPS_TICKS=1` on a 120 Hz screen).
- `upscaler: first dispatch of fa3033d05c0a41d6_b drawn by MetalFX`.
- `frame step: game time X s in Y s (1.000 of real time); held 2 / 3 / 4 ticks a / b / c frames`: the share of frames at 60, 40 and 30 fps, and the game's speed.

When judging smoothness from a `DM_NVN_TSV` table, read `@presented_ms` (the interval between the frames the screen showed, what the HUD's line shows; -1 is a frame that was never shown). `@display_ms` is the pacer's planned slot interval and `@frame_ms` the game-side interval; both alternate by a millisecond or more when the game runs ahead of the screen, which the screen does not show. Make sure the display is on: a run with the display asleep never goes fullscreen (its log has no `front end: drawable` line at the screen's size).

Useful numbers to report with a result: the Mac and its GPU core count, fullscreen or window, the area, and a few of the `timing up to frame` lines (frame time and GPU p50 / p95).

## Known limits

- The heaviest views are on the edge on this GPU: the view from Link's house over the whole village runs 15.3-15.9 ms of GPU work a frame and Zora's Fountain facing the water 16.0 ms, so there is under 1 ms to spare there; the fountain shows about 3 % of its frames one refresh late. Smaller GPUs will not hold 60 in the village; the frame step then settles at an even 40.
- A pipeline that no list names is compiled at its first draw and kept; a render pipeline's first draw can stall for 0.1-0.2 s once. Task / mesh pipelines (foliage and some models), which stalled 0.2-0.35 s each, are built in the background when the game makes their program, on a Mac with more than 16 GB (upstream pull request #2307 by AmateurWizrd; `DM_NVN_MESH_PREDICT=0` turns it off). An earlier state of this branch had it off because one run in about twenty aborted with it at the Water Temple's entrance; the cause was in this tree's function descriptors (a shader loaded again on another thread put an unspecialized descriptor back for a moment) and is fixed. A first session builds its pipelines in the background once, for about 500 MB.
- Anything else that uses the GPU or the video encoder while you play (screen recording, screen sharing, AirPlay) costs frames: with the screen being streamed, identical runs here varied between 41 and 56 fps.
- The event gate changes when part of each frame is translated. It was run through nine areas and a 4,800-frame video check per configuration without a picture fault, a forced gate or a crash, but it is new: `DM_NVN_EVENT_GATE=0` (or deleting the line) restores the old behaviour.
- Tested on one Mac only, with 18 GB. The game holds about 11.5 GB, so a Mac with 16 GB is tight. With 2 GB pinned by a helper, which leaves this Mac what a 16 GB one has, the test walk still ran 60.0 fps with 0.1 % of frames late; if yours stutters while areas load, choose **Texture size: Smaller** in the settings window (about 0.4 GB less, softer surfaces up close). On a Mac with 8 GB that choice is made automatically, upload staging is released after each batch, and at critical memory pressure the game gives back what no frame needs; no such Mac has been tested, and its GPU will not hold 60 fps in any case ([what these do](reference/memory.md#less-memory-on-a-mac-that-has-less-smaller-textures-staging-released-a-trim-at-memory-pressure-shader-code-pools-left-out)).
- The first start after a build prepares pipelines for several minutes behind a progress screen.
