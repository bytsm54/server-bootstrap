---
name: server-init
description: Initialize a new Linux server — set hostname, timezone, install Node.js, configure zsh as default shell with git integration and path display. Use this skill when the user asks to initialize, set up, or bootstrap a new server, or mentions setting hostname, installing Node.js, or configuring zsh on a fresh machine.
---

# Server Init

Initialize a new Linux (Ubuntu/Debian) server with hostname, timezone, Node.js runtime, and a clean zsh configuration.

## Parameters

Ask the user for these if not provided:

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `hostname` | yes | — | Server hostname |
| `timezone` | no | `Asia/Shanghai` | System timezone |
| `node_version` | no | `lts` | Node.js version to install via NodeSource |
| `username` | no | `ubuntu` | Primary user (for zsh config and default shell) |

## Execution

Follow these steps in order. Verify each step before proceeding to the next.

### Step 1: Set Hostname

Check if the hostname contains underscores or other RFC 1123 non-compliant characters:

**If hostname is RFC-compliant** (letters, digits, hyphens only):
```bash
sudo hostnamectl set-hostname <hostname>
```

**If hostname contains underscores** (e.g., `openclaw_travel`):
Both `hostnamectl` and `hostname` commands enforce RFC 1123 and will reject underscores. Write directly to the files and apply immediately:
```bash
# Write to file
echo "<hostname>" | sudo tee /etc/hostname

# Apply immediately in current session (use the kernel interface, bypasses RFC validation)
sudo sh -c 'echo "<hostname>" > /proc/sys/kernel/hostname'
```

Then update `/etc/hosts` — replace the old hostname with the new one on the `127.0.1.1` line. Preserve all other entries.

Verify: `cat /proc/sys/kernel/hostname` should show the new hostname immediately.

If any step fails, report the error and stop. Do not proceed to the next step.

### Step 2: Set Timezone and Locale

```bash
sudo timedatectl set-timezone <timezone>
```

Ensure both `en_US.UTF-8` and `zh_CN.UTF-8` locales are available:

```bash
sudo locale-gen en_US.UTF-8 zh_CN.UTF-8
sudo update-locale LANG=en_US.UTF-8
```

Verify: `timedatectl` shows correct timezone, `locale -a` includes both locales.

### Step 3: Install Node.js via nvm

Use nvm (Node Version Manager) to install Node.js in user space — no sudo needed, no permission issues with `npm install -g`.

1. **Install nvm:**
   ```bash
   curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
   ```

2. **Load nvm into current shell:**
   ```bash
   export NVM_DIR="$HOME/.nvm"
   [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
   ```

3. **Install Node.js:**

   For LTS (default):
   ```bash
   nvm install --lts
   ```

   For a specific version (e.g., `22`):
   ```bash
   nvm install 22
   ```

4. **Set as default:**
   ```bash
   nvm alias default node
   ```

Verify all three:
```bash
node --version
npm --version
npx --version
```

nvm installs everything under `~/.nvm/` — global packages (`npm install -g`) go to `~/.nvm/versions/node/<version>/lib/node_modules/`, never touching `/usr/local/`.

### Step 3.1: Configure npm Registry

Some cloud providers (e.g. Tencent Cloud) ship with `~/.npmrc` pointing to an internal mirror that may be missing native binary packages (like tree-sitter). This causes silent failures when plugins try to install dependencies.

Check and fix:

```bash
if [ -f ~/.npmrc ] && grep -q 'mirrors.tencentyun.com\|mirrors.cloud.aliyuncs.com' ~/.npmrc; then
  echo "⚠️  Found cloud-internal npm mirror in ~/.npmrc — replacing with official registry"
  sed -i 's|registry=.*|registry=https://registry.npmjs.org|' ~/.npmrc
elif [ -f ~/.npmrc ] && grep -q 'registry=' ~/.npmrc; then
  echo "ℹ️  Custom npm registry found: $(grep 'registry=' ~/.npmrc)"
  echo "    If plugin installs fail later, try: npm config set registry https://registry.npmjs.org"
else
  echo "ℹ️  No custom npm registry configured, using default (npmjs.org)"
fi
```

This prevents downstream failures in claude-mem and other plugins that install native npm packages via their SessionStart hooks.

### Step 4: Configure Zsh

Install zsh:

```bash
sudo apt-get install -y zsh
```

Change default shell for the user:

```bash
sudo chsh -s $(which zsh) <username>
```

If the user already has a `~/.zshrc`, back it up to `~/.zshrc.bak` before overwriting.

Write the **exact** content from `templates/zshrc` in this repo to `~/.zshrc`. Read the file at `$REPO_DIR/templates/zshrc` (where `$REPO_DIR` is the path the repo was cloned to — defaults to `~/server-bootstrap` but may differ) and write it verbatim. Do NOT paraphrase, summarize, or rewrite — copy it exactly.

After writing, install optional zsh plugins if available:
```bash
sudo apt-get install -y zsh-syntax-highlighting zsh-autosuggestions 2>/dev/null || true
```

Verify: `grep $(which zsh) /etc/passwd` shows zsh as the user's shell.

### Step 5: Verify Everything

Print a summary:

```
=== Server Init Complete ===
Hostname:  <result of hostname>
Timezone:  <result of timedatectl show -p Timezone --value>
Node.js:   <node --version>
npm:       <npm --version>
Shell:     <echo $SHELL or grep from /etc/passwd>

⚠️  Default shell changed to zsh. Run `zsh -l` or reconnect SSH to activate.
    Do NOT run `source ~/.zshrc` in bash — it will fail because .zshrc uses zsh-only syntax.
```

## Scope

This skill does NOT:
- Install apt packages beyond zsh and nodejs (install what you need manually)
- Configure SSH (use the `ssh-hardening` skill)
- Install Claude Code (do this manually)
- Configure firewalls or swap
