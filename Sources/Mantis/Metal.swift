import AppKit
import Metal
import QuartzCore
import CoreText

/// GPU renderer for the cell grid.
///
/// Every frame is a single instanced draw: one quad per background run and one per glyph.
/// Glyphs are rasterized once by CoreText into a texture atlas
/// and then only *referenced* by later frames, so drawing a full screen is a few
/// microseconds of GPU work and a small loop on the CPU.
///
/// The CoreGraphics grid view stays on top for the things that are cheap to draw and
/// change rarely: decorations (underlines…), cursor, hints, toasts and overlays.

/// One instanced quad. Must match `struct Quad` in the shader source below.
struct GPUQuad {
    var rect: SIMD4<Float>   // x, y, width, height in points (top-left origin)
    var uv: SIMD4<Float>     // atlas u0, v0, u1, v1 (normalized)
    var color: SIMD4<Float>  // straight-alpha RGBA
    var kind: UInt32         // 0 = solid fill, 1 = tinted glyph mask, 2 = color glyph (emoji)
    var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
}

struct GlyphKey: Hashable {
    var code: UInt32
    var style: UInt8
    var width: UInt8
}

/// Shelf-packed RGBA glyph atlas.
final class GlyphAtlas {
    struct Entry {
        var uv: SIMD4<Float>
        var size: CGSize    // points
        var offset: CGPoint // points, relative to the cell's top-left
        var colored: Bool
        var empty: Bool
    }

    let device: MTLDevice
    let size: Int
    private(set) var texture: MTLTexture
    private var entries: [GlyphKey: Entry] = [:]
    private var shelfX = 0, shelfY = 0, shelfH = 0
    /// Bumped whenever the atlas is cleared; entries from older generations are invalid.
    private(set) var generation = 0
    private(set) var scale: CGFloat = 0
    private(set) var fontGeneration = -1

    init?(device: MTLDevice, size: Int = 2048) {
        self.device = device
        self.size = size
        guard let t = GlyphAtlas.makeTexture(device, size) else { return nil }
        texture = t
    }

    private static func makeTexture(_ device: MTLDevice, _ size: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        return device.makeTexture(descriptor: d)
    }

    var count: Int { entries.count }

    /// Drop everything (font or scale changed, or the atlas is full).
    func reset(scale: CGFloat, fontGeneration: Int) {
        entries.removeAll(keepingCapacity: true)
        shelfX = 0; shelfY = 0; shelfH = 0
        generation &+= 1
        self.scale = scale
        self.fontGeneration = fontGeneration
        if let t = GlyphAtlas.makeTexture(device, size) { texture = t } // fresh, zeroed texture
    }

    /// Look up a glyph, rasterizing it on first use. `raster` draws the glyph in white into a
    /// flipped (top-left origin) context, inside `cell`.
    func entry(_ key: GlyphKey, cellSize: CGSize, raster: (CGContext, CGRect) -> Void) -> Entry {
        if let e = entries[key] { return e }
        // Margins let italics, emoji and tall glyphs overhang their cell without clipping.
        let mx = ceil(cellSize.width / 2), my = ceil(cellSize.height / 4)
        let cellW = cellSize.width * CGFloat(max(1, key.width))
        let wPts = cellW + 2 * mx, hPts = cellSize.height + 2 * my
        let pw = Int(ceil(wPts * scale)), ph = Int(ceil(hPts * scale))

        var pixels = [UInt8](repeating: 0, count: pw * ph * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(ph))
            ctx.scaleBy(x: scale, y: -scale) // flipped, in points — same as the grid view
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            raster(ctx, CGRect(x: mx, y: my, width: cellW, height: cellSize.height))
            return true
        }

