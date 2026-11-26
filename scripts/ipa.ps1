# ipa-build 的 Windows 入口。跟 scripts/ipa 干同样的事，换 PowerShell 实现：
# Windows 上没有 ldid，签名交给 zsign；打包用 .NET 的 ZipFile，不依赖 zip 命令。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

if ($env:IPA_HOME) { $tc = $env:IPA_HOME }
elseif ($env:USERPROFILE) { $tc = Join-Path $env:USERPROFILE '.ipa-toolchain' }
else { $tc = Join-Path $HOME '.ipa-toolchain' }
if ($env:IPA_SDK) { $sdk = $env:IPA_SDK } else { $sdk = Join-Path $tc 'sdk/iPhoneOS16.5.sdk' }
$zsign = Join-Path $tc 'bin/zsign.exe'
if (-not (Test-Path $zsign)) {
    $vendored = Join-Path $root 'vendor/zsign/zsign.exe'
    if (Test-Path $vendored) { $zsign = $vendored }
}
if ($env:IPA_ZSIGN) { $zsign = $env:IPA_ZSIGN }
# 工具链自己的环境变量文件，bootstrap 写在这里（不动用户持久 PATH）
$envFile = Join-Path $tc 'env.ps1'
if ((Test-Path $envFile) -and -not $env:IPA_NO_ENV) { . $envFile }

function Die($m) { Write-Host $m; exit 1 }

function Test-Bplist($path) {
    if (-not (Test-Path $path)) { return $false }
    $fs = [IO.File]::OpenRead($path)
    try {
        $b = New-Object byte[] 6
        $fs.Read($b, 0, 6) | Out-Null
        return ([Text.Encoding]::ASCII.GetString($b) -eq 'bplist')
    } finally { $fs.Dispose() }
}

# 按偏移读一小段，不把整个可执行文件塞进内存
function Read-At($fs, $off, $len) {
    $b = New-Object byte[] $len
    $fs.Position = $off
    $n = $fs.Read($b, 0, $len)
    if ($n -lt $len) { return $null }
    return ,$b
}

function Cpu-Name($v) {
    switch ($v) {
        16777228 { 'arm64' }
        16777223 { 'x86_64' }
        12 { 'armv7' }
        7 { 'i386' }
        16777222 { 'arm64_32' }
        default { '?' }
    }
}

# 二进制 plist / Mach-O 里到处是大端，.NET 默认按小端读，这里按需翻转
function U32-At($b, $o, $be) {
    $v = [BitConverter]::ToUInt32($b, $o)
    if (-not $be) { return $v }
    return [uint32](((($v -band 0xFF) -shl 24) -bor (($v -band 0xFF00) -shl 8) -bor (($v -band 0xFF0000) -shr 8) -bor (($v -band 0xFF000000) -shr 24)))
}
function U64-At($b, $o, $be) {
    # 大端时前 4 字节是高 32 位；小端时前 4 字节才是低 32 位
    if ($be) {
        $hi = U32-At $b $o $true
        $lo = U32-At $b ($o + 4) $true
    } else {
        $lo = U32-At $b $o $false
        $hi = U32-At $b ($o + 4) $false
    }
    return ([uint64]$hi -shl 32) -bor [uint64]$lo
}

