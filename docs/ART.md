# Map Art Direction

The map should read like a **hand-painted storybook diorama under warm afternoon light**: the
"painterly 2.5D top-down" of SPEC §13.3. All art is original and procedural (Core Graphics
atlases drawn at startup, Metal shaders); there are no image files.

Numbers below are measured on 1600×1100 renders (pixel scale 2) with
`MapRenderer.animationTime` fixed; isolate layers with `MapRenderer.passes` and `backdrop`.
S is the HSV saturation of the median colour, L* is CIELAB lightness and ΔE is CIEDE2000.
`s` is the tile size (centre to corner).

## 1. Light
- One sun, from the **upper-left of the screen** (west-north-west, high): uniform `sun`,
  `normalize(-0.55, 0.45, 0.70)` in world space (+x east, +y north, +z up).
- Lit faces point west, north and up; core shade sits on east and south faces; **cast
  shadows fall to the lower-right** (ground direction (0.77, −0.63)). Nothing may imply a
  second light.
- Highlights are warm: cream or gold (hue 40–50°), mixing toward sunlight
  (1.00, 0.93, 0.72–0.76) by at most 25% and raising value by at most ×1.2.
- Shades are cool: blue-violet (hue 230–260°), mixing toward the sky by at most 30% at value
  ×0.70–0.80. Never neutral grey or black. Ambient fill is a faint sky blue.
- Never mirror a sprite whose painted light is one-sided (relief, trees, figures): that puts
  the lit face on the east. Mirroring is only for symmetrically lit art such as reeds and
  grass tufts, and for flat ground art lit only from above (a settlement's ground, §11).

## 2. Value and color
- Three value bands: water (deep to mid), land (mid to light), peaks and snow (lightest).
  Water stays darker than the land beside it; snow, ice and snowcaps are the lightest values
  in any view (L* 80–93).
- The darkest ink anywhere is a warm brown-black, about (0.10–0.13, 0.07–0.09, 0.05–0.07).
  No pure white: no channel above 0.96 on large areas.
- Terrain saturation is moderate, harmonious and slightly warm: land mean S ≤ 0.45
  (grassland median ≤ 0.48, plains ≤ 0.45). Variety comes from value (two or three steps
  per biome), not chroma.
- Canopies are at least as saturated as the ground (S 0.40–0.50, no green crown below 0.38).
  Jungle is darker (V −0.08 to −0.12) and 20–40° cooler than forest.
- **Units out-contrast the terrain**: mean S at least the ground's + 0.15, and silhouette
  rim contrast |ΔL*| ≥ 15 on every terrain, so they pop at every zoom.
- **Player colors are reserved for ownership** and never appear in terrain or decoration. No
  terrain or decoration colour may move closer to the eight player colours than it is today
  (closest pairs: desert and yellow 14.1, grassland and bluish green 17.3, plains and yellow
  18.8 ΔE), and saturated accents (S > 0.35: coral, blossoms, flowers) stay at least 15 ΔE
  from all eight.

## 3. Edges
- Sprites: a warm-dark ink outline on the silhouette at alpha 0.40–0.50, 2.0–2.4% of the cell
  edge wide (relief skylines may thin to 1.4–1.6%). Interior lines are at most 60% of that
  width, at alpha ≤ 0.30.
- Units also carry a cream outer rim (1.00, 0.96, 0.86), 1.5–2 pt wide at alpha 0.40–0.50,
  outside the ink line. On ground lighter than L* 55 a 1.25 pt warm-ink line runs outside
  the cream.
- Ground: no outlines. Terrain transitions stay soft and organic (the per-tile noisy blend);
  no painted shape has a straight or polygonal edge longer than 0.3 tile.
- The hex grid is a faint guide, never a design element. Weber contrast across hex edges at
  zoom 0.6: 0.06–0.10 on grassland (still visible at standard zoom), ≤ 0.07 on plains, desert
  and tundra, ≤ 0.05 on snow, ≤ 0.02 (invisible) on water, ice, scree and rock. The line
  mixes toward a warm mid-tone of the local ground, never toward black, and is ×0.6 on
  explored tiles.

## 4. Painterly surface
- Surfaces carry brush-like strokes and patches at two or three scales (regional tint,
  patches, fine strokes) instead of blurry noise.
- Fine detail fades out before it can shimmer or alias (scale it by pixel footprint) and
  holds up at the 72% render scale (§10).

## 5. Grounding
- Everything that stands has a **contact shadow**: colour (0.09, 0.09, 0.19), peak alpha
  0.40–0.45, centred about 0.12 × the sprite width toward the lower-right, soft-edged.
  Sprite bases melt into the ground; nothing floats.
- The ground models the landforms: its baked relief rises in broad domes under hills, in
  massif shoulders under mountains and under every relief sprite's footprint
  (`MapRenderer.reliefFootprints`), lit by the same sun (§1), so peaks and mounds stand on
  shaded slopes, never on flat hex plates.
- Cast shadows are one family everywhere: colour (0.10, 0.10, 0.20), pointing straight away
  from the sun, 0.6 × the painted height long. Foot alpha is 0.36–0.40 for standing sprites
  (trees, palms, peaks, mesas, units) and 0.28–0.32 for low mounds, ridges and benches,
  falling off as foot × (1 − 0.65t) from the foot (t = 0) to the tip (t = 1) and blurring
  with it (mip bias 1 + 2t). Where shadows overlap, the result is at most 10% darker than
  the darkest single shadow there.
- Units stand **among** trees, not on them: a unit's base wash and shadows lie under the
  decorations, and plants standing just in front of a figure cover its legs, hooves and
  wheels (never its body, shield, wagon or standard; at least 75% of a unit stays visible).
  Only thin UI lines (base bands, the selection ring, routes) lie over the trees.

## 6. Shape and variety
- Chunky, readable silhouettes with slight irregularity.
- Heights: broadleaf trees 0.57–0.75 s, pines 0.64–0.84 s, mounds 0.25–0.75 s, ordinary
  summits 0.75–1.3 s, hero summits (at most one per six or so range tiles) 1.7–2.0 s; nothing
  taller than 2.0 s. At zoom ≤ 0.6 a unit's painted figure (feet to helmet, standard
  excluded) is at most 1.35 × a broadleaf tree and 0.55 × the tallest summit in view.
