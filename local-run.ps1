# =============================================================================
# omr-vps-deploy / local-run.ps1
#
# Windows 本机侧一键：把本仓库脚本打包送上 VPS，并在 VPS 上跑 deploy.sh。
#
# 例：
#   .\local-run.ps1                                   # 自检 + 安装 + 验收
#   .\local-run.ps1 -Mode check                       # 只自检
#   .\local-run.ps1 -Mode verify                       # 只验收
#   .\local-run.ps1 -SshPort 22 -KeyFile "$env:USERPROFILE\.ssh\chatgpt_vps"
#
# 说明：
#   * 用 Windows 自带 OpenSSH（ssh.exe / scp.exe），不用装任何东西。
#   * 端口不填就自动探测：先 22，再 65222（装完 OMR 后 SSH 会被挪到 65222）。
#   * 认证默认走密钥；服务器重装后若只有密码，先手动 ssh 一次试试，
#     或在 VPS 上直接跑 README 里的 curl 一行命令。
#   * 本脚本不打印、不保存任何密码。
# =============================================================================
[CmdletBinding()]
param(
    [string]$VpsHost = "192.46.215.164",
    [int]$SshPort = 0,
    [string]$User = "root",
    [string]$KeyFile = "$env:USERPROFILE\.ssh\chatgpt_vps",
    [ValidateSet("check", "deploy", "verify")]
    [string]$Mode = "deploy"
)

$ErrorActionPreference = "Stop"
$RepoDir = $PSScriptRoot

function Info($m) { Write-Host "[local-run] $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "[local-run] $m" -ForegroundColor Red; exit 1 }

# ---------- 依赖 ----------
foreach ($exe in @("ssh", "scp", "tar")) {
    if (-not (Get-Command "$exe.exe" -ErrorAction SilentlyContinue)) {
        Fail "找不到 $exe.exe（Windows 自带 OpenSSH 未安装？设置→应用→可选功能→OpenSSH 客户端）"
    }
}
if (-not (Test-Path -LiteralPath $KeyFile)) {
    Write-Host "[local-run] 提示：默认密钥不存在 -> $KeyFile" -ForegroundColor Yellow
    Write-Host "[local-run] 继续会走 ssh 默认密钥/交互式登录。" -ForegroundColor Yellow
    $useKey = $false
} else {
    $useKey = $true
}

$sshCommon = @("-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15")
if ($useKey) { $sshCommon += @("-i", $KeyFile) }

# ---------- 端口探测 ----------
function Test-Port([int]$p) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($VpsHost, $p)
        if ($t.Wait(4000) -and $c.Connected) { return $true } else { return $false }
    } catch { return $false } finally { $c.Close() }
}

if ($SshPort -eq 0) {
    foreach ($cand in @(22, 65222)) {
        if (Test-Port $cand) { $SshPort = $cand; Info "SSH 端口探测：$cand 可达"; break }
    }
    if ($SshPort -eq 0) {
        Fail "22 与 65222 都不通 —— 服务器可能在重装/关机，或防火墙未放行。（重装完成后 22 通常会开）"
    }
} else {
    Info "使用指定端口 $SshPort"
}

# ---------- 打包上传 ----------
$stage = Join-Path $env:TEMP ("omr-vps-deploy-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$tgz = Join-Path $stage "omr-vps-deploy.tgz"

Info "打包 $RepoDir"
& tar.exe -czf $tgz -C $RepoDir --exclude=.git --exclude=logs .
if ($LASTEXITCODE -ne 0) { Fail "tar 打包失败" }

Info "上传到 ${User}@${VpsHost}:/root/omr-deploy/"
& scp.exe @sshCommon -P $SshPort $tgz "${User}@${VpsHost}:/root/omr-deploy.tgz"
if ($LASTEXITCODE -ne 0) { Fail "scp 上传失败（认证或网络问题）" }

$remoteCmd = @(
    "set -e",
    "mkdir -p /root/omr-deploy",
    "tar -xzf /root/omr-deploy.tgz -C /root/omr-deploy",
    "rm -f /root/omr-deploy.tgz",
    "ls -la /root/omr-deploy"
) -join " && "

Info "解包"
& ssh.exe @sshCommon -p $SshPort "${User}@${VpsHost}" $remoteCmd
if ($LASTEXITCODE -ne 0) { Fail "远端解包失败" }

# ---------- 执行 ----------
$modeArg = switch ($Mode) { "check" { "--check" } "verify" { "--verify" } default { "" } }
Info "在 VPS 上执行 deploy.sh $modeArg"
& ssh.exe @sshCommon -p $SshPort "${User}@${VpsHost}" "bash /root/omr-deploy/deploy.sh $modeArg"
$rc = $LASTEXITCODE

Write-Host ""
if ($Mode -eq "deploy" -and $rc -eq 0) {
    Write-Host "[local-run] 完成。后续：" -ForegroundColor Green
    Write-Host "  1) SSH 端口已被官方安装器改成 65222：ssh -p 65222 root@$VpsHost"
    Write-Host "  2) 需要 MPTCP 新内核生效就 reboot 一次"
    Write-Host "  3) 路由器 LuCI：把新的 API 用户名/密码填回去（见 README「安装后 · 路由器配对」）"
} else {
    Write-Host "[local-run] 退出码 $rc —— 看上面的输出定位失败项。" -ForegroundColor Yellow
}
exit $rc
