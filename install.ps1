<#
.SYNOPSIS
    在 Windows PowerShell 5.1+ 上安装 Defect Resolution skill。

.DESCRIPTION
    把本仓库的 skill 复制到 Claude Code 的 skills 目录，并做环境体检。

    为什么需要它：
      本 skill 的取证脚本用 Bash 写成（Git for Windows 自带 Git Bash）。
      Windows 上直接用 PowerShell 跑不了 .sh，所以安装时必须：
        1) 定位 Git Bash（Git for Windows 安装包里的 bash.exe）
        2) 把它所在的 bin 目录写进用户 PATH（或至少告诉 Claude Code 去哪找）
        3) 验证 git / bash / python 都可用

    幂等：重复运行会覆盖更新，不会产生副本。

.PARAMETER Target
    安装目标目录。默认 %USERPROFILE%\.claude\skills\defect-resolution

.PARAMETER Scope
    User（默认，只装给当前用户）或 AllUsers（装到 ProgramData，需要管理员）

.PARAMETER Force
    即使目标已存在也覆盖（默认行为就是覆盖，此参数用于显式确认）

.PARAMETER NoPath
    不修改用户 PATH（只做安装与体检）

.PARAMETER Uninstall
    卸载：删除安装目录并移除 PATH 条目

.EXAMPLE
    .\install.ps1
    # 安装到当前用户并自动配置 PATH

.EXAMPLE
    .\install.ps1 -Scope AllUsers
    # 为所有用户安装（需要管理员权限）

.EXAMPLE
    .\install.ps1 -Uninstall
    # 卸载
#>

[CmdletBinding()]
param(
    [string] $Target,
    [ValidateSet('User', 'AllUsers')]
    [string] $Scope = 'User',
    [switch] $Force,
    [switch] $NoPath,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------
function Write-Ok   { param($m) Write-Host "[OK]   $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn2{ param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red }
function Write-Step { param($m) Write-Host ""; Write-Host "==> $m" -ForegroundColor Magenta }

# ---------------------------------------------------------------------------
# 路径：把 Unix 风格的 Git Bash 路径转成 Windows 路径，反之亦然
# ---------------------------------------------------------------------------
function ConvertTo-WindowsPath {
    param([string] $Path)
    if (-not $Path) { return $Path }
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return "$($Matches[1]):\" + ($Matches[2] -replace '/', '\')
    }
    # /c/Users/... -> C:\Users\...
    if ($p -match '^/([A-Za-z])/(.*)$') {
        return "$($Matches[1]):\" + ($Matches[2] -replace '/', '\')
    }
    return $Path
}

function ConvertTo-BashPath {
    param([string] $Path)
    if (-not $Path) { return $Path }
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { }
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        return "/$($Matches[1].ToLower())/" + ($Matches[2] -replace '\\', '/')
    }
    return ($full -replace '\\', '/')
}