- Variety comes from seeded procedural variation (shape, size, tint, placement; mirroring
  only as §1 allows). Nothing may look tiled, stamped or repeated side by side: no straight
  sprite foot longer than 0.2 tile, no two neighbouring instances of the same variant at the
  same scale (±10%), and no three consecutive feet along a hex row within ±0.1 s of the same
  y.

## 7. Motion
- Subtle and slow: water shimmer, washing foam, river flow, gentle sway, banner flutter.
  Nothing flickers, and nothing pops on zoom, detail changes or exploration.
- The view runs at 30 fps while only ambient motion plays, so ambient animation must read
  smoothly at 30 fps: nothing moves faster than about 3 Hz.
- The animation clock wraps every hour: every animation completes whole cycles per 3600 s
  (phase = 2π·fract(t·N/3600) with integer N).

## 8. Fog of war
- **Unexplored:** a soft painted layer of cloud or mist (cool dark blue-grey, darker than
  explored land) with gently drifting edges.
- **Explored, not in sight:** a desaturated, cooler, darker version of the map that stays
  legible; every pass applies the same explored-fog look.
- Fog never leaks information. Anything shown on an explored tile depends only on that
  tile, its explored neighbours or world noise; instances that straddle an edge stay hidden
  until both tiles are explored; sprites on unexplored tiles stay hidden. Two worlds that
  differ only on unexplored tiles render within 6/255 of each other at every zoom.
- **Routes into the unexplored:** a route's chevrons, dots and turn markers stop at its last
  explored step. From there faint open rings follow the rest of the planned steps to the
  destination ring, with no turn markers: a guess, where the filled dots are a plan. The plan
  counts unexplored tiles as passable land (M1 §8.6), so the rings show only what the viewer
  knows, and they never cut straight across water or land the plan goes around.
- **Past the poles** lies the polar pack (closed ice) under a pale haze that thickens over
  about four tiles; farther out, broad banks of mist drift west over it, lit on their sunward
  sides and thinning where the pack shows through. Light and low in contrast, it never reads
  as the unexplored bank, and a view zoomed out past the map's height (§9) never shows an
  empty or flat band. An off-map tile takes its edge tile's fog for one row, or two or three
  (seeded by column) where the edge tiles beside it share it, so the light over a seen edge and
  the cloud over an unexplored one carry on a little and end raggedly; farther out it is
  explored all along the edge, so no edge row's fog repeats out into the haze.

## 9. Readability (SPEC §1.5, §14.4)
- At every zoom you can tell terrain types, ownership and units apart.
- Zoom levels: close (camera scale about 0.35–0.6), standard (about 1), strategic (2.1, where
  the medallions take over, and wider, or the widest zoom where the wrap stops short of 2.1).
  Design for all three; decorations thin out and simplify when zoomed out.
- The widest zoom keeps the far edge of the view within 0.92 of a world period (no wrapped
  copy shows twice) and the view no taller than the map plus 0.6-row polar margins, but the
  map's height never stops zoom-out short of 2.3 (`MapCamera.zoomOutFloor`): an upright iPad
  or iPhone zooms out past the poles, the map centred, and reaches the strategic level on
  every map (about 2.27 on an upright 11-inch iPad on the Duel map, where the wrap sets the
  limit). Where the wrap stops zoom-out short of 2.1, the view already spans most of the map's
  width, so the medallions take over at the widest zoom instead: they come in at 2.1 or at 98%
  of the widest zoom, whichever is lower, and go below 1.9/2.1 of that
  (`MapRenderer.strategicSwitch`). The widest zoom with the tilted camera (* where the wrap
  stops it short of 2.1):

  | View (points) | Duel | Small | Standard | Large |
  |---|---|---|---|---|
  | iPhone upright (402×874) | 2.30 | 2.30 | 2.30 | 2.90 |
  | iPhone on its side | 2.17 | 2.95 | 3.94 | 4.00 |
  | iPhone Pro Max on its side (956×440) | 1.98* | 2.70 | 3.60 | 4.00 |
  | iPad mini on its side (1133×744) | 1.67* | 2.28 | 2.68 | 3.40 |
  | 11-inch iPad upright (834×1210) | 2.27 | 2.30 | 2.30 | 2.30 |
  | 11-inch iPad on its side | 1.56* | 2.13 | 2.39 | 3.04 |
  | 13-inch iPad upright (1032×1376) | 1.83* | 2.30 | 2.30 | 2.30 |
  | 13-inch iPad on its side | 1.38* | 1.88* | 2.30 | 2.45 |

  The top-down camera's far edge is no wider than its near one, so the wrap allows a little
  more there (1.85 on the Duel map on an 11-inch iPad on its side).
