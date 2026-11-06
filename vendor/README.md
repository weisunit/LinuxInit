# vendor/ — 第三方脚本本地集成

linuxmirrors 官方脚本的固化副本，由主脚本在运行时直接调用（**不在线拉取**，离线环境可用）。

| 文件 | 官网别名 | 下载来源 | 下载日期 | 官方版本（脚本头 Modified） | sha256 |
| --- | --- | --- | --- | --- | --- |
| ChangeMirrors.sh | main.sh | https://linuxmirrors.cn/main.sh | 2026-11-05 | 2026-10-31 | `f68b776d875ba47bcbba5eeb23d8264c186ef5618ee7b55cec4b8fb305c66983` |
| DockerInstallation.sh | docker.sh | https://linuxmirrors.cn/docker.sh | 2026-11-05 | 2026-05-16 | `830c81fada2a17080e1e80a4c99d10943d8c6de13557b0a7cbc64b60296100f3` |

约定：

- 本目录脚本为上游**原样拷贝，不做任何修改**；定制一律通过命令行参数传入（遵循官方"定制脚本"指引）；
- 升级流程：官网重新下载 → `shasum -a 256` 核对 → diff 审查变更 → 更新上表 → 重新执行 `build.sh` 打包；
- 上游项目：https://github.com/SuperManito/LinuxMirrors （文档：https://linuxmirrors.cn）
