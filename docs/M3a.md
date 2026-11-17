# M3a — Renaissance, Industrial and Modern eras: Design and Plan

**Status:** draft v0.1 · 2026-11-17 · first part of SPEC §16 M3 (content for eras 3–5). Builds on
M2.md, which stays the reference for every rule not restated here.
**Goal:** carry a game from the Medieval era through the **Modern** era (roughly 1450–1945):
gunpowder, sail and steam navies, railroads, factories and power, ideologies, corps and armies,
tanks and the first aircraft. 27 techs, 16 civics, 3 governments, 26 policies, 23 unit types,
13 buildings, 3 strategic resources, 2 improvements and railroads.
**Exit:** the **late-game check**: do turns 150–220 on a Standard map (1+5) still give a decision
worth making every turn, and do wars in the Industrial and Modern eras feel different from Medieval
ones (fronts, resources, air) without the unit count overwhelming the screen?

Same conventions as M1.md and M2.md: numbers are starting values in rules data and are tuned with
HeadlessSim (§17); where this document and SPEC.md disagree for M3a, this document wins.

---

## 0. Decisions

### 0.1 Decided (2026-11-17)

| # | Question | Decision | Why |
|---|---|---|---|
| M3a-D1 | Game length | **No turn limit.** The game ends by domination or last civ standing, or when the player stops; score is shown but never ends the game (§14). Repeatable Future Tech and Future Civic keep research and civics from running dry (§6.3). | The user's call. |
| M3a-D2 | Air units | **Based air** (§9.5): aircraft live in cities (and Hangars), not on map tiles; each phase they strike, patrol or rebase. | Keeps the one-military-unit-per-tile rule and the map readable; gives the Modern era a new layer without a second movement system. |
| M3a-D3 | Railroads need a finer move scale | **Internal move points ×6** (M2 used ×3): road = 2 points, railroad = 1. | A railroad must be cheaper than a road; integer costs need the finer scale. One-time change, every existing cost ×2. |
| M3a-D4 | Corps and armies (SPEC §8.1, M2-D7 deferred them) | **In M3a**: Corps with *Nationalism*, Armies with *Mobilization* (§8.4). | Modern unit counts would otherwise double; War Room groups help with orders but not with clutter. |
| M3a-D5 | Fuel | **Each Power Plant burns Coal or Oil, chosen by its owner** (§5.3). Coal costs the plant's city Stability; Oil competes with Tanks, Destroyers and Bombers. No silent fallback when the chosen fuel runs out. | Makes Coal and Oil an economic resource as well as a military one, and makes the fuel a decision with a cost either way. |
| M3a-D6 | Ideologies (SPEC §7.4: original, neutral names) | **Liberty** (representative), **Equality** (planned economy), **Order** (militarist), from the civics *Suffrage*, *Planned Economy*, *Militarism*. **Free choice** among the three (ordinary governments, M2 switching rules). **Diplomatic weight:** same ideology +5, different −5 (§7.2). | Named by what each values: neutral, no real party or regime names. The modifier makes an ideology more than a slot layout and lets Modern-era blocs form. |
| M3a-D7 | M2 saves | **Not loadable** (rules id `m3a.x`). | Niter, Coal and Oil are placed at map generation; adding them to an existing map has no faithful answer (as M2-D4). |
| M3a-D8 | Naval raiders (Privateer, Submarine) | **Hidden**: seen only by adjacent units and by Destroyers within their sight (§9.4). | The class needs a reason to exist; hiding is the cheapest one that reads clearly. |

### 0.2 Proposed (still open)
Each has a recommendation; the rest of this document assumes it.

| # | Question | Recommendation | Why |
|---|---|---|---|
| M3a-D9 | Espionage (SPEC: Renaissance+) | **Still out.** | SPEC's cut list puts it first; nothing here depends on it. |

### 0.3 Inherited
SPEC D1–D20 and M2's decisions stand, except M2-D1 (turn limit 150, replaced by M3a-D1: none) and M2-D7
(corps, replaced by M3a-D4). Strategic stockpiles (M2-D5), promotions (M2-D6) and the global world
era (M2-D10) carry on and are extended below.

---

## 1. Scope

**In M3a**
- **Eras:** Renaissance (3), Industrial (4), Modern (5) on the global world era (§2).
- **Research:** 27 techs, 9 per era, with Insights (§6).
- **Civics:** 16 civics; 3 governments (the ideologies); 26 policy cards (§7).
- **Units:** 23 new types, 3 new classes (`navalRaider`, `fighter`, `bomber`) and air rules,
  every M2 line extended, tier 3 promotions, corps and armies (§8, §9).
- **Cities:** 13 buildings (Star Fort, Museum, Exchange, Factory, Research Lab, Seaport, Military
  Academy, Menagerie, Sewer, Power Plant, Broadcast Tower, Stadium, Hangar), Power, regional
  buildings (§5).
- **Map:** Niter, Coal, Oil; Fort, Oil Well, Railroad (§3, §4).
- **World:** raiders and minor factions by era, coastal raider ships (§11).
- **AI:** resource planning, ideologies, corps, air, naval raiders, railroads (§15).
- **App and rendering:** era art for units, ships and aircraft; railroads; Power lens; air tray
  (§16).

**Not in M3a:** Atomic and Information eras (M3b: Aluminum, Uranium, jets, nuclear weapons,
Spaceport, Science victory); Faith and beliefs; wonders; notable figures; Golden/Dark Ages;
World Congress; espionage; abilities for the other four civs; aircraft carriers.

---

## 2. Eras and pacing

Era indices `renaissance = 3`, `industrial = 4`, `modern = 5`. The world-era rule (M2 §2) is
unchanged; `forceAheadCount` (3 techs of the era after next) becomes reachable and stays at 3.
On each advance, in addition to M2's effects:
- the strategic cap rises (§3.1);
- raider sets and minor defenders step up (§11);
- City Strength gains +1 per military tech of the new era known (M2 §5.6, now every era).

**Pacing targets** (Standard map, 1+5 AI, HeadlessSim, mean over 20 seeds). M2's targets for
Classical and Medieval stand.

