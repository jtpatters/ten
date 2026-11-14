import GameCore
import SwiftUI

/// The city panel (M1 §16): an own city's yields with their sources, growth, the production
/// queue (add, remove, reorder by dragging a row's handle or from its menu) with each option's
/// cost, turns and Buy price, focus, buildings, and its defence with Bombard. Its worked tiles
/// are marked on the map while it is open.
///
/// On iPad it is a trailing side panel; on iPhone a sheet (35% and large detents), or a 320 pt
/// trailing panel on its side (`GameView`). The header stays put; the rest scrolls, and a
/// request for the production list (a city just founded, an empty queue) scrolls to it. In
/// another player's phase it is read-only: its controls answer "Waiting for <civ>".
struct CityPanel: View {
    enum Style {
        /// A parchment card beside the map.
        case side
        /// The content of a sheet (the sheet is the parchment).
        case sheet
    }

    let session: GameSession
    let city: City
    var style: Style

    @State private var showsLater = false

    private enum Anchor: Hashable {
        case top, production, yields, defence
    }

    /// The city shown and the first item of its queue.
    private struct PanelHead: Equatable {
        var city: CityID
        var head: ProductionItem?
    }

    var body: some View {
        let view = session.view
        VStack(alignment: .leading, spacing: 0) {
            header(view)
                .padding(.horizontal, HUD.Space.l)
                .padding(.top, style == .sheet ? HUD.Space.l + 4 : HUD.Space.m)
                .padding(.bottom, HUD.Space.s)
            Rectangle().fill(HUD.ink.opacity(0.18)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: HUD.Space.l + 2) {
                        overview(view).id(Anchor.top)
                        production(view).id(Anchor.production)
                        citizens(view)
                        yieldsTable(view).id(Anchor.yields)
                        buildings(view)
                        defence(view).id(Anchor.defence)
                    }
                    .padding(.horizontal, HUD.Space.l)
                    .padding(.top, HUD.Space.m)
                    .padding(.bottom, HUD.Space.xl)
                }
                .scrollIndicators(.automatic)
                .onChange(of: session.cityPanelRequest, initial: true) { _, request in
                    let anchor: Anchor = switch request.focus {
                    case .overview: .top
                    case .production: .production
                    case .yields: .yields
                    case .defence: .defence
                    }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .top) }
                }
            }
        }
        .foregroundStyle(HUD.ink)
        .modifier(PanelChrome(style: style))
        // A Settler waiting first in the queue is seen here: Next need not show it again.
        .onChange(of: PanelHead(city: city.id, head: city.queue.first?.item), initial: true) { _, _ in
            session.noteCityPanelShown(city.id)
        }
        .alert(purchaseTitle, isPresented: Binding(get: { session.pendingPurchase != nil }, set: { if !$0 { session.pendingPurchase = nil } }),
               presenting: session.pendingPurchase) { _ in
            Button("Buy") { session.confirmPurchase() }
            Button("Cancel", role: .cancel) { session.pendingPurchase = nil }
        } message: { request in
            Text("That is more than half of your \(request.gold) gold.")
        }
    }

    private var purchaseTitle: String {
        guard let request = session.pendingPurchase else { return "" }
        return "Buy \(ItemName.withArticle(request.item, rules: session.state.rules)) for \(request.price) gold?"
    }

    private var readOnly: Bool { !session.isInputEnabled }

    // MARK: Header

    private func header(_ view: PlayerView) -> some View {
        HStack(spacing: HUD.Space.s) {
            PlayerEmblem(player: city.owner, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: HUD.Space.xs + 2) {
                    Text(city.name).font(HUD.title(.title3)).lineLimit(1).minimumScaleFactor(0.75)
                        .accessibilityAddTraits(.isHeader)
                    if city.has(view.rules.palace.id) {
                        Image(systemName: "star.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(HUD.gilt)
                            .accessibilityLabel("Capital")
                    }
                }
                // Narrow panels drop the founding turn before cutting the line short.
                ViewThatFits(in: .horizontal) {
                    Text(subtitle(view, short: false)).lineLimit(1).fixedSize()
                    // Large text: wraps rather than cutting the population off.
                    Text(subtitle(view, short: true)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .font(HUD.body(.caption))
                .foregroundStyle(HUD.inkSoft)
                // In a duel the original capital decides the game (M1 §10): said while at peace
                // too, in the danger colour at war.
                if view.capitalAtStake == city.id {
                    let atWar = view.players.contains { $0.id != session.viewer && view.isAtWar(with: $0.id) }
                    Label("If \(city.name) falls, you lose the game", systemImage: "exclamationmark.shield.fill")
                        .font(HUD.body(.caption).weight(.semibold))
                        .foregroundStyle(atWar ? HUD.danger : HUD.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: HUD.Space.s)
            CloseButton { session.deselect() }
                .padding(.vertical, HUD.Space.m)
        }
    }

    private func subtitle(_ view: PlayerView, short: Bool) -> String {
        var parts: [String] = []
        if city.capturedTurn == view.turn {
            parts.append("Captured this turn")
        } else if city.has(view.rules.palace.id) {
            parts.append("Capital")
        }
        parts.append("Population \(city.population)")
        if city.capturedTurn != view.turn, !short {
            parts.append(city.originalOwner == city.owner ? "Founded turn \(city.foundedTurn)" : "Founded by \(session.civName(of: city.originalOwner))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Overview

    @ViewBuilder
    private func overview(_ view: PlayerView) -> some View {
        let yields = view.cityYields(city.id)
        let growth = view.growth(of: city.id)
        let maxHP = max(view.rules.constants.city.maxHP, 1)
        VStack(alignment: .leading, spacing: HUD.Space.m) {
            if readOnly, let waiting = session.waitingFor {
                Label("Waiting for \(waiting.civName)", systemImage: "hourglass")
                    .font(HUD.body(.caption).weight(.semibold))
                    .foregroundStyle(HUD.inkSoft)
            }
            if let yields { YieldStrip(population: city.population, yields: yields) }
            if let growth { GrowthRow(growth: growth) }
            if let wellbeing = view.wellbeing(of: city.id) { WellbeingRow(wellbeing: wellbeing, population: city.population) }
            if city.hp < maxHP {
                HStack(spacing: HUD.Space.s) {
                    Image(systemName: "heart.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HUD.health(Double(city.hp) / Double(maxHP)))
                    HealthBar(fraction: Double(city.hp) / Double(maxHP), height: 7)
                    Text("\(city.hp)/\(maxHP)").font(HUD.numeric(.caption))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Health \(city.hp) of \(maxHP)")
            }
            let targets = view.cityAttackOptions(for: city.id)
            if !targets.isEmpty {
                Button {
                    session.beginBombard(city.id)
                } label: {
                    Label(targets.count == 1 ? "Bombard · 1 target in range" : "Bombard · \(targets.count) targets in range",
                          systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BronzeButtonStyle())
                .opacity(readOnly ? 0.6 : 1)
                .accessibilityHint("Choose a target on the map.")
            }
        }
    }

    // MARK: Production

    @ViewBuilder
    private func production(_ view: PlayerView) -> some View {
        let status = view.queueStatus(of: city.id)
        let perTurn = view.cityYields(city.id)?.total.production ?? 0
        let options = view.productionOptions(for: city.id).filter { $0.queueProblem != "already built" }
        let now = options.filter { Self.isAvailable($0) }
        let later = options.filter { !Self.isAvailable($0) }
        let maxQueue = view.rules.constants.production.maxQueue
        // A Builder's note when the city's own land has no job for it.
        let builderNote = BuilderGuidance.cityNote(view, city: city.id)
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            HeaderRow(title: "Production") {
                Label("\(perTurn) per turn", systemImage: YieldChip.Kind.production.systemImage)
                    .font(HUD.numeric(.caption))
                    .foregroundStyle(HUD.inkSoft)
            }
            if status.isEmpty {
                HStack(spacing: HUD.Space.s) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(HUD.danger)
                    Text("Nothing in production. Choose what to build below.")
                        .font(HUD.body(.subheadline))
                        .foregroundStyle(HUD.danger)
                }
                .padding(.horizontal, HUD.Space.m)
                .frame(maxWidth: .infinity, minHeight: HUD.touch, alignment: .leading)
                .parchmentWell()
            } else {
                QueueList(rows: status, rules: view.rules, readOnly: readOnly, builderNote: builderNote,
                          onMove: { session.moveInQueue(from: $0, to: $1, in: city.id) },
                          onRemove: { session.removeFromQueue(at: $0, in: city.id) })
            }
            // Stored production (M1 §5): the row it goes into says so; while none takes it, the
            // store, its cap and what is lost beyond it.
            if let stored = view.storedProduction(of: city.id), stored.receiver == nil, stored.amount > 0 || perTurn > 0 {
                StoredProductionNote(stored: stored, perTurn: perTurn, queueEmpty: status.isEmpty)
            }
            HeaderRow(title: "Add to queue") {
                Text("\(city.queue.count) of \(maxQueue) queued").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
            }
            .padding(.top, HUD.Space.xs)
            VStack(spacing: HUD.Space.xs) {
                ForEach(now, id: \.item) { option in
                    OptionRow(option: option, city: city.id, session: session, readOnly: readOnly, builderNote: builderNote)
                }
            }
            if !later.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsLater.toggle() }
                } label: {
                    HStack(spacing: HUD.Space.xs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(showsLater ? 90 : 0))
                        Text("Not yet available (\(later.count))").font(HUD.body(.caption).weight(.semibold))
                        Spacer()
                    }
                    .foregroundStyle(HUD.inkSoft)
                    .frame(minHeight: HUD.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsLater {
                    VStack(spacing: HUD.Space.xs) {
                        ForEach(later, id: \.item) { option in
                            OptionRow(option: option, city: city.id, session: session, readOnly: readOnly, builderNote: builderNote)
                        }
                    }
                }
            }
        }
    }

    /// Options that may be queued now, or only wait for the queue to have room.
    private static func isAvailable(_ option: ProductionOption) -> Bool {
        option.queueProblem == nil || option.queueProblem == "queue full" || option.queueProblem == "already queued"
    }

    // MARK: Citizens

    @ViewBuilder
    private func citizens(_ view: PlayerView) -> some View {
        let unemployed = max(0, city.population - city.workedTiles.count)
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            SectionHeader(title: "Citizens")
            FocusPicker(focus: city.focus, readOnly: readOnly) { session.setFocus($0, of: city.id) }
            Text(workedText(unemployed: unemployed))
                .font(HUD.body(.caption))
                .foregroundStyle(HUD.inkSoft)
        }
    }

    private func workedText(unemployed: Int) -> String {
        let worked = city.workedTiles.count
        var text = worked == 1 ? "1 citizen works the tile marked on the map" : "\(worked) citizens work the tiles marked on the map"
        if worked == 0 { text = "No citizen works a tile" }
        if unemployed > 0 { text += "; \(unemployed) without a tile" }
        return text + "."
    }

    // MARK: Yields

    @ViewBuilder
    private func yieldsTable(_ view: PlayerView) -> some View {
        if let yields = view.cityYields(city.id) {
            VStack(alignment: .leading, spacing: HUD.Space.s) {
                SectionHeader(title: "Yields")
                YieldBreakdown(yields: yields, city: city, rules: view.rules)
                    .padding(HUD.Space.m)
                    .parchmentWell()
            }
        }
    }

    // MARK: Buildings

    @ViewBuilder
    private func buildings(_ view: PlayerView) -> some View {
        let defs = city.buildings.compactMap { view.rules.building($0) }
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            SectionHeader(title: "Buildings")
            if defs.isEmpty {
                Text("No buildings yet.").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(defs.enumerated()), id: \.element.id) { i, def in
                        HStack(spacing: HUD.Space.s) {
                            ItemIcon(item: .building(def.id), size: 28)
                            Text(def.name).font(HUD.title(.subheadline))
                            Spacer(minLength: HUD.Space.s)
                            Text(Self.effect(of: def, in: city))
                                .font(HUD.body(.caption))
                                .foregroundStyle(HUD.inkSoft)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, HUD.Space.m)
                        .frame(minHeight: 40)
                        .accessibilityElement(children: .combine)
                        if i < defs.count - 1 { Rectangle().fill(HUD.ink.opacity(0.1)).frame(height: 1).padding(.leading, 48) }
                    }
                }
                .parchmentWell()
            }
        }
    }

    /// "+3 Gold", "+2 Culture", "Wall 80/100 · +5 City Strength".
    static func effect(of def: BuildingDef, in city: City) -> String {
        var parts: [String] = []
        let y = def.yields
        for (value, name) in [(y.food, "Food"), (y.production, "Production"), (y.gold, "Gold"), (y.science, "Science"),
                              (y.culture, "Culture")] where value != 0 {
            parts.append("\(YieldChip.signed(value)) \(name)")
        }
        if let housing = def.housing, housing != 0 { parts.append("\(YieldChip.signed(housing)) Housing") }
        if let stability = def.stability, stability != 0 { parts.append("\(YieldChip.signed(stability)) Stability") }
        if def.wallHP > 0 {
            parts.append("Wall \(city.wallHP)/\(def.wallHP)")
            if def.cityStrength > 0 { parts.append("+\(def.cityStrength) City Strength") }
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: Defence

    @ViewBuilder
    private func defence(_ view: PlayerView) -> some View {
        let strength = view.knownCityStrength(at: city.position)
        let garrison = view.garrison(of: city.id)
        let problem = session.bombardProblem(city.id)
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            SectionHeader(title: "Defence")
            VStack(alignment: .leading, spacing: HUD.Space.s) {
                if let strength {
                    HStack(alignment: .firstTextBaseline, spacing: HUD.Space.s) {
                        Label("City Strength", systemImage: "shield.lefthalf.filled").font(HUD.body(.subheadline))
                        Spacer()
                        Text("\(strength.total)").font(HUD.numeric(.headline))
                    }
                    Text((["Base \(strength.base)"] + strength.modifiers.map { "\($0.name) \(YieldChip.signed($0.value))" })
                        .joined(separator: " · "))
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.inkSoft)
                }
                HStack(spacing: HUD.Space.s) {
                    Label(garrison.map { "Garrison: \($0.type.displayName)" } ?? "No garrison",
                          systemImage: garrison == nil ? "person.slash" : "person.fill.checkmark")
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.inkSoft)
                    Spacer()
                    if let garrison { Text("HP \(garrison.hp)").font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft) }
                }
            }
            .padding(HUD.Space.m)
            .parchmentWell()
            Button {
                session.beginBombard(city.id)
            } label: {
                Label("Bombard", systemImage: "scope").frame(maxWidth: .infinity)
            }
            .buttonStyle(ParchmentButtonStyle())
            .opacity(problem == nil && !readOnly ? 1 : 0.55)
            .accessibilityHint(problem.map { "Unavailable: \($0)." } ?? "Choose a target on the map.")
            if let problem {
                Text("Bombard: \(problem).").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
            }
        }
    }
}

