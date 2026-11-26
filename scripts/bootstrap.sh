#!/usr/bin/env bash
# 一次性把环境铺好：SDK、ldid、libplist 都在 vendor/ 里，不用联网；
# 只有 clang 和 lld 得从系统包里装。

set -e

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
tc="${IPA_HOME:-$HOME/.ipa-toolchain}"

mkdir -p "$tc/bin" "$tc/sdk" "$tc/src" "$tc/deps"
echo "装到 $tc"

os="$(uname -s)"

if [ "$os" = "Darwin" ]; then
  if ! command -v clang >/dev/null 2>&1; then
    echo "缺 Xcode 命令行工具，开始装（系统会弹一个确认框，点一下就行）"
    xcode-select --install >/dev/null 2>&1 || true
    for i in 1 2 3 4 5 6 7 8; do
      command -v clang >/dev/null 2>&1 && break
      echo "等 Xcode 命令行工具装完（$((i*15))s / 120s，网络慢就会超时）"
      sleep 15
    done
    command -v clang >/dev/null 2>&1 || { echo "命令行工具还没装完（等了两分钟没等到）。等它装完再跑一次这个脚本就行"; exit 1; }
  fi

  # Apple 自带的 clang 不带 ld64.lld，得用 brew 的 llvm
  if ! command -v ld64.lld >/dev/null 2>&1; then
    if ! command -v brew >/dev/null 2>&1; then
      echo "没有 Homebrew，先装一个"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ||         { echo "Homebrew 没装上（网络问题），装完再跑一次"; exit 1; }
    fi
    echo "装 llvm，里面有 ld64.lld，几百 MB，等一下"
    brew install llvm
    prefix="$(brew --prefix llvm 2>/dev/null || true)"
    [ -n "${prefix:-}" ] || { echo "brew 装完找不到 llvm 目录"; exit 1; }
    ln -sf "$prefix/bin/ld64.lld" "$tc/bin/ld64.lld"
  fi
else
  if ! command -v clang >/dev/null 2>&1; then
    echo "缺 clang，装一个"
    if command -v apt-get >/dev/null 2>&1; then
      # 不动系统软件源，换源影响这台机器上所有 apt 操作。
      # 要换：IPA_APT_MIRROR=tuna bash scripts/bootstrap.sh，两种源格式都认
      if [ "${IPA_APT_MIRROR:-}" = "tuna" ]; then
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
          [ -f "$f" ] || continue
          sudo cp -n "$f" "$f.bak.ipa" 2>/dev/null || true
          sudo sed -i 's|http://archive.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g; s|http://security.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g; s|http://deb.debian.org/debian/|https://mirrors.tuna.tsinghua.edu.cn/debian/|g; s|http://deb.debian.org/debian-security/|https://mirrors.tuna.tsinghua.edu.cn/debian-security/|g' "$f"
        done
      fi
      sudo mkdir -p /var/lib/apt/lists/partial
      sudo apt-get update -qq || true
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang lld python3 zip unzip
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y clang lld python3 zip unzip
    elif command -v pacman >/dev/null 2>&1; then
      sudo pacman -Sy --needed --noconfirm clang lld python zip unzip
    else
      echo "认不出包管理器（只有 apt / dnf / pacman 会装），请自己装 clang、lld、python3、zip、unzip" >&2
      exit 1
    fi
  fi

  # clang 调 ld64.lld 时按这个名字找，系统装的是带版本号的文件，做个软链接
  if ! command -v ld64.lld >/dev/null 2>&1; then
    real="$(ls /usr/bin/ld64.lld-* /usr/lib/llvm-*/bin/ld64.lld 2>/dev/null | head -1)"
    [ -n "$real" ] || { echo "装了 clang 但没 lld，运行: sudo apt install lld"; exit 1; }
    sudo ln -sf "$real" /usr/local/bin/ld64.lld
  fi
fi

if [ ! -f "$tc/deps/lib/libplist-2.0.a" ]; then
  echo "编 libplist"
  rm -rf "$tc/src/libplist-2.6.0"
  tar -xjf "$root/vendor/libplist-2.6.0.tar.bz2" -C "$tc/src"
  ( cd "$tc/src/libplist-2.6.0" && ./configure --prefix="$tc/deps" --disable-cython >/dev/null \
    && make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )
fi

if [ ! -x "$tc/bin/ldid" ]; then
  echo "编 ldid"
  rm -rf "$tc/src/ldid-master"
  cp -r "$root/vendor/ldid-master" "$tc/src/"
  ( cd "$tc/src/ldid-master" && PKG_CONFIG_PATH="$tc/deps/lib/pkgconfig" make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" >/dev/null \
    && cp ldid "$tc/bin/ldid" )
fi

SDK_SHA="1d55ed9e66a37c0e6813c5be29df6f64f1ce448f58911a6cb87db07d5f6b8c58"
ZSIGN_SHA="abc1087da5a410c42fdbb8e90049802c2cc6c03fcd0ebb6d5c315b17f6d26a87"

check_sha() {
  local f="$1" want="$2"
  [ -f "$f" ] || return 0
  local got
  if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$f" | cut -d' ' -f1)"
  else got="$(shasum -a 256 "$f" | cut -d' ' -f1)"; fi
  [ "$got" = "$want" ] || { echo "$f 的 sha256 对不上：$got（应为 $want），包被换过或者没下全，停下" >&2; exit 1; }
}

check_sha "$root/vendor/zsign/zsign.exe" "$ZSIGN_SHA"

if [ ! -d "$tc/sdk/iPhoneOS16.5.sdk" ]; then
  echo "解包 SDK"
  check_sha "$root/vendor/iPhoneOS16.5.sdk.tar.xz" "$SDK_SHA"
  tar -xJf "$root/vendor/iPhoneOS16.5.sdk.tar.xz" -C "$tc/sdk"
fi

# 老包里的 .tbd 是软链，解出来只有几个字节，链接时会缺 libc++ 符号
tbd="$tc/sdk/iPhoneOS16.5.sdk/usr/lib/libc++.tbd"
if [ -f "$tbd" ] && [ "$(wc -c <"$tbd")" -lt 1000 ]; then
  echo "SDK 里的 .tbd 是没展开的软链，重新解一份：把 vendor/iPhoneOS16.5.sdk.tar.xz 换成新包"
  exit 1
fi

cat > "$tc/env.sh" <<EOF
export IPA_HOME="$tc"
export IPA_SDK="$tc/sdk/iPhoneOS16.5.sdk"
export IPA_LDID="$tc/bin/ldid"
export PATH="$tc/bin:$PATH"
export LD_LIBRARY_PATH="$tc/deps/lib:\${LD_LIBRARY_PATH:-}"
EOF

echo
"$here/ipa" doctor
echo
echo "自检一下："
echo "  $here/ipa build $here/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp"
