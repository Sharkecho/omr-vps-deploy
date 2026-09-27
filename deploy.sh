#!/bin/bash
# =============================================================================
# omr-vps-deploy / deploy.sh
#
# 在 VPS 上一次性把 OpenMPTCProuter 服务端装好（非交互、可重复、装完自验收）。
#
#   一键（在 VPS 上，root）：
#       curl -fsSL https://raw.githubusercontent.com/Sharkecho/omr-vps-deploy/main/deploy.sh | bash
#
#   推荐做法（先看一眼再跑）：
#       curl -fsSLO https://raw.githubusercontent.com/Sharkecho/omr-vps-deploy/main/deploy.sh
#       bash deploy.sh --check          # 只做环境自检，不动系统
#       bash deploy.sh                  # 自检 + 安装 + 验收 + 汇总
#
#   子命令：
#       --check     只自检
#       --verify    只验收（等价 verify.sh）
#       --fetch     只下载官方安装器并打印 sha256
#       --help
#
#   配置优先级：命令行环境变量 > omr.env > 内置默认
#
# 设计要点（踩过的坑都写在这儿）：
#   * 官方安装器本身没有 set -e —— 某些步骤失败它会继续跑，
#     所以"装完必须验收"，不能只看退出码。本脚本的 verify 阶段是硬要求。
#   * 官方安装器会把 SSH 端口 22 改成 65222。安装期间已建立的连接不会被踢，
#     但**之后必须用 -p 65222 重连**。
#   * 官方安装器默认会装自己的 MPTCP 内核并把 grub 默认项切过去。
#     本脚本默认 KERNEL=6.12（与路由器固件 v0.63-6.12 同一条内核线）。
#     若这台 VPS 的引导器由服务商控制（很多廉价 VPS 是宿主直启），换内核是空操作，
#     重启后仍是原内核 —— 这不算失败，verify 会如实报告。
#   * 默认 pin 官方脚本到 v0.1052：这是这台服务器此前与路由器正常对接的版本。
#     要换版本：OMR_VERSION=v0.1082 bash deploy.sh  或改 omr.env。
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------- 常量
REPO_SLUG="Sharkecho/omr-vps-deploy"
UPSTREAM_SLUG="Ysurac/openmptcprouter-vps"
UPSTREAM_FILE="debian9-x86_64.sh"
WORKDIR="/root/omr-deploy"
STATE_ENV="$WORKDIR/omr.env"
SECRETS_ENV="$WORKDIR/omr-secrets.env"

# 默认值（都可用环境变量或 omr.env 覆盖）
OMR_VERSION="${OMR_VERSION:-v0.1052}"
KERNEL="${KERNEL:-6.12}"
UPDATE="${UPDATE:-yes}"
REINSTALL="${REINSTALL:-yes}"
FAIL2BAN="${FAIL2BAN:-yes}"
OMR_ADMIN="${OMR_ADMIN:-yes}"
OMR_METRICS="${OMR_METRICS:-no}"
OMR_AI="${OMR_AI:-no}"
SOURCES="${SOURCES:-no}"
CHINA="${CHINA:-no}"
TLS="${TLS:-yes}"
SHADOWSOCKS="${SHADOWSOCKS:-yes}"
SHADOWSOCKS_GO="${SHADOWSOCKS_GO:-yes}"
V2RAY="${V2RAY:-yes}"
XRAY="${XRAY:-yes}"
GLORYTUN_TCP="${GLORYTUN_TCP:-yes}"
GLORYTUN_UDP="${GLORYTUN_UDP:-yes}"
DSVPN="${DSVPN:-yes}"
MLVPN="${MLVPN:-yes}"
UBOND="${UBOND:-no}"
MQVPN="${MQVPN:-yes}"
WIREGUARD="${WIREGUARD:-yes}"
OPENVPN="${OPENVPN:-yes}"
OPENVPN_BONDING="${OPENVPN_BONDING:-yes}"
SOFTETHERVPN="${SOFTETHERVPN:-no}"

MODE="all"
[ $# -ge 1 ] && case "$1" in
    --check)  MODE="check" ;;
    --verify) MODE="verify" ;;
    --fetch)  MODE="fetch" ;;
    -h|--help)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) echo "未知参数：$1（用 --help 看用法）" >&2; exit 2 ;;
esac

