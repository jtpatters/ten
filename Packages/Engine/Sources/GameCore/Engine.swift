/// Every state change, from human or AI, is a Command applied by `GameEngine`.
/// This is what makes undo, replays, bug repro from logs, and future async
/// multiplayer possible: send commands, not state.
public enum Command: Codable, Hashable, Sendable {
    /// Move toward a destination; continues automatically on later turns.
    case moveUnit(unit: UnitID, to: HexCoord)
    /// Clear a unit's standing orders.
    case cancelOrders(unit: UnitID)
    /// End the current player's phase.
    case endTurn
    case foundCity(unit: UnitID)
    case buildImprovement(unit: UnitID, improvement: Improvement)
    case fortify(unit: UnitID)
    case sleep(unit: UnitID)
    case wake(unit: UnitID)
    case skip(unit: UnitID)
    case disband(unit: UnitID)
    /// Attack the enemy city or military unit on `target` (M1 §8.3): melee units from a
    /// neighbouring tile, ranged units from within range. A melee or antiCavalry unit attacking
    /// a city at 0 HP captures it.
    case attack(unit: UnitID, target: HexCoord)
    /// A city's bombard: a ranged attack within 2 tiles, once per phase (M1 §5).
    case cityAttack(city: CityID, target: HexCoord)
    /// Replace a city's production queue (M1 §5).
    case setQueue(city: CityID, items: [ProductionItem])
    /// Buy an item for 3 × its production cost in Gold (M1 §5).
    case purchase(city: CityID, item: ProductionItem)
    case setFocus(city: CityID, focus: CityFocus)
    /// Research a tech, through its missing prerequisites (M1 §6).
    case setResearch(tech: TechID)
    /// Declare war on a player met and at peace with (M1 §9).
    case declareWar(on: PlayerID)
    /// Propose peace to a player at war with (M1 §9); it answers in its own phase.
    case proposePeace(to: PlayerID)
    /// Answer a peace proposal (M1 §9).
    case respondToPeace(from: PlayerID, accept: Bool)
    /// Raze a city captured this phase that is no original capital (M1 §5).
    case razeCity(city: CityID)
    /// Upgrade a unit to its `upgradesTo` type for Gold (M2 §8.2).
    case upgrade(unit: UnitID)
    /// Take one of the promotions offered to a unit with one due (M2 §8.3).
    case promote(unit: UnitID, promotion: String)
    /// A Builder lays a road where it stands (M2 §3.3).
    case buildRoad(unit: UnitID)
    /// A military unit pillages the enemy tile it stands on (M2 §3.3).
    case pillage(unit: UnitID)
}

public enum CommandError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownUnit(UnitID)
    case notYourUnit(UnitID)
    case unknownCity(CityID)
    case notYourCity(CityID)
    case noPath
    /// Only the current player may issue commands.
    case notYourTurn
    /// The game has an outcome; nothing more can happen.
    case gameOver
    /// The unit's movement was ended by an enemy's zone of control this phase.
    case zoneOfControl
    /// The command exists but its rules are not written yet (no M1 command throws it any more).
    case notImplemented
    /// Not allowed now, with a reason the UI can show.
    case rejected(reason: String)

    public var description: String {
        switch self {
        case let .unknownUnit(id): "no unit \(id)"
        case let .notYourUnit(id): "unit \(id) is not yours"
        case let .unknownCity(id): "no city \(id)"
        case let .notYourCity(id): "city \(id) is not yours"
        case .noPath: "can't reach that tile"
        case .notYourTurn: "not your turn"
        case .gameOver: "the game is over"
        case .zoneOfControl: "stopped by a zone of control"
        case .notImplemented: "not available yet"
        case let .rejected(reason): reason
        }
    }
}

