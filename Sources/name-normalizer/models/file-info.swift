import Foundation

public struct FileInfo {
    public let path: String
    public let filename: String
    
    public init(
        path: String,
        filename: String
    ) {
        self.path = path
        self.filename = filename
    }

    public var nameWithoutExtension: String {
        let url = URL(fileURLWithPath: filename)
        return url.deletingPathExtension().lastPathComponent
    }

    public var extensionWithDot: String {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        return ext.isEmpty ? "" : ".\(ext)"
    }
}