// MARK: - Chrome

/// The side panel's parchment card, or nothing in a sheet (the sheet is parchment).
private struct PanelChrome: ViewModifier {
    var style: CityPanel.Style

    func body(content: Content) -> some View {
        switch style {
        case .side:
            content
                .clipShape(RoundedRectangle(cornerRadius: HUD.Radius.large, style: .continuous))
                .parchment(cornerRadius: HUD.Radius.large)
        case .sheet:
            content
        }
    }
}

// MARK: - Pieces

/// An item's symbol on a small disc.
struct ItemIcon: View {
    var item: ProductionItem
    var size: CGFloat = 32
    var tint: Color = HUD.Yield.production

    var body: some View {
        Image(systemName: Self.symbol(item))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(HUD.parchmentTop.opacity(0.8)))
            .overlay(Circle().stroke(HUD.ink.opacity(0.25), lineWidth: 1))
            .accessibilityHidden(true)
    }

    static func symbol(_ item: ProductionItem) -> String {
        switch item {
        case let .unit(type):
            switch type {
            case .settler: "figure.walk"
            case .builder: "hammer"
            case .scout: "binoculars"
            case .archer: "scope"
            case .spearman: "shield.fill"
            case .warrior: "shield.lefthalf.filled"
            case .horseman: "hare"
            case .heavyChariot: "circle.circle"
            case .swordsman: "bolt.shield"
            case .catapult: "circle.bottomhalf.filled"
            case .manAtArms: "shield.checkered"
            case .crossbowman: "scope"
            case .pikeman: "arrow.up"
            case .knight: "crown.fill"
            case .trebuchet: "triangle"
            case .galley, .cog: "sailboat"
            case .quadrireme, .dromon: "sailboat.fill"
            }
        case let .building(id):
            switch id.rawValue {
            case "palace": "crown"
            case "monument": "building.columns"
            case "granary": "basket"
            case "library": "books.vertical"
            case "walls": "shield"
            case "market": "storefront"
            case "waterMill": "water.waves"
            default: "building.2"
            }
        }
    }
}

