import CoreGraphics
import GameCore
import QuartzCore
import simd

// Event animations (M1 §15). `apply(state:events:)` turns the events the viewer may see into
// steps on the units' pictures (`UnitVisual.steps`) and effects over the map, on one clock that
// runs while anything is pending:
//
// - Moves walk hex to hex. A foreign unit walks only the steps the viewer sees (a step is seen
//   when either of its tiles is visible before or after the event), fading in where it comes
//   out of the fog and out where it goes into it. Several `unitMoved` records of one unit in
//   one `apply` (the runs of one move an observer sees, or moves of several commands) chain:
//   each walks after the one before, a gap between them (a stretch the viewer does not see)
//   fades out and in again, and only the last decides where the picture comes to rest.
// - An attack: a melee lunge, or an arrow arcing from the attacker (a city's bombard from the
//   city). Where it lands the defender flashes, its HP bar drops, a burst marks the blow and
//   `onEventShown` reports it; the attacker takes its retaliation the same way.
// - A killed or disbanded unit's picture stays as a ghost and fades out; the winner then
//   advances (its move waits for the fade).
// - A captured civilian keeps its picture under its new id (`unitCaptured` gives one) and
//   changes colour (and type) under a flash once its captor arrives.
// - A created unit fades in.
// - A taken tribal village fades out as its plants fade back in, from when the unit that took
//   it reaches its tile (at once for a city's claim), and is reported then
//   (`MapRenderer+TribalVillages.swift`).
//
// Each unit's steps wait for its earlier ones, and an attack for both sides, so moves of
// different units play together while one unit's actions play in order. Without event
// animations (`animatesEvents` off, as for Reduce Motion) everything lands at once and
// `onEventShown` reports each event right away.

/// One scheduled change to a unit's picture, on the animation clock (seconds).
struct UnitStep {
    enum Kind {
        /// Walks from where it stands to `to`.
        case move(to: SIMD2<Float>)
        /// Steps toward `toward` and back: a melee blow, landing `lungeStrike` of the way
        /// through.
        case lunge(toward: SIMD2<Float>)
        /// Opacity from where it is to `to`.
        case fade(to: Float)
        /// Takes `damage` as it begins: a flash, and the HP bar drops.
        case hit(damage: Int)
        /// Changes owner and type halfway through, under a flash (a captured civilian).
        case recolor(owner: PlayerID, type: UnitType)
    }

    var kind: Kind
    var start: Double
    var duration: Double
    /// A fade's opacity when it began.
    var from: Float?
    var started = false

    var end: Double { start + duration }

    /// The share of a lunge at which the blow lands.
    static let lungeStrike: Float = 0.38
}

/// An arrow in flight or the burst of a blow, over the map.
struct MapEffect {
    enum Kind { case arrow, burst }
    var kind: Kind
    var start: Double
    var duration: Double
    /// Ground points (world, hex centres): where it flies from and to (a burst stays at `to`).
    var from: SIMD2<Float>
    var to: SIMD2<Float>
    /// Heights above them (tile sizes) up close: a figure's chest, a city's towers.
    var lift: SIMD2<Float>
}

/// An event to report through `onEventShown` when its moment comes: where the unit `unit` is
/// drawn then, else at `hex`.
struct AnimationCue {
    var at: Double
    var record: EventRecord
    var unit: UnitID?
    var hex: HexCoord
}

/// The event animations' clock and what runs on it.
struct AnimationState {
    var clock: Double = 0
    /// When each unit's scheduled steps end.
    var busy: [UnitID: Double] = [:]
    /// When the blows on each hex end (cities have no pictures to wait on).
    var busyHex: [HexCoord: Double] = [:]
    var effects: [MapEffect] = []
    /// Sorted by time.
    var cues: [AnimationCue] = []
    /// Units with steps.
    var active: Set<UnitID> = []
    /// Taken tribal villages fading out (waiting for their taker to arrive, or fading).
    var tribalVillageFades: [TribalVillageFade] = []
    /// Whether anything ran since `onAnimationsFinished` was last called.
    var running = false