/// Output of applying a command, consumed by rendering/audio/notifications.
/// Rendering never mutates state; it only reacts to these. Events carry every hex they concern
/// and the type and owner of anything they remove (M1 §12.5).
public enum GameEvent: Hashable, Sendable, Codable {
    case unitMoved(unit: UnitID, from: HexCoord, path: [HexCoord])
    /// A new turn began (before the first phase's `phaseStarted`).
    case turnStarted(turn: Int)
    /// A move stopped short (an unseen obstacle or a zone of control); its order is cleared.
    case moveInterrupted(unit: UnitID, at: HexCoord)
    case unitCreated(unit: UnitID, type: UnitType, owner: PlayerID, at: HexCoord)
    case unitKilled(unit: UnitID, type: UnitType, owner: PlayerID, at: HexCoord)
    /// A civilian captured: `old` is removed and its captor's player gets `new`, of `type`.
    case unitCaptured(old: UnitID, new: UnitID, type: UnitType, from: PlayerID, to: PlayerID, at: HexCoord)
    /// `upkeep`: disbanded because its owner could not pay upkeep.
    case unitDisbanded(unit: UnitID, type: UnitType, owner: PlayerID, at: HexCoord, upkeep: Bool)
    /// One attack: damage dealt to the defender and taken by the attacker (0 for ranged).
    case combat(attacker: Combatant, defender: Combatant, from: HexCoord, to: HexCoord, ranged: Bool, dealt: Int, taken: Int)
    case cityFounded(city: CityID, name: String, owner: PlayerID, at: HexCoord)
    case cityGrew(city: CityID, population: Int, at: HexCoord)
    case cityShrank(city: CityID, population: Int, at: HexCoord)
    case cityCaptured(city: CityID, name: String, from: PlayerID, to: PlayerID, at: HexCoord)
    case cityRazed(city: CityID, name: String, owner: PlayerID, at: HexCoord)
    case productionCompleted(city: CityID, item: ProductionItem, at: HexCoord)
    case techResearched(player: PlayerID, tech: TechID)
    case borderGrew(city: CityID, tile: HexCoord)
    case improvementBuilt(improvement: Improvement, at: HexCoord, owner: PlayerID)
    case playersMet(PlayerID, PlayerID)
    case warDeclared(by: PlayerID, on: PlayerID)
    case peaceProposed(from: PlayerID, to: PlayerID)
    case peaceSigned(PlayerID, PlayerID)
    case peaceDeclined(proposer: PlayerID, by: PlayerID)
    /// A tribal village was taken (M1 §7.7): entered by `unit`, or taken in by `city`'s land
    /// (one of the two is set); `player` gets the gift.
    case tribalVillageTaken(at: HexCoord, player: PlayerID, unit: UnitID?, city: CityID?)
    /// What the villagers gave `player` for the tribal village at `at` (a fallback reported as
    /// the Gold it became).
    case tribalVillageGift(player: PlayerID, at: HexCoord, gift: TribalVillageGift)
    case playerEliminated(PlayerID)
    case gameOver(GameOutcome)
    /// A tech's Insight fired for `player` (M2 §6.2): `credit` science toward it.
    case insightGained(player: PlayerID, tech: TechID, credit: Int)
    /// The world entered era `era` (an index into the rules' eras, M2 §2).
    case worldEraAdvanced(era: Int)
    /// A unit upgraded in place (M2 §8.2).
    case unitUpgraded(unit: UnitID, from: UnitType, to: UnitType, owner: PlayerID, at: HexCoord)
    /// A unit took a promotion (M2 §8.3).
    case unitPromoted(unit: UnitID, promotion: String, owner: PlayerID, at: HexCoord)
    /// A road was built (M2 §3.3).
    case roadBuilt(at: HexCoord, owner: PlayerID)
    /// `unit` of `by` pillaged the tile of `owner` at `at` (M2 §3.3): `improvement` (nil: the
    /// road), with `gold` or `healed` HP to the pillager.
    case tilePillaged(at: HexCoord, unit: UnitID, by: PlayerID, owner: PlayerID?, improvement: Improvement?, gold: Int, healed: Int)
    case phaseStarted(turn: Int, player: PlayerID)
}

