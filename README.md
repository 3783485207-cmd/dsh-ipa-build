# dsh-ipa-build

把 iOS 源码编成 `.ipa`，或者把现成的 `.app` 打成包、改 bundle id、重签，包里带的 dylib 一并处理。Windows、Linux、macOS 都能跑，SDK 和签名工具都塞在插件里，不用另装 Xcode。

导入插件后不用做什么准备。把源码或者 `.app` 交给 AI，让它出包就行——环境由插件自己铺，第一次用时铺一次，之后不再动。

## 安装

DSH 里装：

```
dsh plugin add dsh-ipa-build
```

也可以给仓库地址 `https://github.com/3783485207-cmd/dsh-ipa-build`，或者直接把目录拷进 DSH 的插件目录。

想手动铺环境（一般不必要）：

```bash
bash scripts/bootstrap.sh          # Linux / macOS
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1   # Windows
```

东西都落在 `~/.ipa-toolchain`（Windows 下是 `%USERPROFILE%\.ipa-toolchain`）。SDK、ldid、zsign 从 `vendor/` 里铺，不联网；只有编译器要下载。

- Linux：`apt` 装 clang、lld
- macOS：先 `xcode-select --install`（系统会弹一次窗），再用 brew 装 llvm 拿 `ld64.lld`
- Windows：先用机器里已有的 LLVM，没有就下载解压，断了下重跑会接着续

`ipa doctor` 会告诉你哪一环缺。

## 用法

```bash
scripts/ipa build ./myapp --name MyApp --bundle-id com.you.myapp          # 源码出包
scripts/ipa pack MyApp.app -o dist/MyApp.ipa --bundle-id com.you.app2     # 现成的 .app 出包
scripts/ipa resign old.ipa -o new.ipa                                    # 重签
scripts/ipa info dist/MyApp.ipa                                          # 看看包里是什么
```

Windows 把 `scripts/ipa` 换成 `scripts\ipa.ps1`，子命令和参数一样。

## 用真证书签

三个命令都认 `--p12 --prov --password`：

```bash
IPA_CERT_PASSWORD=证书密码 scripts/ipa resign old.ipa -o new.ipa --p12 dev.p12 --prov app.mobileprovision
```

密码走 `IPA_CERT_PASSWORD` 环境变量，`--password` 只是兼容写法，会留在 shell 历史里。

不给 p12 就是 ad-hoc 伪签：越狱机和 TrollStore 能装，普通设备装不上。Windows 上的 zsign 支持真签名；Linux/macOS 上要自己编一个 zsign 放进 `~/.ipa-toolchain/bin/`（上游只发 Windows 版）。

真签名时 bundle id 必须跟描述文件对上，对不上签名会失败。zsign 签完会查 OCSP 吊销状态，断网时会慢一点或者报个警告。

## 平台差异

`pack` / `resign` / `info` 不依赖编译器，三平台行为一样。`build` 要 clang + ld64.lld：Linux/macOS 跑完 bootstrap 就有；Windows 上 bootstrap 会装 LLVM，实在装不上而机器里有 WSL 时，`build` 会把活转给 WSL 里的 bash 版本，命令不用改。

## 自检

```bash
scripts/ipa build scripts/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp
scripts/ipa info dist/HelloApp.ipa
```

`info` 的签名行有内容就说明编译、打包、签名这条链路通了。没有编译器的机器用 `pack` 打这个例子也能验证打包和签名。

## 包里的东西

- `vendor/iPhoneOS16.5.sdk.tar.xz` — 16.5 的 iPhoneOS SDK，`.tbd` 已展开成真文件。sha256 `1d55ed9e66a37c0e6813c5be29df6f64f1ce448f58911a6cb87db07d5f6b8c58`
- `vendor/zsign/zsign.exe` — 来自 https://github.com/zhlynn/zsign v1.1.3 的 Windows 版。sha256 `abc1087da5a410c42fdbb8e90049802c2cc6c03fcd0ebb6d5c315b17f6d26a87`
- `vendor/libplist-2.6.0.tar.bz2`、`vendor/ldid-master/` — Linux/macOS 编 ldid 用。ldid 是上游 master 的源码快照（没有 pin commit，所以不是一个可复现的构建，介意就自己换固定版本重编）

第三方组件许可证各不相同，见 `NOTICE`：仓库自己的代码是 MIT，ldid 是 AGPL-3.0，libplist 是 LGPL-2.1，SDK 归 Apple，zsign 见上游仓库。

## 不做的

Swift 不编（`swiftc` 只在 Apple 工具链里）。不做 App Store 上架，也不碰 FairPlay。
