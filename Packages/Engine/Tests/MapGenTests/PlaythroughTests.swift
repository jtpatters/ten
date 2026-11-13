import Foundation
import Testing
import GameCore
import MapGen

// An integration play test (core-3): a scripted, human-like game on a generated Duel map,
// played only through `GameEngine.apply`, with player 0's decisions taken from its PlayerView.
// Player 1 is idle: it starts with two extra Settlers and a Warrior (scenario setup), founds its
// capital and a second city, parks the third Settler behind its capital with the Warrior
// fortified on it (so player 0's moves cannot capture it in passing, M1 §7.3) and otherwise
// only ends its turn.
// Player 0 founds a city, sets production and research, grows, builds a Builder and improves a
// tile (the nearest Farm or Pasture site, or a Mine site once Mining is known), builds Archers,
// meets player 1, declares war, besieges and takes the second city (checking each preview
// against the outcome, and the raze window), proposes peace (unanswered, so it expires into a
// cool-down), then takes the capital: a domination victory with player 1 still alive.

/// The events of a list, without their audiences.
private func events(_ records: [EventRecord]) -> [GameEvent] { records.map(\.event) }

/// The single `combat` event of a list of records (nil when there is none or several).
private func combatEvent(_ records: [EventRecord]) -> (dealt: Int, taken: Int, ranged: Bool)? {
    let all = records.compactMap { record -> (Int, Int, Bool)? in
        if case let .combat(_, _, _, _, ranged, dealt, taken) = record.event { return (dealt, taken, ranged) }
        return nil
    }
    return all.count == 1 ? (all[0].0, all[0].1, all[0].2) : nil
}

private func expectSound(_ state: GameState, sourceLocation: SourceLocation = #_sourceLocation) {
    let problems = state.checkInvariants()
    #expect(problems.isEmpty, "\(problems)", sourceLocation: sourceLocation)
}

struct Playthrough {
    let me = PlayerID(0), them = PlayerID(1)
    var state: GameState
    /// Records player 0 received, in order.
    var seen: [EventRecord] = []
    /// Milestones reached, by name, with the turn.
    var milestones: [(String, Int)] = []
    let theirStart: HexCoord
    var myCapital: CityID?
    var theirCapital: CityID?
    var theirSecondCity: CityID?
    var secondSettler: UnitID
    var parkedSettler: UnitID
    var guardian: UnitID
    var site: HexCoord?
    var park: HexCoord?
    var farmTile: HexCoord?
    var proposedTurn: Int?
    var previewsChecked = 0

