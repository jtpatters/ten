// Tribal villages (M1 §7.7): small independent settlements the game places on the land between
// the starts. The first unit of any player to enter one's tile, or the city whose land takes it
// in, gets a gift from the villagers: Gold, Science or a Builder.
//
// This file holds what phase 3g's packages share (H0, contracts): the live state, the gift, a
// placed site with its tag, the sorted tile lists, and the helpers that fix the two events'
// audiences. H1 (p3g-core) added placement (`TribalVillagePlacer`, run by `newGame`), the gift
// bag and `takeTribalVillage`, which every take goes through: a unit entering the tile
// (`executeMove`), a founding (`foundCity`) and border growth (`runBorders`).
//
// The live sites are internal to GameCore (`GameState.tribalVillages`): the AI, the App, the
// renderer and HeadlessSim learn of a tribal village only through a player's memory
// (`PlayerMemory.tribalVillages`, `PlayerView.knownTribalVillages`), or `DebugTools` for
// diagnostics and tests. Without the rules section (`Ruleset.tribalVillages == nil`) a game has
// none, its state field stays nil, and saves and `stateHash()` are exactly as before.

/// The tribal villages of a game, nil in a game without them (`GameState.tribalVillages`), so
/// its key is absent from saves and the state hash.
struct TribalVillageState: Codable, Hashable, Sendable {
    /// Tile indices of the tribal villages still standing: sorted, unique.
    var sites: [Int32]
    /// Per player: the gifts received so far (the next gift's place in the player's bags).
    var gifts: [Int]

    init(sites: [Int32], gifts: [Int]) {
        self.sites = sites
        self.gifts = gifts
    }

    /// None placed yet, and no gifts for any of `players` players.
    init(players: Int) {
        self.init(sites: [], gifts: [Int](repeating: 0, count: players))
    }

    /// Whether a tribal village stands on tile `t`.
    func holds(_ t: Int) -> Bool { SortedTiles.contains(sites, t) }

    /// Adds a site on tile `t`, in order; false when one is already there.
    @discardableResult
    mutating func insert(_ t: Int) -> Bool { SortedTiles.insert(t, into: &sites) }

    /// Removes the site on tile `t`; false when there is none.
    @discardableResult
    mutating func remove(_ t: Int) -> Bool { SortedTiles.remove(t, from: &sites) }
}

/// What a tribal village gave (`GameEvent.tribalVillageGift`). A gift that falls back (Science
/// with every tech known, a Builder with no room) is reported as the `.gold` it became.
public enum TribalVillageGift: Codable, Hashable, Sendable {
    /// Gold added to the treasury.
    case gold(Int)
    /// Research progress, toward the tech being researched (nil: banked with nothing being
    /// researched).
    case science(Int, toward: TechID?)
    /// A new Builder.
    case builder(UnitID)
}

/// A tribal village as placement put it (`DebugTools.tribalVillagePlacement`, H1): its tile and
/// the round it came from, for the placement property test and HeadlessSim's statistics.
public struct TribalVillageSite: Codable, Hashable, Sendable {
    public var hex: HexCoord
    /// The index of the start (player) whose own round placed it; nil for a shared one.
    public var start: Int?

    public init(hex: HexCoord, start: Int?) {
        self.hex = hex
        self.start = start
    }
}

