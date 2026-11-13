import GameCore
import MapRendering
import UIKit

// City banners (M1 §16): what each banner says, built from the viewer's knowledge, and its art,
// drawn once per change with Core Graphics in the HUD's style (`MapOverlay` hangs the images
// over the map). A banner is a parchment ribbon with the owner's seal (colour and emblem) at its
// left end, the population, the name and a capital's star; own cities add a second row with the
// turns to grow and what receives the production with its turns (and, behind a pause glyph, the
// first item of the queue when it waits, a Settler for population); a damaged city shows its
// health under it.
// Zoomed out to strategic tokens it is a compact tag: the population in an ink badge and the
// name, on parchment edged in the owner's colour. Over a focus tile (the selected unit, a route)
// it collapses to that tag, its pill, with a damaged city's health under it.

/// A city's banner as the viewer knows the city.
struct CityBannerModel: Equatable, Sendable {
    enum Growth: Equatable, Sendable {
        /// Grows in this many turns.
        case turns(Int)
        case stagnant
        case starving
    }

    enum Production: Equatable, Sendable {
        /// What receives the production, with its turns; `waiting`: the first item of the queue
        /// when it waits (a Settler for population) while this one is built.
        case item(name: String, turns: Int?, waiting: String?)
        /// Every item in the queue waits; the first one.
        case waiting(name: String)
        /// Nothing queued: an attention item (M1 §5).
        case empty
    }

    var id: CityID
    var hex: HexCoord
    var name: String
    var owner: PlayerID
    var own: Bool
    var population: Int
    var capital: Bool
    /// Hit points as a fraction of full while damaged; nil at full health.
    var health: Double?
    /// Own cities only.
    var growth: Growth?
    /// Own cities only.
    var production: Production?
    var selected = false
    /// A foreign city out of sight, as last seen.
    var remembered = false

    /// Overlap priority, most important first: the selection, own cities, capitals, the
    /// largest (M1 §16: overlapping foreign banners hide first).
    static func ranked(_ a: CityBannerModel, before b: CityBannerModel) -> Bool {
        (a.selected ? 0 : 1, a.own ? 0 : 1, a.capital ? 0 : 1, -a.population, a.id.rawValue)
            < (b.selected ? 0 : 1, b.own ? 0 : 1, b.capital ? 0 : 1, -b.population, b.id.rawValue)
    }

    /// What VoiceOver reads.
    var accessibilityLabel: String {
        var parts = [name, "population \(population)"]
        if capital { parts.append("capital") }
        if let health { parts.append("health \(Int((health * 100).rounded())) percent") }
        switch growth {
        case let .turns(n)?: parts.append("grows in \(n) \(n == 1 ? "turn" : "turns")")
        case .stagnant?: parts.append("not growing")
        case .starving?: parts.append("starving")
        case nil: break
        }
        switch production {
        case let .item(item, turns, waiting)?:
            parts.append("producing \(item)" + (turns.map { ", \($0) \($0 == 1 ? "turn" : "turns")" } ?? ""))
            if let waiting { parts.append("\(waiting) waits") }
        case let .waiting(item)?: parts.append("\(item) waits")
        case .empty?: parts.append("nothing in production")
        case nil: break
        }
        return parts.joined(separator: ", ")
    }
}

