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

    private var prefix: String
    private var suffix: String
    
    public init(
        files: [FileInfo],
        style: CaseStyle,
        separators: SeparatorPolicy,
        initialFilters: [String],
        initialPrefix: String,
        initialSuffix: String
    ) {
        self.files = files
        self.style = style
        self.separators = separators
        self.filters = initialFilters
        self.prefix = initialPrefix
        self.suffix = initialSuffix
    }

    public var selected: Set<Int> = []
    public var currentIndex: Int = 0

    // redraw cache
    private var lastDrawnIndex: Int = -1
    private var lastDrawnSelection = Set<Int>()
    private var lastDrawnFilters: [String] = []
    private var lastDrawnSurface: InputSurface = .none
    private var lastDrawnPrefix: String = ""
    private var lastDrawnSuffix: String = ""
    private var lastDrawnCols: Int = 0

    private enum InputSurface: Equatable {
        case none
        case filter(buffer: String)
        case modify(field: ModifyField, buffer: String)
    }

    private enum ModifyField: Equatable {
        case prefix
        case suffix

        var title: String {
            switch self {
            case .prefix: return "Prefix"
            case .suffix: return "Suffix"
            }
        }
    }

    public struct SelectionResult { 
        public let files: [FileInfo]
        public let filters: [String] 
        public let prefix: String
        public let suffix: String
    }

    public mutating func present() async throws -> SelectionResult {
        guard !files.isEmpty else { 
            return .init(
                files: [],
                filters: [],
                prefix: "",
                suffix: ""
            ) 
        }

        // RAII: restores TTY + screen; leaves SIGINT handler active
        let _ = TerminalSessionGuard()

        try displayMenu(force: true, surface: .none)

        var surface: InputSurface = .none
        var inputBuffer = ""

        while true {
            // let key = readKey()
            let key = readKey(textInputActive: surface != .none)

            switch surface {
            case .none:
                if key == .startFilter {
                    inputBuffer = filters.joined(separator: ", ")
                    surface = .filter(buffer: inputBuffer)
                    try displayMenu(force: true, surface: surface)
                    continue
                }

                if key == .startPrefix {
                    inputBuffer = prefix
                    surface = .modify(field: .prefix, buffer: inputBuffer)
                    try displayMenu(force: true, surface: surface)
                    continue
                }

                if key == .startSuffix {
                    inputBuffer = suffix
                    surface = .modify(field: .suffix, buffer: inputBuffer)
                    try displayMenu(force: true, surface: surface)
                    continue
                }

                if !handleListKey(key) {
                    return .init(
                        files: selected.sorted().map { files[$0] },
                        filters: filters,
                        prefix: prefix,
                        suffix: suffix
                    )
                }

                try displayMenu(surface: .none)

            case .filter:
                let cont = handleFilterKey(
                    key,
                    buffer: &inputBuffer,
                    applied: { new in self.filters = Self.parseFilters(new) },
                    cancelled: {}
                )

                surface = cont ? .filter(buffer: inputBuffer) : .none
                try displayMenu(force: true, surface: surface)

            case .modify(let field, _):
                let cont = handleModifyInputKey(key, buffer: &inputBuffer, field: field)

                surface = cont ? .modify(field: field, buffer: inputBuffer) : .none
                try displayMenu(force: true, surface: surface)
            }
        }

        return .init(
            files: selected.sorted().map { files[$0] },
            filters: filters,
            prefix: prefix,
            suffix: suffix
        )
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
            "Prefix: ^T",
            "Suffix: ^Y",
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

    private mutating func displayMenu(
        force: Bool = false,
        surface: InputSurface = .none
    ) throws {
        let cols = terminalColumns()

        if !force,
            lastDrawnCols == cols,
            lastDrawnIndex == currentIndex,
            lastDrawnSelection == selected,
            lastDrawnFilters == filters,
            lastDrawnPrefix == prefix,
            lastDrawnSuffix == suffix,
            lastDrawnSurface == surface {
            return
        }

        lastDrawnCols = cols
        lastDrawnIndex = currentIndex
        lastDrawnSelection = selected
        lastDrawnFilters = filters
        lastDrawnSurface = surface
        lastDrawnPrefix = prefix
        lastDrawnSuffix = suffix

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

        fputs("\u{1B}[2mModifiers:\u{1B}[0m ", stderr)
        let p = prefix.isEmpty ? "(none)" : prefix
        let s = suffix.isEmpty ? "(none)" : suffix
        fputs("prefix=\(p)  suffix=\(s)\n", stderr)

        // List
        for (index, file) in files.enumerated() {
            let isSelected = selected.contains(index)
            let isCurrent  = index == currentIndex
            let marker     = isSelected ? "✓" : " "
            let rowPrefix     = isCurrent ? ">" : " "

            // Name with inline highlights for matched parts
            let colored = highlightMatches(in: file.filename, parts: filters, isCurrent: isCurrent)
            // Right-hand preview (filtered → case-converted)
            let preview = previewName(for: file)

            if isCurrent { fputs("\u{1B}[7m", stderr) } // inverse
            fputs("\(rowPrefix) [\(marker)] ", stderr)
            fputs(colored, stderr)
            if isCurrent { fputs("\u{1B}[27m", stderr) } // end inverse only

            // faint arrow + preview
            fputs("  \u{1B}[2m→ \(preview)\u{1B}[0m\n", stderr)
         }
 
        switch surface {
        case .none:
            break

        case .filter(let buffer):
            fputs("\n\u{1B}[1mFilter (comma-separated):\u{1B}[0m ", stderr)
            fputs(buffer, stderr)
            fputs("\n\u{1B}[2mEnter to apply • Esc to cancel • Backspace to delete\u{1B}[0m\n", stderr)

        case .modify(let field, let buffer):
            fputs("\n\u{1B}[1m\(field.title):\u{1B}[0m ", stderr)
            fputs(buffer, stderr)
            fputs("\n\u{1B}[2mEnter to apply • Esc to cancel • Backspace to delete\u{1B}[0m\n", stderr)
        }

        fflush(stderr)
    }

    // Input

    private enum Key: Equatable {
        case up, down
        case enter
        case toggle
        case toggleAll
        case quit
        case startFilter
        case startPrefix
        case startSuffix

        case char(Character)
        case backspace
        case escape
        case other
    }

    // private func readKey(textInputActive: Bool = false) -> Key {
    private func readKey(textInputActive: Bool) -> Key {
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

        func swallowPairedNewline(after first: UInt8) {
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            defer { _ = fcntl(fd, F_SETFL, flags) }

            var peek: UInt8 = 0
            if read(fd, &peek, 1) == 1 {
                // No pushback available. Only intended to consume CRLF/LFCR pairs.
                _ = peek
            }
        }

        func readEscape(textInputActive: Bool) -> Key {
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            defer { _ = fcntl(fd, F_SETFL, flags) }

            var rest = [UInt8](repeating: 0, count: 8)
            let m = read(fd, &rest, rest.count)

            if m >= 2 && rest[0] == 0x5B {
                switch rest[1] {
                case 0x41:
                    return textInputActive ? .other : .up
                case 0x42:
                    return textInputActive ? .other : .down
                default:
                    return .other
                }
            }

            return .escape
        }

        if textInputActive {
            switch b0 {
            case 0x03:
                return .quit                 // ^C fallback
            case 0x0D, 0x0A:
                swallowPairedNewline(after: b0)
                return .enter
            case 0x7F, 0x08:
                return .backspace            // DEL or BS
            case 0x1B:
                return readEscape(textInputActive: true)
            case 0x00:
                return .other                // ^Space/NUL, not text
            default:
                if b0 >= 0x20 && b0 <= 0x7E {
                    return .char(Character(UnicodeScalar(b0)))
                } else {
                    return .other
                }
            }
        }

        switch b0 {
        case 0x03:
            return .quit                 // ^C fallback
        case 0x01:
            return .toggleAll            // ^A
        case 0x06:
            return .startFilter          // ^F
        case 0x14:
            return .startPrefix          // ^T
        case 0x19:
            return .startSuffix          // ^Y
        case 0x6B:
            return .up                   // k
        case 0x6A:
            return .down                 // j
        case 0x10:
            return .up                   // ^P
        case 0x0E:
            return .down                 // ^N
        case 0x00, 0x20:
            return .toggle               // ^Space or Space
        case 0x0D, 0x0A:
            swallowPairedNewline(after: b0)
            return .enter
        case 0x71, 0x51:
            return .quit                 // q/Q
        case 0x7F, 0x08:
            return .backspace
        case 0x1B:
            return readEscape(textInputActive: false)
        default:
            if b0 >= 0x20 && b0 <= 0x7E {
                return .char(Character(UnicodeScalar(b0)))
            } else {
                return .other
            }
        }
    }

    // private func readKey() -> Key {
    //     var cooked = termios()
    //     var raw    = termios()
    //     let fd = STDIN_FILENO

    //     // Refresh saved cooked state for handler
    //     tcgetattr(fd, &cooked)
    //     _store.saved = cooked
    //     _store.hasSaved = true

    //     raw = cooked
    //     cfmakeraw(&raw)

    //     // Keep signals so ^C delivers SIGINT; still disable echo/canonical
    //     raw.c_lflag |= tcflag_t(ISIG)
    //     raw.c_lflag &= ~tcflag_t(ECHO | ICANON)

    //     // Block for exactly one byte
    //     withUnsafeMutablePointer(to: &raw.c_cc) { ccp in
    //         ccp.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
    //             cc[Int(VMIN)]  = 1
    //             cc[Int(VTIME)] = 0
    //         }
    //     }

    //     tcsetattr(fd, TCSANOW, &raw)

    //     var b0: UInt8 = 0
    //     let n = read(fd, &b0, 1)

    //     // Restore cooked immediately after read
    //     tcsetattr(fd, TCSANOW, &cooked)

    //     guard n > 0 else { return .other }

    //     switch b0 {
    //     case 0x03: return .quit                 // ^C (fallback if ISIG off)
    //     case 0x01: return .toggleAll            // ^A
    //     case 0x06: return .startFilter          // ^F

    //     case 0x14: return .startPrefix   // ^T
    //     case 0x19: return .startSuffix   // ^Y

    //     case 0x6B: return .up                   // 'k'
    //     case 0x6A: return .down                 // 'j'
    //     case 0x10: return .up                   // ^P
    //     case 0x0E: return .down                 // ^N
    //     case 0x00, 0x20: return .toggle         // ^Space (NUL) or Space
    //     // case 0x0D, 0x0A: return .enter          // CR/LF
    //     case 0x0D, 0x0A:
    //         // Swallow an immediately following paired newline (CRLF or LFCR),
    //         // so a single physical Enter isn’t seen as two logical enters.
    //         let fd = STDIN_FILENO
    //         let flags = fcntl(fd, F_GETFL)
    //         _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    //         defer { _ = fcntl(fd, F_SETFL, flags) }
    //         var peek: UInt8 = 0
    //         if read(fd, &peek, 1) == 1 {
    //             if (b0 == 0x0D && peek != 0x0A) && (b0 == 0x0A && peek != 0x0D) {
    //                 // Not the matching pair; push back behavior isn't available,
    //                 // so we just ignore the extra char if it's unrelated.
    //             }
    //         }
    //         return .enter
    //     case 0x71, 0x51: return .quit           // q/Q
    //     case 0x7F: return .backspace            // DEL
    //     case 0x1B:
    //         // Nonblocking drain to recognize ESC [ A/B (arrows)
    //         let flags = fcntl(fd, F_GETFL)
    //         _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    //         defer { _ = fcntl(fd, F_SETFL, flags) }

    //         var rest = [UInt8](repeating: 0, count: 8)
    //         let m = read(fd, &rest, rest.count)

    //         if m >= 2 && rest[0] == 0x5B {
    //             switch rest[1] {
    //             case 0x41: return .up
    //             case 0x42: return .down
    //             default: break
    //             }
    //         }

    //         // return .other
    //         return .escape
    //     default:
    //         if b0 >= 0x20 && b0 <= 0x7E {
    //             return .char(Character(UnicodeScalar(b0)))
    //         } else {
    //             return .other
    //         }
    //         // return .other
    //     }
    // }

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

    private mutating func handleModifyInputKey(
        _ key: Key,
        buffer: inout String,
        field: ModifyField
    ) -> Bool {
        switch key {
        case .enter:
            switch field {
            case .prefix:
                prefix = buffer
            case .suffix:
                suffix = buffer
            }
            return false

        case .escape, .quit:
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

    // === Rendering helpers ===
    private func previewName(for file: FileInfo) -> String {
        var base = file.nameWithoutExtension
        if !filters.isEmpty {
            base = filterParts(in: base, parts: filters)
        }
        let converted = convertIdentifier(base, to: style, separators: separators)
        // return converted + file.extensionWithDot
        return prefix + converted + suffix + file.extensionWithDot
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
