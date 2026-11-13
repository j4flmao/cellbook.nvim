## Summary

<!-- What does this change and why? Link the spec or issue. -->

## Constitution checklist

- [ ] Round-trip safety: unmodified notebooks still save byte-identically (fixture tests pass)
- [ ] A regression fixture was added if this fixes a notebook-altering bug
- [ ] No blocking I/O on the main loop; no new hard plugin dependency; no pynvim
- [ ] Keymaps stay buffer-local and disable-able
- [ ] `doc/cellbook.txt` and README updated for user-facing changes
- [ ] Tests added/updated (`./scripts/test.sh`, `uv run pytest`)