mkdir -p "$WORKDIR/logs"
LOG="$WORKDIR/logs/deploy-$(date +%Y%m%d-%H%M%S).log"

# 从 GitHub raw 自举时 $0 是 bash，不能依赖；统一用 SCRIPT_DIR 定位同目录文件
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$WORKDIR"
fi

log()  { printf '%s %s\n' "[$(date +%H:%M:%S)]" "$*" | tee -a "$LOG"; }
ok()   { log "  ✔ $*"; }
bad()  { log "  ✘ $*"; }
warn() { log "  ! $*"; }
hr()   { log "------------------------------------------------------------------------"; }

# ---------------------------------------------------------------- 配置装载
load_config() {
    if [ -f "$STATE_ENV" ]; then
        log "装载配置：$STATE_ENV"
        # shellcheck disable=SC1090
        set -a; . "$STATE_ENV"; set +a
    elif [ -f "$SCRIPT_DIR/omr.env" ]; then
        log "装载配置：$SCRIPT_DIR/omr.env"
        # shellcheck disable=SC1090
        set -a; . "$SCRIPT_DIR/omr.env"; set +a
    fi
    # 命令行环境变量优先级最高：用 :- 兜一次，防止被上面的文件覆盖成空
    : "${OMR_VERSION:=v0.1052}"; : "${KERNEL:=6.12}"
    INSTALLER="$WORKDIR/$UPSTREAM_FILE"
    INSTALLER_META="$WORKDIR/installer.meta"
}

# ---------------------------------------------------------------- 自检
hr; log "阶段 1/3 · 环境自检"; hr
PREFLIGHT_FAIL=0
pf_note() { log "  · $*"; }
pf_fail() { bad "$*"; PREFLIGHT_FAIL=1; }

preflight() {
    # 1. root
    if [ "$(id -u)" -eq 0 ]; then ok "以 root 运行"; else pf_fail "必须以 root 运行（当前 uid=$(id -u)）"; fi

    # 2. OS —— 与官方安装器的支持矩阵完全一致（它装不上就不浪费后面的步骤）
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_OK=0
        case "${ID:-}" in
            debian) case "$VERSION_ID" in 9|10|11|12|13) OS_OK=1 ;; esac ;;
            ubuntu) case "$VERSION_ID" in 18.04|19.04|20.04|22.04) OS_OK=1 ;; esac ;;
        esac
        if [ "$OS_OK" = 1 ]; then
            ok "OS: ${PRETTY_NAME:-$ID $VERSION_ID}"
        else
            pf_fail "OS ${ID:-?} ${VERSION_ID:-?} 不在官方安装器支持范围" \
                    "（Debian 9-13 / Ubuntu 18.04/19.04/20.04/22.04，官方原话 Use Debian when possible）。" \
                    "请在服务商面板把系统重装为 Debian 12 或 13 再跑本脚本。"
        fi
    else
        pf_fail "读不到 /etc/os-release"
    fi

    # 3. 架构
    ARCH_LOCAL="$(dpkg --print-architecture 2>/dev/null | tr -d '\n')"
    case "$ARCH_LOCAL" in
        amd64|arm64) ok "架构: $ARCH_LOCAL" ;;
        "")          pf_fail "拿不到 dpkg 架构" ;;
        *)           pf_fail "架构 $ARCH_LOCAL 不在官方支持范围（amd64/arm64）" ;;
    esac

    # 4. 内存 / 磁盘
    MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    DISK_MB=$(df -Pk / | awk 'NR==2{print $4}')
    pf_note "内存 ${MEM_MB} MB / 根分区可用 $((DISK_MB/1024)) MB"
    [ "$MEM_MB" -ge 450 ] || warn "内存偏小（<450MB），安装器可能吃紧"
    [ "$DISK_MB" -ge 3000000 ] || warn "根分区可用 <3GB，装内核+全家桶可能不够"

    # 5. 出网
    if command -v curl >/dev/null 2>&1; then
        for url in "https://www.openmptcprouter.com/" "https://github.com/"; do
            code=$(curl -m 12 -ks -o /dev/null -w '%{http_code}' "$url" || echo 000)
            case "$code" in
                2*|3*|4*) ok "出网: $url -> HTTP $code" ;;
                *)        pf_fail "出网失败: $url -> HTTP $code" ;;
            esac
        done
    else
        pf_fail "没有 curl（apt-get install -y curl）"
    fi

    # 6. 既有安装
    if [ -f /root/openmptcprouter_config.txt ] || grep -qs OpenMPTCProuter /etc/motd 2>/dev/null; then
        warn "检测到既有 OpenMPTCProuter 安装 —— 本次属于【覆盖升级/重装】"
        warn "  配置文件: /root/openmptcprouter_config.txt（升级不会重新生成密钥）"
    else
        ok "未发现既有安装（干净机器）"
    fi

    # 7. 目标端口是否被非 OMR 进程占用
    for p in 65500 65001 65101 65222; do
        if command -v ss >/dev/null 2>&1 && ss -tlnp 2>/dev/null | grep -q ":$p "; then
            who=$(ss -tlnp 2>/dev/null | awk -v P=":$p " '$4 ~ P {print $6}' | head -1)
            warn "端口 $p 已被监听：$who（若是旧 OMR 服务属正常）"
        fi
    done

    # 8. 引导方式提示
    if [ -d /sys/firmware/efi ]; then pf_note "UEFI 引导"; else pf_note "BIOS/宿主直启"; fi
    pf_note "当前内核: $(uname -r)"
    pf_note "目标内核线: KERNEL=$KERNEL （安装器会装对应的 xanmod-mptcp 内核并尽量切 grub 默认项）"
}

