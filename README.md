# exi-airgap-kit

Build self-contained, checksummed transfer kits for deploying the
[EXIficient native-image](https://github.com/M4lwar/exificient-native-image)
bake ecosystem (library + [`exi-bake-template`](https://github.com/M4lwar/exi-bake-template))
into an air-gapped GitLab instance — one that cannot reach GitHub, ghcr.io, or
any other outside registry.

This repo is **connected-side tooling only**. It never travels into the
enclave itself: the receiving-side script and runbook (`deploy-kit.sh`,
`DEPLOY.md`) are copied INTO every kit this tool builds, and that's what
crosses the air gap. This repo stays on the connected side, where it can keep
reaching GitHub/ghcr.io to assemble the next kit.

## The two-command story

On a connected machine, with network access to GitHub and ghcr.io:

```sh
./airgap-kit.sh --out kits/site-a --tar
```

This clones and bundles the library and template repos at pinned refs, pulls
and saves the builder container images, computes checksums, and (optionally)
tars the whole thing up into one file.

Transfer `kits/site-a` (or the tarball) across the air gap by whatever means
your site allows (USB, approved file transfer, physical media review against
`SHA256SUMS`, etc).

Inside the enclave, on a machine that can reach the target GitLab:

```sh
cd site-a   # wherever the kit landed
export GITLAB_TOKEN=...
./deploy-kit.sh --gitlab https://gitlab.internal --group tools/exi \
  --runner-tag-amd64 amd64-docker --runner-tag-arm64 arm64-docker \
  --bake-runner-tag amd64-docker --trigger
```

That's the whole deployment: it verifies the kit's integrity, creates the
GitLab group/projects, mirror-pushes both repos from their bundles, seeds the
builder images into the target registry, sets every CI/CD variable the
pipelines need, configures the job-token allowlist, disables Auto-DevOps, and
(with `--trigger`) runs both pipelines to completion.

See `DEPLOY.md` **inside the kit itself** for the full receiving-side runbook,
manual step-by-step equivalent, and fallbacks (registry disabled, self-signed
TLS, etc). This repo's own copies of `deploy-kit.sh`/`DEPLOY.md` are the
source that gets copied into each kit — they aren't meant to be run from here.

## `airgap-kit.sh` flags

| Flag | Default | Meaning |
|---|---|---|
| `--out DIR` | *(required)* | Directory to assemble the kit into |
| `--library-repo URL` | `https://github.com/M4lwar/exificient-native-image.git` | Library repo to bundle |
| `--library-ref REF` | `v1.0.0` | Tag/branch/commit to bundle from the library repo |
| `--template-repo URL` | `https://github.com/M4lwar/exi-bake-template.git` | Template repo to bundle |
| `--template-ref REF` | `main` | Tag/branch/commit to bundle from the template repo |
| `--arches "x86_64 arm64"` | `x86_64 arm64` | Space-separated builder image architectures to save |
| `--builder-image-base BASE` | `ghcr.io/m4lwar/exificient-builder:1.0.0` | Image reference minus the `-<arch>` suffix |
| `--windows` | off | Also assemble a Windows toolchain kit (GraalVM + Maven + warmed `.m2`) |
| `--engine auto\|podman\|docker` | `auto` | Container engine to pull/save images with |
| `--tar` | off | Also produce a single tarball of the kit directory |

## Kit contents

A built kit directory looks like:

| Path | Contents |
|---|---|
| `exi-lib.bundle` | Verified `git bundle` of the library repo at the pinned ref |
| `exi-template.bundle` | Verified `git bundle` of the template repo at the pinned ref |
| `builder-x86_64.tar` | `podman`/`docker save` of the builder image, x86_64 |
| `builder-arm64.tar` | Same, arm64 (one file per `--arches` entry) |
| `windows/graalvm-community-jdk-<ver>_windows-x64_bin.zip` | Only with `--windows`; version parsed from `Dockerfile.builder` |
| `windows/apache-maven-<ver>-bin.zip` | Only with `--windows` |
| `windows/m2-repo.tar` | Only with `--windows`; warmed `~/.m2` extracted from the builder image (MSVC Build Tools NOT included — site prerequisite) |
| `deploy-kit.sh` | The receiving-side deployer, copied from this repo |
| `DEPLOY.md` | The receiving-side runbook, copied from this repo |
| `kit-manifest.txt` | Refs resolved to commits, image digests, build date, tool versions |
| `SHA256SUMS` | sha256 of every other file in the kit (for media-review / integrity checks) |

## Design

The full design — why this is a separate repo, the receiving-side protocol,
registry/TLS/push-to-create contingencies, and the validation approach — lives
in the library repo:
[`docs/specs/2026-07-04-airgap-kit-design.md`](https://github.com/M4lwar/exificient-native-image/blob/master/docs/specs/2026-07-04-airgap-kit-design.md).

## Validated

This kit and `deploy-kit.sh` have been validated end-to-end against a live
**GitLab CE 19.1** instance (a subgroup used to simulate an air-gapped
target): repo mirroring, builder-image seeding into the target registry,
CI/CD variable configuration, job-token allowlisting, and idempotent reruns
of the whole deploy all completed successfully. One site prerequisite
surfaced during validation and isn't something this tooling can fix for
you: runner fleets must trust the target instance's container registry TLS
certificate, or image pulls in the seeded pipelines fail — see
`DEPLOY.md` §5.3 for the fallback.

## Built kits are never hosted here

This repo ships the *tooling*, not built kits. A kit bundles multi-gigabyte
container images (typically 3–5 GB total) and pins specific refs at build
time, so a hosted kit would immediately start going stale and would exceed
GitHub's release-asset size limits. Build kits on demand, from the refs you
actually intend to deploy, with `airgap-kit.sh`.
