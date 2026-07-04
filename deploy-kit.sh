#!/bin/sh
# deploy-kit.sh — receiving-side deployer. Run from INSIDE a kit directory on
# a machine that can reach the target GitLab (and its container registry).
# Prerequisites: bash/sh, git, curl, python3, podman or docker.
# Idempotent: safe to rerun. See DEPLOY.md for the full runbook + fallbacks.
set -eu

GITLAB="" GROUP="" TOKEN_ENV="GITLAB_TOKEN" REGISTRY="auto" ENGINE="auto"
TAG_AMD64="" TAG_ARM64="" BAKE_TAG="" SKIP_IMAGES=0 TRIGGER=0 INSECURE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --gitlab) GITLAB="${2%/}"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --token-env) TOKEN_ENV="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --runner-tag-amd64) TAG_AMD64="$2"; shift 2 ;;
    --runner-tag-arm64) TAG_ARM64="$2"; shift 2 ;;
    --bake-runner-tag) BAKE_TAG="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --skip-images) SKIP_IMAGES=1; shift ;;
    --trigger) TRIGGER=1; shift ;;
    --insecure) INSECURE=1; shift ;;
    -h|--help) grep '^# ' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$GITLAB" ] && [ -n "$GROUP" ] || { echo "--gitlab and --group are required" >&2; exit 2; }
TOKEN=$(printenv "$TOKEN_ENV" || true)
[ -n "$TOKEN" ] || { echo "token env \$$TOKEN_ENV is empty" >&2; exit 2; }
HOST="${GITLAB#https://}"; HOST="${HOST#http://}"

CURL_OPTS="-sf"; GIT_TLS=""; ENGINE_TLS=""
[ "$INSECURE" = 1 ] && { CURL_OPTS="-skf"; GIT_TLS="-c http.sslVerify=false"; ENGINE_TLS="--tls-verify=false"; }

if [ "$ENGINE" = auto ]; then
  if command -v podman >/dev/null 2>&1; then ENGINE=podman
  elif command -v docker >/dev/null 2>&1; then ENGINE=docker; ENGINE_TLS=""
  else [ "$SKIP_IMAGES" = 1 ] || { echo "need podman/docker (or --skip-images)" >&2; exit 1; }; fi
fi

api() { # method path [curl -d args...]
  M="$1"; P="$2"; shift 2
  curl $CURL_OPTS -X "$M" -H "PRIVATE-TOKEN: $TOKEN" "$GITLAB/api/v4$P" "$@"
}
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"; }

echo "==> verifying kit integrity"
if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS >/dev/null; else shasum -a 256 -c SHA256SUMS >/dev/null; fi
git bundle verify exi-lib.bundle >/dev/null && git bundle verify exi-template.bundle >/dev/null
echo "    checksums + bundles OK"

echo "==> resolving group $GROUP"
ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$GROUP")
GID=$(api GET "/groups/$ENC" | jget "['id']" 2>/dev/null || true)
if [ -z "$GID" ]; then
  PARENT="${GROUP%/*}"; LEAF="${GROUP##*/}"
  if [ "$PARENT" != "$GROUP" ]; then
    PENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$PARENT")
    PID=$(api GET "/groups/$PENC" | jget "['id']")
    GID=$(api POST "/groups" -d "name=$LEAF" -d "path=$LEAF" -d "parent_id=$PID" | jget "['id']")
  else
    GID=$(api POST "/groups" -d "name=$GROUP" -d "path=$GROUP" | jget "['id']")
  fi
  echo "    created group id $GID"
else echo "    group id $GID"; fi

make_project() { # path -> echoes project id
  api POST "/projects" -d "name=$1" -d "path=$1" -d "namespace_id=$GID" -d "visibility=private" >/dev/null 2>&1 || true
  api GET "/projects/$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$GROUP/$1")" | jget "['id']"
}
echo "==> creating projects"
LIB_ID=$(make_project exificient-native-image)
TMPL_ID=$(make_project exi-bake-template)
echo "    library=$LIB_ID template=$TMPL_ID"