/// A `GameEvent` and the players who may see it, fixed when it is emitted (M1 §12.5). The
/// renderer, toasts and the attention queue use only records whose audience includes the viewer.
///
/// Audiences: tile events → players for whom a tile the event names is visible before or after
/// the command; production and research → the owner; disbanding and a tribal village taken →
/// the owner (the taker) and tile viewers; a tribal village's gift → the taker only; diplomacy →
/// both parties; war declared → everyone who has met either side; phases, elimination and game
/// over → everyone. Records come in the order the rules ran (units by id, then cities by id
/// within each step).
public struct EventRecord: Hashable, Sendable, Codable {
    public var event: GameEvent
    /// Player bitmask: bit n set means `PlayerID(n)` may see the event.
    public var audience: UInt16

    /// Every player.
    public static let everyone: UInt16 = 0xFFFF

    public init(_ event: GameEvent, audience: UInt16) {
        self.event = event
        self.audience = audience
    }

    public func isVisible(to player: PlayerID) -> Bool {
        guard (0..<16).contains(player.rawValue) else { return audience == Self.everyone }
        return audience & (UInt16(1) << player.rawValue) != 0
    }
}

public enum GameEngine {
    /// Validates and applies `command` for `player`, who must be the current player, and
    /// returns its events. A rejected command leaves the state unchanged (except that a
    /// rejected `foundCity` writes the city in the way into the player's memory, M1 §5).
    @discardableResult
    public static func apply(_ command: Command, by player: PlayerID, to state: inout GameState) throws(CommandError) -> [EventRecord] {
        guard state.outcome == nil else { throw .gameOver }
        guard player == state.currentPlayer else { throw .notYourTurn }
        return try perform(command, by: player, on: &state)
    }

