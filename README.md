# omr-vps-deploy

**把 OpenMPTCProuter 服务端（VPS 侧）一键装回服务器。**
服务器被服务商重装/重置后，用一条命令恢复到"路由器能连上"的状态 —— 包括装什么版本、
怎么验收、装完路由器要改哪里，全都固化在这里，不再依赖记忆。

- 目标服务器（本项目的生产 VPS）：`172.236.187.101`
- 配套路由器固件：OMR `v0.63-6.12`（GL-MT3000 / mediatek-filogic）
- 默认部署版本：`omr-vps` **v0.1052**（= 这台服务器此前与路由器正常对接的版本）
- 默认内核线：**6.12**（与路由器固件的内核线一致）

---

## 一键用法

### 路线 A · 直接登录 VPS（推荐）

```sh
ssh -p 65222 root@172.236.187.101          # 重装后还没装 OMR 时用 -p 22

# 先看再跑（推荐）
curl -fsSLO https://raw.githubusercontent.com/Sharkecho/omr-vps-deploy/main/deploy.sh
bash deploy.sh --check      # 只自检，不动系统
bash deploy.sh              # 自检 + 安装 + 验收 + 汇总

# 或者一行到底
curl -fsSL https://raw.githubusercontent.com/Sharkecho/omr-vps-deploy/main/deploy.sh | bash
```

### 路线 B · 从 Windows 本机推上去

```powershell
cd <本仓库目录>
.\local-run.ps1 -Mode check     # 自检（自动探测 22 / 65222）
.\local-run.ps1                 # 安装
.\local-run.ps1 -Mode verify    # 只验收
```

只用到 Windows 自带的 OpenSSH（`ssh.exe` / `scp.exe` / `tar.exe`），不装任何东西。
端口不填会自动探测：先 22，再 65222。

---

## 它会做什么

| 阶段 | 动作 | 是否改动系统 |
|---|---|---|
| 1 自检 | root / Debian-Ubuntu / 架构 / 内存 / 磁盘 / 出网 / 既有安装 / 端口占用 | 否 |
| 2 取件 | 从 GitHub 拉官方安装器（多镜像回退），记 sha256 | 只写 `/root/omr-deploy/` |
| 3 安装 | 用**显式环境变量**跑官方安装器（全非交互） | 是，见下 |
| 4 验收 | API / 端口 / systemd / nftables / 配置文件 / 内核 | 否 |
| 5 汇总 | `/root/omr-deploy/report.txt` + 日志 | 只写报告 |

`--check` 只做阶段 1；`--verify` 只做阶段 4+5（可反复跑）。

### 官方安装器会改动的系统面（心里有数）

- **SSH 端口 22 → 65222**（`/etc/ssh/sshd_config`）；已建立的连接不掉，之后要用 `-p 65222`
- 安装 xanmod-mptcp 内核，并尽量把 grub 默认项切到它 → **要 reboot 才生效**
- 重写 `/etc/nftables.conf` 与 `/etc/nftables/omr*.nft`（自定义规则请放 `/etc/nftables/custom.d/`，那里不会被覆盖）
- 安装/配置 fail2ban（SSH、OpenVPN、omr-admin API、Xray、Shadowsocks-Go）
- 安装一批 systemd 单元：`omr`、`omr-admin`、`omr-service`（看门狗，10s 一轮）、各隧道
- 密钥与端口汇总写入 `/root/openmptcprouter_config.txt`

### 装完的端口表

| 服务 | 端口 |
|---|---|
| SSH | 65222 |
| omr-admin API（路由器 Web UI 用） | 65500 (https) |
| Shadowsocks | 65101 |
| Glorytun（TCP/UDP） | 65001 |
| DSVPN | 65401 |
| MLVPN | 65201+ |
| UBOND | 65251+ |
| MQVPN | 65443 |
| WireGuard 服务端 / 客户端 | 65311 / 65312 |
| OpenVPN | 65301 |
| SoftEther | 65390 |

---

## 参数

优先级：**命令行环境变量 > `/root/omr-deploy/omr.env` > 仓库目录下 `omr.env` > 内置默认**。

```sh
OMR_VERSION=v0.1082 bash deploy.sh      # 临时换服务端版本
KERNEL=6.18     bash deploy.sh          # 临时换内核线
```

完整可调项见 [`omr.env.example`](omr.env.example)。常用几个：

| 变量 | 默认 | 说明 |
|---|---|---|
| `OMR_VERSION` | `v0.1052` | 官方 vps 脚本的 git tag；`master` = 最新 |
| `KERNEL` | `6.12` | MPTCP 内核线：5.4 / 6.1 / 6.6 / 6.10 / 6.11 / 6.12 / 6.18 |
| `REINSTALL` | `yes` | 同版本也重装；`no` = 已是最新就直接退出 |
| `TLS` | `yes` | 只有 `VPS_DOMAIN` 真的能解析时才会去签 ACME 证书，否则自动跳过 |
| `CHINA` | `no` | 走国内镜像才 `yes` |

### 版本策略：为什么默认 pin `v0.1052`