echo "==> pushing mirrors from bundles"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
git clone --mirror exi-lib.bundle "$W/lib" >/dev/null 2>&1
git -C "$W/lib" $GIT_TLS push --mirror "https://oauth2:$TOKEN@$HOST/$GROUP/exificient-native-image.git" 2>&1 | tail -1
git clone --mirror exi-template.bundle "$W/tmpl" >/dev/null 2>&1
git -C "$W/tmpl" $GIT_TLS push --mirror "https://oauth2:$TOKEN@$HOST/$GROUP/exi-bake-template.git" 2>&1 | tail -1

IMG_AMD64="" IMG_ARM64=""
if [ "$SKIP_IMAGES" = 0 ]; then
  echo "==> seeding builder images"
  if [ "$REGISTRY" = auto ]; then
    PREFIX=$(api GET "/projects/$LIB_ID" | jget ".get('container_registry_image_prefix') or ''")
    [ -n "$PREFIX" ] || { echo "container registry unavailable; rerun with --registry <prefix> or --skip-images (see DEPLOY.md fallback)" >&2; exit 1; }
  else PREFIX="$REGISTRY"; fi
  REGHOST="${PREFIX%%/*}"
  "$ENGINE" login $ENGINE_TLS -u oauth2 -p "$TOKEN" "$REGHOST"
  for A in x86_64 arm64; do
    [ -f "builder-$A.tar" ] || continue
    LOADED=$("$ENGINE" load -i "builder-$A.tar" | sed 's/^Loaded image[^:]*: //')
    TARGET="$PREFIX/builder:1.0.0-$A"
    "$ENGINE" tag "$LOADED" "$TARGET" && "$ENGINE" push $ENGINE_TLS "$TARGET"
    [ "$A" = x86_64 ] && IMG_AMD64="$TARGET" || IMG_ARM64="$TARGET"
    echo "    pushed $TARGET"
  done
fi

set_var() { # project_id key value
  [ -n "$3" ] || return 0
  api POST "/projects/$1/variables" -d "key=$2" -d "value=$3" >/dev/null 2>&1 \
    || api PUT "/projects/$1/variables/$2" -d "value=$3" >/dev/null
  echo "    $2=$3"
}
echo "==> variables (library project)"
set_var "$LIB_ID" RUNNER_TAG_AMD64 "$TAG_AMD64"
set_var "$LIB_ID" RUNNER_TAG_ARM64 "$TAG_ARM64"
set_var "$LIB_ID" BUILDER_IMAGE_AMD64 "$IMG_AMD64"
set_var "$LIB_ID" BUILDER_IMAGE_ARM64 "$IMG_ARM64"
echo "==> variables (template project)"
set_var "$TMPL_ID" BAKE_RUNNER_TAG "$BAKE_TAG"
set_var "$TMPL_ID" BAKE_BUILDER_IMAGE "$IMG_AMD64"
set_var "$TMPL_ID" LIBRARY_REPO_URL "$GITLAB/$GROUP/exificient-native-image.git"
set_var "$TMPL_ID" LIBRARY_REF "v1.0.0"

echo "==> job-token allowlist + hygiene"
api POST "/projects/$LIB_ID/job_token_scope/allowlist" -d "target_project_id=$TMPL_ID" >/dev/null 2>&1 || true
api PUT "/projects/$LIB_ID" -d "auto_devops_enabled=false" >/dev/null
api PUT "/projects/$TMPL_ID" -d "auto_devops_enabled=false" >/dev/null
echo "    done"

if [ "$TRIGGER" = 1 ]; then
  echo "==> triggering pipelines"
  for P in $LIB_ID $TMPL_ID; do
    REF=$(api GET "/projects/$P" | jget "['default_branch']")
    PIP=$(api POST "/projects/$P/pipeline" -d "ref=$REF" | jget "['id']")
    echo "    project $P pipeline $PIP (ref $REF)"
    N=0
    while [ $N -lt 90 ]; do
      S=$(api GET "/projects/$P/pipelines/$PIP" | jget "['status']")
      case "$S" in success) echo "    project $P pipeline $PIP: SUCCESS"; break ;;
                   failed|canceled) echo "    project $P pipeline $PIP: $S" >&2; exit 1 ;; esac
      sleep 20; N=$((N+1))
    done
  done
fi
echo "==> deploy complete. Consumers: conan remote add <name> $GITLAB/api/v4/projects/<id>/packages/conan --insecure"
