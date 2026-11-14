import GameCore
import SwiftUI

/// The tech panel (M1 §16): the techs as a small tree, each with its cost, turns and what it
/// unlocks (an improvement with its sites near the player's cities); tap one to research it (through its missing prerequisites, M1 §6: the path is
/// numbered). Wide enough, the tree is drawn in columns by depth with its links; narrower, it is
/// an indented outline. In another player's phase it is read-only.
struct TechPanel: View {
    let session: GameSession
    var onDone: () -> Void

    @State private var width: CGFloat = 0

    var body: some View {
        let view = session.view
        let options = BuilderGuidance.annotated(view.researchOptions(), view)
        let tree = TechTree(options: options.map(TreeOption.init)).with(eras: view.rules.eras.map(\.name))
        let science = view.income().science
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Research", systemImage: YieldChip.Kind.science.systemImage, onClose: onDone) {
                Text("\(YieldChip.signed(science)) per turn").font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft)
            }
            .padding(.horizontal, HUD.Space.l)
            .padding(.top, HUD.Space.l)
            .padding(.bottom, HUD.Space.xs)
            if let learnt = learnt(view) {
                // The tech learnt this turn (no News card repeats it).
                Label(learnt, systemImage: "checkmark.seal.fill")
                    .font(HUD.body(.caption).weight(.semibold))
                    .foregroundStyle(HUD.good)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HUD.Space.l)
                    .padding(.bottom, HUD.Space.xxs)
            }
            Text(status(view, options)).font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                .padding(.horizontal, HUD.Space.l)
                .padding(.bottom, HUD.Space.s)
            ScrollView([.vertical]) {
                Group {
                    if width >= TechTreeLayout.minWidth {
                        TechTreeLayout(tree: tree, width: width - 2 * HUD.Space.l, progress: progress(view)) { choose($0) }
                    } else {
                        TechOutline(tree: tree, progress: progress(view)) { choose($0) }
                    }
                }
                .padding(.horizontal, HUD.Space.l)
                .padding(.bottom, HUD.Space.xl)
                .opacity(session.isInputEnabled ? 1 : 0.75)
            }
        }
        .foregroundStyle(HUD.ink)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// "Learnt Bronze Working: Spearman", in the turn it was learnt.
    private func learnt(_ view: PlayerView) -> String? {
        guard let last = session.lastResearched, last.turn == view.turn, view.me.knows(last.tech) else { return nil }
        let name = view.rules.tech(last.tech)?.name ?? last.tech.rawValue
        let unlocks = view.unlocks(of: last.tech)
        return unlocks.isEmpty ? "Learnt \(name)" : "Learnt \(name): \(unlocks.joined(separator: ", "))"
    }

    private func status(_ view: PlayerView, _ options: [ResearchOption]) -> String {
        if let waiting = session.waitingFor { return "Waiting for \(waiting.civName)." }
        if let current = options.first(where: \.researching) {
            let turns = current.turns.map { ", \(turnsText($0)) left" } ?? ""
            if let target = options.first(where: \.isTarget), target.tech != current.tech {
                return "Researching \(current.name)\(turns), on the way to \(target.name)."
            }
            return "Researching \(current.name)\(turns). Tap another tech to change."
        }
        if options.allSatisfy(\.known) { return "Every tech of this age is known." }
        return "Choose what to research. Techs whose prerequisites are missing are reached through them."
    }

    /// Research progress toward the tech being researched, 0...1.
    private func progress(_ view: PlayerView) -> Double {
        guard let tech = view.me.researching, let def = view.rules.tech(tech) else { return 0 }
        return Double(view.me.researchProgress) / Double(max(def.cost, 1))
    }

    private func choose(_ node: TreeOption) {
        guard let option = session.view.researchOptions().first(where: { $0.tech.rawValue == node.key }) else { return }
        if session.chooseResearch(option) { onDone() }
    }
}

extension GameSession {
    /// A tap on a tech panel row (and automation `research`): researches the tech (through its
    /// missing prerequisites), or says it is known. True when the research was set (the panel
    /// then closes).
    @discardableResult
    func chooseResearch(_ option: ResearchOption) -> Bool {
        guard !option.known else {
            show("\(option.name) is already known")
            return false
        }
        return perform(.setResearch(tech: option.tech))
    }
}

// MARK: - Civics

/// The civic panel (M2 §7.1): the civics as the tech panel's tree, Culture in place of Science;
/// tap one to study it (through its missing prerequisites). Read-only in another player's phase.
struct CivicPanel: View {
    let session: GameSession
    var onDone: () -> Void

