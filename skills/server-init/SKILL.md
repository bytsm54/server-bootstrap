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

```bash
sudo hostnamectl set-hostname <hostname>
```

Then update `/etc/hosts` — replace the old hostname with the new one. Preserve all other entries.

Hostname validation: `hostnamectl` enforces RFC 1123 (no underscores). If the user wants an underscore in the hostname, write directly to `/etc/hostname` and update `/etc/hosts` manually instead of using `hostnamectl`.

Verify: `hostnamectl --static` should show the new hostname.

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

### Step 4: Configure Zsh

Install zsh:

```bash
sudo apt-get install -y zsh
```

Change default shell for the user:

```bash
sudo chsh -s $(which zsh) <username>
```

Write `~/.zshrc` for the target user. The configuration should be lightweight (no oh-my-zsh or other frameworks) and include:

**History:**
```zsh
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
```

**Completion:**
```zsh
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
```

**Git-aware prompt:**
```zsh
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats ' %F{cyan}(%b)%f'
zstyle ':vcs_info:git:*' actionformats ' %F{cyan}(%b|%a)%f'
setopt PROMPT_SUBST
PROMPT='%F{green}%n@%m%f %F{blue}%~%f${vcs_info_msg_0_} %F{yellow}$%f '
```

This prompt shows: `user@host ~/path (branch) $`
- Full working directory path in blue
- Git branch name in cyan (only shown inside a git repo)
- Git action (rebase/merge) shown when in progress

**Path and environment:**
```zsh
export PATH="$HOME/.local/bin:$PATH"
export EDITOR=vim
export LANG=en_US.UTF-8
```

If the user already has a `~/.zshrc`, back it up to `~/.zshrc.bak` before overwriting.

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
```

## Scope

This skill does NOT:
- Install apt packages beyond zsh and nodejs (install what you need manually)
- Configure SSH (use the `ssh-hardening` skill)
- Install Claude Code (do this manually)
- Configure firewalls or swap
