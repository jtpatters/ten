import GameCore
import Observation
import SwiftUI

// Notifications (M1 §16): the events the viewer may see become notices. Most are quiet (the map
// already shows moves, blows and borders); the rest show as a calm toast: one small card at a
// time with up to three lines, notices of a kind merged into one line ("3 cities grew"), new
// ones joining a card that has just appeared, and the next card only after a pause. Important
// notices also go to `NoticeCenter.onImportant`, the attention queue's hook.

/// Something the viewer should hear about, made from events they may see.
struct Notice: Identifiable, Equatable, Codable, Sendable {
    enum Importance: Int, Comparable, Codable, Sendable {
        /// Not shown: the map already says it (moves, blows, borders, the viewer's own acts).
        case quiet
        /// A toast line.
        case info
        /// A toast line, and the attention queue's hook (`NoticeCenter.onImportant`).
        case important
        /// A toast line in the danger tone that stays longer, and the hook: war declared on the
        /// viewer, a city lost.
        case alarm

        static func < (a: Importance, b: Importance) -> Bool { a.rawValue < b.rawValue }
    }

    enum Tone: Codable, Sendable {
        case neutral, good, bad
    }

    /// What it is about, so the attention queue (and a tap on the toast) can act on it.
    enum Subject: Equatable, Codable, Sendable {
        case city(CityID)
        case unit(UnitID)
        case player(PlayerID)
        case tech(TechID)
        case civic(CivicID)
    }

    /// Notices of one kind merge into one line.
    enum Kind: String, Codable, Sendable {
        /// The Explore order's own (GameSession+Explore.swift): an order that ended, a good city site found. No summary:
        /// a line per explorer.
        case explore
        case production, growth, starving, research, met, warOnViewer, war, peaceProposal, peace, peaceDeclined,
             cityFounded, cityCaptured, cityLost, cityTaken, cityRazed, cityRevolted, cityJoined, cityAttacked, unitLost, unitCaptured,
             captured, enemyFell, upkeep, moveInterrupted, eliminated, unitAttacked, evicted, troopsNear, cityDiscovered
        /// A Settler's march ended where it can found a city (SettlerNotices.swift).
        case settlerArrived
        /// Tribal villages the viewer has come to know (M1 §7.7): "Tribal village spotted 5 tiles
        /// north-east of Rome"; `count` is how many (`TribalVillageText`).
        case tribalVillageSeen
        /// A gift from the villagers: "Your Scout reached a tribal village: +50 Gold". No summary:
        /// a line per gift.
        case tribalVillageGift
        /// A tribal village the viewer knew of is gone: a rival reached it first (a toast line),
        /// or it was found gone (quiet: the log only, `NoticeCenter.logsQuietly`).
        case tribalVillageGone
        /// M2 §6.2, §8: an Insight's credit, the world entering an era, an own unit upgraded or
        /// promoted.
        case insight, worldEra, upgraded, promoted
        /// M2 §7.1, §4.3: a civic completed, an envoy token earned.
        case civic, envoy
        /// M2 §11, §12, §13: raider camps, sacks and rebels; minor factions; trade routes.
        case raiders, minor, trade
    }

    /// Set by `NoticeCenter.post` (0 before).
    var id = 0
    var kind: Kind
    var text: String
    var systemImage: String
    var tone: Tone = .neutral
    var importance: Importance = .info
    /// Where it happened (a tap on the toast looks there).
    var place: HexCoord?
    var subject: Subject?
    var turn: Int
    /// How many notices this line stands for.
    var count = 1
    /// Blows on an own unit (`unitAttacked`): what merges notices about one unit.
    var damage: DamageReport?
    /// A lost unit's blows before the one that destroyed it (`unitLost`): taken earlier in the
    /// same events, or kept from the item of blows its loss replaced in the attention queue.
    var before: DamageReport?

    static func == (a: Notice, b: Notice) -> Bool {
        a.id == b.id && a.text == b.text && a.count == b.count
    }

    /// This line standing for `other` too: "3 cities grew", or the first line "and 2 more". A
    /// sighting of tribal villages keeps the rule when the later line has it ("3 tribal villages
    /// spotted · first to arrive gets a gift"), so it goes once a gift has come.
    mutating func absorb(_ other: Notice) {
        let rule = kind == .tribalVillageSeen && other.text.hasSuffix(TribalVillageText.rule)
        count += other.count
        importance = max(importance, other.importance)
        if other.tone == .bad { tone = .bad }
        if place == nil { place = other.place }
        text = Self.summary(kind, count: count).map { $0 + (rule ? TribalVillageText.rule : "") } ?? text
    }

    /// Whether `other` says what this line says: the same kind, subject and words. Tribal
    /// villages (p3g review): a sighting never does (each is of tribal villages not seen before,
    /// so sightings always sum, `absorb`), and a gift or a rival's take does only at the same
    /// place (two Gold gifts in one walk, or two takes "west of Rome", are two lines).
    func isSameNews(as other: Notice) -> Bool {
        guard kind == other.kind, subject == other.subject, text == other.text else { return false }
        switch kind {
        case .tribalVillageSeen: return false
        case .tribalVillageGift, .tribalVillageGone: return place == other.place
        default: return true
        }
    }

    /// This notice of blows on a unit standing for later blows on it too: "Your Archer was
    /// attacked 2 times (−84, 16 HP left)", where the unit stands now.
    mutating func absorbBlows(_ later: Notice) {
        guard let report = damage, let next = later.damage, report.unit == next.unit else { return }
        let merged = report.merged(with: next)
        damage = merged
        text = merged.text
        count += later.count
        place = later.place ?? place
    }

    /// This loss (`unitLost`) taking the place of the item of blows on its unit (`unitAttacked`)
    /// in the attention queue: one item per unit, which keeps those blows as what came before.
    mutating func absorbEarlierBlows(_ item: Notice) {
        guard let report = item.damage else { return }
        before = before.map { report.merged(with: $0) } ?? report
        count += item.count
    }

    /// The line for several notices of a kind, or nil to keep the first.
    static func summary(_ kind: Kind, count n: Int) -> String? {
        switch kind {
        case .production: "\(n) cities finished production"
        case .growth: "\(n) cities grew"
        case .starving: "\(n) cities are starving"
        case .cityAttacked: "\(n) cities are under attack"
        case .unitLost: "\(n) of your units were lost"
        case .unitCaptured: "\(n) of your civilians were captured"
        case .captured: "Captured \(n) civilians"
        case .enemyFell: "\(n) enemy units destroyed"
        case .upkeep: "\(n) units disbanded: no gold for upkeep"
        case .moveInterrupted: "\(n) marches stopped short"
        case .evicted: "\(n) units left land closed to them"
        case .met: "Met \(n) civilisations"
        case .cityFounded: "\(n) cities founded nearby"
        case .cityDiscovered: "Discovered \(n) foreign cities"
        case .tribalVillageSeen: "\(n) tribal villages spotted"
        default: nil
        }
    }
}

// MARK: - Events to notices