| Milestone | Target turn |
|---|---|
| World era Renaissance | 115–125 |
| World era Industrial | 150–162 |
| World era Modern | 185–200 |
| First Tank or Biplane on the map | 195–210 |
| First civ knows every tech | 205–215 |
| Median civ knows every tech | ≥ 220 (not reached) |

Tech totals: Renaissance 3,200, Industrial 5,080, Modern 7,800 (M2: Medieval 2,620). Civic
totals: 1,630, 2,460, 4,520.

---

## 3. Map

### 3.1 Resources
Appended to `enum Resource` (raw values continue M2's). Placed by MapGen with the M2 rules and
stream; each counts in the strategic target per map size (Duel: +3 Niter, +3 Coal, +3 Oil; scale
by land tiles). Fairness pass: every start has a Niter within 8 and Coal or Oil within 10 (not
both guaranteed; trading and conquest are the point).

| Resource | Kind | Yield | On | Improvement | Revealed by |
|---|---|---|---|---|---|
| Niter | strategic | +1 Food, +1 Prod | flat Plains, Grassland, Desert, Tundra | Mine (also flat) | Gunpowder |
| Coal | strategic | +2 Prod | Hills, Forest, Plains, Grassland | Mine (Forest: Lumber Mill) | Industrialization |
| Oil | strategic | +2 Prod | Desert, Tundra, Marsh, Snow, flat Plains | Oil Well | Refining |

**Stockpile changes (M2-D5).**
- **Cap:** `20 + 10 × max(0, worldEra − 1)` (Medieval 30, Renaissance 40, Industrial 50, Modern 60).
- **Income per improved source:** Horses, Iron, Niter +2; Coal, Oil +3 (fuel is burnt, §5.3).
- **Unit cost:** `resourceCost` per unit type (rules data): 10 for Renaissance units, 15 for
  Industrial, 20 for Modern. Upkeep at war stays 1/turn per unit.
- **Out of resource:** M2's −5 Strength, plus: **air units cannot strike** without their fuel.

### 3.2 Embarking
With **Steam Power**, embarked units move 5 on water and defend at 20 (M2: 3 and 10).

### 3.3 Roads and railroads
`Tile.road` becomes a level: `none, road, railroad` (`UInt8`, saved in place of M2's flag).
- **Move points ×6 (M3a-D3):** units have `moves × 6` points; every M2 cost doubles; a step
  road→road costs 2, railroad→railroad 1, any other step at least as in M2.
- **Railroad:** a Builder on a road tile with **Railroad** known builds it: one charge, all moves,
  costs `railCoal` (2) Coal from the stockpile. Trade routes lay roads, never railroads.
- Pillaging a railroad leaves a road; the owner's Builder repairs it for one charge (no Coal).
- Rome's ability (M2 §15) still lays roads only.

### 3.4 Knowledge
Memory's road bit becomes the 2-bit level. Revealing Niter, Coal and Oil fills every explored
tile at once (M2 §3.4).

---

## 4. Tiles and improvements

| Improvement | Raw | Effect | Allowed on | Tech |
|---|---|---|---|---|
| Fort | 9 | a unit on it defends +6 and heals +10 more; counts as fortified at once | land, no resource, not adjacent to another own Fort, not on a quarter | Siege Tactics |
| Oil Well | 10 | +2 Prod; enables Oil | Oil | Refining |

- Railroad is a road level (§3.3), not an improvement.
- **Yield upgrades:** Lumber Mill +1 Prod (Mass Production); Farm +1 Food (Sanitation); Mine on
  Coal +1 Prod (Railroad) if the tile has a railroad.
- **Legion** (Rome) may build Forts with its charge (M2 §15 deferred this).
- Builders: *Mass Production* −25% cost; *Public Works* +2 charges (§7.3).

---

## 5. Cities

### 5.1 Buildings
Each building at most once per city; upkeep `2 + era` Gold (Renaissance 5, Industrial 6,
Modern 7; Hangar 4).

| Building | Where | Cost | Unlocked by | Effect |
|---|---|---|---|---|
| Star Fort | centre | 260 | Siege Tactics | needs Castle; +100 wall HP (300 total), +4 City Strength, +5 bombard |
| Museum | Theater | 290 | *Humanism* | +3 Culture; Theater specialists +1 Culture |
| Exchange | Market | 390 | Economics | +6 Gold; +1 trade route capacity |
| Factory | Workshop | 400 | Industrialization | +3 Prod here; **regional** +2 Prod in every own city within 6 (§5.2) |
| Research Lab | Campus | 450 | Chemistry | +5 Science; +2 more when **Powered** |
| Seaport | Harbor | 380 | Steam Power | +2 Housing; +1 Gold on Coast and Ocean tiles; ships adjacent heal +20 |
| Military Academy | Barracks | 370 | Military Science | +2 Prod; units +10 XP more; may train Corps and Armies directly (§8.4) |
| Menagerie | Arena | 300 | *Natural History* | +1 Stability in the Arena's reach more; +2 Culture |
| Sewer | centre | 260 | Sanitation | +3 Housing |
| Power Plant | Workshop | 520 | Electricity | +4 Prod here; **regional** Power to every own city within 6 (§5.3) |
| Broadcast Tower | Theater | 520 | Radio | +4 Culture (+2 when Powered); +2 Loyalty/turn in own cities within 6 |
| Stadium | Arena | 520 | *Professional Sports* | +2 Stability in the Arena's reach more; +2 Culture |
| Hangar | Barracks | 400 | Flight | +2 air slots (§9.5); aircraft based here heal +20 more |

Quarter costs keep M2's formula (`55 + 30 × world era`, Modern 205). Specialist slots: one per
building, as M2 (§5.3). The SPEC §5.2 building chains are complete through Modern except the
Spaceport (M3b).

### 5.2 Regional buildings
A regional effect reaches own cities whose centre is within 6 of the quarter. **Not cumulative**:
a city takes the best one of each kind (as the Arena in M2 §5.2). The placement preview (M2 §18.2)
shows the cities reached. Regional effects ignore cities captured ≤ 10 turns ago.

### 5.3 Power (M3a-D5)
- Each **Power Plant** has a **fuel**, Coal or Oil, set by its owner: `setFuel(city, .coal | .oil)`,
  free, any time; it takes effect at the next phase start. When the plant completes, the fuel is
  the one with the larger stockpile (Coal on a tie).
- At its owner's phase start a plant burns 1 of its fuel. If that stockpile is 0 it is
  **unfuelled**: no regional Power, and its own +4 Prod halves. It does **not** switch fuel by
  itself; the attention item offers the switch.
- **Coal** is dirty: a plant burning Coal gives its own city −1 Stability (shown as "Coal smoke"
  in the breakdown). **Oil** is clean but is the fuel for Tanks, Destroyers and Bombers, whose
  build cost and war upkeep come from the same stockpile.
- A city is **Powered** while a fuelled Power Plant reaches it (§5.2). Powered: Factory +2 Prod
  more, Research Lab +2 Science, Broadcast Tower +2 Culture, +1 Stability.
- Attention item when a Power Plant is unfuelled or will be within 3 turns at the current burn,
  with a one-tap switch to the other fuel when it has stock ("Out of Coal in 3 turns — burn Oil?
  14 turns of Oil").
- Power Lens: Power Plants, their reach, Powered cities and fuel turns left.

### 5.4 Housing and Stability
- Housing: Sewer +3, Seaport +2, *Tenements*, *Social Insurance*, *Urbanization* (§7).
- Stability: Menagerie, Stadium, Power, policies and governments (§7). The empire-size penalty is
  unchanged (bigger empires are expected to use the new sources).

### 5.5 City combat
M2 §5.6 plus: Star Fort; *Ballistics* gives every city +5 bombard; *Steel* gives +5 City Strength;
*Advanced Ballistics* gives cities **anti-air** (§9.5).

---

## 6. Research

### 6.1 Tech tree
M2 §6 mechanics stand. Array order = tree order. Insight 40% of cost (China 50%).

| Era | Tech | Cost | Requires | Unlocks | Insight |
|---|---|---|---|---|---|
| R | Gunpowder | 340 | Apprenticeship, Stirrups | Musketman; reveals Niter | own an Armory |
| R | Printing | 320 | Machinery, Education | Libraries +1 Science; Campus specialists +1 Science | own 3 Libraries |
| R | Mass Production | 330 | Machinery, Guilds | Lumber Mill +1 Prod; Builders −25% cost | build 3 Lumber Mills |
| R | Navigation | 360 | Cartography, Astronomy | Caravel, Privateer; naval units +1 sight; sea trade range +5 more | found a city on another landmass |
| R | Siege Tactics | 360 | Castles, Gunpowder | Pike and Shot; Star Fort; Fort | own 2 Castles |
| R | Metal Casting | 350 | Gunpowder, Military Engineering | Bombard | own 2 Trebuchets |
| R | Cavalry Reform | 350 | Stirrups, Gunpowder | Hussar | own 3 Knights |
| R | Square Rigging | 390 | Navigation, Gunpowder | Frigate; naval units +1 move on Ocean | kill a unit with a naval unit |
| R | Physics | 400 | Printing, Astronomy | University +2 Science | have a Campus with adjacency ≥ 4 |
| I | Industrialization | 520 | Mass Production, Printing | Factory; reveals Coal | own 3 Workshops |
| I | Economics | 520 | Banking, Printing | Exchange | own 2 Banks |
| I | Rifling | 540 | Gunpowder, Metal Casting | Line Infantry, Ranger | own 4 Musketmen |
| I | Ballistics | 560 | Metal Casting, Siege Tactics | Field Gun; cities +5 bombard | own 2 Bombards |
| I | Chemistry | 560 | Physics, Industrialization | Research Lab | own 2 Factories |
| I | Steam Power | 580 | Industrialization, Square Rigging | Ironclad; Seaport; embarking §3.2 | own 2 Shipyards |
| I | Military Science | 580 | Cavalry Reform, Rifling | Cavalry, Cuirassier; Military Academy | kill 3 units with cavalry or heavy cavalry |
| I | Railroad | 620 | Steam Power | Railroad (§3.3); Coal Mines +1 Prod on railroads | have 30 Coal |
| I | Sanitation | 600 | Chemistry, Economics | Sewer; Farm +1 Food | have a city of population 15 |
| M | Electricity | 800 | Chemistry, Steam Power | Power Plant; Submarine | own 3 Factories |
| M | Steel | 820 | Railroad, Ballistics | Artillery, Battleship; cities +5 Strength | build 4 Railroads |
| M | Refining | 820 | Chemistry, Railroad | reveals Oil; Oil Well | improve 2 Coal |
| M | Replaceable Parts | 840 | Economics, Military Science | Infantry; upgrades −25% Gold | own 6 Line Infantry |
| M | Combustion | 880 | Steel, Refining | Tank, Destroyer | build an Oil Well |
| M | Flight | 880 | Replaceable Parts, Steam Power | Biplane; Hangar; air rules (§9.5) | own a Military Academy |
| M | Radio | 900 | Flight, Electricity | Broadcast Tower | own 2 Museums |
| M | Advanced Ballistics | 900 | Replaceable Parts, Steel | Machine Gun, AT Gun; city anti-air | own 2 Artillery |
| M | Advanced Flight | 960 | Flight, Radio, Combustion | Bomber; air range +2 | kill a unit with an air unit |

### 6.2 New Insight kinds
`foundOverseasCity` (a city on a landmass with none of the player's other cities),
`stockpile(resource, n)`, `cityPopulation(n)`, `buildRoadLevel(railroad, n)`, `treasury(n)`,
`thrivingCities(n)`, `ownCorps(n)`. The rest reuse M2's kinds (M2 §6.2).

### 6.3 Future Tech and Future Civic (M3a-D1)
With no turn limit, a player can exhaust both trees. Once every tech is known, research goes into
**Future Tech**: repeatable, cost `futureTechBase` (1,000) + `futureTechStep` (100) × times
already learned; each completion gives +3 score and is an event like any tech. **Future Civic**
mirrors it for culture (900 + 90 per completion, +2 score). Neither has an Insight. They exist so
the attention item "nothing being researched" never fires with nothing to choose; when Atomic and
Information land (M3b) they move to the end of the longer trees.

---

## 7. Civics, governments and policies

### 7.1 Civic tree

| Era | Civic | Cost | Requires | Unlocks | Insight |
|---|---|---|---|---|---|
| R | Humanism | 300 | Civil Service | Museum; *Grand Tour* | own 3 Amphitheaters |
| R | Exploration | 310 | Diplomatic Service, Mercenaries | *Colonial Offices*, *Press Gangs* | own 3 naval units |
| R | Mercantilism | 330 | Guild Charters | *Chartered Companies*, *Resident Ambassadors* | have 4 trade routes |
| R | Standing Armies | 330 | Mercenaries | *Drill Manuals*, *Garrison Towns* | own 12 military units |
| R | The Enlightenment | 360 | Humanism | *Academies* | own 3 Universities |
| I | Nationalism | 480 | Standing Armies, The Enlightenment | Corps (§8.4); *Mass Levy*, *General Staff* | own 15 military units |
| I | Free Markets | 480 | Mercantilism | *Public Credit*, *Trade Missions* | have 500 Gold |
| I | Natural History | 460 | Humanism | Menagerie; *Public Parks* | own a Museum |
| I | Civil Engineering | 500 | Exploration, Free Markets | *Public Works*, *Heavy Industry* | own 10 quarters |
| I | Urbanization | 540 | Civil Engineering, Natural History | *Tenements*; +1 Housing in every city | have 3 cities of population 10 |
| M | Ideology | 720 | Nationalism, Urbanization | *Propaganda*, *Diplomatic League* | own 2 Factories |
| M | Suffrage | 760 | Ideology | Liberty; *Social Insurance*, *Open Markets* | have 5 Thriving cities |
| M | Planned Economy | 760 | Ideology | Equality; *Production Quotas*, *Collective Farms* | own 4 Workshop quarters |
| M | Militarism | 760 | Ideology | Order; *Lightning Warfare*, *Martial Law* | kill 5 units |
| M | Mobilization | 780 | Nationalism, Ideology | Armies (§8.4); *National Service* | own 3 Corps |
| M | Professional Sports | 740 | Natural History, Ideology | Stadium; *Sports Leagues* | own 3 Menageries |

### 7.2 Governments (M3a-D6)
M2 §7.2 rules stand. Any of the three may be adopted once its civic is known.

| Government | Unlocked by | Slots (Mil / Econ / Dip / Wild) | Inherent bonus |
|---|---|---|---|
| Liberty | Suffrage | 1 / 3 / 2 / 2 | Gold buys −20%; +1 Stability in cities with ≥ 2 quarters; war weariness ×150%; +4 Influence |
| Equality | Planned Economy | 2 / 3 / 1 / 1 | +15% Production in every city; building upkeep −1 (min 0); Gold buys +20%; +4 Influence |
| Order | Militarism | 4 / 1 / 1 / 2 | units cost −20% Production; +5 Strength attacking; war weariness ×50%; +4 Influence |

**Ideology** is the government's family when it is Liberty, Equality or Order; any other
government has none. **Relationship modifier** (M2 §14.1, rules data):

| Modifier | Amount | Decay |
|---|---|---|
| Same ideology (both have one, the same) | +5 | while true |
| Different ideology (both have one, different) | −5 | while true |

It applies to AI opinions of the human and of each other, and the human sees it in the itemized
list like any other. A civ without an ideology gets neither. Changing government updates it at the
next phase start.

### 7.3 Policies
`replacedBy` (M2 §7.3) unslots the policy named in the last column when the new one is unlocked.

| Policy | Kind | Unlocked by | Effect | Replaces |
|---|---|---|---|---|
| Drill Manuals | Mil | Standing Armies | melee, antiCavalry, ranged cost −25% (Renaissance and Industrial units) | Agoge |
| Garrison Towns | Mil | Standing Armies | a city with a garrison +1 Stability, +2 Loyalty/turn | Retainers |
| Press Gangs | Mil | Exploration | naval units cost −25% | |
| Mass Levy | Mil | Nationalism | forming a Corps or Army costs −50% (§8.4); unit upkeep −1 Gold per Corps/Army | |
| General Staff | Mil | Nationalism | all units gain +25% XP | |
| Lightning Warfare | Mil | Militarism | cavalry and heavy cavalry +1 move; +3 Strength attacking from a railroad | Chivalry |
| Martial Law | Mil | Militarism | a city with a garrison +2 Stability; −1 Loyalty/turn in cities without one | |
| National Service | Mil | Mobilization | unit upkeep −2 Gold per unit (min 0) | Conscription |
| Grand Tour | Econ | Humanism | Museums +2 Culture; Theater quarters +1 Gold | |
| Colonial Offices | Econ | Exploration | cities ≥ 10 from the capital +15% Food and +3 Loyalty/turn | |
| Chartered Companies | Econ | Mercantilism | international trade routes +3 Gold; +1 trade route capacity | Caravansaries |
| Academies | Econ | The Enlightenment | Universities +2 Science; Campus adjacency ×2 | Natural Philosophy |
| Public Credit | Econ | Free Markets | Gold buys −15%; Exchanges +2 Gold | |
| Public Works | Econ | Civil Engineering | quarters cost −20%; new Builders +2 charges | Serfdom |
| Heavy Industry | Econ | Civil Engineering | Factories +2 Prod; Workshop adjacency ×2 | |
| Tenements | Econ | Urbanization | +2 Housing in cities with a Workshop quarter | Insulae |
| Social Insurance | Econ | Suffrage | +2 Housing and +1 Stability in cities with ≥ 3 quarters; −2 Gold per city | |
| Open Markets | Econ | Suffrage | international trade routes +2 Gold, +1 Science; Market adjacency ×2 | Town Charters |
| Production Quotas | Econ | Planned Economy | Workshop and Campus adjacency ×2; −1 Gold per city | |
| Collective Farms | Econ | Planned Economy | Farms +1 Food; Builders cost −25% | |
| Sports Leagues | Econ | Professional Sports | Stadiums +2 Stability in reach more; Arena quarters +2 Gold | |
| Public Parks | Wild | Natural History | Menageries +1 Stability more; +1 Culture per Arena quarter | |
| Propaganda | Wild | Ideology | war weariness −25%; +1 Stability in every city while at war | |
| Resident Ambassadors | Dip | Mercantilism | +3 Influence | Envoys of the Crown |
| Trade Missions | Dip | Free Markets | +2 Gold per envoy at minor factions | Merchant Confederation |
| Diplomatic League | Dip | Ideology | +4 Influence; Friendships cost no Influence | Charismatic Leader |

Policy swaps cost `policySwapGold` (50 + 10 per era, Modern 100).

---

## 8. Units

### 8.1 Unit list
Appended to `UnitType` in the order below. New classes: `navalRaider`, `fighter`, `bomber`
(`fighter` and `bomber` are the **air** domain, §9.5). Columns as M2 §8.1. Air units' Range is
their operational range in tiles.

| Unit | Class | Cost | Str | Ranged | Rng | Moves | Res. | Tech | Upgrade |
|---|---|---|---|---|---|---|---|---|---|
| Musketman | melee | 240 | 55 | — | — | 2 | Niter | Gunpowder | Line Infantry |
| Pike and Shot | antiCavalry | 250 | 55 | — | — | 2 | | Siege Tactics | AT Gun |
| Hussar | cavalry | 260 | 52 | — | — | 4 | Horses | Cavalry Reform | Cavalry |
| Bombard | siege | 280 | 43 | 55 | 2 | 2 | Niter | Metal Casting | Artillery |
| Caravel | navalMelee | 240 | 55 | — | — | 4 | | Navigation | Ironclad |
| Privateer | navalRaider | 260 | 40 | 50 | 2 | 4 | | Navigation | Submarine |
| Frigate | navalRanged | 280 | 45 | 55 | 2 | 4 | Niter | Square Rigging | Battleship |
| Line Infantry | melee | 320 | 65 | — | — | 2 | Niter | Rifling | Infantry |
| Ranger | recon | 220 | 45 | 60 | 1 | 3 | | Rifling | |
| Field Gun | ranged | 330 | 50 | 65 | 2 | 2 | | Ballistics | Machine Gun |
| Cavalry | cavalry | 330 | 62 | — | — | 5 | Horses | Military Science | |
| Cuirassier | heavyCavalry | 340 | 64 | — | — | 4 | Horses | Military Science | Tank |
| Ironclad | navalMelee | 380 | 60 | — | — | 5 | Coal | Steam Power | Destroyer |
| Infantry | melee | 430 | 70 | — | — | 2 | | Replaceable Parts | |
| Machine Gun | ranged | 440 | 60 | 75 | 1 | 2 | | Advanced Ballistics | |
| AT Gun | antiCavalry | 430 | 70 | — | — | 2 | | Advanced Ballistics | |
| Artillery | siege | 480 | 60 | 80 | 3 | 2 | | Steel | |
| Tank | heavyCavalry | 500 | 80 | — | — | 4 | Oil | Combustion | |
| Destroyer | navalMelee | 480 | 75 | — | — | 6 | Oil | Combustion | |
| Battleship | navalRanged | 520 | 65 | 80 | 3 | 5 | Coal | Steel | |
| Submarine | navalRaider | 460 | 65 | 75 | 2 | 4 | | Electricity | |
| Biplane | fighter | 450 | 80 | 60 | 6 | — | | Flight | |
| Bomber | bomber | 560 | 65 | 90 | 10 | — | Oil | Advanced Flight | |

The **resource-free line** (Infantry, Machine Gun, AT Gun, Artillery, Field Gun, Pike and Shot,
Caravel, Submarine, Biplane) guarantees a civ with no Niter, Coal or Oil can still defend itself.

**Upgrade lines** (M2 targets retargeted where shown):

| Line | Medieval | → Renaissance | → Industrial | → Modern |
|---|---|---|---|---|
| Melee | Man-at-Arms, Legion | Musketman | Line Infantry | Infantry |
| Anti-cavalry | Pikeman | Pike and Shot | — | AT Gun |
| Ranged | Crossbowman, Crouching Tiger | — | Field Gun | Machine Gun |
| Light cavalry | Horseman (**retargeted** from Knight) | Hussar | Cavalry | (M3b) |
| Heavy cavalry | Knight, Mandekalu | — | Cuirassier | Tank |
| Siege | Trebuchet | Bombard | — | Artillery |
| Naval melee | Cog | Caravel | Ironclad | Destroyer |
| Naval ranged | Dromon | Frigate | — | Battleship |
| Naval raider | — | Privateer | — | Submarine |
| Recon | Scout | — | Ranger | (M3b) |
| Keshig (Mongols) | Keshig | — | Cavalry | |

M2 Medieval units with no upgrade (Man-at-Arms, Pikeman, Knight, Trebuchet, Cog, Dromon,
Crossbowman) get the targets above; their unique replacements follow their line.

### 8.2 Class bonuses
M2's stand, plus (rules data):
- antiCavalry +10 vs `cavalry` and `heavyCavalry` (unchanged; AT Gun gets it against Tanks).
- `navalRaider`: hidden (M3a-D8); may **plunder** trade routes at sea (M2 §13) and pillage coastal
  improvements; −10 attacking cities.
- **Gunpowder vs walls:** siege units of Renaissance and later deal ×200% to wall HP (M2: ×150%).
- Recon **Ranger** has a ranged attack (range 1) and keeps Scout's sight 3.
- **Tank:** may move after attacking. **Destroyer:** sees navalRaiders within its sight; anti-air
  40 (§9.5). **Machine Gun:** anti-air 30.

### 8.3 Promotions
Tier 3 at 90 XP (M2 §8.3 reserved it). New trees for the new classes.

| Class | Tier 3 (pick one) |
|---|---|
| melee | Urban Warfare: +10 attacking cities · Elite: +5 everywhere, heals +10 per phase |
| ranged | Suppression: targets it hits exert no ZOC until their next phase · Emplacement: +10 defending, fortified at once |
| antiCavalry | Hold the Line: adjacent own units +3 defending · Ambush: +10 vs heavy cavalry attacking it |
| cavalry / heavyCavalry | Breakthrough: may move after attacking · Spearhead: +7 attacking from a railroad or road |
| siege | Rolling Barrage: may fire after moving 1 tile · Counter-Battery: +15 vs siege and ranged |
| recon | Spotter: own siege and ranged units +1 range against targets it sees · Infiltrator: ignores ZOC |
| naval | Broadside: +7 vs cities · Coastal Raid: may pillage from water |
| navalRaider (T1 / T2 / T3) | Silent Running: +1 move · Wolfpack: +5 per adjacent own raider / Periscope: +1 sight · Boarding: +10 vs naval melee / Torpedoes: +10 vs naval · Prize Crew: a ship it sinks with ≥ 50% HP left joins it |
| fighter (T1 / T2 / T3) | Dogfighting: +7 vs air · Strafing: +7 vs land / Drop Tanks: +2 range · Escort: bombers striking within 2 take −50% from intercepts / Ace: +10 vs air · Ground Attack: +10 vs land |
| bomber (T1 / T2 / T3) | Payload: +7 vs cities and quarters · Armour: +7 defending vs air and anti-air / Long Range: +2 range · Precision: +10 vs units / Pathfinders: +10 vs wall HP · Evasion: intercepts deal −50% |

### 8.4 Corps and armies (M3a-D4)
- `formCorps(unit, with: other)`: two own military units of the **same type** on adjacent tiles,
  both with moves left, in own territory. `other` is removed; `unit` becomes a **Corps**: +10
  Strength (+10 Ranged), HP = mean of the two, XP = the higher, promotions of `unit`. Costs
  `corpsGold` (`unit` cost × 50%, −50% with *Mass Levy*). Needs *Nationalism*.
- `formArmy`: a Corps plus a third unit of the same type: **Army**, +17 instead of +10. Needs
  *Mobilization*.
- Naval units form **Fleet** and **Armada**, with the same rule and numbers.
- Upkeep: a Corps counts as 2 units, an Army as 3 (Gold and strategic upkeep).
- **Military Academy:** a city with one may queue a unit as a Corps (+75% cost) or Army (+150%).
- Air units, recon and civilians cannot form Corps.
- Upgrading a Corps or Army costs ×2 or ×3. They never split.
- UI: two or three chevrons on the unit token and card; War Room groups count them once.

### 8.5 Trader
Unchanged. Steam Power: Traders move 3. Railroads count toward the route path cost.

---

## 9. Combat

M2 §9 stands. Additions below.

### 9.1 Modifiers
New preview lines: Corps/Army; Fort; "Out of Coal/Oil/Niter" −5; anti-air (§9.5); tier 3 promotions; government (Order +5 attacking).

### 9.2 Zone of control
M2 §9.3 stands. Hidden naval raiders exert no ZOC. Air units have no ZOC and ignore it.

### 9.3 Naval
- Naval units heal +10 at sea within 3 of an own Seaport (M2: +0 at sea).
- Naval units are built in a city with a Harbor quarter; Ironclad and later also need its Shipyard.
- **Coastal bombardment:** Frigate and Battleship use M2's naval ranged rules; the Battleship's
  range 3 reaches inland.

### 9.4 Naval raiders (M3a-D8)
- **Hidden:** a navalRaider is visible only to units adjacent to it, Destroyers within their
  sight, and cities it is adjacent to. Knowledge and fog follow (an unseen raider is unknown; M1
  knowledge-aware moves treat a hidden raider in the way like any unseen unit).
- Attacking reveals it to the target's owner until the end of its next phase.
- Raiders plunder sea trade routes by moving onto a route tile (no attack needed, all moves).

### 9.5 Air (M3a-D2)
- **Bases:** an air unit is based in an own city (`airSlots` 2 per city) or a Hangar (+2). Bases do
  not count toward the one-military-unit rule. Air units are never on other map tiles.
- **Actions** (one per phase, then the unit's moves end):
  - **Rebase** to another own base with a free slot within `2 × range`.
  - **Strike** a tile within `range`: a unit (the top military one), a city, a quarter, or
    pillage an improvement. Ranged attack rules; target strength is its *melee* Strength except
    vs another air unit. The defender does not damage the attacker except through **anti-air**.
  - **Patrol** (fighters only): until its next phase it **intercepts** the first enemy air strike
    whose target lies within its range: air-to-air combat (fighter's Strength vs the striker's
    Strength) before the strike; a striker brought to 0 HP is destroyed, otherwise it strikes
    with its HP penalty.
- **Anti-air:** units with an anti-air value (Destroyer 40, Machine Gun 30) and cities with
  *Advanced Ballistics* (City Strength − 10) fire at strikes on themselves or on tiles adjacent:
  one exchange per strike, damage table with anti-air vs the striker's Strength.
- **Healing:** +20 per phase not acting (+20 more in a Hangar).
- **Loss of base:** when its base city is captured, an air unit rebases to the nearest own base in
  range with a free slot, else it is destroyed.
- **Fuel:** Bombers need Oil to strike (§3.1). **Sight:** a strike reveals the target tile and its
  neighbours to the striker's owner for that phase.
- **Bomber:** ×150% vs wall HP and quarters (pillages a quarter it brings to 0 HP); −10 vs units.
- **Fighter:** Strength 80 is air-to-air; its ranged 60 is vs land and naval.
- Commands: `rebase(unit, to: city)`, `strike(unit, at: tile)`, `patrol(unit)`. Events:
  `airStrike`, `intercepted`, `airUnitLost`.

---

## 10. War

M2 §10 stands. War weariness (M2 §10.3) is scaled by government (§7.2) and *Propaganda*. Each
Corps or Army lost counts as 2 or 3 units for weariness.

---

## 11. Raiders and minor factions

- **Raider sets by world era** (M2 §11): Renaissance Musketman, Crossbowman, Hussar; Industrial
  Line Infantry, Field Gun, Cavalry; Modern Infantry, Machine Gun. Raiders never get resource
  units of the Industrial era or later, Corps or air.
- **Coastal camps:** from the Renaissance, a camp within 2 of Coast also keeps one **Privateer**
  (raider-owned, never more than one). Raider ships plunder routes and pillage fishing boats; they
  stay within 6 of the camp.
- **Rebels** use the same sets.
- **Minor defenders** per era advance: one melee and one ranged of the new era (M2 §12.1);
  Industrial and later minors also get a Star Fort.
- **Envoy tier 6** (M2 §12.2) adds the era's buildings: Scientific +2 with a Research Lab;
  Cultural +2 with a Museum; Trade +2 with an Exchange; Militaristic +2 with a Military Academy;
  Industrial +2 with a Factory.
- **Quests** add "train a Corps", "send a Trader by sea", "connect us with a railroad".

---

## 12. Trade

M2 §13 stands, plus: Navigation +5 sea range more; Exchange +1 capacity; *Chartered Companies*
+1 capacity; routes between two cities joined by an unbroken railroad give +1 Prod to both ends.

---

## 13. Civilizations

The M2 four keep their abilities; their unique units follow their upgrade lines (§8.1). No new
uniques in M3a: the other four civs' designs (SPEC §18 Q1) come with the full roster, which is
where Modern-era uniques belong too. Agenda additions:
- Mongols: also likes civs with Corps or Armies.
- Mali: dislikes civs with an Exchange in fewer cities than it.

---

## 14. Victory

**No turn limit (M3a-D1).** `constants.turnLimit` becomes optional and is unset; the game ends
only by domination or last civ standing (M2 §16), or when the player stops. Score is kept and
shown on the Victory screen as a standing, never as a win condition. It adds `2 · corpsAndArmies`
and `3 · futureTechs + 2 · futureCivics` to M2's terms; techs and civics count as before, so the
new trees raise every score.

---

## 15. AI (GameAI)

M2 §17 stands. Additions:
- **Grand strategy:** the ideology follows the focus (military → Order, science and
  culture → Liberty, expansion and production → Equality; when two score within 10%, the one
  shared by more Friendly civs); switches only on the free
  turn a civic completes.
- **Resources:** a strategic need list per phase (units it plans, Power Plants, railroads). Builders
  improve needed sources first (M2's order: luxuries it lacks > strategic it needs); deals buy a
  missing Coal/Oil source when gold allows; an `attackCity` utility gets a bonus when the target
  holds a needed source.
- **Power:** queues a Power Plant in the Workshop city that reaches most cities. Fuel: Oil when not
  at war (and not planning one) and Oil covers ≥ 20 turns beyond its planned units; otherwise
  Coal; switches when the chosen fuel has < 3 turns left and the other has more. Keeps ≥ 5 turns
  of fuel or turns production to a new source.
- **Railroads:** connect the capital to cities ≥ 4 away and to the frontline once at war, while
  Coal ≥ 10.
- **Corps:** merge two same-type units when both are in own territory and the army has ≥ 8 units
  of the type's class; never during an `attackCity` advance.
- **Air:** fighters patrol over cities with danger > 0, else rebase toward the frontline; bombers
  strike the target with the best preview value (cities in an active siege first, then siege and
  ranged units).
- **Naval raiders:** patrol known enemy sea routes and coastal improvements; avoid tiles seen by
  enemy Destroyers.
- **Budget:** AI phase ≤ 600 ms on Standard 1+5 at turn 220 (Mac, release); SPEC §12.3 stands
  on device.

---

## 16. App and rendering

### 16.1 Screens
- **Tech and civic trees:** three more era columns; the tree scrolls to the current era.
- **Government screen:** the three ideologies with their trade-offs side by side, and which met
  civs follow each (the diplomatic modifier, §7.2).
- **City panel:** Power line (Powered by which plant, fuel turns left); a Coal/Oil switch on a
  city with a Power Plant; regional effects listed by
  source.
- **Top bar:** stockpile chips for Niter, Coal and Oil once revealed (with cap and per-turn net).
- **Unit card:** Corps/Army chevrons and the Form Corps action when a same-type unit is adjacent.
- **Air tray:** tapping a city with aircraft opens a tray (one row per aircraft: HP, action);
  Strike enters target mode with the range ring and previews; Patrol shows the patrol ring until
  the next phase.
- **Lenses:** Power (§5.3); Resources lens adds the new strategics.

### 16.2 Rendering (ART.md)
- **Units:** procedural figures for muskets, rifles and helmets; field guns and artillery pieces;
  vehicles (Tank) as a new figure kind; sail, steam and steel hulls. Corps and Armies draw two or
  three figures in one token.
- **Aircraft:** parked silhouettes on the base tile (max 2 drawn, then a count); a strike animates
  a flight out and back; patrol shows a faint circling silhouette.
- **Railroads:** drawn by the road planner (MapRenderer+Roads) with **less wander** (amplitude
  ×0.3) and twin rails with sleepers; same continuity across hexes as roads.
- **Buildings:** Factory and Power Plant with chimneys (smoke follows the idle/active frame
  rate); Star Fort's angled bastions on the city centre; Stadium, Broadcast Tower and Seaport
  sprites in their quarters.
- **Resources:** Niter, Coal and Oil icons and tile marks; Oil Well derrick; Fort earthworks.
- Battery: smoke and circling aircraft run only at the active frame rate, like other ambient
  motion (ART.md §battery).

---

## 17. HeadlessSim and balance

- New per-player metrics: era turns; stockpiles over time and turns out of each resource; Power
  Plants (fuelled %); railroads built; Corps/Armies; air units built, strikes, intercepts and
  losses; ideology chosen and switches; naval raider plunders.
- `make balance-m3a`: Standard, 20 seeds, 220 turns (a measuring horizon for HeadlessSim, not a
  game rule: games have no turn limit, M3a-D1).

**M3a balance targets** (Standard 1+5, 20 seeds, 220 turns):
- pacing table §2 met;
- **Resources:** ≥ 80% of AIs have a Coal or Oil source (own, traded or Patron) by turn 190; no
  AI is out of fuel for > 20% of its Modern-era turns in ≥ 80% of games;
- **Power:** ≥ 60% of AI cities Powered at turn 210;
- **Ideologies:** each of the three adopted in ≥ 20% of games (none dominates);
- **Unit counts:** median AI military unit count at turn 210 within 1.3× the count at turn 150
  (Corps keep the map readable);
- **Air:** in games with a war after turn 195, ≥ 50% see an air strike;
- **Wars:** a city captured after turn 150 in ≥ 50% of games;
- no crashes; deterministic; invariants hold every phase with `--check-every-phase` on 5 seeds.

---

## 18. Architecture

### 18.1 Rules data
`ruleset.json` id `m3a.1`. New sections and fields: `eras` (3 more), `power` (burn, reach,
bonuses), `regional` (reach, kinds), `air` (slots, rebase factor, heal, anti-air), `corps`
(bonuses, cost %, upkeep multipliers), `railroad` (Coal cost, move points); `units[].resourceCost`,
`units[].antiAir`, `units[].domain`. New effect kinds: `regionalYield`, `powered`, `airSlots`,
`antiAir`, `corpsCostPct`, `warWearinessPct`, `xpPct`.

### 18.2 State
- `Tile.road`: `UInt8` level. `Tile.improvement` adds Fort, Oil Well.
- `Unit`: `formation (.single/.corps/.army)`, `basedAt: CityID?` (air), `patrolling: Bool`,
  `hiddenUntil` (revealed raider).
- `City`: `airUnits` (derived from units, not stored), `powered` (derived each phase).
- `Player`: stockpiles gain Niter, Coal, Oil.

### 18.3 Commands and events
New commands: `formCorps`, `formArmy`, `rebase`, `strike`, `patrol`, `buildRailroad`, `setFuel`.
New events: `corpsFormed`, `armyFormed`, `airStrike`, `intercepted`, `airUnitLost`,
`powerChanged(city)`, `fuelLow(player)`, `raiderRevealed`.

### 18.4 Determinism and performance
Move points ×6 (M3a-D3) changes every path cost; pathfinder, ZOC and AI movement tests re-pin
their expectations; golden hashes re-pin once. Hidden raiders use the same visibility pass as fog.
Power and regional effects ≤ 1 ms per phase on Large (cities × plants within 6, precomputed per
phase).

### 18.5 Persistence (M3a-D7)
Format version bump; M2 saves listed greyed. Golden saves at turns 120, 170, 210.

---

## 19. Tests

- **GameCore:** rules validation (new sections, DAG, every unit line reachable); move-point
  scale (roads and railroads, M2 paths unchanged in moves); resource reveal; stockpile cap by era;
  Power burn, fuel choice, Coal Stability and unfuelled behaviour (no fallback); regional best-of; Corps/Army formation, upkeep and upgrade;
  air rebase, strike, patrol/intercept, anti-air, base loss; hidden raiders and reveal; Fort;
  Star Fort; new Insight kinds; ideologies and their relationship modifier; policy replacements.
- **GameAI:** ideology by focus; resource need list; Power Plant placement; Corps merging; fighter
  patrol and bomber targeting; naval raider routes; fairness test (AI uses only `view(for:)`).
- **MapRendering:** railroad planner continuity (gallery entries for rail junctions and
  rail-over-road), aircraft parking, Corps tokens.
- **Determinism:** golden hashes for 3 seeds to turn 220.

---

## 20. Work plan

Three increments, each merged, balanced and playable before the next, with a contracts package
first (as M2 §22).

| Increment | Content | Exit |
|---|---|---|
| **3a.1 Renaissance** | Era 3; 9 techs, 5 civics, 8 policies; Niter; Fort; Star Fort, Museum; Musketman, Pike and Shot, Hussar, Bombard, Caravel, Privateer, Frigate; naval raiders (hidden); tier 3 promotions; Horseman retarget; raider/minor sets | Turn 150 reached with research and civics never empty; raiders and Privateers playable |
| **3a.2 Industrial** | Era 4; 9 techs, 5 civics, 8 policies; Coal; move points ×6 and railroads; Factory, Exchange, Research Lab, Seaport, Military Academy, Menagerie, Sewer; regional effects; Corps; Line Infantry, Ranger, Field Gun, Cavalry, Cuirassier, Ironclad | Railroads and Factories used by AIs; Corps keep unit counts in target |
| **3a.3 Modern** | Era 5; 9 techs, 6 civics, 3 governments, 10 policies; Oil and Oil Well; Power; Power Plant, Broadcast Tower, Stadium, Hangar; Armies; air layer; Infantry, Machine Gun, AT Gun, Artillery, Tank, Destroyer, Battleship, Submarine, Biplane, Bomber | Full §17 targets; **late-game check** |

### 20.1 3a.1 as built
Simplified where the M2 promotion and bonus fields already cover the spirit; revisit in balance.
- **Square Rigging:** +1 move for naval units everywhere, not only on Ocean.
- **Insights:** Gunpowder is "own 2 Barracks quarters" (there is no Armory); Exploration is
  "own 3 coastal cities".
- **Tier 3 promotions** (one effect each, from M2's fields): Elite has no extra healing;
  Emplacement does not fortify at once; Hold the Line is +10 defending (no aura); Spearhead is
  +7 attacking anywhere; Rolling Barrage also gives +5 vs cities. *Suppression* became
  **Sharpshooters** (+1 range), *Spotter* became **Pathfinder** (+1 move), and *Coastal Raid*
  became **Ironsides** (+7 defending).
- **Naval raider tree:** T1 Silent Running (+1 move) / **Raiding Party** (+7 attacking, for
  *Wolfpack*); T2 **Lookout** (+1 sight, for *Periscope*) / Boarding; T3 **Raking Fire** (+10 vs
  naval, for *Torpedoes*) / **Prize Hunter** (+7 vs wounded units, for *Prize Crew*).
- **Hidden ships:** hidden from a player unless one of its units or cities is adjacent, or the
  ship attacked this turn or last (`Unit.revealedUntil`); hidden ships exert no zone of control
  and send no move events to the players they are hidden from.
- **Strategic fairness** is data (`stockpile.fairness`: Horses or Iron within 6, Niter within 8);
  `strategicPer1000Land` 14 → 21 for the third strategic.
- **Stockpile cap:** +`capBonus` from `capBonusEra` and again for each later era (Medieval 30,
  Renaissance 40).
- **Forts** are not offered in Builder job lists or automation (`Improvement.tileWork`); the AI
  does not build them yet.
- **AI raiders:** at war, Privateers attack like naval melee, else head for the nearest seen
  enemy sea route tile, else the water by a known enemy city. No avoidance of enemy warships yet.
- **Art:** the seven new units use their forebears' bodies and badges (placeholders); the turn
  marker numerals moved to 64 px cells so the Fort job glyph fits in the 2048 × 1536 unit atlas.
  Their own art needs atlas room beyond ART.md §10's budget (to decide with the art pass).

**Cut order inside M3a** if it runs long (lowest value first): tier 3 promotions for new classes
→ naval raider hiding (they become ordinary ships) → patrol/intercept (fighters only strike) →
Armies (keep Corps) → Power (Power Plant becomes a flat +Prod building) → Bomber.
