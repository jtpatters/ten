import GameCore

// Tap routing (M1 §16 tap rules). With an own unit selected that can still move this phase,
// some taps that would select or inspect what stands on a tile route the unit there instead,
// because that is what they most likely mean: an own city's sprite (the unit goes home or
// garrisons it; the banner still selects the city), own units of the other kind (a Warrior
// escorting a Settler, a Builder entering a garrisoned city) and enemy civilians alone at war
// (a capture, M1 §7.3). Each previews the route with a hint; the second tap on the tile moves
// (tap rule 1). With no route there (a unit of the same kind holds the city), the tap says why,
// then selects as it otherwise would.
extension GameSession {
    /// The selected unit, when a tap on `hex` may route it instead of selecting what stands
    /// there: own, not on `hex`, input enabled, and able to move this phase (its movement range
    /// shows). With no moves left the tap selects as before: after a unit's last move, a tap on
    /// a city or another unit most likely means that city or unit.
    private func unitToRoute(to hex: HexCoord) -> GameCore.Unit? {
        guard isInputEnabled, let unit = selectedUnit, unit.owner == viewer, unit.position != hex,
              unit.movesLeft > 0, !unit.zocStopped else { return nil }
        return unit
    }

    /// Whether `unit` has a route to `hex`, by the viewer's knowledge.
    private func hasRoute(_ unit: GameCore.Unit, to hex: HexCoord) -> Bool {
        view.path(for: unit.id, to: hex).map { !$0.steps.isEmpty } ?? false
    }

    /// Tap rule 3, an own city's sprite: with an own unit selected that can move and has a
    /// route into the city (in any number of turns), previews it ("Tap again to move into
    /// Rome"). False when the tap selects the city instead: no unit to route, or no route there
    /// (a unit of the same kind already stands in it), which it first says ("Rome already
    /// holds a military unit (your Warrior)").
    func routeIntoOwnCity(_ city: CityID, at hex: HexCoord) -> Bool {
        guard let unit = unitToRoute(to: hex), let name = view.city(city)?.name else { return false }
        guard hasRoute(unit, to: hex) else {
            showRouteRefusal(for: unit, to: hex)
            return false
        }
        previewPath(for: unit, to: hex)
        showRouteHint("Tap again to move into \(name)")
        return true
    }

    /// Tap rule 4, own units: a tile holding only own units of the other kind than the selected
    /// unit (civilian or military, which may share a tile), when the selected unit can move
    /// and has a route there. False when the tap cycles the tile's selectables instead, after
    /// saying why when that tile has no route for the unit.
    func routeOntoOwnUnits(at hex: HexCoord) -> Bool {
        guard let unit = unitToRoute(to: hex) else { return false }
        let here = view.units(at: hex)
        guard let other = here.first, here.allSatisfy({ $0.owner == viewer && $0.type.isCivilian != unit.type.isCivilian }) else {
            return false
        }
        guard hasRoute(unit, to: hex) else {
            showRouteRefusal(for: unit, to: hex)
            return false
        }
        previewPath(for: unit, to: hex)
        if let city = view.cities.first(where: { $0.position == hex }) {
            showRouteHint("Tap again to move into \(city.name)")
        } else {
            showRouteHint("Tap again to move the \(unit.type.displayName) to the \(other.type.displayName)’s tile")
        }
        return true
    }

    /// Tap rule 4b, enemy civilians: with an own military unit selected that reaches the tile
    /// this phase, previews the move that captures them ("Tap again to capture the Settler").
    func routeToCapture(at hex: HexCoord) -> Bool {
        guard let unit = unitToRoute(to: hex), let victim = captureVictim(at: hex, by: unit) else { return false }
        previewPath(for: unit, to: hex)
        showRouteHint("Tap again to capture the \(victim.type.displayName)")
        return true
    }

    /// The enemy civilian an own military unit captures by moving onto `hex` this phase: the
    /// tile is in sight, holds only civilians of players the viewer is at war with (no city),
    /// and the unit reaches it this phase. Farther away a capture is not promised: the
    /// civilian moves on.
    func captureVictim(at hex: HexCoord, by unit: GameCore.Unit) -> GameCore.Unit? {
        let view = self.view
        // Every step takes at least a point, so a tile farther than the points left is out of
        // reach this phase (checked before the path search).
        guard isInputEnabled, unit.owner == viewer, !unit.type.isCivilian, unit.position != hex,
              view.distance(unit.position, hex) <= unit.movesLeft else { return nil }
        let here = view.units(at: hex)
        guard let victim = here.first, here.allSatisfy({ $0.owner != viewer && $0.type.isCivilian && view.isAtWar(with: $0.owner) }),
              view.knownCity(at: hex) == nil, let path = view.path(for: unit.id, to: hex), path.turns == 1 else { return nil }
        return victim
    }

    /// Where the selected own military unit would capture enemy civilians this phase: marked
    /// like attack targets (`refreshSelection`), so the capture is visible before the tap.
    func captureTargets(for unit: GameCore.Unit) -> [HexCoord] {
        guard isInputEnabled, unit.owner == viewer, !unit.type.isCivilian, unit.movesLeft > 0, !unit.zocStopped else { return [] }
        let view = self.view
        var tiles: [HexCoord] = []
        for other in view.visibleForeignUnits where other.type.isCivilian && view.isAtWar(with: other.owner) && !tiles.contains(other.position) {
            if captureVictim(at: other.position, by: unit) != nil { tiles.append(other.position) }
        }
        return tiles
    }

    /// The tile sheet's move button: "Capture Settler (becomes a Builder)" or "Capture Builder"
    /// where the move captures, else "Move Warrior here".
    func moveHereTitle(for unit: GameCore.Unit, to hex: HexCoord) -> String {
        guard let victim = captureVictim(at: hex, by: unit) else { return "Move \(unit.type.displayName) here" }
        if let becomes = state.rules.unit(victim.type).capturedAs, becomes != victim.type {
            return "Capture \(victim.type.displayName) (becomes a \(becomes.displayName))"
        }
        return "Capture \(victim.type.displayName)"
    }
}
