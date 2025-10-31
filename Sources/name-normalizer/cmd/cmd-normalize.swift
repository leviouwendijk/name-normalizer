import Foundation
import ArgumentParser
import plate

enum CaseStyleOption: String, ExpressibleByArgument {
    case snake
    case camel
    case pascal

    func toCaseStyle() -> CaseStyle {
        switch self {
        case .snake: return .snake
        case .camel: return .camel
        case .pascal: return .pascal
        }
    }
}

enum SeparatorOption: String, ExpressibleByArgument {
    case commonWithDot
    case commonNoDot
    case whitespaceOnly

    func toSeparatorPolicy() -> SeparatorPolicy {
        switch self {
        case .commonWithDot: return .commonWithDot
        case .commonNoDot: return .commonNoDot
        case .whitespaceOnly: return .whitespaceOnly
        }
    }
}

struct NormalizeName: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "normalize",
        abstract: "Normalize filenames in current directory.",
        aliases: []
    )

    @Argument(
        help: "Target case style: snake, camel, or pascal"
    )
    var style: CaseStyleOption = .snake

    @Option(
        name: [.short, .long],
        help: "Separator policy: commonWithDot, commonNoDot, or whitespaceOnly"
    )
    var separators: SeparatorOption = .commonNoDot

    @Flag(
        name: [.short, .long],
        help: "Apply to all files without prompting"
    )
    var all: Bool = false

    @Option(
        name: [.short, .long],
        help: "Path to file containing newline-separated filenames"
    )
    var list: String?

    @Option(
        name: [.short, .long],
        help: "Output directory (default: current directory)"
    )
    var output: String?

    @Flag(
        name: [.short, .long],
        help: "Dry run - show what would be renamed without making changes"
    )
    var dryRun: Bool = false

    @Flag(
        name: [.short, .long],
        help: "Allow overwriting existing files"
    )
    var force: Bool = false

    func run() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let outputDir = output ?? cwd
        
        let filesToProcess = try await getTargetFiles()
        
        guard !filesToProcess.isEmpty else {
            fputs("✗ No files to process.\n", stderr)
            return
        }

        let selectedFiles: [FileInfo]
        if all {
            selectedFiles = filesToProcess
        } else if list != nil {
            selectedFiles = filesToProcess
        } else {
            selectedFiles = try await selectFilesInteractive(filesToProcess)
        }

        guard !selectedFiles.isEmpty else {
            fputs("✗ No files selected.\n", stderr)
            return
        }

        try await processRenames(selectedFiles, outputDir: outputDir)
    }

    // Private Methods
    private func getTargetFiles() async throws -> [FileInfo] {
        let fm = FileManager.default
        let cwd = FileManager.default.currentDirectoryPath

        if let listPath = list {
            let resolvedPath =
                listPath.hasPrefix("/")
                ? listPath
                : (cwd + "/" + listPath)

            guard let content = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
                throw NameNormalizerError.cannotReadFile(resolvedPath)
            }

            let files = content
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .compactMap { filename -> FileInfo? in
                    let path = cwd + "/" + filename
                    guard fm.fileExists(atPath: path) else { return nil }
                    return FileInfo(path: path, filename: filename)
                }
            return files
        } else {
            let contents = try fm.contentsOfDirectory(atPath: cwd)
            let files = contents
                .filter { !$0.hasPrefix(".") } // Skip hidden files
                .compactMap { filename -> FileInfo? in
                    let path = cwd + "/" + filename
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir),
                          !isDir.boolValue else { return nil } // Skip directories
                    return FileInfo(path: path, filename: filename)
                }
            return files
        }
    }

    private func selectFilesInteractive(_ files: [FileInfo]) async throws -> [FileInfo] {
        var ui = FileSelectTUI(files: files)
        return try await ui.present()
    }

    private func processRenames(_ files: [FileInfo], outputDir: String) async throws {
        let fm = FileManager.default
        let caseStyle = style.toCaseStyle()
        let separatorPolicy = separators.toSeparatorPolicy()
        var results: [RenameResult] = []

        for file in files {
            let newName = convertIdentifier(
                file.nameWithoutExtension,
                to: caseStyle,
                separators: separatorPolicy
            ) + file.extensionWithDot

            let oldPath = file.path
            let newPath = outputDir + "/" + newName

            if dryRun {
                print("→ \(file.filename) → \(newName)")
                continue
            }

            do {
                if newPath != oldPath {
                    let shouldOverride = force || !fm.fileExists(atPath: newPath)
                    
                    if !shouldOverride && fm.fileExists(atPath: newPath) {
                        fputs("⚠ File exists (use --force to override): \(newName)\n", stderr)
                        continue
                    }

                    if outputDir == FileManager.default.currentDirectoryPath {
                        // Rename in place
                        try fm.moveItem(atPath: oldPath, toPath: newPath)
                    } else {
                        // Copy to output directory
                        try fm.copyItem(atPath: oldPath, toPath: newPath)
                    }
                    
                    print("✓ \(file.filename) → \(newName)")
                    results.append(RenameResult(
                        original: file.filename,
                        renamed: newName,
                        success: true
                    ))
                }
            } catch {
                fputs("✗ Failed to rename \(file.filename): \(error)\n", stderr)
                results.append(RenameResult(
                    original: file.filename,
                    renamed: newName,
                    success: false,
                    error: error.localizedDescription
                ))
            }
        }

        // Summary
        let successful = results.filter { $0.success }.count
        print("\n✓ Successfully renamed \(successful)/\(results.count) files")
    }
}