# ---------------------------------------------------------------- 抓安装器
fetch_installer() {
    hr; log "阶段 2/3 · 获取官方安装器（${UPSTREAM_SLUG} @ ${OMR_VERSION}）"; hr
    local urls=()
    if [ "$OMR_VERSION" = "master" ]; then
        urls+=("https://www.openmptcprouter.com/server/debian.sh")
        urls+=("https://raw.githubusercontent.com/$UPSTREAM_SLUG/master/$UPSTREAM_FILE")
    else
        urls+=("https://raw.githubusercontent.com/$UPSTREAM_SLUG/$OMR_VERSION/$UPSTREAM_FILE")
        urls+=("https://cdn.jsdelivr.net/gh/$UPSTREAM_SLUG@$OMR_VERSION/$UPSTREAM_FILE")
    fi
    urls+=("https://www.openmptcprouter.com/server/debian.sh")

    local got=""
    for u in "${urls[@]}"; do
        log "  尝试: $u"
        if curl -fsSL -m 90 -o "$INSTALLER.part" "$u" 2>>"$LOG"; then
            sz=$(wc -c < "$INSTALLER.part" | tr -d ' ')
            if [ "$sz" -gt 50000 ] && head -1 "$INSTALLER.part" | grep -q '^#!/bin/sh'; then
                mv "$INSTALLER.part" "$INSTALLER"
                got="$u"; ok "已下载（$sz 字节）"; break
            else
                warn "内容不像安装器（${sz} 字节），换下一个源"
            fi
        else
            warn "取不到"
        fi
    done
    [ -n "$got" ] || { bad "所有镜像都取不到安装器"; return 1; }

    SHA=$(sha256sum "$INSTALLER" | awk '{print $1}')
    log "  sha256: $SHA"
    log "  来源  : $got"
    {
        echo "fetched_at=$(date -Is)"
        echo "requested_version=$OMR_VERSION"
        echo "url=$got"
        echo "sha256=$SHA"
        echo "bytes=$(wc -c < "$INSTALLER" | tr -d ' ')"
    } > "$INSTALLER_META"
    if [ "$MODE" = "fetch" ]; then
        log "（--fetch 模式，到此为止）"
        exit 0
    fi
    return 0
}

