# Projected preview architecture

The projection layer represents generated content as real buffer rows. A provider
returns non-overlapping source ranges, styled text chunks, source rows, and optional
byte spans. The compositor copies untouched Markdown between these ranges.

`preview/features.lua` owns composition, source/display mapping, object identities,
changed-row intervals, refresh subscriptions, and deferred work dispatch.
`preview/table.lua` owns table discovery, width allocation, independent cell wrapping,
and byte spans. It has no window, editing, or process lifecycle. Rendered content is
cached separately from its source position so moving an object can reuse its layout.

This is separate from the existing custom-handler contract: custom handlers continue
to return extmarks for upstream's renderer. Projection providers return real text
rows so native cursor movement, selection, and yanking can reach continuations.

`preview/mermaid.lua` is an optional provider. It discovers Mermaid fences and
uses a declared lazy.nvim Termaid checkout when available, otherwise a conventional
managed checkout or `termaid` on PATH. An explicit command overrides discovery.
A declared but unbuilt checkout does not silently select an unrelated PATH tool.
Missing executables leave fences unchanged without loading placeholders.

Layout reserves measured or estimated rows and returns deferred tasks; it starts no
processes. The compositor commits the frame before dispatch. The provider admits
eight distinct diagrams, runs at most two jobs concurrently, and limits source,
output, rows, chunks, and execution time. Content identities and generations reject
stale completions; source extmarks associate changed elements with their previous
render. Teardown cancels jobs and subscriptions. Failure restores source text.

Run the focused checks without a user configuration:

```sh
nvim --headless -u NONE -i NONE -l tests/preview/run.lua
```

The tests require installed `markdown` and `markdown_inline` Tree-sitter parsers.
