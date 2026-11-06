# PHP, C# and template coverage

PHP (`.php`) and C# (`.cs`) use tree-sitter instead of the lexical fallback.
The collectors extract declarations, namespace/import aliases, inheritance,
call sites, literal context and receiver-type hints from explicit annotations.
Namespace-aware linking can connect those hints to repository declarations;
ambiguous matches remain unresolved. Neither analyzer executes the program.

For example, a PHP parameter typed with an imported alias can connect
`$store->persist()` to its declared class. A C# field explicitly typed as
`Store` can connect `store.Persist()` to a method in another source file.
Comments and ordinary string contents cannot create call sites. Unknown or
dynamic receivers do not receive an invented concrete type hint.

## Templates

Template extraction projects recognized code sections into a syntax parser,
preserving original source line numbers, including non-ASCII markup. It does not
compile templates or treat markup as application code.

- **Blade (`.blade.php`):** `@php` blocks, PHP tags, echo expressions and selected
  directive expressions. Literal `@include`, `@extends`, `@component` and
  `@each` view names can link to a unique local `resources/views/*.blade.php`
  path, including dotted view names. Dynamic view names remain unresolved.
- **Razor (`.razor`, `.cshtml`):** `@code` / `@functions` members, simple
  `@inject` declarations, `@page` literals and simple event method groups such
  as `@onclick="Save"`. A method group is a member reference, not a direct
  invocation during rendering. General inline Razor statements and expressions
  are not covered by this initial projection.

The PHP import resolver recognizes a unique namespace-shaped local path,
including Laravel's conventional `App\` → `app/` prefix. This is a path
convention, not a Composer autoload implementation. Multiple matching view or
class files do not produce an arbitrary dependency edge.

## Limits

These features provide static navigation, not PHP runtime or Roslyn semantic
resolution. Verify runtime behavior and cited source before changing code:

- PHP magic methods, runtime class aliases, variable method names, arbitrary
  Composer mappings and container/facade dispatch need additional tracing.
- C# overload selection, extension methods, virtual dispatch, generated partial
  types, implicit local inference and dependency injection are not
  compiler-resolved here.
- Template projection is partial. Unsupported expressions can produce recovered
  syntax errors; check `syntaxErrorCount` rather than assuming complete coverage.
- Existing linker confidence and completeness checks still apply. A syntax
  match does not prove runtime dispatch, and an empty query does not prove
  absence.

The analyzer identifiers are `tree-sitter-php-csharp` and
`web-template-islands`, both version 1. Their new identities reparse affected
files; linker version 9 refreshes stored reference links. No index schema or
MCP protocol change is required.

## Grammar provenance

The generated parser/scanner sources are vendored in
`VesaliusKit/Sources/CTreeSitterGrammars`, following the existing grammar layout.
They require no parser generator or network download during a normal build.

| Grammar | Release | Exact revision | Source |
| --- | --- | --- | --- |
| PHP and PHP-only | v0.24.2 | `5b5627faaa290d89eb3d01b9bf47c3bb9e797dea` | [tree-sitter-php](https://github.com/tree-sitter/tree-sitter-php) |
| C# | v0.23.1 | `362a8a41b265056592a0c3771664a21d23a71392` | [tree-sitter-c-sharp](https://github.com/tree-sitter/tree-sitter-c-sharp) |

MIT license notices are retained under the grammar target's `LICENSES`
directory. PHP and PHP-only share `common/scanner.h`; the target includes the
PHP tree-sitter header directory for that scanner. Generated tables retain the
repository's existing `linguist-generated` attributes.

## Tests

`WebLanguageTests` checks declarations/calls, aliases, explicit fields, shadowed
and unknown receivers, malformed source, unchanged analyzer selection,
Unicode source lines and comment decoys. `WebIndexTests` exercises real indexing,
cross-file callers, Razor scanning and literal Blade dependencies in synthetic
repositories using the existing fixture helper.

```sh
cd VesaliusKit
swift test --filter 'WebLanguageTests|WebIndexTests'
```
