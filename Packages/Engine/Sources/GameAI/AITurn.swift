import GameCore

// One AI phase (M1 §13). `AITurn` holds the state while the phase is played and the
// bookkeeping of this phase only (units that acted, movement fields, hits on cities, escort
// requests); nothing survives the phase. Every decision reads `view` (the player's PlayerView)
// and every change goes through `issue` (GameEngine.apply).
//
// Order of a phase:
//  1. answer peace proposals;           2. plan (posture, rival, target, rally, threats);
//  3. declare war when ready (re-plan); 4. propose peace;          5. research;
//  6. the first city;                   7. tactics 1–6 (at war);   8. defenders bought for threatened cities;
//  9. settlers, builders, scouts;      10. garrisons, escorts, guards, army;
// 10b. civilians still in an enemy's reach step out or get a fighter on their tile (p3f);
// 11. city production, purchases, focus; 12. units bought fortify; 13. endTurn.
//
// Determinism: units and cities are handled in id order, tiles in index order; sets and
// dictionaries are used for membership and lookups only, never iterated.

struct AITurn {
    let player: PlayerID
    var state: GameState
    let rules: Ruleset
    let ai: AIRules
    /// The AI's random stream for this phase (M1 §12.7: salts turn, player, 0xA1).
    var rng: SplitMix64

    var steps: [AIStep] = []
    var rejections: [AIRejection] = []
    /// Commands issued this phase (the `endTurn` excluded).
    var commands = 0
    var capped = false
    var plan = Plan()

    // MARK: This phase's bookkeeping

    /// Units that have done what they will do this phase (membership only).
    var acted = Set<UnitID>()
    /// Movement fields computed this phase, by unit (lookups only); dropped when the unit moves.
    var fields: [UnitID: [Int32]] = [:]
    /// Movement fields cut off at a cost limit (exact up to it), by unit (lookups only);
    /// dropped when the unit moves.
    var nearFields: [UnitID: (limit: Int, field: [Int32])] = [:]
    /// Attacks on each enemy city this phase (M1 §13 tactic 3), by city (lookups only).
    var cityHits: [CityID: Int] = [:]
    /// Civilians that found no safe way forward and wait for an escort, in id order.
    var escortWanted: [UnitID] = []
    /// Where an escort may join a waiting civilian (tile indices, best first; `escortSpots(for:
    /// toward:_:)`), by civilian (lookups only).
    var escortSpots: [UnitID: [Int]] = [:]
    /// Settlers in `escortWanted` no free fighter could come to this phase, in the same order,
    /// with their escort city, which builds one (p3b ai-settler-escort).
    var unescorted: [(settler: UnitID, city: CityID)] = []
    /// Cities a unit was sent to garrison this phase (lookups only).
    var garrisonSent: [CityID: UnitID] = [:]
    /// The danger map, computed once per phase on first use.
    var dangerCache: [Int32]?
    /// Tiles of known enemy cities, once per phase on first use.
    var enemyCitiesCache: [Int]?
    /// Terrain cost to the nearest own city, with the cities it was computed for (units
    /// heading home); recomputed within the phase only when the cities change (tiles revealed
    /// meanwhile wait for the next phase: it only steers units home).
    var homeFieldCache: (cities: [CityID], field: [Int32])?
    /// Notes on notable decisions (only when `narrate`; never read by a decision).
    let narrate: Bool
    var notes: [String] = []
    /// With `profile`: the time each step of the phase took, in order (HeadlessSim `--profile`;
    /// the clock is read only then, and nothing reads the times back).
    let profile: Bool
    var stepTimes: [(step: String, time: Duration)] = []

    init(state: GameState, player: PlayerID, narrate: Bool = false, profile: Bool = false) {
        self.player = player
        self.state = state
        self.narrate = narrate
        self.profile = profile
        rules = state.rules
        ai = state.rules.ai
        rng = SplitMix64(seed: state.seed, salts: UInt64(state.turn), UInt64(player.rawValue), 0xA1)
    }

    /// Records a notable decision for narration (kept only when narrating; notes are rare, a
    /// few per phase at most).
    mutating func note(_ text: String) {
        if narrate { notes.append(text) }
    }

    /// A city's name for notes.
    func cityName(_ id: CityID) -> String {
        view.city(id)?.name ?? view.knownCities.first { $0.id == id }?.name ?? "\(id)"
    }

    /// What the player knows now.
    var view: PlayerView { state.view(for: player) }

    /// The phase is still this player's to play.
    var live: Bool { state.outcome == nil && state.currentPlayer == player }

    // MARK: The phase