    init(seed: UInt64) throws {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: seed))
        var state = GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions,
                                      mapSizeName: MapSize.duel.rawValue)
        theirStart = generated.startPositions[1]
        // Scenario: player 1 gets two more Settlers next to its start and a Warrior with the
        // second of them.
        var extra: [UnitID] = []
        for n in state.map.neighbors(of: theirStart) where extra.count < 2 && state.canEnd(.settler, owner: PlayerID(1), at: n) {
            extra.append(state.addUnit(.settler, owner: PlayerID(1), at: n))
        }
        try #require(extra.count == 2)
        secondSettler = extra[0]
        parkedSettler = extra[1]
        let parkedAt = try #require(state.unit(extra[1])).position
        try #require(state.canEnd(.warrior, owner: PlayerID(1), at: parkedAt))
        guardian = state.addUnit(.warrior, owner: PlayerID(1), at: parkedAt)
        self.state = state
    }

    var view: PlayerView { state.view(for: me) }
    var turn: Int { state.turn }

    mutating func note(_ milestone: String) {
        if !milestones.contains(where: { $0.0 == milestone }) { milestones.append((milestone, state.turn)) }
    }

    func reached(_ milestone: String) -> Bool { milestones.contains { $0.0 == milestone } }

    @discardableResult
    mutating func play(_ command: Command, sourceLocation: SourceLocation = #_sourceLocation) throws -> [EventRecord] {
        let records = try GameEngine.apply(command, by: state.currentPlayer, to: &state)
        seen += records.filter { $0.isVisible(to: me) }
        return records
    }

    /// Like `play`, but a refusal is only returned.
    @discardableResult
    mutating func attempt(_ command: Command) -> CommandError? {
        do { try play(command) } catch let error as CommandError { return error } catch { return nil }
        return nil
    }

    // MARK: Player 1, idle

    mutating func opponentPhase() throws {
        // The Warrior walks to the park and fortifies there.
        if let park, let unit = state.view(for: them).unit(guardian) {
            if unit.position == park {
                if unit.activity != .fortified, unit.movesLeft > 0 { attempt(.fortify(unit: unit.id)) }
            } else if unit.destination == nil, unit.movesLeft > 0 {
                attempt(.moveUnit(unit: unit.id, to: park))
            }
        }
        for id in state.view(for: them).units.filter({ $0.type == .settler }).map(\.id) {
            let view = state.view(for: them)
            guard let unit = view.unit(id) else { continue }
            if view.cities.isEmpty {
                try play(.foundCity(unit: unit.id))
                theirCapital = state.cities.first { $0.owner == them }?.id
                pickSites()
            } else if unit.id == secondSettler, let site {
                if unit.position == site {
                    try play(.foundCity(unit: unit.id))
                    theirSecondCity = state.cities.last { $0.owner == them }?.id
                } else if unit.destination == nil, unit.movesLeft > 0 {
                    attempt(.moveUnit(unit: unit.id, to: site))
                }
            } else if unit.id == parkedSettler, let park {
                if unit.position == park {
                    if unit.activity != .sleeping { try play(.sleep(unit: unit.id)) }
                } else if unit.destination == nil, unit.movesLeft > 0 {
                    attempt(.moveUnit(unit: unit.id, to: park))
                }
            }
        }
        try play(.endTurn)
    }

    /// Player 1's second city site (best settle score 4–5 from its capital, 6+ from player
    /// 0's start, nearer player 0 than its capital where possible) and the tile 3 behind its
    /// capital where the third Settler waits.
    mutating func pickSites() {
        let view = state.view(for: them)
        let mine = view.cities[0].position
        let myStart = state.units(of: me).first { $0.type == .settler }?.position ?? state.cities.first { $0.owner == me }!.position
        var best: (score: Int, near: Bool, tile: Int)?
        for t in 0..<view.tileCount {
            let h = view.coord(at: t)
            let d = view.distance(h, mine)
            guard (4...5).contains(d), view.distance(h, myStart) >= 6 else { continue }
            let score = view.settleScore(at: h)
            guard score > 0, view.path(for: secondSettler, to: h) != nil else { continue }
            let near = view.distance(h, myStart) < view.distance(mine, myStart)
            if let b = best, (b.near && !near) || (b.near == near && b.score >= score) { continue }
            best = (score, near, t)
        }
        site = best.map { view.coord(at: $0.tile) }
        var far: (distance: Int, tile: Int)?
        for t in 0..<view.tileCount {
            let h = view.coord(at: t)
            guard view.distance(h, mine) == 3, site.map({ view.distance(h, $0) >= 4 }) ?? true,
                  state.canEnd(.settler, owner: them, at: h), state.canEnd(.warrior, owner: them, at: h),
                  view.path(for: parkedSettler, to: h) != nil, view.path(for: guardian, to: h) != nil else { continue }
            let d = view.distance(h, myStart)
            if let f = far, f.distance >= d { continue }
            far = (d, t)
        }
        park = far.map { view.coord(at: $0.tile) }
    }

    // MARK: Player 0, human-like

    /// Moves `unit` toward the nearest tile (by its movement field) at most `distance` from
    /// `target`; nothing if it is already there or has a standing order to such a tile.
    mutating func approach(_ id: UnitID, _ target: HexCoord, within distance: Int) {
        guard let unit = view.unit(id), unit.movesLeft > 0, !unit.zocStopped else { return }
        if view.distance(unit.position, target) <= distance { return }
        if let d = unit.destination, view.distance(d, target) <= distance { return }
        let field = view.movementField(for: id)
        var best: (cost: Int32, tile: Int)?
        for h in view.coords(within: distance, of: target) {
            // Not onto a tile with a seen unit (moving onto enemy civilians would capture them).
            guard let t = view.index(of: h), field[t] > 0, view.units(at: h).isEmpty else { continue }
            if let b = best, b.cost <= field[t] { continue }
            best = (field[t], t)
        }
        if let best { attempt(.moveUnit(unit: id, to: view.coord(at: best.tile))) }
    }

    /// One attack by an own unit on the city at `target`, checked against its preview.
    mutating func attackCity(_ id: UnitID, at target: HexCoord) throws {
        guard let unit = view.unit(id), unit.movesLeft > 0,
              let option = view.attackOptions(for: id).first(where: { $0.target == target }) else { return }
        if option.from != unit.position {
            guard option.moveCost < unit.movesLeft else { return }
            try play(.moveUnit(unit: id, to: option.from))
            guard let moved = view.unit(id), moved.position == option.from, moved.movesLeft > 0 else { return }
        }
        let preview = try #require(view.combatPreview(attacker: .unit(id), target: target, from: option.from))
        let city = try #require(state.city(at: target))
        let hpBefore = city.hp + city.wallHP
        let records = try play(.attack(unit: id, target: target))
        previewsChecked += 1
        if preview.capturesCity {
            #expect(records.contains { if case .cityCaptured = $0.event { true } else { false } })
            #expect(preview.killChancePercent == 100 && preview.deathChancePercent == 0)
            return
        }
        let combat = try #require(combatEvent(records))
        #expect(combat.dealt <= preview.damageDealt.upperBound)
        #expect(combat.dealt >= min(preview.damageDealt.lowerBound, hpBefore))
        #expect(preview.damageTaken.contains(combat.taken) || state.unit(id) == nil)
        #expect(combat.ranged == preview.ranged && (combat.ranged ? combat.taken == 0 : true))
        let hpAfter = state.city(at: target).map { $0.hp + $0.wallHP } ?? 0
        #expect(hpAfter == max(0, hpBefore - combat.dealt))
    }

    var military: [GameCore.Unit] { view.units.filter { !$0.type.isCivilian } }

    mutating func myPhase() throws {
        let view = self.view
        // Turn 1: found the capital, set production and research.
        if myCapital == nil, let settler = view.units.first(where: { $0.type == .settler }) {
            #expect(view.canFoundCity(at: settler.position) && view.settleScore(at: settler.position) > 0)
            try play(.foundCity(unit: settler.id))
            let city = try #require(self.view.cities.first)
            myCapital = city.id
            #expect(city.has("palace") && self.view.me.originalCapital == city.id)
            try play(.setQueue(city: city.id, items: [.unit(.warrior), .unit(.builder)]))
            try play(.setResearch(tech: "archery"))
            #expect(self.view.me.researching == "animalHusbandry" && self.view.me.researchTarget == "archery")
            note("founded")
        }
        guard let capitalID = myCapital, let capital = self.view.city(capitalID) else { return }
        if capital.population >= 2 { note("grew") }

        // Builder: walk to the nearest tile of ours with an improvement it may build (one whose
        // tech is known: a Farm, a Pasture or a Mine) and build it.
        if !reached("improved"), let builder = self.view.units.first(where: { $0.type == .builder }) {
            let kinds: [(UnitActionKind, Improvement)] = [(.buildFarm, .farm), (.buildPasture, .pasture), (.buildMine, .mine)]
            let buildable = kinds.filter { kind in state.rules.improvement(kind.1).tech.map { self.view.me.knows($0) } ?? true }
            if farmTile == nil {
                farmTile = (0..<self.view.tileCount).map { self.view.coord(at: $0) }.filter { h in
                    guard let t = self.view.index(of: h), self.view.knownTerritory[t] == 1, h != capital.position,
                          let tile = self.view.tile(at: h), tile.improvement == nil else { return false }
                    return buildable.contains { state.rules.allowsImprovement($0.1, on: tile) } && self.view.path(for: builder.id, to: h) != nil
                }.min { self.view.distance($0, capital.position) < self.view.distance($1, capital.position) }
            }
            if let target = farmTile {
                if builder.position == target, builder.movesLeft > 0 {
                    let before = try #require(self.view.tileYields(at: target))
                    let actions = self.view.unitActions(for: builder.id)
                    let (_, improvement) = try #require(kinds.first { kind in actions.contains { $0.kind == kind.0 && $0.isAvailable } })
                    let records = try play(.buildImprovement(unit: builder.id, improvement: improvement))
                    #expect(events(records).contains(.improvementBuilt(improvement: improvement, at: target, owner: me)))
                    #expect(self.view.tile(at: target)?.improvement == improvement)
                    let after = try #require(self.view.tileYields(at: target))
                    #expect(after.food + after.production + after.gold > before.food + before.production + before.gold)
                    note("improved")
                } else if builder.destination == nil {
                    attempt(.moveUnit(unit: builder.id, to: target))
                }
            }
        }

        // Production: Archers once Archery is known; production focus once the city has grown.
        if self.view.me.knows("archery"), !reached("archers queued") {
            try play(.setQueue(city: capitalID, items: [.unit(.archer), .unit(.archer), .unit(.warrior), .unit(.warrior)]))
            note("archers queued")
        }
        // Research: Mining after Archery (Mines for hills, where no Farm may go).
        if self.view.me.knows("archery"), !self.view.me.knows("mining"), self.view.me.researching != "mining" {
            try play(.setResearch(tech: "mining"))
            #expect(self.view.me.researching == "mining")
        }
        if reached("grew"), reached("improved"), capital.focus != .production {
            try play(.setFocus(city: capitalID, focus: .production))
        }
        if self.view.city(capitalID)?.queue.isEmpty == true, reached("archers queued") {
            try play(.setQueue(city: capitalID, items: [.unit(.warrior)]))
        }

        // Scouting: toward player 1 until met.
        if let scout = self.view.units.first(where: { $0.type == .scout }) {
            if !self.view.hasMet(them) {
                approach(scout.id, theirStart, within: 3)
            } else if scout.activity == .none, !self.view.isAtWar(with: them) {
                attempt(.fortify(unit: scout.id))
            }
        }
        if self.view.hasMet(them) {
            note("met")
            #expect(seen.contains { $0.event == .playersMet(me, them) })
        }

        let archers = military.filter { $0.type == .archer }
        let melee = military.filter { $0.type == .warrior || $0.type == .spearman }

        // War once two Archers and two melee units stand ready and player 1 has two cities.
        if !self.view.isAtWar(with: them), !reached("captured second"), self.view.hasMet(them), archers.count >= 2, melee.count >= 2,
           theirSecondCity != nil {
            #expect(self.view.warProblem(on: them) == nil)
            let records = try play(.declareWar(on: them))
            #expect(events(records).contains(.warDeclared(by: me, on: them)))
            #expect(self.view.peaceProblem(to: them) != nil) // war must last 5 turns first
            note("war")
        }
        guard self.view.isAtWar(with: them) else {
            // Before the war: the army gathers by the capital, fortified.
            for unit in military where unit.type != .scout && unit.activity == .none && unit.destination == nil {
                if self.view.distance(unit.position, capital.position) > 2 {
                    approach(unit.id, capital.position, within: 2)
                } else {
                    attempt(.fortify(unit: unit.id))
                }
            }
            return
        }

        // Peace proposal once the war has lasted 5 turns: unanswered, it expires.
        if proposedTurn == nil, reached("captured second"), let since = self.view.relation(with: them)?.since, turn >= since + 5 {
            #expect(self.view.peaceProblem(to: them) == nil)
            let records = try play(.proposePeace(to: them))
            #expect(events(records) == [.peaceProposed(from: me, to: them)] && records[0].audience == 0b11)
            proposedTurn = turn
            note("peace proposed")
        }

        // The siege: the second city first, then the capital.
        let targetCity = reached("captured second") ? theirCapital : theirSecondCity
        guard let targetID = targetCity, let target = state.city(targetID)?.position, state.city(targetID)?.owner == them else { return }
        for archer in archers {
            try attackCity(archer.id, at: target)
            approach(archer.id, target, within: 2)
        }
        let knownHP = self.view.knownCity(at: target).map { $0.hp + $0.wallHP } ?? 1
        for unit in melee {
            if knownHP == 0 || self.view.combatPreview(attacker: .unit(unit.id), target: target, from: unit.position)?.capturesCity == true {
                try attackCity(unit.id, at: target)
                if state.city(targetID)?.owner == me { break }
            }
            approach(unit.id, target, within: 1)
        }
        if state.city(targetID)?.owner == me {
            if targetID == theirSecondCity {
                note("captured second")
                #expect(self.view.canRaze(targetID)) // captured this phase, not an original capital
            } else {
                note("captured capital")
            }
        }
    }

    /// Plays one full turn: player 0, then idle player 1.
    mutating func playTurn() throws {
        let turn = state.turn
        try myPhase()
        guard state.outcome == nil else { return }
        let capturedThisPhase = milestones.last.map { $0.0 == "captured second" && $0.1 == turn } ?? false
        try play(.endTurn)
        if state.outcome == nil, state.currentPlayer == them { try opponentPhase() }
        expectSound(state)
        // The raze window closes with the phase of the capture.
        if capturedThisPhase, let city = theirSecondCity {
            #expect(!view.canRaze(city))
            #expect(attempt(.razeCity(city: city)) == .rejected(reason: "only a city captured this phase can be razed"))
            note("raze window closed")
        }
        // The unanswered proposal expired at player 0's phase start: a cool-down follows.
        if let proposed = proposedTurn, proposed == turn {
            #expect(seen.contains { $0.event == .peaceDeclined(proposer: me, by: them) })
            #expect(view.peaceProblem(to: them) != nil)
            note("proposal expired")
        }
    }
}

