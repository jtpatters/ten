import GameCore
import SwiftUI

// Cards about a tile (M1 §16): the info card for something foreign (a tap), and the tile sheet
// (a long-press). Both read only what the viewer knows: a foreign city as last seen, units in
// sight, the ground as explored.

/// A foreign city as last seen and the foreign units in sight on a tile: the city's name, owner,
/// population, HP, walls and City Strength (with its parts); each unit's type, HP and strength.
struct InfoCard: View {
    let session: GameSession
    let hex: HexCoord

    var body: some View {
        let view = session.view
        let city = view.knownCity(at: hex)
        let units = view.units(at: hex).filter { $0.owner != session.viewer }
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            if let city {
                CardHeader(title: city.name, player: city.owner, onClose: { session.closeInspector() }) {
                    if city.capital {
                        Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(HUD.gilt)
                            .accessibilityLabel("Capital")
                    }
                }
                relationRow(city.owner, view)
                cityRows(city, view)
                if !units.isEmpty { Divider().overlay(HUD.inkFaint) }
            } else if let first = units.first {
                CardHeader(title: units.count == 1 ? first.type.displayName : "\(units.count) units", player: first.owner,
                           onClose: { session.closeInspector() })
                relationRow(first.owner, view)
            } else {
                CardHeader(title: "Nothing seen", systemImage: "eye.slash", onClose: { session.closeInspector() })
            }
            // A lone unit is named in the header; a stack (or a garrison) lists each.
            ForEach(units, id: \.id) { unit in unitRow(unit, view, named: city != nil || units.count > 1) }
            if session.showStats {
                Text("\(hex.description) · offset \(hex.offset.description)").font(.caption2.monospaced()).foregroundStyle(HUD.inkSoft)
            }
        }
        .hudCard()
    }

    private func relationRow(_ owner: PlayerID, _ view: PlayerView) -> some View {
        let atWar = view.isAtWar(with: owner)
        return HStack(spacing: HUD.Space.s) {
            Text(session.civName(of: owner)).font(HUD.body(.subheadline))
            if owner != session.viewer {
                KindBadge(text: atWar ? "At war" : "At peace", tint: atWar ? HUD.danger : HUD.inkSoft)
            }
        }
    }

    private func cityRows(_ city: CitySighting, _ view: PlayerView) -> some View {
        let maxHP = max(view.rules.constants.city.maxHP, 1)
        let seen = view.isVisible(city.position)
        let strength = view.knownCityStrength(at: hex)
        return VStack(alignment: .leading, spacing: HUD.Space.s) {
            HStack(spacing: HUD.Space.l) {
                StatPill(systemImage: "person.2.fill", value: "\(city.population)", name: "Population")
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HUD.health(Double(city.hp) / Double(maxHP)))
                    HealthBar(fraction: Double(city.hp) / Double(maxHP), height: 6).frame(width: 56)
                    Text("\(city.hp)/\(maxHP)").font(HUD.numeric(.footnote))
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Health \(city.hp) of \(maxHP)")
                if city.walls {
                    StatPill(systemImage: "building.2.fill", value: "\(city.wallHP)", name: "Wall HP")
                }
            }
            if let strength {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: HUD.Space.xs) {
                        Image(systemName: "shield.lefthalf.filled").font(.system(size: 12, weight: .semibold))
                        Text("City Strength \(strength.total)").font(HUD.title(.subheadline))
                    }
                    Text(strengthParts(strength)).font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                }
                .accessibilityElement(children: .combine)
            }
            if !seen {
                Label("As last seen on turn \(city.turnSeen)", systemImage: "clock.arrow.circlepath")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
            }
            // A selected ranged unit cannot shoot what it does not see: how near to come.
            if let unit = session.selectedUnit, let hint = view.outOfSightShotHint(unit: unit.id, city: city) {
                Label(hint, systemImage: "scope")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func strengthParts(_ strength: Strength) -> String {
        (["Base \(strength.base)"] + strength.modifiers.map { "\($0.name) \(YieldChip.signed($0.value))" }).joined(separator: " · ")
    }

    private func unitRow(_ unit: GameCore.Unit, _ view: PlayerView, named: Bool) -> some View {
        let def = view.rules.unit(unit.type)
        let maxHP = max(view.rules.constants.healing.maxHP, 1)
        return HStack(spacing: HUD.Space.s) {
            if named {
                PlayerEmblem(player: unit.owner, size: 20)
                Text(unit.type.displayName).font(HUD.title(.subheadline))
                Spacer(minLength: HUD.Space.s)
            }
            Image(systemName: "heart.fill").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HUD.health(Double(unit.hp) / Double(maxHP)))
            HStack(spacing: 4) {
                HealthBar(fraction: Double(unit.hp) / Double(maxHP), height: 6).frame(width: 40)
                Text("\(unit.hp)").font(HUD.numeric(.footnote))
            }
            .fixedSize()
            if def.isMilitary {
                StatPill(systemImage: "shield.lefthalf.filled", value: "\(def.strength)", name: "Strength")
                if def.isRanged {
                    StatPill(systemImage: "scope", value: "\(def.rangedStrength)", name: "Ranged strength")
                }
            } else {
                KindBadge(text: "Civilian")
            }
            if !named { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.civName(of: unit.owner)) \(unit.type.displayName), health \(unit.hp)"
            + (def.isMilitary ? ", strength \(def.strength)" + (def.isRanged ? ", ranged \(def.rangedStrength)" : "") : ", civilian"))
    }
}

