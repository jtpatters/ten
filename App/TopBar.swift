import GameCore
import SwiftUI

/// The top bar (M1 §16): the turn, Gold (treasury and net per turn), Science (per turn, the
/// research and its turns left, with its progress), Culture (per turn), then the game menu.
/// Gold and Science open small panels: where the gold comes from and goes, and the research
/// choice. In compact width the chips are icon and number only and research takes a second row.
struct TopBar<MenuContent: View>: View {
    let session: GameSession
    var compact: Bool
    /// Opens the research choice (the tech panel, when there is one).
    var onResearch: () -> Void
    @ViewBuilder var menu: () -> MenuContent

    @State private var showingGold = false
    @State private var showingCulture = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let view = session.view
        let income = view.income()
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            HStack(spacing: HUD.Space.s) {
                turnChip(view)
                goldChip(view, income)
                if !compact { researchChip(view, income) }
                cultureChip(income)
                StrategicChip(view: view, compact: compact)
                Spacer(minLength: 0)
                menu()
            }
            if compact { researchChip(view, income) }
        }
    }

    private func turnChip(_ view: PlayerView) -> some View {
        HStack(spacing: HUD.Space.s) {
            PlayerEmblem(player: session.viewer, size: 26)
            // The number alone in compact width and at the accessibility text sizes; never broken.
            Text(compact || typeSize.isAccessibilitySize ? "\(view.turn)" : "Turn \(view.turn)").font(HUD.title(.headline)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.leading, HUD.Space.s)
        .padding(.trailing, HUD.Space.m)
        .frame(minHeight: HUD.touch)
        .parchmentCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.viewerCivName), turn \(view.turn)")
    }

    private func goldChip(_ view: PlayerView, _ income: Income) -> some View {
        Button {
            showingGold = true
        } label: {
            YieldChip(kind: .gold, total: view.me.gold, perTurn: income.net)
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityHint("Shows where your gold comes from.")
        .popover(isPresented: $showingGold) {
            GoldBreakdown(view: view, income: income)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func cultureChip(_ income: Income) -> some View {
        Button {
            showingCulture = true
        } label: {
            YieldChip(kind: .culture, total: nil, perTurn: income.culture)
        }
        .buttonStyle(ChipButtonStyle())
        .popover(isPresented: $showingCulture) {
            InfoPopover(title: "Culture", systemImage: YieldChip.Kind.culture.systemImage, tint: HUD.Yield.culture,
                        lines: ["\(YieldChip.signed(income.culture)) per turn from your cities.",
                                "Each city's culture grows its borders, claiming new tiles to work."])
                .presentationCompactAdaptation(.popover)
        }
    }

    /// Research: what is being learnt, its turns left and progress; "Choose research" when
    /// nothing is (an attention item).
    private func researchChip(_ view: PlayerView, _ income: Income) -> some View {
        let options = view.researchOptions()
        let current = options.first(where: \.researching)
        let target = options.first(where: \.isTarget)
        let progress = current.map { Double(view.me.researchProgress) / Double(max($0.cost, 1)) } ?? 0
        return Button(action: onResearch) {
            HStack(spacing: HUD.Space.xs) {
                Image(systemName: YieldChip.Kind.science.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HUD.Yield.science)
                Text(YieldChip.signed(income.science)).font(HUD.numeric()).lineLimit(1).fixedSize()
                if let current {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: HUD.Space.xs) {
                            Text(current.name).font(HUD.title(.caption)).lineLimit(1)
                            if let turns = current.turns {
                                Text("· \(turnsText(turns))").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft).lineLimit(1)
                            }
                            if let target, target.tech != current.tech {
                                Text("→ \(target.name)").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft).lineLimit(1)
                            }
                        }
                        // On its own row (compact width) the bar runs the chip's length.
                        ProgressBar(fraction: progress, tint: HUD.Yield.science, height: 3)
                            .frame(maxWidth: compact ? .infinity : 140)
                    }
                    .fixedSize(horizontal: !compact, vertical: false)
                } else if options.contains(where: { !$0.known }) {
                    Text("Choose research").font(HUD.title(.caption)).foregroundStyle(HUD.danger)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text("Every tech learnt").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                }
                if compact { Spacer(minLength: 0) }
            }
            .padding(.horizontal, HUD.Space.m)
            .frame(minHeight: HUD.touch)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .parchmentCapsule()
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current.map { c in
            "Science \(YieldChip.signed(income.science)) per turn, researching \(c.name)" + (c.turns.map { ", \(turnsText($0))" } ?? "")
        } ?? "Science \(YieldChip.signed(income.science)) per turn, no research chosen")
        .accessibilityHint("Choose what to research.")
        .accessibilityAddTraits(.isButton)
    }
}

/// Strategic stockpiles (M2 §3.1): each revealed (or stocked) strategic resource's amount out of
/// its cap; a tap shows the improved sources and what the units cost. Hidden until there is one.
struct StrategicChip: View {
    let view: PlayerView
    var compact: Bool
    @State private var showing = false

