#if DEBUG
import GameAI
import GameCore
import MapGen
import UIKit

/// Debug presets that put the game in an interesting place without playing to it
/// (`-scenario <name>` or the automation command `scenario <name>`; App/AUTOMATION.md):
///
/// - `fresh`: a new game, turn 1.
/// - `founded`: turn 1 with the viewer's capital founded where its Settler started.
/// - `midgame`: 40 turns played by the scripted stand-in for every player (the viewer too).
/// - `war`: 30 turns, then an enemy force beside the viewer's capital, met and at war; an own
///   Archer selected with its attack targets marked.
/// - `siege`: 30 turns, then a viewer army around the enemy capital at war, the city already
///   hit by two Archers; an own Warrior beside it selected.
/// - `melee`: 30 turns, then at war, an own Warrior (wounded by an enemy Archer) three tiles from
///   the enemy capital, selected, beside two wounded enemy Warriors: one two tiles from the city,
///   whose combat card warns that the winner moves within the city's bombard range, and one
///   three tiles out, whose card does not.
/// - `cities`: every player founds 8 cities (48 on a Standard map, the size it uses unless
///   `-autostart` names a larger one): the city banners' load test (with `-revealMap YES`
///   every banner shows).
/// - `attention`: 30 turns, then most attention items at once: the capital's queue emptied, a
///   new city waiting for population 2 to finish a Settler, another whose Warrior has no tile
///   to appear on, more units than the empty treasury pays for (asleep), an enemy Warrior at
///   war beside the capital (city under attack, bombard available).
/// - `capture` / `conquest`: 40 turns (`capture`: more, up to 70, until player 1 has a second
///   city), then at war with player 1, one of its cities (the original capital for `conquest`,
///   which wins a duel) at 0 HP after Archers' volleys, and an own Warrior beside it selected:
///   tap the city twice to take it.
/// - `peace`: 30 turns into a war declared on turn 24, player 1 has proposed peace.
/// - `rivals`: 30 turns, then player 1 met (a Warrior of theirs in sight) and at peace: for
///   `aicommand 1 war 0`. A second Warrior of theirs waits out of sight beside a tile in sight
///   within 4 tiles of the capital: `aicommand 1 move` and an end of turn bring it near (the
///   troops-near notice; the scenario's note gives the command).
/// - `walls`: player 1 researches Masonry from turn 1 and, once it knows it, buys Walls in its
///   capital; then, at war, an own Archer two tiles from that city, selected: the combat card's
///   wall bar.
/// - `repreview`: turn 1, the capital founded; at war, an own Warrior two tiles from an enemy
///   Warrior, with an enemy Spearman beside that one out of sight: the move to the attack's
///   tile brings the Spearman into sight and the preview shows the new odds.
/// - `taps`: turn 1, the capital founded (its Warrior inside); an own Warrior two tiles out,
///   selected, beside an own Settler and, at war, player 1's Settler and Builder: the tap
///   rules that route a unit (into a city, onto own units, onto enemy civilians to capture).
/// - `tribal-villages`: turn 1, the capital founded and the Scout selected, with four tribal
///   villages placed by hand (M1 §7.7): one 2 tiles from the Scout, which it reaches this
///   phase (its own tap takes it); one 5 tiles from it and 3 beyond that one, out of sight
///   until the Scout gets there, which an Explore order then takes (an Explore leg's gift); one
///   on the capital's next border tile, its culture filled to one phase short, so the next
///   phase start's border growth takes it in; and a shared one toward player 1, with a Scout of
///   player 1 two tiles beyond it, out of sight, for `aicommand` (a rival's take). The note
///   gives the tiles and commands.
///
/// Every preset is built through `GameEngine` commands and `GameState.addUnit` (which keeps
/// knowledge current), so the state passes `checkInvariants()`; problems are logged. Presets
/// are built without the tribal villages a new game places (`NewGameSetup.tribalVillages`), so
/// their play stays as it was; `tribal-villages` places its own (`DebugTools`).
enum Scenarios {
    /// The note of the latest scenario put on screen (nil when it has none or failed).
    @MainActor static var lastNote: String?

    static let names = ["fresh", "founded", "midgame", "war", "siege", "melee", "cities", "attention", "capture", "conquest", "peace",
                        "rivals", "taps", "walls", "repreview", "tribal-villages", "veterans", "resources", "roads", "naval",
                        "stability", "quarters", "loyalty", "upkeep", "governance", "world"]

    /// What to select and look at once the preset is on screen.
    enum Focus: Sendable {
        case unit(UnitID)
        case city(CityID)
        case hex(HexCoord)
    }

    struct Made: Sendable {
        var state: GameState
        var focus: Focus?
        /// What to do next, for the tester (the `scenario` command's result adds it).
        var note: String? = nil
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func make(_ name: String, size: MapSize, seed: UInt64, civ: CivID) throws -> Made {
        let viewer = PlayerID(0)
        let size = name == "cities" && [.duel, .small].contains(size) ? .standard : size
        var state = AppModel.makeGame(AppModel.NewGameSetup(size: size, seed: seed, civ: civ, diagnostic: false, tribalVillages: false))
        let made: Made
        switch name {
        case "fresh":
            made = Made(state: state, focus: state.units(of: viewer).first.map { .unit($0.id) })
        case "founded":
            foundCapital(&state, player: viewer)
            made = Made(state: state, focus: state.cities(of: viewer).first.map { .city($0.id) })
        case "midgame":
            play(&state, untilTurn: 40)
            made = Made(state: state, focus: state.players[0].capital.map { .city($0) })
        case "war":
            play(&state, untilTurn: 30)
            made = try warFront(&state)
        case "siege":
            play(&state, untilTurn: 30)
            made = try siege(&state)
        case "melee":
            play(&state, untilTurn: 30)
            made = try melee(&state)
        case "cities":
            manyCities(&state, perPlayer: 8)
            made = Made(state: state, focus: state.players[0].capital.map { .city($0) })
        case "attention":
            play(&state, untilTurn: 30)
            made = try attention(&state)
        case "capture", "conquest":
            play(&state, untilTurn: 40)
            if name == "capture" { playUntilASecondCity(&state) }
            made = try capture(&state, capital: name == "conquest")
        case "peace":
            play(&state, untilTurn: 24)
            _ = try warFront(&state)
            play(&state, untilTurn: 30)
            made = try peaceOffer(&state)
        case "rivals":
            play(&state, untilTurn: 30)
            made = try rivals(&state)
        case "taps":
            foundCapital(&state, player: viewer)
            made = try taps(&state)
        case "walls":
            made = try walls(&state)
        case "repreview":
            foundCapital(&state, player: viewer)
            made = try repreview(&state)
        case "tribal-villages":
            foundCapital(&state, player: viewer)
            made = try tribalVillages(&state)
        case "veterans":
            foundCapital(&state, player: viewer)
            made = try veterans(&state)
        case "resources":
            foundCapital(&state, player: viewer)
            made = try resources(&state)
        case "roads":
            foundCapital(&state, player: viewer)
            made = try roads(&state)
        case "naval":
            foundCapital(&state, player: viewer)
            made = try naval(&state)
        case "quarters":
            foundCapital(&state, player: viewer)
            made = try quarters(&state)
        case "loyalty":
            foundCapital(&state, player: viewer)
            made = try loyalty(&state)
        case "stability":
            foundCapital(&state, player: viewer)
            made = try stability(&state)
        case "upkeep":
            foundCapital(&state, player: viewer)
            made = try upkeep(&state)
        case "governance":
            foundCapital(&state, player: viewer)
            made = try governance(&state)
        case "world":
            foundCapital(&state, player: viewer)
            made = try world(&state)
        default:
            throw Failure(description: "no scenario “\(name)” (try \(names.joined(separator: ", ")))")
        }
        let problems = made.state.checkInvariants()
        if !problems.isEmpty { DebugLog.write("Scenario \(name): invariants failed: \(problems.joined(separator: "; "))") }
        return made
    }

