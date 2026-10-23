import Foundation
import VesaliusCore

/// The linker's type index: declarations by name, each type's members (extensions included by identity),
/// superclasses and protocol conformances, and the types expressions produce. It reads the collector → linker
/// type grammar (`receiver_hint`, `symbols.declared_type`):
///
///     hint  := type | '^' | 'elem(' inner ')' | 'ctx(' inner ')' | 'param(^,' INT ')' | '?'
///     inner := type | '^'
///     type  := nominal | '[' type ']' | '[' type ':' type ']' | '(' label ':' type (',' label ':' type)* ')'
extension ReferenceLinker {
    /// What a type name denotes: a repository declaration or a type outside the repository.
    enum TypeTarget: Hashable {
        case repo(Int64)
        case external(String)
    }

    indirect enum LinkType: Hashable {
        case repo(Int64)
        case external(String)
        case array(LinkType?)
        case dictionary(LinkType?, LinkType?)
        case tuple([String], [LinkType?])

        init(_ target: TypeTarget) {
            switch target {
            case .repo(let id): self = .repo(id)
            case .external(let name): self = .external(name)
            }
        }
    }

    /// The type of a value, or of a type itself when it is used as a receiver (`Foo.shared`).
    struct ValueType: Hashable {
        var type: LinkType
        var isMetatype = false
    }

    indirect enum TypeExpr: Hashable {
        case nominal(String)
        case array(TypeExpr)
        case dictionary(TypeExpr, TypeExpr)
        case tuple([String], [TypeExpr])
        /// `^`: the type produced by `receiver_ref` (for a declaration, `declared_type_ref`).
        case producer
        case element(TypeExpr)
        case context(TypeExpr)
        /// `param(^,i)`: parameter `i` of the callee whose call is `receiver_ref`.
        case parameter(Int)
        case unknown
    }

    enum MemberLevel {
        /// Declared by the type or one of its extensions.
        case direct
        /// Inherited from a repository superclass.
        case inherited
        /// A protocol requirement or protocol-extension default.
        case protocolMember
        /// Added by a repository extension of a type the repository does not declare (`extension View`).
        case externalExtension
    }

    struct TypeNameKey: Hashable {
        let file: Int64
        let anchor: Int64
        let name: String
    }

    struct InferenceKey: Hashable {
        let file: Int64
        let anchor: Int64
        let name: String
    }

    struct GuessKey: Hashable {
        let file: Int64
        let name: String
        let kind: ReferenceKind
    }

    // MARK: - Loading

