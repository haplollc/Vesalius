import Foundation
import RepositoryScanner
import VesaliusCore

/// Resolves import statements to repository files or local modules; everything else is recorded as an
/// external dependency (framework/package name).
public struct ImportResolver {
    public struct FileEntry: Sendable {
        public let id: Int64
        public let path: String
        public let language: Language

        public init(id: Int64, path: String, language: Language) {
            self.id = id
            self.path = path
            self.language = language
        }
    }

    let filesByPath: [String: FileEntry]
    let filesByName: [String: [FileEntry]]
    let modulesByName: [String: Int64]
    let detection: ModuleDetection
    /// Python dotted module name → file id.
    let pythonModules: [String: Int64]

    public init(files: [FileEntry], modules: [(id: Int64, module: ModuleInfo)], detection: ModuleDetection) {
        var byPath: [String: FileEntry] = [:]
        var byName: [String: [FileEntry]] = [:]
        for file in files {
            byPath[file.path] = file
            byName[(file.path as NSString).lastPathComponent, default: []].append(file)
        }
        filesByPath = byPath
        filesByName = byName
        var moduleNames: [String: Int64] = [:]
        for (id, module) in modules where moduleNames[module.name] == nil {
            moduleNames[module.name] = id
        }
        modulesByName = moduleNames
        self.detection = detection

        var python: [String: Int64] = [:]
        let roots = detection.pythonSourceRoots.sorted { $0.count > $1.count }
        for file in files where file.language == .python {
            guard let root = roots.first(where: { $0.isEmpty || file.path.hasPrefix($0 + "/") }) else { continue }
            var relative = root.isEmpty ? file.path : String(file.path.dropFirst(root.count + 1))
            guard relative.hasSuffix(".py") || relative.hasSuffix(".pyi") else { continue }
            relative = (relative as NSString).deletingPathExtension
            var dotted = relative.replacingOccurrences(of: "/", with: ".")
            if dotted.hasSuffix(".__init__") { dotted = String(dotted.dropLast(".__init__".count)) }
            if dotted == "__init__" { continue }
            if python[dotted] == nil || file.path.hasSuffix(".py") { python[dotted] = file.id }
        }
        pythonModules = python
    }

    public enum Resolution: Equatable {
        case file(Int64)
        case module(Int64)
        case external(String)
        case unresolved
    }

    public func resolve(module specifier: String, kind: ImportKind, names: [ImportedName], from file: FileEntry) -> Resolution {
        switch file.language {
        case .typescript, .javascript, .html:
            return resolveScript(specifier, from: file)
        case .php where specifier.hasPrefix("laravel-view:"):
            let view = String(specifier.dropFirst("laravel-view:".count)).replacingOccurrences(of: ".", with: "/")
            let suffix = "resources/views/" + view + ".blade.php"
            let matches = filesByPath.values.filter { $0.path == suffix || $0.path.hasSuffix("/" + suffix) }
            return matches.count == 1 ? .file(matches[0].id) : .unresolved
        case .php where specifier.contains("\\"):
            var parts = specifier.split(separator: "\\").map(String.init)
            if parts.first == "App" { parts[0] = "app" }
            let suffix = parts.joined(separator: "/") + ".php"
            let matches = filesByPath.values.filter { $0.path == suffix || $0.path.hasSuffix("/" + suffix) }
            return matches.count == 1 ? .file(matches[0].id) : .external(specifier)
        case .python:
            return resolvePython(specifier, kind: kind, names: names, from: file)
        case .swift:
            if let module = modulesByName[specifier] { return .module(module) }
            return .external(specifier)
        case .c, .cpp, .objectiveC:
            return resolveInclude(specifier, kind: kind, from: file)
        case .java, .kotlin:
            return resolveJVM(specifier)
        case .go:
            return resolveGo(specifier)
        case .rust:
            return resolveRust(specifier, from: file)
        case .ruby:
            return resolveRelativeScript(specifier, from: file, extensions: [".rb"]) ?? .external(specifier)
        default:
            if kind == .relative, let resolved = resolveRelativeScript(specifier, from: file, extensions: [""]) { return resolved }
            return .external(specifier)
        }
    }

    // MARK: TypeScript / JavaScript

