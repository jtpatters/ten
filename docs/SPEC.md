# Ten Thousand Years — Game Spec

**Title:** *Ten Thousand Years* (D19). No "Civilization" branding; all art and audio original.
**Status:** Draft v0.3 · 2026-11-06
**Genre:** Full-depth, turn-based, hex-grid 4X (explore, expand, exploit, exterminate)
**Platforms:** iPadOS (primary), iOS (supported). Mac via "Designed for iPad" as a free bonus.

---

## 0. Decisions Log

| # | Decision | Choice | Notes |
|---|----------|--------|-------|
| D1 | Scope | **Full-depth 4X** | 6+ hour campaigns; diplomacy, culture, beliefs, trade. Multi-year hobby build — see §16 for de-risking. |
| D2 | Tech stack | **Native Swift** — SwiftUI (UI) + custom Metal (map) | SpriteKit was dropped during M0 for a custom Metal renderer (D20, §13.3). |
| D3 | Multiplayer | **Single-player vs AI only** at launch | Architecture stays deterministic/command-based so async MP can be added later. |
| D4 | Monetization | **Undecided / hobby** | No IAP, ads, accounts, or analytics in v1. |
| D5 | City layout | **Quarters** (unstacked cities) | §5.2. Biggest UI/AI cost item; falls back to stacked cities if it doesn't work out (cut list §16). |
| D6 | Setting | **Historical civs** | Original abilities, art, and writing; respectful, researched portrayals (§4). |
| D7 | Art style | **Painterly 2.5D** | Tilted perspective camera with standing sprites; top-down is the same renderer at tilt 0 (§13.3). |
| D8 | Game length | **3–4 hrs at Standard** | Quick ≈ 150 turns, Standard ≈ 250, Epic ≈ 400 (§2.1). |
| D9 | Combat randomness | **±15% seeded spread** | Preview shows a damage range (§8.3). |
| D10 | Extra v1 systems | **City Loyalty + Golden/Dark Ages** | Climate/disasters deferred (§5.5, §7.8). |
| D11 | Art & audio sourcing | **Placeholders through M2**, decide after the fun check | Simple procedural/placeholder art; revisit at end of M2 (§13.3, §15). |
| D12 | Mac | **"Designed for iPad"** on Apple Silicon | No Catalyst target; keyboard/trackpad support covers it (§14.2). |
| D13 | Launch roster | **Balanced spread**: 8 civs, one per play style, 6 regions | §4. M2 uses Rome, Mongols, Mali, China. |
| D14 | Quarters | **10 quarters** (adds Arena + Spaceport); cap **1 + 1 per 3 pop**; Aqueduct & Spaceport exempt | §5.2. |
| D15 | Loyalty tuning | **Moderate** | Forward-settling and holding conquests are risky; well-kept core cities never flip (§5.5). |
| D16 | Era model | **Global world era** | All civs advance together; age checks happen at the same time for everyone (§7.8). |
| D17 | Quarter placement UX | **Suggestions + placement mode** | Same flow on iPad and iPhone (§5.2, §14.1). |
| D18 | Tutorial | **Guided normal game** | Gentle seeded map; guided first ~30 turns, then contextual tips (§14.3). |
| D19 | Title | ***Ten Thousand Years*** | No existing game found with this name (web check, 2026-11-06). Do a proper USPTO trademark search and App Store name check before the first public TestFlight. |
| D20 | Map renderer | **Custom Metal** (2026-11-06) | SpriteKit judged too limiting during M0: CPU-baked chunk textures, no terrain blending or shader effects, no perspective camera. Device benchmark (§16 M0) still validates the Metal budget. |

---

## 1. Vision & Pillars

> A deep, historically-flavored empire builder that feels *native* to touch — the kind of game you play for a week on the couch with an iPad, one turn at a time.

1. **Depth without friction.** Full 4X systems, but every action reachable in ≤2 taps. The UI tells you what needs attention; you never hunt for idle units.
2. **Meaningful turns.** Every turn offers at least one interesting decision. Late-game busywork is automated or eliminated (automation, queues, governors).
3. **A worthy opponent.** AI that plays the game competently on fair terms at normal difficulty; bonuses only at higher levels.
4. **Interruptible.** Background the app mid-turn, come back a week later, pick up exactly where you were. Autosave constantly.
5. **Readable map.** At any zoom you can tell terrain, ownership, threats, and yields at a glance.

