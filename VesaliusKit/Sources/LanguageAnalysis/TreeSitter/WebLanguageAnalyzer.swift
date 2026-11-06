import CTreeSitter
import Foundation
import VesaliusCore

/// Syntax navigation for PHP/C#. This does not run either program or claim compiler-level
/// dispatch: dynamic calls stay unresolved and receiver hints require explicit type evidence.
public struct WebLanguageAnalyzer: LanguageAnalyzer {
    public init() {}
    public let identifier = "tree-sitter-php-csharp"
    public let version = 1
    public func canAnalyze(_ language: Language, path: String) -> Bool {
        language == .php || language == .csharp
    }
    public func analyze(_ file: SourceFile) throws -> FileAnalysis {
        try analyze(file, grammar: file.language == .php ? .php : .csharp)
    }
    func analyze(_ file: SourceFile, grammar: TreeSitterGrammar) throws -> FileAnalysis {
        let source = SourceBytes(file.text)
        let tree = try TreeSitterParser.parse(source.bytes, grammar: grammar)
        var walker = WebWalker(source: source, language: file.language)
        try walker.walk(tree.root, scope: WebScope(), depth: 0)
        walker.result.syntaxErrorCount = TreeSitterUtilities.countSyntaxErrors(tree.root)
        return walker.result
    }
}