# ---------------------------------------------------------------- 执行安装
run_installer() {
    hr; log "阶段 3/3 · 执行官方安装器（非交互）"; hr
    log "  日志：$LOG"
    warn "安装期间 SSH 端口会从 22 改成 65222；已建立的会话不掉线，但之后要用 -p 65222 重连"
    warn "安装器没有 set -e：中途某步失败它会继续跑 —— 所以装完必须看验收结果"

    # 可选：注入既有密钥（让路由器无需重新配对）
    if [ -f "$SECRETS_ENV" ]; then
        warn "检测到 $SECRETS_ENV —— 将沿用其中的旧密钥（路由器无需改配置）"
        warn "文件权限：$(stat -c '%a %U' "$SECRETS_ENV" 2>/dev/null)"
        # shellcheck disable=SC1090
        set -a; . "$SECRETS_ENV"; set +a
    else
        log "  未提供 $SECRETS_ENV —— 安装器将为本次生成全新密钥"
        log "  （路由器侧需要把新的 API 密码填回去，见 README「安装后 · 路由器配对」）"
    fi

    local t0; t0=$(date +%s)
    # 显式传全部关键开关：让每次部署具有确定性。
    # 注意：这里刻意不用 set -x —— 环境里可能带着 omr-secrets.env 的明文密钥，
    #       set -x 会把它们原样打进日志。
    log "  传入开关: KERNEL=$KERNEL UPDATE=$UPDATE REINSTALL=$REINSTALL FAIL2BAN=$FAIL2BAN OMR_ADMIN=$OMR_ADMIN CHINA=$CHINA TLS=$TLS SOURCES=$SOURCES"
    if [ -f "$SECRETS_ENV" ]; then
        log "  密钥来源: 已装载 omr-secrets.env（值不回显）"
    else
        log "  密钥来源: 安装器随机生成（值不明，装完见 /root/openmptcprouter_config.txt）"
    fi
    (
      KERNEL="$KERNEL" UPDATE="$UPDATE" REINSTALL="$REINSTALL" \
      FAIL2BAN="$FAIL2BAN" OMR_ADMIN="$OMR_ADMIN" \
      OMR_METRICS="$OMR_METRICS" OMR_AI="$OMR_AI" SOURCES="$SOURCES" CHINA="$CHINA" TLS="$TLS" \
      SHADOWSOCKS="$SHADOWSOCKS" SHADOWSOCKS_GO="$SHADOWSOCKS_GO" \
      V2RAY="$V2RAY" XRAY="$XRAY" GLORYTUN_TCP="$GLORYTUN_TCP" GLORYTUN_UDP="$GLORYTUN_UDP" \
      DSVPN="$DSVPN" MLVPN="$MLVPN" UBOND="$UBOND" MQVPN="$MQVPN" WIREGUARD="$WIREGUARD" \
      OPENVPN="$OPENVPN" OPENVPN_BONDING="$OPENVPN_BONDING" SOFTETHERVPN="$SOFTETHERVPN" \
      sh "$INSTALLER"
    ) 2>&1 | tee -a "$LOG"
    RC=${PIPESTATUS[0]}
    local dt=$(( $(date +%s) - t0 ))
    log "安装器退出码：$RC（耗时 ${dt}s）—— 注意：退出码 0 也不代表装好了，看下面的验收"
    return 0
}

