import GameCore
import SwiftUI

/// The selected unit (M1 §16): type and status, Moves, HP, Strength, XP (or a Builder's
/// charges), the route being previewed with Move, and the action bar. Actions come from
/// `PlayerView.unitActions` with their reasons: the likeliest first, unavailable ones shown
/// dimmed only when they are the unit's purpose (Found City, improvements). A tap on a dimmed
/// action, or a long-press on any, says what it does and why not; Disband asks first.
struct UnitCard: View {
    let session: GameSession
    let unit: GameCore.Unit
    var compact = false
    var onDisband: (GameCore.Unit) -> Void
    @State private var upgradeDescribed = false

    var body: some View {
        let view = session.view
        let def = view.rules.unit(unit.type)
        let own = unit.owner == session.viewer
        let maxHP = max(1, view.rules.constants.healing.maxHP)
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            CardHeader(title: unit.type.displayName, player: unit.owner, onClose: { session.deselect() }) {
                if let status = session.exploreBadge(of: unit) ?? Self.status(of: unit) { KindBadge(text: status) }
            }
            HStack(spacing: HUD.Space.m) {
                StatPill(systemImage: "figure.walk", value: "\(unit.movesLeft)/\(session.state.maxMoves(of: unit))", name: "Moves",
                         valueTint: unit.movesLeft == 0 ? HUD.inkSoft : HUD.ink)
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HUD.health(Double(unit.hp) / Double(maxHP)))
                    HealthBar(fraction: Double(unit.hp) / Double(maxHP), height: 6).frame(width: compact ? 36 : 48)
                    Text("\(unit.hp)").font(HUD.numeric(.footnote))
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Health \(unit.hp) of \(maxHP)")
                if def.isMilitary {
                    StatPill(systemImage: "shield.lefthalf.filled", value: "\(def.strength)", name: "Strength")
                    if def.isRanged {
                        StatPill(systemImage: "scope", value: "\(def.rangedStrength) · \(session.view.range(of: unit))", name: "Ranged strength and range")
                    }
                    StatPill(systemImage: "star.fill", value: "\(unit.xp)", name: "Experience", tint: HUD.gilt)
                }
                if def.charges > 0 {
                    StatPill(systemImage: "hammer.fill", value: "\(unit.charges)", name: "Charges", tint: HUD.Yield.production)
                }
            }
            if own { routeRow }
            if own { ExploreRow(session: session, unit: unit) }
            if own {
                let actions = Self.ordered(view.unitActions(for: unit.id), unit: unit)
                let offered = def.isMilitary ? view.promotionsOffered(unit.id) : []
                // The tiles share the card's width; when they cannot all fit, the row scrolls,
                // and an edge with more beyond it fades out.
                ActionBar {
                    if session.canExplore(unit), session.exploreLeads(unit) { ExploreTile(session: session, unit: unit, compact: compact) }
                    ForEach(actions, id: \.kind) { action in
                        tile(action, fill: true)
                    }
                    if let target = def.upgradesTo { upgradeTile(to: target) }
                    if !offered.isEmpty { promoteTile }
                    if session.canExplore(unit), !session.exploreLeads(unit) { ExploreTile(session: session, unit: unit, compact: compact) }
                }
                if let kind = session.describedAction, let action = actions.first(where: { $0.kind == kind }) {
                    description(action)
                        .transition(.opacity)
                }
                if session.promotingUnit == unit.id, !offered.isEmpty {
                    promotionList(offered).transition(.opacity)
                }
                if upgradeDescribed, let target = def.upgradesTo {
                    upgradeDescription(to: target).transition(.opacity)
                }
                if session.explore.described == unit.id, session.describedAction == nil {
                    ExploreDescription(session: session, unit: unit).transition(.opacity)
                }
            }
        }
        .hudCard()
        .animation(.easeInOut(duration: 0.15), value: session.describedAction)
        .animation(.easeInOut(duration: 0.15), value: session.promotingUnit)
        .onChange(of: unit.id) { upgradeDescribed = false }
    }

    // MARK: Upgrade and Promote (M2 §8.2, §8.3)

    /// What the upgrade costs now, else what it would cost (the rules' price).
    private var upgradePrice: (cost: Int?, available: Bool) {
        if let cost = session.view.upgradeCost(unit.id) { return (cost, true) }
        return (session.state.upgradeCost(of: unit.type), false)
    }

    /// Upgrade, with its price; lit when it can be done now (`PlayerView.upgradeCost`). A tap
    /// on a dimmed tile asks the engine, which says why not.
    private func upgradeTile(to target: UnitType) -> some View {
        let price = upgradePrice
        let title = price.cost.map { "Upgrade · \($0) Gold" } ?? "Upgrade"
        return ActionTileView(title: title, symbol: "arrow.up.circle.fill", lit: price.available && session.isInputEnabled,
                              destructive: false, compact: compact, fill: true,
                              onTap: {
                                  upgradeDescribed = false
                                  session.perform(.upgrade(unit: unit.id))
                              },
                              onLongPress: { upgradeDescribed.toggle() })
            .accessibilityHint(Self.upgradeHelp(from: unit.type, to: target, cost: price.cost))
    }

    static func upgradeHelp(from type: UnitType, to target: UnitType, cost: Int?) -> String {
        let price = cost.map { " for \($0) Gold" } ?? ""
        return "Become a \(target.displayName)\(price), in your territory, keeping its experience and promotions. Ends its moves."
    }

    private func upgradeDescription(to target: UnitType) -> some View {
        HStack(alignment: .top, spacing: HUD.Space.s) {
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(HUD.inkSoft)
                .frame(width: 16)
            Text("\(Text("Upgrade").font(HUD.title(.caption)))  \(Self.upgradeHelp(from: unit.type, to: target, cost: upgradePrice.cost))")
                .font(HUD.body(.caption))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HUD.Space.s)
        .padding(.vertical, HUD.Space.xs + 2)
        .parchmentWell()
        .onTapGesture { upgradeDescribed = false }
    }

    /// Promote: opens the promotions on offer (`PlayerView.promotionsOffered`).
    private var promoteTile: some View {
        ActionTileView(title: "Promote", symbol: "star.circle.fill", lit: session.isInputEnabled, destructive: false,
                       compact: compact, fill: true,
                       onTap: { session.promotingUnit = session.promotingUnit == unit.id ? nil : unit.id },
                       onLongPress: { session.promotingUnit = unit.id })
            .accessibilityHint("Choose a promotion: the unit has the experience for one.")
    }

    /// The promotions on offer, each with what it does; a tap takes one.
    private func promotionList(_ offered: [PromotionDef]) -> some View {
        VStack(alignment: .leading, spacing: HUD.Space.xs) {
            ForEach(offered, id: \.id) { promotion in
                Button {
                    session.promotingUnit = nil
                    session.perform(.promote(unit: unit.id, promotion: promotion.id))
                } label: {
                    HStack(alignment: .top, spacing: HUD.Space.s) {
                        Image(systemName: "star.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(HUD.gilt)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(promotion.name).font(HUD.title(.caption))
                            Text(promotion.effectText).font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, HUD.Space.s)
                    .padding(.vertical, HUD.Space.xs + 2)
                    .contentShape(Rectangle())
                    .parchmentWell()
                }
                .buttonStyle(.plain)
                .disabled(!session.isInputEnabled)
                .accessibilityLabel("\(promotion.name): \(promotion.effectText)")
                .accessibilityHint("Take this promotion.")
            }
        }
    }

    /// The route being previewed (with Move), or the standing order.
    @ViewBuilder
    private var routeRow: some View {
        if let path = session.pendingPath {
            HStack(spacing: HUD.Space.s) {
                Label("Route: \(RouteText.length(of: path, view: session.view))", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
                Spacer(minLength: HUD.Space.s)
                Button {
                    session.confirmPath()
                } label: {
                    Label("Move", systemImage: "arrow.right")
                }
                .buttonStyle(ParchmentButtonStyle())
                .disabled(!session.isInputEnabled)
                .accessibilityHint("Moves along the marked route. Tapping its end on the map does the same.")
            }
        } else if let destination = unit.destination {
            // The standing route is drawn on the map; with none left, the march is stuck (and
            // the card says why).
            Hint(systemImage: "arrow.triangle.turn.up.right.diamond",
                 text: RouteText.march(unit: unit, goal: destination, view: session.view, civName: session.civName(of:)))
        }
    }

    /// `fill`: the tile takes its share of the row's width.
    private func tile(_ action: UnitAction, fill: Bool) -> some View {
        let info = Self.info(action.kind, view: session.view)
        return ActionTileView(title: info.title, symbol: info.symbol, lit: action.isAvailable && session.isInputEnabled,
                              destructive: action.kind == .disband, compact: compact, fill: fill,
                              onTap: { activate(action) }, onLongPress: { session.describedAction = action.kind })
            .accessibilityHint(action.problem.map { "\(info.help) Not now: \($0)." } ?? info.help)
    }

    private func activate(_ action: UnitAction) {
        guard action.isAvailable else {
            session.describedAction = action.kind
            return
        }
        session.describedAction = nil
        if action.kind == .disband {
            onDisband(unit)
        } else {
            session.performAction(action)
        }
    }

    private func description(_ action: UnitAction) -> some View {
        let info = Self.info(action.kind, view: session.view)
        return HStack(alignment: .top, spacing: HUD.Space.s) {
            Image(systemName: info.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(HUD.inkSoft)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(info.title).font(HUD.title(.caption)))  \(info.help)").font(HUD.body(.caption))
                if let problem = action.problem {
                    Text("Not now: \(problem).").font(HUD.body(.caption).weight(.semibold)).foregroundStyle(HUD.danger)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HUD.Space.s)
        .padding(.vertical, HUD.Space.xs + 2)
        .parchmentWell()
        .onTapGesture { session.describedAction = nil }
    }

    static func status(of unit: GameCore.Unit) -> String? {
        switch unit.activity {
        case .fortified: "Fortified"
        case .fortifying: "Fortifying"
        case .sleeping: "Sleeping"
        case .skipped: "Skipped"
        case .none: unit.zocStopped ? "Stopped" : (unit.destination != nil ? "Marching" : nil)
        }
    }

    /// Likeliest first (M1 §16): what the unit is for (found a city, build), waking a resting
    /// unit, cancelling a march, then fortify, sleep, skip; the unit's purpose stays on the bar
    /// dimmed when it cannot be done here; Disband last. Other unavailable actions are hidden.
    static func ordered(_ actions: [UnitAction], unit: GameCore.Unit) -> [UnitAction] {
        let purpose: Set<UnitActionKind> = [.foundCity, .buildFarm, .buildMine, .buildPasture]
        func rank(_ action: UnitAction) -> Int? {
            let kind = action.kind
            if kind == .disband { return 100 }
            let base: Int = switch kind {
            case .foundCity: 0
            case .buildFarm, .buildMine, .buildPasture: 1
            case .wake: 2
            case .cancelOrders: 3
            case .fortify: 4
            case .sleep: 5
            case .skip: 6
            case .disband: 100
            }
            if action.isAvailable { return base }
            return purpose.contains(kind) ? 50 + base : nil
        }
        var ranked: [(action: UnitAction, rank: Int)] = []
        for action in actions {
            if let r = rank(action) { ranked.append((action, r)) }
        }
        ranked.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.action.kind.rawValue < b.action.kind.rawValue
        }
        return ranked.map(\.action)
    }

    /// Each action's title, symbol and help, the numbers read from the rules: an improvement's
    /// yields, the Fortified bonus (M1 §7.4, §8.1: from the owner's next phase until the unit
    /// moves; healing needs only a phase without moving or attacking, §7.5).
    static func info(_ kind: UnitActionKind, view: PlayerView) -> (title: String, symbol: String, help: String) {
        switch kind {
        case .foundCity: ("Found City", "building.columns.fill", "Settle here: the Settler becomes a new city.")
        case .buildFarm: ("Farm", "leaf.fill", "Build a Farm on this tile: \(yields(of: .farm, view: view)). Uses a charge.")
        case .buildMine: ("Mine", "mountain.2.fill", "Build a Mine on this tile: \(yields(of: .mine, view: view)). Uses a charge.")
        case .buildPasture: ("Pasture", "pawprint.fill", "Build a Pasture on this tile: \(yields(of: .pasture, view: view)). Uses a charge.")
        case .fortify: ("Fortify", "shield.fill",
                        "+\(view.rules.constants.combat.fortified) defence from your next turn until it moves. Any unit that waits a turn heals.")
        case .sleep: ("Sleep", "moon.zzz.fill", "Wait here until woken or an enemy comes near.")
        case .wake: ("Wake", "sun.max.fill", "End sleep or fortification.")
        case .skip: ("Skip", "forward.fill", "Do nothing this turn.")
        case .cancelOrders: ("Cancel", "xmark.circle", "Stop the march to its destination.")
        case .disband: ("Disband", "trash", "Remove the unit for good.")
        }
    }

    /// What an improvement adds to its tile: "+1 Production, +1 Gold"; a Farm's fresh-water Food
    /// with the tech it needs ("+1 more by a river or lake, with Irrigation").
    static func yields(of improvement: Improvement, view: PlayerView) -> String {
        let def = view.rules.improvement(improvement)
        var parts: [String] = []
        if def.food > 0 { parts.append("+\(def.food) Food") }
        if def.production > 0 { parts.append("+\(def.production) Production") }
        if def.gold > 0 { parts.append("+\(def.gold) Gold") }
        var text = parts.isEmpty ? "no yields" : parts.joined(separator: ", ")
        if def.freshWaterFood > 0 {
            let tech = def.freshWaterTech.flatMap { view.me.knows($0) ? nil : view.rules.tech($0)?.name }
            text += " (+\(def.freshWaterFood) more by a river or lake\(tech.map { ", with \($0)" } ?? ""))"
        }
        return text
    }
}

/// One action tile: a tap acts, a long-press describes; it darkens while pressed.
private struct ActionTileView: View {
    var title: String
    var symbol: String
    var lit: Bool
    var destructive: Bool
    var compact: Bool
    var fill = false
    var onTap: () -> Void
    var onLongPress: () -> Void
    @State private var pressed = false

    var body: some View {
        Label(title, systemImage: symbol)
            .actionTile(pressed: pressed, lit: lit, destructive: destructive, compact: compact, fill: fill)
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.4, perform: onLongPress, onPressingChanged: { pressed = $0 })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .accessibilityAction(named: "Describe") { onLongPress() }
    }
}