### Non-goals (v1)
- Multiplayer of any kind (incl. pass-and-play)
- Modding UI / Workshop (data-driven rules make it possible later)
- Scenarios / historical campaigns
- Real-time elements

---

## 2. Core Loop

```
Turn start
  → Review notifications ("needs attention" queue)
  → Move/command units (explore, settle, fight, build improvements)
  → Manage cities (production, citizens, purchases)
  → Choose research / civic / policies when due
  → Diplomacy (respond to proposals, make deals)
End turn → AI players act → world events resolve → next turn
```

**Macro arc (per game):**
Explore & settle (Ancient–Classical) → Specialize & compete for wonders/land (Medieval–Renaissance) → Industrialize, ideologies, world wars (Industrial–Modern) → Race to victory (Atomic–Information).

### 2.1 Game Speeds

| Speed | Turns (approx.) | Target play time | Cost multiplier |
|-------|-----------------|------------------|-----------------|
| Quick | 150 | ~2 hrs | 0.67× |
| **Standard** | **250** | **3–4 hrs** | 1.0× |
| Epic | 400 | 6+ hrs | 1.5× |

The multiplier scales costs for research, civics, production, and growth. Play time assumes a Standard map at ~45 s per turn on average.

---

## 3. The World

### 3.1 Map
- **Hex grid**, pointy-top, axial coordinates. Horizontal wrap (cylinder) by default; no-wrap option.
- **Sizes:**

| Size | Dimensions | Civs | Minor factions | Device note |
|------|-----------|------|----------------|-------------|
| Duel | 44×26 | 2 | 4 | all |
| Small | 60×38 | 4 | 8 | all |
| Standard | 80×50 | 6 | 12 | all |
| Large | 104×64 | 8 | 16 | iPad / 6GB+ devices |

- **Map scripts (launch):** Continents, Pangaea, Archipelago, Fractal. All seeded and reproducible (seed shown in game settings).
- **Fog of war:** unexplored (black) / explored-not-visible (dimmed, last-known state) / visible.

### 3.2 Terrain & Features
- **Base terrain:** Grassland, Plains, Desert, Tundra, Snow, Coast, Ocean, Lake.
- **Elevation:** Flat, Hills, Mountains (impassable until late-game units).
- **Features:** Forest, Jungle, Marsh, Floodplain, Oasis, Reef, Ice.
- **Rivers** run along hex *edges* (fresh water, defensive bonus for crossing, movement cost).
- **Natural wonders:** ~12 unique tiles with large yields/effects.

### 3.3 Resources
- **Bonus** (food/production boost, e.g., Wheat, Deer, Fish)
- **Luxury** (provides Stability to cities; tradeable, e.g., Silk, Spices, Wine)
- **Strategic** (required for certain units/buildings, revealed by tech; e.g., Horses, Iron, Coal, Oil, Uranium). Stockpile model: improved sources yield N units/turn up to a cap.

---

## 4. Civilizations & Leaders

- **Launch roster: 8 civs**, historical cultures with *original* leader abilities, art, and writing. Expansion target: 16+.
- Roster should span continents and eras. Leaders are real historical figures, portrayed respectfully and researched (consult cultural sources for less-represented civs; avoid caricature in art and voice).

### 4.1 Launch Roster (D13)

| Civ | Leader | Play style | Region | In M2 |
|-----|--------|-----------|--------|:-----:|
| Rome | Trajan | Expansionist (cheap settlers, free roads) | Europe | ✓ |
| Mongols | Genghis Khan | Warmonger (cavalry, fast conquest) | Central Asia | ✓ |
| Inca | Pachacuti | Builder (mountains, terrace farms) | South America | |
| Mali | Mansa Musa | Trader (gold, trade routes, desert) | West Africa | ✓ |
| Khmer | Jayavarman VII | Religious (faith, rivers, growth) | Southeast Asia | |
| Norse | Harald Hardrada | Naval / raider (coastal raids, early ocean travel) | Northern Europe | |
| Abbasid Caliphate | Harun al-Rashid | Scientific (Campus quarters, notable scientists) | Middle East | |
| China | Wu Zetian | Cultural (wonders, Theater quarters, Renown) | East Asia | ✓ |

