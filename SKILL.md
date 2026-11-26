---
name: ipa-build
version: 1.2.0
description: 把 iOS 程序打包成 .ipa。机器上有编译器时可以直接把 Objective-C/C/C++ 源码编成 arm64 安装包；没有编译器时也能把现成的 .app 打成 ipa、给已有的 ipa 重做伪签名、改 bundle id 做多开。SDK、ldid、zsign 都在插件里，跑一次自带的 bootstrap 就把编译器也装好，用户不用手动装任何东西。不碰 Swift，也不做 App Store 上架。
---

# 产出 IPA

装好这个插件以后，本机就多了一套 iOS 打包环境，你可以直接干活，不用再回头问用户"你装了 Xcode 吗"。

环境是这么放的：SDK 压缩包、ldid 源码、libplist 源码、zsign.exe 都在 `vendor/` 里，bootstrap 把它们铺到 `~/.ipa-toolchain`（Windows 上是 `%USERPROFILE%\.ipa-toolchain`）。这几个不用联网。编译器由 bootstrap 自己解决，Windows 上它会先找机器里已有的 LLVM，找不到就下载解压，装完把路径写进用户 PATH，不需要用户动手。

## 先把环境铺一遍

Linux / macOS：

```bash
bash scripts/bootstrap.sh
```

Windows（PowerShell）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1
```

两个脚本都可以反复跑，已经装好的部分会跳过，下载断了重跑会接着下。铺完会给一份 doctor 清单，哪行写着"缺"就是哪一环没成。这些都是脚本该干的事，别让用户自己去装 LLVM、装 WSL。

## 这台机器能做到哪一步

得先看清楚机器，别一条命令下去才发现编不了。

**Linux / macOS**：`build`、`pack`、`resign`、`info` 全都能用。前提是 bootstrap 已经把 clang 和 ld64.lld 装上：Linux 从 apt 拿 clang + lld；macOS 先装 Xcode 命令行工具（系统弹窗确认一次），再从 brew 装 llvm 取 `ld64.lld`。

**Windows**：`pack`、`resign`、`info` 一定能用，靠的是插件里带的 zsign.exe 和 .NET 自带的 zip。`build` 要看有没有 clang：

- 跑过 `bootstrap.ps1` 之后，编译器已经在本机了，直接编；
- 万一本机实在搞不定编译器，而机器里有 WSL，`build` 会自动把活交给 WSL 里的 `scripts/ipa`，你还是敲同一条命令；
- 两个都不可用的极端情况，`pack` 和 `resign` 照常能用，先把包做出来；编译这条路等 bootstrap 装完再走。

`doctor` 会把这几项列出来，先看一眼再决定用哪条路子。

## 命令

Linux / macOS 用 `scripts/ipa`，Windows 用 `scripts\ipa.ps1`，子命令和参数是一样的。

**doctor** —— 看环境

```
scripts/ipa doctor
```

**info** —— 看一个包是什么来路

```
scripts/ipa info dist/HelloApp.ipa
```

会给标识符、版本、最低系统、架构、大小，以及有没有 CodeDirectory。给用户解释"这个包装不装得上"之前先跑这个。

**build** —— 源码编成 ipa

```
scripts/ipa build ./我的源码 --name Hello --bundle-id com.you.hello
```

参数：

- `--name` 应用名，也是可执行文件名和产物名，不填用目录名
- `--bundle-id` 默认 `com.example.app`
- `--min-ios` 默认 14.0。给旧设备就要调低，编高了装不上
- `--framework` 可以重复。不填的话脚本会看源码里有没有 `UIKit/`，有就链 UIKit + Foundation，没有就只链 Foundation
- `--entitlements` 签名用的 plist，越狱环境常要 `get-task-allow`、`platform-application`
- `--icon` 一张 PNG，塞成 `AppIcon60x60@2x.png`
- `--p12` `--prov` `--password` 有证书就走真签名，见下面「换证书签」
- `-o` 输出路径，默认 `./dist/<name>.ipa`

**pack** —— 现成的 .app 打成 ipa，顺便能改东西

```
scripts/ipa pack Some.app -o dist/Some.ipa --bundle-id com.you.other --name 分身
```

`pack` 和 `resign` 同样认 `--p12` `--prov` `--password`，带上就走真签名。

`--bundle-id` 换了就是另一个应用，装在同一台机器上不冲突，做多开就靠这个。`--name` 改了显示名，脚本会连可执行文件名一起改（只改 plist 里的名字会让包起不来，这个坑踩过）。

**resign** —— 已有的包重签

```
scripts/ipa resign 旧包.ipa -o 新包.ipa
```

会把 `_CodeSignature` 删掉重签，包里带的 dylib 也一起签。拿到别人的包、或者签名过期了，用这个。

## 换证书签（p12 + mobileprovision）

```
scripts/ipa resign 旧包.ipa -o 新包.ipa --p12 dev.p12 --prov app.mobileprovision --password 证书密码
```

命令行里密码会留在 shell 历史里，用户的密码能让他自己填就让他填。bundle id 必须和描述文件里的一致，不一致 zsign 会直接报签名失败。Windows 上 zsign 拿 p12 走完整签名链，装未越狱设备也能跑，但这一步会联网查 OCSP 吊销状态，没网时可能慢或报警告，不是出错。

Linux / macOS 上证书签名同样靠 zsign，官方 release 没有 Linux 版，需要把编好的 zsign 放到 `~/.ipa-toolchain/bin/` 或 PATH 里；没有就还是 ad-hoc 伪签。

## 交付之前自己先过一遍这几条

1. 签出来的是 **ad-hoc 伪签名**：CodeDirectory 有，CMS 块没有。越狱设备和 TrollStore 能装，普通未越狱手机装不上。用户说装不上，先问设备是什么状态，别急着改代码。
2. 要装进未越狱设备只能换证书：Apple 开发者证书导出的 p12 加 mobileprovision（设备 UDID 在里面）。用户手上有这对文件时，直接 `--p12 --prov --password` 走真签名，别再拿伪签糊过去。
3. **Swift 编不了。** `swiftc` 是 Apple 工具链的一部分，Linux 和 Windows 都没有。碰到 `.swift` 直接说清楚，让对方给编好的 `.app` 走 `pack`，或者改成 Objective-C。
4. 编出来的最低系统版本就是 `--min-ios`。别把 16.5 起步的包交给 iOS 15 的机器。

## 想确认它真能用

`scripts/examples/HelloApp` 是个能直接编的 UIKit 小例子：

```
scripts/ipa build scripts/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp
```

出 `dist/HelloApp.ipa`，然后 `scripts/ipa info dist/HelloApp.ipa` 看签名那行是不是"有 CodeDirectory"，是就通了。

Windows 上没编译器也别灰心，拿这个例子先 `pack` 一下，能出包就说明打包和签名这两段是好的。

## 目录

```
scripts/ipa             Linux / macOS 入口
scripts/ipa.ps1         Windows 入口
scripts/bootstrap.sh    铺 Linux / macOS 环境
scripts/bootstrap.ps1   铺 Windows 环境
scripts/templates/      Info.plist 模板、entitlements 样例
scripts/examples/       HelloApp
vendor/                 SDK、ldid 源码、libplist 源码、zsign.exe
```