        // Empty (space-like) or color (emoji) glyph? Mask glyphs drawn in white have r=g=b=a.
        var empty = true, colored = false
        if drawn {
            var i = 0
            while i < pixels.count {
                let a = pixels[i + 3]
                if a != 0 {
                    empty = false
                    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                    if abs(r - Int(a)) > 3 || abs(g - Int(a)) > 3 || abs(b - Int(a)) > 3 { colored = true; break }
                }
                i += 4
            }
        }
        var e = Entry(uv: .zero, size: CGSize(width: CGFloat(pw) / scale, height: CGFloat(ph) / scale),
                      offset: CGPoint(x: -mx, y: -my), colored: colored, empty: empty || !drawn)
        if !e.empty {
            // Shelf packing, with a 1px gutter so nearest sampling never bleeds.
            if shelfX + pw + 1 > size { shelfX = 0; shelfY += shelfH + 1; shelfH = 0 }
            if shelfY + ph + 1 > size || pw + 1 > size {
                // Full: start over. Callers detect this via `generation` and rebuild the frame.
                reset(scale: scale, fontGeneration: fontGeneration)
                return entry(key, cellSize: cellSize, raster: raster)
            }
            texture.replace(region: MTLRegionMake2D(shelfX, shelfY, pw, ph), mipmapLevel: 0, withBytes: pixels, bytesPerRow: pw * 4)
            let s = Float(size)
            e.uv = SIMD4(Float(shelfX) / s, Float(shelfY) / s, Float(shelfX + pw) / s, Float(shelfY + ph) / s)
            shelfX += pw + 1
            shelfH = max(shelfH, ph)
        }
        entries[key] = e
        return e
    }
}

/// The Metal layer of a terminal pane. Sits between the effect layer and the CoreGraphics
/// grid view (which keeps drawing decorations, cursor and overlays).
final class MetalGridView: NSView {
    weak var owner: TerminalView?
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    let atlas: GlyphAtlas
    private var quadBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    /// Number of quads in the last frame (tests/benchmarks).
    private(set) var lastQuadCount = 0
    /// Frames presented on screen (tests).
    private(set) var presentedFrames = 0
    /// Test hook: copy the next on-screen drawable back to the CPU and hand it over.
    var captureNextFrame: ((CGImage?) -> Void)?

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Quad { float4 rect; float4 uv; float4 color; uint kind; uint pad0, pad1, pad2; };
    struct VOut { float4 pos [[position]]; float2 uv; float4 color; uint kind [[flat]]; };