/// What the viewer knew of units just before a batch of events (the session keeps it from one
/// state change to the next): what the events alone no longer say afterwards. A captured unit's
/// type (the event names the type it becomes), a wounded unit's HP before the blows, a march's
/// goal once a stopped march has lost its order. Own units in full; foreign units in sight by
/// type and owner only (their orders are hidden). And the cities it knew, so a foreign city
/// first seen can be named, and the tribal villages it knew, so a new one is named once and one
/// that left its memory is known to be gone.
struct UnitsBefore {
    struct Entry: Sendable {
        var type: UnitType
        var owner: PlayerID
        var hp: Int
        /// An own unit's march goal.
        var destination: HexCoord?
    }

    private var entries: [UnitID: Entry] = [:]
    /// The cities the viewer knew (own and foreign), by id; nil when not taken from a view.
    private(set) var cities: [CityID]?
    /// The tribal villages the viewer knew (`PlayerView.knownTribalVillages`); nil when not
    /// taken from a view.
    private(set) var knownTribalVillages: [Int32]?

    init() {}

    init(_ view: PlayerView) {
        for unit in view.visibleUnits {
            entries[unit.id] = Entry(type: unit.type, owner: unit.owner, hp: unit.hp,
                                     destination: unit.owner == view.player ? unit.destination : nil)
        }
        cities = view.knownCities.map(\.id)
        knownTribalVillages = view.knownTribalVillages
    }

    subscript(_ id: UnitID) -> Entry? { entries[id] }

    /// A march just ordered for an own unit: its goal from now on.
    mutating func noteGoal(_ goal: HexCoord, of id: UnitID) {
        entries[id]?.destination = goal
    }
}

/// Blows an own unit took (and lived through), for its notice: one blow names who struck, more
/// are counted; the HP is what was left right after them, and what it has now if it has healed
/// since (its owner's phase start).
struct DamageReport: Equatable, Codable, Sendable {
    var unit: UnitID
    var unitName: String
    var hits: Int
    var damage: Int
    var hpAfterBlows: Int
    var hpNow: Int
    /// For a single blow, who struck and how: "Avarga bombarded", "A Mongol Spearman attacked".
    var striker: String?

    var text: String {
        let numbers = "−\(damage), \(hpAfterBlows) HP left" + (hpNow > hpAfterBlows ? "; healed to \(hpNow)" : "")
        if hits == 1, let striker { return "\(striker) your \(unitName) (\(numbers))" }
        // A single blow from a striker out of sight names none.
        return "Your \(unitName) was attacked" + (hits == 1 ? "" : " \(hits) times") + " (\(numbers))"
    }

    func merged(with later: DamageReport) -> DamageReport {
        var report = self
        report.hits += later.hits
        report.damage += later.damage
        report.hpAfterBlows = later.hpAfterBlows
        report.hpNow = later.hpNow
        report.striker = nil
        return report
    }
}

/// Civilisations' names as the notices use them.
enum CivText {
    /// The adjective for a civilisation's people and things ("a Roman Spearman", "Mongol land"):
    /// the rules name civilisations only, so the M1 civs' adjectives live here; any other civ
    /// uses its name.
    static func adjective(_ civ: CivID, name: String) -> String {
        switch civ.rawValue {
        case "rome": "Roman"
        case "mongols": "Mongol"
        case "mali": "Malian"
        case "china": "Chinese"
        case "inca": "Inca"
        case "khmer": "Khmer"
        case "norse": "Norse"
        case "abbasid": "Abbasid"
        default: name
        }
    }

    /// The adjective of a player's civilisation.
    static func adjective(of player: PlayerID, in view: PlayerView, civName: (PlayerID) -> String) -> String {
        guard let civ = view.civ(of: player) else { return civName(player) }
        return adjective(civ, name: civName(player))
    }

    /// "a" or "an" before a word.
    static func article(_ word: String) -> String {
        word.first.map { "AEIOU".contains($0.uppercased()) } == true ? "an" : "a"
    }

    /// "Mongol envoys propose peace": civilisation names are singular (Rome) or plural
    /// (Mongols, Norse), so the line names the envoys instead of the civilisation.
    static func peaceProposal(from player: PlayerID, in view: PlayerView, civName: (PlayerID) -> String) -> String {
        "\(adjective(of: player, in: view, civName: civName)) envoys propose peace"
    }
}

/// Why a route or a march fails, as a sentence (M1 §16: a refusal says why), from
/// `PlayerView.routeRefusal`.
enum RouteText {
    /// The message for a route that cannot be planned: "Closed borders: your military may not
    /// enter Mongol land while at peace", "Cumae already holds a military unit".
    static func refusal(_ refusal: RouteRefusal?, unit: GameCore.Unit, goal: HexCoord, view: PlayerView,
                        civName: (PlayerID) -> String) -> String {
        func adjective(_ p: PlayerID) -> String { CivText.adjective(of: p, in: view, civName: civName) }
        switch refusal {
        case .impassable(.water)?: return "That tile is water: land units can't go there"
        case .impassable(.mountains)?: return "Mountains can't be crossed"
        case .impassable(.ice)?: return "Ice can't be crossed"
        case let .foreignCity(id)?:
            let city = view.knownCities.first { $0.id == id }
            let name = city?.name ?? "that city"
            // M1 §8.6: units never enter a foreign city tile except by capturing it.
            return city.map { view.isAtWar(with: $0.owner) } == true
                ? "\(name) is an enemy city: units enter it only by capturing it" : "Units may not enter \(name), a foreign city"
        case let .closedBorders(owner)?:
            return "Closed borders: your military may not enter \(adjective(owner)) land while at peace"
        case let .foreignUnit(owner, type)?:
            let who = "\(CivText.article(adjective(owner))) \(adjective(owner)) \(type.displayName)"
            return "\(who.prefix(1).uppercased() + who.dropFirst()) stands there"
        case let .ownUnitThere(type)?:
            let kind = type.isCivilian ? "civilian" : "military"
            if let city = view.knownCity(at: goal), city.owner == view.player {
                return "\(city.name) already holds a \(kind) unit (your \(type.displayName))"
            }
            return "Your \(type.displayName) holds that tile: one \(kind) unit per tile"
        case .noLandRoute?: return "No land route leads there, as far as you know"
        case let .closedBordersOnTheWay(owners)?:
            return "Every way there crosses \(lands(owners, adjective)), closed to your military while at peace"
        case .blocked?: return "The way there is blocked"
        case nil: return unit.position == goal ? "Already there" : "Can't reach that tile"
        }
    }

    /// A previewed route's length: "4 turns", or "about 4 turns · goal unexplored, may be water"
    /// when the plan rests on unexplored ground (the pathfinder counts it as land at one move
    /// each, M1 §8.6).
    static func length(of path: GameCore.Path, view: PlayerView) -> String {
        let turns = turnsText(max(path.turns, 1))
        switch view.routeFog(path) {
        case .goal?: return "about \(turns) · goal unexplored, may be water"
        case .way?: return "about \(turns) · through unexplored land"
        case nil: return turns
        }
    }

    /// A standing march, for the unit card: "Marching · 3 turns", "Marching · about 5 turns"
    /// over unexplored ground, or with no route left, why: "Marching · no route: its goal is
    /// water".
    static func march(unit: GameCore.Unit, goal: HexCoord, view: PlayerView, civName: (PlayerID) -> String) -> String {
        guard let path = view.path(for: unit.id, to: goal) else {
            return "Marching · no route: " + goalProblem(unit: unit, goal: goal, view: view, civName: civName)
        }
        let turns = turnsText(max(path.turns, 1))
        return "Marching · " + (view.routeFog(path) == nil ? turns : "about \(turns)")
    }