    @State private var width: CGFloat = 0

    var body: some View {
        let view = session.view
        let options = view.civicOptions()
        let tree = TechTree(options: options.map(TreeOption.init), track: .culture).with(eras: view.rules.eras.map(\.name))
        let culture = view.income().culture
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Civics", systemImage: YieldChip.Kind.culture.systemImage, onClose: onDone) {
                Text("\(YieldChip.signed(culture)) per turn").font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft)
            }
            .padding(.horizontal, HUD.Space.l)
            .padding(.top, HUD.Space.l)
            .padding(.bottom, HUD.Space.xs)
            if let learnt = learnt(view) {
                Label(learnt, systemImage: "checkmark.seal.fill")
                    .font(HUD.body(.caption).weight(.semibold))
                    .foregroundStyle(HUD.good)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HUD.Space.l)
                    .padding(.bottom, HUD.Space.xxs)
            }
            Text(status(view, options)).font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                .padding(.horizontal, HUD.Space.l)
                .padding(.bottom, HUD.Space.s)
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if width >= TechTreeLayout.minWidth {
                        TechTreeLayout(tree: tree, width: max(width - 2 * HUD.Space.l, CGFloat(tree.depth) * 190), progress: progress(view)) { choose($0) }
                    } else {
                        TechOutline(tree: tree, progress: progress(view)) { choose($0) }
                    }
                }
                .padding(.horizontal, HUD.Space.l)
                .padding(.bottom, HUD.Space.xl)
                .opacity(session.isInputEnabled ? 1 : 0.75)
            }
        }
        .foregroundStyle(HUD.ink)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// "Completed Code of Laws: Chiefdom, Discipline", in the turn it was completed.
    private func learnt(_ view: PlayerView) -> String? {
        guard let last = session.lastCivic, last.turn == view.turn, view.me.knowsCivic(last.civic) else { return nil }
        let name = view.rules.civic(last.civic)?.name ?? last.civic.rawValue
        let unlocks = view.unlocks(of: last.civic)
        return unlocks.isEmpty ? "Completed \(name)" : "Completed \(name): \(unlocks.joined(separator: ", "))"
    }

    private func status(_ view: PlayerView, _ options: [CivicOption]) -> String {
        if let waiting = session.waitingFor { return "Waiting for \(waiting.civName)." }
        if let current = options.first(where: \.studying) {
            let turns = current.turns.map { ", \(turnsText($0)) left" } ?? ""
            if let target = options.first(where: \.isTarget), target.civic != current.civic {
                return "Studying \(current.name)\(turns), on the way to \(target.name)."
            }
            return "Studying \(current.name)\(turns). Tap another civic to change."
        }
        if options.allSatisfy(\.known) { return "Every civic of this age is known." }
        return "Choose a civic to study. Culture goes into it each turn; each unlocks governments and policies."
    }

    private func progress(_ view: PlayerView) -> Double {
        guard let civic = view.me.studying, let def = view.rules.civic(civic) else { return 0 }
        return Double(view.me.civicProgress ?? 0) / Double(max(def.cost, 1))
    }

    private func choose(_ node: TreeOption) {
        guard let option = session.view.civicOptions().first(where: { $0.civic.rawValue == node.key }) else { return }
        if session.chooseCivic(option) { onDone() }
    }
}

extension GameSession {
    /// A tap on a civic panel row (and automation `civic`): studies the civic (through its
    /// missing prerequisites), or says it is known. True when it was set.
    @discardableResult
    func chooseCivic(_ option: CivicOption) -> Bool {
        guard !option.known else {
            show("\(option.name) is already known")
            return false
        }
        return perform(.setCivic(civic: option.civic))
    }
}

/// What the tech and civic trees draw: a tech or a civic, keyed by its id.
struct TreeOption {
    var key: String
    var name: String
    var cost: Int
    var requires: [String]
    var known: Bool
    /// Being researched or studied.
    var active: Bool
    var isTarget: Bool
    var available: Bool
    var turns: Int?
    var unlocks: [String]
    var era: Int
    var credit: Int
    var insight: String?
    var insightGained: Bool

    init(_ o: ResearchOption) {
        self.init(key: o.tech.rawValue, name: o.name, cost: o.cost, requires: o.requires.map(\.rawValue), known: o.known,
                  active: o.researching, isTarget: o.isTarget, available: o.available, turns: o.turns, unlocks: o.unlocks,
                  era: o.era, credit: o.credit, insight: o.insight, insightGained: o.insightGained)
    }

