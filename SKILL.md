---
name: ipa-build
version: 1.0.0
description: 在本机用 iPhoneOS 16.5 SDK 交叉编译 iOS 程序（Objective-C/C/C++），ldid 伪签名后打包成 .ipa。插件自带 SDK 与 ldid 源码，装好后模型即可直接产出可安装包，也能把已有的 .app 重新打包签名。不处理 Swift（缺 swiftc）、App Store 上架流程、Android 打包。
---

# 产出 IPA

这个插件装好之后，本机就具备下面这些能力，可以直接用，不用再问用户要环境：

- 一套 **iPhoneOS 16.5 SDK**（在 `vendor/iPhoneOS16.5.sdk.tar.xz` 里）
- **ldid** 伪签名（源码在 `vendor/ldid-master`，会编出 `~/.ipa-toolchain/bin/ldid`）
- **clang 14 + ld64.lld**：能编 arm64 Mach-O 并链 iOS 框架（UIKit/Foundation 等，走 SDK 里的 .tbd stub）
- 把 `Payload/App.app` 打成标准 `.ipa`

也就是说：用户把 iOS 源码给你，你就能编出 `.ipa` 交给对方。

## 第一次用先 bootstrap

```bash
bash scripts/bootstrap.sh
```

幂等，重复跑没事。它做的事：缺 clang/lld 就 apt 装（会把源换清华镜像）、编 libplist、编 ldid、解包 SDK，最后写 `~/.ipa-toolchain/env.sh`。全程离线可用（SDK、ldid、libplist 源码都在 `vendor/`）。

装完自检：

```bash
scripts/ipa doctor
```

四行全是路径/版本，没有「缺」就是齐了。

## 编源码出 ipa

```bash
scripts/ipa build <源码目录> --name AppName --bundle-id com.you.app
```

参数：

- `--name` 应用名，也是产物名，不填就用目录名
- `--bundle-id` 不填默认 `com.example.app`
- `--min-ios` 默认 14.0，给老设备编就调低
- `--framework UIKit` 可重复；不填时自动判断——源码里出现 `UIKit/` 就链 UIKit + Foundation，否则只链 Foundation
- `--entitlements` 指定签名用的 entitlements plist（越狱环境常用 `get-task-allow`、`platform-application`）
- `--icon` 一张 PNG，会按 `AppIcon60x60@2x.png` 放进去
- `-o` 输出路径，默认 `./dist/<name>.ipa`

产物结构是标准 `Payload/AppName.app/{AppName, Info.plist}`，签名由 ldid 在打包前完成。

已有的 `.app` 想重新打包：

```bash
scripts/ipa pack path/to/Some.app -o dist/Some.ipa
```

## 交付时要说清楚的三件事

1. **这是伪签名（ad-hoc）**。CodeDirectory 有，CMS 签名块没有。能装进越狱设备或巨魔（TrollStore），装不进普通未越狱设备。用户说「装不上」先问清楚设备状态，别改代码乱试。
2. **要装进未越狱设备，必须换证书签名**：Apple 开发者证书导出的 p12（带完整证书链）+ 对应的 mobileprovision（设备 UDID 在里面或企业证书）。这一步在本插件之外，用 zsign / Sideloadly 那类工具重签即可，重签会覆盖 ldid 的签名。
3. **Swift 不在支持范围**。`swiftc` 是 Apple 工具链的一部分，Linux 上没有。碰到 `.swift` 直接告诉用户改 Objective-C，或者让对方提供编译好的 `.app` 走 `ipa pack`。

另外：编出来的最低系统版本就是 `--min-ios` 那个值，别给 iOS 15 的设备交一个 16.5 起步的包。

## 目录

```
scripts/bootstrap.sh   一次性的环境搭建
scripts/ipa            doctor / build / pack
scripts/templates/     Info.plist、entitlements 样例
scripts/examples/HelloApp/  一个能直接编的 UIKit 例子
vendor/                SDK 压缩包、ldid 源码、libplist 源码
```

想验证插件是不是真能用，编一下自带的例子：

```bash
scripts/ipa build scripts/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp
```

出来 `dist/HelloApp.ipa`，用 `ldid -h` 看包内可执行文件，能看到 `CodeDirectory v=20400` 和 CDHash，就说明签名链路是通的。
