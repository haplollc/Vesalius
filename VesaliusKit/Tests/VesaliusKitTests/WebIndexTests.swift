import Foundation
import Testing
import QueryEngine
import RepositoryIndex
import VesaliusCore

struct WebIndexTests {
    @Test func csharpCallersLinkAcrossFilesAndTemplatesAreIndexed() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Store.cs": "public class Store { public void Persist() {} }",
            "Caller.cs": "public class Caller { private Store store; public void Go() { store.Persist(); } }",
            "Pages/Orders.razor": "@inject Store Service\n<p>Orders</p>\n@code { void Save() { Service.Persist(); } }"
        ], name: "csharp-web")
        #expect(try engine.allFiles().contains { $0.path == "Pages/Orders.razor" })
        let callers = try engine.callers("Store.Persist")
        #expect(callers.relations.contains { $0.symbol.path == "Caller.cs" && $0.symbol.name == "Go" })
        #expect(callers.relations.contains { $0.symbol.path == "Pages/Orders.razor" && $0.symbol.name == "Save" })
    }
    @Test func phpTypedCallsAndLaravelViewImportsLink() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "app/Services/Store.php": "<?php namespace App\\Services; class Store { public function persist() {} }",
            "app/Caller.php": "<?php use App\\Services\\Store; class Caller { public function go(Store $store) { $store->persist(); } }",
            "resources/views/orders.blade.php": "@include('orders.row')\n{{ count($items) }}",
            "resources/views/orders/row.blade.php": "<p>Order</p>"
        ], name: "php-web")
        let callers = try engine.callers("Store.persist")
        #expect(callers.relations.contains { $0.symbol.path == "app/Caller.php" && $0.symbol.name == "go" })
        let dependencies = try engine.dependencies(of: "resources/views/orders.blade.php")
        #expect(dependencies.files.contains { $0.path == "resources/views/orders/row.blade.php" })
    }
}