# 解析 LC_CODE_SIGNATURE 和签名 SuperBlob：有 CMS 才是真证书签名。
# slice 的字节序看它自己的 magic，不能沿用 fat 头的
function Get-SigState($fs, $base) {
    $m = Read-At $fs $base 4
    if ($m -eq $null) { return '没签' }
    $le = [BitConverter]::ToUInt32($m, 0)
    if ($le -eq 4277009103 -or $le -eq 4277009102) { $be = $false }
    elseif ($le -eq 3472551422 -or $le -eq 3489333246) { $be = $true }
    else { return '没签' }
    $h = Read-At $fs $base 32
    if ($h -eq $null) { return '没签' }
    $magic = U32-At $h 0 $be
    if ($magic -eq 4277009103) { $hsz = 32 } elseif ($magic -eq 4277009102) { $hsz = 28 } else { return '没签' }
    $ncmds = U32-At $h 16 $be
    $sizeofcmds = U32-At $h 20 $be
    if ($ncmds -gt 4096 -or $sizeofcmds -gt 1048576) { return '没签' }
    $cmds = Read-At $fs ($base + $hsz) $sizeofcmds
    if ($cmds -eq $null) { return '没签' }
    $sigoff = -1
    $pos = 0
    for ($i = 0; $i -lt $ncmds; $i++) {
        if ($pos + 8 -gt $sizeofcmds) { break }
        $cmd = U32-At $cmds $pos $be
        $size = U32-At $cmds ($pos + 4) $be
        if ($size -lt 8) { break }
        # dataoff 相对 slice 起点，fat 里必须加 base
        if ($cmd -eq 29 -and $pos + 16 -le $sizeofcmds) { $sigoff = $base + (U32-At $cmds ($pos + 8) $be) }
        $pos += $size
    }
    if ($sigoff -lt 0) { return '没签' }
    $sb = Read-At $fs $sigoff 12
    if ($sb -eq $null) { return '没签' }
    # SuperBlob 固定大端（FA DE 0C C0），不跟 slice 的字节序走
    if ((U32-At $sb 0 $true) -ne 4208856256) { return '没签' }
    $cnt = U32-At $sb 4 $true
    if ($cnt -gt 20) { $cnt = 20 }
    $idx = Read-At $fs ($sigoff + 8) ($cnt * 8)
    if ($idx -eq $null) { return '没签' }
    for ($i = 0; $i -lt $cnt; $i++) {
        if ((U32-At $idx ($i * 8) $true) -eq 65536) { return '真证书签名（有 CMS）' }
    }
    return 'ad-hoc 伪签名（只有 CodeDirectory）'
}

# fat binary 的 offset 4 是 nfat_arch，不是 cputype；
# 标准 fat 头是 CA FE BA BE（小端读出 3199925962），字段大端；
# 3405691582/3405691583 是字节交换变体 FAT_CIGAM，字段小端
function Get-MachReport($path) {
    $fs = $null
    try { $fs = [IO.File]::OpenRead($path) } catch { return @('读不了', '读不了', 0) }
    try {
        $h = Read-At $fs 0 32
        if ($h -eq $null) { return @('?', '读不了', (Get-Item $path).Length) }
        $magic = [BitConverter]::ToUInt32($h, 0)
        $archs = @()
        $sig = '没签'
        if ($magic -eq 4277009103 -or $magic -eq 4277009102) {
            $archs += (Cpu-Name ([BitConverter]::ToUInt32($h, 4)))
            $sig = Get-SigState $fs 0
        } elseif ($magic -eq 3472551422 -or $magic -eq 3489333246) {
            $archs += (Cpu-Name (U32-At $h 4 $true))
            $sig = Get-SigState $fs 0
        } elseif ($magic -eq 3199925962 -or $magic -eq 3216703178 -or $magic -eq 3405691582 -or $magic -eq 3405691583) {
            $be = ($magic -eq 3199925962 -or $magic -eq 3216703178)
            $entSize = if ($magic -eq 3216703178 -or $magic -eq 3405691583) { 32 } else { 20 }
            $nfat = U32-At $h 4 $be
            if ($nfat -gt 20) { $nfat = 0 }
            for ($i = 0; $i -lt $nfat; $i++) {
                $e = Read-At $fs (8 + $i * $entSize) $entSize
                if ($e -eq $null) { continue }
                $archs += (Cpu-Name (U32-At $e 0 $be))
                $off = if ($entSize -eq 32) { U64-At $e 8 $be } else { U32-At $e 8 $be }
                $st = Get-SigState $fs $off
                if ($st -eq '真证书签名（有 CMS）' -or ($st -ne '没签' -and $sig -eq '没签')) { $sig = $st }
            }
        } else {
            $archs += '不是 Mach-O'
        }
        $archLabel = ($archs -join '+')
        if ($archLabel -eq '') { $archLabel = '?' }
        if ($archs.Count -gt 1) { $archLabel = "$archLabel（fat）" }
        return @($archLabel, $sig, (Get-Item $path).Length)
    } finally { if ($fs) { $fs.Dispose() } }
}