/// Population and the city's yields per turn, in a well.
private struct YieldStrip: View {
    var population: Int
    var yields: CityYields

    var body: some View {
        HStack(spacing: 2) {
            cell(systemImage: "person.2.fill", value: "\(population)", name: "Citizens", tint: HUD.ink)
            cell(kind: .food, value: YieldChip.signed(yields.foodSurplus), danger: yields.foodSurplus < 0)
            cell(kind: .production, value: "\(yields.total.production)")
            cell(kind: .gold, value: "\(yields.total.gold)")
            cell(kind: .science, value: "\(yields.total.science)")
            cell(kind: .culture, value: "\(yields.total.culture)")
        }
        .padding(.vertical, HUD.Space.s)
        .parchmentWell()
    }

    private func cell(kind: YieldChip.Kind, value: String, danger: Bool = false) -> some View {
        cell(systemImage: kind.systemImage, value: value, name: kind == .food ? "Food" : kind.name, tint: kind.tint, danger: danger)
    }

    private func cell(systemImage: String, value: String, name: String, tint: Color, danger: Bool = false) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Text(value).font(HUD.numeric(.subheadline)).foregroundStyle(danger ? HUD.danger : HUD.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            // Six names share the row: they stop growing at Large text (the numbers go on).
            Text(name).font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft).lineLimit(1).minimumScaleFactor(0.7)
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(value)")
    }
}

