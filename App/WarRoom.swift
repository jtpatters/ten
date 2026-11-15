import GameCore
import SwiftUI

/// The War Room (docs/M2.md §10.4): the empire's war at a glance, ordered in bulk.
/// - Production: every own city with what it builds; pick cities (All, None, Idle, or by hand),
///   then an item goes first, last or in place of all their queues at once; their new military
///   units can be sent to a rally point picked on the map.
/// - Army: every own military unit, by where it stands, with what it does; pick units (by
///   hand, by place, or by filter), then send them together to a goal picked on the map or
///   from a list (rally points, own cities, enemy cities), fortify, wake or halt them.
/// Read-only in other players' phases.
struct WarRoom: View {
    @Bindable var session: GameSession
    var onDone: () -> Void

    var body: some View {
        let editable = session.isInputEnabled
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "War Room", systemImage: "shield.lefthalf.filled", onClose: onDone)
                .padding(.horizontal, HUD.Space.l)
                .padding(.top, HUD.Space.l)
                .padding(.bottom, HUD.Space.s)
            Picker("Tab", selection: $session.warRoom.tab) {
                ForEach(WarRoomTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, HUD.Space.l)
            .padding(.bottom, HUD.Space.s)
            if let waiting = session.waitingFor {
                Label("Waiting for \(waiting.civName): orders wait for your turn", systemImage: "hourglass")
                    .font(HUD.body(.caption).weight(.semibold))
                    .foregroundStyle(HUD.inkSoft)
                    .padding(.horizontal, HUD.Space.l)
            }
            ScrollView {
                Group {
                    switch session.warRoom.tab {
                    case .production: ProductionOrders(session: session, editable: editable)
                    case .army: ArmyOrders(session: session, editable: editable)
                    }
                }
                .padding(.horizontal, HUD.Space.l)
                .padding(.bottom, HUD.Space.xl)
            }
        }
        .foregroundStyle(HUD.ink)
        .onAppear { session.pruneWarRoom() }
    }
}

extension GameSession {
    /// Drops War Room picks that are gone (cities lost, units fallen).
    func pruneWarRoom() {
        let view = self.view
        warRoom.cities = warRoom.cities.filter { view.city($0) != nil }
        warRoom.units = warRoom.units.filter { view.unit($0).map { !$0.type.isCivilian } == true }
    }
}

// MARK: - Production

private struct ProductionOrders: View {
    @Bindable var session: GameSession
    var editable: Bool

