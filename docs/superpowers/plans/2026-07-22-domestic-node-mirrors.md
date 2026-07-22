# Domestic Node Mirrors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make domestic nvm, Node binary, and npm sources the automatic defaults for every normal server-bootstrap run.

**Architecture:** Keep the existing `npm_registry` compatibility surface and treat it as a source profile. The `china` profile becomes the non-interactive default and resolves mirror environment variables before nvm or Node downloads begin; explicit upstream settings remain a recovery path.

**Tech Stack:** Bash, fake-command shell tests, Git.

## Global Constraints

- Do not introduce a new interactive option.
- Preserve explicit `--npm-registry official` compatibility.
- Preserve caller-provided `NVM_INSTALLER_URL`, `NVM_SOURCE`, and `NVM_NODEJS_ORG_MIRROR` values.
- Do not add automatic remote-installer fallback.

---

### Task 1: Domestic Node download defaults

**Files:**
- Create: `tests/node-domestic-mirrors.sh`
- Modify: `scripts/03-node.sh`
- Modify: `scripts/server-init.sh`
- Modify: `scripts/bootstrap.sh`
- Modify: `tests/server-init.sh`
- Modify: `README.md`
- Modify: `SKILL.md`

**Interfaces:**
- Consumes: existing `--npm-registry official|china`, `NVM_INSTALLER_TAG`, and inherited environment variables.
- Produces: default domestic source routing through `NVM_INSTALLER_URL`, `NVM_SOURCE`, and `NVM_NODEJS_ORG_MIRROR`.

- [ ] **Step 1: Write the failing mirror-routing test**

Create an isolated fake home and fake `curl`, `node`, `npm`, and `npx`. Make the fake nvm installer record its URL and `NVM_SOURCE`, and make fake `nvm install` record `NVM_NODEJS_ORG_MIRROR`. Invoke `scripts/03-node.sh --install-bun no` without `--npm-registry`, then assert:

```text
https://gitee.com/mirrors/nvm/raw/v0.40.3/install.sh
https://gitee.com/mirrors/nvm.git
https://npmmirror.com/mirrors/node
https://registry.npmmirror.com
```

Run:

```bash
bash tests/node-domestic-mirrors.sh
```

Expected: FAIL because `scripts/03-node.sh` still defaults to `official` and downloads the nvm installer from GitHub.

- [ ] **Step 2: Implement minimal source-profile routing**

In `scripts/03-node.sh`, default `NPM_REGISTRY` to `china`, validate the profile before any download, and resolve sources without replacing caller overrides:

```bash
case "$NPM_REGISTRY" in
  china)
    NVM_INSTALLER_URL="${NVM_INSTALLER_URL:-https://gitee.com/mirrors/nvm/raw/$NVM_INSTALLER_TAG/install.sh}"
    export NVM_SOURCE="${NVM_SOURCE:-https://gitee.com/mirrors/nvm.git}"
    export NVM_NODEJS_ORG_MIRROR="${NVM_NODEJS_ORG_MIRROR:-https://npmmirror.com/mirrors/node}"
    ;;
  official|"")
    NVM_INSTALLER_URL="${NVM_INSTALLER_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_INSTALLER_TAG/install.sh}"
    ;;
  *)
    err "--npm-registry 必须是 official 或 china（你给了 $NPM_REGISTRY）"
    exit 2
    ;;
esac
```

Use `curl -fsSL "$NVM_INSTALLER_URL" | bash` for nvm installation. Keep npm registry configuration after Node is available.

- [ ] **Step 3: Verify the mirror test passes and add override coverage**

Run `bash tests/node-domestic-mirrors.sh` and expect PASS. Then extend the test with caller-provided mirror values and verify the script records those exact values instead of the defaults. Re-run and expect PASS.

- [ ] **Step 4: Route all entry points to the domestic default**

Change `scripts/bootstrap.sh` and `scripts/server-init.sh` defaults from `official` to `china`. Remove the interactive npm-registry prompt from `scripts/server-init.sh` while retaining the CLI argument. Update `tests/server-init.sh` so the no-argument execution expects:

```text
03-node.sh --node-version lts --npm-registry china --install-bun no
```

Add an assertion that interactive output does not contain `npm registry (official/china)`.

- [ ] **Step 5: Update user-facing documentation**

Change README and SKILL examples/default tables to show `china` as the default. Document that the domestic profile covers the nvm installer, Node binaries, and npm packages, while `official` is an explicit recovery override.

- [ ] **Step 6: Run targeted and full verification**

Run:

```bash
bash tests/node-domestic-mirrors.sh
bash tests/server-init.sh
for test_file in tests/*.sh; do bash "$test_file"; done
bash -n scripts/*.sh scripts/lib/*.sh tests/*.sh
git diff --check
```

Expected: all shell tests pass, syntax validation exits zero, and `git diff --check` prints no errors.

- [ ] **Step 7: Commit and push**

Review `git diff`, stage only the implementation/test/docs files, then commit:

```bash
git commit -m "perf: default Node installation to domestic mirrors"
git push origin main
```
