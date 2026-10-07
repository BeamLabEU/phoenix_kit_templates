# PR #4 — A write API for override files and an optional LiveView editor

**Author:** timujinne · **Merged:** 2026-10-07 (`8f9dcc6`) · **Reviewer:** Claude
**Released as:** 0.2.3

## Summary

`Overrides` gains `write/5`, `delete/4`, `delete_template/2`, `copy_template/3`,
`list/1`, `valid_name?/1`, `max_bytes/0` and a `label` part; a new
`PhoenixKit.Templates.Editor` `LiveComponent` edits those files. `phoenix_live_view`
is an optional dependency and the editor is compiled only when it is present, so the
package stays a leaf.

The design holds up. Every path goes through one `target/4` (name pattern, part,
locale, `Path.safe_relative/2` for symlinks) before the filesystem is touched;
writes are temp-file + `datasync` + rename with the mode kept; copies are built in a
hidden directory and renamed into place; the cache is reset for the root after every
change, a half-failed `delete_template/2` included. In the editor every event
re-checks `editable?` and the prefix list server-side, so a tampered
`phx-value-*` cannot reach a template the page did not list; the preview is a
script-less `sandbox` iframe and `{:safe, _}` is turned back into an escaped string;
host callbacks are wrapped so a raise is a notice, not a crash. No query runs in
`mount/1`. The `baseline` mechanism (never write back a part the user left alone)
is sound. The findings below are about what a refused save does to the form and
about unhardened options.

## Findings

### BUG - MEDIUM — a refused part lost what the user typed (fixed)

`save/2` reloads `contents` from disk after every save, and the textarea is drawn
from `contents`. When one part was refused (over 256 KiB, a write error such as
`:eacces`/`:enospc`) the form came back showing the old file for that part, so a
user who had pasted a large HTML body and tripped the limit saw "Not saved: HTML:
larger than 256 KiB" over a form that no longer held their HTML. The saved parts
being redrawn from disk is right; the refused ones are not.

Fix: a `retained` assign holds the submitted text of refused parts and the textarea
prefers it. `baseline` stays what is on disk, so the retained value still differs
from it and is retried by the next save. `retained` is dropped by `load_contents/1`
(select, tab switch, a later save) and `deselect/1`, and survives a parent
re-render. Two tests: the text is still in the form and a corrected resubmit writes
it; switching tab does not carry it over.

### IMPROVEMENT - MEDIUM — `locales` and `sample_variables` were not sanitized (fixed)

`name_prefixes` was hardened ("a host's mistake allows nothing rather than a
crash"), but `locales` still went through `locales ++ [nil]` and
`sample_variables` through `Enum.sort/1`, so `locales="et"` or a keyword list for
the variables raised on render. Duplicate locales rendered two identical tabs, and
`""` collided with the Fallback tab's `phx-value-locale=""`. `sanitize_options/1`
now treats all three the same way. Test added.

### NOTE — caption and `update/2` read from disk on every parent re-render (not changed)

`load_templates/1` lists the root and reads each template's `label` file on every
`update/2`. That is per-parent-render file I/O proportional to the template count.
A host's admin template list is small and the reads hit the page cache; caching
would need an invalidation story that the cross-session case (another session
saving) makes harder. Left alone, on record.

### NOTE — each write scans every `:persistent_term` (not changed)

`reset_cache/1` iterates `:persistent_term.get/0`, which copies the whole table, and
erasing triggers a global GC. It is per save, by a human, and this package
deliberately mints few keys (`valid_request?/2` keeps junk out), so it is not worth
a separate index. A host that stores thousands of terms of its own would notice.

### NOTE — `exists?/2` reads the `templates` loaded at the last event (not changed)

A template deleted by another session while this one has it open is still
"visible", and a save recreates its directory. That is the documented
last-write-wins stance (an edited part wins, with no check), not data loss.

## Gate

`mix format`, `compile --warnings-as-errors`, `deps.unlock --check-unused`,
`credo --strict`, `dialyzer` and `mix test` (6 doctests, 228 tests) — see the
release commit. The repo defines no `precommit` alias, so the steps ran individually.