    var isIdle: Bool { active.isEmpty && effects.isEmpty && cues.isEmpty && tribalVillageFades.isEmpty }
}

extension MapRenderer {
    // Timings (seconds at `animationSpeed` 1).
    static let stepDuration: Double = 0.09
    static let fadeDuration: Double = 0.22
    static let lungeDuration: Double = 0.36
    /// How far a lunge reaches toward its target (tile widths).
    static let lungeReach: Float = 0.36
    static let hitDuration: Double = 0.34
    static let deathDuration: Double = 0.55
    static let recolorDuration: Double = 0.4
    static let burstDuration: Double = 0.36
    /// An arrow's flight: a base time plus this per hex.
    static let arrowFlight: (base: Double, perHex: Double) = (0.26, 0.05)

    // MARK: Public controls

    /// Whether event animations are running: moves, attacks, fades and their effects.
    public var isAnimating: Bool { !animation.isIdle }

    /// Finishes every running animation at once: units go where they rest, ghosts go, effects
    /// end, and pending `onEventShown` reports fire now, in order; then `onAnimationsFinished`.
    public func skipAnimations() {
        guard animation.running || !animation.isIdle else { return }
        advanceAnimations(by: .infinity)
    }

    // MARK: Clock

    /// Runs the animation clock forward by `dt` seconds (scaled by `animationSpeed`): steps
    /// that finish take their final effect, running ones set this frame's poses, due events
    /// are reported, and when nothing is left `onAnimationsFinished` is called.
    func advanceAnimations(by dt: Float) {
        guard animation.running else { return }
        let step = dt.isFinite ? Double(dt * max(animationSpeed, 0.01)) : .infinity
        if step.isFinite {
            animation.clock += step
        } else {
            animation.clock = max(animation.busy.values.max() ?? 0, animation.cues.last?.at ?? 0,
                                  animation.effects.map(\.end).max() ?? 0, animation.tribalVillageFades.map(\.end).max() ?? 0,
                                  animation.clock) + 1
        }
        let now = animation.clock
        let reach = Float(layout.tileWidth) * Self.lungeReach
        for id in animation.active {
            guard var visual = unitVisuals[id] else {
                animation.active.remove(id)
                continue
            }
            visual.update(at: now, reach: reach)
            if visual.steps.isEmpty {
                animation.active.remove(id)
                if visual.ghost {
                    unitVisuals[id] = nil
                    continue
                }
                // At rest: show what the state says.
                visual.planned = nil
                if let unit = state.unit(id) { visual.hp = unit.hp }
            }
            unitVisuals[id] = visual
        }
        animation.effects.removeAll { $0.end <= now }
        finishTribalVillageFades(at: now)
        while let cue = animation.cues.first, cue.at <= now {
            animation.cues.removeFirst()
            report(cue)
        }
        animation.busy = animation.busy.filter { $0.value > now }
        animation.busyHex = animation.busyHex.filter { $0.value > now }
        if animation.isIdle {
            animation.running = false
            animation.clock = 0
            onAnimationsFinished?()
        }
    }

    private func report(_ cue: AnimationCue) {
        guard let callback = onEventShown else { return }
        let point = cue.unit.flatMap { unitVisuals[$0] != nil ? screenPoint(ofUnit: $0, lift: Self.reportLift) : nil }
            ?? screenPoint(of: cue.hex, lift: Self.reportLift)
        if let point { callback(cue.record, point) }
    }

    /// Where `onEventShown` points: about the top of a figure (tile sizes above its feet).
    static let reportLift: Float = 0.9

    // MARK: Scheduling