    init(_ o: CivicOption) {
        self.init(key: o.civic.rawValue, name: o.name, cost: o.cost, requires: o.requires.map(\.rawValue), known: o.known,
                  active: o.studying, isTarget: o.isTarget, available: o.available, turns: o.turns, unlocks: o.unlocks,
                  era: o.era, credit: o.credit, insight: o.insight, insightGained: o.insightGained)
    }

    init(key: String, name: String, cost: Int, requires: [String], known: Bool, active: Bool, isTarget: Bool, available: Bool,
         turns: Int?, unlocks: [String], era: Int, credit: Int, insight: String?, insightGained: Bool) {
        self.key = key
        self.name = name
        self.cost = cost
        self.requires = requires
        self.known = known
        self.active = active
        self.isTarget = isTarget
        self.available = available
        self.turns = turns
        self.unlocks = unlocks
        self.era = era
        self.credit = credit
        self.insight = insight
        self.insightGained = insightGained
    }
}

/// Which tree: techs (Science) or civics (Culture).
enum TreeTrack {
    case science, culture

    var tint: Color { self == .science ? HUD.Yield.science : HUD.Yield.culture }
    var icon: String { self == .science ? "flask" : "theatermasks" }
    var activeIcon: String { self == .science ? "flask.fill" : "theatermasks.fill" }
    var unit: String { self == .science ? "science" : "culture" }
    var pathName: String { self == .science ? "research path" : "civic path" }
    var hint: String { self == .science ? "Research it." : "Study it." }
    var activeText: String { self == .science ? "being researched" : "being studied" }
}

// MARK: - Tree

/// The techs arranged as a tree: depth by prerequisites (column), rows in depth-first order with
/// a parent level with its children, and the research path's steps.
struct TechTree {
    /// The era names, by index (M2 §2; empty in rules without eras).
    var eras: [String] = []

    func with(eras: [String]) -> TechTree {
        var tree = self
        tree.eras = eras
        return tree
    }

    func eraName(_ node: Node) -> String? { eras.indices.contains(node.option.era) ? eras[node.option.era] : nil }

    struct Node {
        var option: TreeOption
        var depth: Int
        var row: Double
        /// Prerequisites present in the tree.
        var parents: [String]
        /// Its place in the research path (1 = being researched), if on it.
        var step: Int?
    }

    var track: TreeTrack = .science
    var nodes: [Node]
    var rows: Int
    var depth: Int

    init(options: [TreeOption], track: TreeTrack = .science) {
        self.track = track
        let byID = Dictionary(uniqueKeysWithValues: options.map { ($0.key, $0) })
        var depthOf: [String: Int] = [:]
        func depth(_ id: String) -> Int {
            if let d = depthOf[id] { return d }
            let d = (byID[id]?.requires.compactMap { byID[$0] == nil ? nil : depth($0) + 1 }.max()) ?? 0
            depthOf[id] = d
            return d
        }
        // Children hang under their first prerequisite; leaves take consecutive rows and a parent
        // sits level with the middle of its children.
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for option in options {
            if let parent = option.requires.first(where: { byID[$0] != nil }) {
                children[parent, default: []].append(option.key)
            } else {
                roots.append(option.key)
            }
        }
        var rowOf: [String: Double] = [:]
        var next = 0.0
        func place(_ id: String) {
            let kids = children[id] ?? []
            if kids.isEmpty {
                rowOf[id] = next
                next += 1
            } else {
                kids.forEach(place)
                rowOf[id] = (rowOf[kids.first!]! + rowOf[kids.last!]!) / 2
            }
        }
        roots.forEach(place)
        // The research path: the target's missing prerequisites in tree order, then the target.
        var steps: [String: Int] = [:]
        if let target = options.first(where: \.isTarget) ?? options.first(where: \.active) {
            var needed: Set<String> = [target.key]
            var frontier = [target.key]
            while let id = frontier.popLast() {
                for req in byID[id]?.requires ?? [] where byID[req]?.known == false && !needed.contains(req) {
                    needed.insert(req)
                    frontier.append(req)
                }
            }
            var n = 1
            for option in options where needed.contains(option.key) && !option.known {
                steps[option.key] = n
                n += 1
            }
        }
        nodes = options.map { option in
            Node(option: option, depth: depth(option.key), row: rowOf[option.key] ?? 0,
                 parents: option.requires.filter { byID[$0] != nil }, step: steps[option.key])
        }
        rows = Int(next)
        self.depth = (nodes.map(\.depth).max() ?? 0) + 1
    }

