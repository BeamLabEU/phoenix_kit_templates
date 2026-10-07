# PR #5 — Editor: a text version in the preview, and optional Markdown/text converters

**Author:** timujinne · **Merged:** 2026-10-07 (`1debbec`) · **Reviewer:** Claude
**Released as:** 0.2.4

## Summary

`Editor`'s `preview` may now return `{subject, html, text}`, which adds HTML/Text
tabs to the preview. A new optional `convert` attribute (`to_text`,
`markdown_to_html`) adds two buttons that fill the Text or HTML field from the
form's own content. Re-clicking the open template or language tab no longer
reloads the form. 258 tests, 0 failures; format, `compile --warnings-as-errors`
and `credo --strict` are clean.

The design holds up. A conversion writes nothing: it puts the result into
`form_values`, leaves `baseline` alone, and so Save writes the converted part like
any edited one and never touches a part the user left alone. The converter is
called with the form's text, not the disk's, and an invalid-UTF-8 source or target
refuses the conversion rather than treating it as blank. Converters are wrapped by
`safely/2` like the other callbacks, and an unusable `convert` shape (`[]`, a bad
keyword list, a wrong-arity fun) counts as no converter — no button, and the event
is ignored server-side too, with `writable?` re-checked. The text tab renders
through `{@text}` in a `<pre>`, so it is escaped. `{subject, html, :none}` from a
host is an error, so the internal `:none` marker cannot be forged. `form_rev` on
every textarea is a sound way to force a redraw when a conversion's result equals
what the server already had. A refused part now stays in the form as sent
(`refused_values/2`), which also fixes a conversion's output being lost on a
partly-refused save.

## Findings

### NITPICK — a stray comment and a misplaced `@impl true` (fixed)

The first `handle_event/3` clause carried two comment blocks with `@impl true`
between them; the upper one ("Clicking the template or tab already open switches
nothing…") restated the lower one. Dropped the duplicate; `@impl true` now sits
directly above the clause.

### NOTE — the LiveView 1.0 lower bound for the submitter's `action` is not verified here (not changed)

The conversion buttons rely on LiveView sending the clicked submit button's
`name`/`value` with `phx-submit`. The docs claim this from `phoenix_live_view`
1.0, the package's minimum (`~> 1.0`). The installed 1.2.12 does it (the client
reads the `submitter`), which the tests exercise, but only that version is tested
in this repo, so the 1.0 claim rests on the author's reading of the LiveView
changelog. A degraded host would still be safe: a submit that names no action
saves, so the conversion buttons would act as Save, never as data loss. Left on
record.

### NOTE — re-clicking the open template no longer re-reads the files (not changed)

Intended (see the changelog), and the form was already refreshed on every parent
`update/2` for the parts the user has not edited, so another session's change still
shows once the parent re-renders. A user who wants a reload selects another
template or tab and back.