Ability designs are written separately per civ (to do). The four M2 civs cover expansion, war, economy, and culture, so the core systems all get exercised before the full roster exists.
- Each civ has: 1 unique ability, 1 unique unit, 1 unique building or improvement, a leader with an **agenda** (drives AI diplomacy personality, see §10).
- City name lists per civ; player can rename.

---

## 5. Cities

### 5.1 Founding & Growth
- Founded by **Settler** units; min. 3 tiles between city centers.
- Cities claim tiles in a radius up to 3, expanding via accumulated Culture or by purchase with Gold.
- **Population** grows from surplus Food; each pop works one tile or fills a specialist slot.
- **Housing** soft-caps growth (from fresh water, coast, buildings, improvements).
- **Stability** (per city): from luxuries, entertainment buildings, policies; reduced by war weariness, overcrowding, and number of cities. Low Stability → yield penalties → unrest → rebellion.

### 5.2 Quarters (unstacked cities)
- Specialized building zones placed on tiles inside city borders within 3 hexes of the city center. Buildings are constructed *inside* their quarter. Wonders occupy their own tile.
- **Cap (D14):** 1 quarter + 1 per 3 population (pop 1 → 1, pop 3 → 2, pop 6 → 3, …). **Aqueduct and Spaceport don't count** toward the cap.
- **Adjacency bonuses** reward map-aware placement. Values below are starting points for balancing and live in rules data.

| Quarter | Focus | Adjacency / placement | Buildings (by era) |
|---------|-------|-----------------------|--------------------|
| **Campus** | Science | +1 per mountain, +½ per jungle, +½ per other quarter | Library → University → Research Lab |
| **Holy Site** | Faith | +2 natural wonder, +1 mountain, +½ forest | Shrine → Temple → worship building |
| **Market** | Gold | +2 river, +2 Harbor, +½ per other quarter | Market → Bank → Exchange |
| **Workshop** | Production | +½ per mine/quarry, +2 Aqueduct | Workshop → Factory → Power Plant |
| **Harbor** | Gold, naval units | Must be on coast/lake; +1 per sea resource, +2 city center | Lighthouse → Shipyard → Seaport |
| **Barracks** | Military production, unit XP | Can't be adjacent to city center; has its own defense and ranged attack | Barracks/Stable → Armory → Military Academy |
| **Theater** | Culture, Renown | +1 per wonder, +½ per other quarter | Amphitheater → Museum → Broadcast Tower |
| **Arena** | Stability | No adjacency; gives Stability to all own cities within 6 hexes | Arena → Menagerie → Stadium |
| **Aqueduct** *(exempt)* | Housing, fresh water | Must be adjacent to city center and to river/lake/mountain | none |
| **Spaceport** *(exempt)* | Science-victory projects | Flat land, Information era | none |

- **Placement flow (D17):** choosing a quarter (or wonder) enters **placement mode**. The camera zooms to the city, every valid tile shows its adjacency total, and the **top 3 tiles are highlighted** as suggestions. Tapping a tile opens a confirm sheet with the full breakdown (e.g., "Campus +3 Science: Mountain ×2, Quarter ×1"). It's the same flow on iPad and iPhone. On iPhone the confirm sheet is a bottom sheet, so the tile stays visible.
- Placement mode also previews **how the new quarter changes adjacency for existing quarters**, so placement interactions are never hidden.
- The AI uses the same adjacency scorer as the suggestions (§12.1).

### 5.3 Production
- Production queue (up to 6 items, reorderable by drag).
- **Purchase** with Gold (and Faith for religious items).
- **Overflow** carries over.
- **Governor (optional):** per-city focus (Growth / Production / Gold / Science / Culture / Balanced) auto-manages citizen tiles; player can lock tiles.

### 5.4 Capture & Razing
- Captured cities can be kept, razed (non-capitals), or liberated to a previous owner (diplomatic bonus).

### 5.5 Loyalty
- Each city has **Loyalty 0–100**. Every turn it moves by the net **loyalty pressure**:
  - **+** own nearby cities (population-weighted, falling off over ~9 hexes), capital proximity, garrisoned units, Stability surplus, certain policies/buildings, Golden Age.
  - **−** foreign nearby cities (same formula), Stability deficit, Dark Age, being recently conquered, occupied by enemy units.
