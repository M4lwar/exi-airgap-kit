# DEPLOY.md — receiving-side runbook

You are holding a self-contained transfer kit for the **exificient bake
ecosystem**: the `exificient-native-image` library (schema-neutral EXI codec
as a GraalVM native shared library) and the `exi-bake-template` project
(bakes schema-specific variants and publishes Conan packages). This document
is the complete procedure for deploying the kit into an air-gapped GitLab
instance. It assumes nothing beyond what is in this directory and what is
listed under Prerequisites.

Kit contents (verify against `SHA256SUMS` — see step 0):

| File | What it is |
|---|---|
| `exi-lib.bundle` | git bundle of the library repo (all refs; the pinned release tag is in `kit-manifest.txt`) |
| `exi-template.bundle` | git bundle of the bake-template repo |
| `builder-x86_64.tar` | container image (`podman`/`docker save`) with the full build toolchain, x86_64 |
| `builder-arm64.tar` | same, arm64 (present if the kit was built for both arches) |
| `windows/` | optional Windows toolchain (GraalVM JDK, Maven, warmed `.m2`) — see the last section |
| `deploy-kit.sh` | the automated deployer (this runbook, as a script) |
| `kit-manifest.txt` | exact refs, commit SHAs, image digests, build date |
| `SHA256SUMS` | sha256 of every file in the kit |

---

## 1. Prerequisites

On the machine you run `deploy-kit.sh` from (must reach the target GitLab
over HTTPS, and its container registry if enabled):

- `sh`/`bash`, `git`, `curl`, `python3` (any recent version; used only for
  JSON/URL handling)
- `podman` or `docker` (only needed to seed the builder images; skippable
  with `--skip-images`)
- A GitLab **personal access token** with `api` and `write_repository`
  scope, for a user allowed to create groups/projects (or with access to the
  pre-created target group). Export it as `GITLAB_TOKEN` (or any name, via
  `--token-env`).

On the target GitLab:

- GitLab **16.x or newer** (self-managed). The script uses only v4 REST API
  endpoints that exist in 16.0+ (`/groups`, `/projects`, `/variables`,
  `/job_token_scope/allowlist`, `/pipeline`).
- The **container registry** enabled, instance- and project-level
  (preferred; if it is disabled at your site, use the registry-disabled
  fallback below — the deployment still works).
- **CI runners** registered and tagged. Sizing per runner:

| Runner | Executor | Min resources | Tag |
|---|---|---|---|
| amd64 build runner | docker (Linux x86_64) | 4 vCPU, 8 GB RAM, 30 GB disk | whatever you pass as `--runner-tag-amd64` |
| arm64 build runner | docker (Linux aarch64) | 4 vCPU, 8 GB RAM, 30 GB disk | whatever you pass as `--runner-tag-arm64` |
| bake runner | docker (Linux x86_64) | 4 vCPU, 8 GB RAM, 30 GB disk | whatever you pass as `--bake-runner-tag` (may be the same runner/tag as amd64) |

  GraalVM native-image is memory-hungry; below 8 GB the build jobs get
  OOM-killed. The runner tags are arbitrary — the pipelines select runners
  via CI/CD variables that this script sets, so the tags just have to match
  what you pass on the command line.

---

## 2. Quick path (the whole deployment, one command)

From inside this kit directory:

```sh
export GITLAB_TOKEN=glpat-...
./deploy-kit.sh \
  --gitlab https://gitlab.internal \
  --group tools/exi \
  --runner-tag-amd64 amd64-docker \
  --runner-tag-arm64 arm64-docker \
  --bake-runner-tag amd64-docker \
  --trigger
```

Add `--insecure` if the GitLab instance uses a self-signed certificate that
your machine does not trust (see the TLS section for the better alternative).
Add `--skip-images` if the container registry is disabled (then follow the
registry-disabled fallback below).

