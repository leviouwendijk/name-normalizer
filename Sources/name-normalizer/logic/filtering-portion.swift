import Foundation

/// Filters (removes) specified parts from a string while preserving original case of unmatched portions.
/// 
/// Example:
/// ```
/// filter(in: "MyFileName_TEST", parts: ["file", "test"])
/// // Result: "MyName_" (removes "File" and "TEST" case-insensitively)
/// ```
/// 
/// - Parameters:
///   - string: The input string to filter
///   - parts: Array of substrings to remove (case-insensitive matching)
/// - Returns: String with matched parts removed, original case preserved for remaining text
public func filterParts(in string: String, parts: [String] = []) -> String {
    guard !parts.isEmpty else { return string }
    
    var result = string
    
    for part in parts {
        result = filterSinglePart(result, removing: part)
    }
    
    return result
}

/// Removes a single part from the string (case-insensitive) while preserving case of remaining chars.
private func filterSinglePart(_ string: String, removing part: String) -> String {
    guard !part.isEmpty else { return string }
    
    let lowerString = string.lowercased()
    let lowerPart = part.lowercased()
    let stringScalars = Array(string.unicodeScalars)
    let partScalars = Array(lowerPart.unicodeScalars)
    
    var result: [UnicodeScalar] = []
    var i = 0
    
    while i < stringScalars.count {
        // Check if we have a match at current position
        if let matchLength = matchLength(
            in: lowerString,
            at: i,
            pattern: lowerPart,
            patternScalars: partScalars
        ) {
            // Skip the matched portion
            i += matchLength
        } else {
            // Keep this character
            result.append(stringScalars[i])
            i += 1
        }
    }
    
    return String(String.UnicodeScalarView(result))
}

/// Checks if a pattern matches at the given position in a lowercased string.
/// Returns the count of scalars matched, or nil if no match.
private func matchLength(
    in lowerString: String,
    at position: Int,
    pattern: String,
    patternScalars: [UnicodeScalar]
) -> Int? {
    let stringScalars = Array(lowerString.unicodeScalars)
    
    guard position + patternScalars.count <= stringScalars.count else {
        return nil
    }
    
    for j in 0..<patternScalars.count {
        if stringScalars[position + j] != patternScalars[j] {
            return nil
        }
    }
    
    return patternScalars.count
}
