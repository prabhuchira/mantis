/// VT-series escape sequence parser.
///
/// Implements the state machine from https://vt100.net/emu/dec_ansi_parser.
/// Bytes go in, semantic *actions* (print/execute/csi/esc/osc) come out via
/// `ParserHandler`. The parser itself holds no screen state.
public protocol ParserHandler: AnyObject {
    func print(_ scalar: Unicode.Scalar)
    func execute(_ byte: UInt8)
    /// `params` are parameter groups: `;` starts a group, `:` adds a sub-parameter.
    func csiDispatch(params: CSIParams, intermediates: [UInt8], final: UInt8)
    func escDispatch(intermediates: [UInt8], final: UInt8)
    func oscDispatch(_ data: [UInt8])
    func dcsDispatch(_ data: [UInt8], intermediates: [UInt8], final: UInt8)
}

public extension ParserHandler {
    func dcsDispatch(_ data: [UInt8], intermediates: [UInt8], final: UInt8) {}
}

/// CSI parameters, stored flat (no per-group arrays): `;` starts a group, `:` adds a
/// sub-parameter. `params[i][0]` is group i's main value; `params[i].count` its size.
///
/// A non-owning view of the parser's preallocated buffers: valid only during the
/// `csiDispatch` call (copy `groups` out if you need to keep it).
public struct CSIParams: RandomAccessCollection {
    public struct Group: RandomAccessCollection {
        let values: UnsafePointer<Int>; let lo: Int; let hi: Int
        public var startIndex: Int { 0 }
        public var endIndex: Int { hi - lo }
        public subscript(i: Int) -> Int { values[lo + i] }
    }
    let values: UnsafePointer<Int>
    let ends: UnsafePointer<Int> // ends[i] = one past group i's last value
    public let count: Int
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(i: Int) -> Group { Group(values: values, lo: i == 0 ? 0 : ends[i - 1], hi: ends[i]) }
    /// Nested-array form (for tests and debugging).
    public var groups: [[Int]] { map { Array($0) } }

    /// Call `body` with params built from nested arrays (tests, synthetic sequences).
    public static func with<R>(_ groups: [[Int]], _ body: (CSIParams) -> R) -> R {
        let flat = groups.flatMap { $0 }
        var ends: [Int] = []; var n = 0
        for g in groups { n += g.count; ends.append(n) }
        return flat.withUnsafeBufferPointer { v in ends.withUnsafeBufferPointer { e in
            body(CSIParams(values: v.baseAddress ?? UnsafePointer(bitPattern: 8)!, ends: e.baseAddress ?? UnsafePointer(bitPattern: 8)!, count: groups.count))
        } }
    }
}

/// Optional fast path: receive whole runs of printable ASCII at once.
public protocol ASCIIRunHandler: ParserHandler {
    func printASCII(_ run: UnsafeBufferPointer<UInt8>)
}

public final class Parser {
    public enum State: Equatable {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case oscString
        case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
        case sosPmApcString
    }

    public private(set) var state: State = .ground
    public weak var handler: ParserHandler?
    /// Non-owning, non-weak handler for an owner that outlives the parser (Terminal owns its
    /// parser). Avoids weak-reference side tables, which make every retain/release around a
    /// handler call take Swift's slow refcount path.
    private unowned(unsafe) var owner: ParserHandler?
    public func setOwner(_ h: ParserHandler) { owner = h }

    private var intermediates: [UInt8] = []
    // Preallocated parameter storage (maxParams groups × up to 8 sub-parameters).
    private let paramValues = UnsafeMutablePointer<Int>.allocate(capacity: Parser.maxParams * 8)
    private let paramEnds = UnsafeMutablePointer<Int>.allocate(capacity: Parser.maxParams)
    private var nValues = 0, nGroups = 0
    private var params: CSIParams { CSIParams(values: paramValues, ends: paramEnds, count: nGroups) }
    private var oscBuffer: [UInt8] = []
    private var dcsBuffer: [UInt8] = []
    private var dcsFinal: UInt8 = 0

    // UTF-8 decoder state (ground state only)
    private var utf8Remaining = 0
    private var utf8Codepoint: UInt32 = 0

    static let maxParams = 32
    static let maxOSC = 1 << 20

    public init() {}
    deinit { paramValues.deallocate(); paramEnds.deallocate() }

