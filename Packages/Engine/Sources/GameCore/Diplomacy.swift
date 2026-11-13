// Relations between players (M1 §9): meeting, war and peace, peace proposals with their
// cool-down, and closed borders at peace.

public enum Stance: String, Codable, Hashable, Sendable {
    case peace, war
}

/// The relation of a player pair `a < b`.
public struct Relation: Codable, Hashable, Sendable {
    public let a: PlayerID
    public let b: PlayerID
    /// One has seen the other's unit, city or territory.
    public var met: Bool
    public var stance: Stance
    /// The turn of the last stance change (nil = never changed).
    public var since: Int?
    /// A pending peace proposal and its proposer.
    public var proposalFrom: PlayerID?
    /// The first turn `a` may propose peace again (0 = no cool-down).
    public var aCooldownEnds: Int
    /// The first turn `b` may propose peace again (0 = no cool-down).
    public var bCooldownEnds: Int

    init(_ a: PlayerID, _ b: PlayerID) {
        precondition(a < b)
        self.a = a
        self.b = b
        self.met = false
        self.stance = .peace
        self.since = nil
        self.proposalFrom = nil
        self.aCooldownEnds = 0
        self.bCooldownEnds = 0
    }

    public func involves(_ p: PlayerID) -> Bool { a == p || b == p }

    /// The other player of the pair.
    public func other(than p: PlayerID) -> PlayerID { a == p ? b : a }
}

extension GameState {
    /// Index of the pair's relation (`a != b`, either order).
    func relationIndex(_ a: PlayerID, _ b: PlayerID) -> Int {
        let (i, j) = a < b ? (a.rawValue, b.rawValue) : (b.rawValue, a.rawValue)
        let n = players.count
        return i * (2 * n - i - 1) / 2 + (j - i - 1)
    }

    /// The relation between two different players.
    public func relation(_ a: PlayerID, _ b: PlayerID) -> Relation {
        relations[relationIndex(a, b)]
    }

    mutating func updateRelation(_ a: PlayerID, _ b: PlayerID, _ change: (inout Relation) -> Void) {
        change(&relations[relationIndex(a, b)])
    }

    public func isAtWar(_ a: PlayerID, _ b: PlayerID) -> Bool {
        a != b && relation(a, b).stance == .war
    }

    public func hasMet(_ a: PlayerID, _ b: PlayerID) -> Bool {
        a == b || relation(a, b).met
    }

    /// Whether `player`'s military units may not enter `owner`'s territory: closed borders at
    /// peace (M1 §9). Own territory is always open.
    public func bordersClosed(to player: PlayerID, by owner: PlayerID) -> Bool {
        owner != player && relation(player, owner).stance == .peace
    }

    /// Marks a pair as met (once), with a `playersMet` event for both.
    mutating func meet(_ a: PlayerID, _ b: PlayerID, _ fx: inout Effects) {
        guard a != b else { return }
        let i = relationIndex(a, b)
        guard !relations[i].met else { return }
        relations[i].met = true
        let (x, y) = (relations[i].a, relations[i].b)
        fx.emit(.playersMet(x, y), .pair(x, y))
    }

    /// Phase start step 1 (M1 §3, §9): `player`'s own unanswered peace proposals expire and start
    /// its cool-down.
    mutating func expireProposals(of player: PlayerID, _ fx: inout Effects) {
        for i in relations.indices where relations[i].proposalFrom == player {
            relations[i].proposalFrom = nil
            let ends = turn + rules.constants.diplomacy.proposalCooldownTurns
            if relations[i].a == player { relations[i].aCooldownEnds = ends } else { relations[i].bCooldownEnds = ends }
            let other = relations[i].other(than: player)
            fx.emit(.peaceDeclined(proposer: player, by: other), .pair(player, other))
        }
    }
}

// MARK: - Commands

