# cellbook.nvim — Product Roadmap & Launch Plan

> Jupyter notebooks in Neovim. Open the `.ipynb`, run it, see the plots. One-line install.

This document sits above the Spec Kit feature specs. It covers positioning, release milestones, future specs, the launch playbook, and the metrics we track. Feature-level detail lives in `specs/NNN-*/`.

---

## 1. Why this project

- Notebooks are repeatedly named as the #1 reason Neovim users keep VS Code or JupyterLab open (r/neovim "what do you miss from VSCode" threads, HN discussions on Neovim releases).
- The space is fragmented: molten-nvim (~1.2k stars, needs the Python remote-plugin host), jupynium / neopyter (browser-driven), jupytext.nvim (conversion), and several small plugins (ipynb.nvim, jupyter.nvim, jupynava.nvim, vim-jukit). No single plugin owns "open → run → see → save" with a one-line install.
- Historically, Neovim's biggest star winners consolidated a fragmented category with a faster, simpler, better-integrated tool (lazy.nvim over packer, blink.cmp over nvim-cmp, fzf-lua/snacks over telescope). This project follows that pattern.

*All star counts are snapshots from research done in 2026 — re-verify before launch.*

## 2. Positioning

| | cellbook.nvim | molten-nvim | jupytext-based | jupynium / neopyter |
|---|---|---|---|---|
| Edit `.ipynb` directly | ✅ | ⚠️ via jupytext/quarto | ❌ converts | ✅ (in browser) |
| Needs pynvim / `:UpdateRemotePlugins` | ❌ | ✅ | ❌ | varies |
| Needs a browser | ❌ | ❌ | ❌ | ✅ |
| Byte-identical round-trip | ✅ goal | n/a | ❌ | n/a |
| Inline images | ✅ via snacks/image.nvim | ✅ | ❌ | in browser |
| `:checkhealth` guided setup | ✅ | partial | ❌ | partial |

Tagline candidates:
1. "Jupyter notebooks in Neovim. No browser. No conversion. No remote plugin host."
2. "Open the .ipynb. Run the cell. See the plot."

## 3. Milestones

| Version | Scope | Target | Public? |
|---|---|---|---|
| v0.1.0-alpha | US1: open/edit/save losslessly | Week 5 | Private (dogfood) |
| v0.2.0 | US2: kernel execution, text outputs | Week 8 | Soft launch (10–20 testers) |
| **v0.3.0** | US3: images, DataFrames, long output; README + demo GIF | **Week 10** | **Public launch** |
| v0.4.0 | US4: motions, text objects, cell ops, statusline | Week 12 | Release post |
| v0.5.0 | US5: kernel selection/restart/cleanup | Week 13–14 | Release post |
| **v1.0.0** | US6: checkhealth, docs, perf; all SC met | **Week 16** | Release post + LazyVim extra PR |

Week 0 = start of Phase 1. Assumes ~12 h/week solo.

## 4. Future specs (post-1.0)

| Spec | Feature | Why it matters |
|---|---|---|
| 002-lsp-kernel-intelligence | Shadow document for clean LSP; kernel-based completion & hover (`complete`/`inspect`) as a blink.cmp / nvim-cmp source | Removes magic-line noise; completion on live variables (DataFrame columns) |
| 003-variable-explorer | Floating/side panel listing kernel variables, shapes, dtypes; DataFrame viewer | VS Code/JupyterLab parity; great demo |
| 004-remote-kernels | Connect to a remote Jupyter Server (HTTP + WebSocket) with token auth | GPU servers, cloud notebooks |
| 005-notebook-git | `git diff` driver for notebooks (cell-level diff), merge-conflict helper | Notebook + git pain is universal |
| 006-other-formats | Quarto `.qmd` and Markdown code-block execution with the same engine | Grows audience beyond `.ipynb` |
| 007-ai-assist (optional) | "Explain error", "fix cell" hooks for existing AI plugins (codecompanion, avante) via the public API | Rides AI interest without competing with AI plugins |

Each future spec gets its own `specs/NNN-*/` folder with spec → plan → tasks.

## 5. Launch playbook

### Before v0.3 launch (weeks 8–10)

- [ ] Name verified (GitHub, LuaRocks, dotfyle); repo description = tagline; topics: `neovim`, `nvim-plugin`, `jupyter`, `ipynb`, `notebook`, `lua`
- [ ] README top: one-line pitch → demo GIF (≤ 15 s, ≤ 5 MB, shows: `:e demo.ipynb` → run DataFrame cell → run matplotlib cell → plot appears → `:w`) → install snippet (lazy.nvim + vim.pack) → "Requirements" table → FAQ "How is this different from …?" → full docs link
- [ ] Record demo with VHS (scriptable, reproducible) in Ghostty/kitty with a popular colorscheme (tokyonight/catppuccin) and a large font
- [ ] Social preview image (1280×640) set in repo settings
- [ ] 10–20 soft-launch testers' issues fixed; no open `data-loss` issues
- [ ] `examples/demo.ipynb` included so anyone can reproduce the GIF