    public func feed<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        guard let h = owner ?? handler else { return }
        for b in bytes { step(b, h) }
    }

    public func feed(_ buffer: UnsafeBufferPointer<UInt8>) {
        // Load the (weak) handler and the fast-path cast once per buffer, not per byte.
        guard let h = owner ?? handler else { return }
        let fast = h as? ASCIIRunHandler
        guard let p = buffer.baseAddress else { return }
        var i = 0
        let n = buffer.count
        while i < n {
            if state == .ground && utf8Remaining == 0 {
                // Fast path 1: printable ASCII, scanned 32 bytes at a time.
                let start = i
                i = Parser.scanPrintable(p, i, n)
                if i > start {
                    if let fast {
                        fast.printASCII(UnsafeBufferPointer(start: p + start, count: i - start))
                    } else {
                        for j in start..<i { h.print(Unicode.Scalar(p[j])) }
                    }
                }
                if i == n { return }
                let b = p[i]
                // Fast path 2: complete UTF-8 sequences decoded inline.
                if b >= 0xC2 && b <= 0xF4, let (cp, len) = Parser.decodeUTF8(p, i, n) {
                    h.print(Unicode.Scalar(cp) ?? "\u{FFFD}")
                    i += len
                    continue
                }
                // Fast path 3: a complete CSI sequence (SGR, cursor moves…) parsed in one go.
                if b == 0x1B, i + 2 < n, p[i + 1] == 0x5B, let end = parseCSI(p, i + 2, n) {
                    h.csiDispatch(params: params, intermediates: intermediates, final: p[end])
                    i = end + 1
                    continue
                }
            }
            step(p[i], h)
            i += 1
        }
    }

    /// Index of the first byte at or after `i` that is not printable ASCII (0x20–0x7E).
    @inline(__always)
    static func scanPrintable(_ p: UnsafePointer<UInt8>, _ start: Int, _ n: Int) -> Int {
        var i = start
        let lo = SIMD32<UInt8>(repeating: 0x20), span = SIMD32<UInt8>(repeating: 0x5F)
        while i + 32 <= n {
            let v = UnsafeRawPointer(p + i).loadUnaligned(as: SIMD32<UInt8>.self)
            // 0x20 <= b < 0x7F  ⇔  (b - 0x20) < 0x5F as unsigned bytes
            if any((v &- lo) .>= span) { break }
            i += 32
        }
        while i < n, p[i] &- 0x20 < 0x5F { i += 1 }
        return i
    }

    /// Decode one complete multi-byte UTF-8 sequence at `i`, or nil if it is incomplete or
    /// malformed (the state machine then handles it byte by byte, with the same results).
    @inline(__always)
    static func decodeUTF8(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> (UInt32, Int)? {
        let b = p[i]
        let len = b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
        guard i + len <= n else { return nil }
        var cp = UInt32(b & (len == 2 ? 0x1F : len == 3 ? 0x0F : 0x07))
        for k in 1..<len {
            let c = p[i + k]
            guard c & 0xC0 == 0x80 else { return nil }
            cp = cp << 6 | UInt32(c & 0x3F)
        }
        return (cp, len)
    }

    /// Parse the body of `ESC [` starting at `j` into params/intermediates. Returns the index
    /// of the final byte, or nil (nothing consumed) if the sequence is incomplete or contains
    /// anything the state machine treats specially (embedded controls, ignored forms).
    private func parseCSI(_ p: UnsafePointer<UInt8>, _ start: Int, _ n: Int) -> Int? {
        clear()
        var j = start
        var phase = 0 // 0 = entry, 1 = params, 2 = intermediates
        while j < n {
            let c = p[j]
            switch c {
            case 0x30...0x3B where phase < 2: param(c); phase = 1
            case 0x3C...0x3F where phase == 0: intermediates.append(c); phase = 1 // private marker
            case 0x20...0x2F: intermediates.append(c); phase = 2
            case 0x40...0x7E: return j
            default: clear(); return nil
            }
            j += 1
        }
        clear()
        return nil
    }

    public func advance(_ b: UInt8) {
        if let h = owner ?? handler { step(b, h) }
    }

    private func step(_ b: UInt8, _ h: ParserHandler) {
        // --- UTF-8 handling in ground state ---
        if state == .ground {
            if utf8Remaining > 0 {
                if b & 0xC0 == 0x80 {
                    utf8Codepoint = (utf8Codepoint << 6) | UInt32(b & 0x3F)
                    utf8Remaining -= 1
                    if utf8Remaining == 0 { emitScalar(utf8Codepoint, h) }
                    return
                }
                // Invalid continuation: emit replacement and reprocess byte.
                utf8Remaining = 0
                emitScalar(0xFFFD, h)
            }
            if b >= 0x80 {
                switch b {
                case 0xC2...0xDF: utf8Remaining = 1; utf8Codepoint = UInt32(b & 0x1F)
                case 0xE0...0xEF: utf8Remaining = 2; utf8Codepoint = UInt32(b & 0x0F)
                case 0xF0...0xF4: utf8Remaining = 3; utf8Codepoint = UInt32(b & 0x07)
                default: emitScalar(0xFFFD, h)
                }
                return
            }
        }

        // --- "anywhere" transitions ---
        switch b {
        case 0x18, 0x1A: // CAN, SUB
            leaveState(h)
            h.execute(b)
            state = .ground
            return
        case 0x1B:
            leaveState(h)
            clear()
            state = .escape
            return
        default: break
        }

        switch state {
        case .ground:
            if b < 0x20 { h.execute(b) }
            else if b < 0x7F { h.print(Unicode.Scalar(b)) }

        case .escape:
            switch b {
            case 0x00...0x1F: h.execute(b)
            case 0x20...0x2F: intermediates.append(b); state = .escapeIntermediate
            case 0x5B: clear(); state = .csiEntry          // [
            case 0x5D: oscBuffer.removeAll(keepingCapacity: true); state = .oscString // ]
            case 0x50: clear(); state = .dcsEntry          // P
            case 0x58, 0x5E, 0x5F: state = .sosPmApcString // X ^ _
            case 0x30...0x7E: h.escDispatch(intermediates: intermediates, final: b); state = .ground
            default: break
            }

        case .escapeIntermediate:
            switch b {
            case 0x00...0x1F: h.execute(b)
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x7E: h.escDispatch(intermediates: intermediates, final: b); state = .ground
            default: break
            }

        case .csiEntry:
            switch b {
            case 0x00...0x1F: h.execute(b)
            case 0x20...0x2F: intermediates.append(b); state = .csiIntermediate
            case 0x30...0x3B: param(b); state = .csiParam
            case 0x3C...0x3F: intermediates.append(b); state = .csiParam // private marker
            case 0x40...0x7E: dispatchCSI(b, h)
            default: break
            }

        case .csiParam:
            switch b {
            case 0x00...0x1F: h.execute(b)
            case 0x30...0x3B: param(b)
            case 0x3C...0x3F: state = .csiIgnore
            case 0x20...0x2F: intermediates.append(b); state = .csiIntermediate
            case 0x40...0x7E: dispatchCSI(b, h)
            default: break
            }

        case .csiIntermediate:
            switch b {
            case 0x00...0x1F: h.execute(b)
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x3F: state = .csiIgnore
            case 0x40...0x7E: dispatchCSI(b, h)
            default: break
            }

        case .csiIgnore:
            switch b {
            case 0x00...0x1F: h.execute(b)
            case 0x40...0x7E: state = .ground
            default: break
            }

        case .oscString:
            if b == 0x07 { // BEL terminator (xterm)
                h.oscDispatch(oscBuffer)
                state = .ground
            } else if b >= 0x20, oscBuffer.count < Parser.maxOSC {
                oscBuffer.append(b)
            }

        case .dcsEntry:
            switch b {
            case 0x20...0x2F: intermediates.append(b); state = .dcsIntermediate
            case 0x30...0x3B: param(b); state = .dcsParam
            case 0x3C...0x3F: intermediates.append(b); state = .dcsParam
            case 0x40...0x7E: dcsFinal = b; dcsBuffer.removeAll(); state = .dcsPassthrough
            default: break
            }
        case .dcsParam:
            switch b {
            case 0x30...0x3B: param(b)
            case 0x20...0x2F: intermediates.append(b); state = .dcsIntermediate
            case 0x3C...0x3F: state = .dcsIgnore
            case 0x40...0x7E: dcsFinal = b; dcsBuffer.removeAll(); state = .dcsPassthrough
            default: break
            }
        case .dcsIntermediate:
            switch b {
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x3F: state = .dcsIgnore
            case 0x40...0x7E: dcsFinal = b; dcsBuffer.removeAll(); state = .dcsPassthrough
            default: break
            }
        case .dcsPassthrough:
            if b != 0x7F, dcsBuffer.count < Parser.maxOSC { dcsBuffer.append(b) }
        case .dcsIgnore, .sosPmApcString:
            break
        }
    }

    // MARK: - helpers

    private func emitScalar(_ cp: UInt32, _ h: ParserHandler) {
        h.print(Unicode.Scalar(cp) ?? "\u{FFFD}")
    }

    /// Exit actions run when leaving a string state (e.g. ESC \ terminating OSC).
    private func leaveState(_ h: ParserHandler) {
        switch state {
        case .oscString: h.oscDispatch(oscBuffer)
        case .dcsPassthrough: h.dcsDispatch(dcsBuffer, intermediates: intermediates, final: dcsFinal)
        case .ground where utf8Remaining > 0:
            utf8Remaining = 0
            emitScalar(0xFFFD, h)
        default: break
        }
    }

    private func clear() {
        if !intermediates.isEmpty { intermediates.removeAll(keepingCapacity: true) }
        nValues = 0; nGroups = 0
    }

    private func param(_ b: UInt8) {
        if nGroups == 0 { paramValues[0] = 0; nValues = 1; paramEnds[0] = 1; nGroups = 1 }
        switch b {
        case 0x3B: // ;
            if nGroups < Parser.maxParams { paramValues[nValues] = 0; nValues += 1; paramEnds[nGroups] = nValues; nGroups += 1 }
        case 0x3A: // : sub-parameter
            let g = nGroups - 1
            let size = paramEnds[g] - (g == 0 ? 0 : paramEnds[g - 1])
            if size < 8 { paramValues[nValues] = 0; nValues += 1; paramEnds[g] = nValues }
        default: // digit
            let last = nValues - 1
            paramValues[last] = min(paramValues[last] &* 10 &+ Int(b - 0x30), 65535)
        }
    }

    private func dispatchCSI(_ final: UInt8, _ h: ParserHandler) {
        h.csiDispatch(params: params, intermediates: intermediates, final: final)
        state = .ground
    }
}
