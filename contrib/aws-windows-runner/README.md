# aws-windows-runner

Bakes a Windows Server 2022 AMI with the full toolchain needed to build this
project's Windows artifacts (GraalVM native-image + Conan packaging) as a
GitLab **instance executor** runner host (no containers — the runner SSHes
in and drives PowerShell directly, same model as GitHub's `windows-latest`
hosted runners).

This directory is generic/parameterized and safe to publish: no site
hostnames, no tokens, no baked-in secrets. The one site-specific input (a TLS
trust anchor to add to the machine's certificate store, e.g. an internal CA
or a reverse-proxy origin cert) is injected at bake time via `--pem-file` —
it is never hardcoded into the scripts.

## What it builds

`build-ami.sh` launches a temporary "builder" EC2 Windows instance, waits
for `ami-userdata.ps1` (delivered as EC2 user-data, run once at first boot)
to install:

- OpenSSH Server, keyed to the instance's launch key pair, PowerShell set as
  the default SSH shell
- git (MinGit)
- GraalVM Community JDK 21 (pinned to `21.0.2` — matches this project's
  Linux builder image so native-image behavior is consistent across OSes)
- Apache Maven 3.9.9
- Python 3.12 (the full installer, not the embeddable zip — embeddable
  Python does not ship `pip`) + Conan 2.x via `pip install conan>=2`
- Visual Studio Build Tools, `Microsoft.VisualStudio.Workload.VCTools`
  workload (the slowest step, 15-30 minutes)
- the caller-supplied PEM into `Cert:\LocalMachine\Root`

...into `C:\tools`, sets `JAVA_HOME` and `PATH` machine-wide, and finally
writes `C:\ami-ready.txt` as a sentinel. `build-ami.sh` polls for that
sentinel over SSH, runs toolchain version checks, then stops the instance,
calls `create-image`, waits for the AMI to become `available`, and
terminates the builder instance.

## Usage

```sh
export AWS_BIN=~/aws-cli/aws   # or just `aws` if it's on PATH already
./build-ami.sh \
  --key-name gitlab-win64-bake \
  --ami-name gitlab-win64-bake-ami-v1 \
  --pem-file /path/to/your-trust-anchor-root.pem
```

| Flag | Default | Notes |
|---|---|---|
| `--key-name` | *(required)* | EC2 key pair name; created if it doesn't exist yet. The private key is saved to `~/.ssh/<key-name>.pem` (chmod 600) and **never committed**. Reused on rerun. |
| `--ami-name` | *(required)* | AMI name to produce. |
| `--pem-file` | *(required)* | PEM certificate to import into `Cert:\LocalMachine\Root` on the bake host (e.g. so Conan/git can verify TLS against an internal CA without `--insecure`). |
| `--instance-type` | `m5.xlarge` | Builder instance type. On-demand — the AMI bake is a one-off, not worth spot interruption risk. |
| `--base-ami` | latest `Windows_Server-2022-English-Full-Base` | Resolved via the `/aws/service/ami-windows-latest/...` SSM public parameter if not given. |
| `--ready-timeout-minutes` | `70` | Overall budget from instance launch to the provisioner's ready sentinel (VS Build Tools install alone runs 15-30 min). |
| `--poll-interval-seconds` | `75` | SSH probe interval while waiting for the provisioner. |

Requires: AWS CLI v2 authenticated against the target account/region, `ssh`,
`perl`, `python3`, `curl` on the machine running the script.