/// The food store toward the next citizen, and when the city grows or shrinks.
private struct GrowthRow: View {
    var growth: CityGrowth

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: HUD.Space.s) {
                Text(text).font(HUD.body(.subheadline).weight(.semibold)).foregroundStyle(growth.surplus < 0 ? HUD.danger : HUD.ink)
                Spacer(minLength: HUD.Space.s)
                Text("\(growth.foodStore)/\(growth.threshold)").font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft)
            }
            ProgressBar(fraction: Double(growth.foodStore) / Double(max(growth.threshold, 1)), tint: HUD.Yield.food, height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(text). Food store \(growth.foodStore) of \(growth.threshold).")
    }

    private var text: String {
        if let turns = growth.turnsToGrow { return "Grows to \(growth.population + 1) in \(turnsText(turns))" }
        if let turns = growth.turnsToShrink { return "Starving: shrinks to \(growth.population - 1) in \(turnsText(turns))" }
        if growth.surplus < 0 { return "Starving, at its smallest" }
        return "Not growing: no spare food"
    }
}

/// Housing ("Pop 7 / 8", and the growth it allows) and Stability with its state (M2 §18); a tap
/// opens both breakdowns.
struct WellbeingRow: View {
    var wellbeing: CityWellbeing
    var population: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: HUD.Space.m) {
                    HStack(spacing: 5) {
                        Image(systemName: "house.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(HUD.ink)
                        Text(housingText).font(HUD.body(.subheadline).weight(.semibold))
                            .foregroundStyle(population > wellbeing.housing.total ? HUD.danger : HUD.ink)
                        if wellbeing.growthPct < 100 {
                            Text("growth \(wellbeing.growthPct)%").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                        }
                    }
                    Spacer(minLength: HUD.Space.s)
                    HStack(spacing: 5) {
                        Image(systemName: Self.symbol(wellbeing.state)).font(.system(size: 12, weight: .semibold))
                        Text("\(YieldChip.signed(wellbeing.stability)) \(Self.name(wellbeing.state))")
                            .font(HUD.body(.subheadline).weight(.semibold))
                    }
                    .foregroundStyle(Self.tint(wellbeing.state))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(HUD.inkSoft)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(housingText), growth \(wellbeing.growthPct) percent. Stability \(wellbeing.stability), \(Self.name(wellbeing.state)).")
            .accessibilityHint(expanded ? "Hides the breakdown." : "Shows the breakdown.")
            if expanded { breakdown }
        }
    }

    private var housingText: String { "Pop \(population) / \(wellbeing.housing.total)" }

    private var breakdown: some View {
        let h = wellbeing.housing, b = wellbeing.breakdown
        return Grid(alignment: .leading, horizontalSpacing: HUD.Space.m, verticalSpacing: 4) {
            heading("Housing")
            row("Water", h.base)
            row("Buildings", h.buildings)
            row("Improved tiles", h.improvements)
            total("Housing", h.total)
            heading("Stability")
            row("Buildings", b.buildings)
            row("Luxuries", b.luxuries)
            row("Need (citizens)", -b.need)
            row("Empire size", b.empireSize)
            row("Overcrowding", b.overcrowding)
            row("Occupied", b.occupied)
            total(b.total == wellbeing.stability ? "Stability" : "Next turn", b.total)
        }
        .padding(HUD.Space.m)
        .parchmentWell()
    }

    private func heading(_ title: String) -> some View {
        GridRow {
            Text(title.uppercased()).font(HUD.label()).tracking(0.8).foregroundStyle(HUD.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("")
        }
    }

    private func row(_ name: String, _ value: Int) -> some View {
        GridRow {
            Text(name).font(HUD.body(.caption))
            Text(value == 0 ? "·" : value > 0 ? "+\(value)" : "−\(-value)")
                .font(HUD.body(.caption).monospacedDigit())
                .foregroundStyle(value < 0 ? HUD.danger : value == 0 ? HUD.inkFaint : HUD.ink)
                .gridColumnAlignment(.trailing)
        }
    }

    private func total(_ name: String, _ value: Int) -> some View {
        GridRow {
            Text(name).font(HUD.title(.caption))
            Text(name == "Housing" ? "\(value)" : YieldChip.signed(value)).font(HUD.numeric(.caption))
                .foregroundStyle(value < 0 ? HUD.danger : HUD.ink)
        }
    }

    static func name(_ state: StabilityState) -> String {
        switch state {
        case .thriving: "Thriving"
        case .content: "Content"
        case .restless: "Restless"
        case .unrest: "Unrest"
        case .revolt: "Revolt"
        }
    }

    static func symbol(_ state: StabilityState) -> String {
        switch state {
        case .thriving: "face.smiling.inverse"
        case .content: "face.smiling"
        case .restless: "exclamationmark.bubble"
        case .unrest: "exclamationmark.triangle"
        case .revolt: "flame"
        }
    }

    static func tint(_ state: StabilityState) -> Color {
        switch state {
        case .thriving: HUD.good
        case .content: HUD.ink
        case .restless: HUD.amber
        case .unrest, .revolt: HUD.danger
        }
    }
}