The script is **idempotent** — rerunning it is safe. Existing groups,
projects, and variables are reused/updated, mirror pushes converge, and
image pushes overwrite the same tags.

All flags:

| Flag | Default | Meaning |
|---|---|---|
| `--gitlab URL` | *(required)* | Base URL of the target GitLab |
| `--group PATH` | *(required)* | Group (or `parent/sub` subgroup) to deploy into; created if missing |
| `--token-env NAME` | `GITLAB_TOKEN` | Name of the env var holding the access token |
| `--registry PREFIX\|auto` | `auto` | Registry path prefix for the builder images; `auto` derives it from the library project |
| `--runner-tag-amd64 T` | *(unset)* | Sets `RUNNER_TAG_AMD64` on the library project |
| `--runner-tag-arm64 T` | *(unset)* | Sets `RUNNER_TAG_ARM64` on the library project |
| `--bake-runner-tag T` | *(unset)* | Sets `BAKE_RUNNER_TAG` on the template project |
| `--engine auto\|podman\|docker` | `auto` | Container engine for load/push |
| `--skip-images` | off | Skip loading/pushing builder images (registry-disabled fallback) |
| `--trigger` | off | Run both projects' pipelines after deploying and poll to completion |
| `--insecure` | off | Disable TLS verification everywhere (curl `-k`, git `http.sslVerify=false`, podman `--tls-verify=false`) |

---

## 3. What the script does, step by step

1. **Verify kit integrity** — checks every file against `SHA256SUMS`
   (`sha256sum -c`, falling back to `shasum -a 256 -c` on systems without
   coreutils) and runs `git bundle verify` on both bundles. Aborts on any
   mismatch.
2. **Resolve or create the group** — `GET /groups/:path`; if absent, creates
   it (`POST /groups`), creating a subgroup under the parent when `--group`
   contains a `/`. The parent of a subgroup must already exist.
3. **Create the two projects** — `POST /projects` for
   `exificient-native-image` and `exi-bake-template` under the group
   (tolerates "already exists"), then resolves their numeric IDs. Projects
   are created **via the API first**, so this works even on instances where
   push-to-create is disabled.
4. **Mirror-push both bundles** — `git clone --mirror` from each bundle into
   a temp dir, then `git push --mirror` over HTTPS (token auth as `oauth2`).
   All branches and tags land in the new projects.
5. **Seed the builder images** (unless `--skip-images`) — resolves the
   registry prefix (from the library project's
   `container_registry_image_prefix`, or `--registry`), logs in with the
   token, then for each `builder-<arch>.tar`: `load` → `tag` →
   `push` as `<prefix>/builder:1.0.0-<arch>`.
6. **Set 8 CI/CD variables** —
   on the **library** project: `RUNNER_TAG_AMD64`, `RUNNER_TAG_ARM64`,
   `BUILDER_IMAGE_AMD64`, `BUILDER_IMAGE_ARM64`;
   on the **template** project: `BAKE_RUNNER_TAG`, `BAKE_BUILDER_IMAGE`
   (the amd64 image), `LIBRARY_REPO_URL` (the internal library mirror URL),
   `LIBRARY_REF` (the pinned release tag). Variables with empty values are
   skipped, so you can rerun with only the flags you want to (re)set.
7. **Job-token allowlist** — allows the template project's CI jobs to fetch
   from the library project (`POST /projects/:lib/job_token_scope/allowlist`).
8. **Hygiene** — sets `auto_devops_enabled=false` on both projects so GitLab
   does not inject an Auto-DevOps pipeline next to the real ones.
9. **With `--trigger`** — starts both default-branch pipelines and polls
   every 20 s (up to 30 min each). Exits non-zero if either fails.

---

## 4. Manual runbook (for sites that must review every action)

Everything the script does, as individual commands you can run and inspect
one at a time. Set these once:

```sh
export GITLAB=https://gitlab.internal   # no trailing slash
export GROUP=tools/exi
export GITLAB_TOKEN=glpat-...
api() { curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$@"; }
```

