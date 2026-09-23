# Contributing

Thank you for your interest in RIFF.zig. Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Issues, pull requests, and documentation are written in English.

For a larger change, please open an issue first, so that it can be discussed before you spend time on it.

## Development

### Environment

This project uses [Nix](https://nixos.org/) for the development environment.

```bash
nix develop
zig build test
```

You can also install Zig yourself and work without Nix. Note that `treefmt`, the tool that checks and fixes the formatting, is provided only by the Nix environment (`nix develop`). Without Nix it is not available: format the Zig files you changed with `zig fmt`, and the CI will check the formatting of all files (it runs `nix flake check --all-systems`, which includes a formatting check).

### Zig version

This project uses Zig `0.16.0` (`minimum_zig_version` in `build.zig.zon`).

### Git LFS

Some test files are stored with [Git LFS](https://git-lfs.com/): `*.sf2` and `*.bin` (see `.gitattributes`). The tests embed these files at compile time and compare against them, so after you clone the repository, run:

```bash
git lfs pull
```

Without the real files, the tests do not pass.

`.lfsconfig` points Git LFS to a public, read-only endpoint. The credentials in its URL are public on purpose, and they only allow reading. Because the endpoint is read-only, you cannot upload new LFS files to it yourself. If a change needs a new or a different test file, please open an issue and ask the maintainer. For a new kind of binary file, a matching `filter=lfs diff=lfs merge=lfs -text` line is also needed in `.gitattributes` before the file is added.

## Checks before you submit

Run these commands and make sure they pass:

| Command | When |
| --- | --- |
| `treefmt --fail-on-change` | Always, inside `nix develop` (it is not available without Nix; see "Environment"). It checks the formatting of Zig, Nix, GitHub Actions, and Markdown files. Run `treefmt` to fix the formatting. |
| `zig build` | Always. |
| `zig build test` | Always. |
| `zig build docs` | When you change the public API or a doc comment. |
| `nix flake check --all-systems` | When you change `flake.nix` or `flake.lock`. |

32-bit targets are not a main target of this library, but it is meant to work there too, on a best-effort basis. You do not have to check it for every change. If you want to, this command checks that the tests build for a 32-bit target:

```bash
zig test src/root.zig -target x86-linux --test-no-exec
```

Without `--test-no-exec`, the tests are also run, if your machine can run 32-bit programs.

The CI runs `zig build test` on Linux, macOS, and Windows for every push and pull request.

## Commits and pull requests

- **One issue, one pull request.** Keep a pull request small and about one thing.
- **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, or `build:`, optionally with a scope, for example `fix(read): reject a zero-sized chunk`. Write a short summary (under 72 characters) in the imperative mood, without a period at the end.
- **Breaking changes** are marked with `!` after the type or the scope, for example `refactor(write)!: remove the unused allocator parameter`.
- **Do not write an issue number** in the summary line of a commit or in the title of a pull request. Link the issue in the description of the pull request with `Closes #123`.
- **The description of a pull request** should have these parts:
  - Summary: what changes, and why.
  - The issue it closes (`Closes #123`).
  - Verification: the commands you ran (see "Checks before you submit") and their result.
  - Breaking Changes: what breaks and how to migrate, or "None".
- **A bug fix needs a regression test** that fails without the fix.
- **Update the documentation** when you change the behavior, and keep the doc comments correct.

## AI-assisted contributions

AI tools are welcome, but you are responsible for the change. Read what the tool wrote, run the checks, and make sure that the description matches the code. The rules for AI agents that work in this repository are in [`AGENTS.md`](AGENTS.md): for example, an agent never merges into `main` by itself.

## Versioning and compatibility

This project follows [Semantic Versioning](https://semver.org/). The public API, including the `riff.stream` module, is covered by it.

| Change | Release |
| --- | --- |
| Removing or changing a public declaration, changing a function signature or a type, or changing behavior that callers rely on | major |
| Raising `minimum_zig_version` in `build.zig.zon` (the library then no longer works with earlier Zig releases) | major |
| Adding a public declaration, a function, or a field with a default | minor |
| Adding a member to an error set (`ReadError`, `WriteError`, `FormatError`, `FourCC.NewError` and the error sets of `riff.stream`) | minor |
| Fixing a bug without changing the documented behavior | patch |

Adding a member to an error set breaks a `switch` over it that has no `else` prong. This is why the documentation tells callers to keep an `else` prong, and why it is not counted as a breaking change.

The `version` in `build.zig.zon` is the single source of truth for the version. Zig accepts only a full version (`2.0.0`, `2.0.0-rc.1`), without a `v` prefix.

## Releasing

A release is made by merging a change of `version` in `build.zig.zon` to `main`. A workflow (`.github/workflows/release.yml`) does the rest.

### Before releasing

- The CI is green on the latest commit of `main`.
- Every change that should be in the release is merged, and the open issues are checked.
- The breaking changes are listed (pull requests marked with `!`, and the "Breaking Changes" parts of merged pull requests), and the migration guide is drafted (see "Migration guide").
- For a major release, a release candidate was tried first, for example with a downstream project (see "Release candidates").

### Steps

1. Choose the version following the table in "Versioning and compatibility". Use a pre-release version for a release candidate, for example `2.0.0-rc.1` (then `2.0.0-rc.2`, and so on).
1. Open a pull request that only changes `version` in `build.zig.zon` (title `build: bump version to X.Y.Z`) and merge it. See "Commits and pull requests" for the conventions.
1. The workflow reads the version and checks that it is valid. If a tag with that name already exists, it stops. Otherwise it runs `zig build test` and `zig build`, creates the tag on the merged commit, and creates the GitHub Release with the generated "What's Changed" notes. A version that contains `-` is created as a pre-release.
1. Check the workflow run in the Actions tab, and check the new release.

### Migration guide

For a release with breaking changes, add a section with the breaking changes and the migration steps to the release body. An AI assistant drafts the migration guide and the maintainer reviews it before it is published. It is not stored in the repository. The workflow writes only the generated notes, so add the guide afterwards by editing the release. These commands keep the generated notes:

```bash
version=2.0.0-rc.1
gh release view "$version" --json body --jq .body > generated.md
# write the reviewed migration guide to migration.md, then:
{ cat migration.md; echo; cat generated.md; } > body.md
gh release edit "$version" --notes-file body.md
```

### Release candidates

A release candidate is a pre-release, so GitHub keeps marking the last final release as the latest one. Try the candidate (for example in a downstream project) before you release the final version. If the candidate needs fixes, release `2.0.0-rc.2`. The final release is a separate version bump to `2.0.0`.

### Undoing a release

If a release was created by mistake, delete it together with its tag, then fix the problem and merge a new change:

```bash
gh release delete "$version" --cleanup-tag --yes
```

Do not reuse a version whose contents may already have been fetched by others: publish the next version instead.

### If the workflow fails

Open the failed run in the Actions tab and read the error.

- The version is not valid: fix `version` in a new pull request.
- The tests failed: fix the problem on `main` first.
- The tag or the release could not be created: check the workflow permissions in the repository settings (Settings, Actions, General) and the rules that protect branches and tags, because they can stop a workflow from creating a tag.

After fixing the cause, run the workflow again from the Actions tab on `main` ("Run workflow"). It does nothing if the version is already released.