    var body: some View {
        let view = session.view
        let cities = view.cities.sorted { ($0.buildings.contains("palace") ? 0 : 1, $0.name) < ($1.buildings.contains("palace") ? 0 : 1, $1.name) }
        let idle = cities.filter { $0.queue.isEmpty }
        let picked = cities.filter { session.warRoom.cities.contains($0.id) }
        VStack(alignment: .leading, spacing: HUD.Space.m) {
            if cities.isEmpty {
                Text("You have no cities yet.").font(HUD.body()).foregroundStyle(HUD.inkSoft)
            } else {
                HStack(spacing: HUD.Space.s) {
                    SectionHeader(title: "Cities · \(picked.count) of \(cities.count) picked")
                }
                PickChips {
                    PickChip(title: "All", on: picked.count == cities.count) { session.warRoom.cities = Set(cities.map(\.id)) }
                    PickChip(title: "None", on: picked.isEmpty) { session.warRoom.cities = [] }
                    PickChip(title: "Idle · \(idle.count)", on: !idle.isEmpty && Set(idle.map(\.id)) == session.warRoom.cities) {
                        session.warRoom.cities = Set(idle.map(\.id))
                    }
                    .disabled(idle.isEmpty)
                }
                VStack(spacing: HUD.Space.xs) {
                    ForEach(cities, id: \.id) { city in
                        CityOrderRow(session: session, city: city, picked: session.warRoom.cities.contains(city.id)) {
                            session.warRoom.cities.formSymmetricDifference([city.id])
                        }
                    }
                }
                if !picked.isEmpty {
                    BulkItemPicker(session: session, cities: picked.map(\.id), editable: editable)
                    RallyControls(session: session, cities: picked.map(\.id))
                } else {
                    Hint(systemImage: "hand.tap", text: "Pick cities to change what they build all at once, or to send their new units to a rally point.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One city: its pick box, size, production, what it builds and its rally point.
private struct CityOrderRow: View {
    let session: GameSession
    let city: City
    var picked: Bool
    var toggle: () -> Void

    var body: some View {
        let view = session.view
        let status = view.queueStatus(of: city.id)
        let perTurn = view.cityYields(city.id)?.total.production ?? 0
        Button(action: toggle) {
            HStack(spacing: HUD.Space.s) {
                PickBox(on: picked)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: HUD.Space.xs) {
                        if city.buildings.contains("palace") { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(HUD.gilt) }
                        Text(city.name).font(HUD.title(.subheadline)).lineLimit(1)
                        Text("\(city.population)").font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft)
                        Label("\(perTurn)", systemImage: YieldChip.Kind.production.systemImage)
                            .font(HUD.numeric(.caption)).foregroundStyle(HUD.Yield.production)
                            .labelStyle(.titleAndIcon)
                        if let rally = session.rally(of: city.id) {
                            Label(session.placeName(rally), systemImage: "flag.fill")
                                .font(HUD.body(.caption2)).foregroundStyle(HUD.danger).lineLimit(1)
                        }
                    }
                    if let head = status.first {
                        HStack(spacing: HUD.Space.xs) {
                            ItemIcon(item: head.item, size: 18)
                            Text(head.name).font(HUD.body(.caption).weight(.semibold)).lineLimit(1)
                            if let turns = head.turns { Text("· \(turns == 1 ? "1 turn" : "\(turns) turns")").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft) }
                            if status.count > 1 { Text("· +\(status.count - 1) queued").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft) }
                        }
                    } else {
                        Label("Nothing in production", systemImage: "exclamationmark.circle.fill")
                            .font(HUD.body(.caption).weight(.semibold)).foregroundStyle(HUD.danger)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HUD.Space.m)
            .padding(.vertical, HUD.Space.xs)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous)
                .fill(picked ? HUD.gilt.opacity(0.16) : HUD.parchmentWell.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous)
                .stroke(picked ? HUD.gilt : HUD.ink.opacity(0.15), lineWidth: picked ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// What the picked cities can build, and where it goes in their queues.
private struct BulkItemPicker: View {
    @Bindable var session: GameSession
    var cities: [CityID]
    var editable: Bool

    private struct Choice: Identifiable {
        var item: ProductionItem
        var name: String
        var cost: Int
        var takers: Int
        var problem: String?
        var id: ProductionItem { item }
    }

    var body: some View {
        let view = session.view
        let placement = session.warRoom.placement
        let items = UnitType.allCases.map { ProductionItem.unit($0) } + view.rules.buildings.filter(\.buildable).map { ProductionItem.building($0.id) }
        let choices: [Choice] = items.compactMap { item in
            let changes = view.bulkQueues(item, in: cities, placement: placement)
            let takers = changes.filter { $0.items != nil }.count
            // Items no picked city may build at all (a tech or resource missing, built) are left out.
            let available = changes.contains { $0.items != nil || ["queue full", "already queued", "already first", "already its only item"].contains($0.problem ?? "") }
            guard available else { return nil }
            let problem = takers == 0 ? changes.first?.problem : nil
            return Choice(item: item, name: session.state.itemName(item), cost: view.rules.cost(of: item), takers: takers, problem: problem)
        }
        let military = choices.filter { if case let .unit(t) = $0.item { !t.isCivilian } else { false } }
        let civilian = choices.filter { if case let .unit(t) = $0.item { t.isCivilian } else { false } }
        let buildings = choices.filter { if case .building = $0.item { true } else { false } }
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            SectionHeader(title: "Order for \(cities.count) cit\(cities.count == 1 ? "y" : "ies")").padding(.top, HUD.Space.s)
            Picker("Where it goes", selection: $session.warRoom.placement) {
                Text("Build next").tag(BulkPlacement.first)
                Text("Add to queue").tag(BulkPlacement.last)
                Text("Replace queue").tag(BulkPlacement.only)
            }
            .pickerStyle(.segmented)
            Text(Self.placementHint(placement)).font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            group("Military units", military)
            group("Other units", civilian)
            group("Buildings", buildings)
        }
    }

    static func placementHint(_ placement: BulkPlacement) -> String {
        switch placement {
        case .first: "Goes ahead of everything queued; what was being built keeps its progress."
        case .last: "Goes after everything queued."
        case .only: "Becomes each city's only item; the rest of the queue is dropped (progress is stored)."
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ choices: [Choice]) -> some View {
        if !choices.isEmpty {
            Text(title).font(HUD.title(.caption)).foregroundStyle(HUD.inkSoft).padding(.top, HUD.Space.xs)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: HUD.Space.xs)], spacing: HUD.Space.xs) {
                ForEach(choices.sorted { ($0.cost, $0.name) < ($1.cost, $1.name) }) { choice in
                    Button {
                        session.bulkQueue(choice.item, in: cities, placement: session.warRoom.placement)
                    } label: {
                        HStack(spacing: HUD.Space.s) {
                            ItemIcon(item: choice.item, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.name).font(HUD.title(.caption)).lineLimit(1).minimumScaleFactor(0.8)
                                Text(choice.takers > 0 ? "\(choice.takers) of \(cities.count) · \(choice.cost)⚒" : (choice.problem ?? "none can"))
                                    .font(HUD.numeric(.caption2))
                                    .foregroundStyle(choice.takers > 0 ? HUD.inkSoft : HUD.danger)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, HUD.Space.s)
                        .frame(maxWidth: .infinity, minHeight: HUD.touch, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous).fill(HUD.parchmentTop.opacity(0.7)))
                        .overlay(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous).stroke(HUD.ink.opacity(0.2), lineWidth: 1))
                        .opacity(choice.takers > 0 ? 1 : 0.5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!editable || choice.takers == 0)
                    .accessibilityLabel("\(choice.name), \(choice.takers) of \(cities.count) cities can build it")
                }
            }
        }
    }
}

/// The picked cities' rally point.
private struct RallyControls: View {
    let session: GameSession
    var cities: [CityID]

    var body: some View {
        let rallied = cities.filter { session.rally(of: $0) != nil }
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            SectionHeader(title: "Rally point").padding(.top, HUD.Space.s)
            Text("New military units from these cities, built or bought, march to the rally point by themselves and fortify there.")
                .font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: HUD.Space.s) {
                Button {
                    session.beginRally(cities)
                } label: {
                    Label(rallied.isEmpty ? "Set on the map…" : "Move on the map…", systemImage: "flag.fill")
                }
                .buttonStyle(ParchmentButtonStyle())
                if !rallied.isEmpty {
                    Button {
                        session.clearRally(rallied)
                    } label: {
                        Label("Clear (\(rallied.count))", systemImage: "flag.slash")
                    }
                    .buttonStyle(ParchmentButtonStyle())
                }
            }
        }
    }
}

