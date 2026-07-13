---
name: deorphan
description: >
  Find orphaned Grok agent processes (no live terminal) owned by the current
  user; optionally kill them; print a short report that always lists every
  attached session (including SELF). Use when the user runs /deorphan,
  /deorphan check, /deorphan kill, complains about idle Grok eating CPU,
  leftover sessions after /minimal or /fullscreen, detached grok processes,
  or asks to reap/clean/check orphan grok PIDs.
user-invocable: true
argument-hint: "[check|kill]"
metadata:
  short-description: "Check or kill detached Grok orphans"
---

# /deorphan

Classify **orphaned** vs **attached** Grok Build agent processes for **this user**.
Optionally kill orphans. Always return the script report, which lists **every**
attached session (including the one that invoked the skill, tagged `SELF`).

## Modes (user args → script arg)

| User runs | Script | Behavior |
|-----------|--------|----------|
| `/deorphan` | `…/deorphan.sh` or `…/deorphan.sh kill` | Check, **kill** orphans, report |
| `/deorphan kill` | `…/deorphan.sh kill` | Same as default |
| `/deorphan check` | `…/deorphan.sh check` | Check + report only — **no signals** |

Map any free text after the skill name the same way: if the user said **check** / dry-run / report-only → `check`. If they said **kill** / reap / clean, or said nothing → `kill`.

Unknown extra args: do **not** invent flags. Tell the user supported modes are `check` and `kill`, then stop.

## Do this — nothing else

1. Choose mode from the table above.
2. Run **exactly one** of these (no pipeline, no `sudo`, no `pkill`, no invented filters):

```bash
# default / kill
bash "$HOME/.grok/skills/grok-deorphan/scripts/deorphan.sh" kill

# check only
bash "$HOME/.grok/skills/grok-deorphan/scripts/deorphan.sh" check
```

Bare default (also kill) is fine if args are empty:

```bash
bash "$HOME/.grok/skills/grok-deorphan/scripts/deorphan.sh"
```

3. Paste the script’s stdout into your reply (the `=== deorphan report ===` block).
4. One-sentence summary:
   - **check:** how many attached (note which is SELF), how many orphans, nothing killed.
   - **kill:** how many killed, how many attached kept (including SELF).
5. **Stop.** Do not scan `/proc` yourself. Do not `kill` any PID by hand. Do not “improve” the command.

## Forbidden

- `pkill`, `killall`, `kill -- -PGID`, `kill -9 -1`, broad `ps | awk | xargs kill`
- Touching other users’ processes, shared production service accounts, or multi-tenant app UIDs
- Killing processes that still have a **live** terminal attachment
- Calling `kill` mode when the user asked for `check`
- Rewriting the script mid-flight unless the user asks to change the skill

## What the script already guarantees

All of this is **inside** `scripts/deorphan.sh` (do not re-check in ad-hoc shell):

| Check | Effect |
|-------|--------|
| `uid == $UID` | Only current user’s processes |
| **KEEP** = live terminal | ctty `pts/*` that exists, and/or open FD to a **live** `/dev/pts/N`, and/or `sshd:user@pts/N` ancestor with live pts |
| **ORPHAN** = no live terminal | Deleted pts FDs alone do **not** count as attached (SSH-dead leftovers) |
| **SELF** tag | Invoking agent is always listed under KEEP with `SELF` when detected (force-merged after scan if classify omitted it; never kill-listed) |
| Report fields | `pid ppid tty cwd resume live_pts del_pts reason` so sessions map to projects |
| `/proc/pid/exe` is a Grok binary | Not random commands with “grok” in args |
| cmdline denylist | Skips `deorphan` / `de-orphan` / `grok-deorphan`, reap helpers, debuggers |
| Explicit PID `kill -TERM` then optional `KILL` | No process-group wipes (kill mode only); never signals SELF |
| Orphan bash re-spawn wrappers | TERM only if no attached grok child remains (kill mode only) |
| `mode: check` in report | Confirms no signals were sent |

## If the script is missing

Tell the user the skill install is broken (`~/.grok/skills/grok-deorphan/scripts/deorphan.sh`). Do **not** improvise a killer.
