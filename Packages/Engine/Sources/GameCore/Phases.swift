// Turns and phases (M1 §3), elimination and victory (M1 §10).

extension GameState {
    /// Ends the current player's phase and starts the next living player's (M1 §3). After the
    /// last living player's phase the turn number increases; when the turn limit's last phase
    /// ends, the score victory decides the game instead.
    mutating func endPhase(_ fx: inout Effects) {
        guard outcome == nil else { return }
        let living = players.indices.filter { players[$0].isAlive && players[$0].isMajor }
        guard let first = living.first else { return }
        let next = living.first { $0 > currentPlayer.rawValue }
        if next == nil {
            if turn >= rules.constants.turnLimit {
                setOutcome(.victory(player: scoreLeader(), kind: .score), &fx)
                return
            }
            turn += 1
            fx.emit(.turnStarted(turn: turn), .everyone)
            advanceWorldEraIfDue(&fx)
            runFreeCities(&fx)
        }
        startPhase(of: PlayerID(next ?? first), &fx)
    }

    /// Starts `player`'s phase (M1 §3), steps in order:
    /// 1. expire the player's own unanswered peace proposals;
    /// 2. Stability of its cities (M2 §5.2); its cities in id order: assign citizens → collect yields → food and growth →
    ///    production → culture and borders → healing and wall repair → clear the bombard flag
    ///    (then citizens are reassigned so the city shows what it works next);
    /// 3. gold: the gold yield, then upkeep; 4. science;
    /// 5. its units in id order: clear `zocStopped`, `fortifying` → `fortified`, clear
    ///    `skipped`, heal, restore moves, leave territory closed to them; then, in a second
    ///    pass in id order, standing move orders continue;
    /// 6. record the phase start; 7. visibility, memory and "met", elimination and victory.
    mutating func startPhase(of player: PlayerID, _ fx: inout Effects) {
        phaseCount += 1
        currentPlayer = player
        fx.emit(.phaseStarted(turn: turn, player: player), .everyone)

        expireProposals(of: player, &fx)

        updateStability(for: player)
        updateLoyalty(for: player, &fx)
        var gold = 0, science = 0
        for index in cities.indices where cities[index].owner == player {
            assignCitizens(index)
            let yields = cityYields(cities[index])
            runGrowth(inCity: index, surplus: yields.foodSurplus, &fx)
            runProduction(inCity: index, production: yields.total.production, &fx)
            runBorders(inCity: index, culture: yields.total.culture, &fx)
            healCity(index, &fx)
            cities[index].bombarded = false
            assignCitizens(index)
            gold += yields.total.gold
            science += yields.total.science
        }

        runGold(for: player, income: gold, &fx)
        runResearch(for: player, science: science, &fx)
        runStockpiles(for: player)

        let ids = units.compactMap { $0.owner == player ? $0.id : nil }
        for id in ids {
            startPhase(ofUnit: id)
            evictIfInClosedTerritory(id, &fx)
        }
        for id in ids where unit(id)?.destination != nil {
            continueOrders(id, &fx)
        }

        players[player.rawValue].lastPhaseStart = phaseCount

        updateKnowledge(&fx)
        if resolveEliminationAndVictory(&fx) { updateKnowledge(&fx) }
    }

    /// After a command: knowledge, then elimination and victory (M1 §10); if the current player
    /// was eliminated during their phase, the phase ends at once.
    mutating func finishCommand(_ fx: inout Effects) {
        updateKnowledge(&fx)
        if resolveEliminationAndVictory(&fx) { updateKnowledge(&fx) }
    }

    /// Eliminates players with no cities and no city founders (their units are removed), then
    /// decides the game (defeat when every human is out; the last player standing; domination).
    /// Returns whether anything changed.
    @discardableResult
    mutating func resolveEliminationAndVictory(_ fx: inout Effects) -> Bool {
        guard outcome == nil else { return false }
        var changed = false
        var currentEliminated = false
        for p in players.indices where players[p].isAlive && players[p].isMajor {
            let id = PlayerID(p)
            let hasCity = cities.contains { $0.owner == id }
            let hasFounder = units.contains { $0.owner == id && rules.unit($0.type).foundsCity }
            guard !hasCity, !hasFounder else { continue }
            eliminate(id, &fx)
            changed = true
            if id == currentPlayer { currentEliminated = true }
        }
        let living = livingPlayers
        let humans = players.filter(\.isHuman)
        if living.isEmpty || (!humans.isEmpty && humans.allSatisfy { !$0.isAlive }) {
            setOutcome(.defeat, &fx)
            return true
        }
        if living.count == 1, players.filter(\.isMajor).count > 1 {
            setOutcome(.victory(player: living[0], kind: .lastStanding), &fx)
            return true
        }
        if let winner = dominationWinner() {
            setOutcome(.victory(player: winner, kind: .domination), &fx)
            return true
        }
        if currentEliminated { endPhase(&fx) }
        return changed
    }

    /// A living player who owns every other player's original capital (of players who founded
    /// a city) while every player who never founded one is eliminated.
    func dominationWinner() -> PlayerID? {
        guard players.contains(where: { $0.originalCapital != nil }) else { return nil }
        for p in players where p.isAlive && p.isMajor {
            let wins = players.allSatisfy { q in
                guard q.id != p.id, q.isMajor else { return true }
                if let capital = q.originalCapital { return city(capital)?.owner == p.id }
                return !q.isAlive
            }
            if wins, players.contains(where: { $0.id != p.id && $0.originalCapital != nil }) { return p.id }
        }
        return nil
    }

    mutating func eliminate(_ player: PlayerID, _ fx: inout Effects) {
        players[player.rawValue].isAlive = false
        players[player.rawValue].researching = nil
        players[player.rawValue].researchTarget = nil
        units.removeAll { $0.owner == player }
        for p in players.indices { players[p].memory.units.removeAll { $0.owner == player } }
        for i in relations.indices where relations[i].proposalFrom != nil && relations[i].involves(player) {
            relations[i].proposalFrom = nil
        }
        fx.touchPlayer(player)
        fx.emit(.playerEliminated(player), .everyone)
    }

    mutating func setOutcome(_ outcome: GameOutcome, _ fx: inout Effects) {
        self.outcome = outcome
        fx.emit(.gameOver(outcome), .everyone)
    }

    // MARK: Score

    /// 5·cities + population + 3·techs + 2·buildings, the Palace excluded (M1 §10).
    public func score(of player: PlayerID) -> Int {
        let s = rules.constants.score
        let palace = rules.palace.id
        var total = s.perTech * players[player.rawValue].knownTechs.count
        for city in cities where city.owner == player {
            total += s.perCity + s.perPopulation * city.population
            total += s.perBuilding * city.buildings.reduce(0) { $0 + ($1 == palace ? 0 : 1) }
        }
        return total
    }

    /// The living player with the highest score (ties: lower index).
    func scoreLeader() -> PlayerID {
        var best: (score: Int, player: PlayerID)?
        for p in players where p.isAlive && p.isMajor {
            let s = score(of: p.id)
            if best == nil || s > best!.score { best = (s, p.id) }
        }
        return best?.player ?? PlayerID(0)
    }
}