extension CityBannerModel {
    /// Every banner the viewer should see: own cities live, foreign ones as last seen (M1 §11);
    /// in diagnostic mode every live city.
    @MainActor
    static func all(state: GameState, viewer: PlayerID, diagnostic: Bool, selected: CityID?) -> [CityBannerModel] {
        let view = state.view(for: viewer)
        let rules = state.rules
        let maxHP = max(1, rules.constants.city.maxHP)
        func health(_ hp: Int) -> Double? { hp < maxHP ? Double(max(hp, 0)) / Double(maxHP) : nil }

        func own(_ city: City) -> CityBannerModel {
            var model = CityBannerModel(id: city.id, hex: city.position, name: city.name, owner: city.owner, own: true,
                                        population: city.population, capital: city.has(rules.palace.id), health: health(city.hp))
            if let yields = view.cityYields(city.id) {
                if yields.foodSurplus < 0 {
                    model.growth = .starving
                } else if let turns = view.turnsToGrow(city.id) {
                    model.growth = .turns(turns)
                } else {
                    model.growth = .stagnant
                }
            }
            // What really receives the production (M1 §5): a Settler first in the queue that
            // waits for population takes it while it fills, else the next entry that can complete.
            let status = view.queueStatus(of: city.id)
            let head = status.first.flatMap { $0.wait == nil ? nil : ItemName.of($0.item, rules: rules) }
            if let receiver = status.firstIndex(where: \.receivesProduction) {
                let building = status[receiver]
                model.production = .item(name: ItemName.of(building.item, rules: rules), turns: building.turns,
                                         waiting: receiver == 0 ? nil : head)
            } else if let head {
                model.production = .waiting(name: head)
            } else {
                model.production = .empty
            }
            model.selected = selected == city.id
            return model
        }

        if diagnostic {
            return state.cities.map { city in
                if city.owner == viewer { return own(city) }
                var model = CityBannerModel(id: city.id, hex: city.position, name: city.name, owner: city.owner, own: false,
                                            population: city.population, capital: city.has(rules.palace.id), health: health(city.hp))
                model.selected = selected == city.id
                return model
            }
        }
        return view.knownCities.map { sighting in
            if sighting.owner == viewer, let city = view.city(sighting.id) { return own(city) }
            var model = CityBannerModel(id: sighting.id, hex: sighting.position, name: sighting.name, owner: sighting.owner,
                                        own: false, population: sighting.population, capital: sighting.capital,
                                        health: health(sighting.hp))
            model.selected = selected == sighting.id
            model.remembered = !view.isVisible(sighting.position)
            return model
        }
    }
}

// MARK: - Art

/// Banner images, drawn with Core Graphics in the HUD's palette and serif.
@MainActor
enum BannerArt {
    /// A drawn banner: the image (points `size`), the rectangle its art covers inside it (for
    /// overlaps and taps), and the point that hangs at the city's banner anchor. With secondary
    /// rows (growth and production, HP), `image` is the banner without them and `details` holds
    /// them, the same size, so the overlay can fade them alone while the name stays readable.
    struct Rendered {
        var image: CGImage
        var details: CGImage?
        var size: CGSize
        var content: CGRect
        /// The name row (with the seal): never faded.
        var head: CGRect
        /// Where `details` draws (`.null` without).
        var detailsRect: CGRect
        var anchor: CGPoint
    }

    /// The banner close up, the strategic zoom's tag, or the tag a banner collapses to over a
    /// focus tile (with a damaged city's health).
    enum Style: Hashable {
        case standard, strategic, pill
    }

    /// Room around the art for its shadow, which falls to the lower right (ART.md §1).
    private static let pad = UIEdgeInsets(top: 2, left: 2, bottom: 6, right: 5)

    private struct Metrics {
        var seal: CGFloat
        var row: CGFloat
        var detailRow: CGFloat
        var name: UIFont
        var population: UIFont
        var detail: UIFont
        var detailNumber: UIFont
        var star: CGFloat
        var radius: CGFloat
        var maxName: CGFloat

        static let standard = Metrics(seal: 27, row: 22, detailRow: 17, name: HUD.UI.serif(13.5, weight: .bold),
                                      population: HUD.UI.numeric(12, weight: .bold), detail: HUD.UI.serif(11, weight: .semibold),
                                      detailNumber: HUD.UI.numeric(11, weight: .bold), star: 10, radius: 7, maxName: 150)
    }

