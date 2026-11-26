# 产出 IPA

装上它，本机就有一套能打包 iOS 安装包的环境。有编译器时能直接把 Objective-C 源码编成 `.ipa`；没编译器时也能打包、重签、改标识，Windows 上一样能干。

## 装

Linux / macOS：

```bash
bash scripts/bootstrap.sh
```

Windows（PowerShell，5.1 和 7 都行）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1
```

会把东西铺到 `~/.ipa-toolchain`（Windows：`%USERPROFILE%\.ipa-toolchain`）。脚本跑几遍都没事，装过的会跳过。

SDK、ldid 源码、libplist 源码、zsign.exe 都在 `vendor/`，这部分不用联网。只有 clang 和 lld 要从系统装：Linux 上用 apt（脚本会把源换成清华镜像），Windows 上得自己装 LLVM。

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

Windows 上把这些 `scripts/ipa` 换成 `scripts\ipa.ps1`，子命令和参数一致。

## 平台差异

| | Linux / macOS | Windows |
|---|---|---|
| build 源码编译 | 有 clang + lld 就能编 | 装了 LLVM 能编；装 WSL 的话 build 会自动借 WSL |
| pack / resign / info | 能 | 能，用插件里的 zsign.exe |

Windows 上没有 clang 又不装 WSL 的话，源码是编不出来的，这时候别硬凑——打包和签名这两件事照样能做，告诉用户要编译得先装 LLVM。936MB 的 LLVM 脚本不会偷偷替你下。

## 签的是什么

ad-hoc 伪签名，带 CodeDirectory 但没有 CMS 块。越狱设备和 TrollStore 能装，未越狱的普通手机装不上，那种情况得用开发者证书（p12 + mobileprovision）重签。

Swift 不在范围内，`swiftc` 只有 Apple 工具链里有。

## 自检

```bash
scripts/ipa build scripts/examples/HelloApp --name HelloApp --bundle-id com.example.helloapp
scripts/ipa info dist/HelloApp.ipa
```

`info` 里签名那行写着「有 CodeDirectory」就说明链路通了。Windows 上没有编译器的话，用 `pack` 打这个例子同样能验证打包和签名。
