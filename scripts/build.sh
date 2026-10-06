#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

readonly TARGET_RELEASE='5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284'
readonly TARGET_TIMESTAMP='Fri Jan 9 20:21:51 CST 2026'
readonly MANIFEST_BRANCH='common-android12-5.10-2025-05'
readonly COMMON_TAG='android12-5.10-2025-05_r6'
readonly COMMON_COMMIT='fb24cf99ad973cd4c7c7fa375c6053f939ef3a89'
readonly BAKASU_COMMIT='61e2ce83055e015e97e1e0f5b303b060b6c6a01f'
readonly SUSFS_BRANCH='gki-android12-5.10'
readonly SUSFS_COMMIT='9892175b4acec7ee844e113b8d02c0f4d12cdfac'
readonly ANYKERNEL_COMMIT='e1e9dce98430c5c6f231f7094a8c7f4ecaf50948'

readonly WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly KERNEL_ROOT="$WORKSPACE/kernel-workspace"
readonly COMMON_ROOT="$KERNEL_ROOT/common"
readonly DEFCONFIG="$COMMON_ROOT/arch/arm64/configs/gki_defconfig"
readonly DIST_DIR="$KERNEL_ROOT/out/android12-5.10/dist"
readonly ARTIFACT_DIR="$WORKSPACE/artifacts"
readonly PACKAGE_NAME="BakaSU-SuSFS-${TARGET_RELEASE}-AnyKernel3.zip"

retry() {
  local attempt=1
  local max_attempts="$1"
  shift
  until "$@"; do
    if (( attempt >= max_attempts )); then
      echo "Command failed after ${attempt} attempts: $*" >&2
      return 1
    fi
    echo "Attempt ${attempt} failed; retrying in 10 seconds..." >&2
    attempt=$((attempt + 1))
    sleep 10
  done
}

clone_pinned() {
  local url="$1"
  local ref="$2"
  local destination="$3"
  retry 3 git clone --filter=blob:none --no-checkout "$url" "$destination"
  git -C "$destination" fetch --depth=1 origin "$ref"
  git -C "$destination" checkout --detach FETCH_HEAD
  test "$(git -C "$destination" rev-parse HEAD)" = "$ref"
}

echo '::group::Fetch repo tool and pinned Android kernel source'
mkdir -p "$WORKSPACE/.bin" "$KERNEL_ROOT"
retry 5 curl -fsSL --retry-all-errors --connect-timeout 30 \
  https://storage.googleapis.com/git-repo-downloads/repo \
  -o "$WORKSPACE/.bin/repo"
chmod 0755 "$WORKSPACE/.bin/repo"

cd "$KERNEL_ROOT"
retry 3 "$WORKSPACE/.bin/repo" init --depth=1 \
  -u https://android.googlesource.com/kernel/manifest \
  -b "$MANIFEST_BRANCH" --repo-rev=v2.16

# The monthly branch continued receiving commits after release 6. Pin the exact
# commit behind android12-5.10-2025-05_r6 while retaining its matching build
# system and prebuilt toolchains.
sed -i "/path=\"common\"/ s|revision=\"[^\"]*\"|revision=\"refs/tags/$COMMON_TAG\"|" \
  .repo/manifests/default.xml
retry 3 "$WORKSPACE/.bin/repo" sync -j4 --jobs-checkout=4 \
  --no-tags --no-clone-bundle --retry-fetches=3

actual_common_commit="$(git -C "$COMMON_ROOT" rev-parse HEAD)"
if [[ "$actual_common_commit" != "$COMMON_COMMIT" ]]; then
  echo "Wrong kernel source: expected $COMMON_COMMIT, got $actual_common_commit" >&2
  exit 1
fi
echo '::endgroup::'

echo '::group::Fetch pinned BakaSU, SuSFS, and AnyKernel3'
clone_pinned https://gitlab.com/simonpunk/susfs4ksu.git \
  "$SUSFS_COMMIT" "$WORKSPACE/susfs4ksu"
clone_pinned https://github.com/WildKernels/AnyKernel3.git \
  "$ANYKERNEL_COMMIT" "$WORKSPACE/AnyKernel3"

cd "$KERNEL_ROOT"
retry 5 curl -fsSL --retry-all-errors --connect-timeout 30 \
  "https://raw.githubusercontent.com/Baka-SU/BakaSU/$BAKASU_COMMIT/kernel/setup.sh" \
  -o /tmp/bakasu-setup.sh
sh /tmp/bakasu-setup.sh "$BAKASU_COMMIT"
actual_bakasu_commit="$(git -C KernelSU rev-parse HEAD)"
if [[ "$actual_bakasu_commit" != "$BAKASU_COMMIT" ]]; then
  echo "Wrong BakaSU source: expected $BAKASU_COMMIT, got $actual_bakasu_commit" >&2
  exit 1
fi
echo '::endgroup::'