    // MARK: Pieces

    /// The viewer founds its capital with its first Settler, where it stands.
    static func foundCapital(_ state: inout GameState, player: PlayerID) {
        guard let settler = state.units(of: player).first(where: { state.rules.unit($0.type).foundsCity }) else { return }
        _ = try? GameEngine.apply(.foundCity(unit: settler.id), by: player, to: &state)
    }

    /// Every player (the viewer too) plays scripted stand-in phases until the viewer's phase of
    /// `turn` (or the end of the game).
    static func play(_ state: inout GameState, untilTurn turn: Int) {
        var guardPhases = 0
        while state.outcome == nil, !(state.turn >= turn && state.currentPlayer == PlayerID(0)), guardPhases < 10_000 {
            _ = StandInAI.playTurn(&state, player: state.currentPlayer, random: false)
            guardPhases += 1
        }
    }

    /// Every player founds up to `perPlayer` cities, one per phase: the capital where its Settler
    /// starts, then the nearest free site to its capital, ring by ring.
    static func manyCities(_ state: inout GameState, perPlayer: Int) {
        let players = state.players.count
        for round in 0..<perPlayer {
            for _ in 0..<players {
                guard state.outcome == nil else { return }
                let player = state.currentPlayer
                if round == 0 {
                    foundCapital(&state, player: player)
                } else {
                    foundNear(&state, player: player)
                }
                _ = try? GameEngine.apply(.endTurn, by: player, to: &state)
            }
        }
    }

    /// A city at the nearest site to the player's first city where the rules allow one.
    private static func foundNear(_ state: inout GameState, player: PlayerID) {
        guard let centre = state.cities(of: player).first?.position else { return }
        let map = state.map, rules = state.rules
        let minimum = rules.constants.city.minDistance
        for radius in minimum...14 {
            let ring = map.coords(within: radius, of: centre).filter { map.distance($0, centre) == radius }
            for site in ring {
                guard let t = map.index(of: site) else { continue }
                let tile = map.tiles[t]
                guard rules.isPassable(tile), rules.feature(tile.feature).allowsCity,
                      state.tileOwner(t).map({ $0 == player }) ?? true,
                      !state.cities.contains(where: { map.distance($0.position, site) < minimum }),
                      state.canEnd(.settler, owner: player, at: site) else { continue }
                let settler = state.addUnit(.settler, owner: player, at: site)
                if (try? GameEngine.apply(.foundCity(unit: settler), by: player, to: &state)) != nil { return }
                _ = try? GameEngine.apply(.disband(unit: settler), by: player, to: &state)
            }
        }
    }

    /// The viewer's capital (or first unit's tile) and the enemy (player 1).
    private static func home(_ state: GameState) throws -> HexCoord {
        let viewer = PlayerID(0)
        if let capital = state.players[0].capital.flatMap(state.city) { return capital.position }
        if let unit = state.units(of: viewer).first { return unit.position }
        throw Failure(description: "the viewer has nothing on the map")
    }

    /// Free land tiles at a distance from a centre where a unit of `owner` may stand, nearest
    /// the `toward` hex first.
    private static func spots(_ state: GameState, around centre: HexCoord, distance: ClosedRange<Int>, for type: UnitType,
                              owner: PlayerID, toward: HexCoord?) -> [HexCoord] {
        let map = state.map
        return map.coords(within: distance.upperBound, of: centre)
            .filter { distance.contains(map.distance($0, centre)) && state.canEnd(type, owner: owner, at: $0) && state.city(at: $0) == nil }
            .sorted { a, b in
                guard let toward else { return false }
                return map.distance(a, toward) < map.distance(b, toward)
            }
    }

    private static func declareWar(_ state: inout GameState) throws {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        guard !state.isAtWar(viewer, enemy) else { return }
        do {
            try GameEngine.apply(.declareWar(on: enemy), by: viewer, to: &state)
        } catch {
            throw Failure(description: "could not declare war: \(error)")
        }
    }

    /// An enemy force two to three tiles from the viewer's capital, an own line facing it.
    static func warFront(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        let centre = try home(state)
        let enemyHome = state.players[1].capital.flatMap(state.city)?.position
        // The enemy: three units on the side of the capital facing their homeland.
        var placedEnemy: [HexCoord] = []
        for type in [UnitType.warrior, .spearman, .archer] {
            guard let spot = spots(state, around: centre, distance: 3...3, for: type, owner: enemy, toward: enemyHome)
                .first(where: { s in placedEnemy.allSatisfy { state.map.distance($0, s) <= 2 } }) else { continue }
            state.addUnit(type, owner: enemy, at: spot)
            placedEnemy.append(spot)
        }
        guard let front = placedEnemy.first else { throw Failure(description: "no room for an enemy force") }
        // Our line between them and the capital.
        var archer: UnitID?
        for type in [UnitType.archer, .warrior, .spearman] {
            guard let spot = spots(state, around: centre, distance: 1...2, for: type, owner: viewer, toward: front).first else { continue }
            let id = state.addUnit(type, owner: viewer, at: spot)
            if type == .archer { archer = id }
        }
        try declareWar(&state)
        return Made(state: state, focus: archer.map { .unit($0) } ?? .hex(front))
    }

    /// A viewer army around the enemy capital, two Archers having already struck it.
    static func siege(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        guard let city = state.players[enemy.rawValue].capital.flatMap(state.city) ?? state.cities(of: enemy).first else {
            throw Failure(description: "the enemy has no city")
        }
        let target = city.position
        let home = try? home(state)
        var warrior: UnitID?
        for type in [UnitType.warrior, .spearman] {
            guard let spot = spots(state, around: target, distance: 1...1, for: type, owner: viewer, toward: home).first else { continue }
            let id = state.addUnit(type, owner: viewer, at: spot)
            if type == .warrior { warrior = id }
        }
        var archers: [UnitID] = []
        for _ in 0..<2 {
            guard let spot = spots(state, around: target, distance: 2...2, for: .archer, owner: viewer, toward: home).first else { continue }
            archers.append(state.addUnit(.archer, owner: viewer, at: spot))
        }
        try declareWar(&state)
        for archer in archers {
            _ = try? GameEngine.apply(.attack(unit: archer, target: target), by: viewer, to: &state)
        }
        return Made(state: state, focus: warrior.map { .unit($0) } ?? .city(city.id))
    }
}

extension Scenarios {
    /// A site for a new city of `player` near its capital (at least `minimum` tiles away): the
    /// nearest where the rules allow one, ring by ring.
    static func citySite(_ state: GameState, player: PlayerID, minimumDistance: Int) -> HexCoord? {
        guard let centre = state.players[player.rawValue].capital.flatMap(state.city)?.position else { return nil }
        let map = state.map, rules = state.rules
        let minimum = max(minimumDistance, rules.constants.city.minDistance)
        for radius in minimum...14 {
            for site in map.coords(within: radius, of: centre) where map.distance(site, centre) == radius {
                guard let t = map.index(of: site) else { continue }
                let tile = map.tiles[t]
                guard rules.isPassable(tile), rules.feature(tile.feature).allowsCity, state.tileOwner(t).map({ $0 == player }) ?? true,
                      !state.cities.contains(where: { map.distance($0.position, site) < rules.constants.city.minDistance }),
                      state.canEnd(.settler, owner: player, at: site), state.units.allSatisfy({ $0.position != site }) else { continue }
                return site
            }
        }
        return nil
    }