# $argv[1..0] 在 PowerShell 里会倒序取出 @($null, $argv[0])，后面 $null.StartsWith 直接崩
function Rest($a) {
    if ($a.Count -gt 1) { return @($a[1..($a.Count - 1)]) }
    return @()
}

function Read-Plist($app, [switch]$Strict) {
    $p = Join-Path $app 'Info.plist'
    if (-not (Test-Path $p)) { return $null }
    $b = [IO.File]::ReadAllBytes($p)
    if ($b.Length -gt 6 -and [Text.Encoding]::ASCII.GetString($b, 0, 6) -eq 'bplist') {
        # Xcode 产出的 Info.plist 基本都是 bplist，读不了就不能装作读到了：
        # 改不动字段却照样改可执行文件名，包会起不来。宁可在这里停下。
        if ($Strict) { Die "Info.plist 是二进制格式（bplist），这里改不了字段。先在 macOS 上 plutil -convert xml1 转成 XML，或者不带 --bundle-id/--name/--version 直接 pack。" }
        return $null
    }
    try { return [xml](Get-Content $p -Raw -Encoding UTF8) } catch { return $null }
}

# PowerShell 读 <key> 这种只有文本的节点会直接给字符串，拿不到兄弟节点，
# 所以按 ChildNodes 的下标走：key 的下一个就是值
function Get-Value($pl, $key) {
    if ($pl -eq $null) { return $null }
    $nodes = $pl.plist.dict.ChildNodes
    for ($i = 0; $i -lt $nodes.Count - 1; $i++) {
        if ($nodes[$i].Name -eq 'key' -and $nodes[$i].InnerText -eq $key) {
            $v = $nodes[$i + 1]
            if ($v.Name -eq 'string') { return $v.InnerText }
        }
    }
    return $null
}

function Set-Value($pl, $key, $value) {
    if ($pl -eq $null) { return }
    $dict = $pl.plist.dict
    $nodes = $dict.ChildNodes
    for ($i = 0; $i -lt $nodes.Count - 1; $i++) {
        if ($nodes[$i].Name -eq 'key' -and $nodes[$i].InnerText -eq $key) {
            $v = $nodes[$i + 1]
            if ($v.Name -eq 'string') { $v.InnerText = $value; return }
        }
    }
    # plist 里没有这个键就补上，不然 --name / --version 会静默不生效
    $k = $pl.CreateElement('key')
    $k.InnerText = $key
    $v = $pl.CreateElement('string')
    $v.InnerText = $value
    $dict.AppendChild($k) | Out-Null
    $dict.AppendChild($v) | Out-Null
}

function Get-Exe($app) {
    $declared = Get-Value (Read-Plist $app) 'CFBundleExecutable'
    if ($declared -ne $null) {
        $p = Join-Path $app $declared
        if (Test-Path $p) { return $declared }
    }
    foreach ($f in Get-ChildItem $app -File) {
        if ($f.Extension -eq '.plist' -or $f.Extension -eq '.png') { continue }
        if ($f.Length -lt 8) { continue }
        $fs = [IO.File]::OpenRead($f.FullName)
        $b = New-Object byte[] 8
        $fs.Read($b, 0, 8) | Out-Null
        $fs.Close()
        $m = [BitConverter]::ToUInt32($b, 0)  # 64/32 位 Mach-O、fat 的魔数：64/32 位 Mach-O 或 fat
        # 64/32 位 Mach-O（大小端）、标准 fat、CIGAM fat
        if ($m -in @(4277009103, 4277009102, 3472551422, 3489333246, 3199925962, 3216703178, 3405691582, 3405691583)) { return $f.Name }
    }
    return $null
}

function Find-App($dir) {
    if (-not (Test-Path $dir)) { return $null }
    Get-ChildItem $dir -Recurse -Directory -Filter '*.app' |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
}

# 输出目录不存在的先建出来，不然没有 zsign 时直接 Copy 会失败
function Ensure-Parent($out) {
    $parent = Split-Path -Parent $out
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
}