- Ownership is never shown by color alone: each player also has an emblem and a ring
  pattern (solid, double, dashed, beaded, notched, rope, chevron, thick-thin).
- At strategic zoom each occupied hex shows one medallion: the unit type's pictogram (at
  least 11 pt), the owner's emblem badge (at least 9 pt) and a frame in the owner's colour
  and ring pattern. The shader composes it from the pictogram cell, the procedural ring
  pattern and the emblem cell, so the unit atlas holds no per-player medallions.
- The six unit types (settler, builder, scout, warrior, archer, spearman) are told apart at
  every zoom by silhouette and gear, not colour: ox cart; tool-carrying labourers with a
  wheelbarrow; horseman; axes and clubs (at most one small buckler); bows drawn to the jaw;
  spears with big round shields. Their pictograms: cart, crossed pick and hammer, horse head, sword, bow,
  rimmed shield with a spear.
- A tap on a unit's drawn token selects its tile; a tap on a city's buildings or token
  selects the city (a unit standing in a city is drawn over it and wins); a tap on open
  ground beside them selects the tile under the finger.

## 10. Budgets
- 60 fps on an A14-class device is the target. Use the gallery's GPU timings (release build,
  interleaved A/B runs, minimum of many frames) as a relative measure: no view may get more
  than 30% slower than the baseline.
- Renderer setup at most 150 ms slower than the baseline; decoration placement at most 30 ms
  on the Large map; total texture memory at most 48 MB on the Large map, 50 MB at the very
  most (M1 §15). Atlases: decor 2048×1536, units 2048×1536 since M2's nine land units (which
  share their data cells two to a cell and mirror their west-facing body to face east: placeholder art, so their sun is on the
  wrong side facing east, the one exception to the no-mirroring rule above),
  settlements 2048×512 (§11); the shaders take their sizes from the atlases (`kUnitAtlasTexels`,
  `kTownAtlasTexels`).
- East–west wrap stays seamless (noise periods tied to map width; sprites instanced across
  the seam).
- No MSAA: every edge is antialiased by the art itself (analytic coverage in shaders,
  texture alpha on sprites).
- The view runs at full rate during gestures, camera moves and unit moves, and at 30 fps
  otherwise (§7).
- On devices whose GPU cannot hold 60 fps, the render scale drops (to 72% at most):
  detail must hold up slightly soft.
- Decorations are drawn only near the view: the decoration buffer is [cast shadows][standing
  sprites], each block sorted by descending y (long sorted runs are cut to the visible rows),
  `sizeAnchor` holds each sprite's true extents, and no sprite may reach farther from its
  anchor than its largest side.
- All shader files are concatenated into one source, so helper functions carry their area's
  prefix (`ground…`, `decor…`, `unit…`).
