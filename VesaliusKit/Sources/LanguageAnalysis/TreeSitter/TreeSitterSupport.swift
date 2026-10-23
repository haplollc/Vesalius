import CTreeSitter
import CTreeSitterGrammars
import Dispatch
import Foundation
import VesaliusCore

// A thin, allocation-conscious Swift layer over the tree-sitter C API.
//
// Thread-safety: a `TSParser` is created per parse and destroyed immediately; languages are static
// tables that are safe to share; trees are owned by `SyntaxTree` and deleted on deinit. Nothing here
// keeps global mutable state, so analyzers built on it are safe to call concurrently.

/// Grammars vendored in `CTreeSitterGrammars`.
enum TreeSitterGrammar: Sendable {
    case typescript
    case tsx
    case javascript
    case python
    case php, phpOnly, csharp

    var language: OpaquePointer {
        switch self {
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .javascript: tree_sitter_javascript()
        case .python: tree_sitter_python()
        case .php: tree_sitter_php()
        case .phpOnly: tree_sitter_php_only()
        case .csharp: tree_sitter_c_sharp()
        }
    }
}

/// Owns a parsed tree; the tree is deleted when the wrapper is released.
final class SyntaxTree {
    private let tree: OpaquePointer

    init(tree: OpaquePointer) {
        self.tree = tree
    }

    deinit {
        ts_tree_delete(tree)
    }

    var root: TSNode { ts_tree_root_node(tree) }
}

private struct ParseContext {
    var base: UnsafePointer<UInt8>
    var length: UInt32
    var deadline: UInt64
}

enum TreeSitterParser {
    /// Parses UTF-8 source. Parsing is abandoned (and an error thrown) once `timeout` elapses, so a
    /// pathological file can never stall indexing.
    static func parse(_ bytes: [UInt8], grammar: TreeSitterGrammar, timeout: Double = 10) throws -> SyntaxTree {
        guard let parser = ts_parser_new() else { throw AnalyzerError("tree-sitter: unable to create a parser") }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, grammar.language) else {
            throw AnalyzerError("tree-sitter: grammar ABI is incompatible with the runtime")
        }
        let source = bytes.isEmpty ? [UInt8(ascii: "\n")] : bytes
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0.1, timeout) * 1_000_000_000)
        let tree: OpaquePointer? = source.withUnsafeBufferPointer { buffer -> OpaquePointer? in
            guard let base = buffer.baseAddress else { return nil }
            var context = ParseContext(base: base, length: UInt32(buffer.count), deadline: deadline)
            return withUnsafeMutablePointer(to: &context) { pointer -> OpaquePointer? in
                let payload = UnsafeMutableRawPointer(pointer)
                let input = TSInput(
                    payload: payload,
                    read: { payload, byteIndex, _, bytesRead in
                        let context = payload!.assumingMemoryBound(to: ParseContext.self)
                        let length = context.pointee.length
                        let base = UnsafeRawPointer(context.pointee.base)
                        guard byteIndex < length else {
                            bytesRead?.pointee = 0
                            return base.assumingMemoryBound(to: CChar.self)
                        }
                        bytesRead?.pointee = length - byteIndex
                        return (base + Int(byteIndex)).assumingMemoryBound(to: CChar.self)
                    },
                    encoding: TSInputEncodingUTF8,
                    decode: nil
                )
                let options = TSParseOptions(
                    payload: payload,
                    progress_callback: { state in
                        guard let payload = state?.pointee.payload else { return false }
                        let context = payload.assumingMemoryBound(to: ParseContext.self)
                        return DispatchTime.now().uptimeNanoseconds > context.pointee.deadline
                    }
                )
                return ts_parser_parse_with_options(parser, nil, input, options)
            }
        }
        guard let tree else {
            throw AnalyzerError("tree-sitter: parsing was abandoned after \(Int(timeout))s")
        }
        return SyntaxTree(tree: tree)
    }
}

// MARK: - Source text

/// The UTF-8 bytes a tree was parsed from; node byte ranges index into it.
struct SourceBytes {
    let bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    func text(_ node: TSNode) -> String {
        text(from: Int(ts_node_start_byte(node)), to: Int(ts_node_end_byte(node)))
    }

    func text(from start: Int, to end: Int) -> String {
        let lower = max(0, min(start, bytes.count))
        let upper = max(lower, min(end, bytes.count))
        return String(decoding: bytes[lower..<upper], as: UTF8.self)
    }

    /// Text of a node up to (not including) `limit`'s start, e.g. a declaration header before its body.
    func text(_ node: TSNode, upTo limit: TSNode?) -> String {
        let end = limit.map { Int(ts_node_start_byte($0)) } ?? Int(ts_node_end_byte(node))
        return text(from: Int(ts_node_start_byte(node)), to: end)
    }