    /// Founds a viewer city at the nearest free site (in the viewer's phase).
    static func foundViewerCity(_ state: inout GameState) throws -> CityID {
        let viewer = PlayerID(0)
        guard let site = citySite(state, player: viewer, minimumDistance: 4) else { throw Failure(description: "no site for a new city") }
        let settler = state.addUnit(.settler, owner: viewer, at: site)
        let events = try GameEngine.apply(.foundCity(unit: settler), by: viewer, to: &state)
        guard let id = GameSession.foundedCity(in: events, by: viewer) else { throw Failure(description: "the city was not founded") }
        return id
    }

    /// Most attention items at once (see `attention` above).
    static func attention(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        guard let capital = state.players[0].capital.flatMap(state.city) else { throw Failure(description: "the viewer has no capital") }
        // The capital: nothing to build.
        try GameEngine.apply(.setQueue(city: capital.id, items: []), by: viewer, to: &state)
        // A new city of population 1 with a Settler first in its queue.
        let waiting = try foundViewerCity(&state)
        try GameEngine.apply(.setQueue(city: waiting, items: [.unit(.settler), .unit(.warrior)]), by: viewer, to: &state)
        // Another, every tile it owns taken by a sleeping Warrior: its Warrior has no room.
        let blocked = try foundViewerCity(&state)
        try GameEngine.apply(.setQueue(city: blocked, items: [.unit(.warrior)]), by: viewer, to: &state)
        var sleepers: [UnitID] = []
        if let city = state.city(blocked) {
            for hex in state.map.coords(within: state.rules.constants.production.spawnRadius, of: city.position) {
                guard let t = state.map.index(of: hex), state.tileOwner(t) == viewer, state.canEnd(.warrior, owner: viewer, at: hex) else { continue }
                sleepers.append(state.addUnit(.warrior, owner: viewer, at: hex))
            }
        }
        // More units than an empty treasury pays for.
        state.players[0].gold = 0
        var forecast = state.view(for: viewer).upkeepForecast()
        var extra = 0
        while forecast.disbanded == 0, extra < 12 {
            guard let spot = spots(state, around: capital.position, distance: 2...4, for: .warrior, owner: viewer, toward: nil).first else { break }
            sleepers.append(state.addUnit(.warrior, owner: viewer, at: spot))
            extra += 1
            forecast = state.view(for: viewer).upkeepForecast()
        }
        for unit in sleepers { _ = try? GameEngine.apply(.sleep(unit: unit), by: viewer, to: &state) }
        // An enemy Warrior beside the capital, at war.
        let enemyHome = state.players[1].capital.flatMap(state.city)?.position
        guard let spot = spots(state, around: capital.position, distance: 1...1, for: .warrior, owner: enemy, toward: enemyHome).first else {
            throw Failure(description: "no room beside the capital")
        }
        state.addUnit(.warrior, owner: enemy, at: spot)
        try declareWar(&state)
        return Made(state: state, focus: .hex(capital.position))
    }

    /// The latest turn `capture` plays to for player 1's second city.
    static let captureLatestTurn = 70

    /// Plays on, five turns at a time up to `captureLatestTurn`, until player 1 has a city
    /// besides its original capital (on some seeds its second city comes after turn 40).
    static func playUntilASecondCity(_ state: inout GameState) {
        let enemy = PlayerID(1)
        while state.outcome == nil, state.turn < captureLatestTurn,
              !state.cities(of: enemy).contains(where: { $0.id != state.players[enemy.rawValue].originalCapital }) {
            play(&state, untilTurn: min(state.turn + 5, captureLatestTurn))
        }
    }

    /// One of player 1's cities at 0 HP and an own Warrior beside it (see `capture` above).
    static func capture(_ state: inout GameState, capital: Bool) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        let original = state.players[enemy.rawValue].originalCapital
        let candidates = state.cities(of: enemy).filter { capital ? $0.id == original : $0.id != original }
        guard let target = candidates.first else {
            throw Failure(description: capital ? "player 1 has no original capital"
                : "player 1 has no city besides its capital by turn \(state.turn) (try another -seed: the default 7 works)")
        }
        let home = try? home(state)
        guard let spot = spots(state, around: target.position, distance: 1...1, for: .warrior, owner: viewer, toward: home).first else {
            throw Failure(description: "no room beside \(target.name)")
        }
        let warrior = state.addUnit(.warrior, owner: viewer, at: spot)
        try declareWar(&state)
        // Volleys from two tiles away until the walls and the city are down.
        for _ in 0..<60 {
            guard let city = state.city(target.id), city.hp > 0 else { break }
            guard let from = spots(state, around: target.position, distance: 2...2, for: .archer, owner: viewer, toward: home).first else { break }
            let archer = state.addUnit(.archer, owner: viewer, at: from)
            _ = try? GameEngine.apply(.attack(unit: archer, target: target.position), by: viewer, to: &state)
            _ = try? GameEngine.apply(.disband(unit: archer), by: viewer, to: &state)
        }
        guard state.city(target.id)?.hp == 0 else { throw Failure(description: "\(target.name) still stands") }
        return Made(state: state, focus: .unit(warrior))
    }

    /// At war since turn 24, player 1 proposes peace in its phase of turn 30; the viewer's phase
    /// of turn 31 follows.
    static func peaceOffer(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        guard state.isAtWar(viewer, enemy) else { throw Failure(description: "not at war with player 1") }
        try GameEngine.apply(.endTurn, by: viewer, to: &state)
        while state.currentPlayer != enemy, state.outcome == nil {
            _ = StandInAI.playTurn(&state, player: state.currentPlayer, random: false)
        }
        do {
            try GameEngine.apply(.proposePeace(to: viewer), by: enemy, to: &state)
        } catch {
            throw Failure(description: "player 1 could not propose peace: \(error)")
        }
        play(&state, untilTurn: state.turn + 1)
        return Made(state: state, focus: state.players[0].capital.map { .city($0) })
    }

