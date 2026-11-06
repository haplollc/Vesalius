# Changelog

## Unreleased

- PHP and C# syntax-tree declarations, calls, import aliases and explicit receiver-type hints.
- Partial Blade and Razor code sections with original source lines, literal Blade view dependencies,
  Razor injection directives, route literals and event method-group references.
- Namespace-aware PHP/C# type links and a linker version bump to refresh existing indexes.

## 2.1.0 (2026-10-23)

Two commands from nothing to answers, and a way to see whether Claude is using it.

- **`brew install haplollc/tap/vesalius`** installs a prebuilt binary for Apple silicon (macOS 15 and later). No Xcode
  needed.
- **`vesalius setup`** connects Claude Code for every project, and Codex when its command line is installed. It also
  lets Claude Code run the read-only tools without asking, checks that the server answers, and indexes the repository
  you're in. `--dry-run` shows the plan and `--undo` reverses it. It never writes to your repository, CLAUDE.md or
  hooks.
- **`vesalius doctor`** starts the server the way Claude Code would and checks every link from the command to the
  index, printing a fix for anything that's off:
  - the registration and connection;
  - the server's tool list;
  - which repository it serves and how fresh that index is;
  - when it was last called over MCP.
- **`vesalius stats`** shows what Claude asked: calls per tool, answer sizes, typical answer time, and how many
  completeness checks passed. It reads a local tally that records, per call, the repository path, the tool, and the
  answer's size and time. It never records questions, symbols or code. `VESALIUS_STATS=off` stops it.
- **Every tool declares the full set of MCP annotations.** Read-only was already declared; 2.1.0 adds
  non-destructive, idempotent and closed-world.
- **`vesalius --help`** groups the commands by what they're for.

What Claude sees is unchanged from 2.0.0: the same five tools, descriptions, server instructions and answers. The
benchmark was run on 2.0.0.

## 2.0.0 (2026-10-22)

First public release:

- the five MCP tools (`usages`, `feature_map`, `outline`, `architecture`, `dependency_cycles`);
- the Mac app and the VS Code extension;
- the round 2 benchmark: about half the tokens, with no measurable change in answer quality.
