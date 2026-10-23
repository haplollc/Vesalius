import Foundation
import VesaliusCore

/// Resolves stored references to symbols and files, then aggregates them into typed file edges.
///
/// Resolution is confidence-scored and records how it decided (`refs.basis`):
/// - explicit import bindings (TS/JS/Python), including packages outside the repository (`import`);
/// - a known receiver type: the collector's hint, the declared type of the receiver's own reference, `self`
///   or `super`, walked through extensions, superclasses and protocols (`typed`, `self`, `static`);
/// - lexical scope: same file, then top-level names the file can see (`lexical`);
/// - and, last, the only declaration with that name (`unique-name`), below the edge threshold unless something
///   corroborates it.
/// Swift candidates must be visible from the referencing file: private declarations stay in their file,
/// function-local types in their function, and other modules need an import. Framework members become
/// external references with their module instead of binding to a same-named repository symbol. Only references
/// at or above `edgeThreshold` become graph edges.
public final class ReferenceLinker {
    public static let edgeThreshold = 0.5
    /// Bumped whenever resolution rules change, so existing indexes re-link every reference.
    public static let version = 9

    enum Family: Equatable {
        case swift, script, python, other(Language)

        init(_ language: Language) {
            switch language {
            case .swift: self = .swift
            case .typescript, .javascript, .html: self = .script
            case .python: self = .python
            default: self = .other(language)
            }
        }
    }

    /// One file as the linker reads it (a class, like `SymbolInfo`: looked up for every candidate).
    final class FileInfo {
        let path: String
        let directory: String
        let topDirectory: Substring
        let family: Family
        let moduleID: Int64?
        let isDeclarationFile: Bool

        init(path: String, directory: String, topDirectory: Substring, family: Family, moduleID: Int64?, isDeclarationFile: Bool) {
            self.path = path
            self.directory = directory
            self.topDirectory = topDirectory
            self.family = family
            self.moduleID = moduleID
            self.isDeclarationFile = isDeclarationFile
        }
    }

    /// One declaration as the linker reads it. A class: lookups by id happen for nearly every candidate of every
    /// reference, and must not copy two dozen fields each time. Only `load()` sets the stored `var` fields; the
    /// parsed labels fill in on first use.
    final class SymbolInfo {
        let id: Int64
        let fileID: Int64
        let parentID: Int64?
        let name: String
        let kind: SymbolKind
        let isExported: Bool
        let isDefaultExport: Bool
        /// `static`/`class` members, enum cases and nested types: reachable through the type, never through a value.
        var isTypeLevel: Bool
        /// Framework protocols an attached macro adds (`@Model` → PersistentModel).
        let macroParents: [String]
        /// The type of the projected value (`$x`) when it is not the wrapped value's: `@Published` → its publisher.
        let projection: String?
        let visibility: Visibility?
        let startLine: Int
        let endLine: Int
        /// `embed(_:)`; nil for anything that takes no argument list.
        let selector: String?
        let parameterFlags: String?
        /// `symbols.param_types`, still `|`-joined.
        let parameterTypes: String?
        let declaredType: String?
        let declaredTypeRef: Int64?
        let inherits: [String]
        let signature: String?
        /// Simple name of the container (type or extension) this symbol is a member of.
        var ownerName: String?
        /// The container symbol itself.
        var ownerID: Int64?
        /// Declared inside a function body, or a member of such a declaration.
        var isLocal: Bool
        /// Private or fileprivate, itself or through an enclosing declaration: only its own file can name it.
        var isFileScoped: Bool
        /// For a local declaration: the lines of the declaration whose body contains it.
        var scope: ClosedRange<Int>?
        /// The selector's argument labels and one flag per parameter (`-` where the collector recorded none),
        /// parsed once for the label match.
        lazy var parameterLabels: [String] = selector.map(ReferenceLinker.selectorLabels) ?? []
        lazy var flagCharacters: [Character] = Array(parameterFlags ?? String(repeating: "-", count: parameterLabels.count))

        init(id: Int64, fileID: Int64, parentID: Int64?, name: String, kind: SymbolKind, isExported: Bool, isDefaultExport: Bool,
             isTypeLevel: Bool, macroParents: [String], projection: String?, visibility: Visibility?, startLine: Int, endLine: Int,
             selector: String?, parameterFlags: String?, parameterTypes: String?, declaredType: String?, declaredTypeRef: Int64?,
             inherits: [String], signature: String?, ownerName: String?, ownerID: Int64?, isLocal: Bool, isFileScoped: Bool,
             scope: ClosedRange<Int>?) {
            self.id = id
            self.fileID = fileID
            self.parentID = parentID
            self.name = name
            self.kind = kind
            self.isExported = isExported
            self.isDefaultExport = isDefaultExport
            self.isTypeLevel = isTypeLevel
            self.macroParents = macroParents
            self.projection = projection
            self.visibility = visibility
            self.startLine = startLine
            self.endLine = endLine
            self.selector = selector
            self.parameterFlags = parameterFlags
            self.parameterTypes = parameterTypes
            self.declaredType = declaredType
            self.declaredTypeRef = declaredTypeRef
            self.inherits = inherits
            self.signature = signature
            self.ownerName = ownerName
            self.ownerID = ownerID
            self.isLocal = isLocal
            self.isFileScoped = isFileScoped
            self.scope = scope
        }
    }

    enum Binding {
        case module(Int64)
        case symbol(Int64, String)
        case defaultExport(Int64)
    }

    /// How a reference resolved: the columns `link()` writes.
    struct Resolution: Equatable {
        var symbol: Int64?
        var file: Int64?
        var confidence: Double
        var basis: ResolutionBasis?
        var receiverType: String?
        var isExternal = false
        var externalModule: String?
        var altSymbol: Int64?
        /// `refs.type_evidence_line`: the collector's for a hinted receiver; for one typed through a declaration of
        /// the same file (`private var subscriptions = …` typing `subscriptions.start()`), that declaration's line.
        var evidenceLine: Int?

        static let unresolved = Resolution(symbol: nil, file: nil, confidence: 0, basis: nil)

        /// Above the edge threshold and pointing into the repository: this site becomes part of a file edge.
        var isEdge: Bool { file != nil && confidence >= ReferenceLinker.edgeThreshold }
    }

    /// One `refs` row as the linker reads it (a class: the batch, the cache and the memo share rows without copying).
    final class RefRow {
        let id: Int64
        let fileID: Int64
        let fromSymbol: Int64?
        let name: String
        let kind: ReferenceKind
        let context: String?
        let line: Int
        let receiver: String?
        let receiverHint: String?
        let receiverRef: Int64?
        /// nil = not a call; `[]` = `f()`.
        let argumentLabels: [String]?
        /// `resolved = 0`: the row is (re)linked in this run.
        let pending: Bool
        /// What the row holds now.
        let stored: Resolution

        init(id: Int64, fileID: Int64, fromSymbol: Int64?, name: String, kind: ReferenceKind, context: String?, line: Int, receiver: String?,
             receiverHint: String?, receiverRef: Int64?, argumentLabels: [String]?, pending: Bool, stored: Resolution) {
            self.id = id
            self.fileID = fileID
            self.fromSymbol = fromSymbol
            self.name = name
            self.kind = kind
            self.context = context
            self.line = line
            self.receiver = receiver
            self.receiverHint = receiverHint
            self.receiverRef = receiverRef
            self.argumentLabels = argumentLabels
            self.pending = pending
            self.stored = stored
        }
    }

    let db: SQLiteDatabase

    // MARK: Files and symbols (load)

    var files: [Int64: FileInfo] = [:]
    var symbols: [Int64: SymbolInfo] = [:]
    /// Position of each symbol in (path, start line, id) order: the deterministic tie-break between equal candidates.
    var symbolRank: [Int64: Int] = [:]
    /// Every symbol, in rank order.
    var orderedSymbols: [SymbolInfo] = []
    /// Non-extension symbols by simple name, in rank order.
    var byName: [String: [Int64]] = [:]
    var topLevel: [Int64: [String: Int64]] = [:]
    var defaultExports: [Int64: Int64] = [:]
    var hasLocalSymbols = false

    // MARK: Type index (load)