    mutating func play() {
        guard live, view.me.isAlive else { return }
        timed("respondToPeace") { $0.respondToPeace() }
        timed("plan") { t in
            t.plan = t.makePlan()
            if t.declareWarIfReady() { t.plan = t.makePlan() }
        }
        timed("proposePeace") { $0.proposePeaceIfWanted() }
        timed("research") { $0.chooseResearch() }
        timed("firstCity") { $0.foundFirstCity() }
        // Tactics in the order of M1 §13; 4 also applies at peace.
        let atWar = !plan.enemies.isEmpty
        if atWar {
            timed("1 captureCities") { $0.captureCities() }
            timed("2 bombardAndShoot") { $0.bombardAndShoot() }
            timed("3 meleeAttacks") { $0.meleeAttacks() }
        }
        timed("4 retreatWounded") { $0.retreatWounded() }
        if atWar {
            timed("5 defendCities") { $0.defendCities() }
            timed("6 captureCivilians") { $0.captureCivilians() }
        }
        timed("improveUnits") { $0.improveUnits() }
        timed("buyThreatDefenders") { $0.buyThreatDefenders() }
        timed("moveSettlers") { $0.moveSettlers() }
        timed("moveBuilders") { $0.moveBuilders() }
        timed("explore") { $0.explore() }
        timed("moveMilitary") { $0.moveMilitary() }
        timed("secureCivilians") { $0.secureCivilians() }
        timed("manageCities") { $0.manageCities() }
        timed("fortifyNewUnits") { $0.fortifyNewUnits() }
        if live {
            let command = Command.endTurn
            do {
                let events = try GameEngine.apply(command, by: player, to: &state)
                steps.append(AIStep(command: command, events: events))
            } catch {
                rejections.append(AIRejection(turn: state.turn, player: player, command: command, error: error))
            }
        }
    }