- At **0** the city becomes a **Free City** (no owner). A free city then flips to whichever civ exerts the most pressure on it for several turns, or can be conquered.
- **Tuning target: Moderate (D15).**
  - A healthy core city (near the capital, Stability ≥ 0, surrounded by own cities) should **never** reach 0, even under a culture-heavy neighbor.
  - A city forward-settled within ~5 hexes of a larger rival's core **will** decline unless supported (garrison, policies, Arena, Golden Age).
  - A freshly conquered city starts at 50 Loyalty and needs active support for ~10 turns.
  - Loyalty never drops more than 10/turn, so the player always gets at least ~3 turns of warning in the attention queue before a flip.
  - HeadlessSim tracks flips per game. Target: 0–3 flips per Standard game in AI-only autoplay.
- UI: a loyalty lens overlay shows pressure sources, and the city banner shows the trend arrow and turns until flip. Cities projected to flip go in the attention queue.
- **Relationship to Stability:** Stability is the *internal* health of the city (yields and unrest). Loyalty is *who it belongs to*. Low Stability feeds into Loyalty loss but is not the same thing.

---

## 6. Economy & Yields

| Yield | Used for |
|-------|---------|
| **Food** | City growth |
| **Production** | Units, buildings, wonders, projects |
| **Gold** | Purchasing, unit/building upkeep, diplomacy |
| **Science** | Technology tree |
| **Culture** | Civic tree, border growth |
| **Faith** | Beliefs, religious units, select purchases |
| **Influence** | Envoys to minor factions, diplomatic actions |

- **Tile improvements** built by **Builder** units (limited charges): Farm, Mine, Quarry, Plantation, Camp, Pasture, Fishing Boats, Lumber Mill, Roads/Railroads.
- **Trade routes:** Trader units establish routes between cities (domestic: food/production; international: gold/science, also spread culture/religion). Routes create roads automatically.

---

## 7. Progression

### 7.1 Eras
Ancient → Classical → Medieval → Renaissance → Industrial → Modern → Atomic → Information (8 eras).

### 7.2 Technology Tree (Science)
- ~75 techs. Prerequisite DAG, rendered as a horizontally scrolling, pinch-zoomable tree.
- **Insights:** each tech has an in-game trigger (e.g., "build a Quarry" → 40% toward Masonry) that rewards play style and makes the tree feel alive.

### 7.3 Civic Tree (Culture)
- ~50 civics. Unlocks governments, policy cards, some buildings/wonders, diplomatic options.
- Civics also have Insights.

### 7.4 Governments & Policies
- **Governments (8):** e.g., Chiefdom → Autocracy / Oligarchy / Classical Republic → Monarchy / Theocracy / Merchant Republic → Democracy / Communism / Fascism-equivalent (use original, neutral names for modern ideologies).
- Each government has **slots** (Military / Economic / Diplomatic / Wildcard). ~60 **policy cards** swapped freely when a civic completes, or for Gold otherwise.

### 7.5 Beliefs (Religion)
- Earn Faith → found a **Pantheon** (1 small bonus) → recruit a Prophet → found a **Religion** with founder/follower/worship beliefs.
- Religion spreads passively from cities and via Missionary units; **theological combat** is v1.1 or later (keep v1 lean).

### 7.6 Notable Figures (Great People)
- Points accumulate from quarters/buildings: Scientist, Engineer, Merchant, Artist, General, Admiral, Prophet.
- Each figure is unique with a one-time or permanent effect. Competitive: first civ to reach the threshold recruits them.

### 7.7 Wonders
- ~25 world wonders. Unique, competitive, tile-placed with placement requirements. Losing a race refunds production as Gold.

### 7.8 Ages (Golden & Dark)
- Civs earn **Era Score** for **historic moments**: first to circumnavigate, wonder completed, first city on a new continent, notable figure recruited, battle won against the odds, etc. (~60 moment types, data-driven).
- **Global world era (D16):** the world advances to the next era when the *average* tech + civic progress of all surviving civs crosses the era threshold (or any civ reaches the era after next, which forces it). All civs move to the next era on the same turn, and every civ's age is resolved at once from the Era Score it earned during the previous era:
  - **Dark Age** (below threshold): Loyalty penalty, but unlocks powerful *Dark Age policies* (comeback mechanics).
  - **Normal Age**.
  - **Golden Age** (above threshold): Loyalty bonus, choose 1 of 3 *Dedications* (focused bonuses for the era).
  - **Heroic Age**: a Golden Age entered straight from a Dark Age, giving 2 Dedications.
