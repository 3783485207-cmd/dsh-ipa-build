# 产出 IPA

一个给 Agent 用的插件：装上它，模型就拥有 iPhoneOS 16.5 SDK 和 ldid，能把 iOS 源码编成 `.ipa`。

SDK、ldid 源码、libplist 源码都在 `vendor/` 里，clone 下来不联网也能装。

## 安装

```bash
bash scripts/bootstrap.sh
scripts/ipa doctor
```

bootstrap 会把环境装到 `~/.ipa-toolchain`：编 libplist、编 ldid、解包 SDK；机器上没有 clang 或 lld 的话顺手 apt 装（源会换成清华镜像）。跑几次都没关系。

## 用

```bash
# 源码目录 -> ipa
scripts/ipa build ./myapp --name MyApp --bundle-id com.you.myapp

# 已有 .app -> ipa
scripts/ipa pack ./MyApp.app -o dist/MyApp.ipa
```

`--min-ios` 默认 14.0，编给老设备记得调；`--entitlements` 可以塞越狱环境要的权限；`--icon` 传一张 PNG。

## 说明

- 签名是 ldid 伪签名（ad-hoc），带 CodeDirectory、没有 CMS。越狱设备和巨魔能装，普通未越狱装不上，那种情况要用开发者证书重签。
- Swift 编不了，Linux 没 swiftc。Objective-C 和 C/C++ 没问题。
- 框架走 SDK 里的 .tbd stub 链接，UIKit/Foundation 之外要的框架自己加 `--framework`。

## 验证

```bash
scripts/ipa build scripts/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp
```

出来 `dist/HelloApp.ipa`，`ldid -h` 看里面的可执行文件，有 `CodeDirectory v=20400` 和 CDHash 就是通的。

## License

脚本 MIT。`vendor/iPhoneOS16.5.sdk.tar.xz` 版权归 Apple，`vendor/ldid-master` 版权归原作者（见其 COPYING）。
