import Foundation
import VesaliusCore

/// Projects explicit Blade/PHP and Razor code islands while retaining source lines.
/// Markup is searchable through the file index; it is never parsed as application code.
public struct WebTemplateAnalyzer: LanguageAnalyzer {
    public init() {}
    public let identifier = "web-template-islands"
    public let version = 1
    public func canAnalyze(_ language: Language, path: String) -> Bool {
        path.hasSuffix(".blade.php") || path.hasSuffix(".razor") || path.hasSuffix(".cshtml")
    }
    public func analyze(_ file: SourceFile) throws -> FileAnalysis {
        var projection = TemplateProjection(file.text)
        if file.path.hasSuffix(".blade.php") {
            projection.copyMatches(#"(?s)@php\b(?!\s*\()(.*?)@endphp|<\?php\b(.*?)\?>"#, groups: [1, 2])
            projection.copyMatches(#"(?s)(?<!@)\{\{(?!\-\-)(.*?)\}\}|\{!!(.*?)!!\}"#, groups: [1, 2], terminate: true)
            // Directives contribute their expressions, not invented calls to a directive name.
            for match in projection.matches(#"@(if|elseif|foreach|forelse|while|unless|isset|empty|include|extends|component|each|php)\s*\("#) {
                let open = projection.byteOffset(match.range.location + match.range.length - 1)
                if let close = projection.balancedEnd(open: open, opening: 40, closing: 41) {
                    projection.copy((open + 1)..<close)
                    projection.bytes[close] = 59
                }
            }
            var result = try WebLanguageAnalyzer().analyze(SourceFile(path: file.path, language: .php, text: projection.text), grammar: .phpOnly)
            for match in projection.matches(#"@(include|extends|component|each)\s*\(\s*['"]([\w.\-/]+)['"]"#) {
                let view = projection.substring(match.range(at: 2))
                result.imports.append(ExtractedImport(module: "laravel-view:" + view, kind: .module, line: projection.line(at: projection.byteOffset(match.range.location))))
            }
            return result
        }
        for match in projection.matches(#"@(code|functions)\s*\{"#) {
            let open = projection.byteOffset(match.range.location + match.range.length - 1)
            if let close = projection.balancedEnd(open: open, opening: 123, closing: 125) {
                projection.copy((open + 1)..<close)
            }
        }
        for match in projection.matches(#"(?m)^[\t ]*@inject[\t ]+([\w.<>?,]+[\t ]+\w+)[\t ]*$"#) {
            let range = projection.byteRange(match.range)
            let declaration = projection.substring(match.range(at: 1)) + ";"
            let replacement = String(repeating: " ", count: max(0, range.count - declaration.utf8.count)) + declaration
            projection.bytes.replaceSubrange(range, with: replacement.utf8)
        }
        let component = ((file.fileName as NSString).deletingPathExtension).filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let wrapped = "partial class \(component.isEmpty ? "Template" : component) {\n" + projection.text + "\n}"
        var result = try WebLanguageAnalyzer().analyze(SourceFile(path: file.path, language: .csharp, text: wrapped))
        for index in result.symbols.indices {
            result.symbols[index].range = LineRange(max(1, result.symbols[index].range.start - 1), max(1, min(projection.lines, result.symbols[index].range.end - 1)))
        }
        for index in result.references.indices {
            result.references[index].line = max(1, result.references[index].line - 1)
            result.references[index].statementLine = result.references[index].statementLine.map { max(1, $0 - 1) }
            result.references[index].endLine = result.references[index].endLine.map { max(1, $0 - 1) }
            result.references[index].callEndLine = result.references[index].callEndLine.map { max(1, $0 - 1) }
        }
        for index in result.literals.indices { result.literals[index].line = max(1, result.literals[index].line - 1) }
        // A method-group event handler is a reference, not a direct invocation at render time.
        for match in projection.matches(#"@on\w+\s*=\s*["']@?([A-Za-z_]\w*)["']"#) {
            let offset = projection.byteOffset(match.range(at: 1).location)
            result.references.append(ExtractedReference(name: projection.substring(match.range(at: 1)), kind: .member, line: projection.line(at: offset), enclosingSymbol: result.symbols.first?.localID, context: "read"))
        }
        for match in projection.matches(#"@page\s+["']([^"']+)["']"#) {
            result.literals.append(ExtractedLiteral(value: projection.substring(match.range(at: 1)), line: projection.line(at: projection.byteOffset(match.range.location)), context: "ui", callee: "page"))
        }
        return result
    }
}

private struct TemplateProjection {
    let original: String
    let originalBytes: [UInt8]
    let comments: [NSRange]
    var bytes: [UInt8]
    init(_ text: String) {
        original = text
        originalBytes = Array(text.utf8)
        bytes = originalBytes.map { $0 == 10 || $0 == 13 ? $0 : 32 }
        let pattern = #"(?s)\{\{--.*?--\}\}|<!--.*?-->|@\*.*?\*@"#
        comments = (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range) ?? []
    }
    var text: String { String(decoding: bytes, as: UTF8.self) }
    var lines: Int { originalBytes.filter { $0 == 10 }.count + 1 }
    func matches(_ pattern: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: original, range: NSRange(original.startIndex..., in: original)).filter { match in
            !comments.contains { NSLocationInRange(match.range.location, $0) }
        }
    }
    func substring(_ range: NSRange) -> String { Range(range, in: original).map { String(original[$0]) } ?? "" }
    func byteOffset(_ utf16: Int) -> Int {
        let index = String.Index(utf16Offset: utf16, in: original)
        return original.utf8.distance(from: original.utf8.startIndex, to: index)
    }
    func byteRange(_ range: NSRange) -> Range<Int> { byteOffset(range.location)..<byteOffset(range.location + range.length) }
    func line(at offset: Int) -> Int { originalBytes.prefix(offset).filter { $0 == 10 }.count + 1 }
    mutating func copy(_ range: Range<Int>) { bytes.replaceSubrange(range, with: originalBytes[range]) }
    mutating func copyMatches(_ pattern: String, groups: [Int], terminate: Bool = false) {
        for match in matches(pattern) {
            for group in groups where match.range(at: group).location != NSNotFound {
                let range = byteRange(match.range(at: group))
                copy(range)
                if terminate && range.upperBound < bytes.count { bytes[range.upperBound] = 59 }
            }
        }
    }
    /// Balanced delimiters, skipping quoted strings, raw strings, line/block comments.
    func balancedEnd(open: Int, opening: UInt8, closing: UInt8) -> Int? {
        var depth = 1, i = open + 1
        while i < originalBytes.count {
            let b = originalBytes[i]
            if b == 47 && i + 1 < originalBytes.count && originalBytes[i + 1] == 47 {
                while i < originalBytes.count && originalBytes[i] != 10 { i += 1 }; continue
            }
            if b == 47 && i + 1 < originalBytes.count && originalBytes[i + 1] == 42 {
                i += 2
                while i + 1 < originalBytes.count && !(originalBytes[i] == 42 && originalBytes[i + 1] == 47) { i += 1 }
                i += 2; continue
            }
            if b == 34 || b == 39 || b == 96 {
                let quote = b
                var count = 1
                if quote == 34 { while i + count < originalBytes.count && originalBytes[i + count] == quote { count += 1 } }
                let raw = count >= 3
                let width = raw ? count : 1
                let verbatim = i > 0 && originalBytes[i - 1] == 64
                i += width
                while i < originalBytes.count {
                    if !raw && !verbatim && originalBytes[i] == 92 { i += 2; continue }
                    if originalBytes[i] == quote {
                        if verbatim && i + 1 < originalBytes.count && originalBytes[i + 1] == quote { i += 2; continue }
                        if !raw || (i + width <= originalBytes.count && originalBytes[i..<(i + width)].allSatisfy { $0 == quote }) { i += width; break }
                    }
                    i += 1
                }
                continue
            }
            if b == opening { depth += 1 }
            if b == closing { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }
}
