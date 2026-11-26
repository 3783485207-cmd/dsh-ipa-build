#!/usr/bin/env bash
# 首次使用跑这个脚本，把 iOS 编译环境搭起来。
# SDK 和 ldid 源码都在 vendor/ 里，没网也能装。

set -e

here="$(cd "$(dirname "$0")" && pwd)"
skill="$(dirname "$here")"
tc="${IPA_HOME:-$HOME/.ipa-toolchain}"

mkdir -p "$tc"/bin "$tc"/src "$tc"/deps "$tc"/sdk

echo "装到 $tc"

# clang 和 lld 得从 apt 拿，其他都能自己编
if ! command -v clang >/dev/null 2>&1; then
  echo "没有 clang，装一下"
  if ! grep -q tuna /etc/apt/sources.list 2>/dev/null; then
    sudo sed -i 's|http://archive.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list
    sudo sed -i 's|http://security.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list
  fi
  sudo mkdir -p /var/lib/apt/lists/partial
  sudo apt-get update -qq || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang lld
fi

# clang 链接 Mach-O 的时候会去 PATH 里找 ld64.lld 这个名字，系统装的是带版本号的
if ! command -v ld64.lld >/dev/null 2>&1; then
  real="$(ls /usr/bin/ld64.lld-* 2>/dev/null | head -1)"
  if [ -z "$real" ]; then
    echo "找不到 ld64.lld，先 apt install lld"
    exit 1
  fi
  sudo ln -sf "$real" /usr/local/bin/ld64.lld
fi

# ldid 依赖 libplist，先编 libplist
if [ ! -f "$tc/deps/lib/libplist-2.0.a" ]; then
  echo "编 libplist"
  rm -rf "$tc/src/libplist-2.6.0"
  tar -xjf "$skill/vendor/libplist-2.6.0.tar.bz2" -C "$tc/src"
  cd "$tc/src/libplist-2.6.0"
  ./configure --prefix="$tc/deps" --disable-cython >/dev/null
  make -j"$(nproc)" >/dev/null
  make install >/dev/null
  cd -
fi

if [ ! -x "$tc/bin/ldid" ]; then
  echo "编 ldid"
  rm -rf "$tc/src/ldid-master"
  cp -r "$skill/vendor/ldid-master" "$tc/src/"
  cd "$tc/src/ldid-master"
  PKG_CONFIG_PATH="$tc/deps/lib/pkgconfig" make -j"$(nproc)" >/dev/null
  cp ldid "$tc/bin/ldid"
  cd -
fi

# SDK 解包一次就行
if [ ! -d "$tc/sdk/iPhoneOS16.5.sdk" ]; then
  echo "解包 SDK"
  tar -xJf "$skill/vendor/iPhoneOS16.5.sdk.tar.xz" -C "$tc/sdk"
fi

cat > "$tc/env.sh" <<EOF
export IPA_HOME="$tc"
export IPA_SDK="$tc/sdk/iPhoneOS16.5.sdk"
export IPA_LDID="$tc/bin/ldid"
export LD_LIBRARY_PATH="$tc/deps/lib:\${LD_LIBRARY_PATH:-}"
EOF

echo
echo "好了。试一下："
echo "  $here/ipa doctor"
echo "  $here/ipa build $here/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp"