function Zip-Dir($src, $out) {
    # .NET 的 CreateFromDirectory 不认符号链接，会把链接展开成整份文件副本。
    # .app 里带 framework 符号链接时包里会多出一堆重复文件，这里先说清楚
    $links = Get-ChildItem $src -Recurse -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
    if ($links) {
        Write-Host "包里有 $($links.Count) 个符号链接，Windows 打包会展开成副本（结构能用但体积偏大）。要严格保留链接请在 macOS 上用 scripts/ipa"
    }
    $parent = Split-Path -Parent $out
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path $out) { Remove-Item $out -Force }
    # 传目录名进去，条目就是 Payload/xxx.app/...，正是 ipa 要的层级
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $out, [IO.Compression.CompressionLevel]::Optimal, $false)
}

# 有 p12 就走真证书签名（zsign -k / -m / -p），没有就走 -a ad-hoc。
# 真证书签名 zsign 会联网查 OCSP 吊销状态，离线时可能变慢或告警，这是它本来行为。
function Sign-Ipa($in, $out, $p12, $prov, $pass, $ent) {
    if (-not (Test-Path $zsign)) { Die "没有 zsign.exe，先跑 scripts\bootstrap.ps1" }
    $parent = Split-Path -Parent $out
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $a = @()
    if ($p12) {
        if (-not (Test-Path $p12)) { Die "找不到证书: $p12" }
        if (-not $prov) { Die "证书签名还要描述文件: --prov xxx.mobileprovision" }
        if (-not (Test-Path $prov)) { Die "找不到描述文件: $prov" }
        $a = @('-k', (Resolve-Path $p12).Path, '-m', (Resolve-Path $prov).Path)
        if ($pass) { $a += @('-p', $pass) }
        if ($ent) {
            if (-not (Test-Path $ent)) { Die "找不到 entitlements 文件: $ent" }
            $a += @('-e', (Resolve-Path $ent).Path)
        }
        $a += @('-o', $out, $in)
    } else {
        if ($prov) { Write-Host "只有描述文件没有 p12，还是按伪签处理" }
        $a = @('-a', '-o', $out, $in)
    }

    # 直接用调用运算符传数组，PowerShell 会给带空格的参数自己加引号；
    # Start-Process 是把数组拼成一行再交给系统，密码里有空格就被拆成两个参数了
    if ($pass) { Write-Host "提示：--password 会留在命令历史和进程列表里，建议改用环境变量 IPA_CERT_PASSWORD" }
    & $zsign @a
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) {
        if ($p12) { Die "zsign 签名失败，退出码 $LASTEXITCODE。常见原因是 p12 密码不对，或者 bundle id 跟描述文件对不上。" }
        Die "zsign 签名失败，退出码 $LASTEXITCODE"
    }
}

# 参数表：同名选项重复出现时（比如两个 --framework）收成数组，别互相盖掉
function Opts($argv) {
    $map = @{}
    $i = 0
    while ($i -lt $argv.Count) {
        $k = $argv[$i]
        if (-not $k.StartsWith('-')) { Die "这个参数我认不出来: $k（带空格的路径或名字要用引号包起来）" }
        if ($i + 1 -ge $argv.Count) { Die "$k 后面少一个值" }
        $v = $argv[$i + 1]
        $i += 2
        if ($map.ContainsKey($k)) {
            if ($map[$k] -is [array]) { $map[$k] = @($map[$k]) + $v } else { $map[$k] = @($map[$k], $v) }
        } else {
            $map[$k] = $v
        }
    }
    return $map
}

# 取单个值：同名选项给了多次就取最后一个，跟 bash 版一致
function Opt($map, $names, $default) {
    $v = $null
    foreach ($n in $names) { if ($map.ContainsKey($n)) { $v = $map[$n] } }
    if ($v -is [array]) { return $v[$v.Count - 1] }
    if ($v -eq $null) { return $default }
    return $v
}

