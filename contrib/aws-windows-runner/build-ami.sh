#!/usr/bin/env bash
# build-ami.sh — bakes a Windows Server 2022 AMI carrying the full
# GraalVM/Maven/git/Conan/VS-Build-Tools toolchain, for use as a GitLab
# instance-executor runner image (see ../../README.md and this dir's
# README.md for the bigger picture).
#
# Usage:
#   ./build-ami.sh --key-name gitlab-win64-bake \
#                   --ami-name gitlab-win64-bake-ami-v1 \
#                   --pem-file /path/to/origin-ca-root.pem
#
# Flow: resolve base AMI -> create/reuse a keypair + temporary SG (SSH from
# this machine's public IP only) -> render ami-userdata.ps1 (PEM injected,
# never hardcoded) -> launch a builder instance -> poll over SSH for
# C:\ami-ready.txt -> run toolchain version checks -> stop -> create-image ->
# wait available -> terminate the builder instance. Prints the AMI id on
# stdout as the last line on success.
#
# Idempotent/resumable: every phase first checks AWS for existing state
# (by Name tag / AMI name / key pair) before creating anything, and the
# whole script can simply be re-run to pick up where it left off — this
# also means a single invocation does not need to block for the full
# ~45-60 minute bake; run it in a loop (`until ./build-ami.sh ...; do
# sleep 60; done`) or just let it block if your environment allows it.
#
# Exit codes: 0 = AMI ready (id printed), 2 = still in progress (rerun to
# continue), 1 = hard failure.
set -euo pipefail

AWS_BIN="${AWS_BIN:-aws}"
KEY_NAME="" AMI_NAME="" PEM_FILE=""
INSTANCE_TYPE="m5.xlarge"
BASE_AMI=""
READY_TIMEOUT_MINUTES=70
POLL_INTERVAL_SECONDS=75
ROOT_VOLUME_GB=60
BUILDER_TAG_NAME="gitlab-win64-bake-builder"

usage() { grep '^# ' "$0" | cut -c3-; }

while [ $# -gt 0 ]; do
  case "$1" in
    --key-name) KEY_NAME="$2"; shift 2 ;;
    --ami-name) AMI_NAME="$2"; shift 2 ;;
    --pem-file) PEM_FILE="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --base-ami) BASE_AMI="$2"; shift 2 ;;
    --ready-timeout-minutes) READY_TIMEOUT_MINUTES="$2"; shift 2 ;;
    --poll-interval-seconds) POLL_INTERVAL_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$KEY_NAME" ] && [ -n "$AMI_NAME" ] || { echo "--key-name and --ami-name are required" >&2; exit 2; }