    func node(_ id: String) -> Node? { nodes.first { $0.option.key == id } }

    /// Depth-first order (an outline): each tech followed by the techs under it.
    var outline: [Node] {
        var out: [Node] = []
        var seen: Set<String> = []
        func visit(_ node: Node) {
            guard seen.insert(node.option.key).inserted else { return }
            out.append(node)
            for child in nodes where child.parents.first == node.option.key { visit(child) }
        }
        for root in nodes where root.parents.isEmpty { visit(root) }
        for node in nodes where !seen.contains(node.option.key) { out.append(node) }
        return out
    }
}

/// The tree in columns by depth, linked from each prerequisite to what it leads to.
struct TechTreeLayout: View {
    var tree: TechTree
    private var track: TreeTrack { tree.track }
    var width: CGFloat
    var progress: Double
    var onChoose: (TreeOption) -> Void

    static let minWidth: CGFloat = 540
    static let nodeHeight: CGFloat = 112
    static let rowGap: CGFloat = 10
    static let columnGap: CGFloat = 34

    private var nodeWidth: CGFloat {
        let columns = CGFloat(max(tree.depth, 1))
        return min(230, (width - Self.columnGap * (columns - 1)) / columns)
    }

    private func frame(_ node: TechTree.Node) -> CGRect {
        CGRect(x: CGFloat(node.depth) * (nodeWidth + Self.columnGap), y: node.row * (Self.nodeHeight + Self.rowGap),
               width: nodeWidth, height: Self.nodeHeight)
    }

    var body: some View {
        let height = CGFloat(tree.rows) * (Self.nodeHeight + Self.rowGap) - Self.rowGap
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for node in tree.nodes {
                    for parentID in node.parents {
                        guard let parent = tree.node(parentID) else { continue }
                        let a = frame(parent), b = frame(node)
                        let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.minX, y: b.midY)
                        let midX = (start.x + end.x) / 2
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
                        let lit = node.step != nil || node.option.known
                        context.stroke(path, with: .color(lit ? track.tint.opacity(0.7) : HUD.ink.opacity(0.28)),
                                       style: StrokeStyle(lineWidth: lit ? 2 : 1.5, lineCap: .round))
                    }
                }
            }
            .frame(width: width, height: height)
            ForEach(tree.nodes, id: \.option.key) { node in
                let f = frame(node)
                TechNodeView(node: node, progress: progress, era: tree.eraName(node), track: tree.track, onChoose: onChoose)
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// The tree as an indented outline (narrow screens).
struct TechOutline: View {
    var tree: TechTree
    private var track: TreeTrack { tree.track }
    var progress: Double
    var onChoose: (TreeOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            ForEach(tree.outline, id: \.option.key) { node in
                HStack(spacing: 0) {
                    if node.depth > 0 {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(node.step != nil ? track.tint : HUD.inkFaint)
                            .frame(width: 22)
                            .padding(.leading, CGFloat(node.depth - 1) * 22)
                    }
                    TechNodeView(node: node, progress: progress, era: tree.eraName(node), track: tree.track, onChoose: onChoose)
                        .frame(minHeight: 76)
                }
            }
        }
    }
}

/// One tech: its state (known, researching with progress, on the path with its step, open or
/// locked), name, cost and turns, and unlocks.
private struct TechNodeView: View {
    var node: TechTree.Node
    var progress: Double
    /// Its era's name (M2 §2; nil in rules without eras).
    var era: String?
    var track: TreeTrack
    var onChoose: (TreeOption) -> Void