### Launch day (Tuesday–Thursday, 14:00–16:00 UTC — US morning / EU afternoon)

1. **r/neovim** post: title like *"cellbook.nvim — edit and run Jupyter notebooks natively in Neovim (no browser, no pynvim)"*; GIF/video in the post body; first comment from the author with: motivation, how it works (bridge + extmarks), comparison with molten/jupytext, roadmap, call for feedback. Reply to every comment for the first 24 h.
2. Same day: post on X/Bluesky/Mastodon with the video; tag Neovim-related accounts politely (no spam).
3. Day 2–3: submit to **This Week in Neovim** (dotfyle), add to **dotfyle**, PR to **rockerBOO/awesome-neovim** (Notebook section).
4. Day 3–7: **Show HN** ("Show HN: Native Jupyter notebooks in Neovim") — secondary channel; data/ML angle can do better on HN than a typical plugin.
5. Week 2: data-science communities — r/datascience / r/MachineLearning weekly threads (where self-promo is allowed), Python Discord, Neovim Matrix/Discord.
6. Reach out (one short message each) to Neovim YouTube creators/streamers with a link to the demo; never pay or pressure.

### After launch (steady growth)

- Every minor release (v0.4, v0.5, v1.0, each future spec) gets: CHANGELOG, 10-second clip, a new r/neovim post. Star growth for most plugins comes in steps tied to release posts.
- Open the **LazyVim extra** PR at v1.0 (`lang.jupyter` or `editor.cellbook`), following LazyVim's extra conventions; also propose a section/snippet for kickstart.nvim docs or discussions. Inclusion in a distribution is the strongest long-term star driver.
- Write one blog post: "How I made Jupyter notebooks feel native in Neovim" (technical deep-dive: extmarks, round-trip JSON, bridge) — good for HN/Lobsters.
- Triage weekly; label `good first issue` to grow contributors; thank contributors in release notes.

### What not to do

- Don't launch before images work — the plot appearing under a cell is the hook.
- Don't post the same thing more than once per release.
- Don't disparage competitors; compare factually in the FAQ.
- Don't break round-trip trust; one corrupted notebook story on Reddit undoes months of growth.

## 6. Metrics

| Metric | Target | Source |
|---|---|---|
| Stars, 30 days after v0.3 | 500 | GitHub |
| Stars, 12 months | 1,500–3,000 | GitHub / star-history |
| dotfyle configs using it, 12 months | 300+ | dotfyle |
| LazyVim extra | merged within 12 months | LazyVim repo |
| Time to first cell run (new user) | < 3 min | usability tests (SC-002) |
| Open `data-loss` issues | 0 at every release | issue tracker |
| Median issue first-response time | < 48 h | issue tracker |

Star targets are goals, not guarantees: they assume a working v0.3 with a strong demo and consistent release posts.

## 7. Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Notebook corruption bug | Medium | Critical | Test-first format layer, 50+ fixture corpus, atomic writes, `debug` self-check, `data-loss` priority |
| Image rendering inconsistent across terminals/tmux | High | Medium | Delegate to snacks/image.nvim; placeholder fallback; checkhealth hints for tmux passthrough |
| LSP noise from magics/markdown | Medium | Medium | Comment-prefixed markdown (R2), diagnostic filter (R7), shadow doc in spec 002 |
| Python env confusion (which python?) | High | Medium | Clear discovery order, `python` option, checkhealth shows path used |
| A bigger author ships a similar plugin | Low–Medium | High | Ship v0.3 fast; own the "lossless + zero-setup" niche; build community early |
| Maintainer burnout | Medium | High | Small core (Constitution VI), strict scope, say no to HTML/widgets in 1.x, recruit co-maintainers after 1.0 |

## 8. Repository layout for Spec Kit

```text
cellbook.nvim/
├── .specify/
│   └── memory/constitution.md
├── specs/
│   └── 001-notebook-core/
│       ├── spec.md
│       ├── plan.md
│       ├── research.md
│       ├── data-model.md
│       ├── quickstart.md
│       ├── tasks.md
│       ├── contracts/
│       │   ├── bridge-protocol.md
│       │   ├── lua-api.md
│       │   └── commands-keymaps-config.md
│       └── checklists/requirements.md
├── ROADMAP.md
└── (source tree as in specs/001-notebook-core/plan.md)
```

If you use the `specify` CLI, run `specify init --here --ai claude` in the repo first, then copy these files over the generated templates; continue with `/speckit.implement` on `tasks.md`.