- Costly code that only some pixels need still costs every pixel of its shader (registers),
  so the ground's farm fields live in a second variant of the ground shader (function
  constant `kGroundFields`): the stencil marks squares around known farms, the plain ground
  fills the rest and the fields variant only the marked pixels (about 10% of g01's GPU time).
- Improvement decorations stand on every tile that could take one and are hidden in the
  vertex shader until built: about 3,700 more instances on a Large map (about 28,000 in all;
  placement about 4.5 ms in a release build).
- **Measured at the M1 hand-off** (Apple M5, macOS 26.5, release build, 1600×1100 at pixel
  scale 2, fog off; the pre-M1 engine against the M1 one, each run in its own process, four
  interleaved rounds of 60 frames per view after 3 warm-up frames; minimum GPU time over all
  rounds; lab in `build/m1/art-ab`):

  | View | pre-M1 ms | M1 ms | Change |
  |---|---|---|---|
  | g01 world, tilted (Standard map) | 3.83 | 3.78 | −1% |
  | g03 strategic | 4.17 | 4.41 | +6% |
  | g05 units, close (Small map) | 5.15 | 5.96 | +16% |
  | 300 units at standard zoom | 7.46 | 8.09 | +9% |
  | units in woods | 5.85 | 5.73 | −2% |
  | the city stretch, standard zoom, no M1 inputs | 5.40 | 6.38 | +18% |
  | the same, strategic zoom | 4.68 | 5.06 | +8% |
  | the same with cities, territory and improvements, standard | | 6.93 | +28% on pre-M1 plain |
  | the same, strategic | | 5.21 | +11% on pre-M1 plain |
  | g15 skirmish (overlays, combat units) | | 7.09 | |
  | g15b skirmish close up | | 7.07 | |

  Renderer setup (Standard map, cold process, median of the rounds): 148 ms pre-M1, 170 ms
  M1 (+22 ms). Textures: 36.5 MB pre-M1 and 41.9 MB M1 on the Standard map, 43.2 MB M1 on
  the Large map (of the 5.4 MB added, 5.3 MB is the settlement atlas with its mipmaps). Atlases: decor
  2048×1536, units 2048×1024, settlements 2048×512.
- **Measured for the zoom-out floor** (§9; Phase 3b, the same lab on a heavily loaded machine:
  ten interleaved rounds of 60–100 frames per view with the old build first in each round,
  then four with the new build first; the median of each view's per-round minimum; a mid game
  with fog, upright iPad 834×1210 pt at 2x, iPhone 402×874 pt at 3x; lab in
  `build/m1/p3b-art/ab`). Each view's new widest zoom against its old one:

  | View | old widest | ms | new widest | ms | Change | New first |
  |---|---|---|---|---|---|---|
  | Duel, upright iPad | 0.88 | 9.86 | 2.27 | 8.93 | −9% | −29% |
  | Duel, upright iPhone | 1.22 | 8.31 | 2.30 | 7.93 | −5% | −24% |
  | Duel, iPad on its side | 1.28 | 8.70 | 1.56 | 8.73 | 0% | −7% |
  | Small, upright iPad | 1.26 | 7.70 | 2.30 | 7.80 | +1% | +15% |
  | Small, upright iPhone | 1.75 | 7.08 | 2.30 | 6.56 | −7% | −6% |
  | Standard, upright iPad | 1.65 | 7.19 | 2.30 | 7.70 | +7% | −2% |
  | Standard, upright iPhone | 2.28 | 5.91 | 2.30 | 6.38 | +8% | +1% |

  Views with the same camera in both builds (g01, g03, g04, g05, 300 units, woods and these
  views at the old zoom) changed by −4% to +11% (median +4%) with the old build first, but by
  −26% to +19% (median −6%) with the new one first: on this machine the second process of a
  round runs slower. Averaged over both orders they changed by −14% to +9% (median −2%), so no
  cost shows above the noise.

  Renderer setup (Standard map, a fresh process each, six interleaved runs per build, median):
  114 ms in both with the Metal shader cache warm. With it cold (a new shader source each run,
  as on a first launch after an update) it took 1300 ms before and 1363 ms after: +63 ms, of
  which 26 ms compiles the longer source and 41 ms builds the pipelines. The second renderer
  takes 15 ms in both, and textures stay at 41.9 MB.
- **Measured for routes into the fog and the medallions at the widest zoom** (§8, §9; Phase
  3d, the same lab on a loaded machine, lab in `build/m1/p3d-art/ab`). Ten interleaved rounds
  of 80 frames per view, six with the base (p3s) first and four with the new build first.
  Other processes' GPU work made a view's per-round minimum vary up to threefold, so the table
  takes each view's minimum over all rounds (the iPad views at 2x, the others 1600×1100 at
  2x):

  | View | Zoom | Base ms | New ms | Change |
  |---|---|---|---|---|
  | g01 world, tilted (Standard map) | 1.6 | 3.62 | 3.62 | 0% |
  | g04 start in the fog (Small map) | 1 | 3.26 | 3.27 | 0% |
  | g18 route into the fog (Duel map, upright iPad) | 1 | 4.82 | 4.81 | 0% |
  | the same close up | 0.6 | 5.11 | 5.08 | −1% |
  | the same at the widest zoom | 2.27 | 5.46 | 5.25 | −4% |
  | a 30-step route into the fog (Standard map) | 1 | 1.59 | 1.60 | 0% |
  | the same | 1.8 | 1.79 | 1.79 | 0% |
  | Duel mid game, iPad on its side (medallions in new) | 1.56 | 6.09 | 6.19 | +2% |
  | the same, 13-inch iPad on its side (medallions in new) | 1.38 | 8.39 | 9.15 | +9% |
  | the same, 13-inch iPad upright (medallions in new) | 1.83 | 8.27 | 8.25 | 0% |
  | the same, upright iPad (medallions in both) | 2.27 | 5.91 | 6.78 | +15% |

  The last view draws the same in both builds: in quiet rounds both took 6.78–6.80 ms, and
  only the base reached 5.9 ms (twice). In-process pairs settle it: two renderers in one
  process with their frames interleaved, five rounds per build in both orders, comparing the
  median ratio of their minima, new's over base's. The route against no route: −0.1% on g18
  and on the 30-step route. The borders against none (the overlay shader, the only GPU code
  that changed): +0.4%. The widest zoom against 4% short of it (medallions against figures in
  new, figures in both in base): −0.3% on an iPad on its side, −0.7% on a 13-inch on its side,
  +0.5% on a 13-inch upright. The route's overlay geometry, rebuilt on the CPU every frame,
  grew from 786 to 1044 vertices on g18 (20–22 to 24–28 µs) and from 1518 to 2424 on the
  30-step route (42–43 to 45–59 µs).

  Renderer setup (Standard map, a fresh process each, six interleaved runs per build, median):
  119 ms base and 138 ms new with the Metal shader cache warm (per round −3 to +67 ms, median
  +6; the setup code didn't change), 1426 and 1419 ms with it cold. The second renderer takes
  16 ms in both, and textures stay at 41.9 MB.
- **Measured for the Builder job marks, settler site rings and wash, and route dots** (§12,
  §13; Phase 3f, lab in `build/m1/p3f-art/ab`, a heavily loaded machine). Six interleaved
  rounds of 60 frames per view, the base (p3ds) and the new build each in its own process,
  alternating which goes first; each view's minimum GPU time over all rounds (the iPad views
  upright at 2x, the others 1600×1100 at 2x):

  | View | Zoom | Base ms | New ms | Change |
  |---|---|---|---|---|
  | g01 world, tilted (Standard map) | 1.6 | 3.62 | 3.60 | −1% |
  | g04 start in the fog (Small map) | 1 | 3.31 | 3.31 | 0% |
  | g19 T8 Builder (Duel map, upright iPad) | 0.45 | 8.78 | 8.75 | 0% |
  | the same at standard zoom | 1 | 6.87 | 8.12 | +18% |
  | g19j T33 Builder on its job | 0.45 | 11.82 | 9.20 | −22% |
  | g19g T39 settler overlay | 1 | 10.12 | 6.45 | −36% |
  | the same closer | 0.6 | 11.81 | 8.43 | −29% |
  | g19i T36 ready Settler | 0.45 | 9.47 | 8.51 | −10% |
  | g18 route into the fog | 1 | 5.93 | 5.93 | 0% |
  | g18e later turns over remembered land | 1 | 5.79 | 5.78 | 0% |
  | the same zoomed in | 0.35 | 8.10 | 11.00 | +36% |

  Only the controls held still: an iPad view's per-round minimum varied up to 2.6-fold within
  one build (g18f: base 8.1–15.3 ms, new 11.0–15.2), so the iPad rows show the load, not the
  change. In-process pairs settle it: two renderers in one process, one with the feature and
  one without, frames interleaved, five rounds per process and two processes per build; the
  median ratio of their minima, with over without:

  | Pair | Base | New |
  |---|---|---|
  | T8 Builder's guidance against none (0.45) | −1.2% | −0.5% |
  | T33 Builder's guidance against none (0.45) | −1.3% | −2.0% |
  | T39 settler overlay against none (1) | +0.4% | +0.2% |
  | the same (0.6) | −1.1% | −0.4% |
  | g18 route against none (1) | +0.5% | −0.1% |
  | later turns' dots over remembered land against none (1) | +0.2% | −0.2% |
  | the same (0.35) | +0.4% | −0.3% |

  The new marks, rings, wash and dots cost within 0.7% of what the base drew there. Nesting the
  job ring inside the selection ring on the Builder's own tile (§12) draws the same sprites on
  the same quads; the T33 pair again, in two processes of five rounds each: +0.7% at 0.45
  (g19j) and −1.6% at standard zoom (g19k), medians.

  Renderer setup (Standard map, the first renderer of each of six processes per build, median):
  174 ms base, 181 ms new; one new run took 1386 ms, the first after the build, as with a cold
  shader cache. Textures are unchanged: 41.9 MB on the Standard map and 43.2 MB on the Large
  map. The unit atlas stays 2048×1024, since the three job glyphs take free cells.
