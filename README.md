# Ten Thousand Years

A full-depth, turn-based hex 4X for iPad and iPhone. Design spec: [docs/SPEC.md](docs/SPEC.md).

**Status: M0 (tech spike).** Map generation, deterministic simulation core, custom Metal hex renderer (tilted 2.5D camera, blended terrain, fog of war, east–west wrap), unit movement with path preview.

## Requirements
- Xcode 26+, iOS/iPadOS 18+ target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Commands
| | |
|---|---|
| `make open` | Generate the Xcode project and open it |
| `make test` | Engine unit tests on macOS, including offscreen Metal renders (`RENDER_OUT=dir` saves PNGs) |
| `make headless` | Determinism + perf check: Large map, 100 turns, 300 extra units. Run twice; hashes must match. |
| `make sim` | Build the app for the iPad simulator |

## Playing the spike
- **Tap** a unit to select it, tap a tile to preview the path (numbers = turn of arrival), tap the same tile again to move.
- **Drag** to pan (one or two fingers, or trackpad scroll), **pinch** to zoom, **long-press** a tile for info.
- **Next Unit / End Turn** button (or Space on a keyboard).
- 🐞 menu: spawn stress units, move every unit at once, flyover pan, toggle tilt, fog, grid and render stats (fps / CPU / GPU ms).

### Launch arguments (benchmarks/automation)
Set in the Xcode scheme or pass to `simctl launch`:
`-autostart large -seed 42` skip the start screen · `-revealMap YES` · `-stress 300` · `-cameraScale 3` · `-showSeam YES` · `-topDown YES`

## M0 exit criteria (SPEC §16)
- [x] GameCore determinism: same seed + commands → identical state hash (`make headless`, `replayIsDeterministic` test)
- [x] Large map (104×64) renders with fog, units, wrap, pan/zoom/select
- [ ] **60 fps on an A14-class device** (iPhone 12 / iPad 10th gen) with Large map + 300 units + flyover: needs a real device; the simulator doesn't count
- [x] Renderer decision recorded: custom Metal (SPEC D20)
- [ ] GPU frame time and texture memory read on device (the simulator reports meaningless GPU times)
