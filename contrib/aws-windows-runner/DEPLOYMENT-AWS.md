# Windows runner deployment — AWS scale-from-zero variant

The alternative to [DEPLOYMENT.md](DEPLOYMENT.md) for sites with AWS and
no standing Windows machine: playing the `bake-windows` job launches one
spot Windows instance, the runner SSHes in, builds, uploads the Conan
package, and the instance terminates. Nothing runs between bakes except
the AMI snapshot.

Note two limitations versus the static-machine setup: job artifacts do
not upload (the Conan registry upload — the actual deliverable — works
fine), and every job waits a few minutes for Windows to boot.

**Prerequisites:** an AWS account with AWS CLI v2 authenticated
(`aws sts get-caller-identity` works); a Linux "runner manager" host
already running gitlab-runner v16+ with reach to both AWS's API and your
GitLab (it orchestrates, never builds); your GitLab root CA `.pem` if the
cert isn't publicly trusted.

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

Takes 30–60 minutes; prints the AMI id (`ami-...`) as its last line, and
saves the key pair's private key to `~/.ssh/gitlab-win64-bake.pem` (needed
in Step 4). See `README.md` for flag details.

## Step 2 — IAM credentials

Create a least-privilege IAM user (or extend one your existing fleets
use). Every action listed is load-bearing — the troubleshooting table
maps each missing one to how it fails.

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

Save the key pair from the output for Step 4. Never commit it.

## Step 3 — security group, launch template, auto-scaling group

Fill in `<vpc-id>`, `<manager-egress-ip>` (run `curl -4 ifconfig.me` **on
the runner-manager host** — do not assume), `<ami-id>` from Step 1, and
`<subnet-id>` (must assign public IPs).

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

## Step 4 — configure the runner manager

Create the runner in the GitLab UI (tag `win-amd64`, untagged jobs off)
and copy its `glrt-` token. On the manager host:

```sh
sudo cp gitlab-win64-bake.pem /etc/gitlab-runner/gitlab-win64-bake.pem
sudo chmod 600 /etc/gitlab-runner/gitlab-win64-bake.pem
```

Append this `[[runners]]` block to `/etc/gitlab-runner/config.toml`. Three
of these lines look optional and are not — the README's "Runner manager
configuration" section explains each:

```toml
[[runners]]
  name = "win64-bake"
  url = "https://<your-gitlab-host>"
  token = "glrt-..."
  executor = "instance"
  shell = "powershell"          # the AMI has Windows PowerShell 5.1 only
  # Only if your GitLab's public DNS is CDN-proxied and instances must reach
  # the origin directly (otherwise delete this line):
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

The runner should now show **online** in GitLab.

## Step 5 — variables and first run

Same as [DEPLOYMENT.md](DEPLOYMENT.md) Steps 4–5: set
`BAKE_WINDOWS_RUNNER_TAG` = `win-amd64` on the template project, then play
the manual **bake-windows** job. Expected timeline:

| Elapsed | Trace shows |
|---|---|
| 0:00 | `Preparing the "instance" executor` → `Dialing instance i-...` |
| 2–4 min | `Instance i-... connected` (Windows boot + sshd) |
| +30 s | clone, schemas staged, `bake-windows.ps1` starts |
| +3 min | `BUILD SUCCESS`, conan export, `Upload completed` |
| 8–9 min | **Job succeeded**; ASG back to 0 within minutes |

The trailing `Missing gitlab-runner. Uploading artifacts is disabled.` is
expected (see the limitations note at the top).

## Troubleshooting — symptom → cause → fix

Every row is a failure mode observed on a real deployment, in the order
you'd hit them.

| Symptom | Cause | Fix |
|---|---|---|
| Instances launch and terminate 8 s later, forever; job stuck at `Preparing the "instance" executor` | Runner's IAM identity lacks `ec2:GetPasswordData` / `ec2:CreateTags`; the plugin treats the denial as fatal | Use the full Step-2 policy |
| Instances live 10 min (the connector timeout), never connect; repeat | Plugin polls `GetPasswordData` for a Windows password that never exists (AMIs captured without sysprep have none) | `use_static_credentials = true` + restart |
| Same 10-min hang, but manual `ssh -i <pem> Administrator@<ip>` works fine | Fleeting defaults Windows instances to WinRM (5985); the SG only allows 22, so the dial is silently dropped | `protocol = "ssh"` + restart |
| Config change had no effect | Autoscaler config is only read at service start | `sudo systemctl restart gitlab-runner` |
| Job connects, clone fails `CERT_TRUST_IS_UNTRUSTED_ROOT` | Instance resolved your GitLab via public DNS to a CDN edge whose cert it doesn't trust | `pre_get_sources_script` hosts pin (Step 4) |
| Clone fails `CERT_TRUST_IS_PARTIAL_CHAIN` even though the AMI's cert store trusts the origin | gitlab-runner injects its own CA file and forces git to trust only it (`schannelUseSSLCAInfo`); that file doesn't match the path the instance uses | `GIT_SSL_NO_VERIFY=true` project variable (or make the runner's CA file carry the full chain for the instance's path) |
| `bake-windows.ps1` dies with parser errors / `NativeCommandError` / missing conan profile | Library ref older than `v1.0.0` at `eeeb485` — three Windows PowerShell 5.1 fixes live there | Update the mirror's `v1.0.0` tag |
| `ERROR: new instances are not protected from scale in and should be` in the manager's journal | ASG missing scale-in protection | `--new-instances-protected-from-scale-in` (Step 3) + `autoscaling:SetInstanceProtection` in IAM |
| Job ran on the wrong runner under `/bin/sh` | `BAKE_WINDOWS_RUNNER_TAG` wasn't set when the pipeline was created | Set the variable, then trigger a new pipeline (retrying old jobs keeps the old tag resolution) |

**When the job trace says nothing:** it only shows a generic 15-minute
acquire timeout. The real error is in the manager's journal:
`sudo journalctl -u gitlab-runner | grep -iE 'fleeting|dial|instance'`.
For IAM denials, CloudTrail (`lookup-events`) shows the exact denied call.

## Teardown

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