# ---------------------------------------------------------------------------
# 环境探测
# ---------------------------------------------------------------------------
function Get-GitBash {
    <#
        定位 Git Bash。优先级：
          1) PATH 里的 bash.exe 且它属于 Git for Windows（目录含 usr\bin）
          2) 常见安装路径（GitHubDesktop / VS Code / Git for Windows）
          3) 注册表
        返回 bash.exe 的完整路径，找不到则返回 $null
    #>
    $candidates = New-Object System.Collections.Generic.List[string]

    # 1) PATH 上的 bash
    foreach ($b in @('bash.exe')) {
        $cmd = Get-Command $b -ErrorAction SilentlyContinue
        if ($cmd) { $candidates.Add($cmd.Source) }
    }

    # 2) 常见安装位置
    $known = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\GitHubDesktop\app-*\resources\app\git\cmd\bash.exe",
        "$env:ProgramFiles\Microsoft VS Code\resources\app\extensions\git\dist\git-bash.exe",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\resources\app\extensions\git\dist\git-bash.exe"
    )
    foreach ($k in $known) {
        if ($k -like '*`**') {
            Get-ChildItem -Path $k -ErrorAction SilentlyContinue | ForEach-Object { $candidates.Add($_.FullName) }
        } else {
            $candidates.Add($k)
        }
    }

    # 3) 注册表
    foreach ($key in @(
        'HKLM:\SOFTWARE\GitForWindows',
        'HKCU:\SOFTWARE\GitForWindows'
    )) {
        try {
            $v = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
            if ($v) { $candidates.Add((Join-Path $v 'bin\bash.exe')) }
        } catch { }
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        # Git Bash 的判定：同级目录应有 usr\bin 或 ..\usr\bin
        $dir = Split-Path -Parent $c
        if ((Test-Path (Join-Path $dir 'usr\bin')) -or
            (Test-Path (Join-Path (Split-Path -Parent $dir) 'usr\bin'))) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

function Get-ToolPath {
    param([string] $Name, [string[]] $Extra = @())
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($e in $Extra) {
        if (Test-Path -LiteralPath $e) { return (Resolve-Path -LiteralPath $e).Path }
    }
    return $null
}

function Test-CommandRuns {
    param([string] $Exe, [string[]] $CmdArgs)
    try {
        & $Exe @CmdArgs 2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# PATH 管理（用户级）
# ---------------------------------------------------------------------------
function Get-UserPath {
    $raw = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $raw) { return @() }
    return @($raw -split ';' | Where-Object { $_ -ne '' })
}

function Set-UserPathEntries {
    param([string[]] $Entries, [string[]] $Remove)
    $current = Get-UserPath
    $result = New-Object System.Collections.Generic.List[string]

    foreach ($p in $current) {
        # 移除旧条目（大小写不敏感）
        $hit = $false
        foreach ($r in $Remove) {
            if ($p.TrimEnd('\') -ieq $r.TrimEnd('\')) { $hit = $true; break }
        }
        if (-not $hit) { $result.Add($p) }
    }
    foreach ($e in $Entries) {
        $dup = $false
        foreach ($p in $result) {
            if ($p.TrimEnd('\') -ieq $e.TrimEnd('\')) { $dup = $true; break }
        }
        if (-not $dup) { $result.Add($e) }
    }
    [Environment]::SetEnvironmentVariable('Path', ($result -join ';'), 'User')
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillName = 'defect-resolution'

if (-not $Target) {
    if ($Scope -eq 'AllUsers') {
        $Target = Join-Path $env:ProgramData ".claude\skills\$skillName"
    } else {
        $Target = Join-Path $env:USERPROFILE ".claude\skills\$skillName"
    }
}
$Target = ConvertTo-WindowsPath $Target

Write-Host ""
Write-Host "  Defect Resolution —— Windows 安装程序" -ForegroundColor Cyan
Write-Host "  仓库：$repoRoot" -ForegroundColor DarkGray
Write-Host "  目标：$Target" -ForegroundColor DarkGray
Write-Host ""

# --- 卸载 ---
if ($Uninstall) {
    Write-Step "卸载"
    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Recurse -Force
        Write-Ok "已删除 $Target"
    } else {
        Write-Info "目标目录不存在，跳过"
    }
    $gitBash = Get-GitBash
    if ($gitBash) {
        $binDir = Split-Path -Parent $gitBash
        # 只有当初由本脚本添加的（且不是 Git for Windows 安装器自带的默认 PATH）才移除。
        # 保守策略：仅当 PATH 里**只有这一条**是我们加的时才动它 —— 否则保留，
        # 因为 Git Bash 目录通常对用户的其它工具也有用。
        $metaPath = Join-Path $Target '.install-info.json'
        $weAdded = $false
        if (Test-Path -LiteralPath $metaPath) {
            try {
                $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
                if ($meta.PSObject.Properties.Name -contains 'addedToPath' -and $meta.addedToPath -eq $true) {
                    $weAdded = $true
                }
                elseif ($meta.PSObject.Properties.Name -contains 'bashBinDir' -and
                        $meta.bashBinDir -and ($meta.bashBinDir.TrimEnd('\') -ieq $binDir.TrimEnd('\'))) {
                    # 老版本元信息没有 addedToPath 字段：只有在 PATH 里**只出现一次**
                    # 且是本脚本管理的目录时才移除，避免误删用户原有的配置
                    $userPath = Get-UserPath
                    $count = 0
                    foreach ($p in $userPath) {
                        if ($p.TrimEnd('\') -ieq $binDir.TrimEnd('\')) { $count++ }
                    }
                    if ($count -eq 1) { $weAdded = $true }
                }
            } catch { }
        }
        if ($weAdded) {
            Set-UserPathEntries -Entries @() -Remove @($binDir)
            Write-Ok "已从用户 PATH 移除 Git Bash 目录：$binDir"
        } else {
            Write-Info "保留 PATH 中的 Git Bash 目录（它可能被你的其它工具依赖）"
            Write-Host "        如需手动移除：$binDir" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "卸载完成。" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# --- 1. 环境体检 ---
Write-Step "1/5 环境体检"

$gitExe = Get-ToolPath 'git.exe' @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe")
if (-not $gitExe) {
    Write-Err "找不到 git.exe"
    Write-Host ""
    Write-Host "请先安装 Git for Windows：" -ForegroundColor Yellow
    Write-Host "  https://git-scm.com/download/win" -ForegroundColor Cyan
    Write-Host "安装时勾选「Git from the command line」，然后重新运行本脚本。" -ForegroundColor Yellow
    exit 1
}
Write-Ok "git: $gitExe"

$gitBash = Get-GitBash
if (-not $gitBash) {
    Write-Err "找不到 Git Bash（bash.exe）"
    Write-Host ""
    Write-Host "本 skill 的取证脚本用 Bash 写成，需要 Git for Windows 自带的 Git Bash。" -ForegroundColor Yellow
    Write-Host "请确认已安装 Git for Windows：https://git-scm.com/download/win" -ForegroundColor Cyan
    Write-Host "若装在非常规位置，可把 bash.exe 所在目录加入 PATH 后重试。" -ForegroundColor Yellow
    exit 1
}
Write-Ok "bash: $gitBash"

$pythonExe = Get-ToolPath 'python.exe' @("$env:LOCALAPPDATA\Programs\Python\Python314\python.exe")
if (-not $pythonExe) { $pythonExe = Get-ToolPath 'python3.exe' }
if (-not $pythonExe) {
    $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($py) { $pythonExe = $py.Source }
}
if (-not $pythonExe) {
    Write-Warn2 "找不到 Python —— 符号抽取器 extract_symbols.py 将不可用"
    Write-Host "        其余取证脚本（纯 Bash + git）不受影响。建议安装 Python 3.8+：https://python.org" -ForegroundColor DarkGray
} else {
    Write-Ok "python: $pythonExe"
}

# git 版本与仓库完整性能力
try {
    $gv = (& $gitExe --version) -join ' '
    Write-Info $gv
} catch { }

# --- 2. 安装文件 ---
Write-Step "2/5 安装 skill 文件"

# 目标目录可能不存在（首次安装）—— 先建出来
if (-not (Test-Path -LiteralPath $Target)) {
    try {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Write-Ok "已创建目标目录"
    } catch {
        Write-Err "无法创建目标目录 $Target ：$($_.Exception.Message)"
        exit 1
    }
}

$items = @('SKILL.md', 'scripts', 'references', '.claude-plugin', 'LICENSE', 'README.md')
foreach ($item in $items) {
    $src = Join-Path $repoRoot $item
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warn2 "跳过（源不存在）：$item"
        continue
    }
    $dst = Join-Path $Target $item
    try {
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        Write-Ok "已安装 $item"
    } catch {
        Write-Err "安装 $item 失败：$($_.Exception.Message)"
        exit 1
    }
}

# --- 3. 配置 PATH ---
Write-Step "3/5 配置 PATH"
$binDir = Split-Path -Parent $gitBash
$addedToPath = $false
if ($NoPath) {
    Write-Info "已按 -NoPath 跳过 PATH 修改"
    Write-Host "        Claude Code 仍可通过绝对路径调用脚本。" -ForegroundColor DarkGray
} else {
    $userPath = Get-UserPath
    $already = $false
    foreach ($p in $userPath) {
        if ($p.TrimEnd('\') -ieq $binDir.TrimEnd('\')) { $already = $true; break }
    }
    if ($already) {
        Write-Ok "PATH 已包含 Git Bash 目录：$binDir"
    } else {
        Set-UserPathEntries -Entries @($binDir) -Remove @()
        $addedToPath = $true
        Write-Ok "已把 Git Bash 目录加入用户 PATH：$binDir"
        Write-Host "        （新开的终端才会生效；当前会话可用 `$env:Path = `$env:Path + ';$binDir' 立即生效）" -ForegroundColor DarkGray
    }
}

# --- 4. 写入安装元信息 ---
Write-Step "4/5 写入安装元信息"
$meta = [ordered]@{
    installedAt   = (Get-Date).ToString('o')
    version       = '0.1.0'
    repoRoot      = $repoRoot
    bashPath      = $gitBash
    bashBinDir    = $binDir
    addedToPath   = $addedToPath
    gitPath       = $gitExe
    pythonPath    = $pythonExe
    targetDir     = $Target
    psVersion     = $PSVersionTable.PSVersion.ToString()
}
try {
    $meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Target '.install-info.json') -Encoding UTF8
    Write-Ok "已写入 .install-info.json"
} catch {
    Write-Warn2 "写入元信息失败（不影响功能）：$($_.Exception.Message)"
}

# --- 5. 自检 ---
Write-Step "5/5 安装自检"
$selfTestOk = $true

# 5a) skill 结构
foreach ($need in @('SKILL.md', 'scripts\collect.sh', 'scripts\verify.sh', 'scripts\version_bisect.sh')) {
    $p = Join-Path $Target $need
    if (Test-Path -LiteralPath $p) {
        Write-Ok "存在 $need"
    } else {
        Write-Err "缺失 $need"
        $selfTestOk = $false
    }
}

# 5b) 脚本可执行（在 Git Bash 里跑一次 --help 级别检查）
#     用 bash <script> --help 而不是 bash -lc "..."，避免引号嵌套问题
$probe = Join-Path $Target 'scripts\anchor.sh'
if (Test-Path -LiteralPath $probe) {
    try {
        $out = & $gitBash (ConvertTo-BashPath $probe) --help 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "脚本可被 Git Bash 正常执行"
        } else {
            Write-Err "脚本执行异常（exit=$LASTEXITCODE）"
            Write-Host ($out | Select-Object -First 5) -ForegroundColor DarkGray
            $selfTestOk = $false
        }
    } catch {
        Write-Err "脚本执行抛异常：$($_.Exception.Message)"
        $selfTestOk = $false
    }
}

# 5c) 冒烟测试（跑真实回归套件里的一个场景）
#     注意：不要用 bash -lc "..." 内嵌复杂引号 —— 分号等字符会被 shell 提前解释。
#     改为把脚本写到临时文件，再用 bash <file> <args...> 调用。
$testScript = Join-Path $Target 'scripts\collect.sh'
if ($selfTestOk -and (Test-Path -LiteralPath $testScript)) {
    $smoke = @'
D=$(mktemp -d) || exit 1
cd "$D" || exit 1
git init -q -b main . >/dev/null 2>&1
git config user.email t@t
git config user.name t
mkdir -p src
printf 'int f(void){return 1;}\n' > src/a.c
git add -A >/dev/null 2>&1
git commit -qm v1 >/dev/null 2>&1
git tag v1.0
printf 'int f(void){return 2;}\n' > src/a.c
git commit -qam fix >/dev/null 2>&1
git tag v2.0
# 用法：collect.sh <repo> <A> <B> [选项] —— repo 必须是第一个位置参数
OUT=$(bash "$1" "$D" v1.0 v2.0 --path src/a.c --sym "return 2;" --min-weight 2 2>&1)
if echo "$OUT" | grep -q 'CAND|'; then
  echo SMOKE_OK
else
  echo "$OUT" | tail -20
  echo SMOKE_FAIL
fi
cd /; rm -rf "$D"
'@
    $tmpProbe = Join-Path $env:TEMP "dr_smoke_$([guid]::NewGuid().ToString('N')).sh"
    # 用 ASCII 写，避免 Git Bash 读 UTF-8 无 BOM 出问题
    Set-Content -LiteralPath $tmpProbe -Value $smoke -Encoding ASCII
    try {
        # 用 bash <script> <arg> 而不是 bash -lc "..."，避免引号嵌套问题
        $res = & $gitBash $tmpProbe (ConvertTo-BashPath $testScript) 2>&1
        if ($res -match 'SMOKE_OK') {
            Write-Ok "取证管线冒烟测试通过"
        } else {
            Write-Err "冒烟测试未通过"
            Write-Host ($res | Select-Object -First 10) -ForegroundColor DarkGray
            $selfTestOk = $false
        }
    } catch {
        Write-Err "冒烟测试异常：$($_.Exception.Message)"
        $selfTestOk = $false
    } finally {
        Remove-Item -LiteralPath $tmpProbe -Force -ErrorAction SilentlyContinue
    }
}

# --- 完成 ---
Write-Host ""
if ($selfTestOk) {
    Write-Host "  安装成功。" -ForegroundColor Green
    Write-Host ""
    Write-Host "  使用方式（重启 Claude Code 后生效）：" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   帮我确认这个 bug 是在哪个版本、哪次提交修好的：" -ForegroundColor White
    Write-Host "   仓库：<本地目录 或 https://github.com/yanyan2015/defect-resolution.git>" -ForegroundColor DarkGray
    Write-Host "   问题版本：v1.0.0   修复版本：v2.0.0" -ForegroundColor DarkGray
    Write-Host "   报错：<粘贴错误日志>" -ForegroundColor DarkGray
    Write-Host "   出问题的地方：<文件:行范围>" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  手动调用脚本（在 PowerShell 里）：" -ForegroundColor Cyan
    $example = "& '$gitBash' '$((ConvertTo-BashPath (Join-Path $Target 'scripts\collect.sh')))' <repo> v1.0 v2.0 --path <file>"
    Write-Host "   $example" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
} else {
    Write-Host "  安装完成，但自检未全部通过。" -ForegroundColor Yellow
    Write-Host "  请把上面的 [FAIL] 信息反馈到 https://github.com/yanyan2015/defect-resolution/issues" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