- **Measured for the tribal villages** (§11; phase 3g, lab in `build/m1/art-ab-3g`; provisional:
  measured once while other work loaded the machine, to be re-run on a quiet one). Six
  interleaved rounds of 60 frames per view, the base (p3g0s, which drew H0's stub rings) and
  the new build each in its own process, alternating which goes first; each build's minimum over
  all rounds and the median of its per-round minima (the g20 views on an upright iPad at 2x,
  the others 1600×1100 at 2x):

  | View | Zoom | Base min ms | New min ms | Base median ms | New median ms | Change (medians) |
  |---|---|---|---|---|---|---|
  | g01 world, tilted (Standard map) | 1.6 | 3.59 | 3.59 | 3.59 | 3.60 | 0% |
  | g03 the same at the widest zoom | 3.62 | 3.18 | 3.48 | 3.46 | 3.57 | +3% |
  | g05 units round a start (Small map) | 0.4 | 3.82 | 4.30 | 4.72 | 4.66 | −1% |
  | g20 on hills beside a Scout | 0.45 | 8.30 | 10.40 | 10.63 | 10.68 | 0% |
  | g20b remembered in the fog | 0.6 | 9.08 | 9.09 | 9.09 | 9.12 | 0% |
  | g20c two tiles from the capital | 0.6 | 8.36 | 8.75 | 9.55 | 9.60 | +1% |
  | g20d at the widest zoom | 2.27 | 6.33 | 6.74 | 6.74 | 6.75 | 0% |

  The worst median change is +3.1% (gate +30%). The minima moved with the load (g20's
  per-round minima 8.3–11.1 ms in the base, 10.4–11.1 in the new build), so the medians are the
  measure. Renderer setup took 123 ms in the base and 120 ms in the new build (medians of six).
  Textures are unchanged: 41.9 MB on the Standard map and 43.2 MB on the Large map. No atlas
  grows: the token takes a free cell of the unit atlas, which stays 2048×1024.

## 11. Cities
Settlements are put together at draw time from a kit of procedural pieces in the house style
(same outline, light and materials as the figures), so there is no per-city art.

- **Kit** (`SettlementSprites.swift`, the 2048×512 settlement atlas): a hall and a capital's
  keep, six houses (thatched cottage, tiled cottage, two-storey timber house, stone house,
  longhouse, round hut), granary, library (columned temple front), market stalls, well and
  haystacks, wall towers, a gatehouse, and the wall ring in four quarters plus a breached
  front quarter with rubble; and the trodden ground under a settlement, in two versions.
  256 cells for the big pieces, the wall quarters and the grounds, 128 for the rest: one
  texel density (about 233 texels per tile size) for the whole kit. Pieces are white-and-material art; banners, pennants and
  awnings are team paint with their own mask cells, so **owner colour appears only on
  banners and trims**, multiplied in like the figures' team paint.
- **Layout** (`MapRenderer+Cities.swift`): the hall (or the keep, bigger) stands at the back
  of the hex, houses around it, props by tier, and the plaza in front stays clear for the
  units' base. Size tiers by population: 1–2 a village (three houses and a well), 3–5 a
  town (five houses, granary, haystacks), 6+ a city (two-storey and stone houses, granary,
  market and library). Seeded by the city id: which houses, the mirror image of the plan and
  small offsets, so a city keeps its look as it grows and no two neighbours match.
- **Ground**: a patch of trodden earth (1.5, 1.7 and 1.85 tile sizes across by tier; 1.85,
  filling the ring, when walled), mottled darker and paler, with worn lanes: in from the
  south edge to a worn square in front of the hall, on to the hall, out to the houses on
  either side and away east. A village's lanes carry cart ruts; inside walls the square and
  the main lane are paved with flagstones. Flat and lit from above, it is drawn mirrored with
  the plan, so its lanes meet the houses, and tinted toward the terrain (warmer on desert
  and plains, cooler on tundra and snow). It lies at 85% opacity, under the decorations;
  zoomed out it fades to 30% of that under the token.
- **Walls** (`walls`): a ring of radius 0.74 tile sizes with four towers and a gatehouse;
  breached (`wallHP` 0) the front-left quarter shows a gap and rubble. A capital's keep is
  the tallest piece in view.
- **Damage**: below full hit points, smoke rises over the roofs, a column per third lost
  (dark at the roof, lightening as it billows east, embers at its foot; six-second rises).
- **Layering**: a settlement's ground lies under the decorations; its pieces are one figure
  group in the unit pass, sorted just behind the units on its tile, so they stand on its
  plaza over it, with their base bands and the selection ring drawn after it. The group
  keeps its stencil rank everywhere, so plants standing in front of the wall ring's front
  arc cover it as they cover legs (§5). A city centre (tile texture bit 7) hides all of its
  own tile's decorations, relief included (a hill's mounds in front of the hall would stand
  over the buildings; the ground's baked relief stays, so a hill city still sits on its
  rise), and the plants and rocks straddling an edge onto it. A neighbour's relief reaching
  onto it stays, so a mountain range beside a city keeps its skyline.
