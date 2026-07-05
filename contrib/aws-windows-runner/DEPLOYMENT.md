# Windows runner deployment

Set up a Windows GitLab runner that builds Windows baked variants of
libexificient: playing the template's manual `bake-windows` job produces a
Windows Conan package in your project's package registry.

This guide covers the recommended setup — gitlab-runner installed
directly on a Windows machine you already have (VM or physical). If you
would rather have AWS create a Windows instance on demand per bake and
keep no standing machine, use [DEPLOYMENT-AWS.md](DEPLOYMENT-AWS.md)
instead; everything from Step 4 on is the same for both.

**Machine requirements:** Windows Server 2019/2022 or Windows 10/11
x86_64, admin access, 30 GB free disk, network reach to your GitLab.

## Step 1 — toolchain

Install as admin (versions pinned to match the Linux builder, so
native-image behavior is consistent across OSes):

| Tool | Version / notes |
|---|---|
| GraalVM Community JDK | **21.0.2** (`graalvm-community-jdk-21.0.2_windows-x64_bin.zip`); set `JAVA_HOME`, put `%JAVA_HOME%\bin` on `PATH` |
| Apache Maven | 3.9.x, `bin` on `PATH` |
| git | MinGit or Git for Windows, 64-bit, on `PATH` |
| Python 3.12 + Conan | full installer (the embeddable zip has no pip), then `pip install "conan>=2"` |
| Visual Studio Build Tools | `Microsoft.VisualStudio.Workload.VCTools` workload — check your organization's Visual Studio licensing first |

`ami-userdata.ps1` in this directory scripts this same table (sections
2–7) if you prefer to crib commands. Air-gapped sites: the kit's
`--windows` component ships the GraalVM and Maven zips plus a pre-warmed
Maven repository; `bake-windows.ps1 -M2Repo <path>` then builds fully
offline (MSVC remains a site-provided prerequisite).

Verify in a fresh PowerShell — all four must succeed:

```powershell
java -version        # must say GraalVM
mvn -version
git --version
conan --version
```

## Step 2 — TLS trust (internal-CA sites only)

```powershell
Import-Certificate -FilePath C:\path\to\your-root-ca.pem -CertStoreLocation Cert:\LocalMachine\Root
```

If your GitLab's public DNS is CDN-proxied and this box must reach the
origin directly, pin it once:

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "<origin-ip> <your-gitlab-host>"
```

## Step 3 — install and register gitlab-runner

Create the runner in the GitLab UI (**Admin Area → CI/CD → Runners → New
instance runner**, or a group runner): tag `win-amd64`, untick "Run
untagged jobs". Copy the `glrt-` token, then on the Windows box as admin:

```powershell
New-Item -ItemType Directory -Force -Path C:\gitlab-runner | Out-Null
Invoke-WebRequest -Uri "https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-windows-amd64.exe" -OutFile C:\gitlab-runner\gitlab-runner.exe
cd C:\gitlab-runner
.\gitlab-runner.exe register --non-interactive `
    --url "https://<your-gitlab-host>" `
    --token "glrt-..." `
    --executor "shell" `
    --shell "powershell"
.\gitlab-runner.exe install
.\gitlab-runner.exe start
```

(Air-gapped: carry the exe in on your media instead of the
`Invoke-WebRequest`.) The runner should now show **online** in GitLab.

## Step 4 — project variable

On the `exi-bake-template` project (**Settings → CI/CD → Variables**), set
`BAKE_WINDOWS_RUNNER_TAG` = `win-amd64`. Job tags resolve at pipeline
creation — set the variable before triggering a pipeline.

## Step 5 — run it

Open the project's latest default-branch pipeline and play the manual
**bake-windows** job. The build itself takes a few minutes; on success the
package appears under **Packages → Conan** with a Windows `package_id`,
and consumers install it with
`-o "exificient/*:baked_schema=<your-schema-id>"` per the template docs.

## Troubleshooting

- **Clone fails `CERT_TRUST_IS_UNTRUSTED_ROOT` / `CERT_TRUST_IS_PARTIAL_CHAIN`:**
  the box is hitting a certificate it doesn't trust — recheck Step 2. If
  it persists because gitlab-runner injects its own CA file
  (`CI_SERVER_TLS_CA_FILE` forces git to trust only that file), set the
  project variable `GIT_SSL_NO_VERIFY` = `true` as a stopgap.
- **`bake-windows.ps1` fails with parser errors or `NativeCommandError`:**
  the library ref is older than `v1.0.0` at `eeeb485` — three Windows
  PowerShell 5.1 fixes live there. Update the mirror's `v1.0.0` tag.
- **Job ran on the wrong runner under `/bin/sh`:**
  `BAKE_WINDOWS_RUNNER_TAG` wasn't set when the pipeline was created.
  Set it, then trigger a new pipeline (retrying old jobs keeps the old
  tag resolution).
