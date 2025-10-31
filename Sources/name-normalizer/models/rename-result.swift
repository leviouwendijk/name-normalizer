struct RenameResult {
    let original: String
    let renamed: String
    let success: Bool
    let error: String?

    init(original: String, renamed: String, success: Bool, error: String? = nil) {
        self.original = original
        self.renamed = renamed
        self.success = success
        self.error = error
    }
}
