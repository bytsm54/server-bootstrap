# Domestic Node Mirrors Design

## Goal

Make every normal server-bootstrap run use mainland-China-friendly download sources without requiring per-server environment exports or an interactive registry choice.

## Approaches considered

1. Treat the existing `npm_registry` setting as the download-source profile. This is the smallest compatible change and keeps an explicit `official` recovery path.
2. Add a separate `download_region` option. This models the concern more precisely but adds another prompt and configuration surface that the domestic-only workflow does not need.
3. Hard-code domestic URLs with no override. This is simplest at runtime but leaves no recovery path if a mirror is unavailable.

Approach 1 is selected. The user explicitly requested domestic defaults and no normal-flow choice.

## Behavior

- `china` becomes the default in `scripts/03-node.sh`, `scripts/server-init.sh`, `scripts/bootstrap.sh`, and the skill documentation.
- Interactive `server-init.sh` no longer asks which npm registry to use. An explicit `--npm-registry official` remains accepted for compatibility and emergency fallback.
- Before installing nvm or Node, `scripts/03-node.sh` maps the `china` profile to:
  - nvm installer: `https://gitee.com/mirrors/nvm/raw/<tag>/install.sh`
  - nvm repository source: `https://gitee.com/mirrors/nvm.git`
  - Node binary mirror: `https://npmmirror.com/mirrors/node`
  - npm registry: `https://registry.npmmirror.com`
- Existing environment values for the nvm installer URL, nvm source, and Node binary mirror take precedence so operators can recover from a mirror outage without editing the script.
- The explicit `official` profile continues to use the upstream GitHub installer, upstream nvm source behavior, Node's default distribution host, and the official npm registry.

## Error handling

The existing `curl -fsSL` and post-install `nvm.sh` existence checks remain authoritative. The change does not add automatic cross-region fallback because silently executing a second remote installer would make failures harder to diagnose and expand the trust boundary.

## Testing

- Add a shell test that runs `scripts/03-node.sh` in an isolated fake home and proves the default path uses all three domestic sources.
- Add coverage proving environment overrides are preserved.
- Update server-init routing expectations to the new `china` default and verify the interactive prompt is absent.
- Run all shell tests, `bash -n` over scripts/tests, and `git diff --check`.