# ---------------------------------------------------------------- 验收
verify() {
    hr; log "验收（verify）"; hr
    local pass=0 fail=0
    v_ok()   { ok "$1"; pass=$((pass+1)); }
    v_bad()  { bad "$1"; fail=$((fail+1)); }
    v_note() { log "  · $1"; }

    # 1) omr-admin API
    code=$(curl -m 10 -ks -o "$WORKDIR/_api.html" -w '%{http_code}' https://127.0.0.1:65500/ 2>/dev/null) || code=000
    if [ "$code" = "200" ] && grep -qi 'OpenMPTCProuter Server' "$WORKDIR/_api.html" 2>/dev/null; then
        v_ok "omr-admin API: https://127.0.0.1:65500/ -> 200 且回执正确"
    else
        v_bad "omr-admin API 不可用（HTTP $code）"
    fi

    # 2) 监听端口
    for spec in "65500:omr-admin API" "65001:glorytun" "65101:shadowsocks" "65401:dsvpn" "65443:mqvpn" "65311:wireguard"; do
        p=${spec%%:*}; name=${spec#*:}
        if ss -tln 2>/dev/null | grep -q ":$p "; then v_ok "端口 $p 监听中（$name）"
        else v_bad "端口 $p 未监听（$name）"
        fi
    done
    if ss -uln 2>/dev/null | grep -q ":65001 "; then v_ok "端口 65001/udp 监听中（glorytun-udp）"
    else v_note "65001/udp 未监听（若未启用 glorytun-udp 可忽略）"
    fi

    # 3) systemd 单元
    for u in omr-admin omr-service nftables; do
        if systemctl is-active --quiet "$u"; then v_ok "unit $u: active"
        else v_bad "unit $u: 不是 active（systemctl status $u）"
        fi
    done

    # 4) 防火墙
    if nft list ruleset >/dev/null 2>&1 && [ "$(nft list ruleset 2>/dev/null | wc -l)" -gt 10 ]; then
        v_ok "nftables 规则已加载（$(nft list ruleset 2>/dev/null | wc -l) 行）"
    else
        v_bad "nftables 规则看起来没加载"
    fi

    # 5) SSH 端口现状
    if ss -tln 2>/dev/null | grep -q ':65222 '; then v_ok "sshd 已移到 65222"
    elif ss -tln 2>/dev/null | grep -q ':22 '; then v_note "sshd 仍在 22（安装器应已改 65222，检查 /etc/ssh/sshd_config）"
    else v_note "没看到 sshd 监听（可能由 socket activation 托管）"
    fi

    # 6) 配置文件
    if [ -f /root/openmptcprouter_config.txt ]; then
        v_ok "配置文件存在：/root/openmptcprouter_config.txt"
        chmod 600 /root/openmptcprouter_config.txt 2>/dev/null
    else
        v_bad "缺少 /root/openmptcprouter_config.txt"
    fi

    # 7) 内核
    v_note "当前内核: $(uname -r)"
    if [ -f /var/run/reboot-required ]; then v_note "系统标记需要重启（MPTCP 内核要重启才生效）"
    fi
    if ls /boot/vmlinuz-*xanmod* >/dev/null 2>&1; then
        v_note "已装内核: $(ls /boot/vmlinuz-*xanmod* 2>/dev/null | sed 's|.*vmlinuz-||' | tr '\n' ' ')"
    fi

    hr
    log "验收结果：PASS=$pass  FAIL=$fail"
    [ "$fail" -eq 0 ] || warn "存在失败项 —— 上面对应行有证据，先修它，不要假装装好了"
}

# ---------------------------------------------------------------- 汇总
summary() {
    hr; log "汇总"; hr
    {
        echo "==== OpenMPTCProuter VPS 部署报告 ===="
        echo "时间        : $(date -Is)"
        echo "主机        : $(hostname) / $(hostname -I 2>/dev/null | awk '{print $1}')"
        echo "脚本版本 pin: $OMR_VERSION   （安装器 sha256 见 $INSTALLER_META）"
        echo "内核线      : KERNEL=$KERNEL   运行中: $(uname -r)"
        echo
        echo "---- 端口 ----"
        ss -tlnp 2>/dev/null | awk 'NR==1 || /:(65500|65001|65101|65222|65301|65311|65312|65401|65443) /'
        echo
        echo "---- API 凭据（路由器配对用）----"
        if [ -f /root/openmptcprouter_config.txt ]; then
            grep -iE 'key|pass|user|port|admin' /root/openmptcprouter_config.txt | head -40
        else
            echo "（配置文件缺失）"
        fi
        echo
        echo "---- unit 状态 ----"
        systemctl --no-pager --plain -q list-units 'omr*' 'glorytun*' 'shadowsocks*' 'mqvpn*' 'wireguard*' 'nftables' 2>/dev/null | head -30
    } | tee -a "$LOG" > "$WORKDIR/report.txt"
    log "报告已写入: $WORKDIR/report.txt"
    log "配对信息在 /root/openmptcprouter_config.txt（已 chmod 600）"
    hr
    log "完成。下一步："
    log "  1) 用 -p 65222 重新连 SSH（端口已被安装器改掉）"
    log "  2) 需要 MPTCP 新内核生效 → reboot 一次"
    log "  3) 路由器侧：把新的 API 用户名/密码填进 LuCI 的 OpenMPTCProuter 服务器设置"
    log "     （想免改路由器：把旧密钥放进 $SECRETS_ENV 后重跑本脚本）"
}

# ---------------------------------------------------------------- main
main() {
    log "==== omr-vps-deploy $(date -Is) mode=$MODE ===="
    load_config
    preflight
    if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
        bad "自检未通过 —— 先解决上面标 ✘ 的项"
        exit 10
    fi
    case "$MODE" in
        check)  ok "自检通过（--check 模式，未做任何改动）"; exit 0 ;;
        verify) verify; summary; exit 0 ;;
    esac
    fetch_installer || exit 11
    run_installer
    verify
    summary
}

main "$@"