function Fw-Args($map, $src) {
    if ($map.ContainsKey('--framework')) {
        $list = $map['--framework']
        if (-not ($list -is [array])) { $list = @($list) }
        $out = @()
        foreach ($f in $list) { $out += @('-framework', $f) }
        return $out
    }
    # 只链用得到的框架；源码在子目录里也要扫到，不然 UIKit 漏了会报找不到 UIApplicationMain
    $hit = $false
    $code = Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.m', '.mm', '.h', '.c', '.cpp' }
    foreach ($f in $code) {
        if (Select-String -Path $f.FullName -Pattern 'UIKit/' -SimpleMatch -Quiet) { $hit = $true; break }
    }
    if ($hit) { return @('-framework', 'UIKit', '-framework', 'Foundation') }
    return @('-framework', 'Foundation')
}

function Cmd-Doctor {
    $clang = Get-Command clang.exe -ErrorAction SilentlyContinue
    $lld = Get-Command ld64.lld.exe -ErrorAction SilentlyContinue
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    Write-Host ("clang     " + $(if ($clang) { $clang.Source } else { '缺（源码编不了，pack / resign 不受影响' }))
    Write-Host ("ld64.lld  " + $(if ($lld) { $lld.Source } else { '缺（源码编不了' }))
    Write-Host ("sdk       " + $(if (Test-Path $sdk) { $sdk } else { '缺' }))
    Write-Host ("zsign     " + $(if (Test-Path $zsign) { $zsign } else { '缺' }))
    Write-Host ("wsl       " + $(if ($wsl) { '有，没 clang 时 build 会借它' } else { '没有' }))
}