    private static let scriptExtensions = [".ts", ".tsx", ".d.ts", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts", ".vue", ".svelte", ".json"]
    private static let indexFiles = ["/index.ts", "/index.tsx", "/index.js", "/index.jsx", "/index.mjs", "/index.d.ts"]

    private func resolveScript(_ specifier: String, from file: FileEntry) -> Resolution {
        let directory = (file.path as NSString).deletingLastPathComponent
        if specifier.hasPrefix(".") {
            return tryScript(Self.join(directory, specifier)).map { .file($0) } ?? .unresolved
        }
        if specifier.hasPrefix("/") {
            return tryScript(String(specifier.dropFirst())).map { .file($0) } ?? .unresolved
        }
        // tsconfig path aliases, nearest config first.
        let configs = detection.tsconfigs
            .filter { $0.directory.isEmpty || file.path.hasPrefix($0.directory + "/") }
            .sorted { $0.directory.count > $1.directory.count }
        for config in configs {
            for (pattern, targets) in config.paths {
                if pattern.hasSuffix("*") {
                    let prefix = String(pattern.dropLast())
                    guard specifier.hasPrefix(prefix) else { continue }
                    let rest = String(specifier.dropFirst(prefix.count))
                    for target in targets {
                        let candidate = target.hasSuffix("*") ? String(target.dropLast()) + rest : target
                        if let id = tryScript(Self.normalize(candidate)) { return .file(id) }
                    }
                } else if pattern == specifier {
                    for target in targets {
                        if let id = tryScript(Self.normalize(target)) { return .file(id) }
                    }
                }
            }
            if let base = config.baseURL, let id = tryScript(Self.join(base, specifier)) {
                return .file(id)
            }
        }
        // Monorepo workspace packages.
        for package in detection.workspacePackages.sorted(by: { $0.name.count > $1.name.count }) {
            if specifier == package.name {
                for entry in package.entries { if let id = filesByPath[entry]?.id { return .file(id) } }
                for candidate in ["src/index", "index", "lib/index", "src/main", "main"] {
                    if let id = tryScript(Self.join(package.directory, candidate)) { return .file(id) }
                }
            } else if specifier.hasPrefix(package.name + "/") {
                let rest = String(specifier.dropFirst(package.name.count + 1))
                if let id = tryScript(Self.join(package.directory, rest)) ?? tryScript(Self.join(package.directory, "src/" + rest)) {
                    return .file(id)
                }
            }
        }
        // Bare specifier: an npm package (or node builtin).
        var name = specifier
        if name.hasPrefix("node:") { name = String(name.dropFirst(5)) }
        let parts = name.split(separator: "/")
        let package = name.hasPrefix("@") && parts.count >= 2 ? "\(parts[0])/\(parts[1])" : String(parts.first ?? Substring(name))
        return .external(package)
    }

    private func tryScript(_ base: String) -> Int64? {
        if let file = filesByPath[base], file.language != .unknown || base.hasSuffix(".json") { return file.id }
        // ESM TypeScript convention: `./foo.js` refers to `foo.ts`.
        for jsExtension in [".js", ".jsx", ".mjs", ".cjs"] where base.hasSuffix(jsExtension) {
            let stem = String(base.dropLast(jsExtension.count))
            for ext in [".ts", ".tsx", ".mts", ".cts"] {
                if let file = filesByPath[stem + ext] { return file.id }
            }
        }
        for ext in Self.scriptExtensions {
            if let file = filesByPath[base + ext] { return file.id }
        }
        for index in Self.indexFiles {
            if let file = filesByPath[base + index] { return file.id }
        }
        return nil
    }

    private func resolveRelativeScript(_ specifier: String, from file: FileEntry, extensions: [String]) -> Resolution? {
        let directory = (file.path as NSString).deletingLastPathComponent
        let base = Self.join(directory, specifier)
        for ext in extensions {
            if let found = filesByPath[base + ext] { return .file(found.id) }
        }
        return nil
    }

    // MARK: Python

    private func resolvePython(_ specifier: String, kind: ImportKind, names: [ImportedName], from file: FileEntry) -> Resolution {
        if specifier.hasPrefix(".") {
            let level = specifier.prefix { $0 == "." }.count
            let remainder = String(specifier.dropFirst(level))
            var directory = (file.path as NSString).deletingLastPathComponent
            for _ in 1..<max(level, 1) { directory = (directory as NSString).deletingLastPathComponent }
            let base = remainder.isEmpty ? directory : Self.join(directory, remainder.replacingOccurrences(of: ".", with: "/"))
            // `from . import name` where name is a submodule.
            if names.count == 1, let name = names.first?.name, name != "*" {
                let submodule = base.isEmpty ? name : base + "/" + name
                if let id = pythonFile(submodule) { return .file(id) }
            }
            if let id = pythonFile(base) { return .file(id) }
            return .unresolved
        }
        if names.count == 1, let name = names.first?.name, name != "*", let id = pythonModules[specifier + "." + name] {
            return .file(id)
        }
        if let id = pythonModules[specifier] { return .file(id) }
        // `import a.b.c` where only `a.b` exists locally.
        var parts = specifier.split(separator: ".").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if let id = pythonModules[parts.joined(separator: ".")] { return .file(id) }
        }
        return .external(String(specifier.split(separator: ".").first ?? Substring(specifier)))
    }

