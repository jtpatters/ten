public struct PathStep: Hashable, Sendable {
    public let hex: HexCoord
    /// 1 = reached this turn, 2 = next turn, ...
    public let turn: Int
}

public struct Path: Hashable, Sendable {
    /// Steps after the start tile, ending at the destination.
    public let steps: [PathStep]
    public var destination: HexCoord? { steps.last?.hex }
    public var turns: Int { steps.last?.turn ?? 0 }
}

/// Searches over (tile, moves left) with the unit owner's knowledge (M1 §8.5, §8.6,
/// `MoveKnowledge`). A unit may always enter a passable tile if it has any movement left;
/// entering uses min(movesLeft, cost) and ends the turn at 0. A turn may only end on a tile the
/// unit may stop on, and a unit may end its turn early (keeping its place) to pass an occupied
/// tile later. Entering a zone of control ends the unit's movement for the phase: the state it
/// arrives in may only end the turn (it keeps its points, which an attack can use). A unit
/// already stopped by a zone of control this phase plans from next turn.
public enum Pathfinder {
    public static func findPath(for unit: Unit, to goal: HexCoord, in state: GameState) -> Path? {
        guard let goal = state.map.index(of: goal), let start = state.map.index(of: unit.position), goal != start,
              state.players.indices.contains(unit.owner.rawValue) else { return nil }
        let knowledge = MoveKnowledge(state: state, unit: unit)
        guard knowledge.canEnd(goal) else { return nil }
        return search(knowledge, from: start, movesLeft: unit.zocStopped ? 0 : unit.movesLeft,
                      maxMoves: state.maxMoves(of: unit), to: goal)
    }

    /// The tiles `unit` can reach and stop on this phase, by its owner's knowledge, sorted by
    /// tile index (its own tile excluded).
    public static func reachableTiles(for unit: Unit, in state: GameState) -> [HexCoord] {
        guard unit.movesLeft > 0, !unit.zocStopped, let start = state.map.index(of: unit.position),
              state.players.indices.contains(unit.owner.rawValue) else { return [] }
        let k = MoveKnowledge(state: state, unit: unit)
        let field = phaseField(k, from: start, movesLeft: unit.movesLeft)
        return field.reached.filter { $0 != start && k.canEnd($0) }.sorted().map { k.map.coord(at: $0) }
    }

    /// The most movement points a unit can have left on arriving at each tile this phase.
    struct PhaseField {
        /// Per tile: points left on arrival, −1 if not reachable this phase.
        var best: [Int8]
        /// The tiles reached (the start first), in discovery order.
        var reached: [Int]
    }

    /// The most movement points left on arriving at each tile this phase, from `start` with
    /// `movesLeft` (pass-through tiles included; callers check `canEnd`). A unit that enters a
    /// zone of control moves no further but keeps its points.
    static func phaseField(_ k: MoveKnowledge, from start: Int, movesLeft: Int) -> PhaseField {
        var best = [Int8](repeating: -1, count: k.map.tileCount)
        var reached = [start]
        best[start] = Int8(max(0, movesLeft))
        guard movesLeft > 0 else { return PhaseField(best: best, reached: reached) }
        var buckets = [[Int]](repeating: [], count: movesLeft + 1)
        buckets[movesLeft] = [start]
        for moves in stride(from: movesLeft, through: 1, by: -1) {
            var i = 0
            while i < buckets[moves].count {
                let t = buckets[moves][i]
                i += 1
                guard Int(best[t]) == moves else { continue }
                if t != start, k.zoc[t] { continue } // entered a zone of control: no further
                k.map.forEachNeighbor(of: t) { n, direction in
                    guard k.canEnter(n) else { return }
                    let after = max(0, moves - k.cost(from: t, to: n, direction))
                    if after == 0 || k.zoc[n], !k.canEnd(n) { return }
                    guard after > Int(best[n]) else { return }
                    if best[n] < 0 { reached.append(n) }
                    best[n] = Int8(after)
                    if after > 0 { buckets[after].append(n) }
                }
            }
        }
        return PhaseField(best: best, reached: reached)
    }

    /// Movement points to reach each tile and stop there (M1 §12.6), counting the points left
    /// unused at turn ends: a tile reached this phase costs the points spent; one reached next
    /// turn costs the points left now plus those spent then. −1 where the unit cannot stop (by
    /// its owner's knowledge). Zones of control end the turn. Dial's algorithm over (tile,
    /// moves left); stops once costs pass `limit`.
    static func movementField(_ k: MoveKnowledge, from start: Int, movesLeft: Int, maxMoves: Int,
                              limit: Int = .max) -> [Int32] {
        let count = k.map.tileCount
        var field = [Int32](repeating: -1, count: count)
        let stride = maxMoves + 1
        let m0 = max(0, min(movesLeft, maxMoves))
        let startKey = start * stride + m0
        var cost = [Int32](repeating: .max, count: count * stride)
        // Every step costs 1…maxMoves, so maxMoves + 1 buckets in a ring hold every pending cost.
        var ring = [[Int32]](repeating: [], count: maxMoves + 1)
        var pending = 1
        cost[startKey] = 0
        ring[0].append(Int32(startKey))

        func relax(_ key: Int, _ c: Int, _ ring: inout [[Int32]], _ pending: inout Int) {
            guard c < Int(cost[key]) else { return }
            cost[key] = Int32(c)
            ring[c % ring.count].append(Int32(key))
            pending += 1
        }

        var current = 0
        while pending > 0, current <= limit {
            let slot = current % ring.count
            let bucket = ring[slot]
            ring[slot] = []
            for packed in bucket {
                pending -= 1
                let key = Int(packed)
                guard Int(cost[key]) == current else { continue } // superseded
                let t = key / stride, moves = key % stride
                let stoppable = t == start || k.canEnd(t)
                if stoppable, field[t] < 0 { field[t] = Int32(current) }
                // End the turn here, keeping the place.
                if moves > 0, stoppable { relax(t * stride, current + moves, &ring, &pending) }
                // A unit that entered a zone of control this turn moves no further.
                if moves > 0, key != startKey, k.zoc[t] { continue }
                let available = moves > 0 ? moves : maxMoves
                k.map.forEachNeighbor(of: t) { n, direction in
                    guard k.canEnter(n) else { return }
                    let spent = min(available, k.cost(from: t, to: n, direction))
                    let after = available - spent
                    if after == 0 || k.zoc[n], !k.canEnd(n) { return }
                    relax(n * stride + after, current + spent, &ring, &pending)
                }
            }
            current += 1
        }
        return field
    }