extension TSNode {
    func webField(_ name: String) -> TSNode? {
        let node = name.withCString { ts_node_child_by_field_name(self, $0, UInt32(name.utf8.count)) }
        return node.isNull ? nil : node
    }
}
private struct WebScope {
    var parent: Int?
    var type: String?
    var types: [String: String] = [:]
    var aliases: [String: String] = [:]
    var fields: [String: String] = [:]
    var callee: String?
}
private struct WebWalker {
    let source: SourceBytes
    let language: Language
    var result = FileAnalysis()
    func text(_ node: TSNode?) -> String { node.map(source.text) ?? "" }
    func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: ".").replacingOccurrences(of: "global::", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "?$ "))
    }
    func leaf(_ value: String) -> String {
        String(normalized(value).split(separator: ".").last ?? "")
    }
    func name(_ node: TSNode) -> String {
        if node.typeName == "generic_name" { return text(node.children(namedOnly: true).first) }
        return normalized(text(node))
    }
    func declaredKind(_ node: TSNode) -> SymbolKind? {
        switch node.typeName {
        case "class_declaration", "record_declaration": return .class
        case "struct_declaration": return .struct
        case "interface_declaration": return .interface
        case "trait_declaration": return .protocol
        case "enum_declaration": return .enum
        case "method_declaration": return .method
        case "constructor_declaration": return .initializer
        case "function_definition", "local_function_statement": return .function
        case "property_declaration" where language == .csharp: return .property
        default: return nil
        }
    }
    mutating func addSymbol(_ node: TSNode, name: String, kind: SymbolKind, scope: WebScope, type: String? = nil) -> Int {
        let id = result.symbols.count
        let body = node.webField("body")
        let header = source.text(node, upTo: body).split(whereSeparator: \.isNewline).joined(separator: " ")
        let modifiers = node.children(namedOnly: true).filter { $0.typeName.contains("modifier") }.map(source.text)
        let visibility: Visibility? = modifiers.contains("private") ? .private : modifiers.contains("protected") ? .internal : modifiers.contains("public") ? .public : nil
        result.symbols.append(ExtractedSymbol(localID: id, parentLocalID: scope.parent, name: name, kind: kind,
            range: LineRange(node.startLine, node.endLine), signature: String(header.prefix(600)),
            visibility: visibility, isExported: visibility != .private, attributes: modifiers, declaredType: type))
        return id
    }
    func typedBindings(_ node: TSNode) -> [String: String] {
        // Explicit annotations only: no repository-wide guessing by variable name.
        var bindings: [String: String] = [:]
        var pending = [node]
        while let item = pending.popLast() {
            let kind = item.typeName
            if ["parameter", "simple_parameter", "property_promotion_parameter"].contains(kind),
               let n = item.webField("name"), let t = item.webField("type") {
                bindings[normalized(text(n))] = normalized(text(t))
            }
            if kind == "variable_declaration" || (kind == "property_declaration" && language == .php), let type = item.webField("type") {
                let value = normalized(text(type))
                if value != "var" {
                    for child in item.children(namedOnly: true) where child.typeName == "variable_declarator" || child.typeName == "property_element" {
                        let n = child.webField("name") ?? child.children(namedOnly: true).first
                        if let n { bindings[normalized(text(n))] = value }
                    }
                }
            }
            pending.append(contentsOf: item.children(namedOnly: true))
        }
        return bindings
    }
    mutating func reference(_ node: TSNode, name: String, kind: ReferenceKind, scope: WebScope, receiver: TSNode? = nil, call: TSNode? = nil) {
        guard !name.isEmpty else { return }
        let raw = text(receiver)
        let r = normalized(raw).replacingOccurrences(of: "->", with: ".").replacingOccurrences(of: "?", with: "")
        let field = r.hasPrefix("this.") ? String(r.dropFirst(5)) : r
        let simple = !r.isEmpty && r.allSatisfy { $0.isLetter || $0.isNumber || "_.$".contains($0) }
        var hint: String?
        if r == "this" || r == "self" || r == "static" { hint = scope.type }
        else if r.hasPrefix("this."), let known = scope.fields[field] { hint = known }
        else if let known = scope.types[field] { hint = known }
        else if language == .csharp, let known = scope.fields[field] { hint = known }
        else if let alias = scope.aliases[r] { hint = alias }
        else if simple && r.first?.isUppercase == true { hint = r }
        if let type = hint { hint = scope.aliases[type] ?? type }
        if ["dynamic", "var", "mixed", "?"].contains(hint ?? "") { hint = nil }
        let args = call?.webField("arguments")?.children(namedOnly: true) ?? []
        result.references.append(ExtractedReference(name: leaf(name), kind: kind, line: node.startLine, column: node.startColumn,
            enclosingSymbol: scope.parent, receiver: r.isEmpty ? nil : (r == "this" ? "self" : r),
            statementLine: call?.startLine ?? node.startLine, endLine: call?.endLine ?? node.endLine,
            callEndLine: call?.endLine, context: kind == .call || kind == .instantiate ? "call" : "type",
            argumentLabels: call == nil ? nil : args.map { _ in "_" }, receiverHint: hint))
    }
    mutating func imports(_ node: TSNode, scope: inout WebScope) {
        if language == .csharp {
            let parts = node.children(namedOnly: true)
            let aliasNode = node.webField("name")
            guard let target = parts.last else { return }
            let module = normalized(text(target))
            let alias = aliasNode.map(source.text)
            result.imports.append(ExtractedImport(module: module, kind: .module,
                names: alias == nil ? [] : [ImportedName(name: leaf(module), alias: alias)], line: node.startLine))
            if let alias { scope.aliases[alias] = module }
        } else {
            let group = node.webField("body")
            let prefix = group == nil ? "" : text(node.children(namedOnly: true).first { $0.typeName == "namespace_name" }) + "\\"
            let clauses = (group ?? node).children(namedOnly: true).filter { $0.typeName == "namespace_use_clause" }
            for clause in clauses {
                guard let target = clause.children(namedOnly: true).first else { continue }
                let module = prefix + text(target)
                let alias = clause.webField("alias").map(source.text)
                result.imports.append(ExtractedImport(module: module, kind: .module,
                    names: [ImportedName(name: leaf(module), alias: alias)], line: clause.startLine))
                scope.aliases[alias ?? leaf(module)] = normalized(module)
            }
        }
    }
    mutating func walk(_ node: TSNode, scope input: WebScope, depth: Int) throws {
        guard depth < 512 else { throw AnalyzerError("PHP/C# syntax nesting exceeded 512 levels") }
        let kind = node.typeName
        if kind == "comment" || kind == "text" || kind == "php_tag" { return }
        var scope = input
        if kind == "using_directive" || kind == "namespace_use_declaration" { return }
        if kind == "compilation_unit" || kind == "program" {
            for child in node.children(namedOnly: true) {
                if child.typeName == "using_directive" || child.typeName == "namespace_use_declaration" {
                    imports(child, scope: &scope)
                } else if (child.typeName == "file_scoped_namespace_declaration" || child.typeName == "namespace_definition"), child.webField("body") == nil, let n = child.webField("name") {
                    scope.parent = addSymbol(child, name: normalized(text(n)), kind: .namespace, scope: scope)
                } else { try walk(child, scope: scope, depth: depth + 1) }
            }
            return
        }
        if kind == "namespace_declaration" || kind == "namespace_definition", let n = node.webField("name") {
            scope.parent = addSymbol(node, name: normalized(text(n)), kind: .namespace, scope: scope)
        } else if let symbolKind = declaredKind(node), let n = node.webField("name") {
            let type = node.webField("returns") ?? node.webField("return_type") ?? node.webField("type")
            let symbol = addSymbol(node, name: name(n), kind: symbolKind, scope: scope, type: type.map { normalized(text($0)) })
            if symbolKind.isType {
                scope.type = name(n)
                let bases = node.children(namedOnly: true).filter { ["base_list", "base_clause", "class_interface_clause"].contains($0.typeName) }
                result.symbols[symbol].inheritedTypes = bases.flatMap { $0.children(namedOnly: true).map { normalized(text($0)) } }
                // Only class-level declarations and constructor parameters belong to fields.
                for member in node.webField("body")?.children(namedOnly: true) ?? [] {
                    if ["field_declaration", "property_declaration"].contains(member.typeName) {
                        scope.fields.merge(typedBindings(member)) { _, new in new }
                    } else if member.typeName == "constructor_declaration" || (member.typeName == "method_declaration" && text(member.webField("name")) == "__construct") {
                        for parameter in member.webField("parameters")?.children(namedOnly: true) ?? [] where parameter.typeName == "property_promotion_parameter" {
                            scope.fields.merge(typedBindings(parameter)) { _, new in new }
                        }
                    }
                }
            }
            if symbolKind.isCallable {
                if let params = node.webField("parameters") {
                    scope.types.merge(typedBindings(params)) { _, new in new }
                    let ps = params.children(namedOnly: true).filter { $0.webField("name") != nil }
                    result.symbols[symbol].parameterTypes = ps.map { normalized(text($0.webField("type"))) }
                    result.symbols[symbol].parameterFlags = ps.map { parameter in
                        parameter.webField("default_value") != nil || parameter.children().contains(where: { text($0) == "=" }) ? "d" : "-"
                    }.joined()
                }
            }
            scope.parent = symbol
        }
        if kind == "property_element" || (kind == "variable_declarator" && node.parentNode?.parentNode?.typeName == "field_declaration") {
            if let n = node.webField("name") ?? node.children(namedOnly: true).first {
                _ = addSymbol(node, name: normalized(text(n)), kind: .property, scope: scope, type: node.parentNode?.webField("type").map { normalized(text($0)) })
            }
        }
        if ["if_statement", "for_statement", "foreach_statement", "while_statement", "catch_clause", "conditional_expression"].contains(kind) {
            result.complexity += 1
            if let parent = scope.parent, result.symbols[parent].kind.isCallable { result.symbols[parent].complexity += 1 }
        }
        if ["invocation_expression", "function_call_expression", "member_call_expression", "nullsafe_member_call_expression", "scoped_call_expression"].contains(kind) {
            let function = node.webField("function")
            let target = node.webField("name") ?? function?.webField("name") ?? function
            let receiver = node.webField("object") ?? node.webField("scope") ?? function?.webField("expression")
            if let target, ["identifier", "generic_name", "name", "qualified_name", "member_binding_expression"].contains(target.typeName) {
                reference(target, name: name(target), kind: .call, scope: scope, receiver: receiver, call: node)
                scope.callee = name(target)
            }
        } else if kind == "object_creation_expression" {
            let target = node.webField("type") ?? node.children(namedOnly: true).first { ["name", "qualified_name"].contains($0.typeName) }
            if let target { reference(target, name: name(target), kind: .instantiate, scope: scope, call: node) }
        } else if ["base_list", "base_clause", "class_interface_clause", "named_type"].contains(kind) {
            for target in node.children(namedOnly: true) {
                reference(target, name: name(target), kind: kind == "named_type" ? .typeUse : .inherit, scope: scope)
            }
        } else if ["generic_name", "qualified_name"].contains(kind), node.parentNode?.typeName != "namespace_use_clause" {
            reference(node, name: name(node), kind: .typeUse, scope: scope)
        }
        if ["string", "string_literal", "verbatim_string_literal", "raw_string_literal"].contains(kind) {
            let raw = text(node)
            if raw.utf8.count <= 2000 {
                let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@\"'"))
                if !value.isEmpty { result.literals.append(ExtractedLiteral(value: value, line: node.startLine, column: node.startColumn, enclosingSymbol: scope.parent, context: scope.callee == nil ? "other" : "call-arg", callee: scope.callee)) }
            }
            return
        }
        // Sequential children preserve local annotations but do not leak bindings out of blocks.
        for child in node.children(namedOnly: true) {
            if child.typeName == "using_directive" || child.typeName == "namespace_use_declaration" { imports(child, scope: &scope); continue }
            if child.typeName == "local_declaration_statement" {
                scope.types.merge(typedBindings(child)) { _, new in new }
            }
            try walk(child, scope: scope, depth: depth + 1)
        }
    }
}