    vertex VOut vmain(uint vid [[vertex_id]], uint iid [[instance_id]],
                      constant Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
        Quad q = quads[iid];
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        float2 p = q.rect.xy + corner * q.rect.zw;
        VOut o;
        o.pos = float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
        o.uv = mix(q.uv.xy, q.uv.zw, corner);
        o.color = q.color;
        o.kind = q.kind;
        return o;
    }

    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        if (in.kind == 0) { return float4(in.color.rgb * in.color.a, in.color.a); }
        float4 t = atlas.sample(s, in.uv);
        if (in.kind == 1) { float a = t.a * in.color.a; return float4(in.color.rgb * a, a); }
        return t * in.color.a; // color glyph, already premultiplied
    }
    """

    init?(owner: TerminalView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let atlas = GlyphAtlas(device: device) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        do {
            let lib = try device.makeLibrary(source: MetalGridView.shaderSource, options: nil)
            pd.vertexFunction = lib.makeFunction(name: "vmain")
            pd.fragmentFunction = lib.makeFunction(name: "fmain")
        } catch {
            NSLog("Mantis: Metal shader compile failed, using CoreGraphics: \(error)")
            return nil
        }
        let ca = pd.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one          // premultiplied
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        self.device = device; self.queue = queue; self.pipeline = pipeline; self.atlas = atlas
        self.owner = owner
        super.init(frame: owner.bounds)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.isOpaque = false
        l.framebufferOnly = true
        l.presentsWithTransaction = true // stay in sync with the CoreGraphics overlay layer
        l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        l.needsDisplayOnBoundsChange = true
        return l
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer?.contentsScale = scale
        updateDrawableSize()
        dirty = true
        owner?.gridView.needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let l = metalLayer else { return }
        l.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    /// Build this frame's quads (rebuilding once if the atlas had to be cleared midway).
    func buildQuads() -> [GPUQuad] {
        guard let owner else { return [] }
        if atlas.scale != scale || atlas.fontGeneration != owner.fontGeneration {
            atlas.reset(scale: scale, fontGeneration: owner.fontGeneration)
        }
        let gen = atlas.generation
        var quads = owner.buildGPUQuads(atlas: atlas)
        if atlas.generation != gen { quads = owner.buildGPUQuads(atlas: atlas) }
        lastQuadCount = quads.count
        return quads
    }

    private func quadBuffer(for quads: [GPUQuad]) -> MTLBuffer? {
        let bytes = max(1, quads.count) * MemoryLayout<GPUQuad>.stride
        if quadBuffers.count < 3 { quadBuffers.append(contentsOf: (quadBuffers.count..<3).compactMap { _ in device.makeBuffer(length: 64 * 1024, options: .storageModeShared) }) }
        bufferIndex = (bufferIndex + 1) % quadBuffers.count
        if quadBuffers[bufferIndex].length < bytes {
            guard let b = device.makeBuffer(length: bytes * 2, options: .storageModeShared) else { return nil }
            quadBuffers[bufferIndex] = b
        }
        let buf = quadBuffers[bufferIndex]
        quads.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return buf
    }

    private func encode(_ quads: [GPUQuad], buffer: MTLBuffer, into texture: MTLTexture, cb: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        if !quads.isEmpty {
            var viewport = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
        }
        enc.endEncoding()
    }

    /// Set by every invalidation of the text layer; the frame is rendered during that layer's
    /// draw pass (AppKit does not redisplay CAMetalLayer-backed views on setNeedsDisplay), so the
    /// GPU frame and the CoreGraphics overlay land in the same Core Animation transaction.
    var dirty = true

    func renderIfNeeded() {
        guard dirty else { return }
        dirty = false
        renderOnScreen()
    }

    override func updateLayer() { renderOnScreen() }

    private func renderOnScreen() {
        guard let l = metalLayer, bounds.width > 0, bounds.height > 0, window != nil else { return }
        let quads = buildQuads()
        let capture = captureNextFrame
        captureNextFrame = nil
        l.framebufferOnly = capture == nil
        inFlight.wait()
        guard let buf = quadBuffer(for: quads), let drawable = l.nextDrawable(), let cb = queue.makeCommandBuffer() else { inFlight.signal(); capture?(nil); return }
        encode(quads, buffer: buf, into: drawable.texture, cb: cb)
        var readback: MTLTexture?
        if capture != nil {
            let t = drawable.texture
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat, width: t.width, height: t.height, mipmapped: false)
            d.storageMode = device.hasUnifiedMemory ? .shared : .managed
            readback = device.makeTexture(descriptor: d)
            if let rb = readback, let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: t, to: rb)
                if rb.storageMode == .managed { blit.synchronize(resource: rb) }
                blit.endEncoding()
            }
        }
        let sem = inFlight
        cb.addCompletedHandler { _ in
            sem.signal()
            if let capture, let rb = readback { let img = MetalGridView.image(from: rb); DispatchQueue.main.async { capture(img) } }
        }
        cb.commit()
        cb.waitUntilScheduled()
        drawable.present()
        presentedFrames += 1
    }

    /// Render offscreen and return the pixels (snapshots, `cacheDisplay`, tests).
    func renderImage() -> CGImage? {
        let pw = Int(bounds.width * scale), ph = Int(bounds.height * scale)
        guard pw > 0, ph > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pw, height: ph, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        let quads = buildQuads()
        guard let tex = device.makeTexture(descriptor: d), let buf = quadBuffer(for: quads), let cb = queue.makeCommandBuffer() else { return nil }
        encode(quads, buffer: buf, into: tex, cb: cb)
        if tex.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: tex); blit.endEncoding() }
        cb.commit()
        cb.waitUntilCompleted()
        return MetalGridView.image(from: tex)
    }

    static func image(from tex: MTLTexture) -> CGImage? {
        let pw = tex.width, ph = tex.height
        var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
        tex.getBytes(&bytes, bytesPerRow: pw * 4, from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pw * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Benchmark helper: average ms per frame (build quads + encode + GPU execution) rendering
    /// into one reused offscreen texture — i.e. the on-screen cost without presentation.
    func timeFrames(_ n: Int) -> Double {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(bounds.width * scale), height: Int(bounds.height * scale), mipmapped: false)
        d.usage = .renderTarget; d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d) else { return .nan }
        let start = Date()
        for _ in 0..<n {
            let quads = buildQuads()
            guard let buf = quadBuffer(for: quads), let cb = queue.makeCommandBuffer() else { return .nan }
            encode(quads, buffer: buf, into: tex, cb: cb)
            cb.commit(); cb.waitUntilCompleted()
        }
        return Date().timeIntervalSince(start) / Double(n) * 1000
    }

    /// Used by `cacheDisplay` (snapshots, tests): draw the GPU output into the CG context.
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let img = renderImage() else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height) // the view is flipped; CGImage draws bottom-up
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: bounds)
        ctx.restoreGState()
    }
}
