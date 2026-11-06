import Foundation

/// Languages Vesalius recognises. Swift, TypeScript/JavaScript and Python have full syntax analyzers;
/// every other text language is still indexed lexically.
public enum Language: String, Codable, Sendable, CaseIterable, Comparable {
    case swift
    case typescript
    case javascript
    case python
    case objectiveC = "objc"
    case c
    case cpp
    case go
    case rust
    case java
    case kotlin
    case ruby
    case php
    case csharp
    case dart
    case shell
    case html
    case css
    case sql
    case markdown
    case json
    case yaml
    case toml
    case xml
    case text
    case unknown

    public static func < (lhs: Language, rhs: Language) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .typescript: "TypeScript"
        case .javascript: "JavaScript"
        case .python: "Python"
        case .objectiveC: "Objective-C"
        case .c: "C"
        case .cpp: "C++"
        case .go: "Go"
        case .rust: "Rust"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .csharp: "C#"
        case .dart: "Dart"
        case .shell: "Shell"
        case .html: "HTML"
        case .css: "CSS"
        case .sql: "SQL"
        case .markdown: "Markdown"
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .xml: "XML"
        case .text: "Text"
        case .unknown: "Other"
        }
    }

    /// True for programming languages whose files participate in the dependency graph and code metrics.
    public var isCode: Bool {
        switch self {
        case .swift, .typescript, .javascript, .python, .objectiveC, .c, .cpp, .go, .rust, .java,
             .kotlin, .ruby, .php, .csharp, .dart, .shell, .sql:
            true
        default:
            false
        }
    }

    /// Languages with a dedicated syntax-tree analyzer.
    public var hasSyntaxAnalyzer: Bool {
        switch self {
        case .swift, .typescript, .javascript, .python, .php, .csharp: true
        default: false
        }
    }

    public var lineCommentPrefixes: [String] {
        switch self {
        case .python, .ruby, .shell, .yaml, .toml: ["#"]
        case .sql: ["--"]
        case .html, .xml, .markdown, .json, .text, .unknown, .css: []
        case .php: ["//", "#"]
        default: ["//"]
        }
    }

    public var hasBlockComments: Bool {
        switch self {
        case .python, .ruby, .shell, .yaml, .toml, .markdown, .json, .text, .unknown: false
        default: true
        }
    }

    private static let extensionMap: [String: Language] = [
        "swift": .swift,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "py": .python, "pyi": .python, "pyw": .python,
        "m": .objectiveC, "mm": .objectiveC,
        "h": .c, "c": .c,
        "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "cpp": .cpp, "cc": .cpp, "cxx": .cpp,
        "go": .go,
        "rs": .rust,
        "java": .java,
        "kt": .kotlin, "kts": .kotlin,
        "rb": .ruby, "rake": .ruby,
        "php": .php,
        "cs": .csharp, "razor": .csharp, "cshtml": .csharp,
        "dart": .dart,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "html": .html, "htm": .html, "vue": .html, "svelte": .html,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
        "sql": .sql,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown, "rst": .markdown,
        // StoreKit configurations and test plans are JSON; indexing them makes product ids and test plans searchable.
        "json": .json, "jsonc": .json, "storekit": .json, "xctestplan": .json,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml,
        "xml": .xml, "plist": .xml, "xib": .xml, "storyboard": .xml, "entitlements": .xml,
        "txt": .text, "cfg": .text, "ini": .text, "conf": .text, "env": .text,
        "gradle": .kotlin,
    ]

    private static let filenameMap: [String: Language] = [
        "Dockerfile": .shell, "Makefile": .shell, "Rakefile": .ruby, "Gemfile": .ruby,
        "Podfile": .ruby, "Fastfile": .ruby, "Appfile": .ruby, "Brewfile": .ruby,
        "Package.swift": .swift, "BUILD": .text, "WORKSPACE": .text, "Procfile": .text,
        ".gitignore": .text, ".env": .text,
    ]

    /// Detects the language from a file name (not the full path).
    public static func detect(fileName: String) -> Language {
        if let named = filenameMap[fileName] { return named }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return .unknown }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        return extensionMap[ext] ?? .unknown
    }

    /// File extensions that are TypeScript/JavaScript JSX dialects.
    public static func isJSXExtension(_ fileName: String) -> Bool {
        fileName.hasSuffix(".tsx") || fileName.hasSuffix(".jsx")
    }
}
