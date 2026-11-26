#!/usr/bin/env bash
# install.sh —— 一键装好「产出 IPA」所需工具链
# 依赖：linux x86_64、sudo（可选，用于 apt 装 clang/lld）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="${IPA_HOME:-$HOME/.ipa-toolchain}"
SDK_DIR="$TC/sdk/iPhoneOS16.5.sdk"
LDID="$TC/bin/ldid"
GH_MIRROR="${GH_MIRROR:-https://gh-proxy.com/}"

say() { printf '\033[1;34m[ipa]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ok ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

mkdir -p "$TC"/{bin,sdk,src,deps}

# ---------- 1. clang + Mach-O 链接器 ----------
if ! command -v clang >/dev/null; then
  say "未找到 clang，尝试安装（需要 sudo）"
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang lld
  else
    warn "没有 apt-get，请自行安装 clang 与 lld 后重跑"; exit 1
  fi
fi
ok "clang $(clang --version | head -1 | awk '{print $3}')"

# Mach-O 链接器：ld64.lld，clang -fuse-ld=lld 会按名字找它
if ! command -v ld64.lld >/dev/null; then
  CAND="$(ls /usr/bin/ld64.lld-* /usr/lib/llvm-*/bin/ld64.lld 2>/dev/null | head -1 || true)"
  if [ -n "$CAND" ]; then
    sudo ln -sf "$CAND" /usr/local/bin/ld64.lld && ok "已链接 $CAND -> /usr/local/bin/ld64.lld"
  else
    warn "找不到 ld64.lld，iOS 二进制无法链接"; exit 1
  fi
fi
ok "ld64.lld $(ld64.lld --version 2>/dev/null | head -1)"

# ---------- 2. libplist + ldid ----------
build_libplist() {
  [ -f "$TC/deps/lib/libplist-2.0.a" ] && return 0
  say "编译 libplist"
  local src="$TC/src"
  curl -sSL --retry 3 -o "$src/lp.tar.bz2" \
    "${GH_MIRROR}https://github.com/libimobiledevice/libplist/releases/download/2.6.0/libplist-2.6.0.tar.bz2"
  rm -rf "$src/libplist-2.6.0"; tar -xjf "$src/lp.tar.bz2" -C "$src"
  ( cd "$src/libplist-2.6.0" \
    && ./configure --prefix="$TC/deps" --disable-cython >/dev/null \
    && make -j"$(nproc)" >/dev/null && make install >/dev/null )
  ok "libplist 就绪"
}

build_ldid() {
  say "编译 ldid"
  local src="$TC/src"
  if [ ! -x "$LDID" ]; then
    curl -sSL --retry 3 -o "$src/ldid.tar.gz" \
      "${GH_MIRROR}https://github.com/ProcursusTeam/ldid/archive/refs/heads/master.tar.gz" || \
    curl -sSL --retry 3 -o "$src/ldid.tar.gz" \
      "${GH_MIRROR}https://github.com/ProcursusTeam/ldid/archive/refs/heads/main.tar.gz"
    rm -rf "$src"/ldid-*; tar -xzf "$src/ldid.tar.gz" -C "$src"
    local d; d="$(ls -d "$src"/ldid-* | head -1)"
    ( cd "$d" \
      && PKG_CONFIG_PATH="$TC/deps/lib/pkgconfig" make -j"$(nproc)" \
      && cp ldid "$LDID" )
  fi
  ok "ldid 就绪：$LDID"
}

# 编译 ldid 前必须先有 libplist
build_libplist

# 若仓库自带 ldid 源码目录（vendor/ldid-master），优先本地编译，避免依赖网络
if [ ! -x "$LDID" ]; then
  if [ -d "$ROOT/vendor/ldid-master" ]; then
    say "使用仓库内置 ldid 源码编译"
    mkdir -p "$TC/src"; rm -rf "$TC/src/ldid-master"
    cp -r "$ROOT/vendor/ldid-master" "$TC/src/"
    ( cd "$TC/src/ldid-master" \
      && PKG_CONFIG_PATH="$TC/deps/lib/pkgconfig" make -j"$(nproc)" \
      && cp ldid "$LDID" )
    ok "ldid 就绪：$LDID"
  else
    build_ldid
  fi
fi

# ---------- 3. zsign（证书重签用） ----------
ZSign="$TC/bin/zsign"
if [ ! -x "$ZSign" ]; then
  say "编译 zsign（证书签名用）"
  if [ -d "$ROOT/vendor/zsign-master" ]; then
    rm -rf "$TC/src/zsign-master"; cp -r "$ROOT/vendor/zsign-master" "$TC/src/"
  else
    curl -sSL --retry 3 -o "$TC/src/zsign.tar.gz" \
      "${GH_MIRROR}https://github.com/zhlynn/zsign/archive/refs/heads/master.tar.gz"
    rm -rf "$TC/src"/zsign-master; tar -xzf "$TC/src/zsign.tar.gz" -C "$TC/src"
  fi
  if [ -d "$TC/src/zsign-master/build/linux" ]; then
    ( cd "$TC/src/zsign-master/build/linux" && make -j"$(nproc)" >/dev/null 2>&1 \
      && cp ../../bin/zsign "$ZSign" ) || true
  fi
fi
if [ -x "$ZSign" ]; then ok "zsign 就绪：$ZSign"; else warn "zsign 未构建成功：证书签名不可用，伪签名不受影响"; fi

# ---------- 4. iPhoneOS SDK ----------
if [ ! -d "$SDK_DIR" ]; then
  say "安装 iPhoneOS SDK"
  tarball="${1:-}"
  if [ -n "$tarball" ] && [ -f "$tarball" ]; then
    mkdir -p "$TC/sdk"
    tar -xJf "$tarball" -C "$TC/sdk"
  elif [ -f "$ROOT/vendor/iPhoneOS16.5.sdk.tar.xz" ]; then
    tar -xJf "$ROOT/vendor/iPhoneOS16.5.sdk.tar.xz" -C "$TC/sdk"
  else
    warn "没有 SDK 包。请运行：./install.sh /path/to/iPhoneOS16.5.sdk.tar.xz"; exit 1
  fi
fi
[ -d "$SDK_DIR" ] || { warn "SDK 解压后目录名不是 iPhoneOS16.5.sdk，请检查"; exit 1; }
ok "SDK：$SDK_DIR"

# ---------- 5. 写入环境文件 ----------
cat > "$TC/env.sh" <<EOF
export IPA_HOME="$TC"
export IPA_SDK="$SDK_DIR"
export IPA_LDID="$LDID"
export IPA_ZSIGN="$ZSign"
export DYLD_LIBRARY_PATH="$TC/deps/lib:\${DYLD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$TC/deps/lib:\${LD_LIBRARY_PATH:-}"
EOF
ok "环境文件：$TC/env.sh"

cat <<EOF

安装完成。验证：
  ./ipa doctor
构建示例：
  ./ipa build examples/HelloApp --name HelloApp --bundle-id com.example.helloapp

提示：本 SDK 仅用于在你拥有授权的设备上做开发/自用安装，请勿用于分发他人应用。
EOF