1. **有证据**：这台服务器此前跑的就是 `0.1052`，路由器（v0.63-6.12）与它对接正常 —— 复现已知good状态优先于追新。
2. **可覆盖**：`OMR_VERSION=v0.1082`（或 `master`）随时能换；官方安装器本身也支持原地更新。
3. **旧版本的已知风险**：官方包仓库会下架旧版本包，越老的 pin 越可能在下架后装不上。
   所以 `deploy.sh` 装完**一定要看验收**；若因取包失败而缺件，换 `master` 重跑即可。

---

## 安装后 · 路由器配对（关键一步）

服务端是**重装**的话，官方安装器会**重新随机生成**全部密钥（含路由器访问 API 用的密码）。
路由器里存的是旧密码 → 认证不过 → 需要更新一次。两条路：

### 路线 1 · 让路由器重新配对（一次 LuCI 操作）

1. VPS 上取新凭据：

   ```sh
   grep -iE 'key|user|pass' /root/openmptcprouter_config.txt
   #   username = openmptcprouter
   #   password = <OMR_ADMIN_PASS>
   ```

2. 路由器 LuCI → **OpenMPTCProuter → 系统/服务器** → 把 API 用户名/密码改成上面这组 → 保存应用。

   路由器随后会自己从服务端 API **把隧道端口/密码全部拉回来**（隧道不需要逐个手填）。
3. 等 1–2 分钟，`tun0` 起来、MPTCP 端点回来即配对完成。

### 路线 2 · 沿用旧密钥（路由器一行都不用改）

前提：你手上有**旧的 API 密码**（以及想一并沿用的隧道密码）。

```sh
cp /root/omr-deploy/omr-secrets.env.example /root/omr-deploy/omr-secrets.env
chmod 600 /root/omr-deploy/omr-secrets.env
vi /root/omr-deploy/omr-secrets.env     # 只填 OMR_ADMIN_PASS 就能让路由器免改配置
bash /root/omr-deploy/deploy.sh
```

旧值从哪找：路由器上 `uci show > /tmp/router-uci.txt` 后看 `pass`/`key`/`uuid` 字段；
或刷机前备份包 `mt3000-config-backup.tgz` 里的 `@server[0].*`。

> ⚠️ 别把 `omr-secrets.env` 提交进任何仓库（`.gitignore` 已排除）。

---

## 验收标准（`verify.sh` / `deploy.sh --verify`）

全绿才算装好：

- [x] `curl -k https://127.0.0.1:65500/` → `200` 且包含 `OpenMPTCProuter Server`
- [x] 端口监听：65500 / 65001 / 65101 / 65401 / 65443 / 65311
- [x] systemd：`omr-admin`、`omr-service`、`nftables` 均 active
- [x] nftables 规则集已加载
- [x] `/root/openmptcprouter_config.txt` 存在（权限 600）
- [x] 内核：运行 `uname -r`；装了 xanmod 但没重启会明确提示

`PASS=n FAIL=0` 之后再从外部复核一次（换台机器或手机热点）：

```sh
nc -vz 172.236.187.101 65222
nc -vz 172.236.187.101 65500
curl -k https://172.236.187.101:65500/     # 期望 200 "Welcome to OpenMPTCProuter Server part"
```

---

## 排障

| 现象 | 处理 |
|---|---|
| 自检报「出网失败」 | VPS 的 DNS/出口问题，先 `curl -I https://github.com` 定位 |
| 取件全部镜像失败 | 换 `OMR_VERSION=master` 或手动 `scp` 安装器到 `/root/omr-deploy/` 再跑 |
| 安装器跑完但 API 不通 | `journalctl -u omr-admin -n 100 --no-pager`；看 `/root/omr-deploy/logs/*.log` 卡在哪一步 |
| 装完 SSH 连不上 | 端口已变 65222；确认 `ss -tlnp \| grep 65222`，服务商面板的串口控制台可兜底 |
| 重启后进不了系统 | 内核切换导致的可能性；用服务商控制台改回原内核（`grub` 里保留着旧项） |
| 路由器连不上服务端 | 先按上面「路由器配对」更新 API 密码；再查 `65222/65500` 是否从外部可达 |

## 回滚

- **不换内核**：`KERNEL=6.18` 或改回原内核线重跑；grub 里旧内核项仍在，可从控制台选回。
- **卸载**：官方没有卸载器。去掉 `omr-server` 包即可移除本仓库安装的文件；
  隧道包、内核、`/etc/nftables*` 会留下 —— 干净重来就走服务商的重装。
- **只回滚配置**：`/root/openmptcprouter_config.txt` 与 `/root/omr-deploy/logs/` 是全部现场。

## 安全边界

- 仓库内**不含任何密钥**；密钥只在服务器上生成/存在 `omr-secrets.env`（600，gitignore）。
- 本脚本不做端口扫描、不试密码；SSH 认证失败会被 fail2ban 记录，**不要反复试密码**。

---
*本仓库为 `Sharkecho/MT3000`（LiveOS）项目的配套运维件：MT3000 的路由器侧文档见该仓库 `docs/REMOTE_ACCESS.md`。*