    /// Runs one step of the phase, timing it when profiling.
    mutating func timed(_ step: String, _ body: (inout AITurn) -> Void) {
        guard profile else {
            body(&self)
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        body(&self)
        stepTimes.append((step, clock.now - start))
    }

    // MARK: Commands

    /// Applies a command for the player. A refused command changes nothing and is recorded;
    /// once the phase's cap is reached nothing more is issued.
    @discardableResult
    mutating func issue(_ command: Command) -> Bool {
        guard live else { return false }
        guard commands < ai.maxCommandsPerPhase else {
            capped = true
            return false
        }
        commands += 1
        do {
            let events = try GameEngine.apply(command, by: player, to: &state)
            steps.append(AIStep(command: command, events: events))
            return true
        } catch {
            rejections.append(AIRejection(turn: state.turn, player: player, command: command, error: error))
            return false
        }
    }

    /// Moves an own unit to a tile it reaches this phase (checked with a fresh path, so a tile
    /// another unit took meanwhile is skipped rather than refused). Returns whether it moved.
    @discardableResult
    mutating func move(_ id: UnitID, to hex: HexCoord) -> Bool {
        let v = view
        guard let unit = v.unit(id), unit.owner == player, unit.movesLeft > 0, !unit.zocStopped, hex != unit.position,
              let path = v.path(for: id, to: hex), path.turns <= 1 else { return false }
        forgetFields(id)
        return issue(.moveUnit(unit: id, to: hex))
    }

    /// Moves an own unit along its path toward `goal` as far as it gets this phase, leaving no
    /// standing order (the AI re-plans every phase). Returns whether it moved.
    @discardableResult
    mutating func hop(_ id: UnitID, toward goal: HexCoord) -> Bool {
        let v = view
        guard let unit = v.unit(id), unit.owner == player, unit.movesLeft > 0, !unit.zocStopped, goal != unit.position,
              let path = v.path(for: id, to: goal), let end = path.steps.last(where: { $0.turn <= 1 })?.hex else { return false }
        forgetFields(id)
        return issue(.moveUnit(unit: id, to: end))
    }

    /// Moves a unit to the best of `candidates` it reaches this phase (tile indices, best
    /// first), trying a few in turn. Returns the tile it moved to.
    @discardableResult
    mutating func moveToFirst(_ id: UnitID, of candidates: [Int], tries: Int = 4) -> Int? {
        for t in candidates.prefix(tries) where move(id, to: view.coord(at: t)) {
            return t
        }
        return nil
    }

    // MARK: Units

    /// A unit's movement field (M1 §12.6), computed at most once per phase (until it moves).
    /// A Settler's stops only where an escort could join it (`settlerStops`).
    mutating func field(_ id: UnitID) -> [Int32] {
        if let cached = fields[id] { return cached }
        let v = view
        let computed = settlerStops(id, v).map { v.aiMovementField(for: id, mayStop: $0) } ?? v.movementField(for: id)
        fields[id] = computed
        return computed
    }

    /// A unit's movement field exact up to cost `limit` and −1 beyond (much cheaper than
    /// `field` on a big map). A full field, or a wider one, serves if there is one.
    mutating func field(_ id: UnitID, within limit: Int) -> [Int32] {
        if let full = fields[id] { return full }
        if let near = nearFields[id], near.limit >= limit { return near.field }
        let v = view
        let computed = settlerStops(id, v).map { v.aiMovementField(for: id, mayStop: $0, limit: limit) }
            ?? v.movementField(for: id, limit: limit)
        nearFields[id] = (limit, computed)
        return computed
    }

    /// A path for an own unit by its player's knowledge (`PlayerView.path(for:to:)`); a
    /// Settler's stops only where an escort could join it (`settlerStops`).
    func path(_ id: UnitID, to goal: HexCoord, _ v: PlayerView) -> Path? {
        settlerStops(id, v).map { v.aiPath(for: id, to: goal, mayStop: $0) } ?? v.path(for: id, to: goal)
    }

    /// For a Settler, the tiles where it may end a phase (ai-3): anywhere but on an unsafe tile
    /// (M1 §13 Safety) in territory closed to the player's military (M1 §9), where no escort
    /// could join it. A Settler that went into a peace partner's land and met its garrisons
    /// found every way on unsafe and waited for an escort that could never come (once for 50
    /// turns); so its fields and paths pass such tiles but never stop on them, and sites only
    /// reached that way are out of its reach. Nil for any other unit, and when no territory is
    /// closed (the plain field and path serve).
    func settlerStops(_ id: UnitID, _ v: PlayerView) -> [Bool]? {
        guard let unit = v.unit(id), rules.unit(unit.type).foundsCity else { return nil }
        let closed = v.aiClosedToMilitary()
        guard closed.contains(true) else { return nil }
        let danger = civilianDanger(v)
        return closed.indices.map { !closed[$0] || safe($0, v, danger: danger) }
    }

    /// The movement field over the tiles a unit reaches this phase.
    mutating func reachField(_ id: UnitID) -> [Int32] {
        field(id, within: view.unit(id)?.movesLeft ?? 0)
    }

    /// Drops a unit's cached movement fields (it moved or acted).
    mutating func forgetFields(_ id: UnitID) {
        fields[id] = nil
        nearFields[id] = nil
    }

    /// Tiles (indices) a unit reaches and may stop on this phase by its movement field, its
    /// own tile excluded.
    mutating func reachableThisPhase(_ unit: Unit) -> [Int] {
        guard unit.movesLeft > 0, !unit.zocStopped, let here = view.index(of: unit.position) else { return [] }
        let f = reachField(unit.id)
        return view.aiTiles(within: unit.movesLeft, of: here).filter { $0 != here && f[$0] >= 0 && Int(f[$0]) <= unit.movesLeft }
    }

    /// Units that have not acted take the first promotion offered (rules order is the class
    /// priority) or upgrade when the treasury holds twice the cost (M2 §18).
    mutating func improveUnits() {
        for unit in view.units where unit.owner == player && !acted.contains(unit.id) && unit.movesLeft > 0 {
            guard live else { return }
            if let promotion = view.promotionsOffered(unit.id).first {
                if issue(.promote(unit: unit.id, promotion: promotion.id)) { acted.insert(unit.id) }
            } else if let cost = view.upgradeCost(unit.id), view.me.gold >= 2 * cost {
                if issue(.upgrade(unit: unit.id)) { acted.insert(unit.id) }
            }
        }
    }

    /// Units bought this phase (after the military moved) fortify where they appear.
    mutating func fortifyNewUnits() {
        for unit in view.units where !unit.type.isCivilian && !acted.contains(unit.id) && unit.activity == .none
            && unit.destination == nil && !unit.zocStopped && unit.movesLeft == rules.unit(unit.type).moves {
            guard live else { return }
            fortify(unit)
        }
    }

    /// Fortifies a military unit unless it is fortified or fortifying already.
    mutating func fortify(_ unit: Unit) {
        guard !unit.type.isCivilian, unit.activity != .fortified, unit.activity != .fortifying else { return }
        issue(.fortify(unit: unit.id))
    }

    /// Puts a unit to sleep unless it sleeps already.
    mutating func sleep(_ unit: Unit) {
        guard unit.activity != .sleeping else { return }
        issue(.sleep(unit: unit.id))
    }

    func isRecon(_ type: UnitType) -> Bool { rules.unit(type).unitClass == .recon }
    func isRanged(_ type: UnitType) -> Bool { rules.unit(type).isRanged }
    /// Melee or antiCavalry: the classes that take cities (M1 §5) and count as "melee" for the
    /// AI's army.
    func isLine(_ type: UnitType) -> Bool {
        let c = rules.unit(type).unitClass
        return c == .melee || c == .antiCavalry
    }
    /// Military and not recon: counts for defence and armies (M1 §7, §13).
    func isFighter(_ type: UnitType) -> Bool { !type.isCivilian && !isRecon(type) }

    /// The danger map (M1 §12.6), once per phase.
    mutating func danger() -> [Int32] {
        if let cached = dangerCache { return cached }
        let computed = view.dangerMap()
        dangerCache = computed
        return computed
    }

    /// Tiles (indices) of visible foreign military units, optionally only those of players at
    /// war with this one, and optionally without recon units.
    func foreignMilitaryTiles(_ v: PlayerView, enemiesOnly: Bool, includeRecon: Bool) -> [Int] {
        v.visibleForeignUnits.compactMap { u in
            guard !u.type.isCivilian, includeRecon || !isRecon(u.type), !enemiesOnly || v.isAtWar(with: u.owner) else { return nil }
            return v.index(of: u.position)
        }
    }
}
