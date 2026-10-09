# Projected preview architecture

This preview was migrated from BeckNvim into the renderer. It requires
Neovim 0.12 or newer and the Markdown Tree-sitter parsers. The fork retains the setup,
command, and custom-handler interfaces on a best-effort
basis. Source-mapped preview is an optional capability of each viewing context;
the legacy side-by-side preview has been removed. `preview.enabled = false`
disables the capability globally.

```lua
require('render-markdown').setup({})
-- The owner of this window explicitly permits projection.
vim.w.render_markdown_preview = true
```

Approved Markdown windows then open rendered on the next entry event. `:RenderMarkdown preview`
and `require('render-markdown').preview()` switch between rendered text and source.
Set `preview.auto_open = false` for manual entry. Mermaid activates automatically when an
executable is available; installation is optional. For lazy.nvim, a host can use
`dependencies = { { 'BeckWlim/termaid', optional = true } }` and declare Termaid
separately to opt in. No Python package is installed by this renderer.

## Context permission

The default `preview.condition(source, window)` accepts only windows with
`w:render_markdown_preview = true`. The source is the original buffer, even when
the window currently shows generated text. Hosts may supply a different callback;
only a literal `true` grants permission. Keep the callback synchronous and free of
side effects. Do not grant permission solely because a buffer has Markdown filetype.

Automatic entry, `:RenderMarkdown preview`, the public `preview()` command, and
internal entry all check the same permission. Scheduled entry checks it again before
replacing a buffer. To opt in immediately, set the window variable and call
`require('render-markdown').preview()`. `auto_open = false` still allows manual entry
in approved contexts. Native diff windows and `diffview://` documents remain blocked
as a defensive invariant, even when the callback grants permission.

Permissions belong to the destination window, so two windows displaying one source
can use different modes. Owners should set their permission before exposing a view
and clear it when returning the window to a different owner. To revoke an active
view immediately, set its permission to false and call
`require('render-markdown').leave_preview()` in that window; entry events also
reconcile permissions. Revocation restores source text and retires
only that window's session. A native split copying a projection into an unapproved
window restores the copied source without closing the original preview.

Unapproved contexts retain the normal inline renderer and their source buffer.
Projection still requires an ordinary Markdown source buffer (`buftype = ''`);
approval does not bypass the source/write contract for scratch buffers.

Configure diagrams through `preview.mermaid`: `enabled = false` disables them,
`command` selects an executable, and `arrow_position = 'middle'` changes arrowhead
placement (default `'end'`). Resource limits and scheduling remain internal.

## Ownership

The projection layer represents generated content as real buffer rows. A provider
returns non-overlapping source ranges, styled text chunks, source rows, and optional
byte spans. The compositor copies untouched Markdown between these ranges.

`preview/projection.lua` owns composition, source/display mapping, object identities,
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

Layout reserves measured or estimated rows and returns deferred tasks; it starts no processes.
The compositor commits the frame before dispatch.
The provider admits at most eight Mermaid jobs at a time and runs at most two concurrently.
Completion admits later diagrams until the document is rendered.
Source, output, rows, chunks, and execution time remain bounded. Content identities and generations reject stale completions; source extmarks associate changed
elements with their previous render.
Teardown cancels jobs and subscriptions.
Failure restores source text.

`preview/projection.lua` assembles enabled providers. `preview/init.lua` owns the
source/preview session, source anchors, generated buffer, window restoration,
incremental patches, and refresh subscriptions. Only untouched prose is parsed as
Markdown in the generated buffer; generated labels cannot become accidental links
or code blocks. Upstream continues to render prose through its ordinary lifecycle,
configuration, and custom-handler dispatch. Projected buffers participate in the
existing source lookup and `overrides.preview` configuration path. Table decorations
are disabled only in projected buffers that already contain generated tables.