    /// Schedules the animations of the events the viewer sees (`apply`). `shownBefore`: the
    /// units drawn until now; `seenBefore`: per tile, whether the viewer saw it before the new
    /// state. Pictures of units that left the state or the view must still be in
    /// `unitVisuals`: those the events animate become ghosts.
    func scheduleAnimations(_ records: [EventRecord], shownBefore: Set<UnitID>, seenBefore: [Bool]) {
        var lastAttacker: UnitID?
        var arrivals: [HexCoord: Double] = [:]
        var captures: [(record: EventRecord, unit: UnitID, owner: PlayerID, type: UnitType, at: HexCoord)] = []
        let now = animation.clock
        func free(_ ids: UnitID?...) -> Double {
            ids.compactMap { $0 }.reduce(now) { max($0, animation.busy[$1] ?? now) }
        }
        func cue(_ at: Double, _ record: EventRecord, unit: UnitID?, hex: HexCoord) {
            let k = animation.cues.firstIndex { $0.at > at } ?? animation.cues.count
            animation.cues.insert(AnimationCue(at: at, record: record, unit: unit, hex: hex), at: k)
        }
        func seen(_ hex: HexCoord) -> Bool {
            guard let i = state.map.index(of: hex) else { return false }
            return !fogEnabled || seenBefore[i] || fogLevel(hex) == 0
        }

        // Each unit's next `unitMoved` record after a given one (its walks chain).
        var nextMove = [Int?](repeating: nil, count: records.count)
        var laterMove: [UnitID: Int] = [:]
        for (i, record) in records.enumerated().reversed() {
            guard case let .unitMoved(id, _, _) = record.event else { continue }
            nextMove[i] = laterMove[id]
            laterMove[id] = i
        }
        // Where each unit's walks scheduled so far end, and whether its picture shows there.
        var walked: [UnitID: (hex: HexCoord, showing: Bool)] = [:]
        // When each unit's latest walk reaches each of its tiles (normalized).
        var reached: [UnitID: [(hex: HexCoord, at: Double)]] = [:]

        for (i, record) in records.enumerated() {
            switch record.event {
            case let .unitMoved(id, from, path):
                var next: HexCoord?
                if let n = nextMove[i], case let .unitMoved(_, nextFrom, _) = records[n].event { next = nextFrom }
                if let walk = scheduleMove(id, from: from, path: path, shownBefore: shownBefore, seen: seen, start: free(id),
                                           previous: walked[id], next: next) {
                    walked[id] = (walk.hex, walk.showing)
                    reached[id] = walk.reached
                    if let last = path.last, let hex = state.map.normalize(last) { arrivals[hex] = walk.end }
                }

            case let .moveInterrupted(id, at):
                cue(free(id), record, unit: unitVisuals[id] != nil ? id : nil, hex: at)

            case let .combat(attacker, defender, from, to, ranged, dealt, taken):
                let a: UnitID? = if case let .unit(id) = attacker { id } else { nil }
                let d: UnitID? = if case let .unit(id) = defender { id } else { nil }
                let fromHex = state.map.normalize(from) ?? from, toHex = state.map.normalize(to) ?? to
                var start = free(a, d)
                start = max(start, animation.busyHex[fromHex] ?? now, animation.busyHex[toHex] ?? now)
                let fromP = point(of: a, hex: fromHex)
                let toP = nearest(point(of: d, hex: toHex), to: fromP)
                let attackerLift: Float = a == nil ? 0.75 : 0.5
                let impact: Double
                if ranged {
                    let launch = start + 0.05
                    let flight = Self.arrowFlight.base + Self.arrowFlight.perHex * Double(state.map.distance(from, to))
                    animation.effects.append(MapEffect(kind: .arrow, start: launch, duration: flight, from: fromP, to: toP,
                                                       lift: [attackerLift, 0.45]))
                    impact = launch + flight
                    if let a { animation.busy[a] = max(animation.busy[a] ?? now, launch + 0.12) }
                } else if let a, unitVisuals[a] != nil {
                    add(.lunge(toward: toP), to: a, at: start, duration: Self.lungeDuration)
                    impact = start + Self.lungeDuration * Double(UnitStep.lungeStrike)
                    animation.busy[a] = max(animation.busy[a] ?? now, start + Self.lungeDuration)
                } else {
                    impact = start + 0.05
                }
                if let d, unitVisuals[d] != nil {
                    add(.hit(damage: dealt), to: d, at: impact, duration: Self.hitDuration)
                }
                if let a, taken > 0, unitVisuals[a] != nil {
                    add(.hit(damage: taken), to: a, at: impact + 0.06, duration: Self.hitDuration)
                    animation.busy[a] = max(animation.busy[a] ?? now, impact + 0.06 + Self.hitDuration)
                }
                animation.effects.append(MapEffect(kind: .burst, start: impact, duration: Self.burstDuration, from: toP, to: toP,
                                                   lift: [0.45, 0.45]))
                cue(impact, record, unit: d.flatMap { unitVisuals[$0] != nil ? $0 : nil }, hex: toHex)
                let over = impact + Self.hitDuration
                if let d { animation.busy[d] = max(animation.busy[d] ?? now, over) }
                animation.busyHex[toHex] = max(animation.busyHex[toHex] ?? now, over)
                lastAttacker = a

            case let .unitKilled(id, _, _, at), let .unitDisbanded(id, _, _, at, _):
                guard unitVisuals[id] != nil else { break }
                let start = free(id)
                // A fallen unit flashes once more if it was not just hit, then fades.
                add(.fade(to: 0), to: id, at: start, duration: Self.deathDuration)
                unitVisuals[id]?.ghost = true
                animation.busy[id] = start + Self.deathDuration
                cue(start, record, unit: id, hex: at)
                if case .unitKilled = record.event, let winner = lastAttacker {
                    // The winner advances once the fallen have mostly faded.
                    animation.busy[winner] = max(animation.busy[winner] ?? now, start + Self.deathDuration * 0.7)
                }

            case let .unitCreated(id, _, _, at):
                guard unitVisuals[id] != nil, !shownBefore.contains(id) else { break }
                let start = free(id)
                unitVisuals[id]?.opacity = 0
                add(.fade(to: 1), to: id, at: start, duration: Self.fadeDuration * 1.5)
                animation.busy[id] = start + Self.fadeDuration * 1.5
                cue(start, record, unit: id, hex: at)

            case let .unitCaptured(_, new, type, _, to, at):
                captures.append((record, new, to, type, at))

            case let .tribalVillageTaken(at, _, unit, _):
                // The ghost fades from when the unit that took it reaches the tile (it comes after
                // the unit's move), else at once (a city's claim, or a taker the viewer does not
                // see walk in); the event is reported at the tile as the fade starts.
                let hex = state.map.normalize(at) ?? at
                let start = unit.flatMap { id in reached[id]?.first { $0.hex == hex }?.at } ?? max(now, animation.busyHex[hex] ?? now)
                scheduleTribalVillageFade(at: hex, start: start)
                cue(start, record, unit: nil, hex: hex)

            default:
                break
            }
        }
        // Captures, once their captors have arrived (whichever order the events came in).
        for (record, id, owner, type, at) in captures {
            guard unitVisuals[id] != nil else { continue }
            let hex = state.map.normalize(at) ?? at
            let start = max(free(id), arrivals[hex] ?? now)
            add(.recolor(owner: owner, type: type), to: id, at: start, duration: Self.recolorDuration)
            animation.busy[id] = start + Self.recolorDuration
            cue(start + Self.recolorDuration / 2, record, unit: id, hex: at)
        }
        if !animation.isIdle { animation.running = true }
    }

