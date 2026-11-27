#!/usr/bin/env bash
# 铺环境：SDK、zsign、ldid(源码现编) 都在 vendor/ 里；只有 clang/lld 要从系统包装。
#
# 两个开关：
#   IPA_NO_COMPILER=1  只铺打包/签名要的东西，不碰编译器（pack / resign 走这条）
#   IPA_FORCE=1        把已有的 SDK / ldid / zsign / 编译中间件先删掉再重铺（ipa update 用）

set -e

SDK_SHA="1d55ed9e66a37c0e6813c5be29df6f64f1ce448f58911a6cb87db07d5f6b8c58"
ZSIGN_SHA="abc1087da5a410c42fdbb8e90049802c2cc6c03fcd0ebb6d5c315b17f6d26a87"
LDID_CPP_SHA="78a5f4d08f8affa6bbbf7b26947ba26023bca91347ee78c4f70d46cf7b67563d"

check_sha() {
  local f="$1" want="$2"
  [ -f "$f" ] || return 0
  local got
  if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$f" | cut -d' ' -f1)"
  else got="$(shasum -a 256 "$f" | cut -d' ' -f1)"; fi
  [ "$got" = "$want" ] || { echo "$f 的 sha256 对不上：$got（应为 $want），包被换过或者没下全，停下" >&2; exit 1; }
}

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
tc="${IPA_HOME:-$HOME/.ipa-toolchain}"

mkdir -p "$tc/bin" "$tc/sdk" "$tc/src" "$tc/deps"
echo "装到 $tc"

# 强制重铺：旧的删掉，后面每一步才会真的重做。不清 deps/src 的话 ldid 会拿旧库再编一遍
if [ "${IPA_FORCE:-}" = "1" ]; then
  echo "强制重铺：先删掉旧的 SDK / ldid / zsign"
  rm -rf "$tc/sdk/iPhoneOS16.5.sdk" "$tc/bin/ldid" "$tc/bin/zsign" "$tc/bin/ld64.lld" "$tc/deps" "$tc/src"
  mkdir -p "$tc/bin" "$tc/sdk" "$tc/src" "$tc/deps"
fi

# ---- 1. SDK 和 zsign：这些跟编译器没关系，先铺好，pack / resign 立刻能用 ----

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

if [ ! -f "$tc/bin/zsign" ]; then
  check_sha "$root/vendor/zsign/zsign.exe" "$ZSIGN_SHA"
  cp -f "$root/vendor/zsign/zsign.exe" "$tc/bin/zsign"
  chmod +x "$tc/bin/zsign" 2>/dev/null || true
fi

cat > "$tc/env.sh" <<EOF
export IPA_HOME="$tc"
export IPA_SDK="$tc/sdk/iPhoneOS16.5.sdk"
export IPA_LDID="$tc/bin/ldid"
export PATH="$tc/bin:$PATH"
export LD_LIBRARY_PATH="$tc/deps/lib:\${LD_LIBRARY_PATH:-}"
EOF

# ---- 2. 编译器：只给 build 用，装不上也不该拖住院 SDK 和打包 ----