// MARK: - Army

private struct ArmyOrders: View {
    @Bindable var session: GameSession
    var editable: Bool

    var body: some View {
        let view = session.view
        let all = session.armyUnits
        let maxHP = view.rules.constants.healing.maxHP
        let shown = all.filter { unit in
            switch session.warRoom.filter {
            case .all: true
            case .idle: session.isIdle(unit)
            case .fortified: unit.activity == .fortified || unit.activity == .fortifying
            case .marching: session.war.isMarching(unit.id) || unit.destination != nil
            case .hurt: unit.hp < maxHP
            }
        }
        // By place, the biggest first.
        let places = Dictionary(grouping: shown) { session.placeName($0.position) }
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
        let picked = all.filter { session.warRoom.units.contains($0.id) }
        VStack(alignment: .leading, spacing: HUD.Space.m) {
            if all.isEmpty {
                Text("You have no military units. Build them in the Production tab.").font(HUD.body()).foregroundStyle(HUD.inkSoft)
            } else {
                summary(all)
                PickChips {
                    ForEach(ArmyFilter.allCases) { filter in
                        PickChip(title: filter.title, on: session.warRoom.filter == filter) { session.warRoom.filter = filter }
                    }
                }
                HStack {
                    SectionHeader(title: "\(picked.count) of \(all.count) picked")
                    Button(shown.allSatisfy { session.warRoom.units.contains($0.id) } && !shown.isEmpty ? "Drop shown" : "Pick shown") {
                        let ids = Set(shown.map(\.id))
                        if ids.isSubset(of: session.warRoom.units) { session.warRoom.units.subtract(ids) } else { session.warRoom.units.formUnion(ids) }
                    }
                    .font(HUD.title(.caption))
                    .disabled(shown.isEmpty)
                }
                if !picked.isEmpty {
                    ArmyActions(session: session, units: picked.map(\.id), editable: editable)
                }
                ForEach(places, id: \.key) { place, units in
                    PlaceGroup(session: session, place: place, units: units.sorted { ($0.type.rawValue, $0.id) < ($1.type.rawValue, $1.id) })
                }
                if shown.isEmpty {
                    Text("No unit is \(session.warRoom.filter.title.lowercased()).").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                }
            }
        }
    }