    var body: some View {
        let option = node.option
        Button {
            onChoose(option)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: HUD.Space.xs + 2) {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(iconTint)
                    Text(option.name).font(HUD.title(.subheadline)).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    if let step = node.step, !option.active {
                        Text("\(step)")
                            .font(HUD.numeric(.caption2))
                            .foregroundStyle(HUD.parchmentTop)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(track.tint))
                            .accessibilityLabel("Step \(step) of the \(track.pathName)")
                    }
                }
                Text(costLine).font(HUD.numeric(.caption2)).foregroundStyle(HUD.inkSoft).lineLimit(1)
                Text(option.unlocks.isEmpty ? " " : option.unlocks.joined(separator: ", "))
                    .font(HUD.body(.caption2))
                    .foregroundStyle(option.known ? HUD.inkSoft : HUD.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let insight = option.insight, !option.known {
                    Label(insight, systemImage: option.insightGained ? "lightbulb.fill" : "lightbulb")
                        .font(HUD.body(.caption2))
                        .foregroundStyle(option.insightGained ? track.tint : HUD.inkSoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if option.active {
                    ProgressBar(fraction: progress, tint: track.tint, height: 4)
                }
            }
            .padding(.horizontal, HUD.Space.s + 2)
            .padding(.vertical, HUD.Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous).fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous)
                    .stroke(stroke, style: StrokeStyle(lineWidth: option.active ? 2 : 1, dash: node.step != nil && !option.active ? [4, 3] : []))
            }
            .contentShape(RoundedRectangle(cornerRadius: HUD.Radius.small))
            .opacity(option.known ? 0.8 : 1)
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(option.known ? "" : track.hint)
    }

    private var icon: String {
        let option = node.option
        if option.known { return "checkmark.seal.fill" }
        if option.active { return track.activeIcon }
        if option.available { return track.icon }
        return "lock.fill"
    }

    private var iconTint: Color {
        let option = node.option
        if option.known { return HUD.good }
        if option.active || node.step != nil { return track.tint }
        return option.available ? HUD.inkSoft : HUD.inkFaint
    }

    private var fill: Color {
        let option = node.option
        if option.active { return track.tint.opacity(0.14) }
        if option.known { return HUD.good.opacity(0.12) }
        return HUD.parchmentWell
    }

    private var stroke: Color {
        let option = node.option
        if option.active { return track.tint }
        if node.step != nil { return track.tint.opacity(0.8) }
        return HUD.ink.opacity(option.available ? 0.3 : 0.15)
    }

    private var costLine: String {
        let option = node.option
        let era = self.era.map { "\($0) · " } ?? ""
        if option.known { return "\(era)Known" }
        let turns = option.turns.map { " · \(turnsText($0))" } ?? ""
        let credit = option.credit > 0 ? " (\(option.credit) credited)" : ""
        return "\(era)\(option.cost) \(track.unit)\(credit)\(turns)"
    }

    private var accessibilityText: String {
        let option = node.option
        var parts = [option.name]
        if option.known { parts.append("known") } else if option.active { parts.append(track.activeText) }
        if !option.known { parts.append(costLine) }
        if !option.unlocks.isEmpty { parts.append("unlocks " + option.unlocks.joined(separator: ", ")) }
        if let insight = option.insight, !option.known {
            parts.append((option.insightGained ? "Insight gained: " : "Insight: ") + insight)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Government

/// The government panel (M2 §7.2–7.3): the government and its policy slots, the policies to
/// slot (a draft, applied at once with its Gold cost, checked by `policiesProblem`), and the
/// governments to change to. A civic just completed makes changes free for the turn.
struct GovernmentPanel: View {
    let session: GameSession
    var onDone: () -> Void

    /// Policy ids being arranged (nil: the slotted ones).
    @State private var draft: [String]?

    /// The `GameSession.panelAnchor` that scrolls to the list of governments.
    static let governmentsAnchor = "governments"

    var body: some View {
        let view = session.view
        let current = view.government
        let slotted = view.policies.map(\.id)
        let draft = self.draft ?? slotted
        let changed = draft != slotted
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Government", systemImage: "building.columns", onClose: onDone) {
                if view.isFreeChangeTurn {
                    Label("Free change this turn", systemImage: "gift.fill").font(HUD.body(.caption).weight(.semibold))
                        .foregroundStyle(HUD.good)
                } else {
                    Text("\(view.me.gold) Gold").font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft)
                }
            }
            .padding(.horizontal, HUD.Space.l)
            .padding(.top, HUD.Space.l)
            .padding(.bottom, HUD.Space.s)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: HUD.Space.l) {
                        if let current {
                            currentSection(current, view)
                            slotsSection(current, draft: draft, view)
                            if changed { applyBar(draft, view) }
                            policiesSection(current, draft: draft, view)
                        }
                        governmentsSection(view).id(GovernmentPanel.governmentsAnchor)
                    }
                    .padding(.horizontal, HUD.Space.l)
                    .padding(.bottom, HUD.Space.xl)
                    .opacity(session.isInputEnabled ? 1 : 0.75)
                }
                .onChange(of: session.panelAnchor, initial: true) {
                    guard let anchor = session.panelAnchor else { return }
                    session.panelAnchor = nil
                    withAnimation { reader.scrollTo(anchor, anchor: .top) }
                }
            }
        }
        .foregroundStyle(HUD.ink)
        .onChange(of: view.policies.map(\.id)) { self.draft = nil }
    }

    private func currentSection(_ gov: GovernmentDef, _ view: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: HUD.Space.xxs) {
            Text(gov.name).font(HUD.title(.title3))
            Text(GovernanceText.slots(gov)).font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft)
            ForEach(GovernanceText.lines(gov.bonuses, view.rules), id: \.self) { line in
                Label(line, systemImage: "plus.circle").font(HUD.body(.caption)).foregroundStyle(HUD.ink)
            }
            if !view.isFreeChangeTurn {
                Text("Changes are free in the turn a civic is completed.").font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft)
            }
        }
    }

    /// Each slot with the draft policy in it: a policy fills its own kind's slots, then Wildcard.
    private func slotsSection(_ gov: GovernmentDef, draft: [String], _ view: PlayerView) -> some View {
        let defs = draft.compactMap(view.rules.policy)
        var wild = defs.filter { $0.kind == .wildcard }
        var rows: [(kind: PolicyKind, index: Int, policy: PolicyDef?)] = []
        for kind in PolicyKind.allCases where kind != .wildcard {
            let mine = defs.filter { $0.kind == kind }
            wild += mine.dropFirst(gov.slots(kind))
            for i in 0..<gov.slots(kind) { rows.append((kind, i, mine.indices.contains(i) ? mine[i] : nil)) }
        }
        for i in 0..<gov.slots(.wildcard) { rows.append((.wildcard, i, wild.indices.contains(i) ? wild[i] : nil)) }
        return VStack(alignment: .leading, spacing: HUD.Space.xs) {
            SectionTitle("Policy slots")
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: HUD.Space.s) {
                    Image(systemName: GovernanceText.icon(row.kind)).foregroundStyle(GovernanceText.tint(row.kind)).frame(width: 20)
                    Text(GovernanceText.name(row.kind)).font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft).frame(width: 74, alignment: .leading)
                    if let policy = row.policy {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(policy.name).font(HUD.title(.subheadline))
                            Text(GovernanceText.lines(policy.bonuses, view.rules).joined(separator: "; "))
                                .font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button {
                            self.draft = draft.filter { $0 != policy.id }
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 18))
                        }
                        .buttonStyle(ChipButtonStyle())
                        .accessibilityLabel("Remove \(policy.name)")
                    } else {
                        Text("Empty").font(HUD.body(.subheadline)).foregroundStyle(HUD.inkFaint)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, HUD.Space.s)
                .padding(.vertical, HUD.Space.xs)
                .background(RoundedRectangle(cornerRadius: HUD.Radius.small).fill(HUD.parchmentWell))
            }
            if rows.isEmpty { Text("This government has no policy slots.").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft) }
        }
    }

    /// The draft's cost and problem, with Apply and Reset.
    private func applyBar(_ draft: [String], _ view: PlayerView) -> some View {
        let problem = view.policiesProblem(draft)
        let cost = view.policyChangeCost(to: draft)
        return VStack(alignment: .leading, spacing: HUD.Space.xs) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(HUD.body(.caption)).foregroundStyle(HUD.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Reset") { self.draft = nil }.buttonStyle(.bordered)
                Spacer()
                Button(cost == 0 ? "Apply (free)" : "Apply (\(cost) Gold)") {
                    if session.perform(.setPolicies(policies: draft)) { self.draft = nil }
                }
                .buttonStyle(.borderedProminent)
                .disabled(problem != nil || !session.isInputEnabled)
            }
        }
    }

    /// The policies that could go in, by kind.
    private func policiesSection(_ gov: GovernmentDef, draft: [String], _ view: PlayerView) -> some View {
        let open = view.availablePolicies.filter { !draft.contains($0.id) }
        return VStack(alignment: .leading, spacing: HUD.Space.xs) {
            SectionTitle("Available policies")
            if open.isEmpty { Text("No other policy is available.").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft) }
            ForEach(open, id: \.id) { policy in
                let proposed = draft + [policy.id]
                let fits = gov.fits(proposed.compactMap(view.rules.policy))
                Button {
                    self.draft = proposed
                } label: {
                    HStack(spacing: HUD.Space.s) {
                        Image(systemName: GovernanceText.icon(policy.kind)).foregroundStyle(GovernanceText.tint(policy.kind)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(policy.name).font(HUD.title(.subheadline))
                            Text(GovernanceText.name(policy.kind) + " · " + GovernanceText.lines(policy.bonuses, view.rules).joined(separator: "; "))
                                .font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: fits ? "plus.circle" : "nosign").foregroundStyle(fits ? HUD.ink : HUD.inkFaint)
                    }
                    .padding(.horizontal, HUD.Space.s)
                    .padding(.vertical, HUD.Space.xs)
                    .background(RoundedRectangle(cornerRadius: HUD.Radius.small).stroke(HUD.ink.opacity(0.2)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(!fits)
                .accessibilityHint(fits ? "Slot it." : "No free slot for it.")
            }
        }
    }

    /// Every government: adopt the open ones, the rest say which civic they need.
    private func governmentsSection(_ view: PlayerView) -> some View {
        let all = view.rules.governance?.governments ?? []
        let open = Set(view.availableGovernments.map(\.id))
        let current = view.government?.id
        return VStack(alignment: .leading, spacing: HUD.Space.xs) {
            SectionTitle("Governments")
            ForEach(all, id: \.id) { gov in
                let cost = view.governmentChangeCost(to: gov.id)
                HStack(alignment: .top, spacing: HUD.Space.s) {
                    Image(systemName: gov.id == current ? "checkmark.seal.fill" : open.contains(gov.id) ? "building.columns" : "lock.fill")
                        .foregroundStyle(gov.id == current ? HUD.good : open.contains(gov.id) ? HUD.ink : HUD.inkFaint)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(gov.name).font(HUD.title(.subheadline))
                        Text(GovernanceText.slots(gov)).font(HUD.numeric(.caption2)).foregroundStyle(HUD.inkSoft)
                        let lines = GovernanceText.lines(gov.bonuses, view.rules)
                        if !lines.isEmpty {
                            Text(lines.joined(separator: "; ")).font(HUD.body(.caption2)).foregroundStyle(HUD.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !open.contains(gov.id), let civic = gov.civic {
                            Text("Needs \(view.rules.civic(civic)?.name ?? civic.rawValue)").font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft)
                        }
                    }
                    Spacer(minLength: 0)
                    if gov.id == current {
                        Text("Current").font(HUD.body(.caption).weight(.semibold)).foregroundStyle(HUD.good)
                    } else if open.contains(gov.id) {
                        Button(cost == 0 ? "Adopt (free)" : "Adopt (\(cost) Gold)") {
                            session.perform(.setGovernment(government: gov.id))
                        }
                        .buttonStyle(.bordered)
                        .disabled(!session.isInputEnabled || cost > view.me.gold)
                    }
                }
                .padding(.horizontal, HUD.Space.s)
                .padding(.vertical, HUD.Space.xs)
                .background(RoundedRectangle(cornerRadius: HUD.Radius.small).fill(gov.id == current ? HUD.good.opacity(0.1) : HUD.parchmentWell))
                .opacity(open.contains(gov.id) || gov.id == current ? 1 : 0.7)
            }
        }
    }
}

private struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(HUD.body(.caption2).weight(.semibold)).foregroundStyle(HUD.inkSoft).padding(.top, HUD.Space.xs)
    }
}