echo '::group::Apply SuSFS and Unicode patches'
susfs_patch="$WORKSPACE/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch"
cp "$WORKSPACE/susfs4ksu"/kernel_patches/fs/* "$COMMON_ROOT/fs/"
cp "$WORKSPACE/susfs4ksu"/kernel_patches/include/linux/* "$COMMON_ROOT/include/linux/"
cd "$COMMON_ROOT"
# This release differs by one harmless context line in task_mmu.c from the
# current 5.10 SuSFS patch. Fuzz 1 is required and has been dry-run checked
# against every touched file at COMMON_COMMIT; reject files remain fatal.
patch --batch --forward --fuzz=1 -p1 < "$susfs_patch"

git apply --check "$WORKSPACE/unicode_bypass_fix_6.1-.patch"
git apply "$WORKSPACE/unicode_bypass_fix_6.1-.patch"

if find "$KERNEL_ROOT" -type f -name '*.rej' -print -quit | grep -q .; then
  echo 'A patch produced reject files:' >&2
  find "$KERNEL_ROOT" -type f -name '*.rej' -print >&2
  exit 1
fi
echo '::endgroup::'

echo '::group::Configure the fixed kernel'
cat >> "$DEFCONFIG" <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
EOF

sed -i 's/check_defconfig//' "$COMMON_ROOT/build.config.gki"
sed -i 's/BUILD_SYSTEM_DLKM=1/BUILD_SYSTEM_DLKM=0/' \
  "$COMMON_ROOT/build.config.gki.aarch64"
sed -i '/MODULES_ORDER=android\/gki_aarch64_modules/d' \
  "$COMMON_ROOT/build.config.gki.aarch64"
sed -i '/KMI_SYMBOL_LIST_STRICT_MODE/d' \
  "$COMMON_ROOT/build.config.gki.aarch64"

# Force exactly the requested release string. This also prevents local patch
# state from adding a trailing -dirty suffix.
perl -0pi -e 's/^echo "\$res"$/echo "-android12-9-00003-gfb24cf99ad97-ab14313284"/m' \
  "$COMMON_ROOT/scripts/setlocalversion"
grep -qF 'echo "-android12-9-00003-gfb24cf99ad97-ab14313284"' \
  "$COMMON_ROOT/scripts/setlocalversion"

# KBUILD_BUILD_TIMESTAMP can be normalized by the legacy build scripts, so also
# pin UTS_VERSION at its final generation point.
perl -pi -e 's{UTS_VERSION="\$\(echo \$UTS_VERSION \$CONFIG_FLAGS \$TIMESTAMP \| cut -b -\$UTS_LEN\)"}{UTS_VERSION="#1 SMP PREEMPT Fri Jan 9 20:21:51 CST 2026"}' \
  "$COMMON_ROOT/scripts/mkcompile_h"
grep -qF 'UTS_VERSION="#1 SMP PREEMPT Fri Jan 9 20:21:51 CST 2026"' \
  "$COMMON_ROOT/scripts/mkcompile_h"
echo '::endgroup::'

echo '::group::Compile'
export KBUILD_BUILD_TIMESTAMP="$TARGET_TIMESTAMP"
export KBUILD_BUILD_VERSION=1
export BUILD_NUMBER=14313284
export SOURCE_DATE_EPOCH=1767961311
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_COMPILERCHECK='%compiler% -dumpmachine; %compiler% -dumpversion'
export CCACHE_NOHASHDIR=true
export CCACHE_HARDLINK=true
ccache --max-size=2G
ccache --set-config=compression=true

cd "$KERNEL_ROOT"
LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 \
  build/build.sh CC='/usr/bin/ccache clang'
echo '::endgroup::'

echo '::group::Verify identity and package artifacts'
image="$DIST_DIR/Image"
image_lz4="$DIST_DIR/Image.lz4"
test -s "$image"
test -s "$image_lz4"

# The image also contains the printk format literal "Linux version %s (%s)".
# Search for the requested release directly instead of taking the first generic
# "Linux version" string.
version_line="$(strings "$image" | grep -F -m1 "Linux version $TARGET_RELEASE" || true)"
if [[ -z "$version_line" ]]; then
  echo "Expected kernel release was not found: $TARGET_RELEASE" >&2
  echo 'Linux version candidates:' >&2
  strings "$image" | grep -F 'Linux version ' | head -n 20 >&2 || true
  exit 1
fi
echo "$version_line"

if ! grep -qF "$TARGET_TIMESTAMP" <<< "$version_line"; then
  echo "Expected build timestamp was not found: $TARGET_TIMESTAMP" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR"
cp "$image" "$ARTIFACT_DIR/Image"
cp "$image_lz4" "$ARTIFACT_DIR/Image.lz4"
cp "$image" "$WORKSPACE/AnyKernel3/Image"

cat > "$ARTIFACT_DIR/build-info.txt" <<EOF
kernel_release=$TARGET_RELEASE
build_timestamp=$TARGET_TIMESTAMP
kernel_tag=$COMMON_TAG
kernel_commit=$COMMON_COMMIT
bakasu_commit=$BAKASU_COMMIT
susfs_branch=$SUSFS_BRANCH
susfs_commit=$SUSFS_COMMIT
anykernel3_commit=$ANYKERNEL_COMMIT
unicode_patch=unicode_bypass_fix_6.1-.patch
EOF

(
  cd "$WORKSPACE/AnyKernel3"
  zip -q -r "$ARTIFACT_DIR/$PACKAGE_NAME" . \
    -x '.git/*' '.github/*' 'README.md'
)
sha256sum "$ARTIFACT_DIR"/* > "$ARTIFACT_DIR/SHA256SUMS"
ccache --show-stats
echo '::endgroup::'