/// What a promotion does, built from its effects (`PromotionDef` carries no text).
extension PromotionDef {
    var effectText: String {
        var parts: [String] = []
        if let strength {
            var clause = "+\(strength)\(ranged == true && when == "attack" ? " ranged" : "") Strength"
            if ranged == true && when == "defend" {
                clause += " vs ranged attacks"
            } else if when == "attack" {
                clause += " attacking"
            } else if when == "defend" {
                clause += " defending"
            } else if ranged == true {
                clause += " in ranged fights"
            }
            if let against, !against.isEmpty {
                let military = Set(UnitClass.allCases).subtracting([.civilian])
                clause += military.isSubset(of: against) ? " vs units"
                    : " vs " + against.map(\.displayName).joined(separator: " and ")
            }
            if vsCity == true { clause += " vs cities" } else if vsCity == false { clause += " vs units" }
            if vsWounded == true { clause += " vs wounded units" }
            if inCity == true { clause += " in an own city" }
            parts.append(clause)
        }
        if let moves { parts.append("+\(moves) move\(moves == 1 ? "" : "s")") }
        if let range { parts.append("+\(range) range") }
        if let sight { parts.append("+\(sight) sight") }
        if rangedAfterMove == true { parts.append("fires after moving") }
        if let freeMoveOn, !freeMoveOn.isEmpty { parts.append("no extra move cost on " + freeMoveOn.joined(separator: ", ")) }
        if ignoresZOC == true { parts.append("ignores zones of control") }
        if holdsZOC == true { parts.append("its zone of control holds units that ignore them") }
        if moveAfterAttack == true { parts.append("attacking costs one move") }
        if noRiverPenalty == true { parts.append("no river penalty attacking") }
        if let wallDamagePct { parts.append("\(wallDamagePct)% damage to walls") }
        return parts.isEmpty ? name : parts.joined(separator: "; ")
    }
}

private extension UnitClass {
    var displayName: String {
        switch self {
        case .civilian: "civilians"
        case .recon: "recon"
        case .melee: "melee"
        case .ranged: "ranged"
        case .antiCavalry: "anti-cavalry"
        case .cavalry: "cavalry"
        case .heavyCavalry: "heavy cavalry"
        case .siege: "siege"
        }
    }
}