    /// Why a march stopped, after "<Unit>'s march stopped: ": from the unit now and its former
    /// goal, as the viewer knows them.
    static func interruption(unit: GameCore.Unit?, goal: HexCoord?, view: PlayerView, civName: (PlayerID) -> String) -> String {
        guard let unit else { return "the way was blocked" }
        if unit.zocStopped { return "an enemy unit next to it holds it there" }
        guard let goal else { return "the way was blocked" }
        return goalProblem(unit: unit, goal: goal, view: view, civName: civName)
    }

    /// Why an own unit has no route to its goal, as a clause ("its goal is water", "Avarga
    /// stands on its goal"), as the viewer knows it.
    static func goalProblem(unit: GameCore.Unit, goal: HexCoord, view: PlayerView, civName: (PlayerID) -> String) -> String {
        func adjective(_ p: PlayerID) -> String { CivText.adjective(of: p, in: view, civName: civName) }
        switch view.routeRefusal(for: unit.id, to: goal) {
        case .impassable(.water)?: return "its goal is water"
        case .impassable(.mountains)?: return "its goal is mountains"
        case .impassable(.ice)?: return "its goal is ice"
        case let .foreignCity(id)?: return "\(view.knownCities.first { $0.id == id }?.name ?? "a foreign city") stands on its goal"
        case let .closedBorders(owner)?: return "its goal is in \(adjective(owner)) land, closed to your military while at peace"
        case let .foreignUnit(owner, type)?:
            return "\(CivText.article(adjective(owner))) \(adjective(owner)) \(type.displayName) stands on its goal"
        case let .ownUnitThere(type)?: return "your \(type.displayName) holds its goal"
        case .noLandRoute?: return "no land route leads to its goal"
        case let .closedBordersOnTheWay(owners)?:
            return "every way to its goal crosses \(lands(owners, adjective)), closed to your military while at peace"
        case .blocked?: return "the way is blocked"
        case nil: return "the way was blocked (it can be sent again)"
        }
    }

    /// "Mongol land", "Mongol and Malian land", "foreign land".
    private static func lands(_ owners: [PlayerID], _ adjective: (PlayerID) -> String) -> String {
        owners.isEmpty ? "foreign land" : owners.map(adjective).joined(separator: " and ") + " land"
    }
}

/// Turns event records the viewer may see into notices (pure: everything comes from the
/// viewer's `PlayerView`, the records, and what the viewer knew of units before them).
enum NoticeMaker {
    /// How far from a known city a place may be for a notice to name it after the city ("near
    /// Rome").
    static let nearRadius = 4