    /// True when the first byte of the node equals `ascii`.
    func startsWith(_ node: TSNode, _ prefix: String) -> Bool {
        let start = Int(ts_node_start_byte(node))
        let utf8 = Array(prefix.utf8)
        guard start + utf8.count <= bytes.count else { return false }
        for (offset, byte) in utf8.enumerated() where bytes[start + offset] != byte {
            return false
        }
        return true
    }
}

// MARK: - Node helpers

extension TSNode {
    var isNull: Bool { ts_node_is_null(self) }
    var symbol: TSSymbol { ts_node_symbol(self) }
    var isNamed: Bool { ts_node_is_named(self) }
    var isExtra: Bool { ts_node_is_extra(self) }
    var isMissing: Bool { ts_node_is_missing(self) }
    var isErrorNode: Bool { ts_node_is_error(self) }
    var containsError: Bool { ts_node_has_error(self) }
    var startByte: Int { Int(ts_node_start_byte(self)) }
    var endByte: Int { Int(ts_node_end_byte(self)) }
    var typeName: String { String(cString: ts_node_type(self)) }

    /// 1-based line of the first byte.
    var startLine: Int { Int(ts_node_start_point(self).row) + 1 }

    /// 1-based line of the last byte (a node ending at column 0 ends on the previous line).
    var endLine: Int {
        let end = ts_node_end_point(self)
        let start = ts_node_start_point(self)
        if end.column == 0 && end.row > start.row { return Int(end.row) }
        return Int(end.row) + 1
    }

    var startColumn: Int { Int(ts_node_start_point(self).column) }

    func field(_ id: TSFieldId) -> TSNode? {
        guard id != 0 else { return nil }
        let node = ts_node_child_by_field_id(self, id)
        return ts_node_is_null(node) ? nil : node
    }

    var parentNode: TSNode? {
        let node = ts_node_parent(self)
        return ts_node_is_null(node) ? nil : node
    }

    var previousSibling: TSNode? {
        let node = ts_node_prev_sibling(self)
        return ts_node_is_null(node) ? nil : node
    }

    var previousNamedSibling: TSNode? {
        let node = ts_node_prev_named_sibling(self)
        return ts_node_is_null(node) ? nil : node
    }

    /// Iterates direct children in order using a cursor (linear, unlike repeated `ts_node_child`).
    func forEachChild(_ body: (TSNode, TSFieldId) -> Void) {
        var cursor = ts_tree_cursor_new(self)
        defer { ts_tree_cursor_delete(&cursor) }
        guard ts_tree_cursor_goto_first_child(&cursor) else { return }
        repeat {
            body(ts_tree_cursor_current_node(&cursor), ts_tree_cursor_current_field_id(&cursor))
        } while ts_tree_cursor_goto_next_sibling(&cursor)
    }

    /// Direct children, optionally only named ones.
    func children(namedOnly: Bool = false) -> [TSNode] {
        var result: [TSNode] = []
        forEachChild { child, _ in
            if !namedOnly || ts_node_is_named(child) { result.append(child) }
        }
        return result
    }

    /// All children attached to a field (fields such as `decorator` or Python's `name` can repeat).
    func children(field: TSFieldId) -> [TSNode] {
        guard field != 0 else { return [] }
        var result: [TSNode] = []
        forEachChild { child, id in
            if id == field { result.append(child) }
        }
        return result
    }
}

// MARK: - Reusable cursor

/// One tree cursor reused for every child iteration in an analysis, so visiting a node does not cost a
/// heap allocation. The API is imperative (`begin`/`next`) and not re-entrant: a loop driven by
/// `begin`/`next` must not call anything else that uses the same cursor. The collecting helpers finish
/// iterating before returning, so their results can be used freely.
final class ReusableCursor {
    private var cursor: TSTreeCursor

    init(_ root: TSNode) {
        cursor = ts_tree_cursor_new(root)
    }

    deinit {
        ts_tree_cursor_delete(&cursor)
    }

    /// Positions the cursor on the first child of `node`; false when there are no children.
    @inline(__always)
    func begin(_ node: TSNode) -> Bool {
        ts_tree_cursor_reset(&cursor, node)
        return ts_tree_cursor_goto_first_child(&cursor)
    }

    @inline(__always)
    func next() -> Bool {
        ts_tree_cursor_goto_next_sibling(&cursor)
    }

    @inline(__always)
    var current: TSNode { ts_tree_cursor_current_node(&cursor) }

    @inline(__always)
    var currentField: TSFieldId { ts_tree_cursor_current_field_id(&cursor) }