    /// Type declarations (classes, structs, enums, protocols, actors, type aliases) by simple name, in rank order.
    var typesByName: [String: [Int64]] = [:]
    /// A type's members: its own children plus those of every extension resolved to it.
    var membersByType: [Int64: [String: [Int64]]] = [:]
    /// Members the repository adds to types it does not declare (`extension View`, `extension Double`), by the
    /// extended type's name as written and by its last component.
    var externalMembers: [String: [String: [Int64]]] = [:]
    /// Extension symbol → the type it extends.
    var extensionTargets: [Int64: TypeTarget] = [:]
    var superclasses: [Int64: TypeTarget] = [:]
    /// Repository protocols a type adopts, from its declaration and its extensions.
    var conformances: [Int64: [Int64]] = [:]
    /// Parents outside the repository (`View`, `XCTestCase`, `Codable`).
    var externalParents: [Int64: [String]] = [:]
    /// External types the repository makes conform to its own protocols (`extension Double: Formattable`).
    var externalConformances: [String: [Int64]] = [:]

    // MARK: Imports, modules and targets (load)

    var exports: [Int64: [String: String]] = [:]
    var bindings: [Int64: [String: Binding]] = [:]
    /// Names bound by imports of packages outside the repository: local name → (module, exported name).
    var externalBindings: [Int64: [String: (module: String, exported: String)]] = [:]
    var starImports: [Int64: [Int64]] = [:]
    var reexports: [Int64: [(target: Int64, names: [ImportedName])]] = [:]
    var moduleImports: [Int64: Set<Int64>] = [:]
    /// Modules imported by any file of a module (Swift leaks extension members module-wide).
    var moduleWideImports: [Int64: Set<Int64>] = [:]
    /// `@_exported import`: modules a module makes visible to its own files and to its importers.
    var reexportedModules: [Int64: Set<Int64>] = [:]
    var modulesByName: [String: [Int64]] = [:]
    var moduleNames: [Int64: String] = [:]
    /// Xcode target → its project. Targets of one project share files through target membership.
    var xcodeProjects: [Int64: String] = [:]
    /// Swift imports by file: module name as written → whether it is `@testable`.
    var swiftImports: [Int64: [String: Bool]] = [:]
    /// Imports of modules outside the repository, by file (`StoreKit`, `electron`).
    var externalImports: [Int64: Set<String>] = [:]
    var targets: [Int64: TargetInfo] = [:]
    /// Targets that build a file, from project membership data (legacy folder guesses excluded).
    var fileTargets: [Int64: [Int64]] = [:]
    /// Targets whose membership is only guessed from a folder of the same name.
    var legacyFileTargets: [Int64: [Int64]] = [:]
    /// Module names each target's files can be imported as.
    var targetsByModuleName: [String: [Int64]] = [:]

    // MARK: Per-run state

    var memo: [Int64: Resolution] = [:]
    var resolving: Set<Int64> = []
    var producedTypes: [Int64: ValueType?] = [:]
    var typing: Set<Int64> = []
    var typingDepth = 0
    var declaredTypes: [Int64: ValueType?] = [:]
    var declaringSymbols: Set<Int64> = []
    var typeNames: [TypeNameKey: TypeTarget?] = [:]
    var containerChains: [Int64: [Int64]] = [:]
    var genericParameterCache: [Int64: [String: String?]] = [:]
    var parsedHints: [String: TypeExpr?] = [:]
    var parameterNameCache: [Int64: Set<String>] = [:]
    var qualifiedNames: [Int64: String] = [:]
    var inferredProperties: [InferenceKey: Int64?] = [:]
    var identifierWords: [String: Set<String>] = [:]
    var legacyGuesses: [GuessKey: Int64?] = [:]
    var fileRelations: [UInt64: FileRelation] = [:]
    var fileScopes: [Int64: FileScope] = [:]
    /// The rows of the file being linked.
    var batch: [Int64: RefRow] = [:]
    var batchFile: Int64?
    /// Rows of other files read on demand (a declared type's initializer and its receiver chain).
    var refCache: [Int64: RefRow] = [:]
    /// Types each file names at high confidence (corroboration for unique-name guesses).
    var mentionsByFile: [Int64: Set<Int64>] = [:]
    /// Refs that type a declaration (`symbols.declared_type_ref`): their resolutions are kept across files.
    var declarationRefs: Set<Int64> = []
    /// `invalidateAll()` asked for every row to be re-resolved.
    var relinkingEverything = false

    public init(db: SQLiteDatabase) {
        self.db = db
    }

    public struct Result: Sendable {
        public var processed: Int
        public var linked: Int
        public var filesWithChangedEdges: Set<Int64>
    }

    // MARK: - Invalidation

    /// Marks references whose resolution may change because symbols with these names were added, removed or
    /// modified: uses of the name, uses through a receiver of that name, and uses typed through a type of that name.
    public func invalidate(names: Set<String>) throws {
        guard !names.isEmpty else { return }
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS link_names(name TEXT PRIMARY KEY)")
        try db.execute("DELETE FROM link_names")
        try db.transaction {
            for name in names { try db.run("INSERT OR IGNORE INTO link_names(name) VALUES(?)", [name]) }
        }
        // `Outer.Inner` receivers and receiver types are matched by their last component.
        try db.run("""
            UPDATE refs SET resolved = 0
            WHERE resolved = 1 AND (name IN (SELECT name FROM link_names) OR receiver IN (SELECT name FROM link_names)
                OR substr(receiver, length(rtrim(receiver, replace(receiver, '.', ''))) + 1) IN (SELECT name FROM link_names)
                OR substr(receiver_type, length(rtrim(receiver_type, replace(receiver_type, '.', ''))) + 1) IN (SELECT name FROM link_names))
            """)
    }

    /// Marks every reference for re-resolution (the resolution rules or the project model changed). Recorded as a
    /// flag rather than by clearing `resolved` on every row: the next `link()` re-resolves all rows but rewrites only
    /// those whose resolution changed, and an interrupted run leaves the flag for the next one.
    public func invalidateAll() throws {
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('link_everything', '1')")
    }

    /// Marks every reference in the given files for re-resolution (their import bindings changed).
    public func invalidate(files fileIDs: Set<Int64>) throws {
        guard !fileIDs.isEmpty else { return }
        try db.run("UPDATE refs SET resolved = 0 WHERE file_id IN (\(Array(fileIDs).sqlList))")
    }

    /// Spreads invalidation to what depends on the pending rows: references into files rewritten since the last
    /// link (their symbol ids are new), member uses whose receiver is pending, and uses of declarations typed by a
    /// pending row. A changed or removed type hierarchy re-links everything.
    private func propagateInvalidation() throws {
        let everything = (try? db.queryOne("SELECT value FROM meta WHERE key = 'link_everything'") { $0.string(0) }) == "1"
        let anyResolved = try !everything && db.scalarInt("SELECT EXISTS(SELECT 1 FROM refs WHERE resolved = 1)") == 1
        let hierarchy = hierarchyFingerprint()
        let storedHierarchy = (try? db.queryOne("SELECT value FROM meta WHERE key = 'link_hierarchy'") { $0.string(0) }) ?? nil
        defer {
            if storedHierarchy != hierarchy.json {
                _ = try? db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('link_hierarchy', ?)", [hierarchy.json])
            }
        }
        guard anyResolved else { return }
        if let storedHierarchy, let previous = try? JSONDecoder().decode([String: String].self, from: Data(storedHierarchy.utf8)),
           previous.contains(where: { hierarchy.entries[$0.key] != $0.value }) {
            try invalidateAll()
            return
        }
        if let linkedAt = (try? db.queryOne("SELECT value FROM meta WHERE key = 'linked_at'") { Double($0.string(0)) }) ?? nil {
            try db.run("UPDATE refs SET resolved = 0 WHERE resolved = 1 AND target_file_id IN (SELECT id FROM files WHERE indexed_at > ?)", [linkedAt])
        }
        for _ in 0..<4 {
            let chained = try db.run("""
                WITH RECURSIVE pending(id) AS (
                    SELECT id FROM refs WHERE resolved = 0
                    UNION SELECT r.id FROM refs r JOIN pending p ON r.receiver_ref = p.id
                )
                UPDATE refs SET resolved = 0 WHERE resolved = 1 AND id IN (SELECT id FROM pending)
                """)
            // One pass over the declarations (declared_type_ref has no index), not one per pending row.
            let typed = try db.run("""
                UPDATE refs SET resolved = 0 WHERE resolved = 1 AND name IN (
                    SELECT name FROM symbols WHERE declared_type_ref IN (SELECT id FROM refs WHERE resolved = 0))
                """)
            if chained == 0 && typed == 0 { break }
        }
    }

