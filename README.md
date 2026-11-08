# LinuxInit —— Linux 新装系统通用初始化脚本

> 新装 Linux 服务器开机后的一键初始化：换源 → 更新 → 对时 → 主机名/网络 → 防火墙 → 内核调优 → 常用软件 → 建用户 → Docker → SSH 加固 → NVIDIA 驱动 → 汇总报告。
> 每个模块可**单独运行 / 多选组合 / 全部顺序执行**，均有跳过途径。需求详见 [需求文档.md](需求文档.md)（v0.6，决策点 D1~D15 已全部确认）。

---

## 快速开始

**新装机器只需一行**（自动多通道下载 → 落盘 → 非 root 自动提权 → 启动交互主菜单）：

```bash
bash <(curl -sSL https://cdn.jsdelivr.net/gh/weisunit/LinuxInit@main/init.sh)
```

- 引导脚本依次尝试 4 个下载通道（GitHub codeload 直连 → jsDelivr 双 CDN → ghproxy 镜像 → raw 直连），全部失败会给出 git clone 应急方案；
- 主脚本落盘 `~/linux-init.sh`（含内嵌 vendor，单文件自足），**NVIDIA 装完重启后重跑 `sudo bash ~/linux-init.sh` 即自动续跑验证**；
- 无人值守一行流（密码走环境变量，不进 history；新装机最小系统若无 curl/wget 会自动用现有源安装）：

```bash
LINUX_INIT_USER_PASSWORD='改成你的密码' bash <(curl -sSL https://cdn.jsdelivr.net/gh/weisunit/LinuxInit@main/init.sh) \
  --yes --user deploy --ssh-port 22222 \
  --pubkey-url https://github.com/<user>.keys --with-docker
```

- 版本锁定：默认拉 `main`，稳定环境可 `LINUX_INIT_VERSION=v1.0.0 bash <(curl -sSL .../init.sh)`。

**源码形态（可审查/可定制）**：

```bash
git clone https://github.com/weisunit/LinuxInit.git
cd LinuxInit && sudo bash linux-init.sh        # 交互主菜单（推荐新手）
```

**单文件直发**（内嵌 vendor，离线可用）：

```bash
scp dist/linux-init.sh root@<服务器>:/root/
ssh root@<服务器> 'bash /root/linux-init.sh'
```

> ⚠ 必须以 **root 身份直接运行**（`su root` 或 `sudo -i` 后执行），不要 `sudo bash` 管道方式。

## 交互主菜单

无参数运行进入主菜单：显示 13 个模块 + 实时状态（✅完成 / ○未执行 / ❌失败 / ⏭跳过 / ⏸待重启验证）。

```text
   ID  模块                         状态
   1   更换国内软件源               ✅ 完成
   2   系统与软件更新               ○ 未执行
   ...
   a   全部执行（按推荐顺序 1→13）
   v   查看上次运行报告
   q   退出
```

- **单选** `4`：只跑该模块（前置依赖不满足时交互引导，如 SSH 加固前先建用户）；
- **多选** `2 3 7`：无论输入顺序，按推荐顺序排队执行；
- **全部**：`a` 或 `--all`，交互模式下 Docker/NVIDIA 等默认关闭的模块会逐个询问。

## 模块清单（ID = 推荐执行顺序）

