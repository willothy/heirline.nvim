# Heirline.nvim

## Rules

- Commit regularly with conventional commits style and imperative tense
  - Commits should be atomic. Never mix unrelated changes into the same commits.
  - Never include a co-authored-by signature in commit messages
  - Never include meta-commentary about roadmap or the chat session in commit messages
- Design for reliability and production-readiness always. Never take shortcuts.
- Never make decisions for the purpose of shipping fast; always do things the RIGHT way.
- Never include meta-commentary about roadmap or the chat session in code comments
- Use doc-comments in code
- Always format code before committing (`cargo fmt --all` for Rust). Never commit unformatted code; it breaks format-on-save editor workflows.
- Formatting changes must never be bundled with other work. Format as part of authoring each change so commits are format-clean by construction; if a formatting-only fix is ever needed, it gets its own `style:` commit touching nothing else.
- Avoid free-floating *helper* functions — small utilities that have no meaning outside one caller's context; they belong as methods (or associated functions) on the type that owns the data or resource. Free functions are fine when they are genuinely standalone operations.
- Don't touch unrelated parts of the code when making changes; don't remove comments, change imports, etc. unless the change
  is necessary and related to the primary change.
- Review your own diff before committing. Read it as a pedantic senior engineer would and fix what they would flag.

## Code Quality

- No shortcuts. No band-aid fixes. No "for now" implementations or stubs left behind as if complete.
- Write solid, production-grade code that a pedantic senior engineer would approve: correct error handling, no unwraps on fallible paths in library code, clear ownership of invariants, documented unsafe blocks.
- If a proper solution requires more research or design work, do that work instead of shipping a degraded version.
- Avoid floating helper functions - prefer methods on types or trait impls.

## Edit Discipline

- When making edits, do not touch unrelated code.
- Do not delete or rewrite existing comments unless the change makes them wrong or they are directly relevant to the edit.
- Keep refactors separate from behavior changes (and in separate commits).
- The only allowed workflow is strictly serial: change, commit, change, commit. Never start a second change while one is uncommitted — not even if the commits would end up separate.
- If commit signing fails, commit unsigned rather than blocking; re-sign later.