    static func search(_ k: MoveKnowledge, from start: Int, movesLeft: Int, maxMoves: Int, to goal: Int) -> Path? {
        guard connected(k, start, goal) else { return nil }
        let map = k.map
        let stride = maxMoves + 1
        let stateCount = map.tileCount * stride
        // Per (tile, moves left) state: g = movement spent, counting moves left unused at turn
        // ends, so g + moves = turn × maxMoves.
        var g = [Int32](repeating: .max, count: stateCount)
        var parent = [Int32](repeating: -1, count: stateCount)
        var closed = [Bool](repeating: false, count: stateCount)
        var open = MinHeap<Int>()
        var pushes = 0
        let goalHex = map.coord(at: goal)

        func push(_ key: Int, _ cost: Int, from previous: Int) {
            guard cost < Int(g[key]) else { return }
            g[key] = Int32(cost)
            parent[key] = Int32(previous)
            pushes += 1 // deterministic tie-break by insertion order
            open.push(key, priority: cost + map.distance(map.coord(at: key / stride), goalHex), tiebreak: pushes)
        }

        let m0 = max(0, min(movesLeft, maxMoves))
        let startKey = start * stride + m0
        push(startKey, maxMoves - m0, from: -1)
        while let key = open.pop() {
            guard !closed[key] else { continue }
            closed[key] = true
            let t = key / stride, moves = key % stride
            let cost = Int(g[key])
            if t == goal { return reconstruct(key, start: start, parent: parent, g: g, stride: stride, maxMoves: maxMoves, map: map) }
            // End the turn here, keeping the place (only where the unit may stop).
            if moves > 0, t == start || k.canEnd(t) {
                push(t * stride, cost + moves, from: key)
            }
            // A unit that entered a zone of control this turn moves no further.
            if moves > 0, key != startKey, k.zoc[t] { continue }
            let available = moves > 0 ? moves : maxMoves
            map.forEachNeighbor(of: t) { n, direction in
                guard k.canEnter(n) else { return }
                let spent = min(available, k.cost(from: t, to: n, direction))
                let after = available - spent
                if after == 0 || k.zoc[n], !k.canEnd(n) { return }
                push(n * stride + after, cost + spent, from: key)
            }
        }
        return nil
    }

    /// Whether `goal` can be reached from `start` through tiles the unit may enter, as far as
    /// its player knows (turn ends ignored): a quick breadth-first test, so an unreachable goal
    /// does not make the full search explore everything it can reach.
    static func connected(_ k: MoveKnowledge, _ start: Int, _ goal: Int) -> Bool {
        var seen = [Bool](repeating: false, count: k.map.tileCount)
        var queue = [start]
        seen[start] = true
        var head = 0
        while head < queue.count {
            let t = queue[head]
            head += 1
            var found = false
            k.map.forEachNeighbor(of: t) { n, _ in
                guard !seen[n], k.canEnter(n) else { return }
                if n == goal { found = true }
                seen[n] = true
                queue.append(n)
            }
            if found { return true }
        }
        return false
    }

    private static func reconstruct(_ end: Int, start: Int, parent: [Int32], g: [Int32], stride: Int, maxMoves: Int,
                                    map: HexMap) -> Path {
        var keys = [end]
        while parent[keys.last!] >= 0 { keys.append(Int(parent[keys.last!])) }
        keys.reverse()
        var steps: [PathStep] = []
        var lastTile = start
        for key in keys {
            let t = key / stride
            guard t != lastTile else { continue } // a turn ended in place
            lastTile = t
            steps.append(PathStep(hex: map.coord(at: t), turn: (Int(g[key]) + key % stride) / maxMoves))
        }
        return Path(steps: steps)
    }
}

/// Binary min-heap with deterministic tie-breaking.
struct MinHeap<Element> {
    private var items: [(priority: Int, tiebreak: Int, element: Element)] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ element: Element, priority: Int, tiebreak: Int) {
        items.append((priority, tiebreak, element))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard less(i, parent) else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> Element? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < items.count, less(l, smallest) { smallest = l }
            if r < items.count, less(r, smallest) { smallest = r }
            if smallest == i { break }
            items.swapAt(i, smallest)
            i = smallest
        }
        return top.element
    }

    private func less(_ a: Int, _ b: Int) -> Bool {
        (items[a].priority, items[a].tiebreak) < (items[b].priority, items[b].tiebreak)
    }
}