    private func summary(_ all: [GameCore.Unit]) -> some View {
        let idle = all.filter { session.isIdle($0) }.count
        let marching = all.filter { session.war.isMarching($0.id) }.count
        let fortified = all.filter { $0.activity == .fortified || $0.activity == .fortifying }.count
        return HStack(spacing: HUD.Space.m) {
            StatCount(value: all.count, name: "units", systemImage: "shield.lefthalf.filled")
            StatCount(value: idle, name: "idle", systemImage: "hourglass", tint: idle > 0 ? HUD.danger : HUD.inkSoft)
            StatCount(value: marching, name: "marching", systemImage: "figure.walk")
            StatCount(value: fortified, name: "fortified", systemImage: "shield.fill")
        }
    }
}

/// Units standing in one place, with a pick-all for the place.
private struct PlaceGroup: View {
    @Bindable var session: GameSession
    var place: String
    var units: [GameCore.Unit]

    var body: some View {
        let ids = Set(units.map(\.id))
        let all = ids.isSubset(of: session.warRoom.units)
        VStack(alignment: .leading, spacing: HUD.Space.xs) {
            Button {
                if all { session.warRoom.units.subtract(ids) } else { session.warRoom.units.formUnion(ids) }
            } label: {
                HStack(spacing: HUD.Space.s) {
                    PickBox(on: all, partial: !all && !ids.isDisjoint(with: session.warRoom.units))
                    Text(place.prefix(1).uppercased() + place.dropFirst()).font(HUD.title(.subheadline))
                    Text("\(units.count)").font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft)
                    Spacer()
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(units, id: \.id) { unit in
                UnitOrderRow(session: session, unit: unit, picked: session.warRoom.units.contains(unit.id))
            }
        }
    }
}

private struct UnitOrderRow: View {
    let session: GameSession
    let unit: GameCore.Unit
    var picked: Bool