    /// Player 1 met, at peace: one of its Warriors in sight of the viewer's capital, on the first
    /// unowned tile 2 to 4 tiles out that the viewer sees (an own Warrior on the border facing
    /// player 1's home looks further when there is none); a second out of sight beside another
    /// such tile, for the troops-near notice (see `rivals` above).
    static func rivals(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        let centre = try home(state)
        let enemyHome = state.players[1].capital.flatMap(state.city)?.position
        func unownedInSight(_ state: GameState) -> [HexCoord] {
            spots(state, around: centre, distance: 2...4, for: .warrior, owner: enemy, toward: enemyHome).filter { hex in
                let t = state.map.index(of: hex)!
                return state.tileOwner(t) == nil && state.players[0].visible[t]
            }
        }
        var inSight = unownedInSight(state)
        if inSight.isEmpty, let post = spots(state, around: centre, distance: 1...4, for: .warrior, owner: viewer, toward: enemyHome)
            .first(where: { state.tileOwner(state.map.index(of: $0)!) == viewer }) {
            state.addUnit(.warrior, owner: viewer, at: post)
            inSight = unownedInSight(state)
        }
        guard let spot = inSight.first else { throw Failure(description: "no room for a rival in sight") }
        let first = state.addUnit(.warrior, owner: enemy, at: spot)
        guard !state.view(for: viewer).visibleForeignUnits.isEmpty else { throw Failure(description: "no foreign unit in sight") }
        guard state.hasMet(viewer, enemy) else { throw Failure(description: "player 1 not met") }
        var note = "rivals: Warrior \(first.rawValue) of player 1 in sight at \(spot.q) \(spot.r)"
        // The second: out of sight, one step from a tile in sight within 4 tiles of the capital.
        search: for target in inSight.dropFirst() {
            for start in spots(state, around: target, distance: 1...1, for: .warrior, owner: enemy, toward: enemyHome) {
                let t = state.map.index(of: start)!
                guard !state.players[0].visible[t], state.tileOwner(t) != viewer else { continue }
                let second = state.addUnit(.warrior, owner: enemy, at: start)
                let city = state.players[0].capital.flatMap(state.city)?.name ?? "the capital"
                note += "; Warrior \(second.rawValue) out of sight at \(start.q) \(start.r): `aicommand 1 move \(second.rawValue) "
                    + "\(target.q) \(target.r)` and `endturn` bring it within 4 tiles of \(city) (troops-near notice)"
                break search
            }
        }
        return Made(state: state, focus: .hex(spot), note: note)
    }

    /// The tap-routing pieces (see `taps` above): an own Warrior two tiles from the capital, and
    /// beside it an own Settler and player 1's Settler and Builder, each alone on its tile; met
    /// through them, then at war.
    static func taps(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        let centre = try home(state)
        let enemyHome = state.players[1].capital.flatMap(state.city)?.position ?? state.units(of: enemy).first?.position
        guard let post = spots(state, around: centre, distance: 2...2, for: .warrior, owner: viewer, toward: enemyHome).first else {
            throw Failure(description: "no room for a Warrior near the capital")
        }
        let warrior = state.addUnit(.warrior, owner: viewer, at: post)
        var taken: [HexCoord] = []
        for (type, owner) in [(UnitType.settler, viewer), (.settler, enemy), (.builder, enemy)] {
            guard let spot = spots(state, around: post, distance: 1...1, for: type, owner: owner, toward: nil)
                .first(where: { s in !taken.contains(s) && state.units(at: s).isEmpty }) else {
                throw Failure(description: "no room beside the Warrior")
            }
            taken.append(spot)
            state.addUnit(type, owner: owner, at: spot)
        }
        guard state.hasMet(viewer, enemy) else { throw Failure(description: "player 1 not met") }
        try declareWar(&state)
        return Made(state: state, focus: .unit(warrior))
    }
}