| ID | 模块 | 默认 | 说明 |
|----|------|------|------|
| 1 | 更换国内软件源 | ✅执行 | 集成 [linuxmirrors](https://linuxmirrors.cn)（本地 vendor 副本，不在线拉取）；换源失败默认仅警告（`--strict-mirror` 硬失败） |
| 2 | 系统与软件更新 | ✅执行 | apt full-upgrade / dnf upgrade；自动记录"需重启" |
| 3 | 时区与时间同步 | ✅执行 | Asia/Shanghai + chrony（阿里云/腾讯云 NTP） |
| 4 | 设置主机名 | ⏭跳过 | RFC 1123 校验 + 同步 /etc/hosts（sudo 不再报 resolve 警告） |
| 5 | 网络配置 | ⏭跳过 | **多网卡**固定 IP（总览表 + 会话网卡⚠️识别 + 单默认网关策略）+ /etc/hosts 解析；**默认只写入不激活**（Ubuntu 可 `netplan try` 120s 自动回滚） |
| 6 | 关闭防火墙 | ✅执行 | ufw/firewalld/nftables；RedHat 系**默认同时关闭 SELinux**（`--selinux-enforcing` 保留） |
| 7 | 内核参数调优 | ✅执行 | 温和档（BBR+fq/连接队列/文件描述符）/ 激进档（`--tune aggressive`，多卡 memlock）/ `--tune off` |
| 8 | 安装常用软件 | ✅执行 | basic 组（vim/git/htop/jq/...）；交互可加 dev 组（gcc/python3-pip/tmux...） |
| 9 | 创建用户与 sudo | ✅执行 | **默认 NOPASSWD 免密**（`--sudo-require-password` 反向）；公钥支持 粘贴/文件/https URL |
| 10 | 安装 Docker | ⏭跳过 | linuxmirrors docker.sh（装 Engine+Compose）；已装则 `--only-registry` 换加速器；新用户自动入 docker 组 |
| 11 | SSH 加固 | ✅执行 | 改端口(默认 22222)+禁 root+禁密码+密钥登录；**防锁死五条红线**（见下） |
| 12 | NVIDIA 驱动与 CUDA | ⏭跳过 | 按显卡型号**自动选型**（Blackwell/Hopper→open，Pascal→proprietary）；驱动↔CUDA 自动匹配；无显卡零改动跳过；`apt-mark hold` 锁版本 |
| 13 | 汇总报告与收尾 | ✅固定 | 状态总表 + 关键信息 + 退出前自测清单 + 重启询问 |

## 命令行

```bash
bash linux-init.sh [模块ID...] [选项]     # 无参数 = 交互主菜单
```

```bash
# 单独执行某模块
bash linux-init.sh 11                          # 仅 SSH 加固

# 多选组合（按推荐顺序执行 1→2→3）
bash linux-init.sh 3 1 2

# 主机名 + Hosts 解析 + 温和调优
bash linux-init.sh 4 5 7 --hostname web-01 --hosts-entry "192.168.1.100 nas-01"

# 多网卡固定 IP：eth0 走默认网关，eth1 业务内网不配网关
bash linux-init.sh 5 \
  --nic "eth0:192.168.1.10/24:192.168.1.1:223.5.5.5,119.29.29.29" \
  --nic "eth1:10.0.0.5/24:none"

# 无人值守全功能（密码走环境变量，不进 history）
export LINUX_INIT_USER_PASSWORD='你的密码'
bash linux-init.sh --yes \
  --user deploy --ssh-port 22222 \
  --pubkey-url https://github.com/<user>.keys \
  --tools basic --with-docker

# GPU 服务器（Ubuntu）：驱动自动选型 + 激进调优 + CUDA + Docker
bash linux-init.sh --yes --user ai-runner --tune aggressive \
  --with-docker --with-nvidia --with-cuda
```

常用跳过/开关：`--skip-mirrors` `--skip-update` `--skip-time` `--keep-firewall` `--tune off` `--tools none` `--skip-user`（须与 `--skip-ssh` 同用）`--skip-ssh` `--with-docker` `--with-nvidia` `--with-cuda[=13-0]`；调试：`--dry-run`（只打印动作）`--force-step <ID>`（强制重跑）`--force`（忽略预检告警）。

完整参数见 `bash linux-init.sh --help`。

## 支持的系统

| 级别 | 发行版 |
|---|---|
| ✅ 完整支持 | Ubuntu 20.04/22.04/24.04/26.04 · Debian 11/12/13 · Rocky/AlmaLinux 8/9/10 · CentOS Stream 9/10 · RHEL 8/9/10 |
| ⚠️ 尽力支持 | CentOS 7.9（EOL vault 源）· RHEL 7 · openEuler · OpenCloudOS · Anolis · Fedora · Kali/Armbian/Proxmox |
| ❌ 不支持 | Alpine · openSUSE · Arch · Gentoo · NixOS · 容器内环境 · WSL1 |

NVIDIA 模块 v1 仅支持 Ubuntu（D2 决策）；RHEL 系驱动路径在 backlog。

## 安全设计

**SSH 防锁死五条红线**（模块 11 强制执行）：
1. 新用户 + 公钥就位（权限 700/600）才允许禁用 root/密码登录，否则拒绝继续；
2. 配置修改后先 `sshd -t` 校验，失败自动回滚；
3. 重启 sshd 不断开当前会话，结尾提示"新开终端验证后再关旧会话"；
4. 主配置中既有 `Port` 指令被注释（防多端口叠加监听）；drop-in 用 **`00-` 前缀**确保优先于云镜像的 `50-cloud-init.conf`；
5. 密码仅经交互 `read -s` 或环境变量 `LINUX_INIT_USER_PASSWORD`，**不提供命令行密码参数**（防 history 泄露），日志不落任何明文凭据。

其他：
- 模块 5 静态 IP 默认**只写入不激活**，Ubuntu 走 `netplan try`（120 秒无确认自动回滚）；修改当前会话所在网卡红字警告；
- NVIDIA `apt-mark hold` 锁定驱动（解锁 `apt-mark unhold <包名>`）；Secure Boot 开启时黄字提示（DKMS 模块可能无法加载）；
- 所有配置写入带 `# >>> linux-init >>>` 标记块，可重复执行、可整体删除回滚；改前配置备份至 `/root/linux-init-backup/<时间戳>/`；
- 状态与日志：`/var/lib/linux-init/state.env`、`/var/log/linux-init/<时间戳>.log`、报告 `last-report.txt`。

## 仓库结构

```
LinuxInit/
├── linux-init.sh      # 主脚本（源码形态，引用 vendor/）
├── vendor/            # linuxmirrors 官方脚本固化副本（不改源码）
│   ├── ChangeMirrors.sh         # 换源（2026-10-31 版）
│   ├── DockerInstallation.sh    # Docker（2026-05-16 版）
│   └── README.md                # 来源/版本/sha256 与升级流程
├── build.sh           # 打包：内嵌 vendor → dist 单文件
├── dist/linux-init.sh # 产物：单文件，离线可用，可独立分发
├── 需求文档.md         # v0.6，需求与决策记录
└── README.md
```

vendor 升级：官网重新下载 → sha256 核对 → diff 审查 → 更新 `vendor/` → 重新 `./build.sh`。

## 常见问题

- **SSH 改造后连不上？** 先别关旧会话！按报告里的自测清单排查：云安全组是否放行新端口、`ss -tlnp | grep sshd`、日志 `/var/log/linux-init/`。脚本修改前已自动备份 `/etc/ssh/sshd_config`。
- **Secure Boot 机器装 NVIDIA 驱动异常？** 发行版签名驱动可直接用；DKMS 自编译需关闭 Secure Boot 或注册 MOK（`mokutil --sb-state` 查看状态）。
- **docker 组安全吗？** 等价 root 权限，仅加入你信任的日常用户。
- **换源后 apt/dnf 仍报错？** 模块 1 默认软失败，可重跑模块 1 换一个镜像站（状态文件不会阻止重跑未完成模块，或用 `--force-step 1`）。