    /// - Parameters:
    ///   - records: records the viewer may see, in order.
    ///   - view: the viewer's knowledge after them.
    ///   - viewerActed: they come from the viewer's own command (its own deeds stay quiet).
    ///   - before: what the viewer knew of units before them.
    ///   - exploring: the viewer's units on the Explore order (a gift one of them found is not
    ///     the viewer's own tap, even in an Explore leg the viewer's session applied).
    ///   - civName: a player's civilisation name.
    static func notices(for records: [EventRecord], view: PlayerView, viewerActed: Bool, before: UnitsBefore = UnitsBefore(),
                        exploring: [UnitID] = [], civName: (PlayerID) -> String) -> [Notice] {
        let me = view.player
        let turn = view.turn
        var out: [Notice] = []
        func add(_ kind: Notice.Kind, _ text: String, _ image: String, tone: Notice.Tone = .neutral,
                 importance: Notice.Importance = .info, place: HexCoord? = nil, subject: Notice.Subject? = nil) {
            out.append(Notice(kind: kind, text: text, systemImage: image, tone: tone, importance: importance, place: place,
                              subject: subject, turn: turn))
        }
        func cityName(_ id: CityID) -> String {
            view.city(id)?.name ?? view.knownCities.first { $0.id == id }?.name ?? "A city"
        }
        func adjective(_ player: PlayerID) -> String { CivText.adjective(of: player, in: view, civName: civName) }
        func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        /// A foreign unit that struck: in sight now, or seen just before the events.
        func attackerSeen(_ id: UnitID) -> (type: UnitType, owner: PlayerID)? {
            view.unit(id).map { ($0.type, $0.owner) } ?? before[id].map { ($0.type, $0.owner) }
        }
        /// Who struck a blow and how: "Avarga bombarded", "A Mongol Spearman attacked" (nil: a
        /// unit out of sight).
        func striker(_ attacker: Combatant, ranged: Bool) -> String? {
            switch attacker {
            case let .city(id):
                return "\(cityName(id)) bombarded"
            case let .unit(id):
                guard let (type, owner) = attackerSeen(id) else { return nil }
                let who = adjective(owner)
                return capitalized("\(CivText.article(who)) \(who) \(type.displayName) ") + (ranged ? "shot at" : "attacked")
            }
        }
        /// " near Rome", " in Rome": the known city on or nearest a tile, within a few tiles.
        func placeName(_ hex: HexCoord) -> String {
            guard let city = view.nearestKnownCity(to: hex, within: Self.nearRadius) else { return "" }
            return city.position == hex ? " in \(city.name)" : " near \(city.name)"
        }

        // Own units destroyed in other players' phases, each with the blow that destroyed it.
        var losses: [Int: UnitLoss] = [:]
        if !viewerActed {
            for loss in view.unitLosses(in: records) { losses[loss.record] = loss }
        }
        /// "A Roman Spearman destroyed your Archer near Rome", "Rome's bombard destroyed your
        /// Warrior", or with the killer out of sight (or none: a garrison when its city fell)
        /// "Your Warrior was destroyed in Rome".
        func lossText(_ loss: UnitLoss?, type: UnitType, at: HexCoord) -> String {
            switch loss?.killer {
            case let .city(id)?:
                return "\(cityName(id))'s bombard destroyed your \(type.displayName)"
            case let .unit(id)?:
                if let (killer, owner) = attackerSeen(id) {
                    let who = adjective(owner)
                    return capitalized("\(CivText.article(who)) \(who) \(killer.displayName) destroyed your \(type.displayName)")
                        + placeName(at)
                }
            case nil:
                break
            }
            return "Your \(type.displayName) was destroyed" + placeName(at)
        }
        /// The blows a lost unit took before the one that destroyed it, in the same events (nil
        /// for none, or when its HP before them is not known).
        func earlierBlows(_ loss: UnitLoss) -> DamageReport? {
            guard !loss.earlierAttackers.isEmpty, let hp = before[loss.unit]?.hp else { return nil }
            let left = max(1, hp - loss.earlierDamage)
            return DamageReport(unit: loss.unit, unitName: loss.type.displayName, hits: loss.earlierAttackers.count,
                                damage: loss.earlierDamage, hpAfterBlows: left, hpNow: left,
                                striker: loss.earlierAttackers.count == 1 ? striker(loss.earlierAttackers[0], ranged: loss.earlierRanged[0]) : nil)
        }

        // A unit's population cost is not hunger (M1 §5): its city's shrink goes with the
        // completion ("finished a Settler (population now 1)"); a real starvation still alarms.
        let costs = view.populationCosts(in: records)
        let paidShrinks = Set(costs.map(\.shrink))
        var populationAfter: [Int: Int] = [:]
        for cost in costs { populationAfter[cost.completion] = cost.population }

        for (index, record) in records.enumerated() {
            switch record.event {
            case let .productionCompleted(city, item, at):
                let population = populationAfter[index].map { " (population now \($0))" } ?? ""
                add(.production, "\(cityName(city)) finished \(ItemName.withArticle(item, rules: view.rules))\(population)", "hammer.fill",
                    place: at, subject: .city(city))

            case let .techResearched(player, tech) where player == me:
                let name = view.rules.tech(tech)?.name ?? tech.rawValue
                let unlocks = view.unlocks(of: tech)
                let text = unlocks.isEmpty ? "Researched \(name)" : "Researched \(name): \(unlocks.joined(separator: ", "))"
                add(.research, text, "flask.fill", tone: .good, importance: .important, subject: .tech(tech))

            case let .cityGrew(city, population, at) where view.city(city) != nil:
                add(.growth, "\(cityName(city)) grew to \(population)", "person.2.fill", tone: .good, place: at, subject: .city(city))

            case let .cityShrank(city, population, at) where view.city(city) != nil && !paidShrinks.contains(index):
                add(.starving, "\(cityName(city)) is starving: it shrank to \(population)", "leaf.fill", tone: .bad,
                    importance: .important, place: at, subject: .city(city))

            case let .playersMet(a, b) where a == me || b == me:
                let other = a == me ? b : a
                let leader = view.players.first { $0.id == other }.flatMap { view.rules.civ($0.civ)?.leader }
                add(.met, "Met \(civName(other))" + (leader.map { ", led by \($0)" } ?? ""), "hand.wave.fill",
                    place: firstContact(with: other, view), subject: .player(other))

            case let .warDeclared(by, on):
                if on == me {
                    add(.warOnViewer, "\(civName(by)) declared war on you!", "flame.fill", tone: .bad, importance: .alarm,
                        subject: .player(by))
                } else if by != me {
                    add(.war, "\(civName(by)) declared war on \(civName(on))", "flame", subject: .player(by))
                }

            case let .peaceProposed(from, to) where to == me:
                add(.peaceProposal, CivText.peaceProposal(from: from, in: view, civName: civName), "envelope.fill",
                    importance: .important, subject: .player(from))

            case let .peaceSigned(a, b):
                if a == me || b == me {
                    // Who proposed (the viewer accepting is its own deed), how long the treaty
                    // binds (M1 §9), and the other side's capital as known to look at. Names
                    // may be plural ("Mongols"): the adjective stands in for a possessive.
                    let other = a == me ? b : a
                    let accepted = viewerActed ? "You accepted the \(adjective(other)) peace proposal" : "\(civName(other)) accepted your peace proposal"
                    let holds = view.relation(with: other)?.since.map { ": peace until at least turn \($0 + view.rules.constants.diplomacy.warAfterPeaceTurns)" }
                    let capital = view.knownCities.first { $0.owner == other && $0.capital }
                    add(.peace, accepted + (holds ?? ""), "leaf.arrow.triangle.circlepath", tone: .good,
                        importance: .important, place: capital?.position, subject: .player(other))
                } else {
                    add(.peace, "\(civName(a)) and \(civName(b)) made peace", "leaf.arrow.triangle.circlepath",
                        subject: .player(a))
                }

            case let .peaceDeclined(proposer, by) where proposer == me:
                add(.peaceDeclined, "\(civName(by)) declined peace", "xmark.seal", tone: .bad, subject: .player(by))

            case let .cityFounded(city, name, owner, at) where owner != me:
                add(.cityFounded, "\(civName(owner)) founded \(name)", "building.columns", place: at, subject: .city(city))

            case let .cityCaptured(city, name, from, to, at):
                if to == me {
                    add(.cityTaken, "You took \(name)!", "flag.fill", tone: .good, importance: .important, place: at,
                        subject: .city(city))
                } else if from == me {
                    add(.cityLost, "\(civName(to)) captured \(name)!", "flag.slash.fill", tone: .bad, importance: .alarm,
                        place: at, subject: .city(city))
                } else {
                    add(.cityCaptured, "\(civName(to)) captured \(name)", "flag", place: at, subject: .city(city))
                }

            case let .cityRevolted(city, name, from, _, at):
                // Loyalty 0 (M2 §5.5): the city leaves its civ and becomes a Free City.
                if from == me {
                    add(.cityRevolted, "\(name) revolted and became a Free City!", "flag.slash.fill", tone: .bad,
                        importance: .alarm, place: at, subject: .city(city))
                } else {
                    add(.cityRevolted, "\(name) revolted against \(civName(from)) and became a Free City", "flag.slash",
                        place: at, subject: .city(city))
                }

            case let .cityJoined(city, name, _, to, at):
                if to == me {
                    add(.cityJoined, "The Free City of \(name) joined you!", "flag.fill", tone: .good, importance: .important,
                        place: at, subject: .city(city))
                } else {
                    add(.cityJoined, "The Free City of \(name) joined \(civName(to))", "flag", place: at, subject: .city(city))
                }

            case let .cityRazed(city, name, owner, at) where owner != me:
                add(.cityRazed, "\(name) was razed", "flame", place: at, subject: .city(city))

            case let .combat(_, defender, _, to, _, _, _) where !viewerActed:
                // Blows on own units are summed per unit after the loop.
                if case let .city(id) = defender, view.city(id) != nil {
                    add(.cityAttacked, "\(cityName(id)) is under attack", "shield.lefthalf.filled", tone: .bad,
                        importance: .important, place: to, subject: .city(id))
                }

            case let .unitKilled(unit, type, owner, at):
                if owner == me {
                    // A loss in the viewer's own attack is on the map already.
                    if !viewerActed {
                        // Important, like a hit the unit survived (`unitAttacked`): a loss must not
                        // sink under growth lines in a busy toast. It names who destroyed it and
                        // where, and keeps the blows it took before.
                        let loss = losses[index]
                        add(.unitLost, lossText(loss, type: type, at: at), "xmark.shield.fill", tone: .bad,
                            importance: .important, place: at, subject: .unit(unit))
                        out[out.count - 1].before = loss.flatMap(earlierBlows)
                    }
                } else if !viewerActed, !type.isCivilian {
                    add(.enemyFell, "\(adjective(owner)) \(type.displayName) destroyed", "checkmark.shield.fill", tone: .good,
                        place: at, subject: .unit(unit))
                }

            case let .unitCaptured(old, new, type, from, to, at):
                // `type` is what the captive becomes; what it was, the viewer saw before.
                let was = before[old]?.type
                if from == me {
                    let lost = was.map { "Your \($0.displayName) was captured" } ?? "One of your civilians was captured"
                    add(.unitCaptured, lost, "person.fill.xmark", tone: .bad, importance: .important, place: at)
                } else if to == me {
                    // The viewer's own capture too: a deed worth a line.
                    let whose = adjective(from)
                    let text = if let was, was != type {
                        "Captured \(CivText.article(whose)) \(whose) \(was.displayName): it is now your \(type.displayName)"
                    } else if let was {
                        "Captured \(CivText.article(whose)) \(whose) \(was.displayName)"
                    } else {
                        "Captured \(CivText.article(whose)) \(whose) civilian: it is now your \(type.displayName)"
                    }
                    add(.captured, text, "person.fill.checkmark", tone: .good, place: at, subject: .unit(new))
                }

            case let .unitDisbanded(unit, type, owner, at, upkeep) where owner == me && upkeep:
                add(.upkeep, "\(type.displayName) disbanded: no gold for upkeep", "circle.slash", tone: .bad,
                    importance: .important, place: at, subject: .unit(unit))

            case let .moveInterrupted(unit, at) where view.unit(unit)?.owner == me:
                // Also after the viewer's own move: the stop is news, and says why.
                let current = view.unit(unit)
                let goal = before[unit]?.destination
                let reason = RouteText.interruption(unit: current, goal: goal, view: view, civName: civName)
                add(.moveInterrupted, "\(current?.type.displayName ?? "A unit")'s march stopped: \(reason)", "exclamationmark.triangle",
                    place: goal ?? at, subject: .unit(unit))

            case let .insightGained(player, tech, credit) where player == me:
                let name = view.rules.tech(tech)?.name ?? tech.rawValue
                add(.insight, "Insight: +\(credit) Science toward \(name)", "lightbulb.fill", tone: .good, subject: .tech(tech))

            case let .civicInsightGained(player, civic, credit) where player == me:
                let name = view.rules.civic(civic)?.name ?? civic.rawValue
                add(.insight, "Insight: +\(credit) Culture toward \(name)", "lightbulb.fill", tone: .good, subject: .civic(civic))

            case let .civicCompleted(player, civic) where player == me:
                let name = view.rules.civic(civic)?.name ?? civic.rawValue
                let unlocks = view.unlocks(of: civic)
                let text = unlocks.isEmpty ? "Completed \(name)" : "Completed \(name): \(unlocks.joined(separator: ", "))"
                add(.civic, text + ". Policies change free this turn", "theatermasks.fill", tone: .good, importance: .important,
                    subject: .civic(civic))

            case let .envoyEarned(player, tokens) where player == me:
                add(.envoy, tokens == 1 ? "Envoy token earned from Influence" : "\(tokens) envoy tokens earned from Influence",
                    "person.wave.2.fill", tone: .good)

            case let .raiderCampAppeared(at):
                add(.raiders, "A raider camp appeared", "tent.fill", tone: .bad, place: at)

            case let .raiderCampCleared(player, at, gold):
                if player == me {
                    add(.raiders, "You cleared a raider camp: +\(gold) Gold", "tent", tone: .good, importance: .important, place: at)
                } else {
                    add(.raiders, "\(civName(player)) cleared a raider camp", "tent", place: at)
                }

            case let .citySacked(city, _, gold, at):
                if view.city(city) != nil {
                    add(.raiders, "Raiders sacked \(cityName(city)): −\(gold) Gold", "flame.fill", tone: .bad, importance: .alarm,
                        place: at, subject: .city(city))
                } else {
                    add(.raiders, "Raiders sacked \(cityName(city))", "flame", place: at, subject: .city(city))
                }

            case let .rebelsRose(city, _, at) where view.city(city) != nil:
                add(.raiders, "Rebels rose in \(cityName(city))", "flame.fill", tone: .bad, importance: .important, place: at,
                    subject: .city(city))

            case let .envoySent(player, minor, envoys) where player == me:
                add(.envoy, "Envoy sent to \(civName(minor)): \(envoys) there now", "person.wave.2.fill", tone: .good,
                    subject: .player(minor))

            case let .patronChanged(minor, patron):
                if patron == me {
                    add(.minor, "You are now the Patron of \(civName(minor))", "crown.fill", tone: .good, importance: .important,
                        subject: .player(minor))
                } else if let patron {
                    add(.minor, "\(civName(patron)) is now the Patron of \(civName(minor))", "crown", subject: .player(minor))
                } else {
                    add(.minor, "\(civName(minor)) has no Patron now", "crown", subject: .player(minor))
                }

            case let .questCompleted(minor, player):
                if player == me {
                    add(.minor, "Quest for \(civName(minor)) completed: +1 envoy", "checkmark.seal.fill", tone: .good,
                        importance: .important, subject: .player(minor))
                } else {
                    add(.minor, "\(civName(player)) completed \(civName(minor))'s quest", "checkmark.seal", subject: .player(minor))
                }

            case let .levied(minor, player, units):
                if player == me {
                    add(.minor, "\(civName(minor))'s army serves you: \(units) \(units == 1 ? "unit" : "units")", "figure.2",
                        tone: .good, importance: .important, subject: .player(minor))
                } else {
                    add(.minor, "\(civName(player)) levied \(civName(minor))'s army", "figure.2", subject: .player(minor))
                }

            case let .levyEnded(minor, player) where player == me:
                add(.minor, "\(civName(minor))'s levied army went home", "figure.2", subject: .player(minor))

            case let .tradeRouteStarted(_, owner, from, to):
                if owner == me {
                    add(.trade, "Trade route from \(cityName(from)) to \(cityName(to)) started", "shippingbox.fill", tone: .good,
                        subject: .city(from))
                } else if view.city(to) != nil {
                    add(.trade, "\(CivText.article(adjective(owner)).capitalized) \(adjective(owner)) trade route to \(cityName(to)) started",
                        "shippingbox", subject: .city(to))
                }

            case let .tradeRouteEnded(_, owner, plunderedBy):
                if owner == me, let raider = plunderedBy {
                    add(.trade, "\(civName(raider)) plundered your trade route", "shippingbox", tone: .bad, importance: .important)
                } else if owner == me {
                    add(.trade, "A trade route ended; its Trader is home", "shippingbox")
                } else if plunderedBy == me {
                    add(.trade, "You plundered \(CivText.article(adjective(owner))) \(adjective(owner)) trade route", "shippingbox",
                        tone: .good)
                }

            case let .worldEraAdvanced(era):
                let name = view.rules.eras.indices.contains(era) ? "the \(view.rules.eras[era].name) Era" : "a new era"
                add(.worldEra, "The world enters \(name)", "globe.europe.africa.fill", importance: .important)

            case let .unitUpgraded(unit, from, to, owner, at) where owner == me:
                add(.upgraded, "Your \(from.displayName) was upgraded to \(CivText.article(to.displayName)) \(to.displayName)",
                    "arrow.up.circle.fill", tone: .good, place: at, subject: .unit(unit))

            case let .unitPromoted(unit, promotion, owner, at) where owner == me:
                let name = view.rules.promotions.first { $0.id == promotion }?.name ?? promotion
                let type = view.unit(unit)?.type.displayName ?? "unit"
                add(.promoted, "Your \(type) earned \(name)", "star.circle.fill", tone: .good, place: at, subject: .unit(unit))

            case let .playerEliminated(player) where player != me:
                add(.eliminated, "The \(adjective(player)) civilisation has fallen", "crown", importance: .important,
                    subject: .player(player))

            default:
                break
            }
        }

        if !viewerActed {
            // Blows on own units in other players' phases: one notice per unit that lived (a
            // death has its own), important, so it also joins the attention queue.
            for hurt in view.unitDamage(in: records) {
                let hpBefore = before[hurt.unit]?.hp
                let afterBlows = hpBefore.map { max(1, $0 - hurt.damage) } ?? hurt.hp
                let report = DamageReport(unit: hurt.unit, unitName: hurt.type.displayName, hits: hurt.attackers.count,
                                          damage: hurt.damage, hpAfterBlows: afterBlows, hpNow: hurt.hp,
                                          striker: hurt.attackers.count == 1 ? striker(hurt.attackers[0], ranged: hurt.ranged[0]) : nil)
                var notice = Notice(kind: .unitAttacked, text: report.text, systemImage: "bolt.shield.fill", tone: .bad,
                                    importance: .important, place: hurt.tile, subject: .unit(hurt.unit), turn: turn)
                notice.damage = report
                out.append(notice)
            }
            // Military units sent out of land closed to them (M1 §9).
            for eviction in view.evictions(in: records) {
                add(.evicted, "Your \(eviction.type.displayName) left \(adjective(eviction.owner)) land, closed to your military while at peace",
                    "arrow.uturn.backward", place: eviction.to, subject: .unit(eviction.unit))
            }
            // Settlers whose march ended, at the phase start, where they can found a city.
            out += settlerArrivals(in: records, view: view, before: before)
        }
        // Foreign cities first seen in these events (founded or taken in sight, they have their
        // own line): "Discovered Avarga (Mongols), 4 tiles from Antium".
        if let knew = before.cities {
            var named: [CityID] = []
            for record in records {
                switch record.event {
                case let .cityFounded(city, _, _, _), let .cityCaptured(city, _, _, _, _), let .cityRevolted(city, _, _, _, _),
                     let .cityJoined(city, _, _, _, _): named.append(city)
                default: break
                }
            }
            for city in view.knownCities where city.owner != me && !knew.contains(city.id) && !named.contains(city.id) {
                add(.cityDiscovered, discoveredText(city, view: view, civName: civName), "binoculars.fill", place: city.position,
                    subject: .city(city.id))
            }
        }
        // Tribal villages (M1 §7.7): own gifts, rivals' takes, new sightings, ones found gone.
        // Without a view taken before, nothing counts as new or gone.
        let knewVillages = before.knownTribalVillages ?? view.knownTribalVillages
        for news in view.tribalVillageNews(in: records, knownBefore: knewVillages, viewerActed: viewerActed, exploring: exploring) {
            out.append(TribalVillageText.notice(news, view: view, civName: civName))
        }
        return out
    }

