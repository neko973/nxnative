# Ocarina of Time (Switch 2) on the Mac: the `oot-mac20` branch

A test branch of [seedds/nxnative](https://github.com/seedds/nxnative) for The Legend of Zelda: Ocarina of Time (Switch 2, `0400486024DEC000`, update v131072) on Apple silicon Macs, docked. It is upstream `main` at `7f502220` (2026-11-09) plus the fixes below. Nothing here contains game files: you build it from your own dump, as with upstream.

Tested on a MacBook Pro M3 Pro (18 GB, 120 Hz ProMotion), macOS 27.

## What it adds to upstream main

Picture:

- **Whole-scene flicker fixed** (profile `gpu_ts_hz 31250000`, from padsiwono's PR #1714 / the Mighty-Green-Kokiri-Kid fork). The game reads its raw GPU counter reports at the Switch 2's 31.25 MHz system counter rate. At NVN's 614.4 MHz its wind and particle step was 19.66 times too large: grass, leaves and hanging plants whipped every frame, and standing still in Hyrule Field the ground flipped material (stone path to dirt) in single frames. Measured over 8 consecutive frames standing still, the share of pixels that change for one frame and come back went from 10.9% to 0.004%, brightness flashes from 19.3 to 0.06.
- **MetalFX draws Ocarina's upscaler in the right colours.** Upstream leaves `agl_ndsr_vr.pck` to the game's own network (its colour shape counts as "keep"). Here `game.py` lists `agl_ndsr_vr*.pck` and a variant whose code squares its square-root-encoded output is squared into MetalFX's HDR input (`UP_COLOR_SQ`), so `DM_UPSCALER=metalfx` works on this game and is not washed out.
- **PR #1844** (`-fwrapv`): mesh-shader models no longer take light from the wrong probe texels (the bright band on the Deku Tree's walls, the pale patch at the Kokiri Forest exit, which shimmered while the camera moved).
- **PR #1707**: game-mode passes hold the next pass's task and mesh shaders (a one-frame darkening in Kokiri Forest).

Speed and smoothness:

- **Real game speed at any frame rate** with `DM_FPS_TARGET=0`: the community Dynamic-fps step (the frame's measured time × the base rate when slower) on main's function-matched frame-ratio stub. Upstream's `fps_target 60` steps in whole vsyncs (60 or 30); at target 0 upstream runs the game's own ratio, which is slow motion below 60 fps.
- `DM_NVN_DISPATCH_BARRIER=game`: consecutive compute dispatches ordered by the game's barriers instead of one barrier each (Kokiri Forest 56 → 60 fps on the M3 Pro, measured earlier).
- PRs **#1847** (acquire sync, GPU clock keeper, store-witness set), **#1045** (MetalFX at the present snapshot, leaving a shifted display link in VRR fullscreen), **#1825** (absent pipeline bases cached), **#1320** (wide GPU writes as intervals), **#1840** (no recompaction of a large warm pipeline cache at every launch), **#1708** (mesh grids of at most 1024 workgroups), #1331's second commit (NDVE reconstruction skipped after direct movie scaling).
- Graphics scale tier 0 docked; NDVE movie frames scaled directly (`DM_NVN_NDVE_MOVIE_DIRECT=1`).

Tools: `DM_CTL` `shotk <k> <path>` takes the kth presented frame from now, with up to 64 queued shots, for runs of consecutive frames in flicker checks.

Also present but off by default: the MetalFX temporal upscaler (`DM_UPSCALER=metalfx-temporal`, camera motion vectors from the scene depth). It is not recommended yet: without projection jitter it is softer than the spatial scaler, and its output has a cool, flat cast.

## Build and run

As upstream: `python3 scripts/build_ipa_from_nsp.py <your .nup or NSP folder> --platform mac-app --gpu none --allow-damaged -o "<name>.app"`. The first build translates all 42,848 shaders (about an hour on an M3 Pro). `--allow-damaged` is only needed if your dump has the three `.bntx.zs` files that are not zstd streams.

The first launch prepares about 13,500 render and 2,300 compute pipelines in the background (several minutes, with lag spikes while it runs); later launches do not.

## Recommended settings

`~/Library/Application Support/nxnative/0400486024DEC000/env.txt`:

```
DM_OPMODE=1
DM_FPS_TARGET=0
DM_NVN_NDVE_MOVIE_DIRECT=1
DM_PRESENT_INTERVAL=display
DM_UPSCALER=metalfx
DM_NVN_CUT_BUSY=0
DM_NVN_DISPATCH_BARRIER=game
DM_METAL_HUD=1
DM_FOCUS_KEEP=1
```

`DM_FOCUS_KEEP=1` keeps presenting while the window is not in front: without it the game piles up retired GPU buffers out of focus (upstream PR #1392 reports 11 → 20 GB in 12 s), which can freeze a Mac with 18 GB or less. `DM_METAL_HUD=1` shows the frame rate; delete the line to hide it.

## Results on the M3 Pro (docked, full 1536x864, MetalFX)

- Standing in Hyrule Field: about 54 fps, GPU about 18.4 ms a frame; Link's house and Kokiri Forest about 60.
- No whole-scene flicker standing or walking in consecutive-frame captures; one-frame pixel changes while walking 0.03-1% depending on the view (foliage motion).

## Known open

- Full 60 in Hyrule Field needs about 2 ms less GPU time.
- The MetalFX temporal path needs jitter (sharpness) and a colour fix.
- PR #1392's GPU memory guard is not ported (the setting above avoids its cause).
