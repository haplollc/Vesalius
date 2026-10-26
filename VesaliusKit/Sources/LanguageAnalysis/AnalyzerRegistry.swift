import Foundation
import VesaliusCore

/// Chooses the analyzer for each file. Syntax-tree analyzers come first; the lexical analyzer covers
/// every other programming language. Add a language by appending an analyzer here.
public struct AnalyzerRegistry: Sendable {
    public let analyzers: [any LanguageAnalyzer]

    public init(analyzers: [any LanguageAnalyzer]) {
        self.analyzers = analyzers
    }

    public static let standard = AnalyzerRegistry(analyzers: [
        SwiftAnalyzer(),
        TypeScriptAnalyzer(),
        PythonAnalyzer(),
        WebTemplateAnalyzer(),
        WebLanguageAnalyzer(),
        GenericAnalyzer(),
    ])

    public func analyzer(for language: Language, path: String) -> (any LanguageAnalyzer)? {
        analyzers.first { $0.canAnalyze(language, path: path) }
    }
}
