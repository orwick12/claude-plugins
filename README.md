# claude-plugins

A personal Claude Code plugin marketplace. One plugin so far: **plan-and-verify**.

## Publish (once, from your machine)

1. Create an empty GitHub repo named `claude-plugins` (private is fine).
2. Edit `.claude-plugin/marketplace.json`: set `name` to your GitHub username and `owner.name` to your name. Do the same for `author.name` in `plugins/plan-and-verify/.claude-plugin/plugin.json`.
3. Push:
   ```
   git init && git add -A && git commit -m "plan-and-verify 1.0.0"
   git branch -M main && git remote add origin git@github.com:<you>/claude-plugins.git && git push -u origin main
   ```

## Install (every machine, once)

Prerequisites first: `./prereqs.sh` on macOS/Linux, or `.\prereqs.ps1` in PowerShell on Windows (installs Git for Windows and jq via winget if missing, and points Claude Code at Git Bash for hooks). Restart Claude Code after the Windows one.

Then, in a terminal:
```
claude plugin marketplace add <you>/claude-plugins
claude plugin install plan-and-verify@<you>
```
For a private repo, the machine needs GitHub access (SSH key or `gh auth login`). Inside Claude Code the same works as `/plugin marketplace add <you>/claude-plugins` then `/plugin install plan-and-verify@<you>`; if it says to run `/reload-plugins`, do.

## Use it in every project

Nothing to add per project. Open any repo, and:
- `/agents` lists `builder-sonnet`, `builder-opus`, `milestone-reviewer` under plugin agents
- `/hooks` shows the plugin's SessionStart, SubagentStop and PreToolUse hooks
- the first message of a session includes "plan-and-verify vX is installed. Its scripts are in PV_HOOKS=…"
- `/plan-and-verify <what to build>` writes a plan into `<project>/.claude/build-plans/<slug>/`; commit that folder

To make a team repo use it: `claude plugin install plan-and-verify@<you> --scope project` writes it to the repo's `.claude/settings.json`, and Claude Code prompts collaborators to enable it.

## Update

Edit the plugin, bump `version` in both manifests, commit and push. On each machine: `claude plugin update plan-and-verify`. Plans written before the update carry a `hooks.lock`; the next session warns, and `bash "$PV_HOOKS/lock-hooks.sh" write <slug>` + commit re-locks them. Acceptance refuses until that is done, on purpose.

See `plugins/plan-and-verify/README.md` for how the enforcement works and where it falls down.
