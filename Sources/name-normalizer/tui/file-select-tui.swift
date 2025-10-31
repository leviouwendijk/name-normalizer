import Foundation
import Darwin
import plate

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
    public let style: CaseStyle
    public let separators: SeparatorPolicy
    private var filters: [String]
    
    public init(
        files: [FileInfo],
        style: CaseStyle,
        separators: SeparatorPolicy,
        initialFilters: [String]
    ) {
        self.files = files
        self.style = style
        self.separators = separators
        self.filters = initialFilters
    }

    public var selected: Set<Int> = []
    public var currentIndex: Int = 0

    // redraw cache
    private var lastDrawnIndex: Int = -1
    private var lastDrawnSelection = Set<Int>()
    private var lastDrawnFilters: [String] = []

    // new additions
    private enum Mode { case list, filterInput }

    public struct SelectionResult { 
        public let files: [FileInfo]
        public let filters: [String] 
    }

    // public mutating func present() async throws -> [FileInfo] {
    public mutating func present() async throws -> SelectionResult {
        guard !files.isEmpty else { return .init(files: [], filters: []) }

        // RAII: restores TTY + screen; leaves SIGINT handler active
        let _ = TerminalSessionGuard()

        try displayMenu(force: true)

        var mode: Mode = .list
        var inputBuffer = ""

        while true {
            let key = readKey()
            switch mode {
            case .list:
                if key == .startFilter {
                    mode = .filterInput
                    inputBuffer = filters.joined(separator: ", ")
                    try displayMenu(force: true, filterBuffer: inputBuffer, inFilterMode: true)
                    continue
                }
                if !handleListKey(key) {
                    // Enter or Quit from list mode — finish the TUI.
                    return .init(files: selected.sorted().map { files[$0] }, filters: filters)
                }
                try displayMenu()
            case .filterInput:
                let cont = handleFilterKey(
                    key,
                    buffer: &inputBuffer,
                    applied: { new in
                        self.filters = Self.parseFilters(new)
                    },
                    cancelled: {
                    }
                )
                if !cont {
                    // leave filter mode -> back to list
                    mode = .list
                }
                try displayMenu(force: true, filterBuffer: inputBuffer, inFilterMode: mode == .filterInput)
            }
         }
 
        return .init(files: selected.sorted().map { files[$0] }, filters: filters)
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
            "Filter: ^F",
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

    // private mutating func displayMenu(force: Bool = false) throws {
    private mutating func displayMenu(force: Bool = false, filterBuffer: String? = nil, inFilterMode: Bool = false) throws {
        if !force, 
            lastDrawnIndex == currentIndex, 
            lastDrawnSelection == selected,
            lastDrawnFilters == filters { return }

        lastDrawnIndex = currentIndex
        lastDrawnSelection = selected
        lastDrawnFilters = filters // adding

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

        // fputs("\u{1B}[0m\n", stderr) // reset + blank line
        fputs("\u{1B}[0m", stderr) // reset

        // Filters row
        fputs("\n", stderr)
        fputs("\u{1B}[2mFilters:\u{1B}[0m ", stderr)
        if filters.isEmpty {
            fputs("(none)  ", stderr)
        } else {
            fputs(filters.joined(separator: ", "), stderr)
            fputs("  ", stderr)
        }
        fputs("\u{1B}[2m(press ^F to edit)\u{1B}[0m\n\n", stderr)

        // List
        for (index, file) in files.enumerated() {
            let isSelected = selected.contains(index)
            let isCurrent  = index == currentIndex
            let marker     = isSelected ? "✓" : " "
            let prefix     = isCurrent ? ">" : " "

            // if isCurrent { fputs("\u{1B}[7m", stderr) } // inverse
            // fputs("\(prefix) [\(marker)] \(file.filename)\n", stderr)
            // if isCurrent { fputs("\u{1B}[0m", stderr) }
        // }
            // Name with inline highlights for matched parts
            let colored = highlightMatches(in: file.filename, parts: filters, isCurrent: isCurrent)
            // Right-hand preview (filtered → case-converted)
            let preview = previewName(for: file)

            if isCurrent { fputs("\u{1B}[7m", stderr) } // inverse
            fputs("\(prefix) [\(marker)] ", stderr)
            fputs(colored, stderr)
            if isCurrent { fputs("\u{1B}[27m", stderr) } // end inverse only

            // faint arrow + preview
            fputs("  \u{1B}[2m→ \(preview)\u{1B}[0m\n", stderr)
         }
 
        // Filter input surface (if active)
        if inFilterMode {
            fputs("\n\u{1B}[1mFilter (comma-separated):\u{1B}[0m ", stderr)
            fputs(filterBuffer ?? "", stderr)
            fputs("\n\u{1B}[2mEnter to apply • Esc to cancel • Backspace to delete\u{1B}[0m\n", stderr)
        }

        fflush(stderr)
    }

    // Input

    // private enum Key { case up, down, enter, toggle, toggleAll, quit, other }
    private enum Key: Equatable {
        case up, down, enter, toggle, toggleAll, quit, startFilter
        case char(Character), backspace, escape, other
    }

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
        case 0x06: return .startFilter          // ^F
        case 0x6B: return .up                   // 'k'
        case 0x6A: return .down                 // 'j'
        case 0x10: return .up                   // ^P
        case 0x0E: return .down                 // ^N
        case 0x00, 0x20: return .toggle         // ^Space (NUL) or Space
        // case 0x0D, 0x0A: return .enter          // CR/LF
        case 0x0D, 0x0A:
            // Swallow an immediately following paired newline (CRLF or LFCR),
            // so a single physical Enter isn’t seen as two logical enters.
            let fd = STDIN_FILENO
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            defer { _ = fcntl(fd, F_SETFL, flags) }
            var peek: UInt8 = 0
            if read(fd, &peek, 1) == 1 {
                if (b0 == 0x0D && peek != 0x0A) && (b0 == 0x0A && peek != 0x0D) {
                    // Not the matching pair; push back behavior isn't available,
                    // so we just ignore the extra char if it's unrelated.
                }
            }
            return .enter
        case 0x71, 0x51: return .quit           // q/Q
        case 0x7F: return .backspace            // DEL
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
            // return .other
            return .escape
        default:
            if b0 >= 0x20 && b0 <= 0x7E {
                return .char(Character(UnicodeScalar(b0)))
            } else {
                return .other
            }
            // return .other
        }
    }

    // State
    // private mutating func handleKey(_ key: Key) -> Bool {
    private mutating func handleListKey(_ key: Key) -> Bool {
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
        // case .other:
        //     return true
        default:
            return true
        }
    }

    // Filter-mode keystrokes. Returns whether we remain in filter mode.
    private func handleFilterKey(
        _ key: Key,
        buffer: inout String,
        applied: (String) -> Void,
        cancelled: () -> Void
    ) -> Bool {
        switch key {
        case .enter:
            applied(buffer)
            return false
        case .escape, .quit:
            cancelled()
            return false
        case .backspace:
            if !buffer.isEmpty { buffer.removeLast() }
            return true
        case .char(let c):
            buffer.append(c)
            return true
        default:
            return true
        }
    }

    private static func parseFilters(_ s: String) -> [String] {
        s.split(separator: ",")
         .map { $0.trimmingCharacters(in: .whitespaces) }
         .filter { !$0.isEmpty }
    }

    // === Rendering helpers ===
    private func previewName(for file: FileInfo) -> String {
        var base = file.nameWithoutExtension
        if !filters.isEmpty {
            base = filterParts(in: base, parts: filters)
        }
        let converted = convertIdentifier(base, to: style, separators: separators)
        return converted + file.extensionWithDot
    }

    /// Inline-highlight matched parts inside the given string.
    /// For the current row (inverse), underline the matches; for others, tint them with default fg color changes.
    private func highlightMatches(in s: String, parts: [String], isCurrent: Bool) -> String {
        guard !parts.isEmpty else { return s }
        // Find all case-insensitive ranges to decorate.
        let lower = s.lowercased()
        var marks = Array(repeating: false, count: s.unicodeScalars.count)
        let scalars = Array(s.unicodeScalars)
        let lowerScalars = Array(lower.unicodeScalars)

        func markRange(start: Int, length: Int) {
            guard start >= 0, length > 0, start + length <= marks.count else { return }
            for i in start..<(start+length) { marks[i] = true }
        }
        // Naive scan for each part.
        for p in parts where !p.isEmpty {
            let pSc = Array(p.lowercased().unicodeScalars)
            if pSc.isEmpty { continue }
            var i = 0
            while i + pSc.count <= lowerScalars.count {
                var ok = true
                for j in 0..<pSc.count {
                    if lowerScalars[i+j] != pSc[j] { ok = false; break }
                }
                if ok {
                    markRange(start: i, length: pSc.count)
                    i += pSc.count
                } else {
                    i += 1
                }
            }
        }

        // Rebuild with SGR spans
        var out = ""
        var i = 0
        var inSpan = false
        while i < scalars.count {
            if marks[i] && !inSpan {
                // Start decoration
                if isCurrent {
                    out += "\u{1B}[4m"       // underline within inverse block
                } else {
                    out += "\u{1B}[1m\u{1B}[33m" // bold + yellow
                }
                inSpan = true
            } else if !marks[i] && inSpan {
                // End decoration
                if isCurrent { out += "\u{1B}[24m" } // end underline
                else { out += "\u{1B}[22m\u{1B}[39m" } // normal weight + default fg
                inSpan = false
            }
            out.unicodeScalars.append(scalars[i])
            i += 1
        }
        if inSpan {
            if isCurrent { out += "\u{1B}[24m" }
            else { out += "\u{1B}[22m\u{1B}[39m" }
        }
        return out
    }
}