    /// "Discovered Avarga (Mongols), 4 tiles from Antium": a foreign city first seen, with the
    /// nearest own city (ties: the lower id), if any.
    static func discoveredText(_ city: CitySighting, view: PlayerView, civName: (PlayerID) -> String) -> String {
        let text = "Discovered \(city.name) (\(civName(city.owner)))"
        let own = view.cities.min { (view.distance($0.position, city.position), $0.id.rawValue) < (view.distance($1.position, city.position), $1.id.rawValue) }
        guard let own else { return text }
        let d = view.distance(own.position, city.position)
        return text + ", \(d == 1 ? "1 tile" : "\(d) tiles") from \(own.name)"
    }

    /// Where the viewer met another player, as far as it can tell: the other's unit in sight or
    /// city it knows nearest to the viewer's capital (else its first city or unit), else the
    /// nearest tile of the other's land it knows; nil when it sees nothing of theirs (they saw the
    /// viewer first).
    static func firstContact(with other: PlayerID, _ view: PlayerView) -> HexCoord? {
        let anchor = view.me.capital.flatMap(view.city)?.position ?? view.cities.first?.position ?? view.units.first?.position
        let places = view.visibleForeignUnits.filter { $0.owner == other }.map(\.position)
            + view.knownCities.filter { $0.owner == other }.map(\.position)
        if !places.isEmpty {
            guard let anchor else { return places[0] }
            return places.enumerated().min { a, b in
                (view.distance(a.element, anchor), a.offset) < (view.distance(b.element, anchor), b.offset)
            }?.element
        }
        let code = UInt8(other.rawValue + 1)
        var best: (distance: Int, hex: HexCoord)?
        for (t, owner) in view.knownTerritory.enumerated() where owner == code {
            let hex = view.coord(at: t)
            let d = anchor.map { view.distance(hex, $0) } ?? 0
            if best.map({ d < $0.distance }) ?? true { best = (d, hex) }
        }
        return best?.hex
    }
}