/// The tile sheet (long-press): the ground as explored, its yields for the viewer, the owner and
/// improvement as last seen, what it costs to enter and what it gives a defender, a river's
/// toll, and what stands on it (a tribal village too). With an own unit selected, "Move here"
/// previews its route.
struct TileSheet: View {
    let session: GameSession
    let hex: HexCoord

    var body: some View {
        let view = session.view
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            if let facts = view.tileFacts(at: hex) {
                CardHeader(title: TileText.name(facts.tile), systemImage: "map", onClose: { session.closeInspector() })
                content(facts, view)
            } else {
                CardHeader(title: "Unexplored", systemImage: "questionmark.circle", onClose: { session.closeInspector() })
                Text("No one of yours has seen this land.").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
            }
            if session.showStats {
                Text("\(hex.description) · offset \(hex.offset.description)").font(.caption2.monospaced()).foregroundStyle(HUD.inkSoft)
            }
        }
        .hudCard()
    }

    @ViewBuilder
    private func content(_ facts: TileFacts, _ view: PlayerView) -> some View {
        // Yields, owner, improvement.
        HStack(spacing: HUD.Space.m) {
            YieldNumber(kind: .food, value: facts.yields.food)
            YieldNumber(kind: .production, value: facts.yields.production)
            YieldNumber(kind: .gold, value: facts.yields.gold)
            if let improvement = facts.tile.improvement {
                KindBadge(text: view.rules.improvement(improvement).displayName, tint: HUD.Yield.production)
            }
            Spacer(minLength: 0)
            if let owner = facts.owner {
                HStack(spacing: HUD.Space.xs) {
                    PlayerEmblem(player: owner, size: 16)
                    Text(owner == session.viewer ? "Yours" : session.civName(of: owner)).font(HUD.body(.caption))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Owned by \(owner == session.viewer ? "you" : session.civName(of: owner))")
            } else {
                Text("Unclaimed").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
            }
        }
        // Movement and defence.
        VStack(alignment: .leading, spacing: 3) {
            row(systemImage: "figure.walk", label: "Move cost", value: facts.moveCost.map { "\($0)" } ?? "Impassable",
                note: facts.riverCrossingCost > 0 ? "+\(facts.riverCrossingCost) across the river" : nil)
            if facts.defense.isEmpty {
                row(systemImage: "shield", label: "Defence", value: "None", note: nil)
            } else {
                row(systemImage: "shield.lefthalf.filled", label: "Defence", value: YieldChip.signed(facts.totalDefense),
                    note: facts.defense.map { "\($0.name) \(YieldChip.signed($0.value))" }.joined(separator: ", "))
            }
            if facts.riverAttackModifier != 0 {
                row(systemImage: "water.waves", label: "River", value: YieldChip.signed(facts.riverAttackModifier),
                    note: "to melee attacks across it")
            }
            if facts.cityStrength != 0 {
                row(systemImage: "building.columns", label: "City Strength", value: YieldChip.signed(facts.cityStrength),
                    note: "for a city here")
            }
        }
        .padding(.horizontal, HUD.Space.s)
        .padding(.vertical, HUD.Space.xs + 2)
        .parchmentWell()
        // A resource the viewer knows here (M2 §3.1).
        if let resource = view.resource(at: hex), let def = view.rules.resource(resource) {
            resourceRow(def, view)
        }
        // Land of a player at peace: closed to military units (M1 §9).
        let closed = facts.owner.map { $0 != session.viewer && view.landClosed(by: $0) } ?? false
        if closed {
            Label("Closed to your military (at peace)", systemImage: "hand.raised.fill")
                .font(HUD.body(.caption))
                .foregroundStyle(HUD.inkSoft)
        }
        // With a Settler selected: the site's quality as the overlay shows it, or why not.
        if let unit = session.selectedUnit, unit.owner == session.viewer, view.rules.unit(unit.type).foundsCity {
            siteRow(view, settler: unit)
        }
        // What stands on it.
        if let city = facts.city {
            HStack(spacing: HUD.Space.s) {
                PlayerEmblem(player: city.owner, size: 18)
                Text(city.name).font(HUD.title(.subheadline))
                Text("population \(city.population)").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
            }
            .accessibilityElement(children: .combine)
        }
        let units = view.units(at: hex)
        if !units.isEmpty {
            Text(units.map { ($0.owner == session.viewer ? "" : "\(session.civName(of: $0.owner)) ") + $0.type.displayName }
                .joined(separator: ", "))
                .font(HUD.body(.caption))
        }
        if let village = facts.tribalVillage {
            tribalVillageRow(village)
        }
        if !facts.isVisible {
            Label("As last seen", systemImage: "clock.arrow.circlepath").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
        }
        if let unit = session.selectedUnit, unit.owner == session.viewer, unit.position != hex, session.isInputEnabled,
           facts.moveCost != nil, let refusal = view.routeRefusal(for: unit.id, to: hex) {
            // No route (closed borders, a full city, no way through): say why instead of
            // offering a move that would only be refused (M1 §16: a refusal says why), unless
            // the closed-land row above says it already.
            if case .closedBorders = refusal, closed {
                EmptyView()
            } else {
                Label(RouteText.refusal(refusal, unit: unit, goal: hex, view: view, civName: session.civName(of:)),
                      systemImage: "nosign")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let unit = session.selectedUnit, unit.owner == session.viewer, unit.position != hex, session.isInputEnabled,
           facts.moveCost != nil {
            Button {
                session.routeSelectedUnit(to: hex)
            } label: {
                Label(session.moveHereTitle(for: unit, to: hex), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ParchmentButtonStyle())
            .accessibilityHint("Shows the route; confirm with Move.")
        }
    }

    /// A tribal village the viewer knows of here (M1 §7.7): what it gives, and whether it is
    /// in sight now or remembered.
    private func resourceRow(_ def: ResourceDef, _ view: PlayerView) -> some View {
        Label {
            Text(Self.resourceLine(def, rules: view.rules)).font(HUD.body(.caption)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: Self.resourceSymbol(def.kind)).foregroundStyle(HUD.gilt)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Iron (strategic): +1 Production; improve with a Mine."
    static func resourceLine(_ def: ResourceDef, rules: Ruleset) -> String {
        var parts: [String] = []
        if def.food > 0 { parts.append("+\(def.food) Food") }
        if def.production > 0 { parts.append("+\(def.production) Production") }
        if def.gold > 0 { parts.append("+\(def.gold) Gold") }
        if def.culture > 0 { parts.append("+\(def.culture) Culture") }
        let improvement = Improvement.allCases.first { "\($0)" == def.improvement }.map { rules.improvement($0).displayName }
        let yields = parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")
        return "\(def.displayName) (\(def.kind.rawValue))\(yields)" + (improvement.map { "; improve with \(CivText.article($0)) \($0)" } ?? "")
    }

    static func resourceSymbol(_ kind: ResourceKind) -> String {
        switch kind {
        case .bonus: "leaf.circle.fill"
        case .luxury: "sparkles"
        case .strategic: "shield.lefthalf.filled"
        }
    }

    private func tribalVillageRow(_ village: TileTribalVillage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(Self.tribalVillageLine, systemImage: "house.lodge.fill")
                .font(HUD.body(.caption).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            // Not the clock of the "As last seen" line below it on a remembered tile.
            Label(Self.tribalVillageState(village), systemImage: village == .seen ? "eye" : "eye.slash")
                .font(HUD.body(.caption))
                .foregroundStyle(HUD.inkSoft)
        }
        .accessibilityElement(children: .combine)
    }

    static let tribalVillageLine = "Tribal village: the first to arrive gets a gift (Gold, Science or a Builder)"

    /// "Seen now", or "Remembered: it may be gone" (its tile is out of sight).
    static func tribalVillageState(_ village: TileTribalVillage) -> String {
        village == .seen ? "Seen now" : "Remembered: it may be gone"
    }

    /// "City site: good" (ranked, as the overlay shades it, against the sites around the
    /// Settler) with what it counts ("Within 2: 14 Food, 9 Production"), or why no city can be
    /// founded here.
    @ViewBuilder
    private func siteRow(_ view: PlayerView, settler: GameCore.Unit) -> some View {
        if let problem = view.foundingProblem(at: hex) {
            Label("No city here: \(Self.reason(problem, view: view))", systemImage: "xmark.circle")
                .font(HUD.body(.caption))
                .foregroundStyle(HUD.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let ranking = view.siteRanking(around: settler.position, radius: MapAdapter.siteRadius)
            let quality = ranking.quality(of: view.settleScore(at: hex))
            let tint = switch quality {
            case .good: HUD.gilt
            case .fair: HUD.ink
            case .poor: HUD.inkSoft
            }
            VStack(alignment: .leading, spacing: 2) {
                Label("City site: \(quality.rawValue)", systemImage: quality == .good ? "star.circle.fill" : "building.columns")
                    .font(HUD.body(.caption).weight(.semibold))
                    .foregroundStyle(tint)
                if let facts = view.siteFacts(at: hex) {
                    Text(Self.siteNumbers(facts))
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "Within 2: 14 Food, 9 Production, 2 Gold · fresh water, on the coast · 3 tiles
    /// unexplored": what the site's score counts.
    static func siteNumbers(_ facts: SiteFacts) -> String {
        var yields = ["\(facts.yields.food) Food", "\(facts.yields.production) Production"]
        if facts.yields.gold > 0 { yields.append("\(facts.yields.gold) Gold") }
        var parts = ["Within \(facts.radius): " + yields.joined(separator: ", ")]
        let bonuses = [facts.freshWater ? "fresh water" : nil, facts.coast ? "on the coast" : nil, facts.hills ? "on hills" : nil]
            .compactMap { $0 }
        if !bonuses.isEmpty { parts.append(bonuses.joined(separator: ", ")) }
        if facts.unexplored > 0 { parts.append(facts.unexplored == 1 ? "1 tile unexplored" : "\(facts.unexplored) tiles unexplored") }
        return parts.joined(separator: " · ")
    }

    /// Why no city can be founded on a tile, after "No city here: ".
    static func reason(_ problem: FoundingProblem, view: PlayerView) -> String {
        switch problem {
        case .offMap: return "off the map"
        case .unexplored: return "unexplored"
        case .water: return "cities stand on land, not water"
        case .mountains: return "cities can't stand on mountains"
        case let .feature(name):
            // "on ice", "on an oasis".
            return "cities can't stand on \("aeiou".contains(name.prefix(1)) ? "an " : "")\(name)"
        case let .owned(owner):
            let civ = view.civ(of: owner)
            let name = civ.flatMap { view.rules.civ($0)?.name } ?? "another civilisation"
            return "\(civ.map { CivText.adjective($0, name: name) } ?? name) land"
        case let .tooClose(_, name, minimum):
            return "too close to \(name) (cities must be at least \(minimum) tiles apart)"
        }
    }

    private func row(systemImage: String, label: String, value: String, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HUD.Space.s) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(HUD.inkSoft).frame(width: 16)
            Text(label).font(HUD.body(.caption))
            Text(value).font(HUD.numeric(.caption))
            if let note {
                Text(note).font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