extension Scenarios {
    /// Player 1 researches the tech of the building with walls from turn 1 and buys that building
    /// in its capital once it knows it; then, at war, an own Archer two tiles from the city (see
    /// `walls` above).
    static func walls(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        guard let walls = state.rules.buildings.first(where: { $0.wallHP > 0 }) else { throw Failure(description: "no walls in the rules") }
        var phases = 0
        while state.outcome == nil, phases < 600 {
            let player = state.players[enemy.rawValue]
            if let tech = walls.tech, !player.knows(tech) {
                if state.currentPlayer == enemy, player.researching != tech, player.researchTarget != tech {
                    _ = try? GameEngine.apply(.setResearch(tech: tech), by: enemy, to: &state)
                }
            } else if state.currentPlayer == enemy, player.capital != nil {
                break
            }
            _ = StandInAI.playTurn(&state, player: state.currentPlayer, random: false)
            phases += 1
        }
        guard state.currentPlayer == enemy, let city = state.players[enemy.rawValue].capital.flatMap(state.city) else {
            throw Failure(description: "player 1 never learnt \(walls.tech?.rawValue ?? "the walls' tech") with a capital")
        }
        let item = ProductionItem.building(walls.id)
        state.players[enemy.rawValue].gold += state.purchasePrice(of: item, for: enemy)
        do {
            try GameEngine.apply(.purchase(city: city.id, item: item), by: enemy, to: &state)
        } catch {
            throw Failure(description: "player 1 could not buy \(walls.name): \(error)")
        }
        play(&state, untilTurn: state.turn)
        guard let walled = state.city(city.id), walled.wallHP == walls.wallHP else { throw Failure(description: "\(city.name) has no walls") }
        let home = try? home(state)
        guard let spot = spots(state, around: walled.position, distance: 2...2, for: .archer, owner: viewer, toward: home).first else {
            throw Failure(description: "no room for an Archer near \(walled.name)")
        }
        let archer = state.addUnit(.archer, owner: viewer, at: spot)
        try declareWar(&state)
        let note = "walls: \(walled.name) at \(walled.position.q) \(walled.position.r) has \(walls.name) (\(walled.wallHP)); "
            + "Archer \(archer.rawValue) selected: tap the city for the combat card"
        return Made(state: state, focus: .unit(archer), note: note)
    }

    /// At war, an own Warrior two tiles from an enemy Warrior, an enemy Spearman beside that one
    /// three tiles from the own Warrior, out of sight: the first configuration, nearest player
    /// 1's home, where the attack must move first and that move changes the odds (see
    /// `repreview` above; as MoveThenAttackPreviewTests).
    static func repreview(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        let centre = try home(state)
        let enemyHome = state.players[1].capital.flatMap(state.city)?.position ?? state.units(of: enemy).first?.position
        var tries = 0
        for post in spots(state, around: centre, distance: 5...9, for: .warrior, owner: viewer, toward: enemyHome) {
            for target in spots(state, around: post, distance: 2...2, for: .warrior, owner: enemy, toward: enemyHome) {
                for support in spots(state, around: target, distance: 1...1, for: .spearman, owner: enemy, toward: enemyHome)
                where state.map.distance(support, post) == 3 {
                    tries += 1
                    guard tries <= 400 else { throw Failure(description: "no place where the move changes the odds") }
                    var trial = state
                    trial.addUnit(.warrior, owner: enemy, at: target)
                    trial.addUnit(.spearman, owner: enemy, at: support)
                    let warrior = trial.addUnit(.warrior, owner: viewer, at: post)
                    guard trial.hasMet(viewer, enemy), (try? declareWar(&trial)) != nil else { continue }
                    let view = trial.view(for: viewer)
                    guard !view.isVisible(support), view.isVisible(target),
                          let option = view.attackOptions(for: warrior).first(where: { $0.target == target }), option.moveCost > 0,
                          let before = view.combatPreview(attacker: .unit(warrior), target: target, from: option.from) else { continue }
                    var moved = trial
                    guard (try? GameEngine.apply(.moveUnit(unit: warrior, to: option.from), by: viewer, to: &moved)) != nil,
                          moved.unit(warrior)?.position == option.from else { continue }
                    let after = moved.view(for: viewer)
                    guard let fresh = after.attackOptions(for: warrior).first(where: { $0.target == target }),
                          let now = after.combatPreview(attacker: .unit(warrior), target: target, from: fresh.from),
                          !now.sameInputs(as: before) else { continue }
                    state = trial
                    let note = "repreview: Warrior \(warrior.rawValue) selected; tap the enemy Warrior at \(target.q) \(target.r) "
                        + "twice: the move to \(option.from.q) \(option.from.r) reveals a Spearman at \(support.q) \(support.r) "
                        + "and the card shows the new odds (a third tap attacks)"
                    return Made(state: state, focus: .unit(warrior), note: note)
                }
            }
        }
        throw Failure(description: "no place where the move changes the odds")
    }
}

extension Scenarios {
    /// An own Warrior three tiles from the enemy capital, beside two wounded enemy Warriors two
    /// and three tiles from the city, at war (see `melee` above). An enemy Archer wounds it in the
    /// enemy's phase first, so its expected HP after a win is below the bombard's blow.
    static func melee(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        guard let city = state.players[enemy.rawValue].capital.flatMap(state.city) ?? state.cities(of: enemy).first else {
            throw Failure(description: "the enemy has no city")
        }
        let map = state.map, centre = city.position
        let home = try? home(state)
        // A post three tiles out with free tiles beside it two and three tiles from the city.
        var picked: (post: HexCoord, near: HexCoord, far: HexCoord)?
        for post in spots(state, around: centre, distance: 3...3, for: .warrior, owner: viewer, toward: home) {
            let beside = spots(state, around: post, distance: 1...1, for: .warrior, owner: enemy, toward: nil)
            guard let near = beside.first(where: { map.distance($0, centre) == 2 }),
                  let far = beside.first(where: { map.distance($0, centre) == 3 }) else { continue }
            picked = (post, near, far)
            break
        }
        guard let (post, near, far) = picked else { throw Failure(description: "no room beside \(city.name)") }
        let warrior = state.addUnit(.warrior, owner: viewer, at: post)
        // A Scout keeps the city in sight.
        if let spot = spots(state, around: centre, distance: 2...2, for: .scout, owner: viewer, toward: post)
            .first(where: { map.distance($0, near) > 1 && map.distance($0, far) > 1 }) {
            state.addUnit(.scout, owner: viewer, at: spot)
        }
        DebugTools.refreshAllKnowledge(in: &state)
        try declareWar(&state)
        // The enemy's phase: an Archer of theirs wounds the Warrior, then leaves.
        try GameEngine.apply(.endTurn, by: viewer, to: &state)
        if state.currentPlayer == enemy,
           let spot = spots(state, around: post, distance: 2...2, for: .archer, owner: enemy, toward: centre).first {
            let archer = state.addUnit(.archer, owner: enemy, at: spot)
            _ = try? GameEngine.apply(.attack(unit: archer, target: post), by: enemy, to: &state)
            _ = try? GameEngine.apply(.disband(unit: archer), by: enemy, to: &state)
        }
        while state.outcome == nil, state.currentPlayer != viewer {
            try GameEngine.apply(.endTurn, by: state.currentPlayer, to: &state)
        }
        // The viewer's phase: an enemy Warrior on each tile, each hit by two volleys of own
        // Archers, which then leave.
        for spot in [near, far] {
            let target = state.addUnit(.warrior, owner: enemy, at: spot)
            for _ in 0..<2 {
                guard state.unit(target) != nil,
                      let from = spots(state, around: spot, distance: 2...2, for: .archer, owner: viewer, toward: home).first else { break }
                let archer = state.addUnit(.archer, owner: viewer, at: from)
                _ = try? GameEngine.apply(.attack(unit: archer, target: spot), by: viewer, to: &state)
                _ = try? GameEngine.apply(.disband(unit: archer), by: viewer, to: &state)
            }
        }
        guard state.unit(warrior) != nil else { throw Failure(description: "the Warrior fell") }
        let note = "melee: Warrior \(warrior.rawValue) selected at \(post.q) \(post.r), 3 tiles from \(city.name); "
            + "tap \(near.q) \(near.r) (2 tiles from it): the card warns of its bombard; tap \(far.q) \(far.r) (3 tiles): no warning"
        return Made(state: state, focus: .unit(warrior), note: note)
    }
}

extension Scenarios {
    /// Four tribal villages placed by hand around the viewer's start on turn 1 (see
    /// `tribal-villages` above), and a Scout of player 1 for the rival's take.
    /// M2 §8.2, §8.3: next to the viewer's capital, a Warrior with a promotion due that can
    /// upgrade now (its upgrade tech known, gold in hand), and an Archer with a promotion due
    /// whose upgrade tech is not known yet (Upgrade dimmed).
    static func veterans(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0)
        let centre = try home(state)
        guard let target = state.rules.unit(.warrior).upgradesTo, let tech = state.rules.unit(target).tech else {
            throw Failure(description: "the Warrior has no upgrade in the rules")
        }
        let tier = state.rules.promotionXP.first ?? 15
        let places = spots(state, around: centre, distance: 1...1, for: .warrior, owner: viewer, toward: nil)
        guard places.count >= 2 else { throw Failure(description: "no room beside the capital") }
        DebugTools.learnTech(tech, player: viewer, in: &state)
        state.players[viewer.rawValue].gold = max(state.players[viewer.rawValue].gold, 300)
        let warrior = state.addUnit(.warrior, owner: viewer, at: places[0])
        let archer = state.addUnit(.archer, owner: viewer, at: places[1])
        DebugTools.setExperience(tier, of: warrior, in: &state)
        DebugTools.setExperience(tier, of: archer, in: &state)
        return Made(state: state, focus: .unit(warrior),
                    note: "Warrior: Upgrade (lit) and Promote; Archer: Upgrade dimmed, Promote; Next lists Promotion Due")
    }