**4.0 Verify the kit** (also do this at media review):

```sh
sha256sum -c SHA256SUMS          # or: shasum -a 256 -c SHA256SUMS
git bundle verify exi-lib.bundle
git bundle verify exi-template.bundle
cat kit-manifest.txt             # confirm the refs/digests are what you expect
```

**4.1 Create the group** (skip if it exists):

```sh
api -X POST "$GITLAB/api/v4/groups" -d "name=exi" -d "path=exi" -d "parent_id=<PARENT_ID>"
# top-level group instead: omit parent_id and use the full name/path
```

**4.2 Create the projects** (note the returned `id` of each):

```sh
api -X POST "$GITLAB/api/v4/projects" \
  -d "name=exificient-native-image" -d "path=exificient-native-image" \
  -d "namespace_id=<GROUP_ID>" -d "visibility=private"
api -X POST "$GITLAB/api/v4/projects" \
  -d "name=exi-bake-template" -d "path=exi-bake-template" \
  -d "namespace_id=<GROUP_ID>" -d "visibility=private"
```

**4.3 Mirror-push the bundles:**

```sh
git clone --mirror exi-lib.bundle /tmp/lib
git -C /tmp/lib push --mirror "https://oauth2:$GITLAB_TOKEN@gitlab.internal/$GROUP/exificient-native-image.git"
git clone --mirror exi-template.bundle /tmp/tmpl
git -C /tmp/tmpl push --mirror "https://oauth2:$GITLAB_TOKEN@gitlab.internal/$GROUP/exi-bake-template.git"
rm -rf /tmp/lib /tmp/tmpl
```

**4.4 Seed the builder images** (registry-enabled path):

```sh
podman login -u oauth2 -p "$GITLAB_TOKEN" registry.gitlab.internal
for A in x86_64 arm64; do
  LOADED=$(podman load -i builder-$A.tar | sed 's/^Loaded image[^:]*: //')
  podman tag "$LOADED" "registry.gitlab.internal/$GROUP/exificient-native-image/builder:1.0.0-$A"
  podman push "registry.gitlab.internal/$GROUP/exificient-native-image/builder:1.0.0-$A"
done
```

**4.5 Set the CI/CD variables** (`<LIB_ID>`/`<TMPL_ID>` from 4.2; for an
existing variable use `PUT .../variables/<KEY> -d "value=..."` instead):

```sh
V() { api -X POST "$GITLAB/api/v4/projects/$1/variables" -d "key=$2" -d "value=$3"; }
V <LIB_ID>  RUNNER_TAG_AMD64    amd64-docker
V <LIB_ID>  RUNNER_TAG_ARM64    arm64-docker
V <LIB_ID>  BUILDER_IMAGE_AMD64 registry.gitlab.internal/$GROUP/exificient-native-image/builder:1.0.0-x86_64
V <LIB_ID>  BUILDER_IMAGE_ARM64 registry.gitlab.internal/$GROUP/exificient-native-image/builder:1.0.0-arm64
V <TMPL_ID> BAKE_RUNNER_TAG     amd64-docker
V <TMPL_ID> BAKE_BUILDER_IMAGE  registry.gitlab.internal/$GROUP/exificient-native-image/builder:1.0.0-x86_64
V <TMPL_ID> LIBRARY_REPO_URL    "$GITLAB/$GROUP/exificient-native-image.git"
V <TMPL_ID> LIBRARY_REF         v1.0.0
```

**4.6 Job-token allowlist + Auto-DevOps off:**

```sh
api -X POST "$GITLAB/api/v4/projects/<LIB_ID>/job_token_scope/allowlist" -d "target_project_id=<TMPL_ID>"
api -X PUT "$GITLAB/api/v4/projects/<LIB_ID>"  -d "auto_devops_enabled=false"
api -X PUT "$GITLAB/api/v4/projects/<TMPL_ID>" -d "auto_devops_enabled=false"
```

