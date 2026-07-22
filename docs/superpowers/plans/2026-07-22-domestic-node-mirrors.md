# Domestic Node Mirrors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make domestic nvm, Node binary, and npm sources the automatic defaults for every normal server-bootstrap run.

**Architecture:** Keep the existing `npm_registry` compatibility surface and treat it as a source profile. The `china` profile becomes the non-interactive default and resolves mirror environment variables before nvm or Node downloads begin; explicit upstream settings remain a recovery path.

**Tech Stack:** Bash, fake-command shell tests, Git.

## Global Constraints

- Do not introduce a new interactive option.
- Preserve explicit `--npm-registry official` compatibility.
- Preserve caller-provided `NVM_SOURCE` and `NVM_NODEJS_ORG_MIRROR` values.
- Clone nvm into a temporary directory and verify the checkout against the peeled upstream tag commit before moving or sourcing it.
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
- Produces: default domestic source routing through `NVM_SOURCE` and `NVM_NODEJS_ORG_MIRROR`.

- [x] **Step 1: Write the failing mirror-routing test**

Create an isolated fake home and fake `git`, `node`, `npm`, and `npx`. Make the fake clone record its source, make fake `nvm install` record `NVM_NODEJS_ORG_MIRROR`, and ensure an unexpected commit cannot execute `nvm.sh`. Invoke `scripts/03-node.sh --install-bun no` without `--npm-registry`, then assert:

```text
https://gitee.com/mirrors/nvm.git
https://npmmirror.com/mirrors/node
https://registry.npmmirror.com
```

Run:

```bash
bash tests/node-domestic-mirrors.sh
```

Expected: FAIL because `scripts/03-node.sh` still defaults to the upstream nvm source.

- [x] **Step 2: Implement minimal source-profile routing**

In `scripts/03-node.sh`, default `NPM_REGISTRY` to `china`, validate the profile before any download, and resolve sources without replacing caller overrides:

```bash
case "$NPM_REGISTRY" in
  china)
    NVM_REPOSITORY_URL="${NVM_SOURCE:-https://gitee.com/mirrors/nvm.git}"
    export NVM_NODEJS_ORG_MIRROR="${NVM_NODEJS_ORG_MIRROR:-https://npmmirror.com/mirrors/node}"
    ;;
  official|"")
    NVM_REPOSITORY_URL="${NVM_SOURCE:-https://github.com/nvm-sh/nvm.git}"
    ;;
  *)
    err "--npm-registry 必须是 official 或 china（你给了 $NPM_REGISTRY）"
    exit 2
    ;;
esac
```

Clone the selected tag into a temporary directory and compare its HEAD with `NVM_EXPECTED_COMMIT` before moving it to `NVM_DIR` or sourcing `nvm.sh`; retain an unverified directory for diagnosis. Keep npm registry configuration after Node is available.

- [x] **Step 3: Verify the mirror test passes and add override coverage**

Run `bash tests/node-domestic-mirrors.sh` and expect PASS. Then extend the test with caller-provided mirror values and verify the script records those exact values instead of the defaults. Re-run and expect PASS.

- [x] **Step 4: Route all entry points to the domestic default**

Change `scripts/bootstrap.sh` and `scripts/server-init.sh` defaults from `official` to `china`. Remove the interactive npm-registry prompt from `scripts/server-init.sh` while retaining the CLI argument. Update `tests/server-init.sh` so the no-argument execution expects:

```text
03-node.sh --node-version lts --npm-registry china --install-bun no
```

Add an assertion that interactive output does not contain `npm registry (official/china)`.

- [x] **Step 5: Update user-facing documentation**

Change README and SKILL examples/default tables to show `china` as the default. Document that the domestic profile covers the nvm repository, Node binaries, and npm packages, while `official` is an explicit recovery override.

- [x] **Step 6: Run targeted and full verification**

Run:

```bash
bash tests/node-domestic-mirrors.sh
bash tests/server-init.sh
for test_file in tests/*.sh; do bash "$test_file"; done
for shell_file in scripts/*.sh scripts/lib/*.sh tests/*.sh; do bash -n "$shell_file"; done
git diff --check
```

Expected: all shell tests pass, syntax validation exits zero, and `git diff --check` prints no errors.

- [x] **Step 7: Commit and push**

Review `git diff`, stage only the implementation/test/docs files, then commit:

```bash
git commit -m "perf: default Node installation to domestic mirrors"
git push origin main
```
