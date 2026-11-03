import AppKit
import CoreText
import MantisCore

/// Visual effects drawn on their own layer, so animating them never forces the
/// terminal text to re-render. Background effects sit *behind* the text; overlay
/// effects (CRT) sit *above* it. These are CoreGraphics renderers, not GPU
/// post-processing shaders.
enum EffectKind: String, CaseIterable, Identifiable {
    case none, matrix, crt, starfield, snow, fireflies, aurora, synthwave
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .matrix: return "Matrix Rain"
        case .crt: return "Retro CRT"
        case .starfield: return "Starfield Warp"
        case .snow: return "Snowfall"
        case .fireflies: return "Fireflies"
        case .aurora: return "Aurora"
        case .synthwave: return "Synthwave Grid"
        }
    }

    var blurb: String {
        switch self {
        case .none: return "No effect."
        case .matrix: return "Falling columns of glyphs behind your text."
        case .crt: return "Scanlines, vignette, flicker and a rolling refresh bar over everything."
        case .starfield: return "Stars streaking past at warp speed."
        case .snow: return "Gentle snowflakes drifting down."
        case .fireflies: return "Softly pulsing glowing particles."
        case .aurora: return "Slow-moving ribbons of northern lights."
        case .synthwave: return "An endless neon grid racing toward a striped sun."
        }
    }

    /// Drawn above the text rather than behind it.
    var isOverlay: Bool { self == .crt }

    var defaultColor: RGB {
        switch self {
        case .matrix: return RGB(0x3C, 0xF0, 0x6E)
        case .crt: return RGB(0x7C, 0xFF, 0xB2)
        case .starfield, .snow: return RGB(0xEE, 0xF4, 0xFF)
        case .fireflies: return RGB(0xF7, 0xD4, 0x5C)
        case .aurora: return RGB(0x4D, 0xF2, 0xB0)
        case .synthwave: return RGB(0xFF, 0x3E, 0xC8)
        case .none: return RGB(255, 255, 255)
        }
    }
}

struct EffectSettings: Equatable {
    var kind: EffectKind = .none
    var intensity: CGFloat = 0.45
    var speed: CGFloat = 1
    var density: CGFloat = 0.6
    var color: RGB? = nil
    var pauseWhenInactive = true
    var background = RGB(0x14, 0x16, 0x1B)
    var tint: RGB { color ?? kind.defaultColor }
}

final class EffectView: NSView {
    private(set) var settings = EffectSettings()
    private var timer: Timer?
    private var time: Double = 0
    private var lastTick = CACurrentMediaTime()
    private var rng = SystemRandomNumberGenerator()
    private var builtFor: (EffectKind, CGSize, CGFloat)?

    // particle state (shared shapes across effects)
    private struct Particle { var x, y, z, vx, vy, size, phase: CGFloat }
    private var particles: [Particle] = []
    private struct Column { var head: CGFloat; var speed: CGFloat; var length: Int; var glyphs: [CGGlyph] }
    private var columns: [Column] = []
    private var matrixFont: CTFont = CTFontCreateWithName("Hiragino Sans" as CFString, 14, nil)
    private var matrixGlyphs: [CGGlyph] = []
    private let matrixCell: CGFloat = 16