    /// M2 §3.1, §4.1: around the viewer's capital, resources placed by hand on its own land
    /// with their reveal and improvement techs learnt: Stone under a built Quarry, Wine under a
    /// built Plantation, Iron and Horses unimproved, and Deer with a Builder on it, selected (its
    /// card offers a Camp).
    static func resources(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0)
        let centre = try home(state)
        for tech in ["mining", "animalHusbandry", "bronzeWorking", "masonry", "irrigation", "sailing", "construction"] {
            DebugTools.learnTech(TechID(tech), player: viewer, in: &state)
        }
        let places = spots(state, around: centre, distance: 1...1, for: .builder, owner: viewer, toward: nil)
            .filter { state.map.index(of: $0).flatMap(state.tileOwner) == viewer }
        guard places.count >= 5 else { throw Failure(description: "fewer than five own tiles beside the capital") }
        func put(_ resource: Resource, at hex: HexCoord, terrain: Terrain) {
            state.map[hex] = Tile(terrain: terrain, riverEdges: state.map[hex].riverEdges, resource: resource)
        }
        put(.stone, at: places[0], terrain: .grassland)
        put(.wine, at: places[1], terrain: .plains)
        put(.iron, at: places[2], terrain: .plains)
        put(.horses, at: places[3], terrain: .grassland)
        put(.deer, at: places[4], terrain: .tundra)
        for (hex, improvement) in [(places[0], Improvement.quarry), (places[1], .plantation)] {
            let builder = state.addUnit(.builder, owner: viewer, at: hex)
            do {
                try GameEngine.apply(.buildImprovement(unit: builder, improvement: improvement), by: viewer, to: &state)
            } catch {
                throw Failure(description: "could not build \(improvement): \(error)")
            }
            _ = try? GameEngine.apply(.disband(unit: builder), by: viewer, to: &state)
        }
        let builder = state.addUnit(.builder, owner: viewer, at: places[4])
        DebugTools.refreshAllKnowledge(in: &state)
        func text(_ hex: HexCoord) -> String { "\(hex.q) \(hex.r)" }
        return Made(state: state, focus: .unit(builder),
                    note: "Quarry on Stone at \(text(places[0])), Plantation on Wine at \(text(places[1])), Iron at \(text(places[2])), "
                        + "Horses at \(text(places[3])); the Builder on Deer at \(text(places[4])) offers a Camp")
    }

    /// M2 §3.2, §8.4: Sailing and Shipbuilding learnt, a Galley and a Quadrireme on the water
    /// nearest the capital and a Warrior embarked beside them; the Galley selected.
    static func naval(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0)
        for tech: TechID in ["sailing", "shipbuilding"] { DebugTools.learnTech(tech, player: viewer, in: &state) }
        let centre = try home(state)
        let water = state.map.tiles.indices
            .filter { state.map.tiles[$0].terrain == .coast && state.units(at: state.map.coord(at: $0)).isEmpty }
            .map { state.map.coord(at: $0) }
            .sorted { state.map.distance($0, centre) < state.map.distance($1, centre) }
        guard water.count >= 3 else { throw Failure(description: "no coast near the capital") }
        let galley = state.addUnit(.galley, owner: viewer, at: water[0])
        state.addUnit(.quadrireme, owner: viewer, at: water[1])
        state.addUnit(.warrior, owner: viewer, at: water[2])
        DebugTools.refreshAllKnowledge(in: &state)
        let view = state.view(for: viewer)
        let coastal = state.cities.first.map(view.isCoastal) ?? false
        return Made(state: state, focus: .unit(galley),
                    note: "Galley at \(water[0].q) \(water[0].r), Quadrireme at \(water[1].q) \(water[1].r), embarked Warrior at \(water[2].q) \(water[2].r); capital coastal: \(coastal)")
    }

    /// M2 §5.3, §18.2: the capital at population 9 (four quarters) knowing Writing, Currency,
    /// Bronze Working, Engineering and Apprenticeship, with a Campus and a Market on their best
    /// tiles and an Aqueduct where it may stand, so a Workshop or Barracks has a few legal sites
    /// left; the capital selected.
    /// A forward city beside a large rival capital, losing Loyalty fast, and a viewer city that
    /// revolted into a Free City (M2 §5.5, §12.5).
    static func loyalty(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), rival = PlayerID(1)
        guard state.freeCities != nil else { throw Failure(description: "no Free Cities in these rules") }
        play(&state, untilTurn: 3)
        guard let rivalCapital = state.players[rival.rawValue].capital else { throw Failure(description: "the rival has no capital") }
        DebugTools.setCity(rivalCapital, population: 12, in: &state)
        guard let site = citySite(state, player: rival, minimumDistance: 4) else { throw Failure(description: "no forward site") }
        let settler = state.addUnit(.settler, owner: viewer, at: site)
        let events = try GameEngine.apply(.foundCity(unit: settler), by: viewer, to: &state)
        guard let forward = GameSession.foundedCity(in: events, by: viewer) else { throw Failure(description: "no forward city") }
        DebugTools.setLoyalty(forward, 12, in: &state)
        let rebel = try foundViewerCity(&state)
        guard DebugTools.revolt(rebel, in: &state) else { throw Failure(description: "the city did not revolt") }
        // Scouts in sight of the Free City and of the rival capital.
        for (city, toward) in [(rebel, state.city(forward)?.position), (rivalCapital, state.city(forward)?.position)] {
            guard let centre = state.city(city)?.position,
                  let spot = spots(state, around: centre, distance: 1...2, for: .scout, owner: viewer, toward: toward).first else { continue }
            state.addUnit(.scout, owner: viewer, at: spot)
        }
        return Made(state: state, focus: .city(forward),
                    note: "Open the forward city's panel and tap the Loyalty row; the grey city is the Free City.")
    }

    static func quarters(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0)
        guard let capital = state.cities.first(where: { $0.owner == viewer }) else { throw Failure(description: "no capital") }
        for tech in ["writing", "currency", "bronzeWorking", "engineering", "apprenticeship", "mining"] {
            DebugTools.learnTech(TechID(tech), player: viewer, in: &state)
        }
        DebugTools.setCity(capital.id, population: 9, in: &state)
        var built: [String] = []
        for kind: QuarterKind in ["campus", "market", "aqueduct"] {
            if let site = state.view(for: viewer).quarterOptions(for: capital.id).first(where: { $0.kind == kind })?.sites.first,
               DebugTools.addQuarter(kind, at: site.tile, to: capital.id, in: &state) {
                built.append(kind.rawValue)
            }
        }
        guard !built.isEmpty else { throw Failure(description: "no quarter fits around the capital") }
        DebugTools.refreshAllKnowledge(in: &state)
        let open = state.view(for: viewer).quarterOptions(for: capital.id).filter { $0.problem == nil }
            .map { "\($0.kind.rawValue) \($0.sites.count)" }
        return Made(state: state, focus: .city(capital.id),
                    note: "built \(built.joined(separator: ", ")); sites: \(open.joined(separator: ", "))")
    }

    /// M2 §7.1–7.3, §4.3: the civics up to Political Philosophy learnt (the last this turn, so
    /// changes are free), Oligarchy adopted with a policy in its slots, the next civic being
    /// studied, and Influence part way to an envoy token; 200 Gold. The government panel open.
    static func governance(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0)
        guard let capital = state.cities.first(where: { $0.owner == viewer }) else { throw Failure(description: "no capital") }
        for civic in ["codeOfLaws", "craftsmanship", "foreignTrade", "earlyEmpire", "stateWorkforce", "politicalPhilosophy"] {
            DebugTools.learnCivic(CivicID(civic), player: viewer, in: &state)
        }
        state.players[viewer.rawValue].gold = 200
        DebugTools.setInfluence(14, tokens: 1, player: viewer, in: &state)
        try GameEngine.apply(.setGovernment(government: "oligarchy"), by: viewer, to: &state)
        let open = state.view(for: viewer).availablePolicies
        let picks = [PolicyKind.military, .economic].compactMap { kind in open.first { $0.kind == kind }?.id }
        try GameEngine.apply(.setPolicies(policies: picks), by: viewer, to: &state)
        if let next = state.view(for: viewer).civicOptions().first(where: \.available) {
            try GameEngine.apply(.setCivic(civic: next.civic), by: viewer, to: &state)
        }
        DebugTools.refreshAllKnowledge(in: &state)
        let view = state.view(for: viewer)
        return Made(state: state, focus: .city(capital.id),
                    note: "government \(view.government?.name ?? "none"), policies \(view.policies.map(\.name).joined(separator: ", ")); "
                        + "studying \(view.me.studying?.rawValue ?? "nothing"); free change \(view.isFreeChangeTurn); "
                        + "influence \(view.me.influence ?? 0)/\(view.envoyThreshold) (+\(view.influenceIncome)) (use panel government|civics)")
    }

    /// M2 §11–§13: the viewer has met the nearest minor faction (envoys sent, one token left),
    /// has a Market (trade capacity 2), one Trader on a route to the minor and one at home, and
    /// a raider camp in sight 2 tiles from the capital.
    static func world(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0)
        guard let capital = state.cities.first(where: { $0.owner == viewer }) else { throw Failure(description: "no capital") }
        let map = state.map
        guard let minor = (state.minors ?? []).min(by: { a, b in
            let da = state.cities(of: a.player).first.map { map.distance(capital.position, $0.position) } ?? .max
            let db = state.cities(of: b.player).first.map { map.distance(capital.position, $0.position) } ?? .max
            return da < db
        }), let minorCity = state.cities(of: minor.player).first else { throw Failure(description: "no minor faction") }
        DebugTools.explore(radius: map.distance(capital.position, minorCity.position) + 3, of: capital.position, player: viewer, in: &state)
        DebugTools.revealCity(minorCity.id, to: viewer, in: &state)
        DebugTools.meet(viewer, minor.player, in: &state)
        DebugTools.learnTech(TechID("currency"), player: viewer, in: &state)
        DebugTools.setCity(capital.id, population: 4, adding: [BuildingID("market")], in: &state)
        state.players[viewer.rawValue].gold = 150
        DebugTools.setInfluence(0, tokens: 2, player: viewer, in: &state)
        try GameEngine.apply(.sendEnvoy(to: minor.player), by: viewer, to: &state)
        let first = state.addUnit(.trader, owner: viewer, at: capital.position)
        let home = map.neighbors(of: capital.position).first { hex in
            guard let t = map.index(of: hex) else { return false }
            return state.rules.isPassable(map.tiles[t]) && !map.tiles[t].terrain.isWater && state.units(at: hex).isEmpty
        } ?? capital.position
        let second = state.addUnit(.trader, owner: viewer, at: home)
        var routed = "no route"
        if let unit = state.unit(first) {
            if let problem = state.tradeRouteProblem(unit, to: minorCity.id) {
                routed = "route refused: \(problem)"
            } else {
                try GameEngine.apply(.startTradeRoute(unit: first, toCity: minorCity.id), by: viewer, to: &state)
                routed = "route to \(minorCity.name)"
            }
        }
        let ring = map.coords(within: 2, of: capital.position).filter { hex in
            guard map.distance(capital.position, hex) == 2, let t = map.index(of: hex) else { return false }
            let tile = map.tiles[t]
            return !tile.terrain.isWater && state.rules.isPassable(tile) && state.units(at: hex).isEmpty
                && state.cities.allSatisfy { $0.position != hex }
        }
        if let camp = ring.first { DebugTools.addRaiderCamp(at: camp, in: &state) }
        DebugTools.refreshAllKnowledge(in: &state)
        let view = state.view(for: viewer)
        return Made(state: state, focus: .unit(second),
                    note: "minor \(minorCity.name) (player \(minor.player.rawValue), city \(minorCity.id.rawValue)); \(routed); "
                        + "routes \(view.myTradeRoutes.count)/\(view.tradeCapacity); camps \(view.knownRaiderCamps.count) (use panel minors, trade)")
    }

    /// M2 §5.3, §5.4, §7.4: the capital with a Campus and its Library (a specialist slot) and a
    /// Granary, on the Science focus so a citizen takes the slot; 60 Gold, so it can buy a tile.
    static func upkeep(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0)
        guard let capital = state.cities.first(where: { $0.owner == viewer }) else { throw Failure(description: "no capital") }
        for tech in ["writing", "pottery"] { DebugTools.learnTech(TechID(tech), player: viewer, in: &state) }
        DebugTools.setCity(capital.id, population: 6, adding: ["granary"], in: &state)
        guard let site = state.view(for: viewer).quarterOptions(for: capital.id).first(where: { $0.kind == "campus" })?.sites.first,
              DebugTools.addQuarter("campus", at: site.tile, to: capital.id, in: &state) else {
            throw Failure(description: "no Campus fits around the capital")
        }
        DebugTools.setCity(capital.id, population: 6, adding: ["library"], in: &state)
        try GameEngine.apply(.setFocus(city: capital.id, focus: .science), by: viewer, to: &state)
        state.players[viewer.rawValue].gold = 60
        DebugTools.refreshAllKnowledge(in: &state)
        let view = state.view(for: viewer)
        let specialists = view.specialists(of: capital.id)
        let purchase = view.tilePurchase(of: capital.id)
        return Made(state: state, focus: .city(capital.id),
                    note: "specialists \(specialists?.filled.count ?? 0)/\(specialists?.slots.count ?? 0); "
                        + "tile \(purchase?.price ?? 0) Gold, \(purchase?.tiles.count ?? 0) to buy; "
                        + "upkeep \(view.income().buildings) (use buytile)")
    }

    /// M2 §5.1, §5.2: the capital with a Monument, two citizens over its Housing: overcrowded,
    /// Restless (a City Unrest item) and growing slowly; the capital selected.
    static func stability(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0)
        guard let capital = state.cities.first(where: { $0.owner == viewer }) else {
            throw Failure(description: "no capital")
        }
        DebugTools.setCity(capital.id, population: state.housing(of: capital).total + 2, adding: ["monument"], in: &state)
        DebugTools.refreshAllKnowledge(in: &state)
        guard let city = state.city(capital.id) else { throw Failure(description: "the capital is gone") }
        let wellbeing = state.view(for: viewer).wellbeing(of: city.id)
        return Made(state: state, focus: .city(city.id),
                    note: "\(city.name): pop \(city.population), housing \(wellbeing?.housing.total ?? 0), "
                        + "stability \(wellbeing?.stability ?? 0), growth \(wellbeing?.growthPct ?? 0)%")
    }

    /// M2 §3.3: `resources`, plus roads laid by hand from the capital out through its land and
    /// two tiles beyond, and the Quarry pillaged; The Wheel learnt, so the Builder's card
    /// offers a Road.
    static func roads(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0)
        var made = try resources(&state)
        state = made.state
        DebugTools.learnTech("theWheel", player: viewer, in: &state)
        let centre = try home(state)
        let map = state.map
        var line = [centre]
        var at = centre
        for direction in [HexDirection.allCases[0], HexDirection.allCases[0], HexDirection.allCases[1], HexDirection.allCases[0]] {
            guard let next = map.normalize(at.neighbor(direction)), state.rules.isPassable(map[next]), !map[next].terrain.isWater else { break }
            line.append(next)
            at = next
        }
        for direction in HexDirection.allCases.dropFirst(3).prefix(2) {
            if let next = map.normalize(centre.neighbor(direction)), state.rules.isPassable(map[next]) { line.append(next) }
        }
        // Laid by Builders, so every player's memory of the tiles follows (`buildRoad`).
        for hex in line where !state.map[hex].hasRoad {
            let builder = state.addUnit(.builder, owner: viewer, at: hex)
            _ = try? GameEngine.apply(.buildRoad(unit: builder), by: viewer, to: &state)
            _ = try? GameEngine.apply(.disband(unit: builder), by: viewer, to: &state)
        }
        if let quarry = state.map.tiles.indices.first(where: { state.map.tiles[$0].improvement == .quarry }) {
            state.map[index: quarry].pillaged = true
        }
        DebugTools.refreshAllKnowledge(in: &state)
        made.state = state
        made.note = "roads on " + line.map { "\($0.q) \($0.r)" }.joined(separator: ", ") + "; the Quarry pillaged; " + (made.note ?? "")
        return made
    }

    static func tribalVillages(_ state: inout GameState) throws -> Made {
        let viewer = PlayerID(0), enemy = PlayerID(1)
        guard state.rules.tribalVillages != nil else { throw Failure(description: "the rules have no tribal villages") }
        guard let capital = state.players[0].capital.flatMap(state.city) else { throw Failure(description: "the viewer has no capital") }
        guard let scout = state.units(of: viewer).first(where: { state.rules.unit($0.type).unitClass == .recon }) else {
            throw Failure(description: "the viewer has no Scout")
        }
        let map = state.map
        let enemyHome = state.players[1].capital.flatMap(state.city)?.position ?? state.units(of: enemy).first?.position
        func fromEnemy(_ hex: HexCoord) -> Int { enemyHome.map { map.distance($0, hex) } ?? 0 }
        /// Farthest from player 1's home first (ties: the lower tile).
        func awayFromEnemy(_ a: HexCoord, _ b: HexCoord) -> Bool {
            fromEnemy(a) != fromEnemy(b) ? fromEnemy(a) > fromEnemy(b) : map.index(of: a)! < map.index(of: b)!
        }
        /// Nearest player 1's home first (ties: the lower tile).
        func towardEnemy(_ a: HexCoord, _ b: HexCoord) -> Bool {
            fromEnemy(a) != fromEnemy(b) ? fromEnemy(a) < fromEnemy(b) : map.index(of: a)! < map.index(of: b)!
        }
        func seenNow(_ hex: HexCoord, in state: GameState) -> Bool { state.view(for: viewer).isVisible(hex) }
        var placed: [HexCoord] = []
        /// Passable, unowned and empty land at least 3 tiles from the others (`placeTribalVillage`
        /// checks the rest).
        func open(_ hex: HexCoord) -> Bool {
            guard let t = map.index(of: hex) else { return false }
            return state.rules.isPassable(map.tiles[t]) && state.tileOwner(t) == nil && state.units(at: hex).isEmpty
                && placed.allSatisfy { map.distance($0, hex) >= 3 }
        }
        func place(_ hex: HexCoord) -> Bool {
            guard DebugTools.placeTribalVillage(at: hex, in: &state) else { return false }
            placed.append(hex)
            return true
        }
        func text(_ hex: HexCoord) -> String { "\(hex.q) \(hex.r)" }
        var lines: [String] = []

        // The capital's next border tile: the next phase start's border growth takes it in.
        let border = DebugTools.primeBorderGrowth(of: capital.id, in: &state)
        if let border, open(border), place(border) {
            lines.append("\(capital.name)'s next border tile \(text(border)) holds one: `endturn` and its land takes it in")
        } else {
            lines.append("no tribal village on \(capital.name)'s next border tile (\(border.map(text) ?? "none"))")
        }

        // Two tiles from the Scout, reached this phase (moves left after it, the most first), and
        // five from it, three beyond the first: out of sight until the Scout stands on the first,
        // then within the Explore order's horizon from there (reached this phase or the next).
        let start = scout.position
        let reachable = state.view(for: viewer).reachableTiles(for: scout.id)
        var pairs: [(near: HexCoord, far: HexCoord, movesLeft: Int)] = []
        for near in reachable where map.distance(start, near) == 2 && open(near) {
            var trial = state
            guard (try? GameEngine.apply(.moveUnit(unit: scout.id, to: near), by: viewer, to: &trial)) != nil,
                  let moved = trial.unit(scout.id), moved.position == near else { continue }
            let fars = map.coords(within: 5, of: start).filter { far in
                map.distance(start, far) == 5 && map.distance(near, far) == 3 && open(far) && !seenNow(far, in: state)
                    && (Pathfinder.findPath(for: moved, to: far, in: trial).map { $0.turns <= 2 } ?? false)
            }.sorted(by: awayFromEnemy)
            if let far = fars.first { pairs.append((near, far, moved.movesLeft)) }
        }
        pairs.sort { a, b in a.movesLeft != b.movesLeft ? a.movesLeft > b.movesLeft : awayFromEnemy(a.near, b.near) }
        guard let pair = pairs.first, place(pair.near) else {
            throw Failure(description: "no tile 2 from the Scout with one 5 from it beyond")
        }
        let far = place(pair.far) ? pair.far : nil
        lines.append("tap \(text(pair.near)) twice: the Scout's own tap takes the one 2 tiles away (info line, float label, not in attention)")
        if let far {
            lines.append("that brings \(text(far)) into sight; then `explore on`: an Explore leg takes it this phase or at the next "
                         + "phase start (important, the card waits, news in attention)")
        }

        // Shared, toward player 1: one in sight now (else the nearest out of sight), and player
        // 1's Scout two tiles beyond it, out of sight, that reaches it in one phase.
        let candidates = map.coords(within: 6, of: capital.position).filter {
            (3...6).contains(map.distance(capital.position, $0)) && open($0)
        }.sorted { a, b in
            let (sa, sb) = (seenNow(a, in: state), seenNow(b, in: state))
            return sa != sb ? sa : towardEnemy(a, b)
        }
        var shared: (site: HexCoord, rival: UnitID?)?
        search: for site in candidates.prefix(24) {
            for spot in spots(state, around: site, distance: 2...2, for: .scout, owner: enemy, toward: enemyHome)
            where !seenNow(spot, in: state) && state.tileOwner(map.index(of: spot)!) == nil && !placed.contains(spot) {
                var trial = state
                let id = trial.addUnit(.scout, owner: enemy, at: spot)
                guard let rival = trial.unit(id), Pathfinder.findPath(for: rival, to: site, in: trial)?.turns == 1 else { continue }
                guard place(site) else { continue search }
                shared = (site, state.addUnit(.scout, owner: enemy, at: spot))
                break search
            }
        }
        if shared == nil, let site = candidates.first(where: { place($0) }) { shared = (site, nil) }
        if let shared {
            let seen = seenNow(shared.site, in: state) ? "in sight" : "out of sight"
            let command = shared.rival.map { "`aicommand 1 move \($0.rawValue) \(text(shared.site))` and `endturn`: player 1's Scout takes it" }
            lines.append("shared one at \(text(shared.site)) (\(seen)): " + (command ?? "no Scout of player 1 placed beside it"))
        }
        lines.append("`longpress` any for the tile sheet; `diagnostic on` shows the ones not yet seen")
        let note = "tribal-villages: Scout \(scout.id.rawValue) selected at \(text(start)); " + lines.joined(separator: "; ")
        return Made(state: state, focus: .unit(scout.id), note: note)
    }
}