    /// Applies a command without the phase check (debug tools only).
    static func perform(_ command: Command, by player: PlayerID, on state: inout GameState) throws(CommandError) -> [EventRecord] {
        guard state.players.indices.contains(player.rawValue), state.players[player.rawValue].isAlive else {
            throw .rejected(reason: "no such player")
        }
        let before = state.players.map(\.visible)
        var fx = Effects()

        switch command {
        case let .moveUnit(id, destination):
            let unit = try ownedUnit(id, by: player, in: state)
            if unit.zocStopped { throw .zoneOfControl }
            guard let path = Pathfinder.findPath(for: unit, to: destination, in: state) else { throw .noPath }
            state.updateUnit(id) { $0.activity = .none }
            state.executeMove(id, along: path, &fx)

        case let .cancelOrders(id):
            _ = try ownedUnit(id, by: player, in: state)
            state.updateUnit(id) { $0.destination = nil }

        case .endTurn:
            state.endPhase(&fx)

        case let .foundCity(id):
            let unit = try ownedUnit(id, by: player, in: state)
            guard state.rules.unit(unit.type).foundsCity else { throw .rejected(reason: "only Settlers found cities") }
            let t = state.map.index(of: unit.position)!
            if let problem = state.foundingProblem(at: t, by: player) {
                // The reason never names a city; a city in the way becomes known.
                let minimum = state.rules.constants.city.minDistance
                for city in state.cities where state.map.distance(city.position, unit.position) < minimum {
                    state.remember(city, by: player)
                }
                throw .rejected(reason: problem)
            }
            state.removeUnit(id)
            state.foundCity(at: t, by: player, &fx)

        case let .buildImprovement(id, improvement):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = state.improvementProblem(improvement, by: unit) { throw .rejected(reason: problem) }
            state.buildImprovement(improvement, by: id, &fx)

        case let .fortify(id):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = activityProblem(.fortify, unit) { throw .rejected(reason: problem) }
            state.updateUnit(id) { u in
                u.activity = .fortifying
                u.destination = nil
            }

        case let .sleep(id):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = activityProblem(.sleep, unit) { throw .rejected(reason: problem) }
            state.updateUnit(id) { u in
                u.activity = .sleeping
                u.destination = nil
            }

        case let .wake(id):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = activityProblem(.wake, unit) { throw .rejected(reason: problem) }
            state.updateUnit(id) { $0.activity = .none }

        case let .skip(id):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = activityProblem(.skip, unit) { throw .rejected(reason: problem) }
            state.updateUnit(id) { $0.activity = .skipped }

        case let .disband(id):
            _ = try ownedUnit(id, by: player, in: state)
            state.disband(id, upkeep: false, &fx)

        case let .setQueue(cityID, items):
            let index = try ownedCity(cityID, by: player, in: state)
            if let problem = queueProblem(items, in: state.cities[index], state) { throw .rejected(reason: problem) }
            state.setQueue(ofCity: index, to: items)

        case let .purchase(cityID, item):
            let index = try ownedCity(cityID, by: player, in: state)
            let city = state.cities[index]
            if case .quarter = item { throw .rejected(reason: "quarters cannot be bought") }
            if let problem = state.itemProblem(item, in: city) ?? state.completionProblem(item, in: city) {
                throw .rejected(reason: problem)
            }
            let price = state.purchasePrice(of: item)
            guard state.players[player.rawValue].gold >= price else { throw .rejected(reason: "needs \(price) gold") }
            state.purchase(item, inCity: index, price: price, &fx)

        case let .setFocus(cityID, focus):
            let index = try ownedCity(cityID, by: player, in: state)
            state.cities[index].focus = focus
            state.assignCitizens(index)

        case let .setResearch(tech):
            guard state.rules.tech(tech) != nil else { throw .rejected(reason: "no such tech") }
            guard !state.players[player.rawValue].knows(tech) else { throw .rejected(reason: "already known") }
            state.setResearch(tech, for: player)

        case let .attack(id, target):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = state.attackerProblem(unit) { throw .rejected(reason: problem) }
            guard let t = state.map.index(of: target) else { throw .rejected(reason: "no enemy there") }
            let defender: CombatSide
            switch state.attackTarget(at: t, by: player) {
            case let .problem(problem): throw .rejected(reason: problem)
            case let .target(side): defender = side
            }
            let from = state.map.index(of: unit.position)!
            if let problem = state.attackReachProblem(unit, from: from, at: t, against: defender) {
                throw .rejected(reason: problem)
            }
            state.attack(with: id, at: t, against: defender, &fx)

        case let .cityAttack(cityID, target):
            let index = try ownedCity(cityID, by: player, in: state)
            guard !state.cities[index].bombarded else { throw .rejected(reason: "already bombarded this turn") }
            guard let t = state.map.index(of: target) else { throw .rejected(reason: "no enemy there") }
            let defender: CombatSide
            switch state.attackTarget(at: t, by: player) {
            case let .problem(problem): throw .rejected(reason: problem)
            case let .target(side): defender = side
            }
            let centre = state.map.index(of: state.cities[index].position)!
            guard state.map.distance(index: centre, t) <= state.rules.constants.city.bombardRange else {
                throw .rejected(reason: "target out of range")
            }
            state.bombard(fromCity: index, at: t, against: defender, &fx)

        case let .declareWar(other):
            if let problem = state.warProblem(player, on: other) { throw .rejected(reason: problem) }
            state.declareWar(player, on: other, &fx)

        case let .proposePeace(other):
            if let problem = state.proposalProblem(player, to: other) { throw .rejected(reason: problem) }
            state.proposePeace(player, to: other, &fx)

        case let .respondToPeace(proposer, accept):
            if let problem = state.responseProblem(player, to: proposer) { throw .rejected(reason: problem) }
            state.respondToPeace(player, from: proposer, accept: accept, &fx)

        case let .razeCity(cityID):
            let index = try ownedCity(cityID, by: player, in: state)
            if let problem = state.razeProblem(index) { throw .rejected(reason: problem) }
            state.raze(index, &fx)

        case let .upgrade(id):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = state.upgradeProblem(unit) { throw .rejected(reason: problem) }
            state.upgrade(id, &fx)

        case let .promote(id, promotion):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = state.promoteProblem(unit, promotion) { throw .rejected(reason: problem) }
            state.promote(id, promotion, &fx)

        case let .buildRoad(id):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = state.roadProblem(unit) { throw .rejected(reason: problem) }
            state.buildRoad(by: id, &fx)

        case let .pillage(id):
            let unit = try ownedUnit(id, by: player, in: state)
            if let problem = state.pillageProblem(unit) { throw .rejected(reason: problem) }
            state.pillage(by: id, &fx)
        }

        state.checkInsights(&fx)
        state.finishCommand(&fx)
        return fx.records(before: before, after: state)
    }