install_compiler() {
  os="$(uname -s)"
  if [ "$os" = "Darwin" ]; then
    if ! command -v clang >/dev/null 2>&1; then
      echo "缺 Xcode 命令行工具，开始装（系统会弹一个确认框，点一下就行）"
      xcode-select --install >/dev/null 2>&1 || true
      for i in 1 2 3 4 5 6 7 8; do
        command -v clang >/dev/null 2>&1 && break
        echo "等 Xcode 命令行工具装完（$((i*15))s / 120s）"
        sleep 15
      done
      command -v clang >/dev/null 2>&1 || { echo "命令行工具还没装完，等它装完再跑一次"; return 1; }
    fi

    # Apple 自带 clang 不带 ld64.lld，得用 brew 的 llvm
    if ! command -v ld64.lld >/dev/null 2>&1; then
      command -v brew >/dev/null 2>&1 || {
        echo "没有 Homebrew，先装一个"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { echo "Homebrew 没装上（网络问题）"; return 1; }
      }
      echo "装 llvm（几百 MB）"
      brew install llvm || return 1
      prefix="$(brew --prefix llvm 2>/dev/null || true)"
      [ -n "${prefix:-}" ] || { echo "brew 装完找不到 llvm 目录"; return 1; }
      ln -sf "$prefix/bin/ld64.lld" "$tc/bin/ld64.lld"
    fi
  else
    if ! command -v clang >/dev/null 2>&1; then
      echo "缺 clang，装一个"
      if command -v apt-get >/dev/null 2>&1; then
        if [ "${IPA_APT_MIRROR:-}" = "tuna" ]; then
          for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
            [ -f "$f" ] || continue
            sudo cp -n "$f" "$f.bak.ipa" 2>/dev/null || true
            sudo sed -i 's|http://archive.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g; s|http://security.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g; s|http://deb.debian.org/debian/|https://mirrors.tuna.tsinghua.edu.cn/debian/|g' "$f"
          done
        fi
        sudo mkdir -p /var/lib/apt/lists/partial
        sudo apt-get update -qq || true
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang lld python3 zip unzip || return 1
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y clang lld python3 zip unzip || return 1
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --needed --noconfirm clang lld python zip unzip || return 1
      else
        echo "认不出包管理器（只支持 apt / dnf / pacman），请自己装 clang、lld" >&2
        return 1
      fi
    fi

    if ! command -v ld64.lld >/dev/null 2>&1; then
      real="$(ls /usr/bin/ld64.lld-* /usr/lib/llvm-*/bin/ld64.lld 2>/dev/null | head -1)"
      [ -n "$real" ] || { echo "装了 clang 但没 lld，运行: sudo apt install lld"; return 1; }
      sudo ln -sf "$real" /usr/local/bin/ld64.lld || return 1
    fi
  fi
  return 0
}

if [ "${IPA_NO_COMPILER:-}" = "1" ]; then
  echo "只铺打包要的东西，跳过编译器（IPA_NO_COMPILER=1）"
elif command -v clang >/dev/null 2>&1 && command -v ld64.lld >/dev/null 2>&1; then
  echo "编译器已经在了"
else
  if install_compiler; then :; else
    echo "编译器没装上。pack / resign 照旧能用；build 要等它能用之后再来（多半是没 sudo 或者网络不通）" >&2
  fi
fi

# ---- 3. ldid：要编译器才编得出来，没编译器就跳过 ----

if [ ! -x "$tc/bin/ldid" ]; then
  if command -v clang >/dev/null 2>&1; then
    if [ ! -f "$tc/deps/lib/libplist-2.0.a" ]; then
      echo "编 libplist"
      rm -rf "$tc/src/libplist-2.6.0"
      tar -xjf "$root/vendor/libplist-2.6.0.tar.bz2" -C "$tc/src"
      ( cd "$tc/src/libplist-2.6.0" && ./configure --prefix="$tc/deps" --disable-cython >/dev/null \
        && make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )
    fi

    # ProcursusTeam/ldid v2.1.5-procursus8（commit 18255c5）的源码快照，编前先校验没被改过
    echo "编 ldid"
    check_sha "$root/vendor/ldid-master/ldid.cpp" "$LDID_CPP_SHA"
    rm -rf "$tc/src/ldid-master"
    cp -r "$root/vendor/ldid-master" "$tc/src/"
    ( cd "$tc/src/ldid-master" && PKG_CONFIG_PATH="$tc/deps/lib/pkgconfig" make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" >/dev/null \
      && cp ldid "$tc/bin/ldid" )
  else
    echo "没有编译器，ldid 暂时编不出来：pack / resign 会出没签名的包，build 也用不了"
  fi
fi

echo
"$here/ipa" doctor
echo
echo "自检一下："
echo "  $here/ipa build $here/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp"