extension AppModel {
    /// Puts a debug scenario on screen (`-scenario`, or the automation command).
    func startScenario(_ name: String) async {
        guard busy == nil else { return }
        busy = "Setting up “\(name)”…"
        defer { busy = nil }
        let size = launch.autostart ?? .duel
        let seed = launch.seed ?? 7
        let civ = launch.civ ?? Self.defaultCiv
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Scenarios.Made, Error> in
            Result { try Scenarios.make(name, size: size, seed: seed, civ: civ) }
        }.value
        switch result {
        case let .success(made):
            Scenarios.lastNote = made.note
            if let note = made.note { DebugLog.write("Scenario \(note)") }
            // Never saved automatically: a scenario must not rotate a real game's saves (M1 §14).
            let session = open(made.state, diagnostic: diagnosticPreference, game: GameSession.newGameID(scenario: true))
            switch made.focus {
            case let .unit(id)?:
                session.select(.unit(id))
                if let unit = session.view.unit(id) { session.renderer.centerCamera(on: unit.position, animated: false) }
            case let .city(id)?:
                session.select(.city(id))
                if let city = session.view.city(id) { session.renderer.centerCamera(on: city.position, animated: false) }
            case let .hex(hex)?:
                session.renderer.centerCamera(on: hex, animated: false)
            case nil:
                break
            }
        case let .failure(error):
            Scenarios.lastNote = nil
            alert = AppAlert(title: "Scenario failed", message: "\(error)")
            markStartScreenReady()
        }
    }
}

/// Forces the interface orientation (`-orientation portrait|landscape|landscapeLeft|landscapeRight`).
enum DebugOrientation {
    @MainActor
    static func request(_ name: String) {
        let mask: UIInterfaceOrientationMask
        switch name.lowercased() {
        case "portrait": mask = .portrait
        case "landscapeleft": mask = .landscapeLeft
        case "landscape", "landscaperight": mask = .landscapeRight
        default: return
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                DebugLog.write("Orientation \(name) refused: \(error.localizedDescription)")
            }
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
#endif