    static func render(_ model: CityBannerModel, style: Style, scale: CGFloat) -> Rendered? {
        if style != .standard { return compact(model, scale: scale, withHealth: style == .pill) }
        let m = Metrics.standard
        let ink = HUD.UI.ink

        // Row 1: population badge, name, star.
        let population = "\(model.population)" as NSString
        let populationSize = population.size(withAttributes: [.font: m.population])
        let badge = CGSize(width: max(m.row - 6, ceil(populationSize.width) + 8), height: m.row - 6)
        let name = fitted(model.name, font: m.name, width: m.maxName)
        let nameSize = (name as NSString).size(withAttributes: [.font: m.name])
        let starWidth: CGFloat = model.capital ? m.star + 4 : 0
        let row1Width = badge.width + 5 + ceil(nameSize.width) + starWidth

        // Row 2 (own cities, close up): growth and production.
        var details: [(image: String, tint: UIColor, text: String, number: String?, gap: CGFloat)] = []
        do {
            switch model.growth {
            case let .turns(n)?: details.append(("leaf.fill", HUD.UI.food, "", "\(n)", 9))
            case .stagnant?: details.append(("leaf.fill", HUD.UI.ink.withAlphaComponent(0.45), "", "–", 9))
            case .starving?: details.append(("leaf.fill", HUD.UI.danger, "", "−", 9))
            case nil: break
            }
            switch model.production {
            case let .item(item, turns, waiting)?:
                details.append(("hammer.fill", HUD.UI.production, item, turns.map { "\($0)" }, 9))
                if let waiting { details.append(("pause.circle.fill", HUD.UI.amber, waiting, nil, 6)) }
            case let .waiting(item)?: details.append(("pause.circle.fill", HUD.UI.amber, "\(item) waits", nil, 9))
            case .empty?: details.append(("hammer.fill", HUD.UI.danger, "Choose production", nil, 9))
            case nil: break
            }
        }
        let iconSize: CGFloat = 11
        var row2Width: CGFloat = 0
        var detailWidths: [CGFloat] = []
        for d in details {
            var w = iconSize + 3
            if !d.text.isEmpty { w += ceil((d.text as NSString).size(withAttributes: [.font: m.detail]).width) }
            if let number = d.number {
                w += (d.text.isEmpty ? 0 : 4) + ceil((number as NSString).size(withAttributes: [.font: m.detailNumber]).width)
            }
            detailWidths.append(w)
            row2Width += w
        }
        row2Width += details.dropFirst().reduce(0) { $0 + $1.gap }

        let hasDetails = !details.isEmpty
        let showsHealth = model.health != nil
        let bodyHeight = m.row + (hasDetails ? m.detailRow : 0)
        let textLeft = m.seal / 2 + 4
        let bodyWidth = textLeft + max(row1Width, row2Width) + 9
        let sealProtrusion = max(0, (m.seal - m.row) / 2)
        let healthHeight: CGFloat = showsHealth ? 7 : 0

        let contentWidth = m.seal / 2 + bodyWidth
        let contentHeight = sealProtrusion + bodyHeight + healthHeight
        let size = CGSize(width: ceil(pad.left + contentWidth + pad.right), height: ceil(pad.top + contentHeight + pad.bottom))
        let origin = CGPoint(x: pad.left, y: pad.top)
        let sealCentre = CGPoint(x: origin.x + m.seal / 2, y: origin.y + sealProtrusion + m.row / 2)
        let body = CGRect(x: sealCentre.x, y: origin.y + sealProtrusion, width: bodyWidth, height: bodyHeight)
        let content = CGRect(x: origin.x, y: origin.y, width: contentWidth, height: contentHeight)
        let healthBar = CGRect(x: body.minX + 8, y: body.maxY + 2.5, width: body.width - 14, height: 4.5)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        func draw(_ cg: CGContext) {
            let shape = UIBezierPath(roundedRect: body, cornerRadius: m.radius)
            // A foreign city out of sight is shown as last seen: a little faded.
            if model.remembered {
                cg.setAlpha(0.8)
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            defer { if model.remembered { cg.endTransparencyLayer() } }

            // Shadow, then the parchment body.
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 1.5, height: 2), blur: 3, color: UIColor.black.withAlphaComponent(0.32).cgColor)
            HUD.UI.parchmentBottom.setFill()
            shape.fill()
            cg.restoreGState()
            cg.saveGState()
            shape.addClip()
            let colors = [HUD.UI.parchmentTop.cgColor, HUD.UI.parchmentBottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
            }
            if hasDetails {
                // The details row sits in a faint well.
                // (CGContext.fill blends; UIRectFill would copy the translucent colour through.)
                cg.setFillColor(HUD.UI.parchmentWell.withAlphaComponent(0.45).cgColor)
                cg.fill(CGRect(x: body.minX, y: body.minY + m.row, width: body.width, height: m.detailRow))
            }
            // The owner's colour along the foot of the ribbon (ownership, with the seal's emblem).
            cg.setFillColor(Heraldry.color(model.owner))
            cg.fill(CGRect(x: body.minX, y: body.maxY - 2.5, width: body.width, height: 2.5))
            cg.restoreGState()
            // Inner light rim and the ink outline (gilt when selected).
            UIColor.white.withAlphaComponent(0.45).setStroke()
            let rim = UIBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerRadius: max(1, m.radius - 1.5))
            rim.lineWidth = 0.8
            rim.stroke()
            if model.selected {
                HUD.UI.gilt.setStroke()
                shape.lineWidth = 2.2
            } else {
                ink.withAlphaComponent(0.75).setStroke()
                shape.lineWidth = 1.2
            }
            shape.stroke()

