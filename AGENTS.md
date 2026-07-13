# grok-deorphan — agent notes

## What this project is

Maintenance home for the **deorphan** Grok skill (`/deorphan`): classify attached
vs orphaned Grok agent processes for the current user, optionally kill orphans,
print a report that always lists every attached session (including `SELF`).

## Layout

| Path | Purpose |
|------|---------|
| `SKILL.md` | Agent-facing skill (frontmatter + procedure); `name: deorphan` |
| `scripts/deorphan.sh` | Classifier + killer; sole runtime implementation |
| `README.md` | Human install / overview |

## Install path Grok expects

The skill body hardcodes:

```bash
bash "$HOME/.grok/skills/grok-deorphan/scripts/deorphan.sh" [check|kill]
```

So production installs must present this tree at `~/.grok/skills/grok-deorphan`
(prefer a symlink to this repo). Do not move the script without updating
`SKILL.md`.

## Editing rules

- Keep kill logic **only** inside `scripts/deorphan.sh`. The skill must not
  teach ad-hoc `/proc` scans or hand-rolled `kill`s.
- Preserve hard safety rules: uid-only, no process-group kills, SELF never
  orphan-listed, deleted pts alone is not "attached".
- Default mode remains **kill**; `check` is dry-run only.
- After behavior changes, run both modes on a quiet host and paste the report
  blocks as verification evidence.

## Smoke check

```bash
bash scripts/deorphan.sh check
bash scripts/deorphan.sh --help
```
