/// VT-series escape sequence parser.
///
/// Implements the state machine from https://vt100.net/emu/dec_ansi_parser —
/// the same reference Ghostty's `src/terminal/Parser.zig` is built from.
/// Bytes go in, semantic *actions* (print/execute/csi/esc/osc) come out via
/// `ParserHandler`. The parser itself holds no screen state.
public protocol ParserHandler: AnyObject {
    func print(_ scalar: Unicode.Scalar)
    func execute(_ byte: UInt8)
    /// `params` are parameter groups: `;` starts a group, `:` adds a sub-parameter.
    func csiDispatch(params: [[Int]], intermediates: [UInt8], final: UInt8)
    func escDispatch(intermediates: [UInt8], final: UInt8)
    func oscDispatch(_ data: [UInt8])
    func dcsDispatch(_ data: [UInt8], intermediates: [UInt8], final: UInt8)
}

public extension ParserHandler {
    func dcsDispatch(_ data: [UInt8], intermediates: [UInt8], final: UInt8) {}
}

/// Optional fast path: receive whole runs of printable ASCII at once
/// (Ghostty does the equivalent with SIMD-decoded slices in stream.zig).
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

    private var intermediates: [UInt8] = []
    private var params: [[Int]] = []
    private var oscBuffer: [UInt8] = []
    private var dcsBuffer: [UInt8] = []
    private var dcsFinal: UInt8 = 0

    // UTF-8 decoder state (ground state only)
    private var utf8Remaining = 0
    private var utf8Codepoint: UInt32 = 0

    static let maxParams = 32
    static let maxOSC = 1 << 20

    public init() {}

    public func feed<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        for b in bytes { advance(b) }
    }

    public func feed(_ buffer: UnsafeBufferPointer<UInt8>) {
        var i = 0
        let n = buffer.count
        while i < n {
            // Fast path: plain printable ASCII in ground state (Ghostty does the
            // same with SIMD in stream.zig: decode until next control sequence).
            if state == .ground && utf8Remaining == 0, let h = handler {
                let start = i
                while i < n, buffer[i] >= 0x20, buffer[i] < 0x7F { i += 1 }
                if i > start {
                    if let fast = h as? ASCIIRunHandler {
                        fast.printASCII(UnsafeBufferPointer(rebasing: buffer[start..<i]))
                    } else {
                        for j in start..<i { h.print(Unicode.Scalar(buffer[j])) }
                    }
                }
                if i == n { return }
            }
            advance(buffer[i])
            i += 1
        }
    }

    public func advance(_ b: UInt8) {
        // --- UTF-8 handling in ground state ---
        if state == .ground {
            if utf8Remaining > 0 {
                if b & 0xC0 == 0x80 {
                    utf8Codepoint = (utf8Codepoint << 6) | UInt32(b & 0x3F)
                    utf8Remaining -= 1
                    if utf8Remaining == 0 { emitScalar(utf8Codepoint) }
                    return
                }
                // Invalid continuation: emit replacement and reprocess byte.
                utf8Remaining = 0
                emitScalar(0xFFFD)
            }
            if b >= 0x80 {
                switch b {
                case 0xC2...0xDF: utf8Remaining = 1; utf8Codepoint = UInt32(b & 0x1F)
                case 0xE0...0xEF: utf8Remaining = 2; utf8Codepoint = UInt32(b & 0x0F)
                case 0xF0...0xF4: utf8Remaining = 3; utf8Codepoint = UInt32(b & 0x07)
                default: emitScalar(0xFFFD)
                }
                return
            }
        }

        // --- "anywhere" transitions ---
        switch b {
        case 0x18, 0x1A: // CAN, SUB
            leaveState()
            handler?.execute(b)
            state = .ground
            return
        case 0x1B:
            leaveState()
            clear()
            state = .escape
            return
        default: break
        }

        switch state {
        case .ground:
            if b < 0x20 { handler?.execute(b) }
            else if b < 0x7F { handler?.print(Unicode.Scalar(b)) }

        case .escape:
            switch b {
            case 0x00...0x1F: handler?.execute(b)
            case 0x20...0x2F: intermediates.append(b); state = .escapeIntermediate
            case 0x5B: clear(); state = .csiEntry          // [
            case 0x5D: oscBuffer.removeAll(keepingCapacity: true); state = .oscString // ]
            case 0x50: clear(); state = .dcsEntry          // P
            case 0x58, 0x5E, 0x5F: state = .sosPmApcString // X ^ _
            case 0x30...0x7E: handler?.escDispatch(intermediates: intermediates, final: b); state = .ground
            default: break
            }

        case .escapeIntermediate:
            switch b {
            case 0x00...0x1F: handler?.execute(b)
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x7E: handler?.escDispatch(intermediates: intermediates, final: b); state = .ground
            default: break
            }

        case .csiEntry:
            switch b {
            case 0x00...0x1F: handler?.execute(b)
            case 0x20...0x2F: intermediates.append(b); state = .csiIntermediate
            case 0x30...0x3B: param(b); state = .csiParam
            case 0x3C...0x3F: intermediates.append(b); state = .csiParam // private marker
            case 0x40...0x7E: dispatchCSI(b)
            default: break
            }

        case .csiParam:
            switch b {
            case 0x00...0x1F: handler?.execute(b)
            case 0x30...0x3B: param(b)
            case 0x3C...0x3F: state = .csiIgnore
            case 0x20...0x2F: intermediates.append(b); state = .csiIntermediate
            case 0x40...0x7E: dispatchCSI(b)
            default: break
            }

        case .csiIntermediate:
            switch b {
            case 0x00...0x1F: handler?.execute(b)
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x3F: state = .csiIgnore
            case 0x40...0x7E: dispatchCSI(b)
            default: break
            }

        case .csiIgnore:
            switch b {
            case 0x00...0x1F: handler?.execute(b)
            case 0x40...0x7E: state = .ground
            default: break
            }

        case .oscString:
            if b == 0x07 { // BEL terminator (xterm)
                handler?.oscDispatch(oscBuffer)
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

    private func emitScalar(_ cp: UInt32) {
        handler?.print(Unicode.Scalar(cp) ?? "\u{FFFD}")
    }

    /// Exit actions run when leaving a string state (e.g. ESC \ terminating OSC).
    private func leaveState() {
        switch state {
        case .oscString: handler?.oscDispatch(oscBuffer)
        case .dcsPassthrough: handler?.dcsDispatch(dcsBuffer, intermediates: intermediates, final: dcsFinal)
        case .ground where utf8Remaining > 0:
            utf8Remaining = 0
            emitScalar(0xFFFD)
        default: break
        }
    }

    private func clear() {
        intermediates.removeAll(keepingCapacity: true)
        params.removeAll(keepingCapacity: true)
    }

    private func param(_ b: UInt8) {
        if params.isEmpty { params.append([0]) }
        switch b {
        case 0x3B: // ;
            if params.count < Parser.maxParams { params.append([0]) }
        case 0x3A: // : sub-parameter
            if params[params.count - 1].count < 8 { params[params.count - 1].append(0) }
        default: // digit
            let g = params.count - 1
            let s = params[g].count - 1
            params[g][s] = min(params[g][s] &* 10 &+ Int(b - 0x30), 65535)
        }
    }

    private func dispatchCSI(_ final: UInt8) {
        handler?.csiDispatch(params: params, intermediates: intermediates, final: final)
        state = .ground
    }
}
