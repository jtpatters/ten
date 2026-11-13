import SwiftUI

/// The unit card's action bar (M1 §16), its tiles in the card's order: they share its width
/// when they all fit; a row a little too wide closes its gaps, then squeezes its wider tiles
/// (`FillRow`); else it scrolls, and an edge with more tiles beyond it fades out under a
/// chevron that scrolls there, so the row shows that it scrolls. One scroll view always on
/// screen (no `ViewThatFits`): SwiftUI may lay out a choice it is not showing on its render
/// thread, where the tiles' main-actor builder must not run.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var width: CGFloat = 0
    @State private var more = ScrollEdges()
    @State private var position = ScrollPosition(edge: .leading)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            FillRow(width: width, spacing: HUD.Space.xs + 2, minSpacing: 3) {
                content
            }
            .padding(.vertical, 1)
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .onScrollGeometryChange(for: ScrollEdges.self) { @Sendable geometry in
            let x = geometry.contentOffset.x + geometry.contentInsets.leading
            return ScrollEdges(leading: x > 1, trailing: x + geometry.containerSize.width < geometry.contentSize.width - 1)
        } action: { _, edges in
            more = edges
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: more.leading ? Self.fade : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: more.trailing ? Self.fade : 0)
            }
        }
        .overlay(alignment: .leading) {
            if more.leading { chevron(.leading) }
        }
        .overlay(alignment: .trailing) {
            if more.trailing { chevron(.trailing) }
        }
        .animation(.easeOut(duration: 0.15), value: more)
    }

    static var fade: CGFloat { 36 }

    /// Over a faded edge: more tiles lie beyond it, and a tap scrolls to them. VoiceOver moves
    /// through the tiles themselves (the row scrolls to each), so it skips this.
    private func chevron(_ edge: HorizontalEdge) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: edge == .leading ? .leading : .trailing) }
        } label: {
            Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(HUD.ink)
                .frame(width: 22, height: 22)
                .background(Circle().fill(HUD.parchmentTop))
                .overlay(Circle().stroke(HUD.ink.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .frame(maxWidth: Self.fade, maxHeight: .infinity, alignment: edge == .leading ? .leading : .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}

/// Which ends of a scrolling row have more beyond them.
private struct ScrollEdges: Equatable, Sendable {
    var leading = false
    var trailing = false
}

/// Tiles side by side, at least `width` wide: room to spare goes to the tiles, equal widths
/// when every tile fits in an equal share. A row a little too wide closes its gaps (down to
/// `minSpacing`), then squeezes the tiles wider than their narrowest, all by one share of their
/// own widths (not under `ActionTile.minFit`: their titles shrink a little), before it scrolls;
/// a row that scrolls keeps each tile's own width.
private struct FillRow: Layout {
    var width: CGFloat
    var spacing: CGFloat
    var minSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let row = plan(subviews, room: width)
        let length = row.widths.reduce(0, +) + row.gap * CGFloat(max(row.widths.count - 1, 0))
        let height = zip(subviews, row.widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: max(length, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let row = plan(subviews, room: bounds.width)
        var x = bounds.minX
        for (subview, w) in zip(subviews, row.widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + row.gap
        }
    }

    /// Each tile's width, and the gap between tiles, in a row `room` wide.
    private func plan(_ subviews: Subviews, room: CGFloat) -> (widths: [CGFloat], gap: CGFloat) {
        let natural = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard natural.count > 1 else { return (natural.map { max($0, room) }, spacing) }
        let count = CGFloat(natural.count), gaps = count - 1
        let sum = natural.reduce(0, +)
        // Each tile at its own width at least, the gaps closing (down to `minSpacing`) to fit.
        let gap = min(spacing, (room - sum) / gaps)
        if gap >= minSpacing {
            let share = (room - gap * gaps) / count
            if natural.allSatisfy({ $0 <= share }) { return (Array(repeating: share, count: natural.count), gap) }
            let extra = max(0, room - sum - gap * gaps) / count
            return (natural.map { $0 + extra }, gap)
        }
        // Squeezed, the gaps at `minSpacing`; else it scrolls.
        let floors = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width }
        guard let fit = Self.fit(natural, floors: floors, into: room - minSpacing * gaps) else { return (natural, spacing) }
        return (zip(natural, floors).map { max($1, $0 * fit) }, minSpacing)
    }

    /// The one share of their own widths the tiles take so they come to `target` together,
    /// none below its floor (the narrowest it can be); nil when that share would be under
    /// `ActionTile.minFit`.
    private static func fit(_ natural: [CGFloat], floors: [CGFloat], into target: CGFloat) -> CGFloat? {
        var atFloor = natural.indices.map { natural[$0] <= floors[$0] }
        while true {
            var floorSum: CGFloat = 0, free: CGFloat = 0
            for i in natural.indices {
                if atFloor[i] { floorSum += floors[i] } else { free += natural[i] }
            }
            guard free > 0 else { return nil }
            let fit = (target - floorSum) / free
            // Tiles held at their floors only leave the others less.
            guard fit >= ActionTile.minFit else { return nil }
            let held = natural.indices.filter { !atFloor[$0] && natural[$0] * fit < floors[$0] }
            if held.isEmpty { return min(fit, 1) }
            for i in held { atFloor[i] = true }
        }
    }
}