    /// The player's own unit `id`. Another player's unit is `notYourUnit` only when the player
    /// sees it now or remembers a sighting of it; otherwise the refusal is `unknownUnit`, exactly
    /// as for an id that does not exist, so probing ids reveals no hidden unit (M1 §11).
    static func ownedUnit(_ id: UnitID, by player: PlayerID, in state: GameState) throws(CommandError) -> Unit {
        let unit = state.unit(id)
        if let unit, unit.owner == player { return unit }
        let me = state.players[player.rawValue]
        let seen = unit.map { me.visible[state.map.index(of: $0.position)!] } ?? false
        if seen || me.memory.unit(id) != nil { throw .notYourUnit(id) }
        throw .unknownUnit(id)
    }

    /// The index of the player's own city `id`. Another player's city is `notYourCity` only when
    /// the player knows it (its memory holds the city); otherwise the refusal is `unknownCity`,
    /// as for an id that does not exist, so probing ids reveals no unseen city (M1 §11).
    static func ownedCity(_ id: CityID, by player: PlayerID, in state: GameState) throws(CommandError) -> Int {
        let index = state.cityIndex(id)
        if let index, state.cities[index].owner == player { return index }
        if state.players[player.rawValue].memory.city(id) != nil { throw .notYourCity(id) }
        throw .unknownCity(id)
    }

    enum ActivityCommand { case fortify, sleep, wake, skip }

    /// Why a unit may not take up an activity now (M1 §7.4).
    static func activityProblem(_ command: ActivityCommand, _ unit: Unit) -> String? {
        switch command {
        case .fortify:
            if unit.type.isCivilian { return "civilians cannot fortify" }
            if unit.activity == .fortifying || unit.activity == .fortified { return "already fortified" }
        case .sleep:
            if unit.activity == .sleeping { return "already asleep" }
        case .wake:
            if ![.sleeping, .fortifying, .fortified].contains(unit.activity) { return "not asleep or fortified" }
        case .skip:
            if unit.activity != .none { return "already has an activity" }
        }
        return nil
    }

    /// Why a queue may not be set (M1 §5): at most `maxQueue` items, each available, no
    /// building twice.
    static func queueProblem(_ items: [ProductionItem], in city: City, _ state: GameState) -> String? {
        let max = state.rules.constants.production.maxQueue
        if items.count > max { return "at most \(max) items" }
        for (i, item) in items.enumerated() {
            if let problem = state.itemProblem(item, in: city) {
                return "\(state.itemName(item)): \(problem)"
            }
            if case .building = item, items[..<i].contains(item) { return "\(state.itemName(item)) is queued twice" }
            if case let .quarter(kind, at) = item {
                for case let .quarter(k, a) in items[..<i] {
                    if k == kind { return "\(state.itemName(item)) is queued twice" }
                    if a == at { return "two quarters queued on one tile" }
                }
            }
        }
        let quarters = items.compactMap { item -> QuarterKind? in
            if case let .quarter(kind, _) = item, state.countsTowardCap(kind) { return kind }
            return nil
        }
        if !quarters.isEmpty, state.cappedQuarterCount(city) + quarters.count > state.quarterCap(of: city) {
            return "at most \(state.quarterCap(of: city)) quarters at population \(city.population)"
        }
        return nil
    }
}

extension GameState {
    /// A display name for a production item.
    public func itemName(_ item: ProductionItem) -> String {
        switch item {
        case let .unit(type): type.displayName
        case let .building(id): rules.building(id)?.name ?? id.rawValue
        case let .quarter(kind, _): rules.quarter(kind)?.name ?? kind.rawValue
        }
    }
}
