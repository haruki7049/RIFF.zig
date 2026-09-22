# Update Workflow: Nix Inputs, Zig Version, and Test Fixtures

`RIFF.zig` has no external Zig package dependencies (`dependencies = {}` in `build.zig.zon`), so there is no `zon2nix`/`.deps.nix` step here. The following areas still require a coordinated update.

## Nix inputs (`flake.lock`)

1. Run `nix flake update`.
1. Run `nix fmt -- --fail-on-change`, `zig build`, and `zig build test` (inside `nix develop` or via direnv).
1. Commit with `build(flake.lock): nix flake update`.

## Zig version bumps

When changing the Zig version, update all of the following together:

- `minimum_zig_version` in `build.zig.zon`
- `pkgs.zig_0_XX` / `pkgs.zls_0_XX` in `flake.nix`
- The version noted in `CONTRIBUTING.md`
- The `version:` value in `.github/workflows/ci.yml` and `.github/workflows/deploy-api-docs.yml` (`mlugg/setup-zig`)

## Adding or updating Git LFS test fixtures

`src/assets/riff-files/` and `src/assets/chunk-data/` hold sample RIFF files and expected chunk-data used by tests. `*.sf2` and `*.bin` are Git LFS-tracked via `.gitattributes`.

1. If adding a new large binary fixture type, add a matching `filter=lfs diff=lfs merge=lfs -text` line to `.gitattributes` before adding the file.
1. Run `git lfs pull` to ensure existing LFS pointers are resolved locally before running tests that depend on fixtures.
1. Adding, removing, or replacing LFS-tracked assets is an irreversible-adjacent operation (see `.agents/skills/irreversible/SKILL.md`) — confirm with the user before committing large or replaced binary fixtures.
1. Run `zig build test` to confirm the new fixture is read/parsed as expected.
