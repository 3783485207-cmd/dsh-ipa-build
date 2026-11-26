import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const PROVIDER_NAME = "dsh-ipa-build";
const SKILL_BODY_URL = new URL("./SKILL.md", import.meta.url);
const RESOURCE_BASE = {
  kind: "directory",
  path: fileURLToPath(new URL("./", import.meta.url)),
};

const CANDIDATE = {
  name: "dsh-ipa-build",
  description:
    "把 iOS 程序打包成 .ipa：有源码可用内置 SDK 交叉编译，有现成 .app 可打包，已有 ipa 可重签、改 bundle id 做多开。不碰 Swift，不做上架。",
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
      content: await readFile(SKILL_BODY_URL, "utf8"),
    };
  },
};

const name = "dsh-ipa-build";
const inject = ["skills"];
function apply(ctx) {
  ctx.skills.registerProvider(() => provider);
}
export { apply, inject, name };
