/// What applying a command did besides changing the state (M1 §12.5): its events, each with
/// the rule that fixes its audience, and what the knowledge update must look at.
struct Effects {
    /// Who may see an event. Resolved once the command is done, against each player's
    /// visibility before the command and after it.
    enum Audience {
        /// Players for whom one of these tiles (indices) is visible before or after.
        case tiles([Int])
        /// The owner only (production, research, upkeep).
        case owner(PlayerID)
        /// The owner, plus `tiles` viewers (units their owner disbands).
        case ownerAndTiles(PlayerID, [Int])
        /// A `unitMoved` along `tiles` (the start, then each tile entered). M1 §12.5 fixes the
        /// audience per step: a player sees a step when it sees either of its two tiles before
        /// or after. The owner gets the whole path; another player gets one `unitMoved` per run
        /// of consecutive steps it sees, so a path through its fog never shows the hidden tiles
        /// in between (each run starts on the tile the unit came from, next to a seen one).
        case move(owner: PlayerID, tiles: [Int])
        /// Both parties (diplomacy).
        case pair(PlayerID, PlayerID)
        /// Every player who has met either side (war declared).
        case metEither(PlayerID, PlayerID)
        /// Everyone (phases, elimination, game over).
        case everyone
    }

    private(set) var pending: [(event: GameEvent, audience: Audience)] = []
    /// Tiles whose owner, improvement, city or tribal village changed: visible ones refresh
    /// memory.
    var dirtyTiles: [Int] = []
    /// Players whose units, cities or territory changed: their visibility is recomputed.
    var dirtyPlayers: UInt64 = 0

    mutating func emit(_ event: GameEvent, _ audience: Audience) {
        pending.append((event, audience))
    }

    mutating func touchPlayer(_ player: PlayerID) {
        dirtyPlayers |= 1 << UInt64(player.rawValue)
    }

    mutating func touchAllPlayers(_ count: Int) {
        for p in 0..<count { dirtyPlayers |= 1 << UInt64(p) }
    }

    mutating func touchTile(_ index: Int) {
        dirtyTiles.append(index)
    }

    /// The events as records, audiences resolved against visibility `before` the command and
    /// the state after it.
    func records(before: [TileBitSet], after state: GameState) -> [EventRecord] {
        var records: [EventRecord] = []
        records.reserveCapacity(pending.count)
        for (event, audience) in pending {
            if case let .move(owner, tiles) = audience, case let .unitMoved(unit, from, path) = event, path.count + 1 == tiles.count {
                records += Self.moveRecords(unit: unit, from: from, path: path, owner: owner, tiles: tiles, before: before, after: state)
            } else {
                records.append(EventRecord(event, audience: Self.mask(audience, before: before, after: state)))
            }
        }
        return records
    }

    /// The records of one move (`Audience.move`): every distinct run of seen steps once, with
    /// the players who see exactly that run; runs in path order (the whole path first).
    private static func moveRecords(unit: UnitID, from: HexCoord, path: [HexCoord], owner: PlayerID, tiles: [Int],
                                    before: [TileBitSet], after state: GameState) -> [EventRecord] {
        let steps = path.count
        // runs[k] = (first step, last step, audience), steps numbered 1...steps.
        var runs: [(first: Int, last: Int, mask: UInt16)] = [(1, steps, bit(owner))]
        func add(_ first: Int, _ last: Int, _ p: Int) {
            if let k = runs.firstIndex(where: { $0.first == first && $0.last == last }) {
                runs[k].mask |= bit(PlayerID(p))
            } else {
                runs.append((first, last, bit(PlayerID(p))))
            }
        }
        for p in state.players.indices where p != owner.rawValue {
            let now = state.players[p].visible
            let then = p < before.count ? before[p] : now
            func sees(_ t: Int) -> Bool { then[t] || now[t] }
            var runStart = 0
            for step in 1...steps {
                let seen = sees(tiles[step - 1]) || sees(tiles[step])
                if seen, runStart == 0 { runStart = step }
                if !seen, runStart != 0 {
                    add(runStart, step - 1, p)
                    runStart = 0
                }
            }
            if runStart != 0 { add(runStart, steps, p) }
        }
        runs.sort { $0.first != $1.first ? $0.first < $1.first : $0.last > $1.last }
        return runs.map { run in
            let start = run.first == 1 ? from : path[run.first - 2]
            return EventRecord(.unitMoved(unit: unit, from: start, path: Array(path[(run.first - 1)...(run.last - 1)])),
                               audience: run.mask)
        }
    }

    private static func bit(_ player: PlayerID) -> UInt16 {
        (0..<16).contains(player.rawValue) ? UInt16(1) << UInt16(player.rawValue) : 0
    }

    private static func mask(_ audience: Audience, before: [TileBitSet], after state: GameState) -> UInt16 {
        switch audience {
        case .everyone:
            return EventRecord.everyone
        case let .owner(p):
            return bit(p)
        case let .pair(a, b):
            return bit(a) | bit(b)
        case let .tiles(tiles):
            return tileMask(tiles, before: before, after: state)
        case let .ownerAndTiles(p, tiles), let .move(p, tiles):
            return bit(p) | tileMask(tiles, before: before, after: state)
        case let .metEither(a, b):
            var mask = bit(a) | bit(b)
            for p in state.players where state.hasMet(p.id, a) || state.hasMet(p.id, b) { mask |= bit(p.id) }
            return mask
        }
    }

    private static func tileMask(_ tiles: [Int], before: [TileBitSet], after state: GameState) -> UInt16 {
        var mask: UInt16 = 0
        for p in state.players.indices {
            let now = state.players[p].visible
            let then = p < before.count ? before[p] : now
            if tiles.contains(where: { then[$0] || now[$0] }) { mask |= bit(PlayerID(p)) }
        }
        return mask
    }
}