// MARK: - Tribal villages

/// The tribal village notices' words (M1 §7.7; phase 3g design §6.2), from the facts of
/// `PlayerView.tribalVillageNews`: sightings, gifts, rivals' takes and ones found gone; and a
/// gift's float label over the map (`MapOverlay.showGift`).
enum TribalVillageText {
    /// What a sighting adds while the viewer has had no gift yet.
    static let rule = " · first to arrive gets a gift"
    static let symbol = "house.lodge"

    /// The notice of one piece of news:
    /// - a sighting: "Tribal village spotted 5 tiles north-east of Rome", "2 tribal villages
    ///   spotted" (`count` is how many), with the rule while no gift has come; info;
    /// - a gift: "Your Scout reached a tribal village: +50 Gold", "Antium's land took in a tribal
    ///   village: a Builder joins you"; important unless the viewer's own tap took it; its
    ///   subject the new Builder, else the taker;
    /// - a rival's take: "Mongols reached the tribal village west of Rome first" (civilisation
    ///   names stand alone, as in "Mongols declared war on you!"); info;
    /// - one found gone: "The tribal village north of Rome is gone"; quiet (the log only).
    static func notice(_ news: TribalVillageNews, view: PlayerView, civName: (PlayerID) -> String) -> Notice {
        let turn = view.turn
        switch news {
        case let .spotted(tiles, nearest):
            let place = nearest.text.isEmpty ? "" : " \(nearest.text)"
            let text = (tiles.count == 1 ? "Tribal village spotted\(place)" : "\(tiles.count) tribal villages spotted")
                + (view.tribalVillageGiftsReceived == 0 ? rule : "")
            var notice = Notice(kind: .tribalVillageSeen, text: text, systemImage: symbol, place: nearest.hex, turn: turn)
            notice.count = tiles.count
            return notice
        case let .gift(gift, at, taker, unit, city, cityName, byOwnTap):
            let who = if city != nil {
                "\(cityName ?? "Your city")'s land took in a tribal village"
            } else if let taker {
                "Your \(taker.displayName) reached a tribal village"
            } else {
                "You reached a tribal village"
            }
            let subject: Notice.Subject? = if case let .builder(id) = gift {
                .unit(id)
            } else if let unit {
                .unit(unit)
            } else {
                city.map { .city($0) }
            }
            return Notice(kind: .tribalVillageGift, text: "\(who): \(words(gift, view: view))", systemImage: "gift.fill", tone: .good,
                          importance: byOwnTap ? .info : .important, place: at, subject: subject, turn: turn)
        case let .reachedFirst(player, at, place):
            let way = place.direction.isEmpty ? "" : " \(place.direction)"
            return Notice(kind: .tribalVillageGone, text: "\(civName(player)) reached the tribal village\(way) first",
                          systemImage: symbol, place: at, subject: .player(player), turn: turn)
        case let .gone(hex, place):
            let way = place.direction.isEmpty ? "" : " \(place.direction)"
            return Notice(kind: .tribalVillageGone, text: "The tribal village\(way) is gone", systemImage: symbol, importance: .quiet,
                          place: hex, turn: turn)
        }
    }

