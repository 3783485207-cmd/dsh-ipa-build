---
name: dsh-ipa-build
version: 1.3.6
description: 把 iOS 程序做成 .ipa。源码能直接交叉编译成 arm64 包，现成的 .app 能打包，已有 ipa 能重签、改 bundle id 做多开，dylib 也跟着签。SDK、ldid、zsign 随插件带，环境由 AI 自己铺好，用户不用装东西。
---

# dsh-ipa-build

导入插件后用户什么都不用做。第一次接到打包任务时，你自己把环境铺一遍，然后直接出包——别回头问用户"装了 Xcode 吗""有 SDK 吗"。

## 第一次用：自己铺环境

```bash
bash scripts/bootstrap.sh                                          # Linux / macOS
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1     # Windows
```

SDK、ldid、libplist、zsign 从插件自带的 `vendor/` 铺到 `~/.ipa-toolchain`（Windows 是 `%USERPROFILE%\.ipa-toolchain`），不联网。编译器由脚本装：Linux 走 apt 拿 clang 和 lld；macOS 要 `xcode-select --install` 弹一次窗，再从 brew 拿 `ld64.lld`；Windows 先找机器里已有的 LLVM，没有再下载解压。脚本可以重复跑，装过的跳过，下载断了重跑接着续。

铺完跑 `ipa doctor`，哪行写缺就补哪一环。环境没齐就直接开编，是浪费用户的时间。

## 命令

Linux / macOS 用 `scripts/ipa`，Windows 用 `scripts\ipa.ps1`，子命令参数一致。

**doctor** 看环境。

**info** 看包：

```
scripts/ipa info dist/HelloApp.ipa
```

给标识符、版本、最低系统、架构、大小、签名状态。回答"这包能不能装"之前先跑它。

**build** 源码出包：

```
scripts/ipa build ./源码 --name Hello --bundle-id com.you.hello
```

- `--name` 应用名，同时也是可执行文件名和产物名，缺省取目录名
- `--bundle-id` 缺省 `com.example.app`
- `--min-ios` 缺省 14.0
- `--framework` 可重复；不写就看源码里有没有 `UIKit/`，有就链 UIKit + Foundation，没有只链 Foundation
- `--entitlements` 签名用的 plist
- `--icon` PNG，塞成 `AppIcon60x60@2x.png`
- `--p12 --prov --password` 有证书走真签名
- `-o` 输出，缺省 `./dist/<name>.ipa`

**pack** 现成的 .app 出包：

```
scripts/ipa pack Some.app -o dist/Some.ipa --bundle-id com.you.other --name 分身
```

换 `--bundle-id` 就是另一个应用，同机共存；`--name` 改显示名，可执行文件名跟着改。

**resign** 重签：

```
scripts/ipa resign 旧包.ipa -o 新包.ipa
```

删掉 `_CodeSignature` 重签，包里的 dylib 一起签。签名过期或者换了证书就走这个。

## 证书签名

```
scripts/ipa resign 旧包.ipa -o 新包.ipa --p12 dev.p12 --prov app.mobileprovision --password 密码
```

`pack`、`build` 同样认这三个参数。bundle id 必须和描述文件一致，否则签名失败。

密码优先用 `IPA_CERT_PASSWORD` 环境变量，别写进命令行（会留在 shell 历史和进程列表里）。

Windows 的 zsign 拿 p12 走完整签名链，签完查一次 OCSP，断网时会慢或报警告，不算失败。Linux / macOS 的证书签名也要 zsign，上游只发 Windows 版，得自己编一个放进 `~/.ipa-toolchain/bin/`。

## 交付前确认这几条

1. 不给 p12 签出来的是 ad-hoc：有 CodeDirectory，没 CMS 块。越狱机和 TrollStore 能装，普通设备不行。用户说装不上，先问设备状态，别急着改代码。
2. 要装普通设备只能用开发者证书，p12 加含设备 UDID 的 mobileprovision。
3. Swift 编不了，`swiftc` 只在 Apple 工具链里。遇到 `.swift` 说清楚，让对方给编好的 `.app` 走 `pack`，或者改 Objective-C。
4. 最低系统版本就是 `--min-ios`，别把 16.5 的包给 iOS 15 的机器。

## 验证

```
scripts/ipa build scripts/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp
scripts/ipa info dist/HelloApp.ipa
```

`info` 签名行有内容，就说明编译、打包、签名这条链路都通了。没有编译器的机器用 `pack` 打这个例子，验证后两段。

## 目录

```
scripts/ipa             Linux / macOS 入口
scripts/ipa.ps1         Windows 入口
scripts/bootstrap.sh    铺 Linux / macOS
scripts/bootstrap.ps1   铺 Windows
scripts/templates/      Info.plist 模板、entitlements 样例
scripts/examples/       HelloApp
vendor/                 SDK、ldid 源码、libplist 源码、zsign.exe
```
