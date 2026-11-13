# Driving the app from scripts

Debug builds of Ten Thousand Years can be launched into a known place and driven from a file, so
an agent or a script can play, take screenshots and read the state without touching the
simulator's screen. Everything here except the launch arguments marked "any build" exists only in
debug builds (`#if DEBUG`: `App/Automation.swift`, `App/Scenarios.swift`, `App/DebugLog.swift`).

## Build, install, launch

```sh
make sim SIM="<simulator name>"            # Debug build for that simulator
APP=build/Build/Products/Debug-iphonesimulator/TenThousandYears.app
xcrun simctl install <udid> "$APP"
xcrun simctl launch --terminate-running-process \
    --stdout="$PWD/logs/app-stdout.txt" --stderr="$PWD/logs/app-stderr.txt" \
    <udid> com.tenthousandyears.app -markReady YES -scenario founded
xcrun simctl io <udid> screenshot screens/founded.png
```

Always name the device by UDID; never use `booted`, which may hit someone else's simulator. The
app's data container (saves, inbox, markers) is
`$(xcrun simctl get_app_container <udid> com.tenthousandyears.app data)/Documents`.

If a launch fails with "The request was denied by service delegate (SBMainWorkspace)" and the
simulator's log shows "Launchd job spawn failed" (EPERM), that simulator may not open the
`--stdout`/`--stderr` files (macOS privacy protection on folders such as `~/Documents`): launch
without them, or point them somewhere that simulator can write.

### iPad orientation