            // The seal: the owner's colour and emblem, an ink ring.
            let sealRect = CGRect(x: sealCentre.x - m.seal / 2, y: sealCentre.y - m.seal / 2, width: m.seal, height: m.seal)
            let seal = UIBezierPath(ovalIn: sealRect)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 1, height: 1.5), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            UIColor(cgColor: Heraldry.color(model.owner)).setFill()
            seal.fill()
            cg.restoreGState()
            if let emblem = emblem(model.owner, size: m.seal * 0.68) {
                let e = m.seal * 0.68
                UIImage(cgImage: emblem, scale: Heraldry.pixelsPerPoint, orientation: .up)
                    .draw(in: CGRect(x: sealCentre.x - e / 2, y: sealCentre.y - e / 2, width: e, height: e))
            }
            (model.selected ? HUD.UI.gilt : ink.withAlphaComponent(0.8)).setStroke()
            seal.lineWidth = model.selected ? 2 : 1.3
            seal.stroke()

            // Row 1: the population in an ink badge, the name, a capital's star.
            var x = body.minX + textLeft
            let badgeRect = CGRect(x: x, y: body.minY + (m.row - badge.height) / 2, width: badge.width, height: badge.height)
            ink.withAlphaComponent(0.86).setFill()
            UIBezierPath(roundedRect: badgeRect, cornerRadius: badge.height / 2).fill()
            population.draw(at: CGPoint(x: badgeRect.midX - populationSize.width / 2, y: badgeRect.midY - populationSize.height / 2),
                            withAttributes: [.font: m.population, .foregroundColor: HUD.UI.cream])
            x = badgeRect.maxX + 5
            (name as NSString).draw(at: CGPoint(x: x, y: body.minY + (m.row - nameSize.height) / 2),
                                    withAttributes: [.font: m.name, .foregroundColor: ink])
            x += ceil(nameSize.width) + 3
            if model.capital, let star = symbol("star.fill", size: m.star, tint: HUD.UI.gilt) {
                star.draw(in: CGRect(x: x, y: body.minY + (m.row - m.star) / 2 - 0.5, width: m.star, height: m.star))
            }

            // Row 2: growth and production.
            if hasDetails {
                var dx = body.minX + textLeft
                let midY = body.minY + m.row + (m.detailRow - 2.5) / 2
                for (i, d) in details.enumerated() {
                    if let icon = symbol(d.image, size: iconSize, tint: d.tint) {
                        icon.draw(in: CGRect(x: dx, y: midY - iconSize / 2, width: iconSize, height: iconSize))
                    }
                    var tx = dx + iconSize + 3
                    let color = d.tint == HUD.UI.danger ? HUD.UI.danger : ink
                    if !d.text.isEmpty {
                        let s = (d.text as NSString).size(withAttributes: [.font: m.detail])
                        (d.text as NSString).draw(at: CGPoint(x: tx, y: midY - s.height / 2), withAttributes: [.font: m.detail, .foregroundColor: color])
                        tx += ceil(s.width) + 4
                    }
                    if let number = d.number {
                        let s = (number as NSString).size(withAttributes: [.font: m.detailNumber])
                        (number as NSString).draw(at: CGPoint(x: tx, y: midY - s.height / 2),
                                                  withAttributes: [.font: m.detailNumber, .foregroundColor: ink.withAlphaComponent(0.8)])
                    }
                    dx += detailWidths[i] + (i + 1 < details.count ? details[i + 1].gap : 0)
                }
            }

            // Health under the ribbon: an ink edge, a dark well, the fill (ART.md §13).
            if showsHealth, let health = model.health {
                drawHealth(health, in: healthBar)
            }
        }
        // The secondary rows apart from the name row, the seal (with its shadow) and the health
        // bar, which never fades: split on pixel edges so the images join without a seam.
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let split = px(body.minY + m.row)
        let sealRight = px(origin.x + m.seal + 4), sealBottom = px(max(split, sealCentre.y + m.seal / 2 + 4))
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let anchor = CGPoint(x: content.midX, y: content.maxY)
        let head = CGRect(x: content.minX, y: content.minY, width: content.width, height: split - content.minY)
        guard hasDetails else {
            guard let image = renderer.image(actions: { draw($0.cgContext) }).cgImage else { return nil }
            return Rendered(image: image, details: nil, size: size, content: content, head: content, detailsRect: .null, anchor: anchor)
        }
        let bar = showsHealth ? CGRect(x: px(healthBar.minX - 1), y: px(healthBar.minY - 1), width: px(healthBar.width + 2),
                                       height: px(healthBar.height + 2)) : nil
        let headClip = [CGRect(x: 0, y: 0, width: size.width, height: split), CGRect(x: 0, y: 0, width: sealRight, height: sealBottom)]
            + (bar.map { [$0] } ?? [])
        let tailClip = [CGRect(x: 0, y: sealBottom, width: size.width, height: size.height - sealBottom),
                        CGRect(x: sealRight, y: split, width: size.width - sealRight, height: sealBottom - split)]
        let named = renderer.image { context in
            context.cgContext.clip(to: headClip)
            draw(context.cgContext)
        }
        let rows = renderer.image { context in
            let cg = context.cgContext
            if let bar {
                // Everything but the health bar.
                cg.addRect(CGRect(origin: .zero, size: size))
                cg.addRect(bar)
                cg.clip(using: .evenOdd)
            }
            cg.clip(to: tailClip)
            draw(cg)
        }
        guard let image = named.cgImage, let details = rows.cgImage else { return nil }
        let detailsRect = CGRect(x: content.minX, y: split, width: content.width, height: body.maxY - split)
        return Rendered(image: image, details: details, size: size, content: content, head: head, detailsRect: detailsRect, anchor: anchor)
    }

    /// A city's health: an ink edge, a dark well, the fill (ART.md §13).
    private static func drawHealth(_ health: Double, in bar: CGRect) {
        let ink = HUD.UI.ink
        let well = UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2)
        ink.withAlphaComponent(0.6).setFill()
        well.fill()
        let fill = CGRect(x: bar.minX + 1, y: bar.minY + 1, width: max(bar.height - 2, (bar.width - 2) * health), height: bar.height - 2)
        HUD.UI.health(health).setFill()
        UIBezierPath(roundedRect: fill, cornerRadius: fill.height / 2).fill()
        ink.withAlphaComponent(0.85).setStroke()
        well.lineWidth = 0.9
        well.stroke()
    }

    /// The strategic zoom's tag (M1 §16): the population in an ink badge and the name on a small
    /// parchment ribbon, its left end and foot in the owner's colour; no seal, star or rows, so
    /// cities close together on screen keep their names. `withHealth`: the pill a banner
    /// collapses to over a focus tile, a damaged city's health under it.
    private static func compact(_ model: CityBannerModel, scale: CGFloat, withHealth: Bool = false) -> Rendered? {
        let ink = HUD.UI.ink
        let nameFont = HUD.UI.serif(11, weight: .bold), populationFont = HUD.UI.numeric(9.5, weight: .bold)
        let height: CGFloat = 17, stripe: CGFloat = 4, radius: CGFloat = 5
        let population = "\(model.population)" as NSString
        let populationSize = population.size(withAttributes: [.font: populationFont])
        let badge = CGSize(width: max(12, ceil(populationSize.width) + 6), height: 12)
        let name = fitted(model.name, font: nameFont, width: 110)
        let nameSize = (name as NSString).size(withAttributes: [.font: nameFont])
        let width = stripe + 3 + badge.width + 4 + ceil(nameSize.width) + 6
        let health = withHealth ? model.health : nil
        let healthHeight: CGFloat = health == nil ? 0 : 6
        let size = CGSize(width: ceil(pad.left + width + pad.right), height: ceil(pad.top + height + healthHeight + pad.bottom))
        let body = CGRect(x: pad.left, y: pad.top, width: width, height: height)
        let content = CGRect(x: body.minX, y: body.minY, width: body.width, height: height + healthHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            if model.remembered {
                cg.setAlpha(0.8)
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            let shape = UIBezierPath(roundedRect: body, cornerRadius: radius)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 1, height: 1.5), blur: 2.5, color: UIColor.black.withAlphaComponent(0.32).cgColor)
            HUD.UI.parchmentBottom.setFill()
            shape.fill()
            cg.restoreGState()
            cg.saveGState()
            shape.addClip()
            let colors = [HUD.UI.parchmentTop.cgColor, HUD.UI.parchmentBottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
            }
            cg.setFillColor(Heraldry.color(model.owner))
            cg.fill(CGRect(x: body.minX, y: body.minY, width: stripe, height: body.height))
            cg.fill(CGRect(x: body.minX, y: body.maxY - 2, width: body.width, height: 2))
            cg.restoreGState()
            if model.selected {
                HUD.UI.gilt.setStroke()
                shape.lineWidth = 2
            } else {
                ink.withAlphaComponent(0.75).setStroke()
                shape.lineWidth = 1.1
            }
            shape.stroke()
            let badgeRect = CGRect(x: body.minX + stripe + 3, y: body.minY + (height - 2 - badge.height) / 2,
                                   width: badge.width, height: badge.height)
            ink.withAlphaComponent(0.86).setFill()
            UIBezierPath(roundedRect: badgeRect, cornerRadius: badge.height / 2).fill()
            population.draw(at: CGPoint(x: badgeRect.midX - populationSize.width / 2, y: badgeRect.midY - populationSize.height / 2),
                            withAttributes: [.font: populationFont, .foregroundColor: HUD.UI.cream])
            (name as NSString).draw(at: CGPoint(x: badgeRect.maxX + 4, y: body.minY + (height - 2 - nameSize.height) / 2),
                                    withAttributes: [.font: nameFont, .foregroundColor: ink])
            if let health {
                drawHealth(health, in: CGRect(x: body.minX + 5, y: body.maxY + 1.5, width: body.width - 9, height: 4))
            }
            if model.remembered { cg.endTransparencyLayer() }
        }
        guard let cgImage = image.cgImage else { return nil }
        return Rendered(image: cgImage, details: nil, size: size, content: content, head: content, detailsRect: .null,
                        anchor: CGPoint(x: content.midX, y: content.maxY))
    }

    /// `text`, cut with an ellipsis to fit `width`.
    private static func fitted(_ text: String, font: UIFont, width: CGFloat) -> String {
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        guard w(text) > width else { return text }
        var cut = text
        while !cut.isEmpty, w(cut + "…") > width { cut.removeLast() }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static var emblems: [Int: CGImage] = [:]

    private static func emblem(_ player: PlayerID, size: CGFloat) -> CGImage? {
        let key = player.rawValue * 1000 + Int(size * 10)
        if let cached = emblems[key] { return cached }
        let image = Heraldry.emblemImage(player, size: size)
        emblems[key] = image
        return image
    }

    private struct SymbolKey: Hashable {
        var name: String
        var size: CGFloat
        var tint: UIColor
    }

    private static var symbols: [SymbolKey: UIImage] = [:]

    private static func symbol(_ name: String, size: CGFloat, tint: UIColor) -> UIImage? {
        let key = SymbolKey(name: name, size: size, tint: tint)
        if let cached = symbols[key] { return cached }
        let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .bold))?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
        symbols[key] = image
        return image
    }
}

extension Heraldry {
    /// `emblemImage` draws three pixels per point.
    static let pixelsPerPoint: CGFloat = 3
}