    /// Schedules a unit's walk (a foreign one's trimmed to the steps the viewer sees). It
    /// chains on `previous`, where this unit's walks scheduled earlier in the same `apply` end
    /// (and whether its picture shows there); `next` is where its next walk in the same
    /// `apply` starts. Returns where the walk ends (on the clock and on the map), whether the
    /// picture shows there and when it reaches each tile it walks (normalized), or nil when
    /// nothing of it is shown.
    private func scheduleMove(_ id: UnitID, from: HexCoord, path: [HexCoord], shownBefore: Set<UnitID>,
                              seen: (HexCoord) -> Bool, start: Double, previous: (hex: HexCoord, showing: Bool)?,
                              next: HexCoord?) -> (end: Double, hex: HexCoord, showing: Bool, reached: [(hex: HexCoord, at: Double)])? {
        guard !path.isEmpty else { return nil }
        let hexes = [from] + path
        let live = state.unit(id)
        let own = live?.owner == viewer
        var first = 1, last = path.count
        if !own {
            let shown = (1..<hexes.count).filter { seen(hexes[$0 - 1]) || seen(hexes[$0]) }
            guard let f = shown.first, let l = shown.last else { return nil }
            (first, last) = (f, l)
        }
        if unitVisuals[id] == nil {
            // Never drawn and not in sight now: a ghost that walks through the seen steps.
            guard let live else { return nil }
            let c = Self.vec(layout.center(of: hexes[first - 1]))
            var ghost = UnitVisual(type: live.type, owner: live.owner, base: c, position: c)
            ghost.ghost = true
            ghost.opacity = 0
            ghost.hp = live.hp
            unitVisuals[id] = ghost
        }
        guard var visual = unitVisuals[id] else { return nil }
        func same(_ a: HexCoord, _ b: HexCoord) -> Bool { state.map.normalize(a) == state.map.normalize(b) }
        // Whether the picture shows where this walk begins: chained on a walk that ended in
        // sight right there, or (the first walk) drawn before and seen from its first step.
        let wasShown = previous.map { $0.showing && same($0.hex, hexes[first - 1]) } ?? (shownBefore.contains(id) && first == 1)
        // Whether it shows where this walk ends: it reaches the end in sight and either walks
        // on from there, or (its last walk) rests there in sight now.
        let reachesEnd = last == path.count
        let inSight = live.map { $0.owner == viewer || fogLevel($0.position) == 0 } ?? false
        let endsShown: Bool
        if let next {
            endsShown = reachesEnd && same(path[path.count - 1], next)
        } else {
            endsShown = reachesEnd && inSight && same(path[path.count - 1], live?.position ?? from)
        }
        // Where the walk starts: where the picture stands (or will, after its scheduled moves),
        // else the first seen step's tile, fading in there.
        var at: SIMD2<Float>
        if wasShown {
            at = visual.planned ?? visual.position
        } else {
            at = Self.vec(layout.center(of: hexes[first - 1]))
            if previous == nil {
                visual.position = at
                visual.opacity = 0
            } else {
                // Out of sight since its previous walk ended: it reappears here.
                visual.steps.append(UnitStep(kind: .move(to: at), start: start, duration: 0))
            }
        }
        var t = start
        var x = at.x
        var reached: [(hex: HexCoord, at: Double)] = []
        for k in first...last {
            var p = Self.vec(layout.center(of: hexes[k]))
            if k == path.count, endsShown, next == nil { p = visual.base }
            p.x = Float(layout.nearestCopy(of: CGFloat(p.x), to: CGFloat(x)))
            x = p.x
            visual.steps.append(UnitStep(kind: .move(to: p), start: t, duration: Self.stepDuration))
            t += Self.stepDuration
            if let hex = state.map.normalize(hexes[k]) { reached.append((hex, t)) }
            at = p
        }
        if !wasShown {
            visual.steps.append(UnitStep(kind: .fade(to: 1), start: start, duration: Self.fadeDuration))
        }
        if !endsShown {
            visual.steps.append(UnitStep(kind: .fade(to: 0), start: max(start, t - Self.fadeDuration), duration: Self.fadeDuration))
        }
        if next == nil {
            if inSight, !endsShown {
                // In sight now but resting where this walk does not lead (it cannot normally
                // happen): it reappears where it rests rather than vanishing.
                visual.steps.append(UnitStep(kind: .move(to: visual.base), start: t, duration: 0))
                visual.steps.append(UnitStep(kind: .fade(to: 1), start: t, duration: Self.fadeDuration))
                t += Self.fadeDuration
                at = visual.base
            }
            // Its last walk decides whether the picture stays when the steps are done.
            visual.ghost = !inSight
        }
        // By start time; steps starting together keep the order they were added in.
        visual.steps = visual.steps.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        visual.planned = at
        unitVisuals[id] = visual
        animation.active.insert(id)
        animation.busy[id] = t
        return (t, path[last - 1], endsShown, reached)
    }

