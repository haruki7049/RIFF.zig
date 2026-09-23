# CONTRIBUTING.md

## Development

This project uses [Nix](https://nixos.org/) for the development environment.

```bash
nix develop
zig build test
```

Also, you can use any package manager to installing Ziglang.

### Git LFS

I use Git LFS, so you should use Git LFS to use big size files as SoundFont2.

### Zig version

I use `Zig 0.16.0` for this project.

## Versioning and compatibility

This project follows [Semantic Versioning](https://semver.org/). The public API, including the `riff.stream` module, is covered by it.

| Change | Release |
| --- | --- |
| Removing or changing a public declaration, changing a function signature or a type, or changing behavior that callers rely on | major |
| Raising `minimum_zig_version` in `build.zig.zon` (the library then no longer works with earlier Zig releases) | major |
| Adding a public declaration, a function, or a field with a default | minor |
| Adding a member to an error set (`ReadError`, `WriteError`, `FormatError`, `FourCC.NewError` and the error sets of `riff.stream`) | minor |
| Fixing a bug without changing the documented behavior | patch |

Adding a member to an error set breaks a `switch` over it that has no `else` prong, which is why the documentation tells callers to keep one, and why it is not counted as a breaking change.

The `version` in `build.zig.zon` is the single source of truth for the version. Zig accepts only a full version (`2.0.0`, `2.0.0-rc.1`), without a `v` prefix.

## Releasing

A release is made by merging a change of `version` in `build.zig.zon` to `main`; a workflow (`.github/workflows/release.yml`) does the rest.

1. Choose the version following the table above. Use a pre-release version for a release candidate, for example `2.0.0-rc.1` (then `2.0.0-rc.2`, and so on).
1. Open a pull request that only changes `version` in `build.zig.zon` (title `build: bump version to X.Y.Z`, see [`AGENTS.md`](AGENTS.md) for the commit and pull request conventions) and merge it.
1. The workflow reads the version, checks that it is a valid version, and stops if a tag with that name already exists. Otherwise it runs `zig build test` and `zig build`, creates the tag on the merged commit, and creates the GitHub Release with the auto-generated "What's Changed" notes. A version containing `-` is created as a pre-release.
1. Check the workflow run in the Actions tab and the new release.

### Migration guide

For a release with breaking changes, add a section describing them and the migration steps to the release body. The migration guide is drafted by an AI assistant and reviewed by the maintainer before it is published; it is not stored in the repository. The workflow only writes the generated notes, so add the guide afterwards by editing the release and keeping the generated notes:

```bash
version=2.0.0-rc.1
gh release view "$version" --json body --jq .body > generated.md
# write the reviewed migration guide to migration.md, then:
{ cat migration.md; echo; cat generated.md; } > body.md
gh release edit "$version" --notes-file body.md
```

### Release candidates

A release candidate is a pre-release, so GitHub keeps marking the last final release as the latest. Try the candidate (for example in a downstream project) before releasing the final version, and release `2.0.0-rc.2` if it needs fixes. The final release is a separate version bump to `2.0.0`.

### Undoing a release

If a release was created by mistake, delete it together with its tag, then fix the problem and merge a new change:

```bash
gh release delete "$version" --cleanup-tag --yes
```

Do not reuse a version whose contents may already have been fetched by others: publish the next version instead. If the workflow run failed before the release was created, run it again from the Actions tab on `main` ("Run workflow"); it does nothing if the version is already released.