    func children(of node: TSNode, namedOnly: Bool = false) -> [TSNode] {
        var result: [TSNode] = []
        guard begin(node) else { return result }
        repeat {
            let child = current
            if !namedOnly || ts_node_is_named(child) { result.append(child) }
        } while next()
        return result
    }

    func children(of node: TSNode, field: TSFieldId) -> [TSNode] {
        var result: [TSNode] = []
        guard field != 0, begin(node) else { return result }
        repeat {
            if currentField == field { result.append(current) }
        } while next()
        return result
    }

    /// Named children paired with their field ids.
    func fieldedChildren(of node: TSNode) -> [(node: TSNode, field: TSFieldId)] {
        var result: [(TSNode, TSFieldId)] = []
        guard begin(node) else { return result }
        repeat {
            let child = current
            if ts_node_is_named(child) { result.append((child, currentField)) }
        } while next()
        return result
    }

    /// True when an anonymous child (keyword/operator token) has the given grammar code.
    func hasAnonymousChild(of node: TSNode, table: NodeKindTable, code: UInt8) -> Bool {
        guard begin(node) else { return false }
        repeat {
            let child = current
            if !ts_node_is_named(child) && table.code(child) == code { return true }
        } while next()
        return false
    }
}

// MARK: - Symbol and field tables

/// Maps grammar symbols to analyzer-defined kinds (a dense `UInt8` code; 0 = uninteresting) so the hot
/// traversal loop dispatches on integers instead of node-type strings.
struct NodeKindTable: Sendable {
    private let codes: [UInt8]

    init(language: OpaquePointer, named: [String: UInt8], anonymous: [String: UInt8]) {
        let count = Int(ts_language_symbol_count(language))
        var codes = [UInt8](repeating: 0, count: count + 1)
        for index in 0..<count {
            let symbol = TSSymbol(index)
            guard let cName = ts_language_symbol_name(language, symbol) else { continue }
            let name = String(cString: cName)
            switch ts_language_symbol_type(language, symbol) {
            case TSSymbolTypeRegular:
                if let code = named[name] { codes[index] = code }
            case TSSymbolTypeAnonymous:
                if let code = anonymous[name] { codes[index] = code }
            default:
                break
            }
        }
        self.codes = codes
    }

    @inline(__always)
    func code(_ node: TSNode) -> UInt8 {
        let symbol = Int(ts_node_symbol(node))
        return symbol < codes.count ? codes[symbol] : 0
    }
}

/// Field ids for a grammar, looked up once.
struct FieldTable: Sendable {
    private let ids: [String: TSFieldId]

    init(language: OpaquePointer, names: [String]) {
        var ids: [String: TSFieldId] = [:]
        for name in names {
            ids[name] = name.withCString { pointer in
                ts_language_field_id_for_name(language, pointer, UInt32(name.utf8.count))
            }
        }
        self.ids = ids
    }

    subscript(_ name: String) -> TSFieldId { ids[name] ?? 0 }
}

// MARK: - Shared analysis utilities

/// Local bindings visible at a point (function parameters, locals, closures' outer locals).
final class LocalScope {
    private var names: Set<String>
    let parent: LocalScope?

    init(parent: LocalScope?, names: Set<String> = []) {
        self.parent = parent
        self.names = names
    }

    func insert(_ name: String) {
        names.insert(name)
    }

    func contains(_ name: String) -> Bool {
        declaringScope(of: name) != nil
    }

    func remove(_ name: String) {
        names.remove(name)
    }

    /// The innermost scope in the chain that binds `name`: one identity per binding, even when names repeat.
    func declaringScope(of name: String) -> LocalScope? {
        var scope: LocalScope? = self
        while let current = scope {
            if current.names.contains(name) { return current }
            scope = current.parent
        }
        return nil
    }

    /// Parameters that hold a dynamically imported module (`import("m").then(m => …)`), mapped to the alias the
    /// import is recorded under (`m@11`), which is unique in the file.
    var importAliases: [String: String] = [:]

    /// The module alias `name` stands for, unless an inner scope rebinds it.
    func importAlias(_ name: String) -> String? {
        var scope: LocalScope? = self
        while let current = scope {
            if let alias = current.importAliases[name] { return alias }
            if current.names.contains(name) { return nil }
            scope = current.parent
        }
        return nil
    }
}