    struct Entry: Hashable {
        var name: String
        var amount: Int
        var sources: Int
        var cap: Int
    }

    static func entries(_ view: PlayerView) -> [Entry] {
        Resource.allCases.compactMap { r in
            guard let def = view.rules.resource(r), def.kind == .strategic else { return nil }
            let stock = view.stock(r)
            let revealed = def.revealedBy.map(view.me.knows) ?? true
            guard revealed || stock.amount > 0 || stock.sources > 0 else { return nil }
            return Entry(name: def.displayName, amount: stock.amount, sources: stock.sources, cap: stock.cap)
        }
    }

    var body: some View {
        let entries = Self.entries(view)
        if !entries.isEmpty {
            Button {
                showing = true
            } label: {
                HStack(spacing: HUD.Space.s) {
                    ForEach(entries, id: \.name) { entry in
                        HStack(spacing: HUD.Space.xxs) {
                            Text(compact ? String(entry.name.prefix(1)) : entry.name).font(HUD.title(.caption)).lineLimit(1)
                            Text("\(entry.amount)/\(entry.cap)").font(HUD.numeric(.caption)).monospacedDigit().lineLimit(1)
                                .foregroundStyle(entry.amount == 0 ? HUD.danger : HUD.ink)
                        }
                        .fixedSize()
                    }
                }
                .padding(.horizontal, HUD.Space.m)
                .frame(minHeight: HUD.touch)
                .parchmentCapsule()
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entries.map { "\($0.name) \($0.amount) of \($0.cap), \($0.sources) sources" }.joined(separator: "; "))
            .accessibilityHint("Shows your strategic resources.")
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $showing) {
                InfoPopover(title: "Strategic resources", systemImage: "shield.lefthalf.filled", tint: HUD.gilt,
                            lines: Self.lines(entries, view: view))
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    static func lines(_ entries: [Entry], view: PlayerView) -> [String] {
        let s = view.rules.stockpile
        var lines = entries.map { e in
            let gain = (s?.perSource ?? 0) * e.sources
            return "\(e.name): \(e.amount) of \(e.cap), from \(e.sources) improved source\(e.sources == 1 ? "" : "s")"
                + (gain > 0 ? " (+\(gain) per turn)" : "")
        }
        if let s {
            lines.append("Units that need one cost \(s.unitCost) when built, bought or upgraded; at war each uses \(s.warUsePerUnit) a turn, and fights at \(s.shortageStrength) when the stock is empty.")
        }
        return lines
    }
}

/// Where the gold comes from and goes (the Gold chip's panel).
struct GoldBreakdown: View {
    let view: PlayerView
    let income: Income

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            CardHeader(title: "Treasury", systemImage: YieldChip.Kind.gold.systemImage)
            row("Gold in the treasury", "\(view.me.gold)", bold: true)
            Divider().overlay(HUD.inkFaint)
            row("From cities", YieldChip.signed(income.gold))
            let paid = max(0, income.militaryUnits - income.freeUnits)
            row("Unit upkeep (\(paid) of \(income.militaryUnits) military paid)", income.upkeep == 0 ? "0" : "−\(income.upkeep)")
            row("Buildings and quarters", income.buildings == 0 ? "0" : "−\(income.buildings)")
            Divider().overlay(HUD.inkFaint)
            row("Per turn", YieldChip.signed(income.net), bold: true, tint: income.net < 0 ? HUD.danger : HUD.ink)
            if income.net < 0, view.me.gold + income.net < 0 {
                Label("Without gold for upkeep, units will be disbanded.", systemImage: "exclamationmark.triangle.fill")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.danger)
            }
            let shortfall = view.upkeepForecast().shortfall
            if shortfall > 0 {
                Label("−\(shortfall) Science: can't pay upkeep.", systemImage: "exclamationmark.triangle.fill")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.danger)
            }
            Text("\(income.freeUnits) military units are free of upkeep.").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
        }
        .padding(HUD.Space.l)
        .frame(width: 300)
        .foregroundStyle(HUD.ink)
        .background(LinearGradient(colors: [HUD.parchmentTop, HUD.parchmentBottom], startPoint: .top, endPoint: .bottom))
    }

    private func row(_ label: String, _ value: String, bold: Bool = false, tint: Color = HUD.ink) -> some View {
        HStack {
            Text(label).font(bold ? HUD.title(.subheadline) : HUD.body(.subheadline))
            Spacer(minLength: HUD.Space.m)
            Text(value).font(HUD.numeric()).foregroundStyle(tint)
        }
    }
}

/// A small explanatory panel (a chip's popover).
struct InfoPopover: View {
    var title: String
    var systemImage: String
    var tint: Color
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            HStack(spacing: HUD.Space.s) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(title).font(HUD.title(.headline))
            }
            ForEach(lines, id: \.self) { line in
                Text(line).font(HUD.body(.subheadline)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HUD.Space.l)
        .frame(width: 280, alignment: .leading)
        .foregroundStyle(HUD.ink)
        .background(LinearGradient(colors: [HUD.parchmentTop, HUD.parchmentBottom], startPoint: .top, endPoint: .bottom))
    }
}
