import Foundation

enum NameNormalizerError: LocalizedError {
    case cannotReadFile(String)
    case invalidDirectory(String)
    case noFilesFound

    var errorDescription: String? {
        switch self {
        case .cannotReadFile(let path):
            return "Cannot read file list at: \(path)"
        case .invalidDirectory(let path):
            return "Invalid directory: \(path)"
        case .noFilesFound:
            return "No files found to process"
        }
    }
}