- **Zoom**: settlements grow up to 18% as the view zooms out (as the figures do), so they
  keep their presence next to the units. At strategic zoom the pieces fade with the figures
  and a token takes their place: a crenellated plate in the owner's colour with their
  emblem, a gilt rim and taller middle merlon for a capital; a garrison's medallion covers
  its foot.
- **Fog**: only cities the App passes in are drawn (`setCities`, built from the viewer's
  knowledge), never on unexplored tiles; on explored tiles out of sight they take the
  explored-fog look, without smoke.
- **Banner anchor**: `bannerAnchor(city:)` is the top of the tallest piece (or of the token,
  crossfading with the zoom switch), where the App hangs the city's name banner.
- **Tribal villages** (M1 §7.7, `MapRenderer+TribalVillages.swift`): the villagers' small
  settlements, put together from the same kit by the unit pass from the markers the App passes
  (`setTribalVillages`, the viewer's knowledge). Two round huts (the kit's round hut, one a
  little bigger) and a wood pile (the kit's `hay` piece, smaller) stand about a third of a
  tile round a hearth a little south of the hex centre, the pile in front so no hut hides the
  fire; the plan is turned, nudged and mirrored by the tile index, never the pieces (they are
  lit from the upper left). Under them lies a ragged patch of bare trodden earth 1.25 tile
  sizes across, drawn procedurally (`tribalVillageGround`): blotched darker and paler at two
  scales, worn paler round the hearth, scuffed, tinted toward the terrain as a city's ground
  is, at up to 90% opacity and patchier at its rim. The hearth is a ring of seven small stones
  round a bed of ash with glowing embers. While its tile is in sight a thin, pale, unbroken
  column of smoke rises from the fire (ten small puffs, each about a third as dense as a burning
  city's, with no embers in it).
  - **Never a small city**: it differs from a city of one or two (the village tier above) in
    everything: no hall or keep, no square houses or well, no lanes or square, no banners, no
    team paint or player colour, and no name banner; three pieces on ground 1.25 tile sizes
    across, where a city of one has five on 1.5; a cooking fire's pale smoke, never a burning
    city's dark columns.
  - **Zoom**: zoomed out, the huts and the smoke fade with the figures and a small ivory token
    takes their place (`UnitSprite.tribalVillage`, 0.74 of a unit's medallion frame where a
    city's plate is 1.3): a dark rim round an ivory disc with a cone-roofed hut and a wisp of
    smoke, never in a player's colour. The ground stays under it at 30%. The token takes a free
    cell of the unit atlas, which stays 2048×1024.
  - **Plants**: on its tile (tile texture bit 3 of a, `TileBits.tribalVillage`) the plants
    rooted there (even those leaning over an edge) and their cast shadows hide, so the huts stand
    in a clearing. The tile's relief and rocks stay (hills still read as hills), and so does
    whatever a neighbour reaches over with.
  - **Layering**: its ground lies with the cities' under the decorations; its pieces are one
    figure group, sorted by depth with the cities and units and keeping its stencil rank, so
    plants in front of it cover it; its smoke goes over everything with the cities'. Nothing of
    it is a tap target: a tap on it picks the ground.
  - **Fog**: never drawn on an unexplored tile. Remembered (or its tile out of sight), it takes
    the explored-fog look, without smoke or embers.
  - **Taken** (`tribalVillageTaken`): a ghost of the marker fades out over 0.6 s, eased, from the
    moment the unit that took it reaches the tile (at once for a city's claim, or when the viewer
    does not see the taker walk in), while the tile's plants fade back in through one uniform
    (`options.w`: the tile of the earliest running fade plus how far its plants are back; a
    second fade at the same moment gets its plants back at its end). `onEventShown` reports the
    take at the tile as the fade starts.

## 12. Territory, improvements and overlays
All of these follow the App's inputs (`setTerritory`, `setImprovements`, `setMovementRange`,
`setAttackTargets`, `setWorkedTiles`, `setTileScores` with its job marks, `setSelection`), built
from the viewer's knowledge, and nothing shows on an unexplored tile (§8). Territory, improvements, the
range and the score tiers live in spare bits of the tile texture (`TileBits`: owner in bits
3–6 of r, improvement in bits 5–6 of g, range bit 2, a tribal village's tile bit 3 (§11) and
score tier bits 4–6 of a), so the ground and decoration shaders read them with the tile they
already fetch.

- **Borders** (`MapRenderer+Territory.swift`, `overlayBorder`): along each hex edge between an
  owned tile and a tile of another owner or none, only where **both** tiles are explored, a
  band 2.4 pt wide between 0.7 pt dark keylines just inside the owner's side, in the owner's
  colour and ring pattern (§9). Edges chain into polylines, and the pattern repeats a power of
  two times per edge, so it runs on around corners. Two owners side by side each draw their
  own band. Screen-constant, capped to about a tenth of a tile when zoomed far out. Inside
  the territory, the ground takes a soft tint of the owner's colour (5%, 13% at strategic
  zoom), stronger near the border. Owners beyond the eight styles share them.
- **Farms** (`markFields`): a patchwork of plots in the ground shader, on a sheared, warped
  world-space lattice (plots about half a tile across, a whole number per world period). Each
  plot has its own crop, tone and furrow direction, leaning toward the biome's ground colour,
  with hedgerows between plots. A plot belongs to the farmland when its middle lies on a
  farm, so farmland ends along plot edges, never along a hex edge, and neighbouring farms
  merge into one field system.
- **Pastures** (`markPasture` and decorations): a paddock fence about 0.6 tile sizes out, with
  rails, posts every 0.09 tile sizes and a shadow to the lower right. The grass inside is
  lusher, with a worn trail along the fence, and a herd of three or four grazing animals
  stands in it, a little behind the tile's centre. Cattle graze on grassland, sheep on plains
  and goats on tundra; each animal is painted facing both ways and never mirrored.
- **Mines** (decorations): an adit's dark mouth in a timber frame, cut low into the lit face
  of the hill's frontmost mound, with one or two spoil heaps in front of it.
- **Improvement sprites** (mine entrances, spoil, animals) sit in free cells of the decor
  atlas, which stays 2048×1536. They are placed once, on every tile that could take that
  improvement, so building one never rebuilds the decorations. The decoration shader shows
  each sprite only while its tile has that improvement (`DecorFlags.needs`). Open-land
  scatter and landmarks hide on farms and mines and thin to under half on pastures
  (`DecorFlags.clears`); hills and river reeds stay.
- **Movement range**: a soft cream wash, a little stronger toward the range's edge, plus a
  cream outline between ink keylines around the range. The outline includes the selected
  unit's own tile.
- **Route** (`overlayTrail`): this turn's steps are cream chevrons; later turns' steps are
  cream dots with an ink edge, 6.4 to 7.2 pt across at every zoom and anywhere on screen (sized
  by the points where they lie, so the tilt's far side does not shrink them), translucent over
  land in sight and opaque, with a firmer edge and line, over remembered land, whose greyed
  ground would swallow them.
- **Threat**: on each attackable tile, crimson corner brackets joined by a thin line and a
  slowly pulsing warm wash. On a city, they are sized to clear its walls.
- **City selection**: a ring sized to clear the walls, drawn under the walls' front so they
  stand on it.
- **Worked tiles**: a thin gilt line inset in the hex, with a faint wash.
- **Settler scores**: seven tiers (1 + score·7/256), a wash on the ground (`markScore`): poor
  sites dim toward ink and good ones glow gilt, stepping softly at the tile's edge. Over
  remembered land the wash goes on over the explored fog and grows stronger (ink up to 0.4,
  gilt up to 0.47), so the tiers stay apart there, desert included. The best two tiers also
  get a gilt band between ink keylines over the decorations (`unitSiteHex`; tier 7's
  stronger), so the best sites read through forest and around sprites.
- **Builder jobs** (`JobMark`, through `setTileScores(_:jobs:)`): on each tile a selected
  Builder could work, an ink ring between cream keylines, 2.4 line widths inside the tile's
  edge (at most 0.24 of a tile size), over the decorations: solid where the Builder can start
  this phase, dashed (a dash round each corner and one mid-edge) where it needs more turns. On
  the Builder's own tile the ring nests inside the selection ring's band, clear of it up to
  standard zoom (at most 0.38 of a tile size in), so the band never hides which it is. On the
  ring's south corner (on the Builder's own tile, where it would be without the nesting)
  sits a round badge (13–26 pt) per improvement it could build there, at most two: a sheaf
  for a farm, a pick for a mine, a paw for a pasture. The badges are unit atlas cells
  (`UnitSprite.job`) drawn flat after the selection ring, so a Builder standing on its job
  hides only the ring's far side.
- Rings and brackets are flat quads in the unit pass's band layer: under the figures, over
  the decorations.

## 13. Unit markers and combat
- **Health**: below full health, a pill under the base (up close) or under the medallion
  (strategic). It has an ink edge, a dark well, a fill from green through amber to red and
  quarter ticks. Damage just taken shows as a cream segment that drains away. In a stack,
  only the lead unit shows its bar.
- **Fortified**: a small stone tower (three merlons, a gate, ink outline, cream halo) on the
  base's left. At strategic zoom it moves to the medallion's upper left.
- **Done for the turn**: the viewer's own units with no moves left, or fortified, sleeping,
  skipping or following orders, are drawn desaturated and darker. A unit dims only after its
  animations end. A unit the App marks ready (`setReadyUnits`: a Settler that may found a
  city where it stands, which needs no moves) never dims.
- **Event animation** (`MapRenderer+Animation.swift`): everything runs on one clock, with a
  list of steps per unit. Each event waits for the units and tiles it involves, so a turn's
  events play in order and unrelated units move at the same time.
  - Moves step 0.09 s per hex, eased.
  - A melee attacker lunges 0.36 tile widths over 0.36 s; the blow lands at 38% of the lunge.
  - Ranged attacks fly an arrow on an arc (0.26 s plus 0.05 s per hex). A city's bombard
    flies one too.
  - At impact, the defender flashes warm white, a burst spreads and its bar drops. The
    attacker's bar drops 0.06 s later if it took retaliation.
  - The fallen fade over 0.55 s while the victor waits. New units fade in.
  - A captured unit changes colour (and type) once its captor has arrived.
  - A foreign unit's move shows only the part the viewer can see, fading in and out where it
    enters and leaves that part.
- **Callbacks**: `onEventShown` fires at each event's moment, with a screen point over the
  unit or tile. `onAnimationsFinished` fires when everything has played. `animationSpeed`
  scales the clock, `skipAnimations()` jumps to the end, and with `animatesEvents` off,
  everything lands at once.

## Gallery
`RENDER_OUT=<dir> swift test --filter ArtGallery` (in `Packages/Engine`) renders:

- the standard views, `g01`…`g13`;
- the city views, with their borders:
  - `g14` at standard zoom;
  - `g14b`–`g14d` close up on a walled capital, a burning breached city and a village;
  - `g14e` at strategic zoom;
  - `g14f` top-down;
  - `g14g` in the fog;
- the skirmish views:
  - `g15` with borders, improvements, the movement range and threat;
  - `g15b` close up on the front;
  - `g15c` settler scores;
  - `g15d` a selected city with its worked tiles;
  - `g15e` and `g15f` combat frames (an arrow in flight; a blow landing);
- `g16`, strategic zoom over every border with the units' medallions, and `g16b`, the borders
  at standard zoom;
- `g17`, upright iPads (834×1210 pt) and iPhones (402×874 pt) at the widest zoom on the Duel,
  Small and Standard maps, in a mid game's fog and with the fog off (`-nofog`), both devices
  on their side on the Duel map (`-landscape`) and a 13-inch iPad (1032×1376 pt) both ways on
  the Duel map (`-ipad13…`), with each view's zoom in `portrait.txt`;
- `g18`, a route whose planned steps bend through the fog around a bay (on the iPad
  play-test's map, Duel seed 11, like its T42 Scout) on an upright iPad: at standard zoom,
  close up (`g18b`), at the widest zoom (`g18c`) and with the fog off (`g18d`); and a spent
  Scout's route of later turns' dots over land in sight and remembered land, at standard zoom
  (`g18e`) and zoomed in all the way (`g18f`);
- `g19`, the play-test's guidance on the same map (`GuidanceFixture`, with `guidance.txt`):
  the T8 Builder in Rome close up (`g19`), at standard zoom (`g19b`), unselected (`g19c`) and
  at the widest zoom (`g19d`); the T32 Builder by Rome close up (`g19e`) and at standard zoom
  (`g19f`), and on the hill it was sent to at T33 (`g19j`, a job it can start this phase, and
  `g19k` at standard zoom); the
  T39 settler overlay round Antium over remembered desert (`g19g`, `g19h` closer); and the T36
  Settler, spent, ready to found Neapolis (`g19i`);
- `g20`, the tribal villages on the same map (`TribalVillageFixture`) on an upright iPad: one on
  hills beside a Scout close up (`g20`), one remembered in the fog (`g20b`), one two tiles from
  the capital (`g20c`), and all of them at the widest zoom (`g20d`).

It also dumps the sprite atlases and writes `timing.txt`. Some views render alone with other
filters:

- `--filter CityGallery`: the city views;
- `--filter SkirmishGallery`: the skirmish views;
- `--filter PortraitGallery`: the portrait views;
- `--filter RouteGallery`: the routes into the fog;
- `--filter GuidanceGallery`: the guidance views;
- `--filter TribalVillageGallery`: the tribal village views, and `--filter TribalVillageLooks`
  more of them (`g20e`…`g20n`: every zoom, a take half faded and over, and many layouts on
  every kind of land);
- `--filter ArtLineup`: the six unit types side by side at every zoom (`g05b`).