- Civs that are behind technologically still change era with the world, but don't get techs for free. The era change boosts their **Insight** progress toward the previous era's techs (catch-up).
- The upcoming era change is always visible: a "world era" meter in the top bar shows global progress and your projected age.
- A **Timeline** screen records the civ's historic moments over the game. It doubles as an end-of-game recap.
- Thresholds rise with each Golden Age, so one civ can't chain them indefinitely.

---

## 8. Units & Combat

### 8.1 Stacking
- **One military unit per tile**, plus one civilian and one support unit (e.g., siege tower, medic). Formations (corps/army) combine 2–3 units in later eras to reduce clutter.

### 8.2 Unit classes
Melee, Ranged, Anti-cavalry, Light cavalry, Heavy cavalry, Siege, Naval melee, Naval ranged, Naval raider, Air (fighter/bomber), Civilian (Settler, Builder, Trader, Missionary), Support. ~60 units total, with upgrade paths.

### 8.3 Combat model
- Units have **HP 100**, **Strength** (melee), **Ranged Strength**, **Range**, **Movement**.
- Damage dealt is **exponential in the strength difference**, with a seeded random spread of **±15%** (D9). Exact formula lives in rules data and is tuned during balancing. The RNG stream is derived from (game seed, turn, attacker ID, defender ID), so reloading a save doesn't change the outcome (no save-scumming a result).
- Modifiers: terrain (hills/forest +), river crossing −, flanking/support +, fortification +, health penalty, promotions.
- **Zone of control:** entering a hex adjacent to an enemy military unit ends movement.
- **Combat preview** before every attack: expected damage range both ways and outcome odds (e.g., "Deal 28–38 · Take 12–17 · 85% you win"). No hidden modifiers.
- **Promotions:** XP from combat → choose 1 of 2 promotions per tier (class-specific trees).
- **Cities** have their own strength + walls (separate wall HP), can bombard once per turn.

### 8.4 War systems
- **War weariness** lowers Stability. **Casus belli** types (surprise war, formal war, reconquest, liberation) set the diplomatic penalties.
- **Raiders (barbarians):** spawn from camps in fogged areas, scale with era. Clearing camps gives Gold/XP.

---

## 9. Minor Factions (City-States)

- Single-city factions with types: Scientific, Cultural, Trade, Militaristic, Religious, Industrial.
- Players send **Envoys** (from Influence) for tiered bonuses; the player with the most envoys becomes **Patron** (gets their resources, can levy their military).
- Can be conquered (high diplomatic penalty).

---

## 10. Diplomacy

- **Leader personalities:** every AI leader has 1 fixed agenda (civ-specific) + 1 hidden randomized agenda (revealed via espionage / extended contact).
- **Relationship score** with visible, itemized modifiers ("+6 Shared enemy", "−10 You settled near us"). Transparency is a pillar.
- **States:** Unmet → Neutral → Friendly → Declared Friend → Alliance (levels 1–3: shared vision, trade bonuses, defensive pact). Negative: Unfriendly → Denounced → War.
- **Deals:** trade any of Gold (lump/per turn), resources, open borders, research agreements, cities, alliances. AI evaluates deals with a value function and **explains rejections** ("They want 30 more Gold").
- **World Congress** (Industrial era+): periodic votes on resolutions; Diplomatic Favor as currency; feeds the Diplomatic victory.
- **Espionage** (Renaissance+): Spies — steal tech insights, sabotage, siphon gold, defend cities. *Candidate to cut to v1.1 if schedule slips.*

---

## 11. Victory Conditions

| Victory | Condition |
|---------|-----------|
| **Domination** | Own every other civ's original capital. |
| **Science** | Complete 4 space projects in a Spaceport quarter (satellite → lunar → orbital colony → interstellar launch). |
| **Culture** | Your tourism-equivalent ("Renown") exceeds every other civ's domestic culture output. |
| **Diplomatic** | Earn 20 Diplomatic Victory Points via World Congress. |
| **Score** | Highest score at the turn limit. |

Each condition can be toggled in game setup. A **Victory Progress** screen shows every civ's standing in each track.

---

## 12. AI

