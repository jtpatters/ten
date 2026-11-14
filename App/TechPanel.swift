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
        let tree = TechTree(options: options).with(eras: view.rules.eras.map(\.name))
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

    private func choose(_ option: ResearchOption) {
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
        var option: ResearchOption
        var depth: Int
        var row: Double
        /// Prerequisites present in the tree.
        var parents: [TechID]
        /// Its place in the research path (1 = being researched), if on it.
        var step: Int?
    }

    var nodes: [Node]
    var rows: Int
    var depth: Int

    init(options: [ResearchOption]) {
        let byID = Dictionary(uniqueKeysWithValues: options.map { ($0.tech, $0) })
        var depthOf: [TechID: Int] = [:]
        func depth(_ id: TechID) -> Int {
            if let d = depthOf[id] { return d }
            let d = (byID[id]?.requires.compactMap { byID[$0] == nil ? nil : depth($0) + 1 }.max()) ?? 0
            depthOf[id] = d
            return d
        }
        // Children hang under their first prerequisite; leaves take consecutive rows and a parent
        // sits level with the middle of its children.
        var children: [TechID: [TechID]] = [:]
        var roots: [TechID] = []
        for option in options {
            if let parent = option.requires.first(where: { byID[$0] != nil }) {
                children[parent, default: []].append(option.tech)
            } else {
                roots.append(option.tech)
            }
        }
        var rowOf: [TechID: Double] = [:]
        var next = 0.0
        func place(_ id: TechID) {
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
        var steps: [TechID: Int] = [:]
        if let target = options.first(where: \.isTarget) ?? options.first(where: \.researching) {
            var needed: Set<TechID> = [target.tech]
            var frontier = [target.tech]
            while let id = frontier.popLast() {
                for req in byID[id]?.requires ?? [] where byID[req]?.known == false && !needed.contains(req) {
                    needed.insert(req)
                    frontier.append(req)
                }
            }
            var n = 1
            for option in options where needed.contains(option.tech) && !option.known {
                steps[option.tech] = n
                n += 1
            }
        }
        nodes = options.map { option in
            Node(option: option, depth: depth(option.tech), row: rowOf[option.tech] ?? 0,
                 parents: option.requires.filter { byID[$0] != nil }, step: steps[option.tech])
        }
        rows = Int(next)
        self.depth = (nodes.map(\.depth).max() ?? 0) + 1
    }

    func node(_ id: TechID) -> Node? { nodes.first { $0.option.tech == id } }

    /// Depth-first order (an outline): each tech followed by the techs under it.
    var outline: [Node] {
        var out: [Node] = []
        var seen: Set<TechID> = []
        func visit(_ node: Node) {
            guard seen.insert(node.option.tech).inserted else { return }
            out.append(node)
            for child in nodes where child.parents.first == node.option.tech { visit(child) }
        }
        for root in nodes where root.parents.isEmpty { visit(root) }
        for node in nodes where !seen.contains(node.option.tech) { out.append(node) }
        return out
    }
}

/// The tree in columns by depth, linked from each prerequisite to what it leads to.
private struct TechTreeLayout: View {
    var tree: TechTree
    var width: CGFloat
    var progress: Double
    var onChoose: (ResearchOption) -> Void

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
                        context.stroke(path, with: .color(lit ? HUD.Yield.science.opacity(0.7) : HUD.ink.opacity(0.28)),
                                       style: StrokeStyle(lineWidth: lit ? 2 : 1.5, lineCap: .round))
                    }
                }
            }
            .frame(width: width, height: height)
            ForEach(tree.nodes, id: \.option.tech) { node in
                let f = frame(node)
                TechNodeView(node: node, progress: progress, era: tree.eraName(node), onChoose: onChoose)
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// The tree as an indented outline (narrow screens).
private struct TechOutline: View {
    var tree: TechTree
    var progress: Double
    var onChoose: (ResearchOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            ForEach(tree.outline, id: \.option.tech) { node in
                HStack(spacing: 0) {
                    if node.depth > 0 {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(node.step != nil ? HUD.Yield.science : HUD.inkFaint)
                            .frame(width: 22)
                            .padding(.leading, CGFloat(node.depth - 1) * 22)
                    }
                    TechNodeView(node: node, progress: progress, era: tree.eraName(node), onChoose: onChoose)
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
    var onChoose: (ResearchOption) -> Void

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
                    if let step = node.step, !option.researching {
                        Text("\(step)")
                            .font(HUD.numeric(.caption2))
                            .foregroundStyle(HUD.parchmentTop)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(HUD.Yield.science))
                            .accessibilityLabel("Step \(step) of the research path")
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
                        .foregroundStyle(option.insightGained ? HUD.Yield.science : HUD.inkSoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if option.researching {
                    ProgressBar(fraction: progress, tint: HUD.Yield.science, height: 4)
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
                    .stroke(stroke, style: StrokeStyle(lineWidth: option.researching ? 2 : 1, dash: node.step != nil && !option.researching ? [4, 3] : []))
            }
            .contentShape(RoundedRectangle(cornerRadius: HUD.Radius.small))
            .opacity(option.known ? 0.8 : 1)
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(option.known ? "" : "Research it.")
    }

    private var icon: String {
        let option = node.option
        if option.known { return "checkmark.seal.fill" }
        if option.researching { return "flask.fill" }
        if option.available { return "flask" }
        return "lock.fill"
    }

    private var iconTint: Color {
        let option = node.option
        if option.known { return HUD.good }
        if option.researching || node.step != nil { return HUD.Yield.science }
        return option.available ? HUD.inkSoft : HUD.inkFaint
    }

    private var fill: Color {
        let option = node.option
        if option.researching { return HUD.Yield.science.opacity(0.14) }
        if option.known { return HUD.good.opacity(0.12) }
        return HUD.parchmentWell
    }

    private var stroke: Color {
        let option = node.option
        if option.researching { return HUD.Yield.science }
        if node.step != nil { return HUD.Yield.science.opacity(0.8) }
        return HUD.ink.opacity(option.available ? 0.3 : 0.15)
    }

    private var costLine: String {
        let option = node.option
        let era = self.era.map { "\($0) · " } ?? ""
        if option.known { return "\(era)Known" }
        let turns = option.turns.map { " · \(turnsText($0))" } ?? ""
        let credit = option.credit > 0 ? " (\(option.credit) credited)" : ""
        return "\(era)\(option.cost) science\(credit)\(turns)"
    }

    private var accessibilityText: String {
        let option = node.option
        var parts = [option.name]
        if option.known { parts.append("known") } else if option.researching { parts.append("being researched") }
        if !option.known { parts.append(costLine) }
        if !option.unlocks.isEmpty { parts.append("unlocks " + option.unlocks.joined(separator: ", ")) }
        if let insight = option.insight, !option.known {
            parts.append((option.insightGained ? "Insight gained: " : "Insight: ") + insight)
        }
        return parts.joined(separator: ", ")
    }
}
