---
name: ipa-build
version: 1.1.0
description: 把 iOS 程序打包成 .ipa。机器上有编译器时可以直接把 Objective-C/C/C++ 源码编成 arm64 安装包；没有编译器时也能把现成的 .app 打成 ipa、给已有的 ipa 重做伪签名、改 bundle id 做多开。SDK、ldid、zsign 都在插件里，装一次就行。不碰 Swift，也不做 App Store 上架。
---

# 产出 IPA

装好这个插件以后，本机就多了一套 iOS 打包环境，你可以直接干活，不用再回头问用户"你装了 Xcode 吗"。

环境是这么放的：SDK 压缩包、ldid 源码、libplist 源码、zsign.exe 都在 `vendor/` 里，bootstrap 把它们铺到 `~/.ipa-toolchain`（Windows 上是 `%USERPROFILE%\.ipa-toolchain`）。除了 clang 和 lld 要靠系统装，其他都不需要联网。

## 先把环境铺一遍

Linux / macOS：

```bash
bash scripts/bootstrap.sh
```

Windows（PowerShell）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1
```

两个脚本都可以反复跑，已经装好的部分会跳过。铺完会给一份 doctor 清单，哪行写着"缺"就是哪一环没成。

## 这台机器能做到哪一步

得先看清楚机器，别一条命令下去才发现编不了。

**Linux / macOS**：`build`、`pack`、`resign`、`info` 全都能用。前提是 bootstrap 已经把 clang 和 ld64.lld 装上（Linux 上是从 apt 拿的 clang + lld）。

**Windows**：`pack`、`resign`、`info` 一定能用，靠的是插件里带的 zsign.exe 和 .NET 自带的 zip。`build` 要看有没有 clang：

- 机器上装了 LLVM（要带 ld64.lld），能直接编；
- 没装但装了 WSL，`build` 会自动把活交给 WSL 里的 `scripts/ipa`，你在 Windows 上照样敲一条命令；
- 两个都没有，就别硬来，用 `pack` 或者告诉用户去装 LLVM。936MB 的 LLVM 不该由脚本偷偷下。

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
- `-o` 输出路径，默认 `./dist/<name>.ipa`

**pack** —— 现成的 .app 打成 ipa，顺便能改东西

```
scripts/ipa pack Some.app -o dist/Some.ipa --bundle-id com.you.other --name 分身
```

`--bundle-id` 换了就是另一个应用，装在同一台机器上不冲突，做多开就靠这个。`--name` 改了显示名，脚本会连可执行文件名一起改（只改 plist 里的名字会让包起不来，这个坑踩过）。

**resign** —— 已有的包重签

```
scripts/ipa resign 旧包.ipa -o 新包.ipa
```

会把 `_CodeSignature` 删掉重签，包里带的 dylib 也一起签。拿到别人的包、或者签名过期了，用这个。

## 交付之前自己先过一遍这几条

1. 签出来的是 **ad-hoc 伪签名**：CodeDirectory 有，CMS 块没有。越狱设备和 TrollStore 能装，普通未越狱手机装不上。用户说装不上，先问设备是什么状态，别急着改代码。
2. 要装进未越狱设备只能换证书：Apple 开发者证书导出的 p12 加 mobileprovision（设备 UDID 在里面）。这一步不在插件范围内，用 zsign 或 Sideloadly 重签就行，重签会把 ldid 的签名覆盖掉。
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