**Idempotent / resumable.** Every phase checks existing AWS state (by Name
tag, AMI name, key pair) before creating anything, so the script is safe to
re-run. A single invocation does not block for the entire ~45-60 minute
bake — it polls in bounded windows internally and exits `2` ("still in
progress, rerun me") if the AMI isn't ready yet by the time its window
elapses, `0` with the AMI id on stdout once done, or `1` on a hard failure.
Loop it yourself if you want one command to just block until done:

```sh
until ./build-ami.sh --key-name gitlab-win64-bake --ami-name gitlab-win64-bake-ami-v1 --pem-file ./trust-anchor.pem; do
  status=$?; [ "$status" = 2 ] || exit "$status"; sleep 60
done
```

## Runner manager configuration (the part that actually bites)

The AMI is consumed by a GitLab runner-manager host running the
**instance executor** with `fleeting-plugin-aws` against an
auto-scaling group whose launch template uses this AMI. The connector
defaults are wrong for a Windows fleet in three separate ways — each one
fails as a silent hang, not an error. A known-good `[[runners]]` shape:

```toml
[[runners]]
  name = "win64-bake"
  url = "https://gitlab.example.internal"
  token = "glrt-..."
  executor = "instance"
  shell = "powershell"          # the AMI has Windows PowerShell 5.1 only, no pwsh
  # If your GitLab's public DNS is CDN-proxied (e.g. Cloudflare orange-cloud)
  # and the runner must reach the origin directly, pin it before the first
  # git operation of every job -- fresh instances have no such route:
  pre_get_sources_script = 'Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "<origin-ip> gitlab.example.internal"'
  [runners.autoscaler]
    plugin = "aws:latest"
    capacity_per_instance = 1
    max_instances = 1
    max_use_count = 1
    [runners.autoscaler.plugin_config]
      name = "<asg-name>"
      region = "<region>"
    [runners.autoscaler.connector_config]
      username = "Administrator"
      key_path = "/etc/gitlab-runner/<key-name>.pem"
      use_static_credentials = true   # REQUIRED: without it the plugin polls
                                      # ec2:GetPasswordData forever -- an AMI
                                      # captured without sysprep never has
                                      # password data, so it never resolves
      protocol = "ssh"                # REQUIRED: fleeting defaults Windows
                                      # instances to WinRM (5985); if your SG
                                      # only allows 22, the dial hangs silently
      use_external_addr = true
      timeout = "10m0s"
    [[runners.autoscaler.policy]]
      idle_count = 0
      idle_time = "5m0s"
```

Further field notes:

- **Changes under `[runners.autoscaler]` require a service restart** —
  gitlab-runner's config hot-reload does not reinitialize an
  already-running fleeting plugin.
- The IAM identity the manager uses needs `ec2:GetPasswordData` and
  `ec2:CreateTags` in addition to the usual autoscaling actions — missing
  permissions surface as instances being killed ~8 s after launch in an
  endless churn loop.
- If the runner manager reaches GitLab through a different network path
  than the Windows instances do (e.g. edge vs pinned origin), the CA file
  the runner injects into jobs (`CI_SERVER_TLS_CA_FILE` +
  `http.schannelUseSSLCAInfo`) will not match what the job's git sees and
  every clone fails `CERT_TRUST_IS_PARTIAL_CHAIN` — even when the AMI's
  certificate store trusts the origin. Either make that CA file carry the
  full chain for the path the *instances* use, or set the project variable
  `GIT_SSL_NO_VERIFY=true` as a stopgap.
- Job **artifacts** upload is disabled on these instances ("Missing
  gitlab-runner"): the instance executor needs a gitlab-runner helper
  binary on the host for artifact/cache support. Registry uploads (conan)
  are unaffected. Add the binary to `ami-userdata.ps1` if artifacts
  matter to you.

## What gets created in AWS (and cleaned up)

- A temporary security group (`<key-name>-builder-sg`, tag
  `Name=gitlab-win64-bake-builder`) allowing inbound TCP/22 **only** from
  the calling machine's current public IP (via `checkip.amazonaws.com`) —
  deleted after the AMI is built.
- A one-off builder EC2 instance (same `Name` tag) — stopped, imaged, then
  **terminated**. It never becomes long-lived infrastructure.
- The EC2 key pair (kept — meant to be reused by whatever consumes the
  resulting AMI, e.g. a launch template).
- The AMI (and its backing EBS snapshot) — this is the actual deliverable.

## Costs

Rough order of magnitude (US regions, on-demand `m5.xlarge`, prices vary by
region/time): builder instance ~$0.19/hr x ~1 hour wall clock = **~$0.20 for
the one-off bake**, plus **~$1.50/month** ongoing for the AMI's 60 GB gp3
EBS snapshot while it exists. No standing compute is created — the builder
instance is terminated once the AMI is available.

## Licensing note (read before you bake)

`vs_buildtools.exe` installs Visual Studio Build Tools with the
`Microsoft.VisualStudio.Workload.VCTools` workload. **Visual Studio Build
Tools requires appropriate Visual Studio licensing for your organization**
(see Microsoft's Visual Studio licensing terms — Build Tools' free-use terms
differ depending on organization size, whether use is for open-source
contributions, etc.). This is a compliance decision for whoever runs this
script against their own AWS account and organization — evaluate it before
baking and distributing the resulting AMI internally.

## Security notes

- The PEM you pass via `--pem-file` is embedded into a rendered copy of the
  user-data template (never written back into the checked-in
  `ami-userdata.ps1`) and is only as secure as EC2 user-data normally is
  (readable via instance metadata by anything running on the builder
  instance while it's up — the builder is terminated immediately after
  use).
- The temporary security group is scoped to your current public IP only,
  and torn down after the bake.
- No GitLab/registry tokens or other site secrets are used or required by
  this directory at all — it produces a generic toolchain AMI.
