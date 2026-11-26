import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const MANIFEST_URL = new URL("./package.json", import.meta.url);
let versionPromise;

// 不能在这里 top-level await：宿主有可能是 require 进来的，同步加载才稳
function pluginVersion() {
  versionPromise ??= readFile(MANIFEST_URL, "utf8")
    .then((raw) => JSON.parse(raw).version ?? "0.0.0")
    .catch(() => "0.0.0");
  return versionPromise;
}

// 状态行插在 frontmatter 后面，不能顶到 --- 前面，否则 YAML 头就废了
function withStatus(body, version) {
  const notice =
    `dsh-ipa-build ${version}。工具链在 ~/.ipa-toolchain（Windows 是 %USERPROFILE%\\.ipa-toolchain），` +
    `没铺的时候 build / pack / resign 会自己铺；查新版跑 scripts/ipa update --check（Windows 用 scripts\\ipa.ps1）。`;
  const m = body.match(/^---\r?\n[\s\S]*?\r?\n---\r?\n/);
  if (!m) return notice + "\n\n" + body;
  return m[0] + "\n" + notice + "\n\n" + body.slice(m[0].length);
}

const PROVIDER_NAME = "dsh-ipa-build";
const SKILL_BODY_URL = new URL("./SKILL.md", import.meta.url);
const RESOURCE_BASE = {
  kind: "directory",
  path: fileURLToPath(new URL("./", import.meta.url)),
};

const CANDIDATE = {
  name: "dsh-ipa-build",
  description:
    "把 iOS 程序打包成 .ipa：源码用内置 SDK 交叉编译，Swift / SwiftUI 源码自动转成等价 Objective-C 再编，现成 .app 可打包，已有 ipa 可重签、改 bundle id 做多开。环境自己铺，工具链能云端热更新。",
  invocation: { modelInvocable: true, userInvocable: true },
  provider: PROVIDER_NAME,
  source: "bundled",
  // DSH 的 skill 候选必须带数值 rank，缺了注册时直接抛 "invalid rank"；
  // 600 是官方给打包安装的 provider 用的标准档（BUNDLED_SKILL_RANK）
  rank: 600,
  resourceBase: RESOURCE_BASE,
  locator: SKILL_BODY_URL,
};

const provider = {
  name: PROVIDER_NAME,
  list: () => Promise.resolve([CANDIDATE]),
  async get() {
    return {
      name: CANDIDATE.name,
      description: CANDIDATE.description,
      invocation: CANDIDATE.invocation,
      provider: CANDIDATE.provider,
      source: CANDIDATE.source,
      resourceBase: RESOURCE_BASE,
      // DSH 解析 skill 时对 list() 与 get() 的返回都做候选校验，两边都必须带数值 rank
      rank: CANDIDATE.rank,
      content: withStatus(
        await readFile(SKILL_BODY_URL, "utf8"),
        await pluginVersion(),
      ),
    };
  },
};

const name = "dsh-ipa-build";
const inject = ["skills"];
function apply(ctx) {
  ctx.skills.registerProvider(() => provider);
}
export { apply, inject, name };

// 有的加载器只认默认导出，带上更稳；根目录不能再放 plugin.json，
// DSH 会先读那个文件当插件本体，它不是对象也不是函数，直接报 expect apply
export default { name, apply, inject };
