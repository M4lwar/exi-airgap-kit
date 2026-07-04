#!/bin/sh
# airgap-kit.sh — assemble a self-contained transfer kit for deploying the
# exificient bake ecosystem to an air-gapped GitLab. Everything the enclave
# needs (repos, builder images, receiver script, runbook, checksums) lands in
# one directory / tarball. See DEPLOY.md for the receiving side.
set -eu

LIB_REPO="https://github.com/M4lwar/exificient-native-image.git"
LIB_REF="v1.0.0"
TMPL_REPO="https://github.com/M4lwar/exi-bake-template.git"
TMPL_REF="main"
ARCHES="x86_64 arm64"
IMAGE_BASE="ghcr.io/m4lwar/exificient-builder:1.0.0"
MAVEN_VERSION="3.9.9"
OUT="" ENGINE="auto" WINDOWS=0 MAKE_TAR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --library-repo) LIB_REPO="$2"; shift 2 ;;
    --library-ref) LIB_REF="$2"; shift 2 ;;
    --template-repo) TMPL_REPO="$2"; shift 2 ;;
    --template-ref) TMPL_REF="$2"; shift 2 ;;
    --arches) ARCHES="$2"; shift 2 ;;
    --builder-image-base) IMAGE_BASE="$2"; shift 2 ;;
    --windows) WINDOWS=1; shift ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --tar) MAKE_TAR=1; shift ;;
    -h|--help) grep '^# ' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }

if [ "$ENGINE" = auto ]; then
  if command -v podman >/dev/null 2>&1; then ENGINE=podman
  elif command -v docker >/dev/null 2>&1; then ENGINE=docker
  else echo "need podman or docker" >&2; exit 1; fi
fi

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

bundle_repo() { # url ref outfile clonedir
  echo "==> bundling $1 @ $2"
  git clone --mirror "$1" "$4" >/dev/null 2>&1
  git -C "$4" rev-parse --verify "$2" >/dev/null || { echo "ref $2 not found in $1" >&2; exit 1; }
  git -C "$4" bundle create "$3" --all >/dev/null
  git bundle verify "$3" >/dev/null
  echo "    $(basename "$3"): $(git -C "$4" rev-parse "$2") ($2)"
}

bundle_repo "$LIB_REPO"  "$LIB_REF"  "$OUT/exi-lib.bundle"      "$WORK/lib"
bundle_repo "$TMPL_REPO" "$TMPL_REF" "$OUT/exi-template.bundle" "$WORK/tmpl"

for A in $ARCHES; do
  IMG="${IMAGE_BASE}-${A}"
  echo "==> saving image $IMG"
  "$ENGINE" pull "$IMG" >/dev/null
  "$ENGINE" save -o "$OUT/builder-${A}.tar" "$IMG"
done

if [ "$WINDOWS" = 1 ]; then
  echo "==> assembling windows toolchain kit"
  mkdir -p "$OUT/windows"
  GVM=$(sed -n 's/^ARG GRAALVM_VERSION=//p' "$WORK/lib.checkout/Dockerfile.builder" 2>/dev/null || true)
  if [ -z "$GVM" ]; then
    git -C "$WORK/lib" show "$LIB_REF:Dockerfile.builder" > "$WORK/Dockerfile.builder"
    GVM=$(sed -n 's/^ARG GRAALVM_VERSION=//p' "$WORK/Dockerfile.builder")
  fi
  [ -n "$GVM" ] || { echo "cannot determine GRAALVM_VERSION" >&2; exit 1; }
  curl -fsSL -o "$OUT/windows/graalvm-community-jdk-${GVM}_windows-x64_bin.zip" \
    "https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${GVM}/graalvm-community-jdk-${GVM}_windows-x64_bin.zip"
  curl -fsSL -o "$OUT/windows/apache-maven-${MAVEN_VERSION}-bin.zip" \
    "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.zip"
  FIRST_ARCH=$(echo "$ARCHES" | awk '{print $1}')
  C=$("$ENGINE" create "${IMAGE_BASE}-${FIRST_ARCH}")
  "$ENGINE" cp "$C:/root/.m2" "$WORK/m2"
  "$ENGINE" rm "$C" >/dev/null
  tar -cf "$OUT/windows/m2-repo.tar" -C "$WORK" m2
  echo "    windows kit: GraalVM $GVM, Maven $MAVEN_VERSION, warmed m2 (MSVC Build Tools NOT included - site prerequisite)"
fi

for f in deploy-kit.sh DEPLOY.md; do
  if [ -f "$SELF_DIR/$f" ]; then cp "$SELF_DIR/$f" "$OUT/$f"; else echo "WARNING: $f not found beside airgap-kit.sh; kit is incomplete" >&2; fi
done
[ -f "$OUT/deploy-kit.sh" ] && chmod +x "$OUT/deploy-kit.sh"

{
  echo "exi-airgap-kit manifest"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "library: $LIB_REPO @ $LIB_REF = $(git -C "$WORK/lib" rev-parse "$LIB_REF")"
  echo "template: $TMPL_REPO @ $TMPL_REF = $(git -C "$WORK/tmpl" rev-parse "$TMPL_REF")"
  for A in $ARCHES; do echo "image: ${IMAGE_BASE}-${A} digest: $("$ENGINE" inspect --format '{{index .RepoDigests 0}}' "${IMAGE_BASE}-${A}" 2>/dev/null || echo n/a)"; done
  [ "$WINDOWS" = 1 ] && echo "windows: graalvm+maven+m2 included (MSVC excluded)"
} > "$OUT/kit-manifest.txt"

( cd "$OUT" && find . -type f ! -name SHA256SUMS -exec shasum -a 256 {} + | sed 's|\./||' > SHA256SUMS )
echo "==> kit complete: $OUT"
cat "$OUT/kit-manifest.txt"

if [ "$MAKE_TAR" = 1 ]; then
  T="exi-airgap-kit-$(date -u +%Y%m%d).tar"
  tar -cf "$OUT/../$T" -C "$OUT" .
  echo "==> tarball: $(cd "$OUT/.." && pwd)/$T"
fi
