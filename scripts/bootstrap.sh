#!/usr/bin/env bash
# 一次性把环境铺好：SDK、ldid、libplist 都在 vendor/ 里，不用联网；
# 只有 clang 和 lld 得从系统包里装。

set -e

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
tc="${IPA_HOME:-$HOME/.ipa-toolchain}"

mkdir -p "$tc/bin" "$tc/sdk" "$tc/src" "$tc/deps"
echo "装到 $tc"

if ! command -v clang >/dev/null 2>&1; then
  echo "缺 clang，从 apt 装（源换清华镜像，国内快一点）"
  if [ -f /etc/apt/sources.list ] && ! grep -q tuna /etc/apt/sources.list; then
    sudo sed -i 's|http://archive.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list
    sudo sed -i 's|http://security.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list
  fi
  sudo mkdir -p /var/lib/apt/lists/partial
  sudo apt-get update -qq || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang lld
fi

# clang 调 ld64.lld 时按这个名字找，系统装的是带版本号的文件，做个软链接
if ! command -v ld64.lld >/dev/null 2>&1; then
  real="$(ls /usr/bin/ld64.lld-* 2>/dev/null | head -1)"
  [ -n "$real" ] || { echo "装了 clang 但没 lld，运行: sudo apt install lld"; exit 1; }
  sudo ln -sf "$real" /usr/local/bin/ld64.lld
fi

if [ ! -f "$tc/deps/lib/libplist-2.0.a" ]; then
  echo "编 libplist"
  rm -rf "$tc/src/libplist-2.6.0"
  tar -xjf "$root/vendor/libplist-2.6.0.tar.bz2" -C "$tc/src"
  ( cd "$tc/src/libplist-2.6.0" && ./configure --prefix="$tc/deps" --disable-cython >/dev/null \
    && make -j"$(nproc)" >/dev/null && make install >/dev/null )
fi

if [ ! -x "$tc/bin/ldid" ]; then
  echo "编 ldid"
  rm -rf "$tc/src/ldid-master"
  cp -r "$root/vendor/ldid-master" "$tc/src/"
  ( cd "$tc/src/ldid-master" && PKG_CONFIG_PATH="$tc/deps/lib/pkgconfig" make -j"$(nproc)" >/dev/null \
    && cp ldid "$tc/bin/ldid" )
fi

if [ ! -d "$tc/sdk/iPhoneOS16.5.sdk" ]; then
  echo "解包 SDK"
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
export LD_LIBRARY_PATH="$tc/deps/lib:\${LD_LIBRARY_PATH:-}"
EOF

echo
"$here/ipa" doctor
echo
echo "自检一下："
echo "  $here/ipa build $here/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp"