/// Balanced, Food, Production or Gold (M1 §4): what the citizens favour.
private struct FocusPicker: View {
    var focus: CityFocus
    var readOnly: Bool
    var onChoose: (CityFocus) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(CityFocus.allCases, id: \.self) { option in
                let selected = option == focus
                Button {
                    onChoose(option)
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: Self.symbol(option)).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Self.tint(option))
                        Text(option.rawValue.capitalized).font(HUD.body(.caption2).weight(selected ? .bold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, minHeight: HUD.touch)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: HUD.Radius.small - 2, style: .continuous)
                                .fill(LinearGradient(colors: [HUD.bronzeTop, HUD.bronzeBottom], startPoint: .top, endPoint: .bottom))
                                .overlay(RoundedRectangle(cornerRadius: HUD.Radius.small - 2, style: .continuous)
                                    .stroke(HUD.ink.opacity(0.6), lineWidth: 1))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel("\(option.rawValue.capitalized) focus")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .parchmentWell()
        .opacity(readOnly ? 0.6 : 1)
    }

    static func symbol(_ focus: CityFocus) -> String {
        switch focus {
        case .balanced: "scale.3d"
        case .food: YieldChip.Kind.food.systemImage
        case .production: YieldChip.Kind.production.systemImage
        case .gold: YieldChip.Kind.gold.systemImage
        }
    }

    static func tint(_ focus: CityFocus) -> Color {
        switch focus {
        case .balanced: HUD.ink
        case .food: HUD.Yield.food
        case .production: HUD.Yield.production
        case .gold: HUD.Yield.gold
        }
    }
}

/// The yields by source (M1 §12.6): centre, worked tiles, citizens without a tile, population,
/// buildings; what the citizens eat; the net.
private struct YieldBreakdown: View {
    var yields: CityYields
    var city: City
    var rules: Ruleset