function Cmd-Info($path) {
    if (-not $path) { Die "用法: ipa.ps1 info 某.ipa 或 某.app" }
    if (-not (Test-Path $path)) { Die "没有这个路径: $path" }
    $tmp = $null
    $app = $path
    if ($path -like '*.ipa') {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ipa_' + [guid]::NewGuid().ToString('N'))
        [IO.Compression.ZipFile]::ExtractToDirectory($path, $tmp)
        $found = Find-App (Join-Path $tmp 'Payload')
        if ($found -eq $null) { Die "包里没有 .app" }
        $app = $found.FullName
    }
    $pl = Read-Plist $app
    $exe = Get-Exe $app
    Write-Host "位置     $path"
    Write-Host "可执行   $exe"
    Write-Host "标识符   $(Get-Value $pl 'CFBundleIdentifier')"
    Write-Host "版本     $(Get-Value $pl 'CFBundleShortVersionString') build $(Get-Value $pl 'CFBundleVersion')"
    Write-Host "最低系统 $(Get-Value $pl 'MinimumOSVersion')"
    $iplist = Join-Path $app 'Info.plist'
    if ($pl -eq $null -and (Test-Bplist $iplist)) {
        Write-Host "plist    是二进制格式（bplist），字段读不出来。要看字段先在 macOS 上 plutil -convert xml1 转成 XML"
    }
    if ($exe -ne $null) {
        $bin = Join-Path $app $exe
        $rep = Get-MachReport $bin
        Write-Host "架构     $($rep[0])"
        Write-Host "签名     $($rep[1])"
        Write-Host ("大小     " + [math]::Round($rep[2] / 1KB) + " KB")
    }
    if (Test-Path (Join-Path $app '_CodeSignature')) { Write-Host "签名目录 有 _CodeSignature" }
    if ($tmp -ne $null) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# 密码：命令行的照收，但没有就用环境变量，省得进 shell 历史
function Get-Pass($opt) {
    $p = Opt $opt @('--password', '--pass') $null
    if (-not $p) { $p = $env:IPA_CERT_PASSWORD }
    return $p
}

function Cmd-Pack($argv) {
    if ($argv.Count -eq 0) { Die "用法: ipa.ps1 pack 某.app [-o 输出.ipa] [--bundle-id ...] [--p12 证书 --prov 描述文件 --password 密码]" }
    $src = $argv[0]
    if (-not (Test-Path $src)) { Die "没有这个路径: $src" }
    $opt = Opts @(Rest $argv)

    $work = Join-Path ([IO.Path]::GetTempPath()) ('pack_' + [guid]::NewGuid().ToString('N'))
    $payload = Join-Path $work 'Payload'
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    if ((Split-Path -Leaf $src) -eq 'Payload') { Copy-Item (Join-Path $src '*') $payload -Recurse -Force }
    else { Copy-Item $src (Join-Path $payload (Split-Path -Leaf $src)) -Recurse -Force }

    $found = Find-App $payload
    if ($found -eq $null) { Die "Payload 里没有 .app" }
    $app = $found.FullName

    $bid = Opt $opt @('--bundle-id') $null
    $name = Opt $opt @('--name') $null
    $ver = Opt $opt @('--version') $null
    $pl = $null
    if ($bid -or $name -or $ver) { $pl = Read-Plist $app -Strict }
    if ($pl -ne $null) {
        if ($bid) { Set-Value $pl 'CFBundleIdentifier' $bid }
        if ($name) {
            Set-Value $pl 'CFBundleDisplayName' $name
            Set-Value $pl 'CFBundleExecutable' $name
        }
        if ($ver) { Set-Value $pl 'CFBundleShortVersionString' $ver }
        $pl.Save((Join-Path $app 'Info.plist'))
    }
    $icon = Opt $opt @('--icon') $null
    if ($icon -and (Test-Path $icon)) { Copy-Item $icon (Join-Path $app 'AppIcon60x60@2x.png') -Force }

    $exe = Get-Exe $app
    if ($name -and $exe -ne $null -and $exe -ne $name) { Rename-Item (Join-Path $app $exe) $name }
    $old = Join-Path $app '_CodeSignature'
    if (Test-Path $old) { Remove-Item $old -Recurse -Force }

    $out = Opt $opt @('-o', '--out') $null
    if (-not $out) {
        if ($name) { $leaf = $name } else {
            $leaf = Split-Path -Leaf $app
            $leaf = $leaf.Substring(0, $leaf.Length - 4)
        }
        $out = Join-Path (Get-Location) "dist/$leaf.ipa"
    }

    # 输出 zip 不能放在被压的目录里，否则边写边读会打架
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pack_' + [guid]::NewGuid().ToString('N') + '.ipa')
    Zip-Dir $work $tmp
    if (Test-Path $zsign) {
        Sign-Ipa $tmp $out (Opt $opt @('--p12') $null) (Opt $opt @('--prov') $null) (Get-Pass $opt) (Opt $opt @('--entitlements') $null)
    } else {
        Ensure-Parent $out
        Copy-Item $tmp $out -Force
        Write-Host "没有 zsign，包出来了但没签名"
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "产物 $out"
}

function Cmd-Resign($argv) {
    if ($argv.Count -eq 0) { Die "用法: ipa.ps1 resign 某.ipa 或 某.app [-o 输出.ipa] [--bundle-id ...] [--p12 证书 --prov 描述文件 --password 密码]" }
    $src = $argv[0]
    if (-not (Test-Path $src)) { Die "没有这个路径: $src" }
    if (-not (Test-Path $zsign)) { Die "没有 zsign.exe，先跑 scripts\bootstrap.ps1" }
    $opt = Opts @(Rest $argv)

    $in = $src
    if ($src -like '*.app') {
        $work = Join-Path ([IO.Path]::GetTempPath()) ('resign_' + [guid]::NewGuid().ToString('N'))
        $payload = Join-Path $work 'Payload'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        Copy-Item $src (Join-Path $payload (Split-Path -Leaf $src)) -Recurse -Force
        $in = Join-Path ([IO.Path]::GetTempPath()) ('resign_' + [guid]::NewGuid().ToString('N') + '.ipa')
        Zip-Dir $work $in
    }

    $bid = Opt $opt @('--bundle-id') $null
    if ($bid) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('bid_' + [guid]::NewGuid().ToString('N'))
        [IO.Compression.ZipFile]::ExtractToDirectory($in, $tmp)
        $a = Find-App (Join-Path $tmp 'Payload')
        $pl = Read-Plist $a.FullName -Strict
        if ($pl -ne $null) {
            Set-Value $pl 'CFBundleIdentifier' $bid
            $pl.Save((Join-Path $a.FullName 'Info.plist'))
        }
        $in = Join-Path ([IO.Path]::GetTempPath()) ('bid_' + [guid]::NewGuid().ToString('N') + '.ipa')
        Zip-Dir $tmp $in
    }

    $out = Opt $opt @('-o', '--out') $null
    if (-not $out) {
        $leaf = [IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $src))
        $out = Join-Path (Get-Location) "dist/${leaf}_resigned.ipa"
    }
    Sign-Ipa $in $out (Opt $opt @('--p12') $null) (Opt $opt @('--prov') $null) (Get-Pass $opt) (Opt $opt @('--entitlements') $null)
    Write-Host "产物 $out"
}