/// Sorted, unique lists of tile indices (`TribalVillageState.sites`,
/// `PlayerMemory.tribalVillages`), searched by bisection.
enum SortedTiles {
    /// Where tile `t` is in `tiles`, or where it would go.
    static func search(_ tiles: [Int32], _ t: Int) -> (found: Bool, index: Int) {
        let key = Int32(truncatingIfNeeded: t)
        var lo = 0, hi = tiles.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tiles[mid] == key { return (true, mid) }
            if tiles[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return (false, lo)
    }

    static func contains(_ tiles: [Int32], _ t: Int) -> Bool { search(tiles, t).found }

    /// Inserts `t` in order; false when it is already there.
    @discardableResult
    static func insert(_ t: Int, into tiles: inout [Int32]) -> Bool {
        let (found, i) = search(tiles, t)
        guard !found else { return false }
        tiles.insert(Int32(truncatingIfNeeded: t), at: i)
        return true
    }

    /// Removes `t`; false when it is not there.
    @discardableResult
    static func remove(_ t: Int, from tiles: inout [Int32]) -> Bool {
        let (found, i) = search(tiles, t)
        guard found else { return false }
        tiles.remove(at: i)
        return true
    }
}

extension GameState {
    /// Whether a tribal village stands on tile `t` (always false without them).
    func holdsTribalVillage(_ t: Int) -> Bool { tribalVillages?.holds(t) ?? false }
}

extension PlayerMemory {
    /// The player sees tile `t` and whether a tribal village stands there (`standing`): memory
    /// follows, and a list left empty becomes nil (never `[]`).
    mutating func rememberTribalVillage(at t: Int, standing: Bool) {
        if standing {
            var list = tribalVillages ?? []
            if SortedTiles.insert(t, into: &list) { tribalVillages = list }
        } else if var list = tribalVillages, SortedTiles.remove(t, from: &list) {
            tribalVillages = list.isEmpty ? nil : list
        }
    }
}

extension Effects {
    /// `tribalVillageTaken` (M1 §12.5): the taker, and every player who sees the tile before or
    /// after the command.
    mutating func emitTribalVillageTaken(at t: Int, hex: HexCoord, player: PlayerID, unit: UnitID?, city: CityID?) {
        emit(.tribalVillageTaken(at: hex, player: player, unit: unit, city: city), .ownerAndTiles(player, [t]))
    }

    /// `tribalVillageGift` (M1 §12.5): the taker only; rivals never learn what a tribal village
    /// gave.
    mutating func emitTribalVillageGift(player: PlayerID, at hex: HexCoord, gift: TribalVillageGift) {
        emit(.tribalVillageGift(player: player, at: hex, gift: gift), .owner(player))
    }
}

// MARK: - Placement (M1 §7.7; DESIGN §3.2)

/// Places a game's tribal villages, once, when `GameState.newGame` is asked to: after the start
/// units, before the first knowledge update. Integers only, candidates in tile-index order, one
/// `SplitMix64(seed: seed, salts: 0x4EA7)` stream, no `Set` or `Dictionary`. It never changes
/// the map, the starts or the units.
///
/// - **Steps:** breadth-first over passable land from each start (each step counts 1, whatever
///   the terrain; neighbours in `HexDirection` order, wrapping east–west).
/// - **Sides:** a tile's own start is the start with the fewest steps to it (ties: lower
///   player); its margin is the next-fewest steps minus the fewest (0 on a tie; 30 when no other
///   start reaches it).
/// - **Allowed:** reachable from a start, not a start tile, neither Oasis nor Snow, no unit on
///   it, unowned. A tile within `spacing − 1` hexes of a tribal village already placed is
///   blocked.
/// - **Own rounds** (`rules.rounds`, in order): draw a start offset, then visit the starts from it;
///   each takes a random unblocked tile on its own side from the first of its bands that has one
///   (`min ≤ steps ≤ max`, `margin ≥ band.margin`), blocking around it at once. A round stops at
///   the first start with no candidate in any band: all its picks are dropped and `blocked` is
///   restored, and the stream is not rewound.
/// - **Shared:** then `perStart × starts` times, a random unblocked allowed tile reachable from
///   every start, at least `minSteps` from each, with margin ≤ `maxMargin`, while any is left.
///
/// The placer is a value whose rounds can be run one at a time (the rounds test watches
/// `blocked`, `rng` and `picks` between them).
struct TribalVillagePlacer {
    /// An allowed tile on a start's own side, with its steps from that start and its margin.
    struct Candidate: Hashable {
        let tile: Int
        let steps: Int
        let margin: Int
    }

    /// A placed tribal village: its tile, and the start whose own round placed it (nil: shared).
    struct Pick: Hashable {
        let tile: Int
        let start: Int?
    }

