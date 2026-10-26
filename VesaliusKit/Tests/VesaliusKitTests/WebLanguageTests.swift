import Foundation
import Testing
import VesaliusCore
import LanguageAnalysis

struct WebLanguageTests {
    func analyze(_ source: String, language: Language, path: String) throws -> FileAnalysis {
        let file = SourceFile(path: path, language: language, text: source)
        return try #require(AnalyzerRegistry.standard.analyzer(for: language, path: path)).analyze(file)
    }
    @Test func phpStructuredCallsAndAliases() throws {
        let result = try analyze(#"""
        <?php
        namespace App\Http;
        use App\Services\{Store as Storage, Clock};
        final class Orders extends BaseController {
            public function __construct(private Storage $store) {}
            public function save(
                Order $order,
                int $attempt = 1
            ): Receipt {
                // fakeCall();
                $text = "alsoFake()";
                $this->store->save($order);
                $this->store?->flush();
                Storage::audit();
                return new Receipt($order);
            }
        }
        """#, language: .php, path: "app/Orders.php")
        #expect(result.syntaxErrorCount == 0)
        #expect(result.symbols.contains { $0.name == "Orders" && $0.kind == .class && $0.inheritedTypes == ["BaseController"] })
        #expect(result.symbols.contains { $0.name == "save" && $0.parameterTypes == ["Order", "int"] && $0.parameterFlags == "-d" })
        #expect(result.imports.contains { $0.module == #"App\Services\Store"# && $0.names.first?.alias == "Storage" })
        #expect(result.references.contains { $0.name == "save" && $0.kind == .call && $0.receiverHint == "App.Services.Store" && $0.line == 12 })
        #expect(result.references.contains { $0.name == "flush" && $0.kind == .call })
        #expect(result.references.contains { $0.name == "audit" && $0.receiverHint == "App.Services.Store" })
        #expect(result.references.contains { $0.name == "Receipt" && $0.kind == .instantiate })
        #expect(!result.references.contains { ["fakeCall", "alsoFake"].contains($0.name) })
    }
    @Test func csharpDeclarationsTypedFieldsAndMultilineMethods() throws {
        let result = try analyze(#"""
        global using Storage = Example.Store;
        namespace Example;
        public partial class Orders : BaseController, IDisposable {
            private readonly Storage _store;
            public string Name { get; set; }
            public Orders(Storage store) { _store = store; }
            public async Task<T> Save<T>(
                T order,
                int retry = 1) {
                // Fake();
                var text = "FakeToo()";
                _store.Save(order);
                this._store.Flush();
                Storage.Audit();
                await Work();
                return order;
            }
        }
        public record Receipt(int Id);
        """#, language: .csharp, path: "Orders.cs")
        #expect(result.syntaxErrorCount == 0)
        #expect(result.symbols.contains { $0.name == "Receipt" && $0.kind == .class })
        #expect(result.symbols.contains { $0.name == "Save" && $0.kind == .method && $0.parameterFlags == "-d" })
        #expect(result.symbols.contains { $0.name == "Name" && $0.kind == .property })
        #expect(result.references.contains { $0.name == "Save" && $0.receiverHint == "Example.Store" && $0.line == 12 })
        #expect(result.references.contains { $0.name == "Flush" && $0.receiverHint == "Example.Store" })
        #expect(result.references.contains { $0.name == "Audit" && $0.receiverHint == "Example.Store" })
        #expect(!result.references.contains { ["Fake", "FakeToo"].contains($0.name) })
    }
    @Test func unknownAndShadowedReceiversAreNotInvented() throws {
        let cs = try analyze("class C { A service; void Go(B service, dynamic unknown) { this.service.Run(); service.Run(); unknown.Run(); } }", language: .csharp, path: "C.cs")
        let calls = cs.references.filter { $0.name == "Run" && $0.kind == .call }
        #expect(calls.map(\.receiverHint) == ["A", "B", nil])
        let php = try analyze("<?php function go($service, $method) { $service->run(); $service->$method(); }", language: .php, path: "go.php")
        #expect(php.references.filter { $0.kind == .call }.map(\.name) == ["run"])
        #expect(php.references.first { $0.name == "run" }?.receiverHint == nil)
    }
    @Test func bladeIslandsKeepLinesAndIgnoreCommentDecoys() throws {
        let result = try analyze(#"""
        {{-- {{ fakeCall() }} --}}
        <div>ខ្មែរ 🌿</div>
        @extends('layouts.app')
        @include('orders.row')
        {{ $store->save($order) }}
        @php
          actualCall();
        @endphp
        @if($store->ready())
        <p>Ready</p>
        @endif
        """#, language: .php, path: "resources/views/orders.blade.php")
        #expect(result.references.contains { $0.name == "save" && $0.line == 5 })
        #expect(result.references.contains { $0.name == "actualCall" && $0.line == 7 })
        #expect(result.references.contains { $0.name == "ready" && $0.line == 9 })
        #expect(!result.references.contains { $0.name == "fakeCall" })
        #expect(result.imports.contains { $0.module == "laravel-view:orders.row" && $0.line == 4 })
    }
    @Test func razorIncludesCodeInjectionCallbacksAndRoutes() throws {
        let result = try analyze(#"""
        @page "/orders"
        @inject Store Service
        <p>ខ្មែរ 🌿</p>
        <button @onclick="Save">Save</button>
        @code {
            string closing = "}";
            void Save() {
                Service.Save();
                // } Fake();
                Work();
            }
        }
        """#, language: .csharp, path: "Pages/Orders.razor")
        #expect(Language.detect(fileName: "Orders.razor") == .csharp)
        #expect(Language.detect(fileName: "Index.cshtml") == .csharp)
        #expect(result.symbols.contains { $0.name == "Save" && $0.kind == .method && $0.range.start == 7 })
        #expect(result.references.contains { $0.name == "Save" && $0.kind == .call && $0.receiverHint == "Store" && $0.line == 8 })
        #expect(result.references.contains { $0.name == "Save" && $0.kind == .member && $0.line == 4 })
        #expect(result.references.contains { $0.name == "Work" && $0.line == 10 })
        #expect(!result.references.contains { $0.name == "Fake" })
        #expect(result.literals.contains { $0.value == "/orders" && $0.line == 1 })
    }
    @Test func malformedFilesRemainPartialAndDoNotChangeOtherAnalyzers() throws {
        let php = try analyze("<?php class C { function Run( { realCall();", language: .php, path: "C.php")
        #expect(php.syntaxErrorCount > 0)
        #expect(AnalyzerRegistry.standard.analyzer(for: .typescript, path: "app.ts")?.identifier == "tree-sitter-typescript")
        #expect(AnalyzerRegistry.standard.analyzer(for: .swift, path: "App.swift")?.identifier == "swift-syntax")
    }
}