The AI determines whether a single-player 4X is any good. It gets its own budget.

### 12.1 Architecture: layered utility AI
1. **Grand strategy** (every ~10 turns): picks a victory focus based on personality, civ ability, map, and current standing. Sets weights for all lower layers.
2. **Economic layer** (per turn): settle site scoring (now including predicted Loyalty pressure), quarter placement (adjacency scoring), city build orders (utility scoring over candidates), research/civic choice, policy selection, Golden Age dedication choice, tile management via the governor logic.
3. **Military operations** (per turn): threat assessment from **influence maps** (danger, territory, frontline); forms operations (defend city X, attack city Y, escort settler, clear raiders) and assigns units.
4. **Tactical layer** (per unit): executes operations — pathfinding (A* with movement costs + danger), target selection via the combat preview simulator, retreat when damaged.
5. **Diplomacy layer:** relationship model + agenda reactions; deal evaluation via shared value function; war declaration only when the operations layer thinks it can win.

### 12.2 Difficulty
6 levels. **Levels 1–3: no AI bonuses** (lower levels make deliberately suboptimal choices). Levels 4–6: yield/start bonuses, with the decision quality unchanged.

### 12.3 Performance budget
- AI turn processing for **7 AIs on a Standard map in the late game: ≤ 4 s on an A14-class device**, ≤ 2 s on M-series iPad.
- AI runs off the main thread; the player can pan the map and inspect during AI turns. A progress indicator shows which civ is acting.

### 12.4 Tooling (required, not optional)
- **Autoplay / observer mode:** all-AI games at max speed, headless (CLI target on macOS) for balance testing and regression.
- **AI debug overlay:** influence maps, operation assignments, utility scores per decision.

---

## 13. Technical Architecture

### 13.1 Module layout (Swift Package + Xcode app)
```
project.yml            XcodeGen config → TenThousandYears.xcodeproj (generated, not committed)
App/                   SwiftUI app shell, HUD, gesture handling, GameSession
Packages/Engine/       One local Swift package, one target per module:
├── GameCore           Pure Swift. Rules, state, commands, pathfinding. NO UIKit/Metal imports.
├── MapGen             Seeded procedural map scripts.
├── MapRendering       Metal renderer (camera, ground shader, sprite atlas, overlays).
├── HeadlessSim        macOS CLI: autoplay games, determinism + perf checks.
├── (GameAI)           M1+: utility AI, influence maps.
├── (Rules)            M1+: JSON content definitions + validators.
└── (Persistence)      M1+: save/load, autosave, iCloud.
```

### 13.2 Simulation principles
- **Deterministic:** given (rules, seed, command log) → identical game state. Custom seeded RNG (e.g., PCG32 / SplitMix64); never `SystemRandomNumberGenerator` or `Float` ordering-sensitive math in sim-critical paths (use integer/fixed-point for yields and combat).
- **Command pattern:** every player and AI action is a `Command` (e.g., `MoveUnit`, `SetProduction`, `ProposeDeal`) validated and applied by `GameCore`. This enables:
  - Undo of movement within a turn (before new info is revealed)
  - Replays, bug repro from a save + command log
  - Future async multiplayer (send commands, not state)
- **State as value types** (`struct GameState`), with structural sharing where needed for performance. Swift 6 strict concurrency; AI computes on a snapshot inside an actor.
- **Data-driven rules:** techs, units, buildings, policies, civs, and balance constants live in versioned JSON in `Rules/`, validated at load (dangling references, cycles in tech DAG). Hard-coded logic only for *mechanics*, not *content*.
- **Event bus** out of `GameCore` (`UnitMoved`, `CityGrew`, `CombatResolved`…) drives animation, audio, and notifications. Renderer never mutates state.

