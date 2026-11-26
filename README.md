# 产出 IPA · ipa-builder

装完插件直接能用的 iOS 打包工具链：**iPhoneOS SDK + ldid 自动就位，用户给源码 → 输出 `.ipa`**。

在 Linux x86_64 上完整验证过：Objective-C/UIKit 源码 → arm64 Mach-O → `.app` → ldid 签名 → `.ipa`。

## 一条命令安装

```bash
git clone <本仓库地址> ipa-builder
cd ipa-builder
./install.sh                    # 自动装 clang/lld、编译 libplist+ldid、展开内置 SDK
./ipa doctor                    # 验证
```

安装（或自检）完成后，工具链固定在 `~/.ipa-toolchain`：

```
~/.ipa-toolchain/
├── bin/ldid            # 签名器
├── deps/               # libplist
├── sdk/iPhoneOS16.5.sdk
└── env.sh              # 环境变量，ipa 脚本自动加载
```

如果 SDK 包不在 `vendor/` 里，显式传路径：`./install.sh /path/iPhoneOS16.5.sdk.tar.xz`

## 构建 IPA

```bash
./ipa build examples/HelloApp \
  --name HelloApp \
  --bundle-id com.example.helloapp
```

输出：`dist/HelloApp.ipa`。

实际运行结果（本机实测）：

```
源码 1 个，目标 arm64-apple-ios16.5
可执行文件: Mach-O 64-bit arm64 executable, flags:<NOUNDEFS|DYLDLINK|TWOLEVEL|PIE>
CodeDirectory v=20400 size=705 flags=0x0(none) hashes=17+2 location=embedded
Hash type=sha256 size=32
IPA: dist/HelloApp.ipa (8.0K)
        0  Payload/
        0  Payload/HelloApp.app/
    70224  Payload/HelloApp.app/HelloApp
      935  Payload/HelloApp.app/Info.plist
```

### 常用参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `--name` | 应用名，也是产物文件名 | 源码目录名 |
| `--bundle-id` | CFBundleIdentifier | `com.example.app` |
| `--min-ios` | MinimumOSVersion / 编译目标 | `16.5` |
| `--framework UIKit` | 额外链接框架，可重复 | 自动检测（有 `<UIKit/` 就链 UIKit+Foundation） |
| `--entitlements` | 签名用的 entitlements plist | 无（用 `templates/entitlements.plist` 可传） |
| `--icon` | 图标 PNG | 无 |
| `-o` | 输出路径 | `dist/<name>.ipa` |

### 只打包已有的 .app

```bash
./ipa pack 某App.app -o dist/某App.ipa
```

会先对 `Payload/*.app/<CFBundleExecutable>` 做 ldid 签名，再压成标准 `Payload/` 结构。

## 目录结构

```
ipa-builder/
├── ipa                  # 主程序（doctor / install-sdk / build / pack）
├── install.sh           # 一键安装
├── plugin.json          # 插件清单（DSH/Agent 插件可直接读这个）
├── templates/
│   ├── Info.plist.in    # 构建时替换 {{NAME}} {{BUNDLE}} {{MINIOS}}
│   └── entitlements.plist
├── examples/HelloApp/   # UIKit 示例
├── vendor/              # 内置 SDK 包与 ldid 源码（离线可用）
└── dist/                # 产物
```

## 工作方式（出问题先看这里）

1. `ipa build` 用 `clang -target arm64-apple-ios16.5 -isysroot <SDK>` 编译，链接器是 `ld64.lld`（clang 的 `-fuse-ld=lld` 会按名字找 `ld64.lld`，install.sh 已建好软链）。
2. 框架从 SDK 的 `.tbd` stub 链接：`-F $SDK/System/Library/Frameworks -framework UIKit`。
3. 打包成 `Payload/<Name>.app/`，写入 Info.plist，再 `ldid -S` 伪签名，最后 `zip -qr` 成 `.ipa`。

## 边界

- **不支持 Swift**：Swift 编译必须有 Apple 的 `swiftc`，Linux 上没有。检测到 `.swift` 会直接报错并提示改用 `./ipa pack` 提供已编译的 `.app`。
- **ldid 是伪签名**：签名不依赖 Apple 证书，能装到越狱设备/已信任环境，**不能上架 App Store**，也不能在未越狱设备上绕过系统校验。
- **SDK 版权归 Apple**：仅在你获授权的开发场景使用；不要用它分发他人的应用。

## License

本仓库的脚本与模板：MIT。`vendor/` 下的 iPhoneOS SDK 版权归 Apple Inc.，ldid 版权归其原作者（见 `vendor/ldid-master/COPYING`）。