    private static let kinds: [YieldChip.Kind] = [.food, .production, .gold, .science, .culture]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: HUD.Space.s, verticalSpacing: 5) {
            GridRow {
                // The names' column takes the spare width, so the well spans the panel.
                Text("Source").font(HUD.label()).tracking(0.8).foregroundStyle(HUD.inkSoft).gridColumnAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Self.kinds, id: \.self) { kind in
                    Image(systemName: kind.systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(kind.tint)
                        .frame(minWidth: 26, alignment: .trailing)
                        .accessibilityLabel(kind.name)
                }
            }
            ForEach(Array(yields.breakdown.enumerated()), id: \.offset) { _, entry in
                GridRow {
                    Text(name(of: entry.source)).font(HUD.body(.caption)).lineLimit(1).minimumScaleFactor(0.8)
                    ForEach(Self.kinds, id: \.self) { kind in number(value(entry.yields, kind)) }
                }
            }
            if yields.foodEaten > 0 {
                GridRow {
                    Text("Citizens eat").font(HUD.body(.caption))
                    number(-yields.foodEaten)
                    ForEach(0..<4, id: \.self) { _ in Text("") }
                }
            }
            Rectangle().fill(HUD.ink.opacity(0.2)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("Net per turn").font(HUD.title(.caption))
                number(yields.foodSurplus, bold: true)
                ForEach(Self.kinds.dropFirst(), id: \.self) { kind in number(value(yields.total, kind), bold: true) }
            }
        }
    }

    private func number(_ n: Int, bold: Bool = false) -> some View {
        Text(n == 0 ? "·" : (n > 0 ? "\(n)" : "−\(-n)"))
            .font(bold ? HUD.numeric(.caption) : HUD.body(.caption).monospacedDigit())
            .foregroundStyle(n < 0 ? HUD.danger : (n == 0 ? HUD.inkFaint : HUD.ink))
    }

    private func value(_ y: Yields, _ kind: YieldChip.Kind) -> Int {
        switch kind {
        case .food: y.food
        case .production: y.production
        case .gold: y.gold
        case .science: y.science
        case .culture: y.culture
        }
    }

    private func name(of source: YieldSource) -> String {
        switch source {
        case .centre: "City centre"
        case .workedTiles: "Worked tiles (\(city.workedTiles.count))"
        case .unemployed: "Without a tile (\(max(0, city.population - city.workedTiles.count)))"
        case .population: "Population"
        case let .building(id): rules.building(id)?.name ?? id.rawValue.capitalized
        case .stability: "Stability"
        }
    }
}

/// A section header with a note at its end; the note goes under it when the two do not fit on
/// one line (the largest text sizes), so the header never breaks mid-word ("Produc-tion").
private struct HeaderRow<Note: View>: View {
    var title: String
    @ViewBuilder var note: () -> Note

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: title).fixedSize()
                Spacer(minLength: HUD.Space.s)
                note().fixedSize()
            }
            VStack(alignment: .leading, spacing: HUD.Space.xxs) {
                SectionHeader(title: title)
                note()
            }
        }
    }
}

// MARK: - Queue

/// The queue's rows, reordered by dragging a row's handle (or from its menu, or VoiceOver's
/// actions), each removable.
private struct QueueList: View {
    var rows: [QueueItemStatus]
    var rules: Ruleset
    var readOnly: Bool
    /// The note on a Builder (`BuilderGuidance.cityNote`): its city's land has no job for it.
    var builderNote: String?
    var onMove: (Int, Int) -> Void
    var onRemove: (Int) -> Void

    @State private var dragging: Int?
    @State private var dragOffset: CGFloat = 0
    /// 60 pt at the default text size, growing with it (a name may take two lines at the
    /// accessibility sizes).
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 60

    static let spacing: CGFloat = 6

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                QueueRow(row: row, index: index, count: rows.count, readOnly: readOnly, dragging: dragging == index, height: rowHeight,
                         note: BuilderGuidance.isBuilder(row.item, rules: rules) ? builderNote : nil,
                         onRemove: { onRemove(index) }, onMove: { onMove(index, $0) }, handle: handle(index))
                    .offset(y: offset(of: index))
                    .zIndex(dragging == index ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: target)
    }

    /// Where the dragged row would land.
    private var target: Int? {
        guard let from = dragging else { return nil }
        let step = rowHeight + Self.spacing
        return min(max(from + Int((dragOffset / step).rounded()), 0), rows.count - 1)
    }

    private func offset(of index: Int) -> CGFloat {
        guard let from = dragging, let to = target else { return 0 }
        if index == from { return dragOffset }
        let step = rowHeight + Self.spacing
        if from < to, index > from, index <= to { return -step }
        if from > to, index >= to, index < from { return step }
        return 0
    }

    private func handle(_ index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard !readOnly, rows.count > 1 else { return }
                dragging = index
                dragOffset = value.translation.height
            }
            .onEnded { _ in
                let to = target
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragging = nil
                    dragOffset = 0
                }
                if let to, to != index { onMove(index, to) }
            }
    }
}