### 13.3 Rendering
- **Custom Metal renderer** (D20), benchmarked on an A14 device with a Large (104×64 ≈ 6.6k tiles) map, full fog, units, borders, and yield overlay:
  - Target **60 fps** pan/zoom (120 fps on ProMotion when idle-animating isn't needed — throttle otherwise to save battery).
  - **Camera:** perspective, looking north, tilt adjustable (0 = top-down). Taps unproject to the ground plane; unit tokens are hit-tested first.
  - **Ground pass:** one quad; the fragment shader finds each pixel's hex from a per-tile data texture (terrain, elevation, feature, rivers, fog) and blends the tile with its six neighbors. Per-tile noisy weights give organic coastlines and soft fog fronts, with no seams at hex corners. A fog update uploads ~26 KB; nothing is re-baked.
  - **Sprites:** trees, hills, mountains and units are camera-facing sprites from one atlas, sorted back to front, instanced three times for east–west wrap.
  - **Overlays:** selection, path and borders as ground-plane geometry.
  - Shaders compile at runtime from source, so `swift test` renders real frames offscreen and catches shader errors.
- Art direction: **painterly 2.5D top-down**, hand-painted terrain tiles with edge blending, clear silhouettes for units. All assets original.
- **Asset plan (D11):** placeholder/procedural art through M2 (flat-shaded hexes, simple glyph units). Placeholders must already meet the readability bar (terrain, ownership, and threats distinguishable at every zoom) so the fun check is judged fairly. Sourcing decision (commission / self-made / licensed) happens at the end of M2.
- Asset pipeline from M0: atlases built from a source folder by a build script, so swapping placeholders for final art means changing files, not code.
- Overlays: yields, resources, borders, movement range, attack range, settle-site scores, quarter adjacency previews.

### 13.4 Persistence
- **Autosave** at every turn start (rolling 10) + on `scenePhase == .background`.
- Save format: versioned, compressed `Codable` binary (state snapshot + command log since snapshot). Save migration path required from first TestFlight.
- **iCloud Drive** document sync for saves (a game on iPad can be continued on iPhone). Conflict resolution: keep both, label by device + turn.

### 13.5 Targets
- **Minimum:** iOS / iPadOS 18, A14-class devices (iPhone 12, iPad 10th gen, iPad Air 4).
- **Memory:** < 1.2 GB on Standard map; Large map gated to 6 GB+ RAM devices.
- **Save size:** < 5 MB late-game Standard.
- **Fully offline.** No account, no network required.

---

## 14. UX & Controls

### 14.1 Touch
| Gesture | Action |
|---------|--------|
| Tap unit / city | Select |
| Tap destination (unit selected) | Show path preview + turn count; tap again to confirm |
| Drag from unit | Live path preview; release to move |
| Pinch | Zoom (3 levels of detail: strategic / standard / close) |
| Two-finger drag | Pan (one-finger drag pans when nothing selected) |
| Long-press tile | Tile info sheet (yields, owner, combat modifiers) |
| Swipe up on bottom bar | Expand city/unit detail |

- **"Next" button** (primary action, bottom-right): cycles through everything needing attention, then becomes **End Turn**.
- **Attention queue:** idle units, finished production, research/civic choices, diplomacy offers, threats. Each item is one tap to resolve.
- **Action bar** for selected unit: context-sorted actions (most likely first), with long-press for descriptions.
- Confirmation only for irreversible or costly actions (declare war, raze, disband, spend > X gold).

### 14.2 Layouts
- **iPad:** map full-bleed; city screen and tech tree as large sheets/side panels; supports Split View and Stage Manager (resizable window — layouts must adapt down to compact width).
- **iPhone:** compact layout, bottom sheets with detents, portrait *and* landscape. Every feature must be playable on iPhone; nothing iPad-exclusive.
- **Hardware keyboard & trackpad (iPad):** hover tooltips, right-click context menus, scroll-to-zoom, shortcuts (Space = Next, Return = End Turn, F = Fortify, S = Sleep, etc.). Shown via the iPadOS menu bar / ⌘-hold overlay.
- **Apple Pencil:** hover shows tile tooltip (Pencil hover on supported iPads).

### 14.3 Information design
- **Civilopedia-equivalent ("Archive"):** in-game encyclopedia, deep-linked from every tooltip.
- Every number is explainable: tap a yield to see its breakdown.
- **Tutorial (D18): guided normal game.**
  - "Learn to Play" starts a real game: Duel map, curated seed (gentle start: river, varied resources, one nearby minor faction, a raider camp at turn ~15), Rome, lowest difficulty, 1 AI opponent.
  - **Turns 1–30:** scripted guide steps that unlock as you go: move → settle → produce → research → improve tiles → second city → combat → civics/policies → first quarter (introduces placement mode).
  - **After turn 30:** contextual tips the first time each system appears (Loyalty, ages, beliefs, diplomacy, World Congress…). Tips can be dismissed and turned back on.
  - The player can leave the guide at any point and keep playing the same game. Tutorial games produce normal saves.
  - Guide steps are data-driven triggers ("on first CityFounded → show step 4"), driven off the GameCore event bus. No special game mode in the sim.

### 14.4 Accessibility
- Dynamic Type for all UI text; VoiceOver for all menus and screens (map: VoiceOver rotor for units/cities/notifications).
- Colorblind-safe player colors + pattern/emblem borders, not color alone.
- Reduce Motion honors system setting (skip combat animations, instant camera moves).
- Animation speed setting; "quick combat" and "quick movement" toggles.

---

## 15. Audio
- Era-evolving soundtrack (each civ has a theme that gains instrumentation by era) — original compositions.
- Ambient map audio by zoom level/terrain; UI sounds; leader voice lines are a stretch goal.
- Placeholder/free-licensed audio through M2, same as art (D11).
- Haptics: subtle feedback on selection, combat hits, turn end (respect system settings).

---

## 16. Milestones & De-risking

Full-depth 4X as a hobby is a multi-year effort. Each milestone ships something **playable**, and the riskiest work (rendering at scale, AI, determinism) is front-loaded.

| Milestone | Goal | Exit criteria |
|-----------|------|---------------|
| **M0 — Tech spike** (4–6 wks) | Prove renderer + core architecture | Large map at 60 fps on A14; pan/zoom/select feels great; GameCore deterministic test (same seed + commands → same hash). Renderer decision made. |
| **M1 — Vertical slice** (3–4 mo) | Ancient era, 1 player vs 1 AI | Map gen, settle, grow, produce, 10 techs, 6 units, combat w/ preview, fog, basic AI that expands and attacks, save/load, autosave. **Fun check: is the first 50 turns enjoyable?** |
| **M2 — Core 4X** (6–9 mo) | Ancient → Medieval, 4 civs (Rome, Mongols, Mali, China) | Civics, governments/policies, Stability, Housing, quarters, Loyalty, trade, minor factions, raiders, diplomacy basics, AI layers 1–4, HeadlessSim tool. **Art/audio sourcing decision.** |
| **M3 — Full game** (9–12 mo) | All 8 eras, all victories | Full trees, beliefs, notable figures, wonders, Golden/Dark Ages + Timeline, World Congress, AI diplomacy, all 8 civs, iCloud saves, final art/audio production. |
| **M4 — Polish & beta** (3–6 mo) | Ship quality | Tutorial, Archive, accessibility pass, balance via autoplay, performance budgets met, art/audio complete, TestFlight. |
| **v1.1+** | Post-launch | Espionage (if cut), theological combat, climate & disasters, more civs, scenarios, async multiplayer (Game Center turn-based), modding. |

**Cut list if scope must shrink** (in order): espionage → Golden/Dark Ages → World Congress (drop Diplomatic victory) → beliefs → Loyalty → quarters (revert to stacked cities) → Large map size.

---

## 17. Testing Strategy
- **GameCore unit tests:** rules, combat math, yield calculation, tech DAG validation (Swift Testing).
- **Determinism tests:** run seeded games N turns, assert state hash; run in CI on every commit.
- **Golden-save regression:** load fixture saves, apply command logs, compare outcomes.
- **AI regression:** HeadlessSim plays 100 seeded games nightly; track win-rate by civ, average victory turn, crashes, turn-time percentiles.
- **Performance tests:** XCTest metrics for map render frame time and AI turn time on device.
- **Save migration tests:** every released save version must load.

---

## 18. Open Questions

*Round 1 (D5–D12) and Round 2 (D13–D18) resolved 2026-11-06. Remaining design work is detail rather than direction:*

1. **Civ ability designs:** unique ability, unit, and building/improvement for each of the 8 civs (start with the 4 M2 civs).
2. **Leader agendas:** fixed agenda per leader + the pool of hidden agendas (§10).
3. **Tech & civic trees:** full node lists, costs, and Insight triggers per era.
4. **Government & policy card list** (§7.4), including names for the modern ideologies.
5. **Historic moment list** and Era Score thresholds (§7.8).
6. **Balance constants:** combat formula, yield values, growth curve, Loyalty pressure formula. Draft as rules JSON during M1–M2, then tune with HeadlessSim.