    private func pythonFile(_ path: String) -> Int64? {
        filesByPath[path + ".py"]?.id ?? filesByPath[path + "/__init__.py"]?.id ?? filesByPath[path + ".pyi"]?.id
    }

    // MARK: C family

    private func resolveInclude(_ specifier: String, kind: ImportKind, from file: FileEntry) -> Resolution {
        let directory = (file.path as NSString).deletingLastPathComponent
        if kind == .include {
            let local = Self.join(directory, specifier)
            if let found = filesByPath[local] { return .file(found.id) }
        }
        if let found = filesByPath[specifier] { return .file(found.id) }
        let name = (specifier as NSString).lastPathComponent
        let candidates = (filesByName[name] ?? []).filter { $0.path.hasSuffix(specifier) }
        if candidates.count == 1 { return .file(candidates[0].id) }
        if kind == .include, candidates.count > 1 {
            // Prefer the candidate sharing the longest directory prefix with the includer.
            let best = candidates.max { Self.commonPrefixLength($0.path, file.path) < Self.commonPrefixLength($1.path, file.path) }
            if let best { return .file(best.id) }
        }
        if let module = modulesByName[(specifier as NSString).deletingPathExtension] { return .module(module) }
        return .external(specifier.split(separator: "/").first.map(String.init) ?? specifier)
    }

    // MARK: JVM, Go, Rust

    private func resolveJVM(_ specifier: String) -> Resolution {
        let parts = specifier.split(separator: ".").map(String.init)
        guard let last = parts.last else { return .external(specifier) }
        let pathSuffix = parts.joined(separator: "/")
        for ext in [".java", ".kt"] {
            if let match = filesByName[last + ext]?.first(where: { $0.path.hasSuffix(pathSuffix + ext) }) {
                return .file(match.id)
            }
        }
        let unique = (filesByName[last + ".java"] ?? []) + (filesByName[last + ".kt"] ?? [])
        if last != "*", unique.count == 1 {
            return .file(unique[0].id)
        }
        return .external(parts.prefix(2).joined(separator: "."))
    }

    private func resolveGo(_ specifier: String) -> Resolution {
        guard let module = detection.goModulePath, specifier == module || specifier.hasPrefix(module + "/") else {
            return .external(specifier)
        }
        let directory = specifier == module ? "" : String(specifier.dropFirst(module.count + 1))
        let match = filesByPath.values
            .filter { ($0.path as NSString).deletingLastPathComponent == directory && $0.path.hasSuffix(".go") && !$0.path.hasSuffix("_test.go") }
            .min { $0.path < $1.path }
        return match.map { .file($0.id) } ?? .unresolved
    }

    private func resolveRust(_ specifier: String, from file: FileEntry) -> Resolution {
        var parts = specifier.split(separator: ":").filter { !$0.isEmpty }.map(String.init)
        guard let first = parts.first else { return .external(specifier) }
        var base: String
        switch first {
        case "crate":
            let srcIndex = file.path.range(of: "src/")
            base = srcIndex.map { String(file.path[..<$0.upperBound]) + "" } ?? ""
            base = base.hasSuffix("/") ? String(base.dropLast()) : base
            parts.removeFirst()
        case "super":
            base = ((file.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            parts.removeFirst()
        case "self":
            base = (file.path as NSString).deletingLastPathComponent
            parts.removeFirst()
        default:
            return .external(first)
        }
        while !parts.isEmpty {
            let candidate = Self.join(base, parts.joined(separator: "/"))
            if let found = filesByPath[candidate + ".rs"] ?? filesByPath[candidate + "/mod.rs"] { return .file(found.id) }
            parts.removeLast()
        }
        return .unresolved
    }

    // MARK: Paths

    static func join(_ directory: String, _ path: String) -> String {
        var components = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    static func normalize(_ path: String) -> String { join("", path) }

    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}