enum TreeSitterUtilities {
    /// Counts ERROR and MISSING nodes, descending only into subtrees that contain errors.
    static func countSyntaxErrors(_ root: TSNode) -> Int {
        guard ts_node_has_error(root) else { return 0 }
        var count = 0
        var cursor = ts_tree_cursor_new(root)
        defer { ts_tree_cursor_delete(&cursor) }
        while true {
            let node = ts_tree_cursor_current_node(&cursor)
            if ts_node_is_error(node) || ts_node_is_missing(node) { count += 1 }
            if ts_node_has_error(node), !ts_node_is_missing(node), ts_tree_cursor_goto_first_child(&cursor) {
                continue
            }
            while !ts_tree_cursor_goto_next_sibling(&cursor) {
                if !ts_tree_cursor_goto_parent(&cursor) { return count }
            }
        }
    }

    /// FNV-1a over the node-type sequence of a subtree. `normalize` returns a replacement code for
    /// nodes whose identity should not matter (identifiers, literals); their children are skipped.
    /// Comments are ignored, so reformatted or re-commented copies hash identically.
    static func structuralHash(_ node: TSNode, normalize: (TSNode) -> Int?) -> UInt64 {
        var hasher = FNV1a()
        var cursor = ts_tree_cursor_new(node)
        defer { ts_tree_cursor_delete(&cursor) }
        while true {
            let current = ts_tree_cursor_current_node(&cursor)
            var descend = false
            if ts_node_is_extra(current) {
                descend = false
            } else if let code = normalize(current) {
                hasher.combine(code)
            } else {
                hasher.combine(Int(ts_node_symbol(current)))
                descend = true
            }
            if descend, ts_tree_cursor_goto_first_child(&cursor) { continue }
            while !ts_tree_cursor_goto_next_sibling(&cursor) {
                if !ts_tree_cursor_goto_parent(&cursor) { return hasher.value }
            }
        }
    }

    /// `Foo`, `FooBar` (but not `FOO` or `foo`).
    static func isPascalCase(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSetLite.isUpper(first) else { return false }
        return name.unicodeScalars.contains { CharacterSetLite.isLower($0) }
    }

    /// `MAX_SIZE`, `API_URL2`.
    static func isScreamingCase(_ name: String) -> Bool {
        var sawLetter = false
        for scalar in name.unicodeScalars {
            if CharacterSetLite.isLower(scalar) { return false }
            if CharacterSetLite.isUpper(scalar) { sawLetter = true }
        }
        return sawLetter
    }

    /// Strips matching quotes from a string literal's text.
    static func unquote(_ text: String) -> String {
        var value = Substring(text)
        // Python prefixes (r, b, f, u and combinations).
        while let first = value.first, "rRbBfFuU".contains(first), value.count > 1, let second = value.dropFirst().first, "'\"rRbBfFuU".contains(second) {
            value = value.dropFirst()
        }
        for quote in ["\"\"\"", "'''", "\"", "'", "`"] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count >= quote.count * 2 {
            return String(value.dropFirst(quote.count).dropLast(quote.count))
        }
        return String(value)
    }
}

enum CharacterSetLite {
    @inline(__always) static func isUpper(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 65 && scalar.value <= 90 || (scalar.value > 127 && scalar.properties.isUppercase)
    }

    @inline(__always) static func isLower(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 97 && scalar.value <= 122 || (scalar.value > 127 && scalar.properties.isLowercase)
    }
}

/// Accumulates symbols with stable local ids for one file.
struct SymbolCollector {
    private(set) var symbols: [ExtractedSymbol] = []

    @discardableResult
    mutating func add(
        name: String,
        kind: SymbolKind,
        range: LineRange,
        parent: Int?,
        signature: String? = nil,
        doc: String? = nil,
        visibility: Visibility? = nil,
        isExported: Bool = false,
        attributes: [String] = [],
        inheritedTypes: [String] = []
    ) -> Int {
        let id = symbols.count
        symbols.append(ExtractedSymbol(
            localID: id,
            parentLocalID: parent,
            name: name,
            kind: kind,
            range: range,
            signature: signature,
            doc: doc,
            visibility: visibility,
            isExported: isExported,
            attributes: attributes,
            inheritedTypes: inheritedTypes
        ))
        return id
    }

    subscript(id: Int) -> ExtractedSymbol {
        get { symbols[id] }
        set { symbols[id] = newValue }
    }

    mutating func addComplexity(_ id: Int?, _ amount: Int = 1) {
        guard let id, id < symbols.count else { return }
        symbols[id].complexity += amount
    }

    func kind(of id: Int?) -> SymbolKind? {
        guard let id, id < symbols.count else { return nil }
        return symbols[id].kind
    }
}

/// Debugging aid: the S-expression of a parse tree (used by tests and when extending analyzers).
enum TreeSitterDebug {
    static func sexpression(_ source: String, grammar: TreeSitterGrammar) -> String {
        guard let tree = try? TreeSitterParser.parse(Array(source.utf8), grammar: grammar) else { return "<parse failed>" }
        guard let pointer = ts_node_string(tree.root) else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