**4.7 Run the pipelines:**

```sh
api -X POST "$GITLAB/api/v4/projects/<LIB_ID>/pipeline"  -d "ref=master"
api -X POST "$GITLAB/api/v4/projects/<TMPL_ID>/pipeline" -d "ref=main"
# watch in the UI, or poll: api "$GITLAB/api/v4/projects/<ID>/pipelines/<PID>"
```

---

## 5. Fallbacks

### 5.1 Container registry disabled

If the instance (or the target project) has no container registry, the
pipelines cannot pull the builder image from GitLab — but every runner host
can hold it locally instead:

1. Deploy with `--skip-images`:

   ```sh
   ./deploy-kit.sh --gitlab ... --group ... --skip-images ...
   ```

2. Copy `builder-x86_64.tar` to every **amd64** runner host and
   `builder-arm64.tar` to every **arm64** runner host, and load it there
   under a stable local tag:

   ```sh
   # on each amd64 runner host:
   podman load -i builder-x86_64.tar
   podman tag ghcr.io/m4lwar/exificient-builder:1.0.0-x86_64 localhost/exi-builder:1.0.0-x86_64
   # on each arm64 runner host:
   podman load -i builder-arm64.tar
   podman tag ghcr.io/m4lwar/exificient-builder:1.0.0-arm64 localhost/exi-builder:1.0.0-arm64
   ```

   (`podman load` restores the tag the image was saved with; the `podman tag`
   gives it a registry-independent local name. `docker load`/`docker tag`
   work identically for docker-executor runners.)

3. Tell each runner **not** to try pulling that image from a registry — in
   the runner's `config.toml`, in the `[runners.docker]` section:

   ```toml
   [runners.docker]
     pull_policy = "if-not-present"
   ```

   then restart the runner (`gitlab-runner restart`). Without this, the
   default `always` pull policy makes every job fail trying to pull the
   local-only tag.