    /// "+50 Gold", "+20 Science toward Pottery" ("+20 Science" with nothing being researched),
    /// "a Builder joins you".
    static func words(_ gift: TribalVillageGift, view: PlayerView) -> String {
        switch gift {
        case let .gold(amount): "+\(amount) Gold"
        case let .science(amount, toward?): "+\(amount) Science toward \(view.rules.tech(toward)?.name ?? toward.rawValue)"
        case let .science(amount, nil): "+\(amount) Science"
        case .builder: "a Builder joins you"
        }
    }

    /// The float label over the tribal village (`MapOverlay.showGift`): "+50 Gold", "+20
    /// Science", "+1 Builder".
    static func label(_ gift: TribalVillageGift) -> String {
        switch gift {
        case let .gold(amount): "+\(amount) Gold"
        case let .science(amount, _): "+\(amount) Science"
        case .builder: "+1 Builder"
        }
    }
}

// MARK: - Troops near cities

/// Foreign troops near the viewer's cities, for the notice at the start of its phase (M1 §16): an
/// army that gathers or marches in shows before it strikes. A city gets a notice when foreign
/// military units that were near none of the viewer's cities when it last looked (the end of its
/// phase) are near it now (`PlayerView.foreignMilitaryNear`: in sight, within 4 tiles, recon left
/// out, each unit counted at its nearest city), at most once every 5 turns. Troops already known
/// that shift from one city to the next say nothing again. Fair: it reads only what the viewer
/// sees.
struct TroopWatch {
    /// The phase (`phaseCount`) of the latest state change looked at; nil before the first.
    var phase: Int?
    /// The units near the viewer's cities when it last looked.
    private var known: Set<UnitID> = []
    /// The turn of each city's latest notice.
    private var noticed: [CityID: Int] = [:]

    static let radius = 4
    static let quietTurns = 5

    /// What is near now is known: no notice for it later.
    mutating func remember(_ near: [TroopsNear]) {
        known = Set(near.flatMap { $0.units.map(\.id) })
    }

    /// The notices for cities with troops that were near none of the viewer's cities when it
    /// last looked (then what is near now is known). At war with their owner a notice is
    /// important (it joins the attention queue as news), unless the city already has its own
    /// "under attack" item.
    mutating func notices(for near: [TroopsNear], view: PlayerView, underAttack: Set<CityID>,
                          civName: (PlayerID) -> String) -> [Notice] {
        var out: [Notice] = []
        for group in near {
            guard group.units.contains(where: { !known.contains($0.id) }),
                  noticed[group.city].map({ view.turn - $0 >= Self.quietTurns }) ?? true,
                  let city = view.city(group.city) else { continue }
            noticed[group.city] = view.turn
            var owners: [PlayerID] = []
            for unit in group.units where !owners.contains(unit.owner) { owners.append(unit.owner) }
            let atWar = owners.contains { view.isAtWar(with: $0) }
            out.append(Notice(kind: .troopsNear, text: Self.text(group, city: city.name, owners: owners, view: view, civName: civName),
                              systemImage: "binoculars.fill", tone: atWar ? .bad : .neutral,
                              importance: atWar && !underAttack.contains(group.city) ? .important : .info,
                              place: group.units.first?.position, subject: .city(group.city), turn: view.turn))
        }
        remember(near)
        return out
    }

    /// "Mongol Spearman near Antium", "Mongol troops near Antium (3 units)", "Mongol and Malian
    /// troops near Antium (4 units)".
    static func text(_ group: TroopsNear, city: String, owners: [PlayerID], view: PlayerView,
                     civName: (PlayerID) -> String) -> String {
        let names = owners.map { CivText.adjective(of: $0, in: view, civName: civName) }
        let whose = names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        if group.units.count == 1, let unit = group.units.first {
            return "\(whose) \(unit.type.displayName) near \(city)"
        }
        return "\(whose) troops near \(city) (\(group.units.count) units)"
    }
}

// MARK: - The toast queue

/// The notices on their way to the screen (M1 §16 "Notifications"), calm by design: one card
/// at a time with at most three lines, a kind's notices merged into one line, new notices
/// joining a card for its first moments, then a pause before the next card. Important ones
/// also reach `onImportant` (the attention queue's hook), in arrival order, and their card
/// waits for the viewer (`acknowledge`). The log's newest rows count as unread (`unread`).
@Observable
@MainActor
final class NoticeCenter {
    /// The toast on screen.
    struct Card: Identifiable, Equatable {
        var id: Int
        var lines: [Notice]
        /// Notices beyond the lines.
        var more: Int
        var isAlarm: Bool { lines.contains { $0.importance == .alarm } }
    }

    private(set) var card: Card?
    /// Every notice that was not quiet, newest last (at most `logLimit`): the session's event
    /// log, and what the attention queue may review.
    private(set) var log: [Notice] = []
    /// Called with each important or alarm notice as it arrives: the attention queue's hook.
    @ObservationIgnored var onImportant: ((Notice) -> Void)?
    /// What the troop notices remember between the viewer's phases (`TroopWatch`): they too
    /// keep the notices calm, at most one per city every few turns.
    @ObservationIgnored var troopWatch = TroopWatch()

    @ObservationIgnored private var pending: [Notice] = []
    @ObservationIgnored private var shownAt: ContinuousClock.Instant?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var nextID = 1
    /// The newest notice when the latest AI phase began (`markPhaseStart`): a save of that
    /// phase's start keeps the log up to there (`NoticeLogStore`).
    @ObservationIgnored private(set) var phaseStartID = 0
    /// The newest notice when the round began or the log was last open (`startUnreadCount`):
    /// the log's later rows are unread.
    private(set) var readThroughID = 0
    /// How long the important card on screen lasts once the viewer acknowledges it; nil when no
    /// card waits.
    @ObservationIgnored private var waitingCardDuration: Duration?

    static let maxLines = 3
    static let logLimit = 100

    /// A notice whose own card opens at once with the same line (a city taken: its Keep or
    /// Raze card): the log and the hook have it, but a toast would only repeat the card.
    static func opensItsOwnCard(_ kind: Notice.Kind) -> Bool { kind == .cityTaken }
    /// A quiet notice the log keeps all the same, with no toast: a remembered tribal village found
    /// gone (the map shows it gone; the log tells what became of it).
    static func logsQuietly(_ notice: Notice) -> Bool { notice.importance == .quiet && notice.kind == .tribalVillageGone }
    /// How long a new card takes in more notices.
    static let joinWindow: Duration = .milliseconds(1200)
    /// The pause between two cards.
    static let gap: Duration = .milliseconds(450)