    static let fps: Double = 30

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // click-through

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        prepareMatrixGlyphs()
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ s: EffectSettings) {
        let rebuild = s.kind != settings.kind || s.density != settings.density
        settings = s
        isHidden = s.kind == .none
        if rebuild { builtFor = nil }
        updateTimer()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); builtFor = nil }

    private func updateTimer() {
        let wants = settings.kind != .none && window != nil
        if wants && timer == nil {
            lastTick = CACurrentMediaTime()
            let t = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common) // keep animating during live resize / menu tracking
            timer = t
        } else if !wants {
            timer?.invalidate(); timer = nil
        }
    }

    deinit { timer?.invalidate() }

    /// Animation is skipped (frame frozen) when nobody can see it or the user asked for less motion.
    private var shouldAnimate: Bool {
        guard let w = window, w.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { return false }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        if settings.pauseWhenInactive && !NSApp.isActive { return false }
        return true
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        guard shouldAnimate else { return }
        advance(dt * Double(settings.speed))
        needsDisplay = true
    }

    /// Advance the simulation (public so snapshots/tests can step it deterministically).
    func advance(_ dt: Double) {
        ensureBuilt()
        time += dt
        let w = bounds.width, h = bounds.height
        let d = CGFloat(dt)
        switch settings.kind {
        case .matrix:
            let rows = Int(h / matrixCell) + 1
            for i in columns.indices {
                columns[i].head += columns[i].speed * d
                if Int(columns[i].head) - columns[i].length > rows {
                    columns[i].head = -CGFloat(Int.random(in: 0...rows, using: &rng))
                    columns[i].speed = CGFloat.random(in: 6...22, using: &rng)
                    columns[i].length = Int.random(in: 8...28, using: &rng)
                }
                // glyphs flicker: mutate a few each frame
                if !matrixGlyphs.isEmpty, CGFloat.random(in: 0...1, using: &rng) < 0.5 {
                    let k = Int.random(in: 0..<columns[i].glyphs.count, using: &rng)
                    columns[i].glyphs[k] = matrixGlyphs.randomElement(using: &rng)!
                }
            }
        case .starfield:
            for i in particles.indices {
                particles[i].z -= 0.35 * d
                if particles[i].z <= 0.02 { particles[i] = newStar(z: 1) }
            }
        case .snow:
            for i in particles.indices {
                particles[i].y += particles[i].vy * d
                particles[i].x += sin(CGFloat(time) * 0.8 + particles[i].phase) * 18 * d
                if particles[i].y > h + 5 { particles[i].y = -5; particles[i].x = CGFloat.random(in: 0...w, using: &rng) }
                if particles[i].x < -5 { particles[i].x = w + 5 } else if particles[i].x > w + 5 { particles[i].x = -5 }
            }
        case .fireflies:
            for i in particles.indices {
                particles[i].vx += CGFloat.random(in: -30...30, using: &rng) * d
                particles[i].vy += CGFloat.random(in: -30...30, using: &rng) * d
                particles[i].vx = max(-25, min(25, particles[i].vx)); particles[i].vy = max(-25, min(25, particles[i].vy))
                particles[i].x += particles[i].vx * d; particles[i].y += particles[i].vy * d
                if particles[i].x < 0 || particles[i].x > w { particles[i].vx *= -1; particles[i].x = max(0, min(w, particles[i].x)) }
                if particles[i].y < 0 || particles[i].y > h { particles[i].vy *= -1; particles[i].y = max(0, min(h, particles[i].y)) }
            }
        default: break
        }
    }

    private func ensureBuilt() {
        let key = (settings.kind, bounds.size, settings.density)
        if let b = builtFor, b.0 == key.0, b.1 == key.1, b.2 == key.2 { return }
        builtFor = key
        particles = []; columns = []; columnX = []
        let w = max(1, bounds.width), h = max(1, bounds.height)
        let dens = settings.density
        switch settings.kind {
        case .matrix:
            let n = Int(w / matrixCell) + 1
            let rows = Int(h / matrixCell) + 1
            for i in 0..<n where CGFloat.random(in: 0...1, using: &rng) < 0.35 + 0.65 * dens || i % 2 == 0 && dens > 0.5 {
                let glyphs = (0..<(rows + 30)).map { _ in matrixGlyphs.randomElement(using: &rng) ?? 0 }
                columns.append(Column(head: CGFloat.random(in: -CGFloat(rows)...CGFloat(rows), using: &rng),
                                      speed: CGFloat.random(in: 6...22, using: &rng),
                                      length: Int.random(in: 8...28, using: &rng), glyphs: glyphs))
                columnX.append(CGFloat(i) * matrixCell)
            }
        case .starfield:
            particles = (0..<Int(60 + 340 * dens)).map { _ in newStar(z: CGFloat.random(in: 0.05...1, using: &rng)) }
        case .snow:
            particles = (0..<Int(30 + 220 * dens)).map { _ in
                let z = CGFloat.random(in: 0.3...1, using: &rng) // depth: bigger + faster when near
                return Particle(x: .random(in: 0...w, using: &rng), y: .random(in: 0...h, using: &rng), z: z,
                                vx: 0, vy: 20 + 45 * z, size: 1 + 2.6 * z, phase: .random(in: 0...6.28, using: &rng))
            }
        case .fireflies:
            particles = (0..<Int(8 + 52 * dens)).map { _ in
                Particle(x: .random(in: 0...w, using: &rng), y: .random(in: 0...h, using: &rng), z: 0,
                         vx: .random(in: -15...15, using: &rng), vy: .random(in: -15...15, using: &rng),
                         size: .random(in: 6...16, using: &rng), phase: .random(in: 0...6.28, using: &rng))
            }
        default: break
        }
    }

    private var columnX: [CGFloat] = []

    private func newStar(z: CGFloat) -> Particle {
        Particle(x: .random(in: -1...1, using: &rng), y: .random(in: -1...1, using: &rng), z: z,
                 vx: 0, vy: 0, size: .random(in: 0.6...1.6, using: &rng), phase: 0)
    }

    private func prepareMatrixGlyphs() {
        // half-width katakana + digits + a few symbols, rendered from a font that has them
        var chars: [UniChar] = Array(0xFF66...0xFF9D).map { UniChar($0) }
        chars += Array("0123456789Z:=*+-<>¦".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(matrixFont, chars, &glyphs, chars.count)
        matrixGlyphs = glyphs.filter { $0 != 0 }
        if matrixGlyphs.isEmpty { // fall back to digits in a monospaced font
            matrixFont = CTFontCreateWithName("Menlo" as CFString, 14, nil)
            var d = Array("0123456789".utf16); var g = [CGGlyph](repeating: 0, count: d.count)
            CTFontGetGlyphsForCharacters(matrixFont, &d, &g, d.count)
            matrixGlyphs = g
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard settings.kind != .none, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ensureBuilt()
        let a = settings.intensity
        let tint = settings.tint
        switch settings.kind {
        case .matrix: drawMatrix(ctx, a, tint)
        case .crt: drawCRT(ctx, a, tint)
        case .starfield: drawStarfield(ctx, a, tint)
        case .snow: drawSnow(ctx, a, tint)
        case .fireflies: drawFireflies(ctx, a, tint)
        case .aurora: drawAurora(ctx, a, tint)
        case .synthwave: drawSynthwave(ctx, a, tint)
        case .none: break
        }
    }

    private func color(_ c: RGB, _ alpha: CGFloat) -> CGColor { c.nsColor.withAlphaComponent(max(0, min(1, alpha))).cgColor }

    private func drawMatrix(_ ctx: CGContext, _ a: CGFloat, _ tint: RGB) {
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // Bucket glyphs by brightness so each bucket is one CTFontDrawGlyphs call.
        let buckets = 8
        var glyphs = [[CGGlyph]](repeating: [], count: buckets)
        var points = [[CGPoint]](repeating: [], count: buckets)
        var heads: [CGGlyph] = [], headPts: [CGPoint] = []
        let rows = Int(bounds.height / matrixCell) + 1
        for (i, col) in columns.enumerated() {
            let head = Int(col.head)
            for k in 0..<col.length {
                let r = head - k
                guard r >= 0 && r < rows else { continue }
                let g = col.glyphs[r % col.glyphs.count]
                // CTFontDrawGlyphs positions are in *text space*: the flipped text matrix
                // (needed for upright glyphs in a flipped view) also negates y, so pre-negate it.
                let p = CGPoint(x: columnX[i] + 1, y: -(CGFloat(r + 1) * matrixCell - 3))
                if k == 0 { heads.append(g); headPts.append(p); continue }
                let fade = 1 - CGFloat(k) / CGFloat(col.length)
                let b = min(buckets - 1, Int(fade * CGFloat(buckets)))
                glyphs[b].append(g); points[b].append(p)
            }
        }
        for b in 0..<buckets where !glyphs[b].isEmpty {
            ctx.setFillColor(color(tint, a * (CGFloat(b) + 1) / CGFloat(buckets)))
            CTFontDrawGlyphs(matrixFont, glyphs[b], points[b], glyphs[b].count, ctx)
        }
        if !heads.isEmpty {
            ctx.setFillColor(color(tint.blended(with: RGB(255, 255, 255), 0.75), min(1, a * 1.6)))
            CTFontDrawGlyphs(matrixFont, heads, headPts, heads.count, ctx)
        }
    }

    private func drawCRT(_ ctx: CGContext, _ a: CGFloat, _ tint: RGB) {
        let w = bounds.width, h = bounds.height
        // phosphor tint
        ctx.setFillColor(color(tint, 0.035 * a)); ctx.fill(bounds)
        // scanlines: one path, one fill
        let p = CGMutablePath()
        var y: CGFloat = 0
        while y < h { p.addRect(CGRect(x: 0, y: y, width: w, height: 1)); y += 3 }
        ctx.addPath(p); ctx.setFillColor(color(RGB(0, 0, 0), 0.45 * a)); ctx.fillPath()
        // rolling refresh bar
        let barH = h * 0.18
        let barY = CGFloat((time * 0.12).truncatingRemainder(dividingBy: 1)) * (h + barH) - barH
        if let g = CGGradient(colorsSpace: nil, colors: [color(tint, 0), color(tint, 0.07 * a), color(tint, 0)] as CFArray, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: barY), end: CGPoint(x: 0, y: barY + barH), options: [])
        }
        // vignette
        if let g = CGGradient(colorsSpace: nil, colors: [color(RGB(0, 0, 0), 0), color(RGB(0, 0, 0), 0.75 * a)] as CFArray, locations: [0.55, 1]) {
            let c = CGPoint(x: w / 2, y: h / 2)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: hypot(w, h) / 2, options: [.drawsAfterEndLocation])
        }
        // flicker
        let flicker = CGFloat(sin(time * 53) * 0.5 + 0.5) * 0.025 * a
        ctx.setFillColor(color(RGB(255, 255, 255), flicker)); ctx.fill(bounds)
    }

    private func drawStarfield(_ ctx: CGContext, _ a: CGFloat, _ tint: RGB) {
        let w = bounds.width, h = bounds.height, cx = w / 2, cy = h / 2
        let scale = max(w, h) * 0.5
        ctx.setLineCap(.round)
        for s in particles {
            let px = cx + s.x / s.z * scale * 0.5, py = cy + s.y / s.z * scale * 0.5
            guard px > -10 && px < w + 10 && py > -10 && py < h + 10 else { continue }
            let zPrev = min(1, s.z + 0.035 * settings.speed)
            let qx = cx + s.x / zPrev * scale * 0.5, qy = cy + s.y / zPrev * scale * 0.5
            let near = 1 - s.z
            ctx.setStrokeColor(color(tint, a * (0.25 + near)))
            ctx.setLineWidth(s.size * (0.4 + near * 2.2))
            ctx.move(to: CGPoint(x: qx, y: qy)); ctx.addLine(to: CGPoint(x: px, y: py)); ctx.strokePath()
        }
    }

    private func drawSnow(_ ctx: CGContext, _ a: CGFloat, _ tint: RGB) {
        for f in particles {
            ctx.setFillColor(color(tint, a * (0.35 + 0.65 * f.z)))
            ctx.fillEllipse(in: CGRect(x: f.x - f.size, y: f.y - f.size, width: f.size * 2, height: f.size * 2))
        }
    }

    private func drawFireflies(_ ctx: CGContext, _ a: CGFloat, _ tint: RGB) {
        for f in particles {
            let pulse = 0.25 + 0.75 * (0.5 + 0.5 * sin(CGFloat(time) * 1.7 + f.phase))
            let r = f.size * (1.2 + pulse)
            guard let g = CGGradient(colorsSpace: nil, colors: [color(tint, a * pulse), color(tint, a * pulse * 0.35), color(tint, 0)] as CFArray,
                                     locations: [0, 0.25, 1]) else { continue }
            let c = CGPoint(x: f.x, y: f.y)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }
    }

    private func drawAurora(_ ctx: CGContext, _ a: CGFloat, _ tint: RGB) {
        let w = bounds.width, h = bounds.height
        let t = CGFloat(time)
        // three ribbons with hue-shifted variants of the tint
        let hues: [RGB] = [tint, tint.blended(with: RGB(0x5B, 0x8C, 0xFF), 0.6), tint.blended(with: RGB(0xC0, 0x5C, 0xFF), 0.55)]
        for (i, c) in hues.enumerated() {
            let fi = CGFloat(i)
            let base = h * (0.18 + 0.12 * fi)
            let amp = h * (0.06 + 0.02 * fi)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: h))
            var x: CGFloat = 0
            while x <= w + 8 {
                let y = base + sin(x / w * 2 * .pi * (1.1 + 0.3 * fi) + t * (0.35 + 0.1 * fi) + fi * 1.7) * amp
                    + sin(x / w * 2 * .pi * 3.3 + t * 0.7 + fi) * amp * 0.3
                path.addLine(to: CGPoint(x: x, y: y))
                x += 8
            }
            path.addLine(to: CGPoint(x: w, y: h)); path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            if let g = CGGradient(colorsSpace: nil, colors: [color(c, 0.55 * a), color(c, 0.15 * a), color(c, 0)] as CFArray, locations: [0, 0.35, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: base - amp), end: CGPoint(x: 0, y: base + h * 0.55), options: [])
            }
            ctx.restoreGState()
        }
    }

    private func drawSynthwave(_ ctx: CGContext, _ a: CGFloat, _ tint: RGB) {
        let w = bounds.width, h = bounds.height
        let horizon = h * 0.58
        let cx = w / 2
        // sun with horizontal cut-outs
        let r = min(w, h) * 0.2
        let sunRect = CGRect(x: cx - r, y: horizon - r * 1.55, width: r * 2, height: r * 2)
        ctx.saveGState()
        let clip = CGMutablePath()
        clip.addEllipse(in: sunRect)
        ctx.addPath(clip); ctx.clip()
        if let g = CGGradient(colorsSpace: nil, colors: [color(RGB(0xFF, 0xD3, 0x4E), 0.7 * a), color(tint, 0.65 * a)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: sunRect.minY), end: CGPoint(x: 0, y: horizon), options: [])
        }
        ctx.setBlendMode(.clear)
        var sy = sunRect.midY
        var gap: CGFloat = 2
        while sy < horizon { ctx.fill(CGRect(x: sunRect.minX, y: sy, width: sunRect.width, height: gap)); sy += 10; gap += 1.2 }
        ctx.restoreGState()
        // horizon glow
        if let g = CGGradient(colorsSpace: nil, colors: [color(tint, 0), color(tint, 0.35 * a), color(tint, 0)] as CFArray, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: horizon - 30), end: CGPoint(x: 0, y: horizon + 30), options: [])
        }
        // grid
        let gridColor = RGB(0x2E, 0xE6, 0xFF).blended(with: tint, 0.35)
        ctx.setLineWidth(1.2)
        let n = 18
        for i in -n...n {
            let fx = CGFloat(i) / CGFloat(n)
            ctx.setStrokeColor(color(gridColor, a * (0.9 - abs(fx) * 0.4)))
            ctx.move(to: CGPoint(x: cx + fx * w * 0.08, y: horizon))
            ctx.addLine(to: CGPoint(x: cx + fx * w * 1.6, y: h))
            ctx.strokePath()
        }
        let offset = CGFloat((time * 0.6).truncatingRemainder(dividingBy: 1))
        for k in 0..<14 {
            let z = CGFloat(k) + 1 - offset            // distance, shrinking as we move forward
            let y = horizon + (h - horizon) * (1 / z)  // perspective
            guard y <= h else { continue }
            ctx.setStrokeColor(color(gridColor, a * min(1, (y - horizon) / (h - horizon) * 2.2)))
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)); ctx.strokePath()
        }
    }
}