4. Point the CI variables at the local tag (values must match what you
   tagged in step 2):

   ```sh
   V <LIB_ID>  BUILDER_IMAGE_AMD64 localhost/exi-builder:1.0.0-x86_64
   V <LIB_ID>  BUILDER_IMAGE_ARM64 localhost/exi-builder:1.0.0-arm64
   V <TMPL_ID> BAKE_BUILDER_IMAGE  localhost/exi-builder:1.0.0-x86_64
   ```

   (with `--skip-images`, `deploy-kit.sh` deliberately leaves the three
   `*_IMAGE_*` variables unset — it does not know your local tags — so this
   manual step is always required on this path. Use the `V` helper from
   §4.5, or the project's Settings → CI/CD → Variables UI.)

When new kit versions arrive, repeat step 2 on the runner hosts — with
`if-not-present`, a **changed** tag (e.g. `:1.1.0-x86_64`) is picked up
automatically; a **reused** tag requires removing the old local image first.

### 5.2 Push-to-create disabled

Handled by design — no action needed. The script creates both projects via
the API (`POST /projects`) **before** any `git push`, so it never relies on
GitLab's push-to-create behavior. The manual runbook has the same ordering
(4.2 before 4.3).

### 5.3 Self-signed / private-CA TLS

**Preferred: install the root CA** so everything verifies normally — no
flags needed, and runners/consumers work too:

```sh
# on the deploy machine and every runner host (RHEL/Fedora):
sudo cp your-root-ca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust
# Debian/Ubuntu:
sudo cp your-root-ca.crt /usr/local/share/ca-certificates/your-root-ca.crt && sudo update-ca-certificates
```

For docker-executor runners, also make the CA available inside jobs if your
jobs call the GitLab API/registry over TLS (usually mounting
`/etc/ssl/certs` read-only via `volumes` in `config.toml`, or baking the CA
into the runner helper config — see your site's runner baseline).

**Fallback: `--insecure`.** This disables TLS *verification* (encryption
remains) in all three channels the script uses:

- `curl -k` on every API call,
- `git -c http.sslVerify=false` on the mirror pushes,
- `podman ... --tls-verify=false` on registry login/push (podman only —
  docker has no per-command flag; for docker, add the registry to
  `insecure-registries` in `/etc/docker/daemon.json` and restart dockerd).

`--insecure` covers the deploy step only. Runners pulling from the registry
also need trust: either the root CA (above, preferred) or the registry
listed as insecure in each runner host's
`/etc/containers/registries.conf` (podman) / `daemon.json` (docker).

---

## 6. Verification checklist

After a deploy (with `--trigger`, or after manually running the pipelines):

- [ ] **Both pipelines green** — library project (`master`) and template
      project (`main`) latest pipelines show `passed` in the UI, or:

  ```sh
  api "$GITLAB/api/v4/projects/<LIB_ID>/pipelines?per_page=1"   # "status":"success"
  api "$GITLAB/api/v4/projects/<TMPL_ID>/pipelines?per_page=1"  # "status":"success"
  ```

- [ ] **Packages published** — the projects' Conan package registries list
      the artifacts:

  ```sh
  api "$GITLAB/api/v4/projects/<LIB_ID>/packages"
  # expect a conan package "exificient/1.0.0" (per-arch, from the library pipeline)
  api "$GITLAB/api/v4/projects/<TMPL_ID>/packages"
  # expect the baked schema-variant conan package(s) from the template pipeline
  ```

- [ ] **A consumer can install** — from any machine that reaches GitLab:

  ```sh
  conan remote add exi-internal "$GITLAB/api/v4/projects/<LIB_ID>/packages/conan"
  conan remote login exi-internal <username> -p "$GITLAB_TOKEN"
  conan install --requires=exificient/1.0.0 -r exi-internal
  ```

  (append `--insecure` to `conan remote add` if you deployed against
  untrusted TLS and have not installed the root CA on the consumer.)

---

## 7. Windows kit (only if `windows/` is present)

The kit's `windows/` directory carries the offline toolchain for baking
schema variants **on a Windows x86_64 host** (Windows native-image builds
cannot run in the Linux builder containers):

| File | Purpose |
|---|---|
| `graalvm-community-jdk-<ver>_windows-x64_bin.zip` | GraalVM JDK 21 (the exact version the Linux builders use) |
| `apache-maven-<ver>-bin.zip` | Maven |
| `m2-repo.tar` | pre-warmed Maven local repository — makes the build fully offline |

**Site prerequisite (NOT in the kit):** Visual Studio Build Tools with the
MSVC C/C++ workload and a Windows SDK must be preinstalled — GraalVM
native-image's toolchain discovery requires it and it cannot be vendored.

Setup on the Windows build host:

```powershell
Expand-Archive windows\graalvm-community-jdk-*_windows-x64_bin.zip -DestinationPath C:\graalvm
Expand-Archive windows\apache-maven-*-bin.zip -DestinationPath C:\maven
tar -xf windows\m2-repo.tar -C C:\kit          # yields C:\kit\m2
$env:JAVA_HOME = "C:\graalvm\<extracted-dir>"  # the graalvm-community-openjdk-21.* folder
$env:Path = "$env:JAVA_HOME\bin;C:\maven\<extracted-dir>\bin;$env:Path"
```

Then clone the library from the internal mirror and bake, fully offline,
pointing `-M2Repo` at the warmed repository:

```powershell
git clone https://gitlab.internal/tools/exi/exificient-native-image.git
cd exificient-native-image
git checkout v1.0.0
pwsh .\bake-windows.ps1 -Schema schemas\My.xsd -Id my-1.0 -Version 1.0.0 `
    -Out out -M2Repo C:\kit\m2
```

The produced artifacts (DLL, import library, headers, optional Conan export)
land in `-Out`; upload the Conan package to the internal registry the same
way the Linux pipelines do, or distribute the tarballs directly.