    /// Queues notices (quiet ones only reach the log's caller, never the screen, and the log only
    /// when it keeps them, `logsQuietly`; nor does one whose own card opens with it reach the
    /// screen, `opensItsOwnCard`).
    func post(_ notices: [Notice]) {
        for var notice in notices where notice.importance > .quiet || Self.logsQuietly(notice) {
            notice.id = nextID
            nextID += 1
            log.append(notice)
            if notice.importance >= .important { onImportant?(notice) }
            if notice.importance > .quiet, !Self.opensItsOwnCard(notice.kind) { pending.append(notice) }
        }
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        guard !pending.isEmpty else { return }
        if let card, let shownAt, ContinuousClock.now - shownAt < Self.joinWindow || pending.contains(where: { $0.importance == .alarm }) && !card.isAlarm {
            // The card has just appeared (or an alarm cannot wait): the news joins it.
            show(Self.compose(card.lines + pending, more: card.more, id: card.id))
            pending.removeAll()
        } else if card == nil, timer == nil {
            showNext()
        }
    }

    /// Takes the card off the screen (a tap on it); the next one follows after the pause.
    func dismiss() {
        waitingCardDuration = nil
        card = nil
        shownAt = nil
        schedule(after: Self.gap) { $0.showNext() }
    }

    /// Puts back the log of a save being opened, oldest first (before anything is posted), with
    /// the newest of it read when it was saved (`readThrough`; nil: all of it).
    func restore(_ notices: [Notice], readThrough: Int? = nil) {
        log = Array(notices.suffix(Self.logLimit))
        nextID = max(nextID, (log.map(\.id).max() ?? 0) + 1)
        phaseStartID = nextID - 1
        readThroughID = min(readThrough ?? nextID - 1, nextID - 1)
    }

    /// An AI phase begins: a save of its start keeps the log as it is now.
    func markPhaseStart() {
        phaseStartID = nextID - 1
    }

    /// The newest notice a save made now covers (its log keeps those up to it): all so far, or
    /// for a save of the latest AI phase's start, those before that phase.
    func savedThrough(phaseStart: Bool) -> Int {
        phaseStart ? phaseStartID : nextID - 1
    }

    /// The log's rows posted since the round began and since the log was last open: the badge
    /// on the game menu and its Notices… entry.
    var unread: Int { log.reduce(0) { $0 + ($1.id > readThroughID ? 1 : 0) } }

    /// The unread count starts again from here: the other players' phases begin after the
    /// viewer's (a new round), or the log opens or closes.
    func startUnreadCount() {
        readThroughID = nextID - 1
    }

    /// Whether the card on screen waits for the viewer's first tap or Next.
    var cardWaits: Bool { waitingCardDuration != nil && card != nil }

    /// The viewer's first tap on the map, or Next: an important card waiting on screen goes
    /// once it has been there as long as any card would be.
    func acknowledge() {
        guard let duration = waitingCardDuration else { return }
        waitingCardDuration = nil
        let shown = shownAt.map { ContinuousClock.now - $0 } ?? duration
        schedule(after: max(.zero, duration - shown)) { center in
            center.card = nil
            center.shownAt = nil
            center.schedule(after: Self.gap) { $0.showNext() }
        }
    }

    /// Clears everything (the game closes).
    func reset() {
        timer?.cancel()
        timer = nil
        waitingCardDuration = nil
        card = nil
        pending.removeAll()
    }

    private func showNext() {
        timer = nil
        guard !pending.isEmpty else { return }
        show(Self.compose(pending, more: 0, id: nextID))
        nextID += 1
        pending.removeAll()
    }

    private func show(_ card: Card) {
        self.card = card
        shownAt = .now
        let lines = card.lines.count
        let seconds = card.isAlarm ? 5.0 : min(5.0, 2.6 + 0.8 * Double(lines - 1) + (card.more > 0 ? 0.6 : 0))
        // An important card stays until the viewer's first tap or Next (`acknowledge`).
        if card.lines.contains(where: { $0.importance >= .important }) {
            waitingCardDuration = .milliseconds(Int(seconds * 1000))
            timer?.cancel()
            timer = nil
            return
        }
        waitingCardDuration = nil
        schedule(after: .milliseconds(Int(seconds * 1000))) { center in
            center.card = nil
            center.shownAt = nil
            center.schedule(after: Self.gap) { $0.showNext() }
        }
    }

    private func schedule(after delay: Duration, _ action: @escaping @MainActor (NoticeCenter) -> Void) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    /// A card from notices: merged by kind, the most pressing first (then in order), at most
    /// `maxLines` lines, the rest counted.
    static func compose(_ notices: [Notice], more: Int, id: Int) -> Card {
        var lines: [Notice] = []
        for notice in notices where !lines.contains(where: { $0.id == notice.id }) {
            // Blows on one unit, batch after batch, are one line that sums them.
            if let unit = notice.damage?.unit, let i = lines.firstIndex(where: { $0.damage?.unit == unit }) {
                lines[i].absorbBlows(notice)
                continue
            }
            // The same news twice ("Rome is under attack" after each blow) is one line.
            if lines.contains(where: { $0.isSameNews(as: notice) }) { continue }
            // Kinds with a summary merge ("3 cities grew"); others keep a line each.
            if Notice.summary(notice.kind, count: 2) != nil, let i = lines.firstIndex(where: { $0.kind == notice.kind }) {
                lines[i].absorb(notice)
            } else {
                lines.append(notice)
            }
        }
        let ranked = lines.enumerated().sorted { a, b in
            a.element.importance != b.element.importance ? a.element.importance > b.element.importance : a.offset < b.offset
        }.map(\.element)
        let shown = Array(ranked.prefix(maxLines))
        let extra = ranked.dropFirst(maxLines).reduce(0) { $0 + $1.count }
        return Card(id: id, lines: shown, more: more + extra)
    }
}

// MARK: - The toast

/// The notice card under the top bar: a line per notice with its icon, the danger tone for
/// alarms. A tap looks at where the first line happened and dismisses the card.
struct NoticeToast: View {
    var card: NoticeCenter.Card
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: HUD.Space.xs) {
                ForEach(card.lines) { line in
                    HStack(spacing: HUD.Space.s) {
                        Image(systemName: line.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint(line.tone))
                            .frame(width: 18)
                        Text(line.text)
                            .font(HUD.body(.callout).weight(line.importance >= .important ? .semibold : .regular))
                            .foregroundStyle(line.importance == .alarm ? HUD.danger : HUD.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if card.more > 0 {
                    Text("and \(card.more) more")
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.inkSoft)
                        .padding(.leading, 26)
                }
            }
            .padding(.horizontal, HUD.Space.l)
            .padding(.vertical, HUD.Space.s + 2)
            .frame(minHeight: HUD.touch)
            .parchment(cornerRadius: HUD.Radius.large)
            .overlay {
                if card.isAlarm {
                    RoundedRectangle(cornerRadius: HUD.Radius.large, style: .continuous)
                        .stroke(HUD.danger.opacity(0.7), lineWidth: 2)
                        .padding(2)
                }
            }
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows where it happened.")
    }

    private func tint(_ tone: Notice.Tone) -> Color {
        switch tone {
        case .neutral: HUD.inkSoft
        case .good: HUD.good
        case .bad: HUD.danger
        }
    }
}