    func load() throws {
        files = [:]
        try db.forEach("SELECT id, path, language, module_id FROM files") { row in
            let path = row.string(1)
            files[row.int64(0)] = FileInfo(
                path: path,
                directory: (path as NSString).deletingLastPathComponent,
                topDirectory: path.split(separator: "/").first ?? "",
                family: Family(Language(rawValue: row.string(2)) ?? .unknown),
                moduleID: row.optionalInt64(3),
                isDeclarationFile: path.hasSuffix(".d.ts")
            )
        }

        var loaded: [SymbolInfo] = []
        var depths: [Int64: Int] = [:]
        try db.forEach("""
            SELECT id, file_id, parent_id, name, kind, is_exported, attributes, is_local, visibility, start_line, end_line,
                selector, param_flags, param_types, declared_type, declared_type_ref, inherits, signature, depth
            FROM symbols
            """) { row in
            let kind = SymbolKind(rawValue: row.string(4)) ?? .variable
            let attributes = (row.optionalString(6) ?? "").split(separator: ",")
            let inherits = (row.optionalString(16) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let id = row.int64(0)
            depths[id] = row.int(18)
            loaded.append(SymbolInfo(
                id: id,
                fileID: row.int64(1),
                parentID: row.optionalInt64(2),
                name: row.string(3),
                kind: kind,
                isExported: row.bool(5),
                isDefaultExport: attributes.contains("default"),
                isTypeLevel: kind == .enumCase || attributes.contains("static") || attributes.contains("class"),
                macroParents: kind.isType ? attributes.compactMap { Self.macroConformances[String($0)] } : [],
                projection: attributes.contains("@Published") ? "Published.Publisher" : nil,
                visibility: row.optionalString(8).flatMap(Visibility.init(rawValue:)),
                startLine: row.int(9),
                endLine: row.int(10),
                selector: row.optionalString(11),
                parameterFlags: row.optionalString(12),
                parameterTypes: row.optionalString(13),
                declaredType: row.optionalString(14),
                declaredTypeRef: row.optionalInt64(15),
                inherits: inherits,
                signature: row.optionalString(17),
                ownerName: nil,
                ownerID: nil,
                isLocal: row.bool(7),
                isFileScoped: false,
                scope: nil
            ))
        }
        // (path, start line, id) order, comparing paths once: a file's rank is its position in path order.
        var fileRanks: [Int64: Int] = [:]
        for (rank, id) in files.keys.sorted(by: { files[$0]!.path < files[$1]!.path }).enumerated() { fileRanks[id] = rank }
        loaded.sort { a, b in
            let fileA = fileRanks[a.fileID] ?? -1, fileB = fileRanks[b.fileID] ?? -1
            if fileA != fileB { return fileA < fileB }
            if a.startLine != b.startLine { return a.startLine < b.startLine }
            return a.id < b.id
        }
        symbols = [:]
        symbolRank = [:]
        symbols.reserveCapacity(loaded.count)
        for (index, symbol) in loaded.enumerated() {
            symbols[symbol.id] = symbol
            symbolRank[symbol.id] = index
        }
        orderedSymbols = loaded

        // Owners, nesting, locality and file scope.
        hasLocalSymbols = false
        for info in loaded {
            if let parentID = info.parentID, let parent = symbols[parentID], parent.kind.isContainer {
                info.ownerName = parent.name.split(separator: ".").last.map(String.init) ?? parent.name
                info.ownerID = parentID
                if info.kind.isType { info.isTypeLevel = true }
            }
            var current = info.parentID
            var outermostLocal: SymbolInfo? = info.isLocal ? info : nil
            var hops = 0
            let family = files[info.fileID]?.family
            if Self.confinesToFile(info.visibility, family) { info.isFileScoped = true }
            while let parentID = current, let parent = symbols[parentID], hops < 16 {
                if parent.isLocal {
                    info.isLocal = true
                    outermostLocal = parent
                }
                if Self.confinesToFile(parent.visibility, family), parent.kind.isContainer {
                    info.isFileScoped = true
                }
                current = parent.parentID
                hops += 1
            }
            if info.isLocal {
                hasLocalSymbols = true
                // A local declaration is visible inside the body of the declaration that contains it.
                if let owner = outermostLocal?.parentID.flatMap({ symbols[$0] }) {
                    info.scope = owner.startLine...max(owner.startLine, owner.endLine)
                }
            }
        }

        byName = [:]
        topLevel = [:]
        defaultExports = [:]
        typesByName = [:]
        for info in loaded {
            if info.kind != .extension { byName[info.name, default: []].append(info.id) }
            if info.kind.isType { typesByName[info.name, default: []].append(info.id) }
            if depths[info.id] == 0, topLevel[info.fileID]?[info.name] == nil {
                topLevel[info.fileID, default: [:]][info.name] = info.id
            }
            if info.isDefaultExport, defaultExports[info.fileID] == nil { defaultExports[info.fileID] = info.id }
        }

        try loadImports()
        try loadProjectModel()
        buildTypeIndex()
    }

    /// Extensions by identity, members per type, superclasses and conformances. Needs imports and targets,
    /// because an extended or inherited name resolves like any type name in its file.
    private func buildTypeIndex() {
        extensionTargets = [:]
        membersByType = [:]
        externalMembers = [:]
        superclasses = [:]
        conformances = [:]
        externalParents = [:]
        externalConformances = [:]
        typeNames = [:]
        containerChains = [:]
        genericParameterCache = [:]
        parameterNameCache = [:]
        qualifiedNames = [:]
        fileRelations = [:]
        fileScopes = [:]

        let ordered = orderedSymbols
        // Members declared in the types themselves first: extending `Outer.Inner` needs `Inner` as a member of `Outer`.
        var declared: [Int64: [String: [Int64]]] = [:]
        for symbol in ordered {
            guard let owner = symbol.ownerID, symbols[owner]?.kind != .extension else { continue }
            declared[owner, default: [:]][symbol.name, default: []].append(symbol.id)
        }
        membersByType = declared
        // Then extensions, twice: a type nested in one extension can be what another extension extends.
        for _ in 0..<2 {
            typeNames = [:]
            for symbol in ordered where symbol.kind == .extension {
                extensionTargets[symbol.id] = resolveTypeName(symbol.name, fileID: symbol.fileID, anchor: nil)
            }
            var members = declared
            externalMembers = [:]
            for symbol in ordered {
                guard let owner = symbol.ownerID, symbols[owner]?.kind == .extension else { continue }
                switch extensionTargets[owner] {
                case .repo(let type)?:
                    members[type, default: [:]][symbol.name, default: []].append(symbol.id)
                case .external(let name)?:
                    externalMembers[name, default: [:]][symbol.name, default: []].append(symbol.id)
                    if let last = name.split(separator: ".").last.map(String.init), last != name {
                        externalMembers[last, default: [:]][symbol.name, default: []].append(symbol.id)
                    }
                case nil:
                    break
                }
            }
            membersByType = members
        }
        typeNames = [:]
        // Conformances a macro adds (`@Model` → PersistentModel), whose members the repository never declares.
        for symbol in ordered where !symbol.macroParents.isEmpty {
            externalParents[symbol.id, default: []].append(contentsOf: symbol.macroParents)
        }

        // Parents: a class's first inherited name is its superclass when it names a class (or a framework type that
        // is not a well-known protocol); every repository protocol named is a conformance.
        for symbol in ordered where !symbol.inherits.isEmpty && (symbol.kind.isType || symbol.kind == .extension) {
            let subject: TypeTarget
            if symbol.kind == .extension {
                guard let target = extensionTargets[symbol.id] else { continue }
                subject = target
            } else {
                subject = .repo(symbol.id)
            }
            for (index, inherited) in symbol.inherits.enumerated() {
                let parent = resolveTypeName(inherited, fileID: symbol.fileID, anchor: symbol.id)
                let isFirstOfClass = index == 0 && symbol.kind == .class
                switch (subject, parent) {
                case (.repo(let type), .repo(let parentID)?):
                    let parentKind = symbols[parentID]?.kind
                    if isFirstOfClass, parentKind == .class {
                        superclasses[type] = .repo(parentID)
                    } else if parentKind == .protocol || parentKind == .interface {
                        conformances[type, default: []].append(parentID)
                    } else if parentKind == .class, symbols[type]?.kind == .class {
                        superclasses[type] = superclasses[type] ?? .repo(parentID)
                    }
                case (.repo(let type), .external(let name)?):
                    if isFirstOfClass, !Self.wellKnownProtocols.contains(name) {
                        superclasses[type] = .external(name)
                    }
                    externalParents[type, default: []].append(name)
                case (.external(let name), .repo(let parentID)?):
                    if symbols[parentID]?.kind == .protocol { externalConformances[name, default: []].append(parentID) }
                default:
                    break
                }
            }
        }
    }

    /// Whether an access level keeps a declaration in its file: Swift `private`/`fileprivate`, TypeScript `private`.
    /// Python's leading underscore is a convention (subclasses and importers use such names), and the lexical
    /// analyzer reports Java/Kotlin `protected` as `fileprivate`, so only `private` counts outside Swift.
    static func confinesToFile(_ visibility: Visibility?, _ family: Family?) -> Bool {
        switch family {
        case .python?: return false
        case .swift?: return visibility == .private || visibility == .fileprivate
        default: return visibility == .private
        }
    }

    /// Attached macros that make a type conform to a framework protocol.
    static let macroConformances: [String: String] = ["@Model": "PersistentModel", "@Observable": "Observable"]

    /// Standard protocols a class may list first without having a superclass.
    static let wellKnownProtocols: Set<String> = [
        "Codable", "Decodable", "Encodable", "Hashable", "Equatable", "Comparable", "Identifiable", "Sendable",
        "ObservableObject", "CustomStringConvertible", "CustomDebugStringConvertible", "Error", "LocalizedError",
        "CaseIterable", "RawRepresentable", "Actor", "View", "App", "Scene", "AnyObject", "NSObjectProtocol",
        "AppIntent", "TimelineProvider", "Widget", "ViewModifier", "Shape", "PreviewProvider", "Collection", "Sequence",
    ]

    // MARK: - Containers and generic parameters

    /// Types and extensions enclosing a symbol, innermost first.
    func containerChain(_ anchor: Int64?) -> [Int64] {
        guard let anchor else { return [] }
        if let known = containerChains[anchor] { return known }
        var chain: [Int64] = []
        var current: Int64? = anchor
        var hops = 0
        while let id = current, let symbol = symbols[id], hops < 16 {
            if symbol.kind.isContainer { chain.append(id) }
            current = symbol.parentID
            hops += 1
        }
        containerChains[anchor] = chain
        return chain
    }

    /// The type a container stands for: itself, or what its extension extends.
    func containerType(_ container: Int64) -> ValueType? {
        guard let symbol = symbols[container] else { return nil }
        if symbol.kind == .extension { return extensionTargets[container].map { ValueType(type: LinkType($0)) } }
        return symbol.kind.isType ? ValueType(type: .repo(container)) : nil
    }

    /// Generic parameters a declaration introduces (`<T: Store, Key>`), mapped to their first constraint.
    func genericParameters(of symbolID: Int64) -> [String: String?] {
        if let known = genericParameterCache[symbolID] { return known }
        var result: [String: String?] = [:]
        if let symbol = symbols[symbolID], let signature = symbol.signature, let clause = Self.genericClause(signature, name: symbol.name) {
            for parameter in Self.splitTopLevel(clause, separator: ",") {
                let parts = parameter.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let name = parts.first, !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
                let constraint = parts.count > 1 ? Self.nominalPrefix(parts[1]) : nil
                result[name] = .some(constraint)
            }
        }
        genericParameterCache[symbolID] = result
        return result
    }

    /// The text between `<` and its `>` right after the declared name in a signature.
    static func genericClause(_ signature: String, name: String) -> String? {
        guard signature.utf8.contains(UInt8(ascii: "<")), let nameRange = signature.range(of: name + "<") else { return nil }
        var index = nameRange.upperBound
        var depth = 1
        var clause = ""
        while index < signature.endIndex {
            let character = signature[index]
            if character == "<" { depth += 1 }
            if character == ">" {
                depth -= 1
                if depth == 0 { return clause }
            }
            clause.append(character)
            index = signature.index(after: index)
        }
        return nil
    }

    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            switch character {
            case "<", "(", "[": depth += 1
            case ">", ")", "]": depth -= 1
            default: break
            }
            if character == separator && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    /// The dotted identifier a type text starts with (`Store & Sendable` → `Store`, `any Foo.Bar` → `Foo.Bar`).
    static func nominalPrefix(_ text: String) -> String? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        for keyword in ["some ", "any ", "inout ", "borrowing ", "consuming "] where rest.hasPrefix(keyword) {
            rest = rest.dropFirst(keyword.count)
        }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        guard let first = name.first, first.isLetter || first == "_" else { return nil }
        return String(name).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    // MARK: - Type names

    /// What a type name means in a file, seen from a declaration (`anchor`): a generic parameter's constraint, a
    /// nested type of an enclosing type, a local type in scope, an imported or same-module type, else a type
    /// outside the repository. Memoized per (file, anchor, name).
    func resolveTypeName(_ dotted: String, fileID: Int64, anchor: Int64?) -> TypeTarget? {
        // Seen from inside a type, the answer depends on the enclosing type only, unless a generic parameter or a
        // function-local type of that name could be in scope.
        let first = dotted.split(separator: ".", maxSplits: 1).first.map(String.init) ?? dotted
        var memoAnchor = anchor ?? 0
        if let anchor, first != "Self", genericConstraint(first, anchor: anchor) == nil,
           !(typesByName[first] ?? []).contains(where: { symbols[$0]?.isLocal == true }) {
            memoAnchor = containerChain(anchor).first.map { -$0 } ?? 0
        }
        let key = TypeNameKey(file: fileID, anchor: memoAnchor, name: dotted)
        if let known = typeNames[key] { return known }
        typeNames[key] = .some(nil)  // A name met again while it is being resolved (an alias cycle) means nothing.
        let result = lookupTypeName(dotted, fileID: fileID, anchor: anchor)
        typeNames[key] = .some(result)
        return result
    }

    private func lookupTypeName(_ dotted: String, fileID: Int64, anchor: Int64?) -> TypeTarget? {
        // PHP/C# namespace containers are not enclosing types. Match an explicit qualified
        // annotation, or a type in the current/imported namespace, without guessing between
        // duplicate declarations. Other language families keep the original resolution path.
        if let family = files[fileID]?.family, family == .other(.php) || family == .other(.csharp) {
            var names: Set<String> = [dotted]
            if !dotted.contains(".") {
                var parent = anchor
                var depth = 0
                while let id = parent, let symbol = symbols[id], depth < 64 {
                    if symbol.kind == .namespace { names.insert(qualifiedName(id) + "." + dotted) }
                    parent = symbol.parentID
                    depth += 1
                }
                if family == .other(.csharp) {
                    for module in externalImports[fileID] ?? [] { names.insert(module + "." + dotted) }
                }
            }
            let leaf = dotted.split(separator: ".").last.map(String.init) ?? dotted
            let exact = (typesByName[leaf] ?? []).filter { id in
                guard let symbol = symbols[id], !symbol.isLocal, compatible(id, family: family),
                      access(id, from: fileID, line: anchor.flatMap { symbols[$0]?.startLine } ?? 0).isVisible else { return false }
                return names.contains(qualifiedName(id))
            }
            if exact.count == 1 { return .repo(exact[0]) }
            if exact.count > 1 { return nil }
        }
        let components = dotted.split(separator: ".").map(String.init)
        guard let first = components.first, !first.isEmpty else { return nil }
        var current: TypeTarget?
        var rest = components.dropFirst()
        if first == "Self" {
            guard let container = containerChain(anchor).first, let type = containerType(container)?.type else { return nil }
            switch type {
            case .repo(let id): current = .repo(id)
            case .external(let name): current = .external(name)
            default: return nil
            }
        } else if let generic = genericConstraint(first, anchor: anchor) {
            // A generic parameter stands for its constraint; without one it says nothing about members.
            guard let constraint = generic else { return nil }
            current = resolveTypeName(constraint, fileID: fileID, anchor: nil)
        } else if let found = firstComponent(first, fileID: fileID, anchor: anchor) {
            current = found
        } else if !rest.isEmpty, let modules = modulesByName[first] {
            // `AtlasKit.Model`: a type of a repository module, named through the module.
            let next = rest.removeFirst()
            let candidates = (typesByName[next] ?? []).filter { id in
                guard let symbol = symbols[id], symbol.ownerName == nil, !symbol.isLocal, let module = files[symbol.fileID]?.moduleID else { return false }
                return modules.contains(module)
            }
            guard let best = bestByLocality(candidates, file: fileID) else { return .external(dotted) }
            current = .repo(best)
        } else {
            return .external(dotted)
        }
        for component in rest {
            switch current.map({ target -> TypeTarget in
                if case .repo(let id) = target { return aliasTarget(id) ?? target }
                return target
            }) {
            case .repo(let resolved)?:
                let nested = (membersByType[resolved]?[component] ?? []).filter { symbols[$0]?.kind.isType == true }
                guard let best = bestByLocality(nested, file: fileID) else { return nil }
                current = .repo(best)
            case .external(let name)?:
                current = .external(name + "." + component)
            case nil:
                return nil
            }
        }
        if case .repo(let id)? = current, let alias = aliasTarget(id) { return alias }
        return current
    }

    /// The constraint of a generic parameter declared by the anchor or a declaration around it: `.some(nil)` for
    /// an unconstrained parameter, nil when no enclosing declaration has one of that name.
    private func genericConstraint(_ name: String, anchor: Int64?) -> String?? {
        var current = anchor
        var hops = 0
        while let id = current, let symbol = symbols[id], hops < 16 {
            if let constraint = genericParameters(of: id)[name] { return .some(constraint) }
            current = symbol.parentID
            hops += 1
        }
        return nil
    }

    private func firstComponent(_ name: String, fileID: Int64, anchor: Int64?) -> TypeTarget? {
        guard let file = files[fileID] else { return nil }
        let line = anchor.flatMap { symbols[$0]?.startLine }
        // Nested types of the enclosing types, innermost first.
        for container in containerChain(anchor) {
            guard case .repo(let type)? = containerType(container)?.type else { continue }
            let nested = (membersByType[type]?[name] ?? []).filter { id in
                guard let symbol = symbols[id], symbol.kind.isType else { return false }
                return isAccessible(id, from: fileID, line: line)
            }
            if let best = nested.min(by: { rank($0) < rank($1) }) { return .repo(best) }
        }
        let candidates = typesByName[name] ?? []
        // A function-local type in scope.
        if hasLocalSymbols, let local = candidates.first(where: { id in
            guard let symbol = symbols[id], symbol.isLocal, symbol.ownerName == nil, symbol.fileID == fileID else { return false }
            return line.map { symbol.scope?.contains($0) ?? true } ?? false
        }) {
            return .repo(local)
        }
        if file.family == .script || file.family == .python {
            if let binding = bindings[fileID]?[name] {
                switch binding {
                case .symbol(let target, let exported):
                    if let symbol = lookupExport(file: target, name: exported, depth: 0), symbols[symbol]?.kind.isType == true { return .repo(symbol) }
                case .defaultExport(let target):
                    if let symbol = defaultSymbol(file: target), symbols[symbol]?.kind.isType == true { return .repo(symbol) }
                case .module:
                    break
                }
            }
            if let external = externalBindings[fileID]?[name] { return .external(external.exported == "default" || external.exported == "*" ? name : external.exported) }
            let visible = candidates.filter { id in
                guard let symbol = symbols[id], symbol.ownerName == nil, !symbol.isLocal else { return false }
                return symbol.fileID == fileID || files[symbol.fileID]?.isDeclarationFile == true
            }
            if let best = bestByLocality(visible, file: fileID) { return .repo(best) }
            return nil
        }
        // Top-level types this file can see.
        let visible = candidates.filter { id in
            guard let symbol = symbols[id], symbol.ownerName == nil, !symbol.isLocal, compatible(id, family: file.family) else { return false }
            return access(id, from: fileID, line: line ?? 0).isVisible
        }
        if let best = bestByLocality(visible, file: fileID) { return .repo(best) }
        return nil
    }

    /// For a type alias: what it stands for (`typealias D = ReadingDuration`). Nil for anything else, or for an
    /// associated type without a default.
    func aliasTarget(_ id: Int64) -> TypeTarget? {
        guard let symbol = symbols[id], symbol.kind == .typeAlias else { return nil }
        let text: String?
        if let declared = symbol.declaredType, declared != "^", declared != "?" {
            text = declared
        } else if let signature = symbol.signature, let equals = signature.firstIndex(of: "="), signature.hasPrefix("typealias") || signature.contains("typealias ") {
            text = Self.nominalPrefix(String(signature[signature.index(after: equals)...]))
        } else {
            text = nil
        }
        guard let text, let expression = Self.parseType(text), case .nominal(let name) = expression else { return nil }
        guard name != symbol.name else { return nil }
        return resolveTypeName(name, fileID: symbol.fileID, anchor: symbol.parentID)
    }

    // MARK: - Members

    /// Members named `name` reachable on a type, from the nearest level that has an accepted one: the type and
    /// its extensions, its superclass chain, its protocols (requirements and defaults), then repository
    /// extensions of its framework parents.
    func lookupMember(_ type: LinkType, named name: String, accept: (Int64) -> Bool) -> (ids: [Int64], level: MemberLevel)? {
        switch type {
        case .repo(let id):
            if case .external(let name2)? = aliasTarget(id) { return lookupMember(.external(name2), named: name, accept: accept) }
            let typeID: Int64
            if case .repo(let resolved)? = aliasTarget(id) { typeID = resolved } else { typeID = id }
            return lookupRepoMember(typeID, named: name, accept: accept)
        case .external(let external):
            return lookupExternalMember([external] + Self.standardParents(external), named: name, accept: accept)
        case .array:
            return lookupExternalMember(["Array", "Collection", "Sequence", "RandomAccessCollection", "BidirectionalCollection", "MutableCollection", "RangeReplaceableCollection"], named: name, accept: accept)
        case .dictionary:
            return lookupExternalMember(["Dictionary", "Collection", "Sequence"], named: name, accept: accept)
        case .tuple:
            return nil
        }
    }

    private func lookupRepoMember(_ typeID: Int64, named name: String, accept: (Int64) -> Bool) -> (ids: [Int64], level: MemberLevel)? {
        let isProtocol = symbols[typeID]?.kind == .protocol || symbols[typeID]?.kind == .interface
        if let direct = membersByType[typeID]?[name]?.filter(accept), !direct.isEmpty {
            return (direct, isProtocol ? .protocolMember : .direct)
        }
        // The superclass chain.
        var chain: [Int64] = [typeID]
        var externalNames: [String] = externalParents[typeID] ?? []
        var current = superclasses[typeID]
        var hops = 0
        while let parent = current, hops < 12 {
            hops += 1
            switch parent {
            case .repo(let superclass):
                guard !chain.contains(superclass) else { current = nil; continue }
                chain.append(superclass)
                if let inherited = membersByType[superclass]?[name]?.filter(accept), !inherited.isEmpty {
                    return (inherited, .inherited)
                }
                externalNames.append(contentsOf: externalParents[superclass] ?? [])
                current = superclasses[superclass]
            case .external(let external):
                if !externalNames.contains(external) { externalNames.append(external) }
                current = nil
            }
        }
        // Protocols of the type and its superclasses, breadth first, with their parents.
        var queue: [Int64] = chain.flatMap { conformances[$0] ?? [] }
        if isProtocol { queue = conformances[typeID] ?? [] }
        var seen = Set<Int64>(isProtocol ? [typeID] : [])
        var index = 0
        while index < queue.count {
            let proto = queue[index]
            index += 1
            guard seen.insert(proto).inserted else { continue }
            if let found = membersByType[proto]?[name]?.filter(accept), !found.isEmpty {
                return (found, .protocolMember)
            }
            queue.append(contentsOf: conformances[proto] ?? [])
            externalNames.append(contentsOf: externalParents[proto] ?? [])
        }
        if let external = lookupExternalMember(externalNames, named: name, accept: accept) {
            return (external.ids, .externalExtension)
        }
        return nil
    }

    private func lookupExternalMember(_ names: [String], named name: String, accept: (Int64) -> Bool) -> (ids: [Int64], level: MemberLevel)? {
        var protocols: [Int64] = []
        for external in names {
            if let found = externalMembers[external]?[name]?.filter(accept), !found.isEmpty {
                return (found, .externalExtension)
            }
            protocols.append(contentsOf: externalConformances[external] ?? [])
        }
        var seen = Set<Int64>()
        var index = 0
        while index < protocols.count {
            let proto = protocols[index]
            index += 1
            guard seen.insert(proto).inserted else { continue }
            if let found = membersByType[proto]?[name]?.filter(accept), !found.isEmpty {
                return (found, .protocolMember)
            }
            protocols.append(contentsOf: conformances[proto] ?? [])
        }
        return nil
    }

    /// Protocols (standard library, SwiftUI) whose repository extensions a framework value also has.
    static func standardParents(_ name: String) -> [String] {
        switch name {
        case "String", "Substring": return ["StringProtocol", "Collection", "Sequence", "BidirectionalCollection", "RangeReplaceableCollection", "Comparable", "Hashable"]
        case "Set": return ["SetAlgebra", "Collection", "Sequence", "Hashable"]
        case "Array", "ArraySlice", "ContiguousArray": return ["Collection", "Sequence", "RandomAccessCollection", "BidirectionalCollection", "MutableCollection", "RangeReplaceableCollection"]
        case "Dictionary": return ["Collection", "Sequence"]
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return ["BinaryInteger", "FixedWidthInteger", "Numeric", "AdditiveArithmetic", "Comparable", "Hashable"]
        case "Double", "Float", "CGFloat", "Float16":
            return ["BinaryFloatingPoint", "FloatingPoint", "Numeric", "AdditiveArithmetic", "Comparable", "Hashable"]
        case "Range", "ClosedRange": return ["Collection", "Sequence", "RangeExpression"]
        case "Optional": return []
        // SwiftUI views and shapes reach the repository's `extension View` (`Text(…).dataLabel()`).
        default: return FrameworkCatalog.protocols(of: name)
        }
    }

    /// Display name of a type, as `refs.receiver_type` records it.
    func typeName(_ type: LinkType) -> String {
        switch type {
        case .repo(let id): return qualifiedName(id)
        case .external(let name): return name
        case .array(let element): return "[" + (element.map(typeName) ?? "?") + "]"
        case .dictionary(let key, let value): return "[" + (key.map(typeName) ?? "?") + ": " + (value.map(typeName) ?? "?") + "]"
        case .tuple: return "(tuple)"
        }
    }

    /// `Outer.Inner` for a nested type; extensions contribute the name they extend.
    func qualifiedName(_ id: Int64) -> String {
        if let known = qualifiedNames[id] { return known }
        var parts: [String] = []
        var current: Int64? = id
        var hops = 0
        while let symbolID = current, let symbol = symbols[symbolID], hops < 12 {
            if symbol.kind.isType || symbol.kind == .extension || symbol.kind == .namespace {
                parts.append(symbol.name)
                if symbol.kind == .extension { break }
            } else if symbolID != id {
                break
            }
            current = symbol.parentID
            hops += 1
        }
        let name = parts.reversed().joined(separator: ".")
        qualifiedNames[id] = name
        return name
    }

    // MARK: - Types of expressions

    /// The type a reference produces: an instantiation's type, a type used as a receiver (a metatype), a member's
    /// declared type (a function's only when called), a case's or initializer's owner. Memoized, depth ≤ 6.
    func typeOf(ref id: Int64?) -> ValueType? {
        guard let id else { return nil }
        if let known = producedTypes[id] { return known }
        guard typingDepth < 6, typing.insert(id).inserted else { return nil }
        typingDepth += 1
        defer {
            typingDepth -= 1
            typing.remove(id)
        }
        guard let row = refRow(id), let resolution = resolution(ofRef: id) else { return nil }
        let type = producedType(row, resolution)
        producedTypes[id] = .some(type)
        return type
    }

    private func producedType(_ row: RefRow, _ resolution: Resolution) -> ValueType? {
        if resolution.receiverType == "(tuple)" {
            guard let receiver = receiverType(of: row)?.value, case .tuple(let labels, let types) = receiver.type,
                  let index = labels.firstIndex(of: row.name), let element = types[index] else { return nil }
            return ValueType(type: element)
        }
        if resolution.isExternal {
            if row.kind == .instantiate { return ValueType(type: .external(row.receiver.map { $0 + "." + row.name } ?? row.name)) }
            if row.kind == .typeUse { return ValueType(type: .external(row.receiver.map { $0 + "." + row.name } ?? row.name), isMetatype: true) }
            // `Calendar.current`, `FileManager.default`: a framework singleton has its type's type.
            if resolution.basis == .static, let owner = resolution.receiverType, Self.singletonNames.contains(row.name) {
                return ValueType(type: .external(owner))
            }
            return nil
        }
        // A guess never types anything: a chain through it would compound the guess.
        guard resolution.basis != .uniqueName, resolution.confidence >= ReferenceLinker.edgeThreshold,
              let target = resolution.symbol, let symbol = symbols[target] else { return nil }
        // `$availability` of a `@Published` property is its publisher, not the wrapped value.
        if row.context == ReferenceContext.projected.rawValue, let projection = symbol.projection {
            return ValueType(type: .external(projection))
        }
        if symbol.kind.isType {
            let type = aliasTarget(target) ?? .repo(target)
            return ValueType(type: LinkType(type), isMetatype: row.kind == .typeUse || row.kind == .read)
        }
        switch symbol.kind {
        case .initializer:
            return symbol.ownerID.flatMap(containerType)
        case .enumCase:
            if let declared = declaredValueType(of: target) { return declared }
            return symbol.ownerID.flatMap(containerType)
        case .function, .method, .macro:
            return row.kind == .call || row.kind == .instantiate ? declaredValueType(of: target) : nil
        default:
            return declaredValueType(of: target)
        }
    }

    /// Framework singletons whose value has the type they are read from (`URLSession.shared`).
    static let singletonNames: Set<String> = [
        "shared", "default", "standard", "current", "main", "processInfo", "autoupdatingCurrent", "now", "sharedApplication",
        "defaultCenter", "sharedInstance",
    ]

    /// A declaration's type: `symbols.declared_type` in the grammar above (`^` follows `declared_type_ref`), or for
    /// properties of an index whose collector did not record one, what the signature shows.
    func declaredValueType(of symbolID: Int64) -> ValueType? {
        if let known = declaredTypes[symbolID] { return known }
        guard let symbol = symbols[symbolID], declaringSymbols.insert(symbolID).inserted else { return nil }
        defer { declaringSymbols.remove(symbolID) }
        var result: ValueType?
        if let declared = symbol.declaredType, let expression = parsedHint(declared) {
            result = resolve(expression, file: symbol.fileID, anchor: symbol.parentID ?? symbol.id, producer: symbol.declaredTypeRef)
        } else if symbol.declaredType == nil {
            result = signatureType(of: symbol)
        }
        declaredTypes[symbolID] = .some(result)
        return result
    }

    /// Resolves a parsed hint or declared type in a file, seen from `anchor`; `^` is the type `producer` produces.
    func resolve(_ expression: TypeExpr, file fileID: Int64, anchor: Int64?, producer: Int64?) -> ValueType? {
        switch expression {
        case .nominal(let name):
            return resolveTypeName(name, fileID: fileID, anchor: anchor).map { ValueType(type: LinkType($0)) }
        case .array(let element):
            return ValueType(type: .array(resolve(element, file: fileID, anchor: anchor, producer: producer)?.type))
        case .dictionary(let key, let value):
            return ValueType(type: .dictionary(resolve(key, file: fileID, anchor: anchor, producer: producer)?.type,
                                               resolve(value, file: fileID, anchor: anchor, producer: producer)?.type))
        case .tuple(let labels, let types):
            return ValueType(type: .tuple(labels, types.map { resolve($0, file: fileID, anchor: anchor, producer: producer)?.type }))
        case .producer:
            return typeOf(ref: producer)
        case .element(let inner):
            guard let container = resolve(inner, file: fileID, anchor: anchor, producer: producer) else { return nil }
            return element(of: container.type).map { ValueType(type: $0) }
        case .context(let inner):
            return resolve(inner, file: fileID, anchor: anchor, producer: producer)
        case .parameter(let index):
            return parameterType(callee: producer, index: index)
        case .unknown:
            return nil
        }
    }

    /// `elem(X)`: what iterating X yields.
    func element(of type: LinkType) -> LinkType? {
        switch type {
        case .array(let element): return element
        case .dictionary(let key, let value): return .tuple(["key", "value"], [key, value])
        case .external(let name):
            switch name {
            case "String", "Substring": return .external("Character")
            case "Data": return .external("UInt8")
            default: return nil
            }
        default: return nil
        }
    }

    /// `param(^,i)`: the declared type of the parameter that argument `i` of the call fills. An instantiation resolves
    /// to its type, so its arguments fill the parameters of the initializers the labels fit (when they agree), or of a
    /// struct's memberwise initializer (`Card(style: .compact)` → the stored property `style`).
    private func parameterType(callee: Int64?, index: Int) -> ValueType? {
        guard let callee, let row = refRow(callee), let resolution = resolution(ofRef: callee), let target = resolution.symbol,
              let symbol = symbols[target] else { return nil }
        guard symbol.kind.isType else { return parameterType(of: target, call: row, index: index) }
        let accept: (Int64) -> Bool = { self.symbols[$0]?.kind == .initializer && self.access($0, from: row.fileID, line: row.line).isVisible }
        let initializers = lookupMember(.repo(target), named: "init", accept: accept)?.ids ?? []
        let fitting = row.argumentLabels.map { labels in initializers.filter { labelsFit(labels, symbol: $0, lenient: false) } } ?? initializers
        if !fitting.isEmpty {
            let types = fitting.map { parameterType(of: $0, call: row, index: index) }
            guard let first = types.first, types.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
        guard symbol.kind == .struct, let labels = row.argumentLabels, labels.indices.contains(index),
              labels[index] != "_", !labels[index].hasSuffix("{}") else { return nil }
        let stored = (membersByType[target]?[labels[index]] ?? []).first { id in
            guard let member = symbols[id] else { return false }
            return member.kind == .property && !member.isTypeLevel && member.ownerID == target
        }
        return stored.flatMap(declaredValueType)
    }

    private func parameterType(of symbolID: Int64, call row: RefRow, index: Int) -> ValueType? {
        guard let symbol = symbols[symbolID], let types = symbol.parameterTypes else { return nil }
        let parameterTypes = types.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        var position = index
        if let labels = row.argumentLabels, symbol.selector != nil, symbol.parameterFlags != nil,
           let assignment = Self.assignArguments(labels, to: symbol.parameterLabels, flags: symbol.flagCharacters), assignment.indices.contains(index) {
            position = assignment[index]
        }
        guard parameterTypes.indices.contains(position), let expression = parsedHint(parameterTypes[position]) else { return nil }
        return resolve(expression, file: symbol.fileID, anchor: symbol.id, producer: nil)
    }

    // MARK: - Receivers

    /// The receiver's type for a member use, from the collector's evidence, with the most confidence the evidence
    /// allows. Nil when the receiver is a local of unknown type (`?`) or nothing types it.
    func receiverType(of row: RefRow) -> (value: ValueType, cap: Double, inferred: Bool, evidence: Int?)? {
        if let hint = row.receiverHint {
            guard let expression = parsedHint(hint) else { return nil }
            return resolve(expression, file: row.fileID, anchor: row.fromSymbol, producer: row.receiverRef).map { ($0, 1, false, nil) }
        }
        if let receiverRef = row.receiverRef {
            guard let type = typeOf(ref: receiverRef) else { return nil }
            return (type, 1, false, resolution(ofRef: receiverRef)?.symbol.flatMap { evidenceLine(of: $0, in: row.fileID) })
        }
        guard let receiver = row.receiver else { return nil }
        // `$settings.usesSerifFont`: a property wrapper's projected value forwards the wrapped value's members.
        if receiver.hasPrefix("$"), Self.isPlainIdentifier(String(receiver.dropFirst())),
           let property = inferredProperty(String(receiver.dropFirst()), row: row), let type = declaredValueType(of: property) {
            return (type, 0.9, true, evidenceLine(of: property, in: row.fileID))
        }
        // An index whose collector predates receiver evidence: a plain identifier that names a property of the
        // enclosing type (or a global) is typed by that declaration, with less confidence, since a local of the
        // same name would shadow it.
        guard Self.isPlainIdentifier(receiver), let property = inferredProperty(receiver, row: row),
              let type = declaredValueType(of: property) else { return nil }
        return (type, 0.75, true, evidenceLine(of: property, in: row.fileID))
    }

    /// The line of a variable or property declared in `fileID` that types a receiver.
    private func evidenceLine(of symbolID: Int64, in fileID: Int64) -> Int? {
        guard let symbol = symbols[symbolID], symbol.fileID == fileID,
              symbol.kind == .property || symbol.kind == .variable || symbol.kind == .constant else { return nil }
        return symbol.startLine
    }

    /// A receiver the linker may type by the property it names: `store`, or a projected value `$store`.
    static func isInferableReceiver(_ text: String) -> Bool {
        isPlainIdentifier(text) || text.hasPrefix("$") && isPlainIdentifier(String(text.dropFirst()))
    }

    static func isPlainIdentifier(_ text: String) -> Bool {
        var bytes = text.utf8.makeIterator()
        guard let first = bytes.next(), (0x61...0x7A).contains(first) || first == 0x5F && text.utf8.count > 1 else { return false }
        while let byte = bytes.next() {
            guard (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F else { return false }
        }
        return !selfReceivers.contains(text)
    }

    /// The property (or global) a bare receiver identifier names, unless the enclosing function takes a parameter
    /// of that name.
    private func inferredProperty(_ name: String, row: RefRow) -> Int64? {
        guard let file = files[row.fileID], file.family == .swift else { return nil }
        let key = InferenceKey(file: row.fileID, anchor: row.fromSymbol ?? 0, name: name)
        if let known = inferredProperties[key] { return known }
        let property = findProperty(name, row: row)
        inferredProperties[key] = .some(property)
        return property
    }

    private func findProperty(_ name: String, row: RefRow) -> Int64? {
        if let function = row.fromSymbol, parameterNames(of: function).contains(name) { return nil }
        let isValue: (Int64) -> Bool = { id in
            guard let symbol = self.symbols[id] else { return false }
            return (symbol.kind == .property || symbol.kind == .variable || symbol.kind == .constant)
                && self.access(id, from: row.fileID, line: row.line).isVisible
        }
        if let container = containerChain(row.fromSymbol).first, let selfType = containerType(container),
           let hit = lookupMember(selfType.type, named: name, accept: isValue) {
            return hit.ids.min { rank($0) < rank($1) }
        }
        let globals = (byName[name] ?? []).filter { id in
            guard let symbol = symbols[id], symbol.ownerName == nil, !symbol.isLocal else { return false }
            return isValue(id)
        }
        if let local = globals.first(where: { symbols[$0]?.fileID == row.fileID }) { return local }
        return globals.count == 1 ? globals[0] : nil
    }

    private func parameterNames(of symbolID: Int64) -> Set<String> {
        if let known = parameterNameCache[symbolID] { return known }
        let names = Self.parameterNames(symbols[symbolID]?.signature)
        parameterNameCache[symbolID] = names
        return names
    }

    /// Internal parameter names in a function signature (`func save(token t: String, force: Bool)` → t, force).
    static func parameterNames(_ signature: String?) -> Set<String> {
        guard let signature, let open = signature.firstIndex(of: "(") else { return [] }
        var depth = 0
        var clause = ""
        for character in signature[open...] {
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            if depth >= 1 { clause.append(character) }
        }
        clause = String(clause.dropFirst())
        var names = Set<String>()
        for parameter in splitTopLevel(clause, separator: ",") {
            guard let colon = parameter.firstIndex(of: ":") else { continue }
            let words = parameter[..<colon].split(separator: " ").map(String.init).filter { !$0.hasPrefix("@") }
            if let name = words.last, name != "_" { names.insert(name) }
        }
        return names
    }

    // MARK: - Signatures (collector without declared types)

    /// A declaration's type from its one-line signature: a function's return type (`-> Book?`), or a property's
    /// annotation (`let wax: Wax`), instantiation (`= SessionStore()`), static member (`= PremiumStore.shared`)
    /// or literal. Nil when the signature was cut before the type.
    private func signatureType(of symbol: SymbolInfo) -> ValueType? {
        guard let signature = symbol.signature else { return nil }
        let anchor = symbol.parentID ?? symbol.id
        if symbol.kind == .function || symbol.kind == .method {
            guard !signature.hasSuffix("…"), let arrow = Self.returnArrow(signature) else { return nil }
            let text = signature[arrow...].dropFirst(2).prefix { $0 != "{" }
            let returned = (text.range(of: " where ").map { text[..<$0.lowerBound] } ?? text).trimmingCharacters(in: .whitespaces)
            guard let expression = Self.parseSourceType(returned) else { return nil }
            return resolve(expression, file: symbol.fileID, anchor: symbol.id, producer: nil)
        }
        guard symbol.kind == .property || symbol.kind == .variable || symbol.kind == .constant else { return nil }
        if let wrapped = Self.environmentObjectType(signature) {
            return resolveTypeName(wrapped, fileID: symbol.fileID, anchor: anchor).map { ValueType(type: LinkType($0)) }
        }
        guard let binding = Self.bindingRange(signature, name: symbol.name) else { return nil }
        var rest = Substring(signature[binding.upperBound...]).drop { $0 == " " }
        if rest.hasPrefix(":") {
            rest = rest.dropFirst()
            let annotation = rest.prefix { $0 != "=" && $0 != "{" }.trimmingCharacters(in: .whitespaces)
            guard !annotation.hasSuffix("…"), let expression = Self.parseSourceType(annotation) else { return nil }
            return resolve(expression, file: symbol.fileID, anchor: anchor, producer: nil)
        }
        guard rest.hasPrefix("=") else { return nil }
        var value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        for keyword in ["try? ", "try! ", "try ", "await "] where value.hasPrefix(keyword) {
            value = String(value.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
        }
        if let literal = Self.literalType(value) { return ValueType(type: .external(literal)) }
        let chain = value.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        let after = value.dropFirst(chain.count)
        guard !chain.isEmpty, !after.hasPrefix("…") else { return nil }
        let parts = chain.split(separator: ".").map(String.init)
        if after.hasPrefix("(") || after.hasPrefix("<") {
            // `Foo()` / `Foo.Bar()` / `Foo.init()`: an instance; `Foo.make()`: a static call's return type.
            if parts.allSatisfy({ $0.first?.isUppercase == true }) {
                return resolveTypeName(parts.joined(separator: "."), fileID: symbol.fileID, anchor: anchor).map { ValueType(type: LinkType($0)) }
            }
            if parts.count >= 2, parts.last == "init" {
                return resolveTypeName(parts.dropLast().joined(separator: "."), fileID: symbol.fileID, anchor: anchor).map { ValueType(type: LinkType($0)) }
            }
            if parts.count >= 2, let member = parts.last {
                return staticMemberType(parts.dropLast().joined(separator: "."), member: member, called: true, from: symbol, anchor: anchor)
            }
            return nil
        }
        if after.isEmpty || after.hasPrefix(" ") || after.hasPrefix("?") || after.hasPrefix("!") {
            // `Foo.shared`: a static member's type.
            if parts.count >= 2, let member = parts.last, member.first?.isLowercase == true {
                return staticMemberType(parts.dropLast().joined(separator: "."), member: member, called: false, from: symbol, anchor: anchor)
            }
        }
        return nil
    }

    private func staticMemberType(_ typeName: String, member: String, called: Bool, from symbol: SymbolInfo, anchor: Int64) -> ValueType? {
        guard typeName.first?.isUppercase == true, let owner = resolveTypeName(typeName, fileID: symbol.fileID, anchor: anchor) else { return nil }
        switch owner {
        case .repo(let id):
            guard let hit = lookupMember(.repo(id), named: member, accept: { self.symbols[$0]?.isTypeLevel == true }),
                  let target = hit.ids.min(by: { rank($0) < rank($1) }), let declaration = symbols[target] else { return nil }
            if declaration.kind == .enumCase { return ValueType(type: .repo(id)) }
            if declaration.kind.isCallable && !called { return nil }
            return declaredValueType(of: target)
        case .external(let name):
            return Self.singletonNames.contains(member) && !called ? ValueType(type: .external(name)) : nil
        }
    }

    /// The type an `@Environment(…)` property holds: `@Environment(Foo.self)` → Foo, `@Environment(\.modelContext)` →
    /// ModelContext (the SwiftUI keys apps use).
    static func environmentObjectType(_ signature: String) -> String? {
        guard let start = signature.range(of: "@Environment(") else { return nil }
        let argument = signature[start.upperBound...].prefix { $0 != ")" }.trimmingCharacters(in: .whitespaces)
        if argument.hasPrefix("\\.") { return environmentKeys[String(argument.dropFirst(2))] }
        guard argument.hasSuffix(".self") else { return nil }
        let name = argument.dropLast(5).trimmingCharacters(in: .whitespaces)
        return name.first?.isUppercase == true ? name : nil
    }

    static let environmentKeys: [String: String] = [
        "modelContext": "ModelContext", "dismiss": "DismissAction", "openURL": "OpenURLAction", "scenePhase": "ScenePhase",
        "colorScheme": "ColorScheme", "horizontalSizeClass": "UserInterfaceSizeClass", "verticalSizeClass": "UserInterfaceSizeClass",
        "locale": "Locale", "calendar": "Calendar", "timeZone": "TimeZone", "dynamicTypeSize": "DynamicTypeSize",
        "managedObjectContext": "NSManagedObjectContext", "requestReview": "RequestReviewAction", "openWindow": "OpenWindowAction",
        "dismissWindow": "DismissWindowAction", "purchase": "PurchaseAction", "undoManager": "UndoManager", "editMode": "EditMode",
        "accessibilityReduceMotion": "Bool", "isEnabled": "Bool", "isPresented": "Bool", "layoutDirection": "LayoutDirection",
        "displayScale": "CGFloat", "openSettings": "OpenSettingsAction", "supportsMultipleWindows": "Bool",
    ]

    /// The `->` of a function signature's return clause (outside parameter parentheses).
    static func returnArrow(_ signature: String) -> String.Index? {
        var depth = 0
        var index = signature.startIndex
        var found: String.Index?
        while index < signature.endIndex {
            let character = signature[index]
            if character == "(" || character == "[" || character == "<" { depth += 1 }
            if character == ")" || character == "]" || (character == ">" && index > signature.startIndex && signature[signature.index(before: index)] != "-") { depth -= 1 }
            if depth == 0, character == "-", signature.index(after: index) < signature.endIndex, signature[signature.index(after: index)] == ">" {
                found = index
                break
            }
            index = signature.index(after: index)
        }
        return found
    }

    /// The range of `var name` / `let name` in a signature.
    static func bindingRange(_ signature: String, name: String) -> Range<String.Index>? {
        for keyword in ["var ", "let "] {
            var searchStart = signature.startIndex
            while let range = signature.range(of: keyword + name, range: searchStart..<signature.endIndex) {
                let end = range.upperBound
                let boundaryAfter = end == signature.endIndex || !(signature[end].isLetter || signature[end].isNumber || signature[end] == "_")
                let boundaryBefore = range.lowerBound == signature.startIndex || !(signature[signature.index(before: range.lowerBound)].isLetter)
                if boundaryAfter && boundaryBefore { return range }
                searchStart = end
            }
        }
        return nil
    }

    static func literalType(_ value: String) -> String? {
        guard let first = value.first else { return nil }
        if first == "\"" { return "String" }
        if value == "true" || value == "false" { return "Bool" }
        if first.isNumber || (first == "-" && value.dropFirst().first?.isNumber == true) {
            let number = value.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" || $0 == "e" }
            return number.contains(".") ? "Double" : "Int"
        }
        return nil
    }

    // MARK: - Parsing the type grammar

    /// `parseHint`, memoized: a few thousand distinct texts (`^`, `ctx(^)`, `param(^,0)`, type names) recur on most rows.
    func parsedHint(_ text: String) -> TypeExpr? {
        if let known = parsedHints[text] { return known }
        let expression = Self.parseHint(text)
        parsedHints[text] = .some(expression)
        return expression
    }

    /// Parses a hint or declared type (`^`, `elem(^)`, `[Foo: Bar]`, `(label: String, reason: String)`).
    static func parseHint(_ text: String) -> TypeExpr? {
        var parser = TypeParser(text)
        guard let expression = parser.hint(), parser.atEnd else { return nil }
        return expression
    }

    static func parseType(_ text: String) -> TypeExpr? {
        var parser = TypeParser(text)
        guard let expression = parser.type(), parser.atEnd else { return nil }
        return expression
    }

    /// A type as written in source (`[Book]?`, `Set<Tag>`, `some View`, `Result<A, B>`), normalized to the grammar.
    static func parseSourceType(_ text: String) -> TypeExpr? {
        var parser = TypeParser(text, lenient: true)
        guard let expression = parser.type(), parser.atEnd else { return nil }
        return expression
    }

    struct TypeParser {
        let bytes: [UInt8]
        var index = 0
        /// Source syntax: generic arguments, `?`/`!`, `some`/`any` and attributes are accepted and normalized.
        let lenient: Bool

        init(_ text: String, lenient: Bool = false) {
            bytes = Array(text.utf8)
            self.lenient = lenient
        }

        var atEnd: Bool {
            mutating get {
                skipSpaces()
                return index >= bytes.count
            }
        }

        mutating func skipSpaces() {
            while index < bytes.count, bytes[index] == 0x20 { index += 1 }
        }

        mutating func consume(_ text: String) -> Bool {
            skipSpaces()
            let pattern = Array(text.utf8)
            guard index + pattern.count <= bytes.count, Array(bytes[index..<index + pattern.count]) == pattern else { return false }
            index += pattern.count
            return true
        }

        mutating func hint() -> TypeExpr? {
            skipSpaces()
            if consume("^") { return .producer }
            if consume("elem(") {
                guard let inner = inner(), consume(")") else { return nil }
                return .element(inner)
            }
            if consume("ctx(") {
                guard let inner = inner(), consume(")") else { return nil }
                return .context(inner)
            }
            if consume("param(") {
                guard consume("^"), consume(","), let number = integer(), consume(")") else { return nil }
                return .parameter(number)
            }
            return type()
        }

        mutating func inner() -> TypeExpr? {
            if consume("^") { return .producer }
            return type()
        }

        mutating func integer() -> Int? {
            skipSpaces()
            let start = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            return index > start ? Int(String(decoding: bytes[start..<index], as: UTF8.self)) : nil
        }

        mutating func identifier() -> String? {
            skipSpaces()
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                let isWord = (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F || byte >= 0x80
                guard isWord || (byte == 0x2E && index > start) else { break }
                index += 1
            }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func type() -> TypeExpr? {
            skipSpaces()
            if lenient {
                while consume("@") { _ = identifier() }
                for keyword in ["some ", "any ", "inout ", "borrowing ", "consuming "] where consume(keyword) {}
            }
            var result: TypeExpr
            if consume("?") {
                return .unknown
            } else if consume("[") {
                guard let first = type() else { return nil }
                if consume(":") {
                    guard let value = type(), consume("]") else { return nil }
                    result = .dictionary(first, value)
                } else {
                    guard consume("]") else { return nil }
                    result = .array(first)
                }
            } else if consume("(") {
                var labels: [String] = []
                var types: [TypeExpr] = []
                if consume(")") { return .nominal("Void") }
                repeat {
                    let save = index
                    var label = "_"
                    if let name = identifier(), consume(":") {
                        label = name
                    } else {
                        index = save
                    }
                    guard let element = type() else { return nil }
                    labels.append(label)
                    types.append(element)
                } while consume(",")
                guard consume(")") else { return nil }
                if lenient, consume("->") || consume("throws") || consume("async") { return nil }
                result = types.count == 1 && labels[0] == "_" ? types[0] : .tuple(labels, types)
            } else {
                guard var name = identifier() else { return nil }
                if name.hasSuffix(".") { name.removeLast() }
                if lenient, consume("<") {
                    var arguments: [TypeExpr] = []
                    repeat {
                        guard let argument = type() else { return nil }
                        arguments.append(argument)
                    } while consume(",")
                    guard consume(">") else { return nil }
                    switch (name, arguments.count) {
                    case ("Optional", 1): result = arguments[0]
                    case ("Array", 1), ("Set", 1), ("ArraySlice", 1), ("ContiguousArray", 1): result = .array(arguments[0])
                    case ("Dictionary", 2): result = .dictionary(arguments[0], arguments[1])
                    default: result = .nominal(name)
                    }
                    if consume(".") {
                        guard let member = identifier() else { return nil }
                        result = .nominal(name + "." + member)
                    }
                } else {
                    result = name == "Void" ? .nominal("Void") : .nominal(name)
                }
            }
            if lenient {
                while consume("?") || consume("!") || consume(".Type") {}
            }
            return result
        }
    }

    // MARK: - Argument labels

    /// `importBook(from:preferences:)` → `["from", "preferences"]`.
    static func selectorLabels(_ selector: String) -> [String] {
        guard let open = selector.firstIndex(of: "("), let close = selector.lastIndex(of: ")"), open < close else { return [] }
        return selector[selector.index(after: open)..<close].split(separator: ":", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// Which parameter each argument fills, or nil when the call's labels cannot match the declaration.
    /// Defaulted parameters (`d`, `D`) and variadic ones may receive nothing; a trailing closure (`{}`) fills the next
    /// closure-typed parameter (`c`, `D`), `label{}` the next one with that label. With `lenient`, a trailing
    /// closure may fill any parameter (closure types hidden behind a type alias).
    static func assignArguments(_ labels: [String], to parameters: [String], flags: [Character], lenient: Bool = false) -> [Int]? {
        guard flags.count == parameters.count else { return nil }
        var regular: [(position: Int, label: String)] = []
        var trailing: [(position: Int, label: String)] = []
        for (position, label) in labels.enumerated() {
            if label.hasSuffix("{}") {
                trailing.append((position, String(label.dropLast(2))))
            } else {
                regular.append((position, label))
            }
        }
        var assignment = Array(repeating: -1, count: labels.count)
        func skippable(_ j: Int) -> Bool { flags[j] == "d" || flags[j] == "D" || flags[j] == "v" }
        func takesClosure(_ j: Int) -> Bool { lenient || flags[j] == "c" || flags[j] == "D" }

        func matchTrailing(_ t: Int, _ j: Int) -> Bool {
            if t == trailing.count {
                return (j..<parameters.count).allSatisfy(skippable)
            }
            var k = j
            while k < parameters.count {
                let fits = trailing[t].label.isEmpty ? takesClosure(k) : (parameters[k] == trailing[t].label && takesClosure(k))
                if fits {
                    assignment[trailing[t].position] = k
                    if matchTrailing(t + 1, k + 1) { return true }
                }
                guard skippable(k) else { return false }
                k += 1
            }
            return false
        }

        func matchRegular(_ i: Int, _ j: Int) -> Bool {
            if i == regular.count { return matchTrailing(0, j) }
            guard j < parameters.count else { return false }
            if parameters[j] == regular[i].label {
                assignment[regular[i].position] = j
                if flags[j] == "v" {
                    // A variadic parameter also takes the unlabeled arguments after its first one: try the longest run first.
                    var end = i + 1
                    while end < regular.count, regular[end].label == "_" { end += 1 }
                    for stop in stride(from: end, through: i + 1, by: -1) {
                        for k in (i + 1)..<stop { assignment[regular[k].position] = j }
                        if matchRegular(stop, j + 1) { return true }
                    }
                } else if matchRegular(i + 1, j + 1) {
                    return true
                }
            }
            if skippable(j), matchRegular(i, j + 1) { return true }
            return false
        }

        guard matchRegular(0, 0) else { return nil }
        return assignment
    }
}
