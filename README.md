# 产出 IPA

装好这套东西，本机就能把 Objective-C 源码编成 `.ipa`，也能把现成的 `.app` 打包、改标识、重新签名。Windows 一样能用，不用装 WSL，也不用自己去找 SDK。

## 装

先跑一次，之后不用管它装了什么：

```bash
# Linux / macOS
bash scripts/bootstrap.sh
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1
```

东西都落在 `~/.ipa-toolchain`（Windows 是 `%USERPROFILE%\.ipa-toolchain`）。脚本可以反复跑，装过的跳过。

SDK、ldid、libplist、zsign 都在 `vendor/`，这几个不用联网。编译器脚本自己解决：

- Linux：apt 装 clang 和 lld
- macOS：先用 `xcode-select --install` 装命令行工具（系统会弹一次确认框，点掉就行），再从 brew 装 llvm 拿 `ld64.lld`
- Windows：先找机器里已有的 LLVM（PATH、Program Files、winget 装过的位置），没有就自己下载解压到工具链目录，断了重跑会接着下

装完路径都写进 `~/.ipa-toolchain/env.sh` 或用户 PATH，`doctor` 能看到。除了 macOS 那个系统弹窗，不需要你动手装别的东西。

## 用

```bash
# 源码 -> ipa
scripts/ipa build ./myapp --name MyApp --bundle-id com.you.myapp

# 现成的 .app -> ipa，顺手改标识做多开
scripts/ipa pack MyApp.app -o dist/MyApp.ipa --bundle-id com.you.myapp2

# 已有的包重签
scripts/ipa resign old.ipa -o new.ipa

# 看包里是什么
scripts/ipa info dist/MyApp.ipa
```

Windows 上把 `scripts/ipa` 换成 `scripts\ipa.ps1`，子命令和参数一样。

## 用手上的证书签

手里有开发者证书（p12 加 mobileprovision）时，sign 走真签名，不再用 ad-hoc：

```bash
scripts/ipa resign old.ipa -o new.ipa --p12 dev.p12 --prov app.mobileprovision --password 证书密码
scripts/ipa pack MyApp.app -o dist/MyApp.ipa --p12 dev.p12 --prov app.mobileprovision --password 证书密码
```

`build` 也认这三个参数。bundle id 要跟描述文件里的对上，对不上签名会失败。

Windows 上的 zsign 会拿 p12 走完整签名链，装到未越狱设备也能跑。这一步 zsign 会联网查证书吊销状态（OCSP），网络不通时可能慢一点，或者报个警告。

Linux / macOS 上的证书签名也要 zsign，但官方 release 只发了 Windows 版，得自己编一个放进 `~/.ipa-toolchain/bin/zsign`，或者把它放到 PATH 里。没有 zsign 的时候这两台机器只能 ad-hoc 伪签。

## 平台差异

`pack`、`resign`、`info` 三个命令在两边完全一样，不依赖编译器。`build` 需要 clang 和 ld64.lld：Linux / macOS 跑 bootstrap 就有了；Windows 上 bootstrap 会装好 LLVM，装不上时如果机器里有 WSL，`build` 会自动转给 WSL 里的 bash 版本跑。

## 签出来的是什么

ad-hoc 伪签名：有 CodeDirectory，没有 CMS 块。越狱设备和 TrollStore 能装，普通手机装不上，那种情况用上面说的 p12 走真签名。

Swift 不在范围内，`swiftc` 只有 Apple 工具链里有。

## 自检

```bash
scripts/ipa build scripts/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp
scripts/ipa info dist/HelloApp.ipa
```

`info` 里签名那行写着「有 CodeDirectory」，说明编译、打包、签名这条链路通了。没有编译器的机器，用 `pack` 打这个例子也能验证打包和签名。

## vendor 里的东西

- `iPhoneOS16.5.sdk.tar.xz`：16.5 的 iPhoneOS SDK。包里的 `.tbd` 已经全部展开成真文件，Windows 解包不会拿到空壳。sha256 `1d55ed9e66a37c0e6813c5be29df6f64f1ce448f58911a6cb87db07d5f6b8c58`
- `zsign/zsign.exe`：签名工具，来自 https://github.com/zhlynn/zsign 的 v1.1.3 Windows 版。MD5 `c42f137b76eb4cb2cad2b1a227a0f8f0`
- `libplist-2.6.0.tar.bz2`、`ldid-master/`：Linux / macOS 上编 ldid 用