Each frame commit invalidates ordinary Markdown decorations before replacing
text and parse regions, then requests their rebuild through the existing renderer
after cursor restoration. The deferred request belongs to the current session and
generation; superseded or retired views cannot publish it. Saves also request a
rebuild, so language labels do not depend on a later cursor or text-change event.
Before every preview highlighter start, the renderer reapplies configured query
adjustments to the current Markdown query. Lazy-loading another plugin can replace
that query through a runtime-path change; native code-fence line concealment must
remain disabled so it cannot hide the renderer's language decorations.

## Editing and lifecycle

Every generated row is a real buffer line, so native cursor movement, Visual selection, scrolling, and yanking operate on displayed text. `q` and `<C-q>` return to source; Enter retains native next-line movement.
Normal editing keys restore the mapped source position and replay native counts and registers.
Visual delete, change, replace, paste, indent, join, and case conversion map both selection endpoints to source and replay the native command.
Characterwise selections edit the contiguous source range between those endpoints; linewise selections edit whole source rows, including when selecting a wrapped table continuation.

Block edits work on unchanged prose; selections crossing generated table or diagram rows require source mode because their display columns do not form a source rectangle.
Visual text objects, endpoint motions, and yanks retain their native preview behavior.
Background refreshes wait until Visual mode ends. If the source changes meanwhile, the edit asks you to leave Visual mode and select again against the refreshed text.

Returning to Normal mode restores preview after a quick edit; explicitly selected
source stays raw.
`:write`, `:update`, undo, and redo target the original buffer. Native write hooks, readonly and external-change checks, encoding, and forced writes remain in effect.

Buffer switches preserve jump history. Hidden previews survive navigation and quick edits.
Every window of a source owns its generated buffer, source map, cursor, and width-specific provider jobs.
Native splits create independent projections; closing or replacing a pane preserves its siblings.

Explicit source selection or window closure retires only that view.
Source deletion retires all its views; source subscriptions remain active until the last view closes.
Source changes, provider completions, and resize events post coalesced refresh
messages to the main loop. Insert/Visual modes, active interactions, and hidden
views retain the dirty request; Normal-mode, interaction-completion, and preview-entry
events resume it. No idle timer controls view lifetime or refresh readiness.
Frame commits preserve cursor/source anchors and unchanged object rows.
Hidden source buffers receive native file change checks. Global and buffer enable/disable commands retire projected views as appropriate.

Missing parsers leave a source-only preview; oversized documents show a size-limit message without changing the source.

## Host integration

The public API provides source mapping and optional operation routing:

| Call | Result |
| --- | --- |
| `source_location(win?)` | Source buffer and `{ row, byte_column }` under the preview cursor |
| `display_position(win, position)` | Corresponding preview position for a source position |
| `leave_preview()` | Restore source before a dashboard or another full-window UI takes over |
| `source_buffer(buf?)` | Original buffer identity for source or preview |
| `interaction(win?)` | Source/display coordinates, links, syntax ranges, and selection |
| `dispatch(operation, options?)` / `wrap(operation, options?)` | Run an operation or build a callback with source/display routing |
| `select_node(index?, options?)` | Select source syntax; `options.preview = true` projects the selection |
| `link_at_cursor(win?)` | Source link metadata for a user-configured opener |

Positions use one-based rows and zero-based byte columns. Source/display position
helpers return no position outside a projected preview. `b:markdown_preview_source` identifies its original
buffer for statuslines and other passive consumers. Hosts retain their key choices,
theme overrides, link opener, and pinned-context UI. The plugin supplies default
semantic highlight links; it never requires host `config.*` modules. Wrapped table
cells map bytes precisely; Mermaid rows map approximately to diagram source rows
because Termaid does not return source-byte metadata.

Normal-mode text jumps work directly in preview; existing user mappings take precedence
over native edit fallbacks. Source syntax selection runs in source by default;
`select_node(nil, { preview = true })` opts into projecting a source selection.

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