    var body: some View {
        let view = session.view
        let maxHP = view.rules.constants.healing.maxHP
        let status = session.armyStatus(of: unit)
        HStack(spacing: HUD.Space.s) {
            Button {
                session.warRoom.units.formSymmetricDifference([unit.id])
            } label: {
                HStack(spacing: HUD.Space.s) {
                    PickBox(on: picked)
                    ItemIcon(item: .unit(unit.type), size: 28, tint: HUD.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: HUD.Space.xs) {
                            Text(unit.type.displayName).font(HUD.title(.caption)).lineLimit(1)
                            if unit.hp < maxHP { HealthBar(fraction: Double(unit.hp) / Double(maxHP), height: 5).frame(width: 40) }
                        }
                        Text(status).font(HUD.body(.caption2))
                            .foregroundStyle(status == "Awaiting orders" ? HUD.danger : HUD.inkSoft)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                session.openPanel = nil
                session.select(.unit(unit.id))
                session.lookAt(unit.position)
            } label: {
                Image(systemName: "scope").font(.system(size: 14, weight: .semibold)).foregroundStyle(HUD.inkSoft)
                    .frame(width: HUD.touch, height: HUD.touch)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show on the map")
        }
        .padding(.leading, HUD.Space.s)
        .frame(minHeight: 46)
        .background(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous)
            .fill(picked ? HUD.gilt.opacity(0.16) : HUD.parchmentWell.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous)
            .stroke(picked ? HUD.gilt : HUD.ink.opacity(0.12), lineWidth: picked ? 1.5 : 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// What the picked units can be told: go somewhere together, fortify, wake, halt.
private struct ArmyActions: View {
    let session: GameSession
    var units: [UnitID]
    var editable: Bool

    var body: some View {
        let view = session.view
        let rallies = Array(Set(session.war.rallies.values)).sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        let ownCities = view.cities.sorted { $0.name < $1.name }
        let threatened = Set(view.threatenedCities())
        let enemyCities = view.knownCities.filter { view.isAtWar(with: $0.owner) }.sorted { $0.name < $1.name }
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            HStack(spacing: HUD.Space.s) {
                Button {
                    session.beginMarch(units)
                } label: {
                    Label("Send to…", systemImage: "arrow.up.right.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(BronzeButtonStyle())
                Menu {
                    if !enemyCities.isEmpty {
                        Section("Attack: enemy cities") {
                            ForEach(enemyCities, id: \.id) { city in
                                Button("\(city.name) · \(session.civName(of: city.owner))") { session.show(session.sendArmy(units, to: city.position), for: 4) }
                            }
                        }
                    }
                    if !rallies.isEmpty {
                        Section("Rally points") {
                            ForEach(rallies, id: \.self) { tile in
                                Button(session.placeName(tile).prefix(1).uppercased() + session.placeName(tile).dropFirst()) {
                                    session.show(session.sendArmy(units, to: tile), for: 4)
                                }
                            }
                        }
                    }
                    Section("Defend: your cities") {
                        ForEach(ownCities, id: \.id) { city in
                            Button(threatened.contains(city.id) ? "\(city.name) · threatened" : city.name) {
                                session.show(session.sendArmy(units, to: city.position), for: 4)
                            }
                        }
                    }
                } label: {
                    Label("Goals", systemImage: "list.bullet")
                        .font(HUD.title(.headline))
                        .padding(.horizontal, HUD.Space.m)
                        .frame(minHeight: 48)
                        .background(Capsule().fill(HUD.parchmentTop))
                        .overlay(Capsule().stroke(HUD.ink.opacity(0.6), lineWidth: 1.2))
                }
            }
            .disabled(!editable)
            HStack(spacing: HUD.Space.s) {
                Button { session.fortifyAll(units) } label: { Label("Fortify", systemImage: "shield.fill").frame(maxWidth: .infinity) }
                Button { session.wakeAll(units) } label: { Label("Wake", systemImage: "sun.max").frame(maxWidth: .infinity) }
                Button { session.haltAll(units) } label: { Label("Halt", systemImage: "hand.raised").frame(maxWidth: .infinity) }
            }
            .buttonStyle(ParchmentButtonStyle())
            .disabled(!editable)
        }
        .padding(HUD.Space.m)
        .background(RoundedRectangle(cornerRadius: HUD.Radius.medium, style: .continuous).fill(HUD.gilt.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: HUD.Radius.medium, style: .continuous).stroke(HUD.gilt.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - Small parts

private struct PickBox: View {
    var on: Bool
    var partial = false

    var body: some View {
        Image(systemName: on ? "checkmark.square.fill" : partial ? "minus.square.fill" : "square")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(on || partial ? HUD.gilt : HUD.inkSoft)
            .frame(width: 24)
            .accessibilityHidden(true)
    }
}

private struct PickChips<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HUD.Space.xs) { content() }
        }
    }
}

private struct PickChip: View {
    var title: String
    var on: Bool
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(HUD.title(.caption))
                .padding(.horizontal, HUD.Space.m)
                .frame(minHeight: 34)
                .background(Capsule().fill(on ? HUD.gilt.opacity(0.35) : HUD.parchmentWell.opacity(0.8)))
                .overlay(Capsule().stroke(on ? HUD.gilt : HUD.ink.opacity(0.2), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct StatCount: View {
    var value: Int
    var name: String
    var systemImage: String
    var tint: Color = HUD.inkSoft

    var body: some View {
        VStack(spacing: 0) {
            Label("\(value)", systemImage: systemImage).font(HUD.numeric(.subheadline)).foregroundStyle(tint)
            Text(name).font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The goal card and the unit card's parts

/// Choosing a war order's goal on the map: what a tap does, the preview, Go and Cancel.
struct WarTargetCard: View {
    let session: GameSession
    let targeting: WarTargeting

    var body: some View {
        HStack(alignment: .top, spacing: HUD.Space.m) {
            Image(systemName: targeting.cities.isEmpty ? "arrow.up.right.circle.fill" : "flag.fill")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(targeting.cities.isEmpty ? HUD.gilt : HUD.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(HUD.title(.subheadline))
                Text(detail).font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: HUD.Space.s)
            VStack(spacing: HUD.Space.xs) {
                if targeting.plan != nil || targeting.rallyTile != nil {
                    Button(targeting.cities.isEmpty ? "March" : "Set") { session.confirmWarTarget() }
                        .buttonStyle(BronzeButtonStyle())
                }
                Button("Cancel") { session.endWarTargeting() }
                    .buttonStyle(ParchmentButtonStyle())
            }
        }
        .hudCard()
    }

    private var title: String {
        if !targeting.cities.isEmpty {
            let n = targeting.cities.count
            return "Rally point for \(n == 1 ? (session.view.city(targeting.cities[0])?.name ?? "the city") : "\(n) cities")"
        }
        let n = targeting.units.count
        if let plan = targeting.plan { return "\(n == 1 ? "Send the unit" : "Send \(n) units") to \(session.placeName(plan.target))" }
        return n == 1 ? "Where does the unit go?" : "Where do the \(n) units go?"
    }

    private var detail: String {
        if !targeting.cities.isEmpty {
            return targeting.rallyTile == nil ? "Tap explored land: new military units from \(targeting.cities.count == 1 ? "the city" : "these cities") march there and fortify."
                : "Tap the flag again, or Set. Tap elsewhere to move it."
        }
        if let plan = targeting.plan {
            return GameSession.planSummary(plan).prefix(1).uppercased() + GameSession.planSummary(plan).dropFirst()
                + ". Each has its own place (dashed rings). Tap the goal again, or March."
        }
        return "Tap a tile: the group gathers around it, each unit on its own tile; an enemy city is surrounded. Tap own units to add or drop them."
    }
}

/// The unit card's Group tile: gathers the military units nearby to send them together.
struct GroupTile: View {
    let session: GameSession
    let unit: GameCore.Unit
    var compact = false
    @State private var pressed = false

    var body: some View {
        Label("Group", systemImage: "person.3.fill")
            .actionTile(pressed: pressed, lit: session.isInputEnabled, compact: compact, fill: true)
            .onTapGesture { session.beginGroup(around: unit.id) }
            .onLongPressGesture(minimumDuration: 0.4, perform: {
                session.show("Group: send this unit and the military units within \(GameSession.groupRadius) tiles somewhere together", for: 3)
            }, onPressingChanged: { pressed = $0 })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Group")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Gathers the military units nearby, then you pick where they all go.")
            .accessibilityAction { session.beginGroup(around: unit.id) }
    }
}

/// The unit card's line about its march.
struct MarchRow: View {
    let session: GameSession
    let unit: GameCore.Unit

    var body: some View {
        if session.war.isMarching(unit.id) {
            let target = session.war.marches[unit.id].map { session.placeName($0.target) } ?? "its goal"
            Hint(systemImage: "person.3.fill", text: "In a group marching to \(target): it keeps its own place there, and fortifies on arrival unless an enemy is near. Give it any order to take it out of the march.")
        }
    }
}