    /// Adds a step to a unit's picture.
    private func add(_ kind: UnitStep.Kind, to id: UnitID, at start: Double, duration: Double) {
        guard var visual = unitVisuals[id] else { return }
        let step = UnitStep(kind: kind, start: start, duration: duration)
        let k = visual.steps.firstIndex { $0.start > start } ?? visual.steps.count
        visual.steps.insert(step, at: k)
        unitVisuals[id] = visual
        animation.active.insert(id)
    }

    /// Where a combatant stands: its picture's place (where its scheduled moves end) or the
    /// hex's centre.
    private func point(of unit: UnitID?, hex: HexCoord) -> SIMD2<Float> {
        if let unit, let visual = unitVisuals[unit] {
            return visual.planned ?? (visual.steps.isEmpty ? visual.base : visual.position)
        }
        return Self.vec(layout.center(of: hex))
    }

    private func nearest(_ p: SIMD2<Float>, to q: SIMD2<Float>) -> SIMD2<Float> {
        [Float(layout.nearestCopy(of: CGFloat(p.x), to: CGFloat(q.x))), p.y]
    }
}

extension MapEffect {
    var end: Double { start + duration }
}

extension UnitVisual {
    /// Runs its steps up to `now`: finished ones take their final effect and go, running ones
    /// set this frame's pose. `reach`: how far a lunge goes (world units).
    mutating func update(at now: Double, reach: Float) {
        current = nil
        flash = 0
        hpTrail = 0
        var i = 0
        while i < steps.count {
            var step = steps[i]
            guard step.start <= now else {
                i += 1
                continue
            }
            let done = now >= step.end
            let t = done || step.duration <= 0 ? 1 : Float((now - step.start) / step.duration)
            switch step.kind {
            case let .move(to):
                if abs(to.x - position.x) > 1e-3 { facesEast = to.x > position.x }
                if done {
                    position = to
                } else {
                    current = position + (to - position) * t
                }
            case let .lunge(toward):
                let from = current ?? position
                var d = toward - from
                let l = simd_length(d)
                if abs(d.x) > 1e-3 { facesEast = d.x > 0 }
                if !done, l > 1e-3 {
                    let k = UnitStep.lungeStrike
                    let out = t < k ? Self.ease(t / k) : 1 - Self.ease((t - k) / (1 - k))
                    d *= min(reach, 0.6 * l) / l
                    current = from + d * out
                }
            case let .fade(to):
                if !step.started {
                    step.from = opacity
                    step.started = true
                }
                let from = step.from ?? opacity
                opacity = from + (to - from) * Self.ease(t)
            case let .hit(damage):
                let before = hp
                if !step.started {
                    hp = max(hp - damage, 0)
                    step.started = true
                    step.from = Float(before - hp) / 100
                }
                if !done {
                    flash = max(flash, (1 - t) * (1 - t))
                    hpTrail = max(hpTrail, (step.from ?? 0) * (1 - Self.ease(t)))
                }
            case let .recolor(owner, type):
                if t >= 0.5 {
                    self.owner = owner
                    self.type = type
                }
                if !done { flash = max(flash, 1 - abs(2 * t - 1)) }
            }
            if done {
                steps.remove(at: i)
            } else {
                steps[i] = step
                i += 1
            }
        }
    }

    private static func ease(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
