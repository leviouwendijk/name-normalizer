import Foundation
import Darwin

// ========= Global SIGINT handler =========
fileprivate final class _TermiosStore: @unchecked Sendable {
    var hasSaved = false
    var saved    = termios()
}
fileprivate let _store = _TermiosStore()

@_cdecl("nn_sigint_handler")
fileprivate func nn_sigint_handler(_ signo: Int32) {
    if _store.hasSaved {
        var t = _store.saved
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }
    // Show cursor + leave alternate screen (async-signal-safe write)
    let seq = "\u{1B}[?25h\u{1B}[?1049l"
    _ = seq.withCString { cstr in write(STDERR_FILENO, cstr, strlen(cstr)) }
    _exit(130) // standard SIGINT exit code
}

// ========= RAII guard that manages screen + SIGINT =========
fileprivate final class TerminalSessionGuard {
    private let fd: Int32 = STDIN_FILENO
    private var saved = termios()

    init() {
        // Save cooked settings and publish for handler
        tcgetattr(fd, &saved)
        _store.saved = saved
        _store.hasSaved = true

        // Enter alternate screen & hide cursor
        fputs("\u{1B}[?1049h\u{1B}[?25l", stderr)
        fflush(stderr)

        // Install SIGINT handler
        var act = sigaction()
        sigemptyset(&act.sa_mask)
        act.sa_flags = 0
        act.__sigaction_u.__sa_handler = nn_sigint_handler
        sigaction(SIGINT, &act, nil)
    }

    deinit {
        // Restore terminal settings
        var t = saved
        tcsetattr(fd, TCSANOW, &t)

        // Show cursor & leave alternate screen
        fputs("\u{1B}[?25h\u{1B}[?1049l", stderr)
        fflush(stderr)
    }
}

// ========= TUI =========

public struct FileSelectTUI {
    public let files: [FileInfo]
    public var selected: Set<Int> = []
    public var currentIndex: Int = 0

    // redraw cache
    private var lastDrawnIndex: Int = -1
    private var lastDrawnSelection = Set<Int>()

    public init(files: [FileInfo]) { self.files = files }

    public mutating func present() async throws -> [FileInfo] {
        guard !files.isEmpty else { return [] }

        // RAII: restores TTY + screen; leaves SIGINT handler active
        let _ = TerminalSessionGuard()

        try displayMenu(force: true)

        while true {
            let key = readKey()
            if !handleKey(key) { break }
            try displayMenu()
        }

        return selected.sorted().map { files[$0] }
    }

    // Drawing
    // Terminal width (fallback 80 if unknown)
    @inline(__always)
    private func terminalColumns() -> Int {
        var ws = winsize()
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }

    private func renderLegendLines(maxWidth: Int, spacing: String = "   ") -> [String] {
        let chips = [
            "Move: ↑ / k, ↓ / j, ^P / ^N",
            "Toggle: Space / ^Space",
            "All: ^A",
            "Confirm: Enter",
            "Quit: q / ^C"
        ]
        var lines: [String] = []
        var current = ""

        for chip in chips {
            if current.isEmpty {
                current = chip
            } else if current.count + spacing.count + chip.count <= maxWidth {
                current += spacing + chip
            } else {
                lines.append(current)
                current = chip
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private mutating func displayMenu(force: Bool = false) throws {
        if !force, lastDrawnIndex == currentIndex, lastDrawnSelection == selected { return }
        lastDrawnIndex = currentIndex
        lastDrawnSelection = selected

        let cols = terminalColumns()

        // Clear + home
        fputs("\u{1B}[2J\u{1B}[H", stderr)

        // Header
        fputs("\u{1B}[1mSelect files to rename\u{1B}[0m\n", stderr)

        // Legend (dim, auto-wrapped)
        let legendLines = renderLegendLines(maxWidth: max(40, cols - 2))
        fputs("\u{1B}[2m", stderr) // dim
        for line in legendLines {
            fputs(line + "\n", stderr)
        }
        fputs("\u{1B}[0m\n", stderr) // reset + blank line

        // List
        for (index, file) in files.enumerated() {
            let isSelected = selected.contains(index)
            let isCurrent  = index == currentIndex
            let marker     = isSelected ? "✓" : " "
            let prefix     = isCurrent ? ">" : " "

            if isCurrent { fputs("\u{1B}[7m", stderr) } // inverse
            fputs("\(prefix) [\(marker)] \(file.filename)\n", stderr)
            if isCurrent { fputs("\u{1B}[0m", stderr) }
        }

        fflush(stderr)
    }

    // Input

    private enum Key { case up, down, enter, toggle, toggleAll, quit, other }

    private func readKey() -> Key {
        var cooked = termios()
        var raw    = termios()
        let fd = STDIN_FILENO

        // Refresh saved cooked state for handler
        tcgetattr(fd, &cooked)
        _store.saved = cooked
        _store.hasSaved = true

        raw = cooked
        cfmakeraw(&raw)

        // Keep signals so ^C delivers SIGINT; still disable echo/canonical
        raw.c_lflag |= tcflag_t(ISIG)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)

        // Block for exactly one byte
        withUnsafeMutablePointer(to: &raw.c_cc) { ccp in
            ccp.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)]  = 1
                cc[Int(VTIME)] = 0
            }
        }

        tcsetattr(fd, TCSANOW, &raw)

        var b0: UInt8 = 0
        let n = read(fd, &b0, 1)

        // Restore cooked immediately after read
        tcsetattr(fd, TCSANOW, &cooked)

        guard n > 0 else { return .other }

        switch b0 {
        case 0x03: return .quit                 // ^C (fallback if ISIG off)
        case 0x01: return .toggleAll            // ^A
        case 0x6B: return .up                   // 'k'
        case 0x6A: return .down                 // 'j'
        case 0x10: return .up                   // ^P
        case 0x0E: return .down                 // ^N
        case 0x00, 0x20: return .toggle         // ^Space (NUL) or Space
        case 0x0D, 0x0A: return .enter          // CR/LF
        case 0x71, 0x51: return .quit           // q/Q
        case 0x1B:
            // Nonblocking drain to recognize ESC [ A/B (arrows)
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            defer { _ = fcntl(fd, F_SETFL, flags) }

            var rest = [UInt8](repeating: 0, count: 8)
            let m = read(fd, &rest, rest.count)
            if m >= 2 && rest[0] == 0x5B {
                switch rest[1] {
                case 0x41: return .up
                case 0x42: return .down
                default: break
                }
            }
            return .other
        default:
            return .other
        }
    }

    // State
    private mutating func handleKey(_ key: Key) -> Bool {
        switch key {
        case .up:
            currentIndex = (currentIndex - 1 + files.count) % files.count
            return true
        case .down:
            currentIndex = (currentIndex + 1) % files.count
            return true
        case .toggle:
            if selected.contains(currentIndex) { selected.remove(currentIndex) }
            else { selected.insert(currentIndex) }
            return true
        case .toggleAll:
            if selected.count == files.count { selected.removeAll() }
            else { selected = Set(files.indices) }
            return true
        case .enter:
            return false
        case .quit:
            selected.removeAll()
            return false
        case .other:
            return true
        }
    }
}
