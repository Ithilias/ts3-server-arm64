# Maintaining

Notes for whoever releases and updates this image. Users only need the
[README](README.md).

## Building

```sh
docker build -t ts3-server-arm64 .                                   # on arm64
docker buildx build --platform linux/arm64 -t ts3-server-arm64 .     # elsewhere, needs arm64 emulation (binfmt/QEMU)
```

No build stage runs x86 code, so a native arm64 build needs no emulation.

## CI and releases

[`build.yml`](.github/workflows/build.yml) builds every pull request, `v*` tag,
weekly schedule and manual run. Each build starts the image and must reach
`healthy` before anything is pushed. Pull requests are never pushed.

To release, merge to `master` and push a tag:

```sh
git tag v1.2.3 && git push origin v1.2.3
```

| Trigger | Builds | Publishes |
|---|---|---|
| Final tag `vX.Y.Z` | that tag | `:vX.Y.Z`, `:latest` |
| Pre-release tag `vX.Y.Z-rc1` | that tag | `:vX.Y.Z-rc1` only |
| Weekly (Mon 06:17 UTC) | latest final tag, no layer cache | `:latest`, `:YYYYMMDD` |
| Manual run | latest final tag, no layer cache | `:latest` |

The weekly rebuild picks up Debian security fixes (`apt-get upgrade`) while
TeamSpeak and box64 stay pinned. It never touches `:vX.Y.Z` tags, so those stay
immutable for rollbacks. Merging alone never publishes; only a tag does.

Every final tag moves `:latest`, including a hotfix tag on an older release
line, until the next Monday rebuild moves it back to the newest release.

## TeamSpeak updates

[`update-teamspeak.yml`](.github/workflows/update-teamspeak.yml) checks
`teamspeak.com/versions/server.json` every Monday. For a newer version it bumps
`TS_VERSION` / `TS_SHA256` in the Dockerfile, builds and smoke-tests the image,
and opens a PR. Review it, merge, then tag a release.

- The checksum comes from the same feed as the version. It catches corrupt or
  swapped downloads, not a compromised feed.
- If you close an update PR without merging, that version isn't proposed again.
- The bot opens the PR with `GITHUB_TOKEN`, so `build.yml` doesn't run on it.
  The update workflow builds and smoke-tests the image itself, but if branch
  protection requires the `build` check, close and reopen the PR (or push an
  empty commit to its branch) to trigger it.
- One-time setup: *Settings > Actions > General > Workflow permissions >
  "Allow GitHub Actions to create and approve pull requests"*.

To bump by hand, take `.linux.x86_64.version` and `.checksum` from that JSON and
update the two `ARG`s. The build fails if the download doesn't match.

## box64 updates

Change `BOX64_VERSION` and `BOX64_COMMIT` together; the build fails if the tag
doesn't resolve to that commit:

```sh
git ls-remote https://github.com/ptitSeb/box64 refs/tags/v0.4.5
```

box64 releases can regress emulation, so bump deliberately and watch a test
server for crashes. The `STRONGMEM=4` setting the image relies on is labelled
"for evaluation purposes" upstream; see the comments in the
[`Dockerfile`](Dockerfile) for why it is used.

## Housekeeping

- Dependabot keeps the SHA-pinned GitHub Actions current
  ([`.github/dependabot.yml`](.github/dependabot.yml)).
- GitHub disables scheduled workflows in public repos after 60 days without
  repository activity. If the Monday runs stop, re-enable them under *Actions*.