@Suite struct PlaythroughTests {
    @Test(arguments: [UInt64(2026), 7, 42, 99, 123])
    func aDuelFromFoundingToDomination(seed: UInt64) throws {
        var game = try Playthrough(seed: seed)
        while game.state.outcome == nil, game.turn <= 160 {
            try game.playTurn()
        }
        let theirUnits = game.state.units(of: PlayerID(1)).map { "\($0.id) \($0.type) \($0.position)" }
        let captures = game.seen.filter { if case .unitCaptured = $0.event { true } else { false } }.map { "\($0.event)" }
        let summary = game.milestones.map { "\($0.0)@\($0.1)" }.joined(separator: ", ")
            + " | site \(String(describing: game.site)) park \(String(describing: game.park)) theirs \(theirUnits) captures \(captures)"
        print("playthrough seed \(seed): \(summary); \(game.previewsChecked) attacks checked against previews")
        for milestone in ["founded", "grew", "improved", "archers queued", "met", "war", "captured second", "raze window closed",
                          "peace proposed", "proposal expired", "captured capital"] {
            #expect(game.reached(milestone), "missing \(milestone): \(summary)")
        }
        #expect(game.state.outcome == .victory(player: PlayerID(0), kind: .domination), "\(summary)")
        #expect(game.state.players[1].isAlive) // the parked Settler: a domination, not the last player standing
        #expect(game.seen.last?.event == .gameOver(.victory(player: PlayerID(0), kind: .domination)))
        #expect(throws: CommandError.gameOver) { try GameEngine.apply(.endTurn, by: game.state.currentPlayer, to: &game.state) }
        #expect(game.previewsChecked >= 4)
        // What player 0 was told along the way.
        let told = game.seen.map(\.event)
        let me = PlayerID(0)
        #expect(told.contains { if case let .cityGrew(city, _, _) = $0 { city == game.myCapital } else { false } })
        #expect(told.contains(.techResearched(player: me, tech: "animalHusbandry")) && told.contains(.techResearched(player: me, tech: "archery")))
        for item in [ProductionItem.unit(.warrior), .unit(.builder), .unit(.archer)] {
            #expect(told.contains { if case let .productionCompleted(_, done, _) = $0 { done == item } else { false } }, "\(item)")
        }
        #expect(told.filter { if case let .cityCaptured(_, _, _, to, _) = $0 { to == me } else { false } }.count == 2)
        #expect(game.state.cities.filter { $0.owner == me }.count == 3)
        #expect(game.state.players[1].capital == nil && game.state.players[1].originalCapital == game.theirCapital)
        expectSound(game.state)
    }
}
