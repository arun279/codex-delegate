# Releasing

## One-time owner setup

Create a granular npm token with read/write access, permission to publish the new `codex-delegate` package, and bypass 2FA enabled. Save it as the `NPM_TOKEN` repository secret.

## Release procedure

On `main`, manually dispatch the `release` workflow and provide the version to publish. The input must match the versions in `package.json` and `.claude-plugin/plugin.json`; the workflow derives the plugin tag from that version.

Before creating a tag, GitHub release, or npm publication, the job independently verifies:

- completed, successful push CI for the exact release commit;
- agreement among the requested version, package version, plugin version, and release tag;
- whether that exact package version already exists in the npm registry, so rerunning a release skips publication safely; and
- whether an existing plugin tag points at the exact release commit, with the same check repeated after creating a missing tag.

After those checks, the workflow creates or reuses the plugin tag and GitHub release, then publishes to npm only when that version is absent.