    /// `path#Type#kind#parent` → the parents every such declaration lists (one file can extend a type twice).
    private func hierarchyFingerprint() -> (entries: [String: String], json: String) {
        var lists: [String: [String]] = [:]
        for symbol in symbols.values where !symbol.inherits.isEmpty && (symbol.kind.isType || symbol.kind == .extension) {
            guard let path = files[symbol.fileID]?.path else { continue }
            let key = "\(path)#\(symbol.name)#\(symbol.kind.rawValue)#\(symbol.parentID.flatMap { symbols[$0]?.name } ?? "")"
            lists[key, default: []].append(symbol.inherits.joined(separator: ","))
        }
        let entries = lists.mapValues { $0.sorted().joined(separator: ";") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(entries)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return (entries, json)
    }

    // MARK: - Linking

    /// Resolves all references with `resolved = 0`, file by file. A row's receiver and the declarations that type
    /// it are resolved on demand through a memo, so chains resolve in dependency order across files. Only rows
    /// whose resolution changed are written.
    public func link() throws -> Result {
        let started = Date()
        var phase = started
        try load()
        trace("load", since: &phase)
        try propagateInvalidation()
        resetRunState()
        relinkingEverything = (try? db.queryOne("SELECT value FROM meta WHERE key = 'link_everything'") { $0.string(0) }) == "1"
        declarationRefs = Set(symbols.values.compactMap(\.declaredTypeRef))
        trace("invalidate", since: &phase)

        let pendingFiles = try db.query("SELECT DISTINCT file_id FROM refs\(relinkingEverything ? "" : " WHERE resolved = 0") ORDER BY file_id", cache: false) { $0.int64(0) }
        var updates: [(id: Int64, resolution: Resolution)] = []
        var changedEdges = Set<Int64>()
        var processed = 0
        var linked = 0
        var stats = Tally()
        var everyRowPending = true
        for fileID in pendingFiles {
            let rows = try loadRows(file: fileID)
            batch = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            batchFile = fileID
            for row in rows {
                guard row.pending else {
                    everyRowPending = false
                    continue
                }
                let resolution = resolve(row)
                stats.count(resolution)
                processed += 1
                if resolution.file != nil { linked += 1 }
                if resolution != row.stored {
                    updates.append((row.id, resolution))
                    if resolution.isEdge != row.stored.isEdge || (resolution.isEdge && resolution.file != row.stored.file) {
                        changedEdges.insert(fileID)
                    }
                }
            }
            // Only the references that type a declaration can be needed again, from another file.
            for row in rows where !declarationRefs.contains(row.id) {
                memo[row.id] = nil
                producedTypes[row.id] = nil
                refCache[row.id] = nil
            }
            batch = [:]
            batchFile = nil
        }
        trace("resolve \(processed) in \(pendingFiles.count) files, \(updates.count) changed", since: &phase)

        let totalRows = try db.scalarInt("SELECT COUNT(*) FROM refs")
        try db.transaction {
            // Rewriting most rows is cheaper with the indexes over the rewritten columns rebuilt afterwards.
            let rebuilt = updates.count >= 20_000 && updates.count * 2 >= totalRows ? try dropResolutionIndexes() : []
            try write(updates)
            trace("write: apply \(updates.count)", since: &phase)
            // Every pending row belongs to a file processed above; unchanged ones only need the flag.
            try db.run("UPDATE refs SET resolved = 1 WHERE resolved = 0")
            try db.run("DELETE FROM meta WHERE key = 'link_everything'")
            for statement in rebuilt { try db.execute(statement) }
            trace("write: flags\(rebuilt.isEmpty ? "" : " + \(rebuilt.count) indexes")", since: &phase)
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('linked_at', ?)", [String(Date().timeIntervalSince1970)])
            try writeStats(everyRowPending && processed == totalRows ? stats : nil,
                           processed: processed, seconds: Date().timeIntervalSince(started))
            trace("write: stats", since: &phase)
        }
        trace("write: commit", since: &phase)
        resetRunState()
        return Result(processed: processed, linked: linked, filesWithChangedEdges: changedEdges)
    }

    /// Indexes over the columns `link()` writes. Their definitions come from the schema, so they cannot drift.
    private static let resolutionIndexes = [
        "idx_refs_target_symbol", "idx_refs_target_file", "idx_refs_unresolved", "idx_refs_receiver_type", "idx_refs_external", "idx_refs_alt",
    ]

    /// Drops the resolution indexes and returns the statements that recreate them.
    private func dropResolutionIndexes() throws -> [String] {
        var statements: [String] = []
        for name in Self.resolutionIndexes {
            guard let statement = IndexSchema.statements.first(where: { $0.hasPrefix("CREATE INDEX IF NOT EXISTS \(name) ") }) else { continue }
            try db.execute("DROP INDEX IF EXISTS \(name)")
            statements.append(statement)
        }
        return statements
    }

    /// Writes changed resolutions: staged in an in-memory table many rows per statement, then applied with one
    /// `UPDATE … FROM` (a statement per row costs more than the update itself).
    private func write(_ updates: [(id: Int64, resolution: Resolution)]) throws {
        guard !updates.isEmpty else { return }
        try db.execute("""
            CREATE TEMP TABLE IF NOT EXISTS link_updates(id INTEGER PRIMARY KEY, symbol INTEGER, file INTEGER, confidence REAL,
                basis TEXT, receiver_type TEXT, is_external INTEGER, module TEXT, alt INTEGER, evidence INTEGER)
            """)
        try db.execute("DELETE FROM link_updates")
        let chunk = 200
        var start = 0
        while start < updates.count {
            let slice = updates[start..<min(updates.count, start + chunk)]
            var values: [any SQLBindable] = []
            values.reserveCapacity(slice.count * 10)
            for update in slice {
                let resolution = update.resolution
                values.append(update.id)
                values.append(resolution.symbol)
                values.append(resolution.file)
                values.append(resolution.confidence)
                values.append(resolution.basis?.rawValue)
                values.append(resolution.receiverType)
                values.append(resolution.isExternal)
                values.append(resolution.externalModule)
                values.append(resolution.altSymbol)
                values.append(resolution.evidenceLine)
            }
            let placeholders = Array(repeating: "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", count: slice.count).joined(separator: ", ")
            try db.run("INSERT INTO link_updates VALUES \(placeholders)", values)
            start += chunk
        }
        try db.run("""
            UPDATE refs SET target_symbol_id = u.symbol, target_file_id = u.file, confidence = u.confidence, resolved = 1, basis = u.basis,
                receiver_type = u.receiver_type, is_external = u.is_external, external_module = u.module, alt_symbol_id = u.alt,
                type_evidence_line = u.evidence
            FROM link_updates u WHERE refs.id = u.id
            """)
        try db.execute("DELETE FROM link_updates")
    }

    private static let tracing = ProcessInfo.processInfo.environment["VESALIUS_TRACE"] != nil

    /// Prints a phase timing to stderr when VESALIUS_TRACE is set.
    private func trace(_ phase: String, since start: inout Date) {
        guard Self.tracing else { return }
        let now = Date()
        FileHandle.standardError.write(Data(String(format: "[trace]   link: %-40@ %6.2fs\n", phase as NSString, now.timeIntervalSince(start)).utf8))
        start = now
    }

    private func resetRunState() {
        memo = [:]
        resolving = []
        producedTypes = [:]
        typing = []
        typingDepth = 0
        declaredTypes = [:]
        declaringSymbols = []
        inferredProperties = [:]
        legacyGuesses = [:]
        batch = [:]
        batchFile = nil
        refCache = [:]
        mentionsByFile = [:]
    }

    private static let rowColumns = """
        id, file_id, from_symbol_id, name, kind, context, line, receiver, receiver_hint, receiver_ref, arg_labels, resolved,
        target_symbol_id, target_file_id, confidence, basis, receiver_type, is_external, external_module, alt_symbol_id, type_evidence_line
        """

    private static func row(_ row: SQLRow, everything: Bool) -> RefRow {
        let labels = row.optionalString(10).map { $0.isEmpty ? [] : $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        return RefRow(
            id: row.int64(0),
            fileID: row.int64(1),
            fromSymbol: row.optionalInt64(2),
            name: row.string(3),
            kind: ReferenceKind(rawValue: row.string(4)) ?? .typeUse,
            context: row.optionalString(5),
            line: row.int(6),
            receiver: row.optionalString(7),
            receiverHint: row.optionalString(8),
            receiverRef: row.optionalInt64(9),
            argumentLabels: labels,
            pending: everything || !row.bool(11),
            stored: Resolution(
                symbol: row.optionalInt64(12), file: row.optionalInt64(13), confidence: row.double(14),
                basis: row.optionalString(15).flatMap(ResolutionBasis.init(rawValue:)), receiverType: row.optionalString(16),
                isExternal: row.bool(17), externalModule: row.optionalString(18), altSymbol: row.optionalInt64(19), evidenceLine: row.optionalInt(20)
            )
        )
    }

    private func loadRows(file fileID: Int64) throws -> [RefRow] {
        let everything = relinkingEverything
        return try db.query("SELECT \(Self.rowColumns) FROM refs WHERE file_id = ? ORDER BY id", [fileID]) { Self.row($0, everything: everything) }
    }

    /// A row of the batch, or of another file (read once and cached).
    func refRow(_ id: Int64) -> RefRow? {
        if let row = batch[id] ?? refCache[id] { return row }
        let everything = relinkingEverything
        guard let row = (try? db.queryOne("SELECT \(Self.rowColumns) FROM refs WHERE id = ?", [id]) { Self.row($0, everything: everything) }) ?? nil else { return nil }
        refCache[id] = row
        return row
    }

    /// Rows that name a type. They resolve without any unique-name guess, so they can corroborate one.
    static func namesType(_ row: RefRow) -> Bool {
        switch row.kind {
        case .typeUse, .instantiate, .inherit, .conform: return true
        default: return false
        }
    }

    /// Repository types a file names at 0.85 or more, as a type or through an instantiation: an owner named there
    /// corroborates a unique-name guess for its member. Computed from the file's own rows whichever file is being
    /// linked, so a row resolves the same way on demand and in its own batch.
    func mentions(inFile fileID: Int64) -> Set<Int64> {
        if let known = mentionsByFile[fileID] { return known }
        mentionsByFile[fileID] = []  // A type use met again while computing this set corroborates nothing.
        let rows: [RefRow]
        if fileID == batchFile {
            rows = Array(batch.values)
        } else {
            let everything = relinkingEverything
            rows = (try? db.query("SELECT \(Self.rowColumns) FROM refs WHERE file_id = ? AND kind IN ('type', 'instantiate', 'inherit', 'conform')", [fileID]) { Self.row($0, everything: everything) }) ?? []
            for row in rows where refCache[row.id] == nil && batch[row.id] == nil { refCache[row.id] = row }
        }
        var types = Set<Int64>()
        for row in rows.sorted(by: { $0.id < $1.id }) where Self.namesType(row) {
            let resolution = row.pending ? resolve(row) : row.stored
            guard resolution.confidence >= 0.85, let target = resolution.symbol, let symbol = symbols[target] else { continue }
            if symbol.kind.isType {
                types.insert(target)
            } else if symbol.kind == .initializer, let owner = symbol.ownerID {
                if case .repo(let type)? = containerType(owner)?.type { types.insert(type) }
            }
        }
        mentionsByFile[fileID] = types
        return types
    }

    /// Counts of how references resolved, for `link_stats`.
    struct Tally {
        var byBasis: [String: Int] = [:]
        var external = 0
        var unresolved = 0
        var belowThreshold = 0
        var total = 0

        mutating func add(basis: String, isExternal: Bool, hasTarget: Bool, aboveThreshold: Bool, count: Int = 1) {
            total += count
            if !basis.isEmpty { byBasis[basis, default: 0] += count }
            if isExternal {
                external += count
            } else if basis.isEmpty || !hasTarget && !aboveThreshold {
                unresolved += count
            } else if !aboveThreshold {
                belowThreshold += count
            }
        }

        mutating func count(_ resolution: Resolution) {
            add(basis: resolution.basis?.rawValue ?? "", isExternal: resolution.isExternal, hasTarget: resolution.symbol != nil || resolution.file != nil,
                aboveThreshold: resolution.confidence >= ReferenceLinker.edgeThreshold)
        }
    }

    /// `link_stats`: how the index's references resolved, for the status line and the golden checks. When this
    /// run re-linked every row, the counts are already known; otherwise they are read back.
    private func writeStats(_ known: Tally?, processed: Int, seconds: Double) throws {
        var tally = known ?? Tally()
        if known == nil {
            try db.forEach("""
                SELECT COALESCE(basis, ''), is_external, target_symbol_id IS NOT NULL OR target_file_id IS NOT NULL, confidence >= ?, COUNT(*)
                FROM refs GROUP BY 1, 2, 3, 4
                """, [Self.edgeThreshold]) { row in
                tally.add(basis: row.string(0), isExternal: row.bool(1), hasTarget: row.bool(2), aboveThreshold: row.bool(3), count: row.int(4))
            }
        }
        let (byBasis, external, unresolved, belowThreshold, total) = (tally.byBasis, tally.external, tally.unresolved, tally.belowThreshold, tally.total)
        struct Stats: Encodable {
            let refs: Int
            let processed: Int
            let basis: [String: Int]
            let external: Int
            let unresolved: Int
            let belowThreshold: Int
            let seconds: Double
        }
        let stats = Stats(refs: total, processed: processed, basis: byBasis, external: external, unresolved: unresolved,
                          belowThreshold: belowThreshold, seconds: (seconds * 1000).rounded() / 1000)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(stats), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('link_stats', ?)", [json])
    }

    /// Recomputes outgoing file edges for the given source files from resolved references and imports.
    public func rebuildEdges(for fileIDs: Set<Int64>) throws {
        guard !fileIDs.isEmpty else { return }
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS edge_sources(id INTEGER PRIMARY KEY)")
        try db.execute("DELETE FROM edge_sources")
        try db.transaction {
            for id in fileIDs { try db.run("INSERT OR IGNORE INTO edge_sources(id) VALUES(?)", [id]) }
            try db.run("DELETE FROM file_edges WHERE src_file_id IN (SELECT id FROM edge_sources)")
            // External references and environment variables have no target file, so they never become edges.
            try db.run("""
                INSERT INTO file_edges(src_file_id, dst_file_id, kind, weight)
                SELECT file_id, target_file_id,
                    CASE kind
                        WHEN 'call' THEN 'calls' WHEN 'decorator' THEN 'calls'
                        WHEN 'inherit' THEN 'inherits' WHEN 'conform' THEN 'conformsTo'
                        WHEN 'instantiate' THEN 'instantiates' WHEN 'read' THEN 'reads' WHEN 'write' THEN 'writes'
                        ELSE 'references' END AS edge_kind,
                    SUM(count)
                FROM refs
                WHERE file_id IN (SELECT id FROM edge_sources)
                  AND target_file_id IS NOT NULL AND target_file_id != file_id AND confidence >= ?
                GROUP BY file_id, target_file_id, edge_kind
                """, [Self.edgeThreshold])
            try db.run("""
                INSERT INTO file_edges(src_file_id, dst_file_id, kind, weight)
                SELECT file_id, resolved_file_id, 'imports', COUNT(*)
                FROM imports
                WHERE file_id IN (SELECT id FROM edge_sources) AND resolved_file_id IS NOT NULL AND resolved_file_id != file_id
                  AND is_mock = 0
                GROUP BY file_id, resolved_file_id
                ON CONFLICT(src_file_id, dst_file_id, kind) DO UPDATE SET weight = weight + excluded.weight
                """)
        }
    }

    // MARK: - Resolution

    static let selfReceivers: Set<String> = ["self", "this", "Self", "cls", "super"]

    /// Resolves one row, memoized; a row met again while it is being resolved (a receiver cycle) is unresolved.
    func resolve(_ row: RefRow) -> Resolution {
        if let known = memo[row.id] { return known }
        guard resolving.insert(row.id).inserted else { return .unresolved }
        defer { resolving.remove(row.id) }
        var resolution = compute(row)
        // A hinted receiver's evidence line is the collector's; the linker never rewrites it.
        if row.receiverHint != nil { resolution.evidenceLine = row.stored.evidenceLine }
        memo[row.id] = resolution
        return resolution
    }

    /// The resolution of another row: its stored one unless it is pending in this run.
    func resolution(ofRef id: Int64) -> Resolution? {
        guard let row = refRow(id) else { return nil }
        return row.pending ? resolve(row) : row.stored
    }

    private func compute(_ row: RefRow) -> Resolution {
        guard let file = files[row.fileID] else { return .unresolved }
        // 0. An environment variable (`env:NAME`) is its own target: resolved, but never a declaration.
        if row.name.hasPrefix("env:") {
            return Resolution(symbol: nil, file: nil, confidence: 1, basis: .env)
        }
        // An implicit member (`.red`, `.data(…)`) takes its type from context.
        if row.receiver == "." { return resolveImplicit(row, file: file) }

        // A. Explicit import bindings, including packages outside the repository.
        if file.family == .script || file.family == .python, let bound = resolveImport(row, file: file) {
            return bound
        }

        let receiver = row.receiver
        let isSelfLike = receiver.map { Self.selfReceivers.contains($0) } ?? true
        let isTypeReceiver = !isSelfLike && receiver?.first?.isUppercase == true && row.receiverHint == nil && row.receiverRef == nil

        // T. The receiver's type is known: the collector's hint, its producing reference, or (for an index built
        // before the collector recorded either) the declared type of the property the receiver names.
        if !isSelfLike && !isTypeReceiver, let typed = resolveTypedReceiver(row, file: file) {
            return typed
        }

        // B. Members of the enclosing type (implicit or explicit self); `super` walks the superclass chain only.
        if isSelfLike, let member = resolveSelf(row, file: file) {
            return member
        }

        // C. Same-file declarations.
        if receiver == nil, let local = resolveSameFile(row, file: file) {
            return local
        }

        // D. Receiver is a type or a module: static members, enum cases, nested types (`AuthService.shared`).
        if isTypeReceiver, let member = resolveStatic(row, file: file) {
            return member
        }

        // E. Name lookup without a known receiver type.
        return resolveFallback(row, file: file)
    }

    /// Steps whose receiver identifies the type: returns the resolution with the v3 unique-name guess recorded as
    /// `alt_symbol_id` when it differs ("rejected lookalikes").
    func withLookalike(_ resolution: Resolution, for row: RefRow, file: FileInfo) -> Resolution {
        guard let guess = legacyGuess(row, file: file), guess != resolution.symbol else { return resolution }
        var result = resolution
        result.altSymbol = guess
        return result
    }

    // MARK: - Candidate helpers

    func compatible(_ symbolID: Int64, family: Family) -> Bool {
        guard let symbol = symbols[symbolID], let file = files[symbol.fileID] else { return false }
        switch (family, file.family) {
        case (.swift, .swift), (.script, .script), (.python, .python): return true
        case (.swift, .other(.objectiveC)), (.other(.objectiveC), .swift): return true
        case (.other(let a), .other(let b)): return a == b || [a, b].allSatisfy { [.c, .cpp, .objectiveC].contains($0) }
        default: return false
        }
    }

    func kindMatches(_ symbolKind: SymbolKind, _ reference: ReferenceKind) -> Bool {
        switch reference {
        case .typeUse, .inherit, .conform:
            return symbolKind.isType || symbolKind == .namespace
        case .instantiate:
            return symbolKind.isType || symbolKind == .function
        case .call, .decorator:
            return symbolKind.isCallable || symbolKind.isType || symbolKind == .property || symbolKind == .variable || symbolKind == .constant || symbolKind == .enumCase
        case .read, .write, .member:
            return symbolKind != .extension
        }
    }

    /// Picks the candidate closest to the referencing file: same file, same module, imported module, same
    /// directory, shared top-level directory. Equal scores go to the first in (path, line) order, so the choice
    /// does not depend on dictionary order.
    func bestByLocality(_ candidates: [Int64], file fileID: Int64) -> Int64? {
        guard candidates.count > 1 else { return candidates.first }
        guard let info = files[fileID] else { return candidates.min { rank($0) < rank($1) } }
        let imported = moduleImports[fileID] ?? []
        func score(_ id: Int64) -> Double {
            guard let symbol = symbols[id], let other = files[symbol.fileID] else { return -1 }
            var value = 0.0
            if symbol.fileID == fileID { value += 8 }
            if let module = other.moduleID {
                if module == info.moduleID { value += 4 } else if imported.contains(module) { value += 2 }
            }
            if other.directory == info.directory { value += 1.5 }
            if other.topDirectory == info.topDirectory { value += 0.5 }
            if symbol.isExported { value += 0.25 }
            return value
        }
        var best = candidates[0]
        var bestScore = score(best)
        for candidate in candidates.dropFirst() {
            let value = score(candidate)
            if value > bestScore || value == bestScore && rank(candidate) < rank(best) {
                best = candidate
                bestScore = value
            }
        }
        return best
    }

    func rank(_ id: Int64) -> Int { symbolRank[id] ?? Int.max }

    /// A top-level variable or constant with a capitalised name (`let API = Client()`), used as a receiver.
    func isGlobalValue(_ name: String) -> Bool {
        (byName[name] ?? []).contains { id in
            guard let symbol = symbols[id], symbol.ownerName == nil, !symbol.isLocal else { return false }
            return symbol.kind == .variable || symbol.kind == .constant || symbol.kind == .property
        }
    }
}

// MARK: - Resolution steps

extension ReferenceLinker {
    /// T: the receiver's type is known. A repository type answers with its member (0.95; 0.9 through a superclass,
    /// a protocol or a protocol receiver; 0.7 when labels leave several overloads); a framework type with a
    /// repository extension member or an external reference; a tuple with its element.
    func resolveTypedReceiver(_ row: RefRow, file: FileInfo) -> Resolution? {
        guard row.receiverHint != nil || row.receiverRef != nil || row.receiver.map(Self.isInferableReceiver) == true,
              let receiver = receiverType(of: row) else { return nil }
        guard var resolution = member(row, of: receiver.value, file: file, basis: .typed, missing: !receiver.inferred) else { return nil }
        resolution.confidence = min(resolution.confidence, receiver.cap)
        resolution.evidenceLine = receiver.evidence
        return withLookalike(resolution, for: row, file: file)
    }

    /// The member a use names on a value (or, `isMetatype`, on a type). `missing`: when the type has no such
    /// member, report the site unresolved (with its receiver type) instead of returning nil.
    func member(_ row: RefRow, of value: ValueType, file: FileInfo, basis: ResolutionBasis, missing: Bool = true) -> Resolution? {
        if case .tuple(let labels, _) = value.type {
            guard labels.contains(row.name) else { return missing ? .unresolved : nil }
            return Resolution(symbol: nil, file: nil, confidence: 0.9, basis: basis, receiverType: "(tuple)")
        }
        let receiverName = typeName(value.type)
        let accept: (Int64) -> Bool = { self.acceptsMember($0, row: row, file: file, isMetatype: value.isMetatype) }
        if let hit = lookupMember(value.type, named: row.name, accept: accept), let choice = choose(hit.ids, row: row) {
            var confidence: Double
            switch hit.level {
            case .direct: confidence = isProtocol(value.type) ? 0.9 : 0.95
            case .inherited, .protocolMember, .externalExtension: confidence = 0.9
            }
            if choice.ambiguous { confidence = 0.7 }
            return Resolution(symbol: choice.id, file: symbols[choice.id]?.fileID, confidence: choice.legacy ? confidence * 0.9 : confidence,
                              basis: basis, receiverType: receiverName)
        }
        switch value.type {
        case .repo(let id):
            if let parent = frameworkParent(of: id, member: row.name) {
                var external = externalMember(of: parent, row: row, basis: basis)
                external.receiverType = receiverName
                return external
            }
            if Self.standardMembers.contains(row.name) {
                // `book.map { … }` on an optional, `.first` on a collection: the type grammar drops `?` and `[]` wrappers.
                var external = externalMember(of: receiverName, row: row, basis: basis)
                external.externalModule = "Swift"
                return external
            }
            guard missing else { return nil }
            var unresolved = Resolution.unresolved
            unresolved.receiverType = receiverName
            return unresolved
        case .external(let name):
            return externalMember(of: name, row: row, basis: basis)
        case .array, .dictionary:
            return externalMember(of: receiverName, row: row, basis: basis)
        case .tuple:
            return nil
        }
    }

    /// Optional and collection members a receiver typed by its unwrapped or element type still reaches.
    static let standardMembers: Set<String> = [
        "map", "flatMap", "compactMap", "filter", "reduce", "forEach", "sorted", "contains", "first", "last", "count", "isEmpty",
        "joined", "enumerated", "reversed", "prefix", "suffix", "dropFirst", "dropLast", "allSatisfy", "firstIndex", "lastIndex",
        "min", "max", "indices", "lazy", "unsafelyUnwrapped", "none", "some",
    ]

    func isProtocol(_ type: LinkType) -> Bool {
        guard case .repo(let id) = type else { return false }
        return symbols[id]?.kind == .protocol || symbols[id]?.kind == .interface
    }

    /// The framework type an undeclared member of a repository type comes from: its external superclass, else an
    /// external protocol it adopts (`View`, `ObservableObject`), searching up the superclass chain. A standard
    /// protocol whose members are all known gives only those (`Sendable` none, `Hashable` `hashValue`), and an enum's
    /// raw type only `rawValue`: a member no parent gives (stale code, or a receiver typed by a generic parameter's
    /// constraint) stays unresolved rather than becoming a framework reference.
    func frameworkParent(of typeID: Int64, member name: String) -> String? {
        let isSwift = symbols[typeID].flatMap { files[$0.fileID] }?.family == .swift
        var current: Int64? = typeID
        var hops = 0
        while let id = current, hops < 12 {
            hops += 1
            switch superclasses[id] {
            case .external(let parent)?: return parent
            case .repo(let superclass)?: current = superclass
            case nil: current = nil
            }
            if current == nil, let parents = externalParents[id] {
                let cataloged = parents.filter { FrameworkCatalog.module(forType: $0) != nil }
                return (cataloged + parents.filter { !cataloged.contains($0) }).first { !isSwift || Self.gives($0, member: name) }
            }
        }
        return nil
    }

    /// Whether a Swift framework parent can be where a member comes from.
    static func gives(_ parent: String, member name: String) -> Bool {
        if let known = FrameworkCatalog.knownMembers(ofProtocol: parent) { return known.contains(name) }
        if FrameworkCatalog.rawValueTypes.contains(parent) { return name == "rawValue" || name == "init" || name == "hashValue" || name == "hash" }
        return true
    }

    /// A candidate member for a use: same language family, a kind the use can name, the right side of the
    /// static/instance divide, and visible from the use.
    func acceptsMember(_ id: Int64, row: RefRow, file: FileInfo, isMetatype: Bool) -> Bool {
        guard let symbol = symbols[id], compatible(id, family: file.family), kindMatches(symbol.kind, row.kind) else { return false }
        if file.family == .swift || file.family == .other(.objectiveC) {
            let isTypeSide = symbol.isTypeLevel || symbol.kind == .initializer
            guard isTypeSide == isMetatype else { return false }
        }
        return access(id, from: row.fileID, line: row.line).isVisible
    }

    /// Narrows candidates by the call's argument labels and picks one. `ambiguous`: overloads the labels cannot
    /// separate remain; `legacy`: only the legacy visibility rule admits the choice.
    func choose(_ ids: [Int64], row: RefRow) -> (id: Int64, ambiguous: Bool, legacy: Bool)? {
        guard !ids.isEmpty else { return nil }
        var pool = ids
        if let labels = row.argumentLabels, row.context != ReferenceContext.pattern.rawValue {
            let strict = ids.filter { labelsFit(labels, symbol: $0, lenient: false) }
            let fitting = strict.isEmpty ? ids.filter { labelsFit(labels, symbol: $0, lenient: true) } : strict
            pool = fitting.isEmpty ? ids : fitting
        }
        let visible = pool.filter { access($0, from: row.fileID, line: row.line) == .visible }
        let final = visible.isEmpty ? pool : visible
        if final.count == 1 { return (final[0], false, visible.isEmpty) }
        // A requirement and its default, or one declaration under two `#if` branches, are one choice; overloads that
        // differ only in parameter types are not.
        let signatures = Set(final.map { id -> String in
            guard let symbol = symbols[id] else { return "" }
            return (symbol.selector ?? symbol.name) + "|" + (symbol.parameterTypes ?? "")
        })
        let declared = final.filter { id in symbols[id]?.ownerID.flatMap { symbols[$0]?.kind } != .extension }
        guard let best = bestByLocality(signatures.count == 1 && !declared.isEmpty ? declared : final, file: row.fileID) else { return nil }
        return (best, signatures.count > 1, visible.isEmpty)
    }

    /// Whether a call's labels fit a declaration's selector and parameter flags. Declarations without a selector
    /// (properties holding closures, types) fit any call.
    func labelsFit(_ labels: [String], symbol id: Int64, lenient: Bool) -> Bool {
        guard let symbol = symbols[id], symbol.selector != nil, symbol.kind.isCallable || symbol.kind == .enumCase,
              symbol.name != "subscript", Self.isIdentifierName(symbol.name) else { return true }
        return Self.assignArguments(labels, to: symbol.parameterLabels, flags: symbol.flagCharacters, lenient: lenient) != nil
    }

    static func isIdentifierName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        return first == "_" || CharacterSet.letters.contains(first)
    }

    /// B: a member of the enclosing type, through its extensions, superclasses and protocols (0.92 in the same
    /// file, else 0.85); an unqualified name also reaches static members and nested types of outer types.
    /// `super` starts at the superclass, so an override never resolves to itself.
    func resolveSelf(_ row: RefRow, file: FileInfo) -> Resolution? {
        // TypeScript and Python reach members only through `this` / `self`.
        if row.receiver == nil, file.family == .script || file.family == .python { return nil }
        let containers = containerChain(row.fromSymbol)
        guard let innermost = containers.first, let selfType = containerType(innermost) else { return nil }
        let accept: (Int64) -> Bool = { id in
            guard let symbol = self.symbols[id], self.compatible(id, family: file.family), self.kindMatches(symbol.kind, row.kind) else { return false }
            return self.access(id, from: row.fileID, line: row.line).isVisible
        }
        func found(_ ids: [Int64], on type: LinkType) -> Resolution? {
            guard let choice = choose(ids, row: row) else { return nil }
            let sameFile = symbols[choice.id]?.fileID == row.fileID
            let confidence = sameFile ? 0.92 : 0.85
            return Resolution(symbol: choice.id, file: symbols[choice.id]?.fileID, confidence: choice.legacy ? confidence * 0.9 : confidence,
                              basis: .self, receiverType: typeName(type))
        }

        if row.receiver == "super" {
            guard case .repo(let typeID) = selfType.type, let parent = superclasses[typeID] else { return .unresolved }
            switch parent {
            case .repo(let superclass):
                if let hit = lookupMember(.repo(superclass), named: row.name, accept: accept), let resolution = found(hit.ids, on: .repo(superclass)) {
                    return resolution
                }
                if let framework = frameworkParent(of: superclass, member: row.name) { return externalMember(of: framework, row: row, basis: .self) }
                return .unresolved
            case .external(let name):
                if let hit = lookupMember(.external(name), named: row.name, accept: accept), let resolution = found(hit.ids, on: .external(name)) {
                    return resolution
                }
                return externalMember(of: name, row: row, basis: .self)
            }
        }

        if let hit = lookupMember(selfType.type, named: row.name, accept: accept), let resolution = found(hit.ids, on: selfType.type) {
            return resolution
        }
        if row.receiver == nil {
            for outer in containers.dropFirst() {
                guard let outerType = containerType(outer) else { continue }
                let typeLevel: (Int64) -> Bool = { id in accept(id) && self.symbols[id]?.isTypeLevel == true }
                if let hit = lookupMember(outerType.type, named: row.name, accept: typeLevel), let resolution = found(hit.ids, on: outerType.type) {
                    return resolution
                }
            }
            return nil
        }
        // `self.x` that the repository does not declare comes from a framework parent, or is unknown.
        switch selfType.type {
        case .repo(let id):
            if let framework = frameworkParent(of: id, member: row.name) {
                var external = externalMember(of: framework, row: row, basis: .self)
                external.receiverType = typeName(selfType.type)
                return external
            }
            return .unresolved
        case .external(let name):
            return externalMember(of: name, row: row, basis: .self)
        default:
            return .unresolved
        }
    }

    /// C: a top-level declaration of the same file, or a function-local one in scope (0.9).
    func resolveSameFile(_ row: RefRow, file: FileInfo) -> Resolution? {
        let candidates = (byName[row.name] ?? []).filter { id in
            guard let symbol = symbols[id], symbol.fileID == row.fileID, symbol.ownerName == nil, kindMatches(symbol.kind, row.kind) else { return false }
            return !symbol.isLocal || (symbol.scope?.contains(row.line) ?? true)
        }
        guard let best = candidates.first else { return nil }
        return Resolution(symbol: best, file: row.fileID, confidence: 0.9, basis: .lexical)
    }

    /// D: the receiver names a type (static members, enum cases, nested types: 0.88, or 0.65 when ambiguous), a
    /// repository module (`AtlasKit.load()`), a capitalised global value, or a framework type (an external reference).
    func resolveStatic(_ row: RefRow, file: FileInfo) -> Resolution? {
        guard let receiver = row.receiver else { return nil }
        let target = resolveTypeName(receiver, fileID: row.fileID, anchor: row.fromSymbol)
        if case .repo(let id)? = target {
            let staticAccept: (Int64) -> Bool = { self.acceptsMember($0, row: row, file: file, isMetatype: true) }
            let anyAccept: (Int64) -> Bool = { id in
                guard let symbol = self.symbols[id], self.compatible(id, family: file.family), self.kindMatches(symbol.kind, row.kind) else { return false }
                return self.access(id, from: row.fileID, line: row.line).isVisible
            }
            if let hit = lookupMember(.repo(id), named: row.name, accept: staticAccept) ?? lookupMember(.repo(id), named: row.name, accept: anyAccept),
               let choice = choose(hit.ids, row: row) {
                let confidence = choice.ambiguous ? 0.65 : 0.88
                return Resolution(symbol: choice.id, file: symbols[choice.id]?.fileID, confidence: choice.legacy ? confidence * 0.9 : confidence,
                                  basis: .static, receiverType: qualifiedName(id))
            }
            if let module = resolveInModule(row, file: file) { return module }
            if let framework = frameworkParent(of: id, member: row.name) {
                var external = externalMember(of: framework, row: row, basis: .static)
                external.receiverType = qualifiedName(id)
                return external
            }
            if file.family == .swift, Self.standardMembers.contains(row.name) {
                // `ReadingLevel?.none`: the type grammar drops the optional.
                var external = externalMember(of: qualifiedName(id), row: row, basis: .static)
                external.externalModule = "Swift"
                return external
            }
            var unresolved = Resolution.unresolved
            unresolved.receiverType = qualifiedName(id)
            return unresolved
        }
        if let module = resolveInModule(row, file: file) { return module }
        if file.family == .swift, isGlobalValue(receiver), let global = globalValue(receiver, row: row), let value = declaredValueType(of: global),
           let typed = member(row, of: value, file: file, basis: .typed, missing: false) {
            return withLookalike(typed, for: row, file: file)
        }
        guard case .external(let name)? = target, file.family == .swift || file.family == .other(.objectiveC) else {
            return isGlobalValue(receiver) ? nil : .unresolved
        }
        // A repository extension of the framework type (`extension Color { static let brand }`).
        let staticAccept: (Int64) -> Bool = { self.acceptsMember($0, row: row, file: file, isMetatype: true) }
        if let hit = lookupMember(.external(name), named: row.name, accept: staticAccept), let choice = choose(hit.ids, row: row) {
            let confidence = choice.ambiguous ? 0.65 : 0.88
            return Resolution(symbol: choice.id, file: symbols[choice.id]?.fileID, confidence: confidence, basis: .static, receiverType: name)
        }
        if isGlobalValue(receiver) { return nil }
        return externalMember(of: name, row: row, basis: .static)
    }

    /// `AtlasKit.load()`: a top-level declaration of the repository module the receiver names (0.9, or 0.6 when
    /// the module has several).
    private func resolveInModule(_ row: RefRow, file: FileInfo) -> Resolution? {
        guard file.family == .swift, let receiver = row.receiver, let modules = modulesByName[receiver] else { return nil }
        let inModule = (byName[row.name] ?? []).filter { id in
            guard let symbol = symbols[id], symbol.ownerName == nil, !symbol.isLocal, let module = files[symbol.fileID]?.moduleID,
                  kindMatches(symbol.kind, row.kind) else { return false }
            return modules.contains(module) && access(id, from: row.fileID, line: row.line) != .denied
        }
        guard let best = bestByLocality(inModule, file: row.fileID) else { return nil }
        return Resolution(symbol: best, file: symbols[best]?.fileID, confidence: inModule.count == 1 ? 0.9 : 0.6, basis: .static, receiverType: receiver)
    }

    /// The top-level variable a capitalised receiver names (`API` in `API.fetch()`).
    private func globalValue(_ name: String, row: RefRow) -> Int64? {
        let candidates = (byName[name] ?? []).filter { id in
            guard let symbol = symbols[id], symbol.ownerName == nil, !symbol.isLocal,
                  symbol.kind == .variable || symbol.kind == .constant || symbol.kind == .property else { return false }
            return access(id, from: row.fileID, line: row.line).isVisible
        }
        return bestByLocality(candidates, file: row.fileID)
    }

    /// `.`: an implicit member. With a contextual type (`ctx(…)`, `param(^,i)`, a type), the type-level member or
    /// case of that type (0.95), or an external reference for a framework type; a collection a reference produces
    /// stands for its element. When the context is a framework API whose type the index cannot name, only a
    /// repository extension of a framework type can declare the member. Without any context, the only repository
    /// static member or case of that name (0.6), unless SwiftUI and the standard library use the name everywhere.
    func resolveImplicit(_ row: RefRow, file: FileInfo) -> Resolution {
        if let hint = row.receiverHint, let expression = parsedHint(hint) {
            if var context = resolve(expression, file: row.fileID, anchor: row.fromSymbol, producer: row.receiverRef) {
                // `repairs.contains(.dropStaleBookmark)`, `items.append(.init(…))`: the collector leaves a produced
                // collection to the linker, and the member is its element's unless the collection declares it.
                if hint.contains("^"), case .array(let element?) = context.type,
                   lookupMember(context.type, named: row.name, accept: { self.acceptsMember($0, row: row, file: file, isMetatype: true) }) == nil {
                    context = ValueType(type: element)
                }
                if row.name == "init", case .repo(let id) = context.type {
                    return Resolution(symbol: id, file: symbols[id]?.fileID, confidence: 0.95, basis: .typed, receiverType: qualifiedName(id))
                }
                context.isMetatype = true
                return member(row, of: context, file: file, basis: .typed) ?? .unresolved
            }
            // `ctx.fill(path, with: .color(.red))`, `.font(.system(size: 12))`: the parameter or operand is a framework
            // type. Generic standard-library and XCTest APIs (`XCTAssertEqual(state, .idle)`) take their type from
            // another argument, so their implicit members keep the repository-wide guess below.
            if let producer = row.receiverRef, let source = resolution(ofRef: producer), source.isExternal,
               !Self.genericModules.contains(source.externalModule ?? ""), let api = refRow(producer)?.name,
               !Self.genericFrameworkAPIs.contains(api) {
                return frameworkImplicit(row, file: file, module: source.externalModule)
            }
        }
        guard !FallbackStoplist.implicit.contains(row.name) else { return .unresolved }
        let candidates = (byName[row.name] ?? []).filter { id in
            guard let symbol = symbols[id], symbol.ownerName != nil, symbol.isTypeLevel, !symbol.kind.isType,
                  compatible(id, family: file.family), kindMatches(symbol.kind, row.kind), Self.canBeImplicit(symbol, row) else { return false }
            return access(id, from: row.fileID, line: row.line).isVisible
        }
        let fitting = row.argumentLabels.map { labels in candidates.filter { labelsFit(labels, symbol: $0, lenient: false) } } ?? candidates
        guard fitting.count == 1, let only = fitting.first else { return .unresolved }
        let legacy = access(only, from: row.fileID, line: row.line) == .legacy
        return Resolution(symbol: only, file: symbols[only]?.fileID, confidence: legacy ? 0.54 : 0.6, basis: .uniqueName,
                          receiverType: symbols[only]?.ownerID.map(qualifiedName))
    }

    /// Whether a declaration can be what an implicit member names when only its name chose it: `.date` that is not
    /// called is a case or a property (`displayedComponents: [.date]`), never a method that takes arguments.
    static func canBeImplicit(_ symbol: SymbolInfo, _ row: RefRow) -> Bool {
        row.argumentLabels != nil || !symbol.kind.isCallable
    }

    /// Modules whose generic APIs give an implicit member the type of another argument.
    static let genericModules: Set<String> = ["Swift", "XCTest", "Testing"]

    /// Framework APIs generic in a type another argument names: `.focused($field, equals: .email)`,
    /// `JSONDecoder().decode(Mode.self, from: data) == .walk`.
    static let genericFrameworkAPIs: Set<String> = [
        "focused", "defaultFocus", "environment", "transformEnvironment", "focusedValue", "focusedSceneValue", "preference",
        "tag", "decode", "decodeIfPresent", "unarchivedObject", "fetch",
    ]

    /// An implicit member in a framework type's context: the only member a repository extension of a framework type
    /// declares with that name (`extension Font { static let brand }` for `.font(.brand)`, 0.6), else the framework's
    /// own member (an external reference to the API's module).
    private func frameworkImplicit(_ row: RefRow, file: FileInfo, module: String?) -> Resolution {
        var candidates = (byName[row.name] ?? []).filter { id in
            guard let symbol = symbols[id], let owner = symbol.ownerID, case .external? = extensionTargets[owner],
                  Self.canBeImplicit(symbol, row) else { return false }
            return acceptsMember(id, row: row, file: file, isMetatype: true)
        }
        if let labels = row.argumentLabels { candidates = candidates.filter { labelsFit(labels, symbol: $0, lenient: false) } }
        if candidates.count == 1, let only = candidates.first {
            let legacy = access(only, from: row.fileID, line: row.line) == .legacy
            return Resolution(symbol: only, file: symbols[only]?.fileID, confidence: legacy ? 0.54 : 0.6, basis: .uniqueName,
                              receiverType: symbols[only]?.ownerID.map(qualifiedName))
        }
        guard candidates.isEmpty else { return .unresolved }
        return Resolution(symbol: nil, file: nil, confidence: 0.9, basis: .external, isExternal: true, externalModule: module)
    }

    /// E: no receiver type. Unqualified names resolve lexically against top-level declarations (0.85 unique, 0.75
    /// unique in the module, else 0.55 / 0.35) or become framework references; a member of a value of unknown type
    /// binds only to the one visible member of that name, at 0.45 (0.6 when corroborated), never for stoplisted names.
    func resolveFallback(_ row: RefRow, file: FileInfo) -> Resolution {
        let candidates = (byName[row.name] ?? []).filter { id in
            guard let symbol = symbols[id] else { return false }
            return compatible(id, family: file.family) && kindMatches(symbol.kind, row.kind)
        }
        switch file.family {
        case .script, .python:
            guard row.receiver == nil else { return .unresolved }
            // Without an import, only global declarations (ambient .d.ts types, exported classes) are reachable.
            let typeLike = candidates.filter { id in
                guard let symbol = symbols[id], symbol.kind.isType, symbol.ownerName == nil, !symbol.isLocal else { return false }
                return access(id, from: row.fileID, line: row.line).isVisible
            }
            guard typeLike.count == 1, let only = typeLike.first, let info = symbols[only] else { return .unresolved }
            if files[info.fileID]?.isDeclarationFile == true {
                return Resolution(symbol: only, file: info.fileID, confidence: 0.7, basis: .lexical)
            }
            guard file.family == .script else { return .unresolved }
            return Resolution(symbol: only, file: info.fileID, confidence: 0.5, basis: .uniqueName)
        case .swift, .other:
            if let receiver = row.receiver, !Self.selfReceivers.contains(receiver) {
                return valueFallback(row, file: file, candidates: candidates)
            }
            return unqualifiedFallback(row, file: file, candidates: candidates)
        }
    }

    private func valueFallback(_ row: RefRow, file: FileInfo, candidates: [Int64]) -> Resolution {
        let isSwift = file.family == .swift
        let stoplisted = FallbackStoplist.names.contains(row.name)
        var members = candidates.filter { id in
            guard let symbol = symbols[id], symbol.ownerName != nil else { return false }
            if stoplisted {
                // A stoplisted name still reaches a member of a function-local type in scope.
                guard symbol.isLocal, symbol.fileID == row.fileID, symbol.scope?.contains(row.line) ?? true else { return false }
            }
            return !isSwift || (!symbol.isTypeLevel && symbol.kind != .initializer)
        }
        if let labels = row.argumentLabels {
            members = members.filter { labelsFit(labels, symbol: $0, lenient: true) }
        }
        let reachable = members.filter { access($0, from: row.fileID, line: row.line).isVisible }
        if reachable.count == 1, let only = reachable.first {
            let legacy = access(only, from: row.fileID, line: row.line) == .legacy
            let confidence = corroborates(only, row: row) ? 0.6 : 0.45
            return Resolution(symbol: only, file: symbols[only]?.fileID, confidence: legacy ? confidence * 0.9 : confidence, basis: .uniqueName)
        }
        if (2...3).contains(reachable.count), let best = bestByLocality(reachable, file: row.fileID) {
            return Resolution(symbol: best, file: symbols[best]?.fileID, confidence: 0.35, basis: .uniqueName)
        }
        if reachable.isEmpty {
            // Declared only in a module this code never imports: keep the guess, out of the graph.
            let unimported = members.filter { access($0, from: row.fileID, line: row.line) == .notImported }
            if unimported.count == 1, unimported.count == members.count {
                return Resolution(symbol: unimported[0], file: symbols[unimported[0]]?.fileID, confidence: 0.3, basis: .uniqueName)
            }
        }
        return .unresolved
    }

    private func unqualifiedFallback(_ row: RefRow, file: FileInfo, candidates: [Int64]) -> Resolution {
        let isSwift = file.family == .swift
        let topLevel = candidates.filter { id in
            guard let symbol = symbols[id] else { return false }
            return symbol.ownerName == nil && !symbol.isLocal
        }
        var visible = topLevel.filter { access($0, from: row.fileID, line: row.line).isVisible }
        if isSwift, visible.count > 1 {
            let strict = visible.filter { access($0, from: row.fileID, line: row.line) == .visible }
            if !strict.isEmpty { visible = strict }
        }
        func lexical(_ id: Int64, _ confidence: Double) -> Resolution {
            let legacy = access(id, from: row.fileID, line: row.line) == .legacy
            return Resolution(symbol: id, file: symbols[id]?.fileID, confidence: legacy ? confidence * 0.9 : confidence, basis: .lexical)
        }
        if visible.count == 1 { return lexical(visible[0], 0.85) }
        if visible.count > 1 {
            let own = files[row.fileID]?.moduleID
            let sameModule = visible.filter { id in
                guard let symbol = symbols[id] else { return false }
                return files[symbol.fileID]?.moduleID == own || (isSwift && relation(from: row.fileID, to: symbol.fileID).sharedTarget)
            }
            if sameModule.count == 1 { return lexical(sameModule[0], 0.75) }
            let pool = sameModule.isEmpty ? visible : sameModule
            if let best = bestByLocality(pool, file: row.fileID) { return lexical(best, pool.count <= 2 ? 0.55 : 0.35) }
        }
        if isSwift {
            // Nothing in the repository this file can see: a framework type or function.
            let imports = externalImports[row.fileID] ?? []
            let typeLike = row.name.first?.isUppercase == true
            if typeLike, FrameworkCatalog.module(forType: row.name, imports: imports) != nil {
                return Resolution(symbol: nil, file: nil, confidence: 0.9, basis: .external, isExternal: true, externalModule: externalModule(forType: row.name, fileID: row.fileID))
            }
            if !typeLike, let module = FrameworkCatalog.module(forFunction: row.name, imports: imports) {
                return Resolution(symbol: nil, file: nil, confidence: 0.9, basis: .external, isExternal: true, externalModule: module)
            }
            if typeLike, candidates.isEmpty, row.kind != .call || row.argumentLabels != nil {
                return Resolution(symbol: nil, file: nil, confidence: 0.9, basis: .external, isExternal: true, externalModule: soleFrameworkImport(row.fileID))
            }
            if let best = bestByLocality(topLevel.filter({ access($0, from: row.fileID, line: row.line) == .notImported }), file: row.fileID) {
                return Resolution(symbol: best, file: symbols[best]?.fileID, confidence: 0.3, basis: .lexical)
            }
        }
        if FallbackStoplist.names.contains(row.name) { return .unresolved }
        let containers = containerChain(row.fromSymbol)
        if let innermost = containers.first {
            // Inside a type, an unqualified name the repository hierarchy lacks comes from a framework parent.
            guard isSwift, case .repo(let id)? = containerType(innermost)?.type ?? nil, let framework = frameworkParent(of: id, member: row.name) else {
                if isSwift, case .external(let name)? = containerType(innermost)?.type {
                    return externalMember(of: name, row: row, basis: .self, confidence: 0.85)
                }
                return .unresolved
            }
            var external = externalMember(of: framework, row: row, basis: .self, confidence: 0.85)
            external.receiverType = qualifiedName(id)
            return external
        }
        // Top-level code: the only member of that name anywhere visible.
        var members = candidates.filter { symbols[$0]?.ownerName != nil && access($0, from: row.fileID, line: row.line).isVisible }
        if let labels = row.argumentLabels { members = members.filter { labelsFit(labels, symbol: $0, lenient: true) } }
        guard members.count == 1, let only = members.first else { return .unresolved }
        return Resolution(symbol: only, file: symbols[only]?.fileID, confidence: corroborates(only, row: row) ? 0.6 : 0.45, basis: .uniqueName)
    }

    /// A unique-name guess is corroborated when the file names the member's owner type at high confidence, or when
    /// the receiver shares a word with the owner (`wax` → `Wax`, `session` → `WaxSession`).
    func corroborates(_ candidate: Int64, row: RefRow) -> Bool {
        guard let symbol = symbols[candidate], let owner = symbol.ownerID else { return false }
        if case .repo(let ownerType)? = containerType(owner)?.type, mentions(inFile: row.fileID).contains(ownerType) { return true }
        guard let receiver = row.receiver, Self.isPlainIdentifier(receiver), let ownerName = symbol.ownerName else { return false }
        let receiverWords = words(receiver)
        return words(ownerName).contains { word in
            receiverWords.contains(word) || receiverWords.contains(word + "s") || receiverWords.contains(word + "es")
        }
    }

    /// The lowercase words of an identifier (three letters or more), memoized.
    private func words(_ identifier: String) -> Set<String> {
        if let known = identifierWords[identifier] { return known }
        let words = Set(Tokenizer.splitIdentifier(identifier).filter { $0.count >= 3 })
        identifierWords[identifier] = words
        return words
    }
}