iPadOS 26 runs apps in resizable windows, which ignore `-orientation`. For screenshots in a set
orientation on an iPad simulator (an agent's own device only):

1. Turn off the simulator's windowing modes, then reboot it:
   `xcrun simctl spawn <udid> defaults write com.apple.springboard SBMedusaMultitaskingEnabled -bool NO`
   and the same for `SBChamoisWindowingEnabled`; `xcrun simctl shutdown <udid>`, `xcrun simctl boot <udid>`.
2. Install a copy of the app marked full screen and re-signed:
   `plutil -replace UIRequiresFullScreen -bool YES <copy>/TenThousandYears.app/Info.plist`,
   `codesign --force --sign - <copy>/TenThousandYears.app`.
3. Launch with `-orientation landscape` (or `portrait`). Rotate at launch, not with the
   `orientation` inbox command, which can leave the window half turned.

`simctl io screenshot` saves an iPad's landscape screen in its portrait buffer: turn the image with
`sips -r 270`. Undo step 1 afterwards with `defaults delete` of both keys and a reboot.

## Launch arguments

They go after the bundle id, as `-name value` pairs (the `UserDefaults` argument domain), and
apply only to that launch.

| Argument | Builds | Effect |
|---|---|---|
| `-autostart duel\|small\|standard\|large` | debug | Skip the start screen: a new game of that size. |
| `-seed <n>` | debug | Seed for `-autostart` (default 42) and `-scenario` (default 7). |
| `-civ <id>` | debug | The human's civ (`rome`, `mongols`, `mali`, `china`, `inca`, `khmer`, `norse`, `abbasid`); default the first in the rules. |
| `-continue YES` | any | Open the newest save of any kind (as the Continue button). |
| `-revealMap YES\|NO` | any | Diagnostic mode (fog off), or not, for every game opened this launch, saves included; without it, new games follow the start screen's switch and saves open with the fog on. |
| `-stress <n>` | debug | With `-autostart`: spawn n extra units (renderer benchmark). |
| `-cameraScale <x>` | debug | Initial zoom: world points per screen point (1 = tiles at their nominal size, the default; larger zooms out, from 0.35 up to what the map allows). |
| `-topDown YES` | debug | Top-down camera instead of the tilted one. |
| `-showStats YES` | debug | Frame stats and tile coordinates readout. |
| `-showSeam YES` | debug | Start centred on the east–west wrap seam. |
| `-markReady YES` | debug | Write `Documents/rendered` when the first frame is drawn: `start` (start screen) or `game` (a game's map). Wait for it before a screenshot. |
| `-scenario <name>` | debug | Open a preset (below) at `-autostart`'s size (default `duel`), `-seed`, `-civ`. |
| `-orientation portrait\|landscape\|landscapeLeft\|landscapeRight` | debug | Rotate the window. Works on iPhone. On iPad, iPadOS's windowing refuses programmatic rotation (logged as `Orientation … refused`) unless the app runs full screen: see "iPad orientation" below. |
| `-resetSaves YES` | debug | Delete `Documents/Saves` and `Documents/NoticeLogs` before anything else, and forget the games in which the end-turn question was asked (`endTurnQuestionAsked`). |
| `-seedText <text>` | debug | What the New Game card's seed field starts with (its validation: letters, a number too large, `""` for empty). |
| `-aiDriver real\|scripted\|random` | debug | Who plays the AI players: `AIPlayer.playTurn` (the default), or the stand-ins built on `DebugTools`. |
| `-quickAITurns YES\|NO` | any | AI phases land at once (no playback waits). Without it, the in-game switch's remembered value. |
| `-diagnosticMode YES\|NO` | any | The start screen's diagnostic switch for this launch: new games only (Continue and Load open with the fog on). |

## Scenarios

`-scenario <name>` or the inbox command `scenario <name>`. Each is built through `GameEngine`
commands and `GameState.addUnit`, so it passes `checkInvariants()` (a failure is logged).
A scenario's game never autosaves or writes a background slot (nor does one loaded from its
manual saves), so it never pushes a real game's saves out (M1 §14). Every scenario is built
without the tribal villages a new game places (`NewGameSetup.tribalVillages` false), so the
others' play, gold, research and unit ids stay as they were; `tribal-villages` places its own.
New Game, `newgame` and `-autostart` always place them.

| Name | What is on screen |
|---|---|
| `fresh` | A new game, turn 1, the first unit selected. |
| `founded` | Turn 1 with the human's capital founded where its Settler stood; the city selected. |
| `midgame` | 40 turns played by the scripted stand-in for every player (the human too); the capital selected. |
| `war` | 30 turns, then an enemy force (player 1) three tiles from the human's capital, met and at war, and an own line between; an own Archer selected with its targets marked. |
| `siege` | 30 turns, then a human army around player 1's capital at war, the city already hit by two Archers; an own Warrior beside it selected. |
| `melee` | 30 turns, then at war, an own Warrior (wounded by an enemy Archer in its phase) three tiles from player 1's capital, selected, beside two wounded enemy Warriors: `tap` the one two tiles from the city for a combat card that warns the winner moves within its bombard's range; the one three tiles out gets no warning. The note gives both tiles. Turn 31. |
| `cities` | Eight cities per player founded on valid sites (capital first, then the nearest sites), one per phase: the city-banner load test. Played on `standard` when the size asked for is `duel` or `small`; any other size is kept (`-autostart large -scenario cities` for strategic zoom). |
| `attention` | 30 turns, then most attention items at once: the capital's queue emptied, a new city (population 1) with a Settler first in its queue, another whose own tiles all hold sleeping Warriors (its Warrior has no room), more units than an empty treasury pays for, and an enemy Warrior beside the capital at war (city under attack, bombard). Nothing selected; `attention` lists the queue. |
| `capture` | 40 turns (more, five at a time up to turn 70, until player 1 has a second city: seed 9 takes 50), then player 1's second city at 0 HP, at war, an own Warrior beside it selected: `tap` the city and `attack` to take it (the Keep/Raze card). |
| `conquest` | As `capture`, on player 1's original capital: taking it wins by domination (the game-over card). |
| `peace` | At war with player 1 from turn 24; in its phase of turn 30 player 1 proposes peace; the human's phase of turn 31 follows, the capital selected. The proposal is the last attention item. |
| `rivals` | 30 turns, then one of player 1's Warriors in sight of the human's capital (met, at peace), on the first unowned tile 2 to 4 tiles out that the human sees (when there is none, an own Warrior on the border facing player 1 looks further first): the diplomacy sheet with Declare War, and `aicommand 1 war 0` for a war declared on the human. A second Warrior of player 1 waits out of sight one step from another such tile, for the troops-near notice (below). |
| `taps` | Turn 1, the capital founded (its Warrior inside); an own Warrior two tiles out, selected, with an own Settler beside it, and at war with player 1, whose Settler and Builder stand alone beside the Warrior (marked as capture targets): the tap rules that route a unit into an own city, onto own units of the other kind, and onto enemy civilians to capture them. |
| `walls` | Player 1 researches Masonry from turn 1 and, once it knows it, buys Walls (wall HP 100) in its capital; then, at war, an own Archer two tiles from that city, selected: `tap` the city for the combat card's wall bar. |
| `repreview` | Turn 1, the capital founded; at war, an own Warrior selected two tiles from an enemy Warrior, with an enemy Spearman beside that one out of sight. `tap` the Warrior twice: the move to the attack's tile brings the Spearman into sight, so the attack stops and the card shows the new odds ("New units in sight: check the odds"); a third tap attacks. |
| `tribal-villages` | Turn 1, the capital founded and the Scout selected, with four tribal villages placed by hand (`DebugTools.placeTribalVillage`): one 2 tiles from the Scout (reached this phase); one 5 tiles from it and 3 beyond the first, out of sight until the Scout stands on the first, then within the Explore order's reach; one on the capital's next border tile, its culture primed (`DebugTools.primeBorderGrowth`) so the next phase start's border growth takes it in; and one toward player 1, in sight, with one of player 1's Scouts out of sight 2 tiles beyond it that reaches it in one phase. The note names the tiles and the commands (below). |

The `scenario` command's result ends with the scenario's note when it has one: the units and
tiles to use next (`rivals`, `walls`, `repreview`, `tribal-villages`).

**Troops near** (the troops-near notice, M1 §16 "Notifications"): in `rivals`, the note names the
second Warrior and a tile in sight within 4 tiles of the capital, as a ready command. Unit ids and
tiles change with the seed and the rules, so run the `aicommand` the note prints, not one copied
from here (on Duel seed 7, at the time of writing: Warrior 18, `aicommand 1 move 18 12 7`):

```sh
automate.sh <udid> "scenario rivals"     # … Warrior 18 out of sight at 13 7: `aicommand 1 move 18 12 7` and `endturn` …
automate.sh <udid> "<the note's aicommand>" "endturn" "notices"
# ok notices -> Mongol troops near Rome (2 units) (waits); 1 logged, 1 unread
```

The notice comes at the start of the human's phase, for units that were not near any of its
cities when its previous phase ended (the first rival is already known), at most once per city
every 5 turns.

**Tribal villages** (M1 §7.7; the notices are kinds `tribalVillageSeen`, `tribalVillageGift` and
`tribalVillageGone` in `noticelog`): `tribal-villages` puts four around the human's start. Its
note names the Scout, the tiles and the `aicommand` to use; they change with the seed and the
rules, so use the note's, not these (Duel seed 7, at the time of writing: Scout 3 at 10 6, the
near one at 10 4, the far one at 7 4, the border one at 9 8, the shared one at 12 7 with player
1's Scout 7). Each player's gifts come from its own bag (Gold, Science and a Builder in every
three, in an order fixed by the seed; the amounts are the rules'), so which gift a take gives
depends on how many came before. Two passes, each from a fresh `scenario`; the results are those
of the time of writing:

```sh
# Pass 1: the turn-1 toast, the tile sheet, the rival's take and the border claim.
automate.sh <udid> "scenario tribal-villages" "notices" "longpress 10 4"
# ok notices -> 3 tribal villages spotted · first to arrive gets a gift; 1 logged, 1 unread
# ok longpress 10 4 -> (10,4) · tribal village: Seen now
automate.sh <udid> "escape" "aicommand 1 move 7 12 7" "endturn" "notices" "attention"
# ok notices -> Rome's land took in a tribal village: a Builder joins you | Met Mongols, led by
#   Genghis Khan | Mongols reached the tribal village east of Rome first (waits); 4 logged, 3 unread
# ok attention -> 6 [unit 2, unit 3, unit 8, emptyQueue 1, research, news 6] next unit 8
# (The Scout at 10 6 saw player 1's take: info. The border claim at the human's phase start is
# important: the card waits, `news` in `attention`, and the new Builder 8 has its moves.)

# Pass 2: the own tap, the float label, the remembered tile, the Explore order and "gone".
automate.sh <udid> "scenario tribal-villages"
automate.sh <udid> "slowmo 4" "tap 10 4" "tap 10 4"
xcrun simctl io <udid> screenshot tap.png   # the "+1 Builder" label rising from 10 4
automate.sh <udid> "slowmo 1" "notices" "attention" "noticelog 3"
# ok notices -> 4 tribal villages spotted | Your Scout reached a tribal village: a Builder joins
#   you; 3 logged, 3 unread      (info: no `(waits)`, nothing in `attention`; the merged
#   sighting drops the rule once a gift has come)
# ok noticelog 3 -> … | t1 tribalVillageSeen: Tribal village spotted 4 tiles south-west of Rome
automate.sh <udid> "longpress 12 7"   # … tribal village: Remembered: it may be gone
automate.sh <udid> "escape" "explore on" "explore list"   # 3->(7,4)
automate.sh <udid> "aicommand 1 move 7 12 7" "endturn" "notices" "attention"
# ok notices -> Rome's land took in a tribal village: +20 Science | Your Scout reached a tribal
#   village: +50 Gold | Met Mongols, led by Genghis Khan (+1) (waits); 7 logged, 4 unread
# ok attention -> 6 [unit 2, unit 8, emptyQueue 1, research, news 7, news 8] next unit 8
# (An Explore leg took 7 4 at the phase start: important, as is the border claim. Player 1 took
# 12 7 out of the human's sight: no line yet.)
automate.sh <udid> "tapnotice" "select unit 2" "tap 11 6" "tap 11 6" "endturn" "noticelog 1" "notices"
# ok noticelog 1 -> t3 tribalVillageGone: The tribal village east of Rome is gone
# ok notices -> no card; …     (quiet: in the log, never on the toast)

# Nothing about the ones the human never saw: their rings show only with `diagnostic on`, and no
# notice names one it never knew of. In a new game none may be in sight on turn 1 (the nearest
# lie 4 to 6 steps out): sightings come as units explore.
automate.sh <udid> "newgame duel 11" "diagnostic on" "select unit 3" "explore on" \
  "endturn" "endturn" "endturn" "endturn" "endturn" "endturn" "noticelog 30" "dump"
# … t2 tribalVillageSeen: Tribal village spotted 2 tiles south-east of your Scout · first to
#   arrive gets a gift | … | t5 tribalVillageSeen: Tribal village spotted 2 tiles north of your Scout …
```

Before takes exist (a copy without phase 3g's core), `testgift` (below) shows a gift's notice,
label and attention through the same path, without changing the game.

## The inbox

The app polls `Documents/automation.txt` every 0.25 s. Write the whole file elsewhere and move it
into place, so the app never reads half a file. The app deletes the inbox and any old
`automation.done`, runs the lines in order (each waits as described below), then writes
`Documents/automation.done` with one line per command: `ok <command>[ -> <result>]` or
`error <command> -> <why>`. Blank lines and lines starting with `#` are skipped.

```sh
#!/bin/zsh
# automate.sh <udid> <command lines...>: runs the commands and prints automation.done.
UDID=$1; shift
DOC="$(xcrun simctl get_app_container $UDID com.tenthousandyears.app data)/Documents" || exit 1
rm -f "$DOC/automation.done"
printf '%s\n' "$@" > "$DOC/automation.tmp"
mv "$DOC/automation.tmp" "$DOC/automation.txt"
for i in $(seq 1 1200); do [ -f "$DOC/automation.done" ] && break; /bin/sleep 0.25; done
cat "$DOC/automation.done" 2>/dev/null || { echo "automation timed out"; exit 1; }
```

```sh
automate.sh <udid> "scenario founded" "select city 1" "dump"
automate.sh <udid> "command queue 1 warrior monument" "endturn" "endturn"
```

"Idle" below means no world being made, no AI phase, no animation and no save being written,
plus 0.25 s for the screen to draw.

### App commands (work on the start screen too)

| Command | Effect | Result |
|---|---|---|
| `newgame [size] [seed] [civ] [fog\|nofog]` | New game (default `duel 42`, first civ, fog on); waits until idle. | `turn T, player P, U units, C cities` |
| `scenario <name>` | Open a scenario; waits until idle. | as above, then the scenario's note, if any |
| `continue` | Open the newest save; waits until idle (AI phases before the human's play first). | as above |
| `load [i]` | Open save number i of the list, newest first (default 0). | as above |
| `saves` | List the saves, then the files Load cannot open. | `file[kind, turn T], …, file[other version\|damaged], …` |
| `quit` | Back to the start screen, as the menu's Quit (writes the game's resume point when anything happened since the newest save; none for a finished game). | `start screen` |
| `loadsheet [off]` | Show (or close) the Load Game sheet. | `true` / `false` |
| `alert ok` | Dismiss the app's alert (such as "Rules Changed"). | its title |
| `orientation <name>` | As `-orientation`. | |
| `wait [seconds]` | Sleep (default 1). | |
| `wait-idle` | Wait until idle (60 s at most). | as `newgame` |

### Game commands (need a game on screen)

| Command | Effect |
|---|---|
| `tap <q> <r>` | A tap on that tile, as a finger would make it: on units if any, else on a city, else the ground. Follows the tap rules (select, cycle the stack, preview a route or attack, a second tap confirms, a foreign unit or city opens its info card). With an own unit selected that can move, an own city, a tile of only own units of the other kind, or enemy civilians at war within this phase's reach preview the unit's route instead; the hint ("Tap again to capture the Settler") is the dump's `message`. Result: the selection or preview (`unit 15`, `city 1`, `attack preview on (q,r)`, `path to (q,r) in N turns`, `info card (q,r)`, `tile sheet (q,r)`, `nothing selected`). |
| `tapcity <q> <r>` | The same, preferring the city on the tile. |
| `tapscreen <x> <y>` | A tap at a view point (points from the map's top-left), exactly as a finger: a city banner first, else what the map shows there. Result as `tap`. |
| `tapbanner <city>` | A tap on that city's banner: an own city's selects it in one tap (with a route into it previewed, it moves the unit; on the selected city, the cycle goes on to its units); a foreign city's is as a tap on its sprite. Result as `tap`. |
| `longpress <q> <r>` | The tile sheet for that tile (yields, owner, defence, a tribal village the human knows of). Result: `(q,r)`, followed by `· tribal village: Seen now` or `· tribal village: Remembered: it may be gone` when the sheet has that row. |
| `escape` | The Esc key: closes the combat preview, else drops the previewed route, else closes the open card, else deselects. Result as `tap`. |
| `routeto <q> <r>` | The tile sheet's "Move here": previews the selected unit's route there. |
| `confirmpath` | The unit card's Move: moves along the previewed route. |
| `actions` | The selected unit's action bar in order, each `kind` or `kind(why not)`. |
| `action <kind>` | A tap on that action tile (`foundCity`, `buildFarm`, `fortify`, …); an unavailable one shows its description and reason instead. Result: the reason, or the message shown. |
| `describe <kind>\|off` | The action bar's description line, as a long-press on the tile. |
| `explore [on\|off\|describe\|list]` | The selected military unit's Explore tile (a Scout's first action, the others' last): `on` (the default) taps it while the unit is not exploring (the order is given and its first steps taken), `off` taps Stop while it is, `describe` long-presses it. Result: the card's line (`Exploring · heading north-east`, as the map shows it; `Exploring · heading west, keeping out of the Roman Scout's reach` after a step that leads no nearer its goal; `Exploring · resting to heal, 45 HP (on at 80)`; or why the order ended this phase); after `off`, the card's line or `not exploring`. `list`: the explorers, `unit->(q,r)` (the frontier tile or the tribal village it heads for), `resting`, and `knows [ids]` (enemies in sight when the order was given), or `none`. Why an order ended, and a good city site an explorer found ("Scout found a good city site 6 tiles west of Rome (river, hills)"), are notices of kind `explore` (`noticelog`), one line each. |
| `banners` | The city banners shown, top-most first: `id:name@x,y,wxh`, with `(focus)` on a banner over the selection, a route, an attack or the tile of an open card (taps there, off its name row, go to the map), and `(faded)` on one whose secondary rows (growth, production, HP) are faded over a unit next to its city. The name row never fades. At strategic zoom, `(up)` or `(down)` marks a tag moved one tag height from its place to clear another. `(pill)`: the banner over a focus tile collapsed to its pill (the strategic tag, with a damaged city's HP bar). A damaged city's HP bar never fades, so `(faded)` dims growth and production only, and the human's own units asleep or fortified fade nothing. |
| `notices` | The notice toast on screen (its lines; `(waits)`: an important card, which stays until a tap on the map (`tap`, `tapcity`, `tapscreen`, `tapbanner`, `longpress`), `next`, End Turn or `tapnotice`), how many notices are logged, and how many are unread (posted since the human last ended a phase, until the Notices log opens; the game menu's badge; a save keeps it). |
| `noticelog [n]` | The last n notices of the log (default 10), oldest first: `t<turn> <kind>: <text> \| …`. Tribal villages log as `tribalVillageSeen` (a sighting; on the toast, sightings merge: "4 tribal villages spotted"), `tribalVillageGift` (a gift the human had) and `tribalVillageGone` (a rival's take the human saw, and, quiet, so in the log only, one found gone). |
| `noticelog locate <i>` | A tap on row i of the Notices log (0: the top row, the newest), as its button: the log closes and the camera goes where it happened. Result: `camera to (q,r): <text>`, or why not (a row with no place has no button). |
| `tapnotice` | A tap on the notice toast: the camera goes to its first line's place. |
| `testnotices` | Posts three sample notices (production, growth, a declaration of war), for looking at the toast. |
| `testgift [gold\|science\|builder] [phase] [city] [q r]` | A tribal village gift to the human, shown as a take would show it (a `tribalVillageTaken` and a `tribalVillageGift` record through the session's notice, label and attention path) without changing the game: taken by the selected own unit, or with `city` by the capital's land; on the taker's tile, or on `q r`; as the human's own command, or with `phase` as at its phase start (important, so the card waits and `attention` lists `news N`). The amounts are the rules'. Result: the log's newest line, `<kind> <importance>: <text>` (`tribalVillageGift info: Your Scout reached a tribal village: +50 Gold`). With `slowmo 4` first, a screenshot catches the float label. |
| `panel research\|tech\|diplomacy\|notices\|close` | Opens the tech panel, the diplomacy sheet or the notices log (the menu's Notices…), or closes the open one (and the Load sheet); `close` also deselects a selected city, closing its panel, as `escape` would. Result: what is open (`panel research`, `city panel (overview)`, the selection). |
| `research <tech>` | A tap on that tech's row of the tech panel (id such as `animalHusbandry`, or name), opening the panel first: researches it through its missing prerequisites and closes the panel, or says why not (`Mining is already known`, another player's phase). Result: `researching <tech>, N turns[, on the way to <target>]; panel closed`. |
| `panel city <id>` | Selects that own city: its panel (iPad side panel, iPhone sheet). |
| `panel production\|overview\|yields\|defence` | Scrolls the selected city's panel to that part (production opens the iPhone sheet at its large detent). |
| `slowmo <factor>` | Event animations and damage numbers that many times slower (1: normal), for screenshots. |
| `flyover [off]` | A continuous eastward pan: frame rates while scrolling. |
| `framestats` | The developer readout line: renderer stats, banners shown, time the overlay spends per frame. |
| `select unit <id>`, `select city <id>`, `select none` | Select directly. |
| `deselect` | Clear the selection and previews. |
| `command <verb> …` | One `GameEngine` command for the human player (refusals come back as `error … -> <reason>`); see the grammar below. |
| `attack` | Confirm the attack being previewed. |
| `next` | The Next button (Space): visits the next attention item (a unit is selected; a city opens its panel; research opens the tech panel; peace, war, upkeep, news and Keep/Raze show their cards), or ends the turn when none is left. Result: `<item>: <what opened>`, or `ended the turn -> turn N`. |
| `attention` | The attention queue in order, what Next visits next, and how long working them out took on the main thread: `N [unit 3, emptyQueue 1, research, settlerWaiting 4, productionBlocked 5, upkeep, cityUnderAttack 1, bombard 1, peaceProposal 1, warDeclared 1, capturedCity 4, news 2] next unit 3 (0.42 ms)`. |
| `requestendturn` | Return: ends the turn (waiting for the other phases), or asks "N items need attention — End Turn?" once per game. Result: `prompt: N items` or `turn A -> B`. |
| `hourglass` | A tap on the hourglass beside Next, there while items are pending: as `requestendturn`. An error when it is not shown (nothing pending, another player's phase, the game over). |
| `endturnprompt reset` | The question will be asked again in this game. |
| `confirm yes\|no` | Answers the confirmation on screen, the first of: the end-turn question, a purchase over half the treasury, Raze, Declare War, Disband, Load with unsaved moves. |
| `queue add <item>`, `queue remove <i>`, `queue move <from> <to>` | The selected city's panel: add an item (a unit type or building id), remove entry i (0 first), or drag entry `from` to `to`. Result: the queue. |
| `buy <item>` | The panel's Buy button: buys at once, asks first above half the treasury (`asks: P of G gold`), or says why not. |
| `focus balanced\|food\|production\|gold` | The panel's Citizens focus. |
| `bombard [cancel]` | The selected city's Bombard: target mode (the panel steps aside; with one target its preview opens), or leaves it. |
| `keep`, `raze` | The Keep/Raze card's buttons (Raze asks first: `confirm yes`). |
| `peace accept\|decline` | Answers the peace card, or else the first pending proposal. |
| `declarewar <player>` | Diplomacy's Declare War (asks first: `confirm yes`). |
| `proposepeace <player>` | Diplomacy's Propose Peace. |
| `closecard` | Closes the attention card on screen (a Keep/Raze card stays in the queue until answered). |
| `aicommand <player> <command…>` | The AI player issues that command (grammar below) at the start of its next phase, before it plays: `aicommand 1 war 0` declares war on the human. |
| `savemenu`, `savemenu ok\|cancel` | The menu's Save Game… prompt with its default name ("<Civ> – Turn N"), then its Save or Cancel (a name left at its default, or empty, names the turn saved). |
| `loadmenu` | The menu's Load Game…: asks first when moves were made since the newest save (`asks first`; `confirm yes` opens the list), else the list. |
| `warnload` | Shows the alert a save with changed rules data shows when opened (`alert ok` closes it). |
| `endturn [nowait]` | End the human's phase; waits (up to 300 s) for the other players' phases unless `nowait`. Result: `turn A -> B`. |
| `zoom close\|standard\|strategic\|<scale>` | Camera scale, as `-cameraScale` (close 0.6, standard 1, strategic 2.6, clamped to what the map allows: strategic tokens show from 2.1, or from 98% of the widest zoom where the map's width stops zoom-out short of 2.1: Duel on an iPad on its side or on a 13-inch iPad, Small on a 13-inch iPad on its side). |
| `center <q> <r>`, `center selection`, `center unit <id>`, `center city <id>` | Move the camera, without animation. |
| `diagnostic [off]` | Diagnostic mode on (fog off) or off. |
| `quickai [off]` | Quick AI turns on or off (remembered, like the in-game switch). |
| `aidriver real\|scripted\|random` | Change who plays the AI players from the next AI phase. |
| `save [name]` | A manual save (default name "<Civ> – Turn N"). Result: the file name. |
| `stats [off]` | The developer readout. |
| `dump` | Write `Documents/automation-state.json` (below). |

Coordinates are axial `q r` (the dump gives both axial and offset `col`/`row`); they are
normalized across the wrap seam. Unit and city ids are the engine's (`UnitID`, `CityID`); the
first city of a game has id 1.

### `command` grammar

`found <unit>` · `move <unit> <q> <r>` · `attack <unit> <q> <r>` · `bombard <city> <q> <r>` ·
`fortify|sleep|wake|skip|disband|cancel <unit>` · `build <unit> farm|mine|pasture` ·
`research <tech>` · `queue <city> <item>…` (unit types such as `warrior`, or building ids such as
`monument`; replaces the queue) · `buy <city> <item>` · `focus <city> <focus>` ·
`war <player>` · `peace <player>` · `accept <player>` · `decline <player>` · `raze <city>` ·
`endturn` · `json <Command as JSON>` (any command, in its `Codable` form).

`command endturn` ends the phase and starts the other players' phases but does not wait for
them; `endturn` (the app command) does.

### `automation-state.json`

Written by `dump`, pretty-printed with sorted keys. What the human player knows, plus a few
facts about the session:

- `turn`, `currentPlayer`, `phaseCount`, `outcome` (null while the game goes on), `stateHash`
  (hex, of the whole state: equal hashes mean equal games);
- `gold`, `researching`, `diagnostic`, `inputEnabled` (false during AI phases), `message` (the
  message over the map, if any), `selection` (as the `tap` result), `cameraScale`, `strategic`
  (whether the map shows strategic tokens at this zoom), `commandsSinceSave`;
- `card`: the bottom card on screen (`gameOver`, `keepOrRaze`, `peaceProposal`, `warDeclared`,
  `upkeep`, `news`, `combatPreview`, `bombardTargets`, `tileSheet`, `infoCard`, `unit`, or null;
  a city's panel is not a card), `pendingPathTurns` (the previewed route's turns, or null);
- `attention` (the queue, as the `attention` command lists it), `nextItem`, `attentionCard`,
  `openPanel` (`research`, `diplomacy`, `notices` or null), `cityPanel` (the selected city's panel part, or
  null), `bombardTargeting` (the city picking a target), `endTurnPrompt` (the count asked
  about), `pendingPurchase`, `pendingRaze`, `pendingWar`, `peaceProposals` (players whose
  proposal awaits the human's answer), `mapInsets` (points the HUD covers on each side),
  `viewSize` (the map view, points), `selectionPoint` (where the selection's tile is in the
  view, or null), `selectionInOpen` (whether that is in the part the panels leave open);
- `notice` (the notice toast's lines, or null), `noticesLogged`;
- `bannersShown`, `bannersKnown` (city banners on screen and in all), `overlayMs` (time the
  overlay spends placing banners and damage numbers per frame, smoothed);
- `units`: own units with `id`, `type`, `at`, `moves`, `hp`, `activity`, `attackTargets`;
- `cities`: own cities with `id`, `name`, `at`, `population`, `hp`, `queue`, `focus`,
  `storedProgress`, `capturedTurn`, `bombardTargets`;
- `knownCities`: every city the human knows of (as last seen), with `owner`;
- `visibleForeignUnits`: other players' units in sight now;
- `players`: `id`, `civ`, `alive`, `score`, `met`, `atWar`;
- `tribalVillages`: the tribal villages the human knows of (its memory, sorted by tile), each
  `{q, r, col, row, seen}` (`seen`: in sight now, else remembered); `tribalVillageGifts`: how
  many gifts it has had.

Each `at` is `{q, r, col, row}`.

## Log lines

Debug builds write these to standard output as they happen (no buffering), so
`simctl launch --stdout=<file>` captures them:

- `AI playback, <civ>: N steps, M shown, waited X ms[, instant from step K]`: one per AI phase.
  "Shown" counts the batches whose events the human may see and that playback waited for;
  "instant from step K" means the steps from K on landed at once (K = 0: all of them), because
  the 3 s playback budget was spent, or for quick AI turns, Reduce Motion or the app not in the
  foreground.
- `Invariants failed after <civ>'s phase of turn T: …`: `checkInvariants()` runs after every AI
  phase (on a background thread).
- `Invariants failed before the autosave|background save of turn T (it will not load): …`: the
  state about to be saved is checked too.
- `Scenario <name>: invariants failed: …`
- `Explore resumed for [ids] of [ids]`: after a load, the units whose Explore order the save's
  header kept that took it up again. `Explore ended for unit N: <text>` and `Explore found a site
  for unit N at (q,r): <text>`: the order's notices. `Explore leg of unit N to (q,r) refused: …`:
  a step the engine refused (there should be none).
- `AI phases suspended in <civ>'s phase of turn T`, `AI phases resumed in turn T`: a load stopped
  the other players' phases while its save opened (resumed when it would not open).
- `Orientation <name> refused: …`
- `Notices log for <save file> not written: …`: a save's Notices log (`Documents/NoticeLogs`) could
  not be written; the save opens with an empty log.

Debug builds also assert that replaying an AI phase on the main state gives the same events and
the same final `stateHash()` as the AI's own run (the hash is checked on a background thread, just
after the phase). Release builds log a refused replay step to the system log (subsystem
`com.tenthousandyears.app`, category `AI playback`).
