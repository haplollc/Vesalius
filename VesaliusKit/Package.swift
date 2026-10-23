// swift-tools-version: 6.0
import PackageDescription

let treeSitterCSettings: [CSetting] = [
    .headerSearchPath("src"),
    .define("_POSIX_C_SOURCE", to: "200112L"),
    .define("_DEFAULT_SOURCE"),
    .define("_DARWIN_C_SOURCE"),
    .unsafeFlags(["-w"]),
]

let package = Package(
    name: "VesaliusKit",
    platforms: [.macOS(.v15)],
    products: [
        // Everything the macOS app needs, as one product.
        .library(
            name: "VesaliusKit",
            targets: ["VesaliusCore", "RepositoryScanner", "LanguageAnalysis", "RepositoryIndex", "GraphEngine", "HealthEngine", "SemanticSearch", "QueryEngine", "VesaliusRender", "VesaliusMCP", "VesaliusCommands"]
        ),
        .library(name: "VesaliusCore", targets: ["VesaliusCore"]),
        .library(name: "QueryEngine", targets: ["QueryEngine"]),
        .library(name: "VesaliusMCP", targets: ["VesaliusMCP"]),
        .executable(name: "vesalius", targets: ["VesaliusCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "603.0.0"..<"605.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // MARK: Vendored C parsers
        .target(
            name: "CTreeSitter",
            path: "Sources/CTreeSitter",
            exclude: ["LICENSE", "LICENSE-ICU"],
            sources: ["src/lib.c"],
            publicHeadersPath: "include",
            cSettings: treeSitterCSettings
        ),
        .target(
            name: "CTreeSitterGrammars",
            path: "Sources/CTreeSitterGrammars",
            exclude: ["LICENSES"],
            sources: [
                "typescript/typescript/src/parser.c",
                "typescript/typescript/src/scanner.c",
                "typescript/tsx/src/parser.c",
                "typescript/tsx/src/scanner.c",
                "javascript/src/parser.c",
                "javascript/src/scanner.c",
                "python/src/parser.c",
                "python/src/scanner.c",
                "php/src/parser.c",
                "php/src/scanner.c",
                "php_only/src/parser.c",
                "php_only/src/scanner.c",
                "csharp/src/parser.c",
                "csharp/src/scanner.c",
            ],
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-w"]), .headerSearchPath("php/src")]
        ),

        // MARK: Engine
        .target(name: "VesaliusCore"),
        .target(name: "RepositoryScanner", dependencies: ["VesaliusCore"]),
        .target(
            name: "LanguageAnalysis",
            dependencies: [
                "VesaliusCore",
                "CTreeSitter",
                "CTreeSitterGrammars",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "RepositoryIndex",
            dependencies: ["VesaliusCore", "RepositoryScanner"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "GraphEngine", dependencies: ["VesaliusCore"]),
        .target(name: "HealthEngine", dependencies: ["VesaliusCore", "GraphEngine"]),
        .target(name: "SemanticSearch", dependencies: ["VesaliusCore", "RepositoryIndex"]),
        .target(
            name: "QueryEngine",
            dependencies: [
                "VesaliusCore",
                "RepositoryScanner",
                "LanguageAnalysis",
                "RepositoryIndex",
                "GraphEngine",
                "HealthEngine",
                "SemanticSearch",
            ]
        ),
        // Plain-text rendering shared by the CLI and the MCP server (result types are all in VesaliusCore).
        .target(name: "VesaliusRender", dependencies: ["VesaliusCore"]),
        .target(name: "VesaliusMCP", dependencies: ["QueryEngine", "RepositoryIndex", "VesaliusRender"]),
        .target(
            name: "VesaliusCommands",
            dependencies: [
                "QueryEngine",
                "RepositoryIndex",
                "VesaliusRender",
                "VesaliusMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "VesaliusCLI", dependencies: ["VesaliusCommands"]),

        // MARK: Tests
        .testTarget(
            name: "VesaliusKitTests",
            dependencies: [
                "VesaliusCore",
                "RepositoryScanner",
                "LanguageAnalysis",
                "RepositoryIndex",
                "GraphEngine",
                "HealthEngine",
                "SemanticSearch",
                "QueryEngine",
                "VesaliusRender",
                "VesaliusMCP",
                "VesaliusCommands",
                "VesaliusCLI",
            ]
        ),
    ]
)