/// One queue entry: its progress, turns or why it waits, a × and the drag handle.
private struct QueueRow<Handle: Gesture>: View {
    var row: QueueItemStatus
    var index: Int
    var count: Int
    var readOnly: Bool
    var dragging: Bool
    var height: CGFloat
    /// An amber note (a Builder with no job on its city's land).
    var note: String?
    var onRemove: () -> Void
    var onMove: (Int) -> Void
    var handle: Handle
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: HUD.Space.s) {
            ItemIcon(item: row.item, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                // A narrow panel (a phone on its side) trades the "Now" badge for a hammer
                // before it would cut the name short; at the accessibility text sizes the name
                // then takes a line (or two) of its own.
                ViewThatFits(in: .horizontal) {
                    titleLine(compactBadge: false)
                    titleLine(compactBadge: true)
                    if typeSize.isAccessibilitySize { stackedTitle }
                }
                ProgressBar(fraction: Double(row.progress) / Double(max(row.cost, 1)),
                            tint: row.wait == nil || row.receivesProduction ? HUD.Yield.production : HUD.amber, height: 4)
                if let wait = waitText {
                    // In amber at the accessibility sizes, where it may stand for "waiting".
                    Text(wait).font(HUD.body(.caption2))
                        .foregroundStyle(typeSize.isAccessibilitySize ? HUD.amber : HUD.inkSoft)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.8)
                }
                if let stored = storedText {
                    Text(stored).font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft).lineLimit(1).minimumScaleFactor(0.8)
                }
                if let note {
                    Text(note).font(HUD.body(.caption2)).foregroundStyle(HUD.amber).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            // Full 44 pt targets, side by side (no gap: the targets themselves keep them apart).
            HStack(spacing: 0) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(HUD.inkSoft)
                        .frame(width: HUD.touch, height: HUD.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(row.name)")
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(count > 1 ? HUD.inkSoft : HUD.inkFaint)
                    .frame(width: HUD.touch, height: HUD.touch)
                    .contentShape(Rectangle())
                    .highPriorityGesture(handle)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, HUD.Space.s)
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous)
                .fill(row.receivesProduction ? HUD.parchmentWell.opacity(1.5) : HUD.parchmentWell)
        }
        .overlay {
            if dragging {
                RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous).stroke(HUD.bronzeBottom, lineWidth: 1.5)
            }
        }
        .shadow(color: .black.opacity(dragging ? 0.25 : 0), radius: 6, x: 2, y: 3)
        .opacity(readOnly ? 0.7 : 1)
        .contextMenu {
            if index > 0 {
                Button { onMove(0) } label: { Label("Build Next", systemImage: "arrow.up.to.line") }
                Button { onMove(index - 1) } label: { Label("Move Up", systemImage: "arrow.up") }
            }
            if index < count - 1 {
                Button { onMove(index + 1) } label: { Label("Move Down", systemImage: "arrow.down") }
            }
            Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((["\(index + 1). \(row.name)", detail] + [waitText, storedText, note].compactMap { $0 }).joined(separator: ", "))
        .accessibilityAction(named: "Move up") { if index > 0 { onMove(index - 1) } }
        .accessibilityAction(named: "Move down") { if index < count - 1 { onMove(index + 1) } }
        .accessibilityAction(named: "Remove", onRemove)
    }

    private func titleLine(compactBadge: Bool) -> some View {
        HStack(spacing: HUD.Space.xs) {
            // The last resort (the compact line) may still cut a long name short.
            Text(row.name).font(HUD.title(.subheadline)).lineLimit(1).fixedSize(horizontal: !compactBadge, vertical: false)
            if row.receivesProduction {
                if compactBadge {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(HUD.Yield.production)
                        .accessibilityLabel("Now")
                } else {
                    KindBadge(text: "Now", tint: HUD.Yield.production)
                }
            }
            Spacer(minLength: HUD.Space.xs)
            Text(detail).font(HUD.numeric(.caption))
                .foregroundStyle(row.wait == nil || row.receivesProduction ? HUD.inkSoft : HUD.amber)
                .lineLimit(1).fixedSize()
        }
    }

    /// The name over the turns, the name wrapping (the accessibility text sizes). A waiting
    /// entry has no turns line: its reason, below the bar, takes two lines instead.
    private var stackedTitle: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.name).font(HUD.title(.subheadline)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if row.wait == nil || row.receivesProduction {
                HStack(spacing: HUD.Space.xs) {
                    if row.receivesProduction {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HUD.Yield.production)
                            .accessibilityLabel("Now")
                    }
                    Text(detail).font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft).lineLimit(1)
                }
            }
        }
    }

    /// A Settler that fills while it waits for population (M1 §5) shows the turns until the city
    /// has grown and it is paid for; any other waiting entry says "waiting".
    private var detail: String {
        if row.wait != nil, !row.receivesProduction { return "waiting" }
        if let turns = row.turns { return turnsText(turns) }
        if row.wait != nil { return "waiting" }
        return "\(row.progress)/\(row.cost)"
    }

    /// The city's stored production this entry takes at the next phase start (M1 §5), counted in
    /// its bar and turns: "40 stored goes into the Warrior".
    private var storedText: String? {
        row.storedIncluded > 0 ? "\(row.storedIncluded) stored goes into the \(row.name)" : nil
    }

    private var waitText: String? {
        switch row.wait {
        // Foreseen: a Settler ahead in the queue will have shrunk the city by then, and it will
        // not have grown back at its current surplus (if it grows at all, it may yet).
        case let .population(n)? where row.waitIsForeseen:
            row.waitIsUncertain ? "May wait for population \(n) after a Settler" : "Waits for population \(n) after a Settler"
        case let .population(n)? where row.receivesProduction: "Builds now, done at population \(n)"
        case let .population(n)?: "Waits for population \(n)"
        case .noRoom?: "Waits: no free tile to place it"
        case let .resource(r, needed, have)?: "Waits: needs \(needed) \("\(r)".capitalized) (have \(have))"
        case nil: nil
        }
    }
}

