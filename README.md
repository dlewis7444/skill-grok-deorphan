# grok-deorphan

Grok Build skill that finds (and optionally kills) **orphaned** Grok agent
processes owned by the current user — agents with no live terminal attachment
(SSH-dead leftovers, post-`/minimal` / `/fullscreen` detachments, idle CPU hogs).

This repo is the maintenance home for the skill. On a Grok host, install it at:

```text
~/.grok/skills/grok-deorphan → this directory (symlink)
```

`SKILL.md` is the agent-facing procedure; `scripts/deorphan.sh` does the real work.
Slash command: **`/deorphan`**.

## What it classifies

| Class | Meaning |
|-------|---------|
| **KEEP** | Live terminal: real `pts/*` ctty, open FD to a live `/dev/pts/N`, and/or `sshd:user@pts/N` ancestor with a live pts. Always listed, including the invoker (`SELF`). |
| **ORPHAN** | No live terminal. Deleted pts FDs alone do **not** count as attached. |
| **WRAPPER** | ProjectMan re-spawn bash wrappers; considered in kill mode only when they have no attached grok child. |

## Modes

| Command | Behavior |
|---------|----------|
| `/deorphan` or `/deorphan kill` | Classify, **TERM** orphans (then **KILL** if needed), report |
| `/deorphan check` | Classify + report only — no signals |

## Install (Grok host)

```bash
git clone git@github.com:dlewis7444/skill-grok-deorphan.git ~/path/to/skill-grok-deorphan
mkdir -p ~/.grok/skills
ln -sfn ~/path/to/skill-grok-deorphan ~/.grok/skills/grok-deorphan
```

The agent always invokes:

```bash
bash "$HOME/.grok/skills/grok-deorphan/scripts/deorphan.sh" check   # or kill
```

## Safety guarantees (in the script)

- Only processes owned by `$UID`
- Never process-group wipes (`pkill` / `killall` / `kill -- -PGID` forbidden)
- Explicit PID `SIGTERM`, optional `SIGKILL` after re-check
- Invoking agent (`SELF`) is force-listed under KEEP and never kill-listed
- Exe must be a Grok Build binary; cmdline denylist skips this skill and debuggers

## Origin

Originally developed as a user-scoped Grok skill for reclaiming idle detached
agent processes; maintained here as `skill-grok-deorphan` with slash command
`/deorphan` and install path `~/.grok/skills/grok-deorphan`.
