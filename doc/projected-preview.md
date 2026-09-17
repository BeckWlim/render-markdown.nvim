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

Run the focused checks without a user configuration:

```sh
nvim --headless -u NONE -i NONE -l tests/preview/run.lua
```

The tests require installed `markdown` and `markdown_inline` Tree-sitter parsers.