/// The city's stored production while no queue entry takes production (an empty queue, or
/// only items that wait): how much, up to what (`storedProgressCapMultiplier` × the phase's
/// production, M1 §5), and in amber that production beyond it is lost meanwhile. ("2 stored, up
/// to 14"; the founding production may stand above the cap, and stays.)
private struct StoredProductionNote: View {
    var stored: StoredProduction
    var perTurn: Int
    var queueEmpty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.Space.xxs) {
            if let line = storedLine {
                Hint(systemImage: "tray.and.arrow.down", text: line)
            }
            if perTurn > 0 {
                Label(lossLine, systemImage: "exclamationmark.triangle")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var full: Bool { stored.amount >= stored.cap }

    /// "2 stored, up to 14."; above the cap, "40 stored: the store is full."
    private var storedLine: String? {
        guard stored.amount > 0 else { return nil }
        return full ? "\(stored.amount) production stored for the next item: the store is full."
            : "\(stored.amount) production stored for the next item, up to \(stored.cap)."
    }

    private var lossLine: String {
        let meanwhile = queueEmpty ? "while nothing is queued" : "while every item waits"
        return full ? "New production is lost \(meanwhile)." : "Production beyond \(stored.cap) is lost \(meanwhile)."
    }
}

/// A production option: tap to queue it; its cost, turns (or why not), and Buy with the price.
private struct OptionRow: View {
    var option: ProductionOption
    var city: CityID
    var session: GameSession
    var readOnly: Bool
    /// The note on a Builder (`BuilderGuidance.cityNote`): its city's land has no job for it.
    var builderNote: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let queueable = option.queueProblem == nil
        // At the accessibility text sizes the price goes under the name, which keeps the width.
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 0)) : AnyLayout(HStackLayout(spacing: HUD.Space.s))
        layout {
            Button {
                if let problem = option.queueProblem {
                    session.show("Can't queue \(option.name): \(problem)")
                } else {
                    session.enqueue(option.item, in: city)
                }
            } label: {
                HStack(spacing: HUD.Space.s) {
                    ItemIcon(item: option.item, size: 30, tint: queueable ? HUD.Yield.production : HUD.inkFaint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.name).font(HUD.title(.subheadline)).foregroundStyle(queueable ? HUD.ink : HUD.inkSoft)
                        Text(detail).font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft).lineLimit(large ? 2 : 1).minimumScaleFactor(0.8)
                        if let note {
                            Text(note).font(HUD.body(.caption2)).foregroundStyle(HUD.amber).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    Spacer(minLength: HUD.Space.xs)
                    if queueable {
                        Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(HUD.bronzeBottom)
                    }
                }
                .padding(.leading, HUD.Space.s)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityLabel("\(option.name), \(detail)\(note.map { ", \($0)" } ?? "")")
            .accessibilityHint(option.queueProblem.map { "Unavailable: \($0)." } ?? "Adds it to the queue.")
            BuyButton(price: option.buyPrice, available: option.buyProblem == nil && !readOnly) {
                session.buy(option.item, in: city)
            }
            .accessibilityLabel("Buy \(option.name) for \(option.buyPrice) gold")
            .accessibilityHint(option.buyProblem.map { "Unavailable: \($0)." } ?? "")
            .padding(.bottom, large ? HUD.Space.xs : 0)
        }
        .padding(.trailing, HUD.Space.xs)
        .background(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous).fill(HUD.parchmentWell.opacity(queueable ? 1 : 0.5)))
        .opacity(readOnly ? 0.7 : 1)
    }

    private var detail: String {
        let cost = "\(option.cost) production"
        if let problem = option.queueProblem, problem != "already queued" { return "\(cost) · \(problem)" }
        guard let turns = option.turns else { return "\(cost) · no production" }
        return "\(cost) · \(turnsText(turns))" + (option.queueProblem == "already queued" ? " · queued" : "")
    }

    /// A Settler in a city too small for it: it would wait, and its turns count only once the
    /// city has grown.
    private var waitNote: String? {
        switch session.view.productionWait(option.item, in: city) {
        case let .population(n)?: return "Waits for population \(n)"
        case let .resource(r, needed, have)?: return "Waits: needs \(needed) \("\(r)".capitalized) (have \(have))"
        default: return nil
        }
    }

    /// The amber line under the cost: why it would wait, or a Builder's city with no job for it.
    private var note: String? {
        waitNote ?? (BuilderGuidance.isBuilder(option.item, rules: session.view.rules) ? builderNote : nil)
    }
}

/// The gold price as a small capsule: dimmed when it cannot be bought (a tap says why).
private struct BuyButton: View {
    var price: Int
    var available: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: YieldChip.Kind.gold.systemImage).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HUD.Yield.gold)
                Text("\(price)").font(HUD.numeric(.caption))
            }
            .padding(.horizontal, HUD.Space.s + 2)
            .frame(minWidth: 64, minHeight: 32)
            .background(Capsule().fill(HUD.parchmentTop.opacity(available ? 1 : 0.5)))
            .overlay(Capsule().stroke(HUD.ink.opacity(available ? 0.55 : 0.2), lineWidth: 1))
            .opacity(available ? 1 : 0.5)
            .frame(minHeight: HUD.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipButtonStyle())
    }
}
