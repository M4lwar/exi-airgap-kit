# Windows bake runner — end-to-end deployment guide

Step-by-step instructions for standing up a **scale-from-zero Windows
GitLab runner on AWS** that builds Windows baked variants of libexificient
on demand. Written so someone who has never touched fleeting/instance
executors can follow it; every command is copy-paste with `<placeholders>`
to fill in.

**What you end up with:** playing a manual `bake-windows` CI job causes AWS
to launch one spot Windows instance, the runner SSHes in, builds the
native library (~2 min build), uploads a Conan package to your GitLab
project's package registry, and the instance terminates. Idle cost is the
AMI snapshot only (~$1.50/month); each bake costs a few cents of spot time.

**Time budget:** ~2 hours, most of it waiting for the AMI bake.

**Choose your path first:**

- **Path A — AWS scale-from-zero fleet** (this page, Steps 1–7): no
  standing Windows machine; an instance exists only while a bake runs.
  Worth the setup when you have AWS and bake rarely.
- **Path B — a static Windows machine you already have** (VM or physical,
  no AWS): see [the appendix at the bottom](#path-b--static-windows-machine-no-aws).
  Dramatically simpler — no IAM, no ASG, no SSH connector, and job
  artifacts work too. If you have any always-on Windows box to spare,
  start there.

Both paths end at the same place: a runner tagged `win-amd64` that the
template's manual `bake-windows` job routes to, producing a Windows Conan
package in your project registry. Steps 6–7 (project variables, running
the job) are identical for both.

---

## Prerequisites

- An AWS account + AWS CLI v2 authenticated against it (`aws sts get-caller-identity` works), region chosen.
- A GitLab instance with the `exi-bake-template` and `exificient-native-image` repos mirrored (see the main kit docs), and permission to create runners and project CI/CD variables.
- A Linux "runner manager" host that already runs `gitlab-runner` (v16+) and can reach both AWS's API and your GitLab. This host never runs builds itself — it only orchestrates.
- The TLS trust anchor for your GitLab if it uses an internal/private CA (a root-CA `.pem`). Skip if your GitLab has a publicly trusted certificate.

## Step 1 — bake the AMI

From this directory, on any machine with AWS CLI + ssh:

```sh
until ./build-ami.sh \
    --key-name gitlab-win64-bake \
    --ami-name gitlab-win64-bake-ami-v1 \
    --pem-file /path/to/your-root-ca.pem; do
  status=$?; [ "$status" = 2 ] || exit "$status"; sleep 60
done
```

Takes 30–60 min; prints the AMI id (`ami-...`) as its last line. It also
creates the EC2 key pair and saves the private key to
`~/.ssh/gitlab-win64-bake.pem` — you need that file on the runner-manager
host in Step 5. See `README.md` in this directory for flag details.

## Step 2 — IAM credentials for the runner manager

Create a least-privilege IAM user (or reuse one your existing runner
fleets use) with this policy. **Every action listed is load-bearing** —
the table at the bottom tells you exactly how each missing one fails.

```sh
cat > /tmp/win-runner-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "FleetingWindowsRunner",
    "Effect": "Allow",
    "Action": [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:SetInstanceProtection",
      "ec2:DescribeInstances",
      "ec2:GetPasswordData",
      "ec2:CreateTags"
    ],
    "Resource": "*"
  }]
}
EOF
aws iam create-user --user-name gitlab-win64-runner
aws iam put-user-policy --user-name gitlab-win64-runner \
    --policy-name fleeting-windows --policy-document file:///tmp/win-runner-policy.json
aws iam create-access-key --user-name gitlab-win64-runner
```

Save the `AccessKeyId`/`SecretAccessKey` output — it goes into the runner
config in Step 5. Never commit it anywhere.

## Step 3 — security group, launch template, auto-scaling group

Fill in: `<vpc-id>`, `<manager-egress-ip>` (the public IP the runner
manager's outbound traffic uses: run `curl -4 ifconfig.me` **on that
host** — do not assume), `<ami-id>` from Step 1, `<subnet-id>` (must be a
subnet that assigns public IPs).

```sh
# Security group: SSH only, only from the runner manager
SG_ID=$(aws ec2 create-security-group --group-name gitlab-win64-bake-sg \
    --description "gitlab windows bake fleet" --vpc-id <vpc-id> \
    --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr <manager-egress-ip>/32

# Launch template: spot instance, the baked AMI, the bake keypair
aws ec2 create-launch-template --launch-template-name gitlab-win64-bake \
    --launch-template-data "{
      \"ImageId\": \"<ami-id>\",
      \"InstanceType\": \"c5.2xlarge\",
      \"KeyName\": \"gitlab-win64-bake\",
      \"SecurityGroupIds\": [\"$SG_ID\"],
      \"InstanceMarketOptions\": {\"MarketType\": \"spot\"}
    }"

# ASG: scale-from-zero, max 1, scale-in protection ON (the plugin requires it)
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name gitlab-asg-win64-bake \
    --launch-template LaunchTemplateName=gitlab-win64-bake,Version='$Default' \
    --min-size 0 --max-size 1 --desired-capacity 0 \
    --new-instances-protected-from-scale-in \
    --vpc-zone-identifier <subnet-id>
```

## Step 4 — create the runner in GitLab

In the GitLab UI: **Admin Area → CI/CD → Runners → New instance runner**
(or a group runner). Set:

- Tags: `win-amd64`
- Untick "Run untagged jobs"

Copy the `glrt-...` authentication token it shows you.

## Step 5 — configure the runner manager

Copy two files onto the manager host:

```sh
sudo cp gitlab-win64-bake.pem /etc/gitlab-runner/gitlab-win64-bake.pem
sudo chmod 600 /etc/gitlab-runner/gitlab-win64-bake.pem
```

Append this `[[runners]]` block to `/etc/gitlab-runner/config.toml`,
filling in your GitLab URL, the `glrt-` token, region, and the Step-2
keys. Read the comments — three of these lines look optional and are not
(the README's "Runner manager configuration" section explains each):

```toml
[[runners]]
  name = "win64-bake"
  url = "https://<your-gitlab-host>"
  token = "glrt-..."
  executor = "instance"
  shell = "powershell"          # the AMI has Windows PowerShell 5.1 only
  # Only if your GitLab's public DNS is CDN/proxy-fronted and instances must
  # reach the origin directly (otherwise delete this line):
  pre_get_sources_script = 'Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "<origin-ip> <your-gitlab-host>"'
  [runners.autoscaler]
    plugin = "aws:latest"
    capacity_per_instance = 1
    max_instances = 1
    max_use_count = 1
    [runners.autoscaler.plugin_config]
      name = "gitlab-asg-win64-bake"
      region = "<region>"
      access_key_id = "<AccessKeyId from Step 2>"
      secret_access_key = "<SecretAccessKey from Step 2>"
    [runners.autoscaler.connector_config]
      username = "Administrator"
      key_path = "/etc/gitlab-runner/gitlab-win64-bake.pem"
      use_static_credentials = true   # REQUIRED (see troubleshooting)
      protocol = "ssh"                # REQUIRED (see troubleshooting)
      use_external_addr = true
      timeout = "10m0s"
    [[runners.autoscaler.policy]]
      idle_count = 0
      idle_time = "5m0s"
```

Then install the plugin (once) and restart:

```sh
sudo gitlab-runner fleeting install
sudo systemctl restart gitlab-runner
```

**Any later change under `[runners.autoscaler]` needs another restart** —
config hot-reload does not reinitialize a running fleeting plugin.

The runner should now show **online** in the GitLab runners page.

## Step 6 — project variables

On the `exi-bake-template` project (**Settings → CI/CD → Variables**):

| Variable | Value | Why |
|---|---|---|
| `BAKE_WINDOWS_RUNNER_TAG` | `win-amd64` | Routes the `bake-windows` job to this fleet. Job tags resolve at **pipeline creation** — set this *before* triggering a pipeline, or the job runs untagged on whatever grabs it. |
| `GIT_SSL_NO_VERIFY` | `true` | Only if jobs fail with `CERT_TRUST_IS_PARTIAL_CHAIN` (see troubleshooting). Skip on publicly-trusted GitLab certs. |

## Step 7 — run it

Open the project's latest default-branch pipeline, find the manual
**bake-windows** job, press play. Expected timeline:

| ~Time | Trace shows |
|---|---|
| 0:00 | `Preparing the "instance" executor` → `Dialing instance i-...` |
| 2–4 min | `Instance i-... connected` (Windows boot + sshd) |
| +30 s | clone, schemas staged, `bake-windows.ps1` starts |
| +3 min | `BUILD SUCCESS`, conan export, `Upload completed` |
| ~8–9 min | **Job succeeded**; ASG back to 0 within minutes |

The package lands in the project's **Packages → Conan** registry with a
Windows `package_id`. Consumers install it with
`-o "exificient/*:baked_schema=<your-schema-id>"` per the template docs.

One expected wart: `Missing gitlab-runner. Uploading artifacts is
disabled.` at the end. Job *artifacts* (the `bake-out/` files) need a
gitlab-runner helper binary on the AMI; the Conan registry upload — the
actual deliverable — is unaffected.

## Troubleshooting — symptom → cause → fix

Every row below is a failure mode observed on a real deployment, in the
order you'd hit them.

| Symptom | Cause | Fix |
|---|---|---|
| Instances launch and terminate ~8 s later, forever; job stuck at `Preparing the "instance" executor` | Runner's IAM identity lacks `ec2:GetPasswordData` / `ec2:CreateTags`; the plugin treats the denial as fatal | Use the full Step-2 policy |
| Instances live ~10 min (the connector timeout), never connect; repeat | Plugin polls `GetPasswordData` for a Windows password that never exists (AMIs captured without sysprep have none) | `use_static_credentials = true` + restart |
| Same 10-min hang, but manual `ssh -i <pem> Administrator@<ip>` works fine | Fleeting defaults Windows instances to **WinRM (5985)**; the SG only allows 22, so the dial is silently dropped | `protocol = "ssh"` + restart |
| Config change had no effect | Autoscaler config is only read at service start | `sudo systemctl restart gitlab-runner` |
| Job connects, clone fails `CERT_TRUST_IS_UNTRUSTED_ROOT` | Instance resolved your GitLab via public DNS to a CDN edge whose cert it doesn't trust | `pre_get_sources_script` hosts pin (Step 5) so instances hit the origin |
| Clone fails `CERT_TRUST_IS_PARTIAL_CHAIN` even though the AMI's cert store trusts the origin | gitlab-runner injects its own CA file and forces git to trust *only* it (`schannelUseSSLCAInfo`); that file doesn't match the path the instance uses | `GIT_SSL_NO_VERIFY=true` project variable (or make the runner's CA file carry the full chain for the *instance's* path) |
| `bake-windows.ps1` dies with parser errors / `NativeCommandError` on `java -version` / missing conan profile | Library ref older than `v1.0.0 @ eeeb485` — three Windows-PowerShell-5.1 fixes live there | Update the mirror's `v1.0.0` tag (re-mirror) |
| `ERROR: new instances are not protected from scale in and should be` in the manager's journal | ASG missing scale-in protection | `--new-instances-protected-from-scale-in` (Step 3) + `autoscaling:SetInstanceProtection` in IAM |
| Runner picks up the job on the wrong runner under `/bin/sh` | `BAKE_WINDOWS_RUNNER_TAG` wasn't set when the pipeline was created | Set the variable, then trigger a **new** pipeline (retrying jobs from the old one keeps the old tag resolution) |

**Where to look when the job trace says nothing:** the trace only shows a
generic 15-minute acquire timeout. The real error is in the manager's
journal: `sudo journalctl -u gitlab-runner | grep -iE 'fleeting|dial|instance'`.
For IAM denials, CloudTrail (`lookup-events`) shows the exact denied call.

## Cleanup / teardown

```sh
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name gitlab-asg-win64-bake --force-delete
aws ec2 delete-launch-template --launch-template-name gitlab-win64-bake
aws ec2 delete-security-group --group-id <sg-id>
aws ec2 deregister-image --image-id <ami-id>
aws ec2 delete-snapshot --snapshot-id <its-snapshot-id>   # from describe-images BlockDeviceMappings
aws iam delete-access-key --user-name gitlab-win64-runner --access-key-id <key-id>
aws iam delete-user-policy --user-name gitlab-win64-runner --policy-name fleeting-windows
aws iam delete-user --user-name gitlab-win64-runner
```

Plus remove the `[[runners]]` block from the manager's `config.toml`
(restart) and delete the runner in the GitLab UI.

---

## Path B — static Windows machine (no AWS)

Use this when you have an internal Windows box (VM or physical) instead
of AWS. gitlab-runner runs **on the Windows machine itself** as a shell
executor — there is no runner-manager host, no fleeting plugin, no SSH
connector, and none of the failure modes those bring. The AWS-specific
troubleshooting rows above don't apply; the TLS and tag-resolution rows
still do.

**Machine requirements:** Windows Server 2019/2022 or Windows 10/11
x86_64, admin access, ~30 GB free disk, and network reach to your GitLab
(plus the internet OR the air-gap kit for the toolchain).

### B1 — provision the toolchain

Install, as admin (same versions the Linux builder pins, so native-image
behavior matches across OSes):

| Tool | Version / source |
|---|---|
| GraalVM Community JDK | **21.0.2** (`graalvm-community-jdk-21.0.2_windows-x64_bin.zip`) — set `JAVA_HOME` to it and put `%JAVA_HOME%\bin` on `PATH` |
| Apache Maven | 3.9.x — `bin` on `PATH` |
| git | MinGit or Git for Windows, 64-bit, on `PATH` |
| Python 3.12 + Conan | full installer (not the embeddable zip — that has no pip), then `pip install "conan>=2"` |
| Visual Studio Build Tools | `Microsoft.VisualStudio.Workload.VCTools` workload (**check your organization's Visual Studio licensing first** — see the README's licensing note) |

`ami-userdata.ps1` in this directory is the scripted version of this
table (sections 2–7); on a static box you can run those sections by hand
in an admin PowerShell — skip the OpenSSH sections (1, 8–9), which only
exist for the AWS SSH connector.

**Air-gapped?** The kit's `--windows` component ships GraalVM + Maven
zips and a pre-warmed Maven repository; `bake-windows.ps1 -M2Repo <path>`
then builds fully offline. MSVC Build Tools remains a site-provided
prerequisite (its installer is not redistributable in the kit).

Verify before moving on — all four must succeed in a *fresh* PowerShell:

```powershell
java -version        # must say GraalVM
mvn -version
git --version
conan --version
```

### B2 — TLS trust (internal CA sites only)

```powershell
Import-Certificate -FilePath C:\path\to\your-root-ca.pem -CertStoreLocation Cert:\LocalMachine\Root
```

If your GitLab's public DNS is CDN-proxied and this box must reach the
origin directly, pin it once (persistent — this replaces Path A's
`pre_get_sources_script`):

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "<origin-ip> <your-gitlab-host>"
```

### B3 — install and register gitlab-runner

Create the runner in the GitLab UI exactly as in Step 4 above (tag
`win-amd64`, untagged jobs off), then on the Windows box in an admin
PowerShell:

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

(Air-gapped: carry `gitlab-runner-windows-amd64.exe` in on your media
instead of the `Invoke-WebRequest`.)

The runner should show **online** in GitLab. The shell is Windows
PowerShell 5.1 — already accounted for; the library's `v1.0.0` (at
`eeeb485` or later) carries the required 5.1 fixes.

### B4 — run it

Continue at **Step 6** (project variables) and **Step 7** (play the job)
above — identical from here. Two Path-B differences, both pleasant: job
*artifacts* upload works (the runner binary is on the box, so `bake-out/`
attaches to the job), and there is no boot wait — jobs start in seconds.

One operational note: builds run consecutively on one machine
(`concurrent = 1` is the registered default — keep it; native-image is
memory-hungry). Leftover state between jobs is possible with shell
executors; the job checks out fresh and `bake-windows.ps1` stages into
per-job directories, so this is cosmetic for this workload.