/// Words for governments and policies: slot counts, kinds and what their bonuses do.
enum GovernanceText {
    static func name(_ kind: PolicyKind) -> String {
        switch kind {
        case .military: "Military"
        case .economic: "Economic"
        case .diplomatic: "Diplomatic"
        case .wildcard: "Wildcard"
        }
    }

    static func icon(_ kind: PolicyKind) -> String {
        switch kind {
        case .military: "shield.fill"
        case .economic: "dollarsign.circle.fill"
        case .diplomatic: "person.2.wave.2.fill"
        case .wildcard: "star.fill"
        }
    }

    static func tint(_ kind: PolicyKind) -> Color {
        switch kind {
        case .military: HUD.danger
        case .economic: HUD.Yield.gold
        case .diplomatic: HUD.Yield.science
        case .wildcard: HUD.Yield.culture
        }
    }

    /// "1 Military · 1 Economic · 1 Wildcard".
    static func slots(_ gov: GovernmentDef) -> String {
        let parts = PolicyKind.allCases.compactMap { kind in gov.slots(kind) > 0 ? "\(gov.slots(kind)) \(name(kind))" : nil }
        return parts.isEmpty ? "No policy slots" : parts.joined(separator: " · ")
    }

    /// One line per effect: "+1 Influence per turn", "−25% Production on Melee units".
    static func lines(_ b: Bonuses?, _ rules: Ruleset) -> [String] {
        guard let b else { return [] }
        var out: [String] = []
        func add(_ value: Int?, _ text: (Int) -> String) { if let value, value != 0 { out.append(text(value)) } }
        func signed(_ n: Int) -> String { n < 0 ? "−\(-n)" : "+\(n)" }
        add(b.influence) { "\(signed($0)) Influence per turn" }
        add(b.influencePerFourCities) { "\(signed($0)) Influence per 4 cities" }
        if let y = b.capitalYields {
            let parts = [(y.food, "Food"), (y.production, "Production"), (y.gold, "Gold"), (y.science, "Science"), (y.culture, "Culture")]
                .filter { $0.0 != 0 }.map { "\(signed($0.0)) \($0.1)" }
            if !parts.isEmpty { out.append(parts.joined(separator: ", ") + " in the capital") }
        }
        add(b.cityProduction) { "\(signed($0)) Production in every city" }
        for s in b.strength ?? [] {
            out.append("\(signed(s.amount)) Strength for " + s.classes.map { "\($0)" }.joined(separator: ", ") + " units")
        }
        add(b.quarterStability) { "\(signed($0)) Stability per quarter" }
        add(b.wallsHousing) { "\(signed($0)) Housing with Walls" }
        add(b.capitalLoyalty) { "\(signed($0)) Loyalty in the capital" }
        add(b.capitalLoyaltyReach) { "Capital Loyalty reaches \($0) more tiles" }
        add(b.tradeRoutes) { "\(signed($0)) trade route capacity" }
        add(b.buyPct) { "Purchases cost \($0)% less" }
        for cut in b.costCuts ?? [] {
            var what: [String] = []
            what += (cut.units ?? []).map { ItemName.of(.unit($0), rules: rules) }
            what += (cut.classes ?? []).map { "\($0)" }
            what += (cut.buildings ?? []).map { ItemName.of(.building(BuildingID($0)), rules: rules) }
            if cut.centre == true { what.append("city-centre buildings") }
            let era = cut.maxEra.map { " (to the \($0) era)" } ?? ""
            out.append("−\(cut.pct)% Production on " + (what.isEmpty ? "items" : what.joined(separator: ", ")) + era)
        }
        add(b.reconMoves) { "\(signed($0)) Movement for recon units" }
        add(b.reconSight) { "\(signed($0)) Sight for recon units" }
        add(b.unitUpkeepCut) { "Unit upkeep \($0) Gold less" }
        add(b.pillageBonusPct) { "Pillaging yields \($0)% more" }
        add(b.enemyTerritoryStrength) { "\(signed($0)) Strength in enemy territory" }
        add(b.cityStrength) { "\(signed($0)) city Strength" }
        add(b.bombard) { "\(signed($0)) city bombard Strength" }
        add(b.garrisonStability) { "\(signed($0)) Stability with a garrison" }
        add(b.garrisonLoyalty) { "\(signed($0)) Loyalty with a garrison" }
        add(b.conqueredLoyalty) { "\(signed($0)) Loyalty per turn in conquered cities" }
        add(b.upgradePct) { "Upgrades cost \($0)% less" }
        add(b.builderCharges) { "\(signed($0)) Builder charges" }
        add(b.newBuilderCharges) { "\(signed($0)) charges for new Builders" }
        add(b.tileBuyPct) { "Tiles cost \($0)% less" }
        add(b.quartersHousing) { "\(signed($0)) Housing in cities with 2 quarters" }
        if let kinds = b.adjacencyDouble, !kinds.isEmpty { out.append("Double adjacency: " + kinds.joined(separator: ", ")) }
        add(b.quarterCulture) { "\(signed($0)) Culture per quarter" }
        add(b.raiderStrength) { "\(signed($0)) Strength against tribal raiders" }
        add(b.tradeRouteGold) { "\(signed($0)) Gold per trade route" }
        add(b.intlTradeScience) { "\(signed($0)) Science per foreign trade route" }
        add(b.intlTradeCulture) { "\(signed($0)) Culture per foreign trade route" }
        add(b.envoyGold) { "\(signed($0)) Gold per envoy" }
        add(b.friendshipCostPct) { "Friendship costs \($0)% less" }
        return out
    }
}
