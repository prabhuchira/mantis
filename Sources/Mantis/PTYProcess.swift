import Foundation
import CPTY
import MantisCore

/// Owns the child process + pty and the IO threads.
/// A reader thread drains the pty; a writer thread sends input to it.
///
///   reader thread : read(master) → lock → terminal.feed() → unlock → onOutput()
///   writer queue  : serial queue doing blocking write(master) so big pastes
///                   never stall the UI thread.
final class PTYProcess {
    let terminal: Terminal
    private(set) var pid: pid_t = -1
    private(set) var masterFD: Int32 = -1
    private let writeQueue = DispatchQueue(label: "mantis.pty.writer")
    private var readerThread: Thread?

    /// Called on the reader thread after each chunk is parsed.
    var onOutput: (() -> Void)?
    /// Called on the reader thread when the child exits (exit status).
    var onExit: ((Int32) -> Void)?

    init(terminal: Terminal) { self.terminal = terminal }

    func start(config: Config, cols: Int, rows: Int) throws {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent

        // Build argv/envp *before* fork: the child must only make async-signal-safe calls.
        var argv: [String]
        if let cmd = config.command {
            argv = [shell, "-l", "-c", cmd]
        } else {
            argv = ["-" + shellName] // leading '-' = login shell (like Terminal.app)
        }
        var envDict = env
        envDict["TERM"] = "xterm-256color"
        envDict["COLORTERM"] = "truecolor"
        envDict["TERM_PROGRAM"] = "Mantis"
        envDict["TERM_PROGRAM_VERSION"] = "0.1.0"
        if envDict["LANG"] == nil { envDict["LANG"] = "en_US.UTF-8" }
        envDict.removeValue(forKey: "TERMINFO") // don't inherit a parent terminal's terminfo
        if config.shellColors { ShellColors.apply(to: &envDict, shell: shell) }
        let cwd = config.workingDirectory ?? NSHomeDirectory()

        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = envDict.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgv.forEach { free($0) }; cEnv.forEach { free($0) } }

        var master: Int32 = -1
        let p = cArgv.withUnsafeBufferPointer { a in
            cEnv.withUnsafeBufferPointer { e in
                cpty_spawn(shell, a.baseAddress, e.baseAddress, cwd, UInt16(rows), UInt16(cols), &master)
            }
        }
        guard p > 0 else { throw NSError(domain: "Mantis", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "forkpty failed: \(String(cString: strerror(errno)))"]) }
        pid = p
        masterFD = master

        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "mantis.pty.reader"
        t.qualityOfService = .userInteractive
        readerThread = t
        t.start()
    }

    private func readLoop() {
        let size = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        let fd = masterFD
        while true {
            let n = read(fd, buf, size)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break } // EIO once the child side closes
            terminal.lock.lock()
            terminal.feed(UnsafeBufferPointer(start: buf, count: n))
            terminal.lock.unlock()
            onOutput?()
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        onExit?(code)
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeQueue.async { [fd = masterFD] in
            guard fd >= 0 else { return }
            var off = 0
            bytes.withUnsafeBytes { raw in
                while off < bytes.count {
                    let w = Darwin.write(fd, raw.baseAddress! + off, bytes.count - off)
                    if w < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                    off += w
                }
            }
        }
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        guard masterFD >= 0 else { return }
        _ = cpty_set_size(masterFD, UInt16(rows), UInt16(cols), UInt16(clamping: pixelWidth), UInt16(clamping: pixelHeight))
    }

    /// True if something other than the shell is running in the foreground (for close confirmation).
    var hasForegroundJob: Bool {
        guard masterFD >= 0, pid > 0 else { return false }
        let fg = cpty_foreground_pid(masterFD)
        return fg > 0 && fg != pid
    }

    /// Working directory of the foreground job (or the shell) — used to resolve relative paths.
    var currentDirectory: String? {
        var pids: [pid_t] = []
        if masterFD >= 0 { let fg = cpty_foreground_pid(masterFD); if fg > 0 { pids.append(fg) } }
        if pid > 0 { pids.append(pid) }
        for p in pids {
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if cpty_process_cwd(p, &buf, Int32(buf.count)) == 0 { return String(cString: buf) }
        }
        return nil
    }

    func terminate() {
        if pid > 0 { kill(pid, SIGHUP) }
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
    }

    deinit { terminate() }
}
