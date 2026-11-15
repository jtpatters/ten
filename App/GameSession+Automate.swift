import GameAI
import GameCore
import Persistence
import SwiftUI

// The Automate order for Builders, an App-side convenience and no rule (as the Explore order):
// the engine never hears of it. An automated Builder is played, at the start of each of the
// viewer's phases (before the autosave) and right after the order is given, by the AI's own
// Builder logic (`AIPlayer.builderCommands`: improve the best worked tile, Farms by fresh water
// first, Mines on hills, then lay the roads between the cities; keep out of enemies' reach),
// reading only the viewer's knowledge, through ordinary commands. With nothing left to do it
// waits in the nearest city, still automated, and goes back to work when there is some. The
// order ends when the player gives the Builder another order (or taps Stop), or when the
// Builder is gone (its charges used up). Automated Builders are not in the attention queue.
// The order lives in the save header (`SaveSummary.explorers`, entries marked `automated`), so
// it survives save, quit and Continue.

/// The session's automated Builders, by unit id.
struct BuilderAutomation: Equatable {
    private(set) var units: [UnitID] = []
    /// What each did in its last phase, for its card ("Automated · building a Farm").
    private(set) var lastDeed: [UnitID: String] = [:]

    func contains(_ id: UnitID) -> Bool { units.contains(id) }

    mutating func add(_ id: UnitID) {
        guard !units.contains(id) else { return }
        units.append(id)
        units.sort()
    }

    mutating func remove(_ id: UnitID) {
        units.removeAll { $0 == id }
        lastDeed[id] = nil
    }

    mutating func note(_ id: UnitID, _ deed: String?) { lastDeed[id] = deed }
}

extension GameSession {
    /// Whether own unit `id` is automated.
    func isAutomated(_ id: UnitID) -> Bool { automation.contains(id) }

    /// Whether the unit may take the order: an own Builder with charges left.
    func canAutomate(_ unit: GameCore.Unit) -> Bool {
        unit.owner == viewer && unit.type == .builder && unit.charges > 0
    }

    /// The unit card's Automate tile: gives the order, or ends it.
    func toggleAutomate(_ id: UnitID) {
        if isAutomated(id) {
            automation.remove(id)
            show("Builder awaits your orders")
            refreshSelection()
        } else {
            startAutomating(id)
        }
    }

    /// Gives own Builder `id` the order and plays its first steps now. A march or a rest under way
    /// gives way to it, and a route previewed for it goes.
    func startAutomating(_ id: UnitID) {
        guard isInputEnabled else {
            show(waitingFor.map { "Waiting for \($0.civName)" } ?? "Not your turn")
            return
        }
        guard let unit = view.unit(id), canAutomate(unit) else { return }
        clearPreviews()
        if unit.destination != nil { perform(.cancelOrders(unit: id)) }
        if unit.activity == .sleeping || unit.activity == .fortified || unit.activity == .fortifying {
            perform(.wake(unit: id))
        }
        automation.add(id)
        stepAutomated(only: id)
        show("Builder automated: it improves your cities' tiles and lays roads on its own")
    }

    /// `perform`'s hook: an order the player gives an automated Builder ends its automation.
    func automateHeard(_ command: Command) {
        let id: UnitID? = if case let .buildRoad(unit) = command { unit } else { Self.orderedUnit(of: command) }
        guard let id, isAutomated(id) else { return }
        automation.remove(id)
    }

    /// After a load, before play begins: the Builders the save's header kept automated.
    func resumeAutomating(_ saved: [SavedExplorer]) {
        let view = self.view
        for record in saved where record.automated {
            guard let unit = view.unit(record.unit), canAutomate(unit) else { continue }
            automation.add(record.unit)
        }
    }

    /// The viewer's phase began: every automated Builder works.
    func continueAutomating() {
        stepAutomated(only: nil)
    }

    /// The AI's Builder logic for the automated Builders (or only `only`), applied command by
    /// command as the viewer's own (without the march's stop notice). Builders gone since (their
    /// charges used up, killed or captured) leave the order.
    private func stepAutomated(only: UnitID?) {
        guard isInputEnabled else { return }
        for id in automation.units where view.unit(id).map(canAutomate) != true { automation.remove(id) }
        let ids = automation.units.filter { only == nil || $0 == only }
        guard !ids.isEmpty else { return }
        let commands = AIPlayer.builderCommands(state, player: viewer, builders: ids)
        var deeds: [UnitID: String] = [:]
        for command in commands {
            guard isInputEnabled else { break }
            do {
                let events = try applyOthers(command, by: viewer)
                stateChanged(events: events.filter {
                    if case .moveInterrupted = $0.event { false } else { true }
                }, byViewer: true)
                switch command {
                case let .buildImprovement(unit, improvement):
                    deeds[unit] = "built a \(state.rules.improvement(improvement).displayName)"
                case let .buildRoad(unit): deeds[unit] = "laid a road"
                case let .moveUnit(unit, _):
                    if deeds[unit] == nil { deeds[unit] = "on its way to work" }
                default: break
                }
                if !isViewerPhase {
                    playOtherPhases()
                    break
                }
            } catch {
                #if DEBUG
                DebugLog.write("Automated Builder command \(command) refused: \(error)")
                #endif
            }
        }
        for id in ids {
            if view.unit(id) == nil {
                automation.remove(id)
            } else {
                automation.note(id, deeds[id] ?? "waiting for work")
            }
        }
        refreshSelection()
    }

    /// The card's badge for an automated Builder.
    func automateBadge(of unit: GameCore.Unit) -> String? {
        isAutomated(unit.id) ? "Automated" : nil
    }

    /// The card's line: what the Builder did this turn.
    func automateHint(of unit: GameCore.Unit) -> String? {
        guard isAutomated(unit.id) else { return nil }
        let deed = automation.lastDeed[unit.id] ?? "working"
        return "Automated · \(deed). Give it any order to take back control."
    }
}

// MARK: - The unit card's Automate tile and line

/// The Automate tile of a Builder's action bar: Automate, or Stop while automated.
struct AutomateTile: View {
    let session: GameSession
    let unit: GameCore.Unit
    var compact = false
    @State private var pressed = false

    var body: some View {
        let on = session.isAutomated(unit.id)
        let title = on ? "Stop Auto" : "Automate"
        Label(title, systemImage: on ? "stop.circle" : "gearshape.2")
            .actionTile(pressed: pressed, lit: session.isInputEnabled, compact: compact, fill: true)
            .onTapGesture { session.toggleAutomate(unit.id) }
            .onLongPressGesture(minimumDuration: 0.4, perform: {
                session.show(on ? "Stop automating: the Builder waits for your orders"
                    : "Automate: the Builder improves your worked tiles and lays roads by itself, every turn")
            }, onPressingChanged: { pressed = $0 })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(on ? "The Builder waits for your orders again."
                : "The Builder improves your worked tiles and lays roads by itself, every turn.")
            .accessibilityAction { session.toggleAutomate(unit.id) }
    }
}

/// The card's line about the order.
struct AutomateRow: View {
    let session: GameSession
    let unit: GameCore.Unit

    var body: some View {
        if let text = session.automateHint(of: unit) {
            Hint(systemImage: "gearshape.2", text: text)
        }
    }
}
