---
name: claude-code-setup
description: Set up the full Claude Code development environment — install plugins (superpowers, claude-mem, web-access, pua, claude-hud), install skills (context7, docx, pdf, xlsx, pptx, frontend-design, skill-creator, skill-vetter, find-skills, wechat-article-extractor), configure GitHub auth and gh CLI. Use this skill when the user asks to set up Claude Code environment, install standard plugins/skills, or configure a new Claude Code installation on a server.
---

# Claude Code Setup

Configure a complete Claude Code development environment: GitHub auth, gh CLI, plugins, skills, and project memory.

## Prerequisites

Before running this skill, the user must have:
- Node.js + npm installed (use `server-init` skill if needed)
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`) and logged in
- Network access to GitHub

## Parameters

Ask the user for required parameters if not provided:

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `github_username` | yes | — | GitHub username for git config |
| `github_email` | yes | — | GitHub email for git config |
| `extra_plugins` | no | `[]` | Additional plugins to install beyond the default list |
| `extra_skills` | no | `[]` | Additional skills to install beyond the default list |
| `skip_plugins` | no | `[]` | Plugins to skip from the default list |
| `skip_skills` | no | `[]` | Skills to skip from the default list |

## Execution

### Step 1: Configure Git Identity

```bash
git config --global user.name "<github_username>"
git config --global user.email "<github_email>"
```

Verify: `git config --global --list` shows correct name and email.

### Step 2: Configure GitHub Authentication

Check if `GITHUB_TOKEN` is set:

```bash
echo "GITHUB_TOKEN length: ${#GITHUB_TOKEN}"
```

**If not set (length 0):** guide the user through setup:

1. Go to https://github.com/settings/tokens?type=beta
2. Create a Fine-grained PAT with permissions:
   - **Contents**: Read and Write
   - **Administration**: Read and Write (for creating repos)
3. In Claude Code, execute:
   ```
   ! echo 'export GITHUB_TOKEN=<token>' >> ~/.zshrc && source ~/.zshrc
   ```

**Verify token is valid:**

```bash
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Authenticated as: {d.get(\"login\")}')"
```

**Configure git credential helper** so HTTPS operations use the token:

```bash
git config --global credential.helper store
echo "https://<github_username>:${GITHUB_TOKEN}@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials
```

### Step 3: Install GitHub CLI

```bash
type gh >/dev/null 2>&1 || (curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli-stable.list > /dev/null && sudo apt-get update && sudo apt-get install -y gh)
```

Authenticate gh with the token:

```bash
echo "$GITHUB_TOKEN" | gh auth login --with-token
```

Verify: `gh auth status` shows authenticated.

### Step 4: Install Plugins

Install each plugin. For each plugin:
1. Add its marketplace: `claude /plugin marketplace add <marketplace-name>`
2. Install: `claude plugins install <plugin>@<marketplace>`

The installation commands automatically update `~/.claude/settings.json` and `~/.claude/plugins/installed_plugins.json`.

**Default plugin list (5):**

| Plugin | Marketplace Add Command | Install Command |
|--------|------------------------|----------------|
| `superpowers` | (already in default marketplace) | `claude plugins install superpowers@claude-plugins-official` |
| `claude-mem` | `claude /plugin marketplace add thedotmack/claude-mem` | `claude plugins install claude-mem@thedotmack` |
| `web-access` | `claude /plugin marketplace add --git https://github.com/eze-is/web-access.git` | `claude plugins install web-access@web-access` |
| `pua` | `claude /plugin marketplace add tanweai/pua` | `claude plugins install pua@pua-skills` |
| `claude-hud` | `claude /plugin marketplace add jarrodwatts/claude-hud` | `claude plugins install claude-hud@claude-hud` |

Run each install command. Skip any plugin in the user's `skip_plugins` list. Add any from `extra_plugins`.

After all installs, verify:

```bash
cat ~/.claude/plugins/installed_plugins.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Installed plugins: {len(d[\"plugins\"])}')"
```

### Step 4.1: Configure claude-hud

After installing claude-hud, configure its statusline and optional features:

1. **Detect runtime and plugin path:**
   ```bash
   PLUGIN_DIR=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/claude-hud/claude-hud/*/ 2>/dev/null | awk -F/ '{ print $(NF-1) "\t" $0 }' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 | cut -f2-)
   RUNTIME=$(command -v bun 2>/dev/null || command -v node 2>/dev/null)
   # If runtime is bun, SOURCE=src/index.ts; if node, SOURCE=dist/index.js
   ```

2. **Test the command:**
   ```bash
   bash -c 'plugin_dir=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/claude-hud/claude-hud/*/ 2>/dev/null | awk -F/ '"'"'{ print $(NF-1) "\t" $(0) }'"'"' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 | cut -f2-); exec "<RUNTIME>" "${plugin_dir}<SOURCE>"' 2>&1 | head -3
   ```
   Replace `<RUNTIME>` and `<SOURCE>` with detected values. Should produce output within seconds.

3. **Write statusLine config** into `~/.claude/settings.json` (merge, don't overwrite):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "<the tested command from step 2>"
     }
   }
   ```

4. **Enable optional features** — write `~/.claude/plugins/claude-hud/config.json`:
   ```json
   {
     "display": {
       "showTools": true,
       "showAgents": true,
       "showTodos": true,
       "showDuration": true,
       "showConfigCounts": true
     }
   }
   ```

5. **Remind user**: statusLine requires a Claude Code restart to take effect.

### Step 5: Install Skills

Install each skill via `npx skills add`. The installation automatically creates symlinks in `~/.claude/skills/` and updates `~/.agents/.skill-lock.json`.

**Default skill list (10):**

| Skill | Install Command |
|-------|----------------|
| `context7` | `npx skills add intellectronica/agent-skills@context7 -g -y` |
| `find-skills` | `npx skills add vercel-labs/skills@find-skills -g -y` |
| `frontend-design` | `npx skills add anthropics/skills@frontend-design -g -y` |
| `skill-creator` | `npx skills add anthropics/skills@skill-creator -g -y` |
| `skill-vetter` | `npx skills add useai-pro/openclaw-skills-security@skill-vetter -g -y` |
| `docx` | `npx skills add anthropics/skills@docx -g -y` |
| `pdf` | `npx skills add anthropics/skills@pdf -g -y` |
| `xlsx` | `npx skills add anthropics/skills@xlsx -g -y` |
| `pptx` | `npx skills add anthropics/skills@pptx -g -y` |
| `wechat-article-extractor` | `npx skills add freestylefly/wechat-article-extractor-skill -g -y` |

Run each install command. Skip any skill in the user's `skip_skills` list. Add any from `extra_skills`.

After all installs, verify:

```bash
ls -1 ~/.claude/skills/ | wc -l
```

### Step 6: Configure Project Memory

Create the standard memory structure. Determine the project memory path based on the current working directory:

```bash
# Get the Claude projects path for the current directory
PROJECT_PATH=$(echo "$PWD" | sed 's|/|-|g; s|^-||')
mkdir -p ~/.claude/projects/-${PROJECT_PATH}/memory
```

Write `feedback_skill_vetting.md`:

```markdown
---
name: Skill vetting rule
description: Must run skill-vetter before installing any skill from external sources
type: feedback
---

Always run the skill-vetter skill before installing any new skill from ClawHub, GitHub, or other external sources. No exceptions.

**Why:** Security policy — prevent malicious or poorly-written skills from being installed without review.

**How to apply:** Before any `npx skills add` or skill installation, invoke `/skill-vetter` first and get user approval.
```

Write `MEMORY.md`:

```markdown
- [Skill vetting rule](feedback_skill_vetting.md) — Must run skill-vetter before any skill install/update
```

### Step 7: Verify Everything

Print a summary:

```
=== Claude Code Setup Complete ===
Git user:     <git config user.name>
Git email:    <git config user.email>
GitHub auth:  <gh auth status summary>
Plugins:      <count> installed
Skills:       <count> installed
Memory:       configured at <path>
```

## Notes

- All `settings.json` and `installed_plugins.json` changes are handled automatically by the install commands — this skill never writes those files directly
- If a plugin or skill installation fails, report the error and continue with the remaining items rather than stopping entirely
- The `skipDangerousModePermissionPrompt` setting is configured automatically by the superpowers plugin