# WSL 里拼命令，每个参数单独用单引号包住，带空格的路径不会被拆开
function Q($s) {
    # 单引号里的撇号要写成 '\'' 这一串（关引号、转义撇号、重开引号），
    # 用 Replace 拼，别用 -replace 的替换串，那边反斜杠和引号会被吃掉
    $bs = [char]92
    $q  = [char]39
    return $q + $s.Replace([string]$q, [string]$q + $bs + [string]$q + [string]$q) + $q
}

function To-WslPath($p) {
    $s = $p -replace '\\', '/'
    if ($s -match '^([A-Za-z]):') { $s = '/mnt/' + $matches[1].ToLower() + ($s -replace '^[A-Za-z]:', '') }
    return $s
}

function Cmd-Build($argv) {
    if ($argv.Count -eq 0) { Die "用法: ipa.ps1 build 源码目录 --name 名字 --bundle-id com.a.b [--p12 证书 --prov 描述文件 --password 密码]" }
    $src = $argv[0]
    if (-not (Test-Path $src)) { Die "没有这个目录: $src" }
    $opt = Opts @(Rest $argv)

    $clang = Get-Command clang.exe -ErrorAction SilentlyContinue
    $lld = Get-Command ld64.lld.exe -ErrorAction SilentlyContinue

    # 本机没有 clang 就甩给 WSL 里的 bash 脚本，别在这里硬编
    if ($clang -eq $null -or $lld -eq $null) {
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if ($wsl -ne $null) {
            Write-Host "本机没 clang，交给 WSL 编"
            & wsl.exe bash -lc 'test -d "$HOME/.ipa-toolchain"'
            if ($LASTEXITCODE -ne 0) {
                Die "WSL 里还没铺过环境（那是 WSL 自己的 home，跟 Windows 这份不共用）。先在 WSL 里跑一次 bash scripts/bootstrap.sh，或者直接跑 scripts\bootstrap.ps1 把本机编译器装上。"
            }
            $parts = @('bash', (Q (Join-Path $here 'ipa')), 'build', (Q (To-WslPath (Resolve-Path $src).Path)))
            # 路径参数一律换到 /mnt/...，不然产物落在 WSL 的 home 里，用户在 Windows 目录找不到
            $pathOpts = @('-o', '--out', '--icon', '--entitlements', '--p12', '--prov')
            $expectPath = $false
            foreach ($a in @(Rest $argv)) {
                $looksPath = (Test-Path $a) -or ($a -match '^[A-Za-z]:') -or ($a -match '[/\\]')
                if (-not $a.StartsWith('-') -and ($expectPath -or $looksPath)) {
                    $full = $a
                    if (Test-Path $a) { $full = (Resolve-Path $a).Path }
                    elseif (-not [IO.Path]::IsPathRooted($a)) { $full = Join-Path (Get-Location) $a }
                    $parts += (Q (To-WslPath $full))
                    $expectPath = $false
                    continue
                }
                $parts += (Q $a)
                $expectPath = ($pathOpts -contains $a)
            }
            $cmd = $parts -join ' '
            # wsl.exe 默认不把 Windows 的环境变量带进 bash，密码按推荐方式放 env 的话
            # 转发时会变成空串，所以这里显式前置进去
            $wpass = Get-Pass $opt
            if ($wpass) { $cmd = 'IPA_CERT_PASSWORD=' + (Q $wpass) + ' ' + $cmd }
            & wsl.exe bash -lc $cmd
            exit $LASTEXITCODE
        }
        Die "这台机器上没有 clang，也没有 WSL，源码编不了。跑 scripts\bootstrap.ps1，它会自己把编译器弄好。`n只打包或改签的话不用编译器，ipa.ps1 pack / resign 照常能用。"
    }

    $name = Opt $opt @('--name') $null
    if (-not $name) { $name = Split-Path -Leaf (Resolve-Path $src).Path }
    $bid = Opt $opt @('--bundle-id') 'com.example.app'
    $minios = Opt $opt @('--min-ios') '14.0'

    $work = Join-Path (Get-Location) ".build/$name"
    $app = Join-Path $work "Payload/$name.app"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Path $app -Force | Out-Null

    $files = @(Get-ChildItem $src -Recurse -File | Where-Object { $_.Extension -in '.m', '.mm', '.c', '.cpp' })
    if ($files.Count -eq 0) { Die "$src 里没有 .m/.mm/.c/.cpp" }

    $fw = Fw-Args $opt $src
    $arc = @()
    foreach ($f in $files) { if ($f.Extension -eq '.m' -or $f.Extension -eq '.mm') { $arc = @('-fobjc-arc'); break } }

    Write-Host "编译 $($files.Count) 个文件，arm64 ios$minios"
    & $clang.Source -target ("arm64-apple-ios" + $minios) -isysroot $sdk `
        -F (Join-Path $sdk 'System/Library/Frameworks') `
        -fuse-ld=lld -O2 -fPIC $arc $fw -o (Join-Path $app $name) ($files | ForEach-Object { $_.FullName })
    if ($LASTEXITCODE -ne 0) { Die "clang 编译失败" }

    $tpl = Get-Content (Join-Path $here 'templates/Info.plist') -Raw -Encoding UTF8
    $tpl = $tpl -replace '@NAME@', $name -replace '@BUNDLEID@', $bid -replace '@MINIOS@', $minios
    Set-Content (Join-Path $app 'Info.plist') $tpl -Encoding UTF8
    $icon = Opt $opt @('--icon') $null
    if ($icon -and (Test-Path $icon)) { Copy-Item $icon (Join-Path $app 'AppIcon60x60@2x.png') }

    $pre = Join-Path ([IO.Path]::GetTempPath()) ('build_' + [guid]::NewGuid().ToString('N') + '.ipa')
    Zip-Dir $work $pre
    $out = Opt $opt @('-o', '--out') $null
    if (-not $out) { $out = Join-Path (Get-Location) "dist/$name.ipa" }
    if (Test-Path $zsign) {
        Sign-Ipa $pre $out (Opt $opt @('--p12') $null) (Opt $opt @('--prov') $null) (Get-Pass $opt) (Opt $opt @('--entitlements') $null)
    } else { Copy-Item $pre $out; Write-Host "没签名，只是打了个包" }
    Remove-Item $pre -Force -ErrorAction SilentlyContinue
    Write-Host "产物 $out"
}

if ($args.Count -eq 0) {
    Write-Host "ipa-build —— Windows 上打包 / 签名 iOS 安装包"
    Write-Host ""
    Write-Host "  doctor   看环境齐不齐"
    Write-Host "  info     看 ipa/app 的标识、版本、架构、签没签"
    Write-Host "  pack     .app 打成 ipa，可改标识/显示名/版本/图标"
    Write-Host "  resign   已有的 ipa 或 app 重新签名，可换标识；给 --p12 就是真证书签名"
    Write-Host "  build    .m/.c 编成 ipa，需要 clang + SDK，没有就借 WSL"
    exit 0
}

switch ($args[0]) {
    'doctor' { Cmd-Doctor }
    'info'   { if ($args.Count -gt 1) { Cmd-Info $args[1] } else { Cmd-Info $null } }
    'build'  { Cmd-Build @(Rest $args) }
    'pack'   { Cmd-Pack @(Rest $args) }
    'resign' { Cmd-Resign @(Rest $args) }
    default  { Write-Host "不认识的命令: $($args[0])"; exit 1 }
}