extension GameState {
    /// Why `player` may not deal with `other` at all (nil: it may): another, living player.
    private func counterpartProblem(_ player: PlayerID, _ other: PlayerID) -> String? {
        guard other != player, players.indices.contains(other.rawValue), players[other.rawValue].isAlive else {
            return "no such player"
        }
        return nil
    }

    /// Why `player` may not declare war on `other` now (nil: it may), M1 §9: they have met, are
    /// at peace, and a peace treaty is at least `warAfterPeaceTurns` turns old.
    func warProblem(_ player: PlayerID, on other: PlayerID) -> String? {
        if let problem = counterpartProblem(player, other) { return problem }
        let relation = relation(player, other)
        let name = players[other.rawValue].name
        guard relation.met else { return "you have not met \(name)" }
        guard relation.stance == .peace else { return "already at war with \(name)" }
        if let since = relation.since {
            let first = since + rules.constants.diplomacy.warAfterPeaceTurns
            if turn < first { return "a peace treaty holds until turn \(first)" }
        }
        return nil
    }

    /// `declareWar` (validated by the caller): everyone who has met either side hears of it.
    mutating func declareWar(_ player: PlayerID, on other: PlayerID, _ fx: inout Effects) {
        let turn = self.turn
        updateRelation(player, other) { relation in
            relation.stance = .war
            relation.since = turn
            relation.proposalFrom = nil
        }
        fx.emit(.warDeclared(by: player, on: other), .metEither(player, other))
    }

    /// Why `player` may not propose peace to `other` now (nil: it may), M1 §9: at war for at
    /// least `peaceAfterWarTurns` turns, no proposal pending between them, and no cool-down.
    func proposalProblem(_ player: PlayerID, to other: PlayerID) -> String? {
        if let problem = counterpartProblem(player, other) { return problem }
        let relation = relation(player, other)
        guard relation.stance == .war else { return "not at war with \(players[other.rawValue].name)" }
        let first = (relation.since ?? 0) + rules.constants.diplomacy.peaceAfterWarTurns
        if turn < first { return "peace can be proposed from turn \(first)" }
        if relation.proposalFrom != nil { return "a peace proposal is pending" }
        let cooldown = relation.a == player ? relation.aCooldownEnds : relation.bCooldownEnds
        if turn < cooldown { return "peace can be proposed again from turn \(cooldown)" }
        return nil
    }

    /// `proposePeace` (validated by the caller). `other` answers in its own phase; unanswered,
    /// the proposal expires at the proposer's next phase start.
    mutating func proposePeace(_ player: PlayerID, to other: PlayerID, _ fx: inout Effects) {
        updateRelation(player, other) { $0.proposalFrom = player }
        fx.emit(.peaceProposed(from: player, to: other), .pair(player, other))
    }

    /// Why `player` may not answer a peace proposal from `proposer` (nil: it may).
    func responseProblem(_ player: PlayerID, to proposer: PlayerID) -> String? {
        if let problem = counterpartProblem(player, proposer) { return problem }
        guard relation(player, proposer).proposalFrom == proposer else {
            return "no peace proposal from \(players[proposer.rawValue].name)"
        }
        return nil
    }

    /// `respondToPeace` (validated by the caller): accepting signs peace (`since` = this turn);
    /// declining starts the proposer's cool-down.
    mutating func respondToPeace(_ player: PlayerID, from proposer: PlayerID, accept: Bool, _ fx: inout Effects) {
        let turn = self.turn
        let cooldown = turn + rules.constants.diplomacy.proposalCooldownTurns
        updateRelation(player, proposer) { relation in
            relation.proposalFrom = nil
            if accept {
                relation.stance = .peace
                relation.since = turn
            } else if relation.a == proposer {
                relation.aCooldownEnds = cooldown
            } else {
                relation.bCooldownEnds = cooldown
            }
        }
        let relation = relation(player, proposer)
        if accept {
            fx.emit(.peaceSigned(relation.a, relation.b), .pair(player, proposer))
        } else {
            fx.emit(.peaceDeclined(proposer: proposer, by: player), .pair(player, proposer))
        }
    }
}