    let map: HexMap
    let rules: TribalVillageRules
    /// Each start's tile index, in player order (nil: off the map, so it reaches nothing).
    let starts: [Int?]
    /// Per start, its own-side allowed tiles, in tile order.
    let own: [[Candidate]]
    /// The allowed tiles a shared tribal village may take (spacing aside), in tile order.
    let shared: [Int]
    /// The placement stream, `SplitMix64(seed: seed, salts: 0x4EA7)`.
    var rng: SplitMix64
    /// Tiles within `spacing − 1` hexes of a tribal village placed so far.
    var blocked: TileBitSet
    /// The tribal villages placed so far, in the order they were placed.
    var picks: [Pick] = []

    /// The margin of a tile only one start reaches.
    static let soleMargin = 30

    /// Prepares placement on `state` (its map, rules, units and seed) for the starts
    /// `startPositions` (player order).
    init(state: GameState, startPositions: [HexCoord], rules: TribalVillageRules) {
        let map = state.map
        let count = map.tileCount
        self.map = map
        self.rules = rules
        rng = SplitMix64(seed: state.seed, salts: 0x4EA7)
        blocked = TileBitSet(count: count)

        let ruleset = state.rules
        var passable = [Bool](repeating: false, count: count)
        for t in 0..<count { passable[t] = ruleset.isPassable(map.tiles[t]) }
        let starts = startPositions.map { map.index(of: $0) }
        self.starts = starts

        // The passable neighbours of each passable tile, six slots a tile (−1: none), worked out
        // once for all the searches.
        var links = [Int32](repeating: -1, count: count * 6)
        for t in 0..<count where passable[t] {
            for direction in HexDirection.allCases {
                if let n = map.neighborIndex(of: t, direction), passable[n] { links[t * 6 + direction.rawValue] = Int32(n) }
            }
        }

        // Steps: one breadth-first search per start, into one flat array (start i's steps to
        // tile t at i·count + t; −1 where it does not reach). Raw buffers keep a debug build
        // well inside its budget; every index is a tile's, or one below starts × tiles.
        var steps = [Int32](repeating: -1, count: starts.count * count)
        var queue = [Int32](repeating: 0, count: count)
        links.withUnsafeBufferPointer { links in
            steps.withUnsafeMutableBufferPointer { steps in
                queue.withUnsafeMutableBufferPointer { queue in
                    for (i, start) in starts.enumerated() {
                        guard let start else { continue }
                        let base = i * count
                        steps[base + start] = 0
                        queue[0] = Int32(start)
                        var head = 0, tail = 1
                        while head < tail {
                            let t = Int(queue[head])
                            head += 1
                            let next = steps[base + t] + 1
                            var k = t * 6
                            let end = k + 6
                            while k < end {
                                let n = Int(links[k])
                                k += 1
                                if n >= 0 && steps[base + n] < 0 {
                                    steps[base + n] = next
                                    queue[tail] = Int32(n)
                                    tail += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        // Allowed tiles, their sides and margins.
        var isStart = [Bool](repeating: false, count: count)
        for start in starts { if let start { isStart[start] = true } }
        var occupied = [Bool](repeating: false, count: count)
        for unit in state.units { if let t = map.index(of: unit.position) { occupied[t] = true } }
        let tileCity = state.tileCity
        var own = [[Candidate]](repeating: [], count: starts.count)
        var shared: [Int] = []
        let s = rules.shared
        steps.withUnsafeBufferPointer { steps in
            for t in 0..<count where passable[t] && !isStart[t] && !occupied[t] && tileCity[t] == 0 {
                let tile = map.tiles[t]
                guard tile.feature != .oasis, tile.terrain != .snow, tile.resource == nil else { continue }
                var nearest = -1, fewest = Int32.max, next = Int32.max, reached = 0
                for i in 0..<starts.count {
                    let d = steps[i * count + t]
                    guard d >= 0 else { continue }
                    reached += 1
                    if d < fewest {
                        next = fewest
                        fewest = d
                        nearest = i
                    } else if d < next {
                        next = d
                    }
                }
                guard nearest >= 0 else { continue }
                let margin = next == Int32.max ? Self.soleMargin : Int(next - fewest)
                own[nearest].append(Candidate(tile: t, steps: Int(fewest), margin: margin))
                if reached == starts.count, Int(fewest) >= s.minSteps, margin <= s.maxMargin { shared.append(t) }
            }
        }
        self.own = own
        self.shared = shared
    }

    /// Runs placement to the end: every own round, then the shared tribal villages. Returns the
    /// picks in tile order.
    mutating func place() -> [Pick] {
        for bands in rules.rounds { runRound(bands) }
        placeShared()
        return picks.sorted { $0.tile < $1.tile }
    }

    /// One own round with these bands (all or none). Returns whether every start got one.
    @discardableResult
    mutating func runRound(_ bands: [TribalVillageRules.Band]) -> Bool {
        guard !starts.isEmpty else { return false }
        let saved = blocked
        let first = picks.count
        let offset = rng.nextInt(below: starts.count)
        for k in starts.indices {
            let start = (offset + k) % starts.count
            guard let tile = pick(for: start, bands) else {
                picks.removeSubrange(first...)
                blocked = saved
                return false
            }
            picks.append(Pick(tile: tile, start: start))
            block(around: tile)
        }
        return true
    }

    /// A random unblocked tile on `start`'s own side from the first band that has one.
    private mutating func pick(for start: Int, _ bands: [TribalVillageRules.Band]) -> Int? {
        for band in bands {
            let candidates = own[start].filter { c in
                band.min <= c.steps && c.steps <= band.max && c.margin >= band.margin && !blocked[c.tile]
            }
            if !candidates.isEmpty { return candidates[rng.nextInt(below: candidates.count)].tile }
        }
        return nil
    }

    /// The shared tribal villages: `perStart × starts` tries, stopping when no tile is left.
    mutating func placeShared() {
        for _ in 0..<(rules.shared.perStart * starts.count) {
            let candidates = shared.filter { !blocked[$0] }
            guard !candidates.isEmpty else { return }
            let tile = candidates[rng.nextInt(below: candidates.count)]
            picks.append(Pick(tile: tile, start: nil))
            block(around: tile)
        }
    }

    /// Blocks every tile within `spacing − 1` hexes of tile `t`.
    mutating func block(around t: Int) {
        var blocked = self.blocked
        map.forEachIndex(within: rules.spacing - 1, of: map.coord(at: t)) { blocked[$0] = true }
        self.blocked = blocked
    }
}

// MARK: - Gifts (M1 §7.7; DESIGN §3.4)

/// The three gifts a player's bag holds.
enum TribalVillageGiftKind: Int, CaseIterable, Hashable, Sendable {
    case gold, science, builder
}

extension TribalVillageState {
    /// Player `player`'s bag number `bag` (its gifts 3·bag … 3·bag + 2), in the order they come:
    /// [Gold, Science, Builder] shuffled by Fisher–Yates (i from 2 down to 1, j below i + 1) with
    /// `SplitMix64(seed: seed, salts: player, bag, 0x4EA8)`. No other stream moves.
    static func bag(seed: UInt64, player: Int, bag: Int) -> [TribalVillageGiftKind] {
        var kinds = TribalVillageGiftKind.allCases
        var rng = SplitMix64(seed: seed, salts: UInt64(player), UInt64(bag), 0x4EA8)
        for i in stride(from: kinds.count - 1, through: 1, by: -1) {
            kinds.swapAt(i, rng.nextInt(below: i + 1))
        }
        return kinds
    }

    /// The kind of player `player`'s gift number `gift` (0 for its first).
    static func giftKind(seed: UInt64, player: Int, gift: Int) -> TribalVillageGiftKind {
        bag(seed: seed, player: player, bag: gift / 3)[gift % 3]
    }
}

extension GameState {
    /// The tribal village on tile `t` is taken by `player` (M1 §7.7): entered by its `unit`, or
    /// taken in by its `city`'s land. In order: the site goes; the tile and the taker are
    /// touched (memory and visibility follow at the knowledge update); `tribalVillageTaken`;
    /// the player's next gift is drawn from its bag and given; `tribalVillageGift`, then
    /// `unitCreated` for a Builder. No other random stream moves.
    ///
    /// - **Gold:** `gifts.gold` into the treasury.
    /// - **Science:** `gifts.science` research progress toward the current research, banked
    ///   with nothing being researched (§6); the Gold gift with every tech known. It is learnt
    ///   at the next science step, so a take during a phase (a command, a standing order at phase
    ///   start) counts at the next phase start, and a border claim at phase start counts at once.
    /// - **Builder:** a new Builder (the rules' charges) with no moves left, on the tile if it may
    ///   stand there, else on the nearest tile within `builderRadius` where it may that holds no
    ///   tribal village (ties: lower index); the Gold gift with no room. Made at phase start by a
    ///   border claim, it gets its moves in that phase start's unit step.
    ///
    /// A fallback is reported as the `.gold` it became. Rules without the section give nothing
    /// (only the take: a save with tribal villages opened under such rules).
    ///
    /// Every living player who sees the tile at the take forgets the tribal village at once.
    /// That is the sight the command began with (visibility is recomputed only when it ends),
    /// so those who hear of the take (`tribalVillageTaken`: the tile seen before or after the
    /// command) forget it even when the same command takes their sight of the tile away: a
    /// Warrior that passes through it and captures the Builder that saw it. Those who see the
    /// tile when the command ends forget it then (`touchTile`, M1 §11).
    mutating func takeTribalVillage(at t: Int, by player: PlayerID, unit: UnitID?, city: CityID?, _ fx: inout Effects) {
        guard tribalVillages?.remove(t) == true else { return }
        let hex = map.coord(at: t)
        for q in players.indices where players[q].isAlive && players[q].visible[t] {
            players[q].memory.rememberTribalVillage(at: t, standing: false)
        }
        fx.touchTile(t)
        fx.touchPlayer(player)
        fx.emitTribalVillageTaken(at: t, hex: hex, player: player, unit: unit, city: city)

        let p = player.rawValue
        guard let gifts = rules.tribalVillages?.gifts, let given = tribalVillages?.gifts, given.indices.contains(p),
              players.indices.contains(p) else { return }
        let k = given[p]
        tribalVillages?.gifts[p] = k + 1
        var gift = TribalVillageGift.gold(gifts.gold)
        var builder: (id: UnitID, tile: Int)?
        switch TribalVillageState.giftKind(seed: seed, player: p, gift: k) {
        case .gold:
            break
        case .science:
            if !rules.techs.allSatisfy({ players[p].knows($0.id) }) {
                players[p].researchProgress += gifts.science
                gift = .science(gifts.science, toward: players[p].researching)
            }
        case .builder:
            if let spot = tribalVillageBuilderTile(near: t, for: player, radius: gifts.builderRadius) {
                let id = insertUnit(.builder, owner: player, at: map.coord(at: spot), movesLeft: 0)
                builder = (id, spot)
                gift = .builder(id)
            }
        }
        if case let .gold(amount) = gift { players[p].gold += amount }
        fx.emitTribalVillageGift(player: player, at: hex, gift: gift)
        if let builder {
            fx.emit(.unitCreated(unit: builder.id, type: .builder, owner: player, at: map.coord(at: builder.tile)),
                    .tiles([builder.tile]))
        }
    }

    /// Where a Builder gift from the tribal village on tile `t` appears for `player`: `t` if a
    /// new Builder may stand there, else the nearest tile within `radius` where it may that
    /// holds no tribal village (ties: lower index); nil with no room.
    func tribalVillageBuilderTile(near t: Int, for player: PlayerID, radius: Int) -> Int? {
        if !holdsTribalVillage(t), mayPlace(.builder, owner: player, at: t) { return t }
        var best: (distance: Int, tile: Int)?
        map.forEachIndex(within: radius, of: map.coord(at: t)) { n in
            guard n != t else { return }
            let d = map.distance(index: n, t)
            if let b = best, (b.distance, b.tile) <= (d, n) { return }
            guard !holdsTribalVillage(n), mayPlace(.builder, owner: player, at: n) else { return }
            best = (d, n)
        }
        return best?.tile
    }
}