[ -n "$PEM_FILE" ] || { echo "--pem-file is required (the origin CA to trust on the builder/bake host)" >&2; exit 2; }
[ -f "$PEM_FILE" ] || { echo "--pem-file $PEM_FILE not found" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERDATA_TEMPLATE="$SCRIPT_DIR/ami-userdata.ps1"
[ -f "$USERDATA_TEMPLATE" ] || { echo "missing $USERDATA_TEMPLATE" >&2; exit 1; }

log() { echo "==> $*"; }
epoch_of_iso() { python3 -c "import sys,datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$1"; }
now_epoch() { python3 -c "import time; print(int(time.time()))"; }

# ---------------------------------------------------------------------
# Phase 0: already-done check — if the AMI already exists and is
# available, we're done (idempotent re-run).
# ---------------------------------------------------------------------
EXISTING_AMI_ID=$("$AWS_BIN" ec2 describe-images --owners self \
  --filters "Name=name,Values=$AMI_NAME" \
  --query 'Images[0].[ImageId,State]' --output text 2>/dev/null || true)
if [ -n "$EXISTING_AMI_ID" ] && [ "$EXISTING_AMI_ID" != "None" ]; then
  IMAGE_ID=$(echo "$EXISTING_AMI_ID" | awk '{print $1}')
  IMAGE_STATE=$(echo "$EXISTING_AMI_ID" | awk '{print $2}')
  if [ "$IMAGE_STATE" = "available" ]; then
    log "AMI $AMI_NAME already exists and is available: $IMAGE_ID"
    # Best-effort cleanup in case a prior run left the builder instance/SG around.
    LIVE_ID=$("$AWS_BIN" ec2 describe-instances \
      --filters "Name=tag:Name,Values=$BUILDER_TAG_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
    if [ -n "$LIVE_ID" ] && [ "$LIVE_ID" != "None" ]; then
      log "terminating leftover builder instance $LIVE_ID"
      "$AWS_BIN" ec2 terminate-instances --instance-ids "$LIVE_ID" >/dev/null
      "$AWS_BIN" ec2 wait instance-terminated --instance-ids "$LIVE_ID" || true
    fi
    SG_ID=$("$AWS_BIN" ec2 describe-security-groups --filters "Name=group-name,Values=${KEY_NAME}-builder-sg" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
      "$AWS_BIN" ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1 || true
    fi
    echo "$IMAGE_ID"
    exit 0
  else
    log "AMI $AMI_NAME exists but is still $IMAGE_STATE; waiting for it to become available"
    if ! "$AWS_BIN" ec2 wait image-available --image-ids "$IMAGE_ID" 2>/dev/null; then
      log "still not available after this invocation's wait window; rerun to keep polling"
      exit 2
    fi
    log "AMI available: $IMAGE_ID"
    LIVE_ID=$("$AWS_BIN" ec2 describe-instances \
      --filters "Name=tag:Name,Values=$BUILDER_TAG_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
    [ -n "$LIVE_ID" ] && [ "$LIVE_ID" != "None" ] && "$AWS_BIN" ec2 terminate-instances --instance-ids "$LIVE_ID" >/dev/null || true
    echo "$IMAGE_ID"
    exit 0
  fi
fi

# ---------------------------------------------------------------------
# Phase 1: key pair (create once, reuse forever — private key never
# committed, lives only under ~/.ssh)
# ---------------------------------------------------------------------
PEM_LOCAL="$HOME/.ssh/$KEY_NAME.pem"
if "$AWS_BIN" ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  [ -f "$PEM_LOCAL" ] || { echo "key pair $KEY_NAME already exists in AWS but $PEM_LOCAL is missing locally — cannot SSH; supply the matching private key at that path or delete the AWS key pair and rerun" >&2; exit 1; }
  log "reusing existing key pair $KEY_NAME ($PEM_LOCAL)"
else
  log "creating key pair $KEY_NAME -> $PEM_LOCAL"
  mkdir -p "$HOME/.ssh"
  "$AWS_BIN" ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$PEM_LOCAL"
  chmod 600 "$PEM_LOCAL"
fi

# ---------------------------------------------------------------------
# Phase 2: base AMI resolution
# ---------------------------------------------------------------------
if [ -z "$BASE_AMI" ]; then
  BASE_AMI=$("$AWS_BIN" ssm get-parameter \
    --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base \
    --query 'Parameter.Value' --output text)
  log "resolved base AMI: $BASE_AMI"
fi

# ---------------------------------------------------------------------
# Phase 3: security group — temporary, SSH from this machine's public
# egress IP only, default egress (all outbound, the SG default) covers
# the builder's need for 443 egress.
# ---------------------------------------------------------------------
SG_NAME="${KEY_NAME}-builder-sg"
SG_ID=$("$AWS_BIN" ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
  [ -n "$MY_IP" ] || { echo "could not resolve this machine's public IP via checkip.amazonaws.com" >&2; exit 1; }
  VPC_ID=$("$AWS_BIN" ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  log "creating SG $SG_NAME in $VPC_ID (SSH from $MY_IP/32 only)"
  SG_ID=$("$AWS_BIN" ec2 create-security-group --group-name "$SG_NAME" \
    --description "Temporary SG for $BUILDER_TAG_NAME (SSH from operator IP only)" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$BUILDER_TAG_NAME}]" \
    --query 'GroupId' --output text)
  "$AWS_BIN" ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32,Description=operator-ssh}]" >/dev/null
else
  log "reusing existing SG $SG_NAME ($SG_ID)"
fi

# ---------------------------------------------------------------------
# Phase 4: launch (or reuse) the builder instance
# ---------------------------------------------------------------------
INSTANCE_ID=$("$AWS_BIN" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$BUILDER_TAG_NAME" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
  log "reusing existing builder instance $INSTANCE_ID"
else
  USERDATA_RENDERED=$(mktemp)
  trap 'rm -f "$USERDATA_RENDERED"' EXIT
  {
    echo '<powershell>'
    perl -0777 -pe 'BEGIN{ open(F,"<","'"$PEM_FILE"'") or die $!; local $/; $pem=<F>; $pem=~s/\r?\n$//; } s/__CF_ORIGIN_PEM__/$pem/e' "$USERDATA_TEMPLATE"
    echo '</powershell>'
  } > "$USERDATA_RENDERED"

  ROOT_DEVICE=$("$AWS_BIN" ec2 describe-images --image-ids "$BASE_AMI" --query 'Images[0].RootDeviceName' --output text)

  log "launching builder instance ($INSTANCE_TYPE, base AMI $BASE_AMI, ${ROOT_VOLUME_GB}GB gp3 root on $ROOT_DEVICE)"
  INSTANCE_ID=$("$AWS_BIN" ec2 run-instances \
    --image-id "$BASE_AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
    --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEVICE\",\"Ebs\":{\"VolumeSize\":$ROOT_VOLUME_GB,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$BUILDER_TAG_NAME}]" \
    --user-data "file://$USERDATA_RENDERED" \
    --query 'Instances[0].InstanceId' --output text)
  log "instance $INSTANCE_ID launched"
fi

"$AWS_BIN" ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$("$AWS_BIN" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
LAUNCH_TIME=$("$AWS_BIN" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].LaunchTime' --output text)
log "instance running: $INSTANCE_ID @ $PUBLIC_IP (launched $LAUNCH_TIME)"

DEADLINE=$(( $(epoch_of_iso "$LAUNCH_TIME") + READY_TIMEOUT_MINUTES * 60 ))

# NOTE: stdout and stderr are intentionally kept separate here. A failed SSH
# *connection* (still booting, sshd not up yet, etc.) must never be
# mistaken for empty-but-successful command output — callers rely on the
# exit status, not just on whether any text came back.
ssh_probe() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout=10 -o BatchMode=yes -i "$PEM_LOCAL" "Administrator@$PUBLIC_IP" "$1"
}

# ---------------------------------------------------------------------
# Phase 5: poll for C:\ami-ready.txt, bounded to this invocation's own
# window (a handful of attempts) as well as the overall READY_TIMEOUT_MINUTES
# budget tracked against the instance's LaunchTime; rerun the script to
# keep polling across invocations.
# ---------------------------------------------------------------------
READY=0
INVOCATION_DEADLINE=$(( $(now_epoch) + 480 ))  # ~8 min of polling per invocation
while [ "$(now_epoch)" -lt "$INVOCATION_DEADLINE" ]; do
  if [ "$(now_epoch)" -gt "$DEADLINE" ]; then
    echo "ERROR: provisioner did not signal ready within ${READY_TIMEOUT_MINUTES} minutes of launch." >&2
    echo "Diagnose via: ssh -i $PEM_LOCAL Administrator@$PUBLIC_IP 'Get-Content C:\\ami-build.log -Tail 100'" >&2
    exit 1
  fi
  if OUT=$(ssh_probe 'Get-Content C:\ami-ready.txt -ErrorAction SilentlyContinue' 2>/dev/null) && [ -n "$OUT" ]; then
    log "provisioner ready (sentinel: $OUT)"
    READY=1
    break
  fi
  log "not ready yet ($(date -u '+%H:%M:%S') UTC); sleeping ${POLL_INTERVAL_SECONDS}s"
  sleep "$POLL_INTERVAL_SECONDS"
done

if [ "$READY" -ne 1 ]; then
  log "still waiting on the provisioner after this invocation's poll window; rerun the same command to keep polling"
  exit 2
fi

# ---------------------------------------------------------------------
# Phase 6: toolchain verification (recorded, must all pass)
# ---------------------------------------------------------------------
log "verifying toolchain"
FAIL=0
for CHECK in 'java -version' 'mvn -version' 'git --version' 'conan --version'; do
  echo "--- $CHECK ---"
  ssh_probe "$CHECK" || FAIL=1
done
echo "--- VC Build Tools presence ---"
VC_CHECK=$(ssh_probe "Test-Path 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC'" 2>&1) || FAIL=1
echo "$VC_CHECK"
echo "$VC_CHECK" | grep -qi '^True' || FAIL=1
if [ "$FAIL" -ne 0 ]; then
  echo "ERROR: one or more toolchain verification checks failed; see output above and C:\\ami-build.log" >&2
  exit 1
fi
log "all toolchain checks passed"

# ---------------------------------------------------------------------
# Phase 7: stop -> create-image -> wait available -> terminate
# ---------------------------------------------------------------------
log "stopping builder instance $INSTANCE_ID"
"$AWS_BIN" ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
"$AWS_BIN" ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"

log "creating image $AMI_NAME from $INSTANCE_ID"
IMAGE_ID=$("$AWS_BIN" ec2 create-image --instance-id "$INSTANCE_ID" --name "$AMI_NAME" \
  --description "GitLab win64 bake runner toolchain image (GraalVM 21.0.2, Maven 3.9.9, git, Conan 2.x, VS Build Tools VCTools)" \
  --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=$AMI_NAME}]" \
  --query 'ImageId' --output text)
log "image $IMAGE_ID creating; waiting for it to become available (this can take a while — rerun to keep polling if this invocation times out)"

if ! "$AWS_BIN" ec2 wait image-available --image-ids "$IMAGE_ID" 2>/dev/null; then
  log "AMI not available yet after this invocation's wait window; rerun the same command to keep polling (builder instance is stopped, not terminated)"
  exit 2
fi
log "AMI available: $IMAGE_ID"

log "terminating builder instance $INSTANCE_ID"
"$AWS_BIN" ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
"$AWS_BIN" ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" || true

"$AWS_BIN" ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1 || log "SG $SG_ID not deleted (likely still detaching); safe to delete manually later"

echo "$IMAGE_ID"
