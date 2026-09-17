# Projected preview architecture

This preview was migrated from BeckNvim into the renderer. It requires
Neovim 0.12 or newer and the Markdown Tree-sitter parsers. The fork retains the setup,
command, and custom-handler interfaces on a best-effort
basis. The source-mapped preview is the default; the legacy side-by-side preview
has been removed. Set `preview.enabled = false` for ordinary inline rendering.

```lua
require('render-markdown').setup({})
```

Markdown files then open rendered in their current window. `:RenderMarkdown preview`
and `require('render-markdown').preview()` switch between rendered text and source.
Set `preview.auto_open = false` for manual entry. Mermaid activates automatically when an
executable is available; installation is optional. For lazy.nvim, a host can use
`dependencies = { { 'BeckWlim/termaid', optional = true } }` and declare Termaid
separately to opt in. No Python package is installed by this renderer.

Configure diagrams through `preview.mermaid`: `enabled = false` disables them,
`command` selects an executable, and `arrow_position = 'middle'` changes arrowhead
placement (default `'end'`). Resource limits and scheduling remain internal.

## Ownership

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

`preview/providers.lua` assembles enabled providers. `preview/init.lua` owns the
source/preview session, source anchors, generated buffer, window restoration,
incremental patches, and refresh subscriptions. Only untouched prose is parsed as
Markdown in the generated buffer; generated labels cannot become accidental links
or code blocks. Upstream continues to render prose through its ordinary lifecycle,
configuration, and custom-handler dispatch. Projected buffers participate in the
existing source lookup and `overrides.preview` configuration path. Table decorations
are disabled only in projected buffers that already contain generated tables.

## Editing and lifecycle

Every generated row is a real buffer line, so native cursor movement, Visual
selection, scrolling, and yanking operate on displayed text. `q` and `<C-q>` return
to source; Enter retains native next-line movement. Normal editing keys restore the
mapped source position and replay native counts and registers. Returning to Normal
mode restores preview after a quick edit; explicitly selected source stays raw.
`:write`, `:update`, undo, and redo target the original buffer. Native write hooks,
readonly and external-change checks, encoding, and forced writes remain in effect.

Buffer switches preserve jump history. Hidden previews survive navigation and quick
edits. Explicit source selection, source deletion, or window closure retires the
session, its subscriptions, and provider jobs. Refreshes wait for navigation to be
idle and preserve unchanged object rows. Hidden source buffers receive native file
change checks. Global and buffer enable/disable commands retire projected views as
appropriate. Missing parsers leave a source-only preview; oversized documents show
a size-limit message without changing the source.

## Host integration

The public API adds three optional helpers:

| Call | Result |
| --- | --- |
| `source_location(win?)` | Source buffer and `{ row, byte_column }` under the preview cursor |
| `display_position(win, position)` | Corresponding preview position for a source position |
| `leave_preview()` | Restore source before a dashboard or another full-window UI takes over |

Positions use one-based rows and zero-based byte columns. Helpers return no position
outside a projected preview. `b:markdown_preview_source` identifies its original
buffer for statuslines and other passive consumers. Hosts retain their key choices,
theme overrides, link opener, and pinned-context UI. The plugin supplies default
semantic highlight links; it never requires host `config.*` modules. Wrapped table
cells map bytes precisely; Mermaid rows map approximately to diagram source rows
because Termaid does not return source-byte metadata.

## Validation

Run the focused checks without a user configuration:

```sh
nvim --headless -u NONE -i NONE -l tests/preview/run.lua
```

The tests require installed `markdown` and `markdown_inline` Tree-sitter parsers.
They cover source maps, table wrapping, async cancellation and stale results,
preview navigation, editing, saving, source restoration, optional dependencies,
custom handlers and public enable/disable APIs. `just test` runs these fork-owned
checks; inherited inline-renderer tests remain available as `just test-inline`.
