# dsh-ipa-build

给 DSH 用的 iOS 打包插件。扔给它一份源码、一个 `.app` 或者一个旧 ipa，拿回来一个能装的包。Windows、Linux、macOS 都能跑。

## 装

```
dsh plugin add dsh-ipa-build@1.4.1
```

版本号照着写，别写 latest。DSH 的插件市场只认精确版本，写范围或者 latest 会被直接拒掉。

## 第一次跑

不用先装 Xcode。第一次出包（build / pack / resign）的时候插件会自己把环境解开，SDK、ldid、zsign 落在 `~/.ipa-toolchain`（Windows 是 `%USERPROFILE%\.ipa-toolchain`），之后再跑就不动了。

想先看一眼也行：

```bash
bash scripts/bootstrap.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1
```

只有编译器这一步绕不开，得联网：

- Linux：`apt` 拿 clang 和 lld，几十兆
- macOS：先 `xcode-select --install`（会弹个框，点一下），再 `brew install llvm` 拿 `ld64.lld`
- Windows：先用机器里已经装的 LLVM，没有就下 18.1.8，九百多兆，慢

装完 `scripts/ipa doctor`，一行一行看过去，缺哪行补哪行。

## 出包

```bash
scripts/ipa build ./myapp --name MyApp --bundle-id com.you.myapp
scripts/ipa pack MyApp.app -o dist/MyApp.ipa --bundle-id com.you.app2
scripts/ipa resign old.ipa -o new.ipa
scripts/ipa info dist/MyApp.ipa
```

Windows 上把 `scripts/ipa` 换成 `scripts\ipa.ps1`，参数一模一样。

`build` 吃的是 `.m` / `.c` 这类能直接交给 clang 的源码。碰到 Swift 或者 SwiftUI，插件不会甩回来让你自己编，它会先转成等价的 Objective-C 再走 `build`。几百行的工程转完基本看不出接缝；几千行、又带动画和自定义绘制的，一定会丢细节，转完在回复里会告诉你哪几处没对上。

## 用证书签

`build`、`pack`、`resign` 都认 `--p12 --prov --password`：

```bash
IPA_CERT_PASSWORD=证书密码 scripts/ipa resign old.ipa -o new.ipa --p12 dev.p12 --prov app.mobileprovision
```

密码优先走 `IPA_CERT_PASSWORD`，`--password` 只是兼容老命令行，那玩意儿会留在 shell 历史里。

不给 p12 就是 ad-hoc 伪签，只有越狱机和 TrollStore 认，普通 iPhone 装不上。

Windows 的 zsign 能走完整证书链；Linux 和 macOS 上 zsign 要自己编一个放进 `~/.ipa-toolchain/bin/`，上游只发 Windows 版。

bundle id 必须和描述文件里的一致，不一致签出来也装不上。zsign 签完会去查一次 OCSP，断网的时候会卡一会儿或者报个警告，别当成失败。

## 换版本

```bash
scripts/ipa update --check     # 只看，插件现在多少、npm 上多少
scripts/ipa update             # 直接下新版工具链铺进 ~/.ipa-toolchain
```

`update` 会先核对 npm 给的 sha512 再解包，旧工具链原地替换，你之前出的包和证书都不受影响。工具链换完，插件本体还要宿主那边换一下，结尾会把命令打出来。

## 平台上的出入

`pack` / `resign` / `info` 不碰编译器，三个平台结果一样。`build` 要 clang 和 ld64.lld：Linux、macOS 跑完 bootstrap 就有；Windows 上 bootstrap 装好 LLVM 就有，装不上但机器里有 WSL 的话，`build` 会把活转给 WSL 里的 bash 版，命令不用改。

打 `.app` 成 `.ipa` 的时候有个差别：Linux、macOS 用 `zip -y`，`.framework` 里的符号链接原样留着；Windows 走 .NET 的 ZipFile，符号链接会被展开成文件副本，打的时候会提示一句。两种包都能装，只是体积和文件列表不完全一样。要一模一样就在 WSL 里打。

## 自检

```bash
scripts/ipa build scripts/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp
scripts/ipa info dist/HelloApp.ipa
```

`info` 的签名那行有内容，说明编译、打包、签名整条链路是通的。没有编译器的机器拿 `pack` 打这个例子，也能验证后两段。

## 包里带了什么

- `vendor/iPhoneOS16.5.sdk.tar.xz`，16.5 的 iPhoneOS SDK，`.tbd` 已经展开成真文件，Windows 解包不会缺符号。sha256 `1d55ed9e66a37c0e6813c5be29df6f64f1ce448f58911a6cb87db07d5f6b8c58`
- `vendor/zsign/zsign.exe`，https://github.com/zhlynn/zsign v1.1.3 的 Windows 版。sha256 `abc1087da5a410c42fdbb8e90049802c2cc6c03fcd0ebb6d5c315b17f6d26a87`
- `vendor/libplist-2.6.0.tar.bz2` 和 `vendor/ldid-master/`，Linux、macOS 上编 ldid 用。ldid 是 ProcursusTeam/ldid v2.1.5-procursus8（commit `18255c5`）的源码快照，`vendor/ldid-master/COMMIT` 里写了怎么对上；bootstrap 编之前先校验 `ldid.cpp` 的 sha256

许可证各是各的，看 `NOTICE`：仓库自己的代码 MIT，ldid 是 AGPL-3.0，libplist 是 LGPL-2.1，SDK 归 Apple，zsign 按上游仓库的声明。

App Store 上架不做，FairPlay 也不碰。
