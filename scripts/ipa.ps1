# ipa-build 的 Windows 入口。跟 scripts/ipa 干同样的事，换 PowerShell 实现：
# Windows 上没有 ldid，签名交给 zsign；打包用 .NET 的 ZipFile，不依赖 zip 命令。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

if ($env:IPA_HOME) { $tc = $env:IPA_HOME } else { $tc = Join-Path $env:USERPROFILE '.ipa-toolchain' }
if ($env:IPA_SDK) { $sdk = $env:IPA_SDK } else { $sdk = Join-Path $tc 'sdk\iPhoneOS16.5.sdk' }
$zsign = Join-Path $tc 'bin\zsign.exe'
if (-not (Test-Path $zsign)) {
    $vendored = Join-Path $root 'vendor\zsign\zsign.exe'
    if (Test-Path $vendored) { $zsign = $vendored }
}
if ($env:IPA_ZSIGN) { $zsign = $env:IPA_ZSIGN }

function Die($m) { Write-Host $m; exit 1 }

function Read-Plist($app) {
    $p = Join-Path $app 'Info.plist'
    if (-not (Test-Path $p)) { return $null }
    $b = [IO.File]::ReadAllBytes($p)
    if ($b.Length -gt 6 -and [Text.Encoding]::ASCII.GetString($b, 0, 6) -eq 'bplist') {
        return $null   # 二进制 plist，这回不动它
    }
    try { return [xml](Get-Content $p -Raw -Encoding UTF8) } catch { return $null }
}

# PowerShell 读 <key> 这种只有文本的节点会直接给字符串，apter 没法拿到兄弟节点，
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
    $nodes = $pl.plist.dict.ChildNodes
    for ($i = 0; $i -lt $nodes.Count - 1; $i++) {
        if ($nodes[$i].Name -eq 'key' -and $nodes[$i].InnerText -eq $key) {
            $v = $nodes[$i + 1]
            if ($v.Name -eq 'string') { $v.InnerText = $value }
        }
    }
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
        $m = [BitConverter]::ToUInt32($b, 0)
        if ($m -eq 4277009103 -or $m -eq 4277009102 -or $m -eq 3199925962) { return $f.Name }
    }
    return $null
}

function Find-App($dir) {
    Get-ChildItem $dir -Recurse -Directory -Filter '*.app' |
        Sort-Object Length | Select-Object -First 1
}

function Zip-Dir($src, $out) {
    $parent = Split-Path -Parent $out
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path $out) { Remove-Item $out -Force }
    # 传目录名进去，条目就是 Payload/xxx.app/...，正是 ipa 要的层级
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $out, [IO.Compression.CompressionLevel]::Optimal, $false)
}

function Sign-Ipa($in, $out) {
    if (-not (Test-Path $zsign)) { Die "没有 zsign.exe，先跑 scripts\bootstrap.ps1" }
    $parent = Split-Path -Parent $out
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $p = Start-Process -FilePath $zsign -ArgumentList @('-a', '-o', $out, $in) -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0 -or -not (Test-Path $out)) { Die "zsign 签名失败，退出码 $($p.ExitCode)" }
}

function Arg-Pairs($rest) {
    $map = @{}
    $i = 0
    while ($i -lt $rest.Count) {
        $k = $rest[$i]
        if ($i + 1 -lt $rest.Count) { $map[$k] = $rest[$i + 1]; $i += 2 } else { $i += 1 }
    }
    return $map
}

function Cmd-Doctor {
    $clang = Get-Command clang.exe -ErrorAction SilentlyContinue
    $lld = Get-Command ld64.lld.exe -ErrorAction SilentlyContinue
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    Write-Host ("clang     " + $(if ($clang) { $clang.Source } else { '缺（只能 pack / resign' }))
    Write-Host ("ld64.lld  " + $(if ($lld) { 'ok' } else { '缺（源码编不了）' }))
    Write-Host ("sdk       " + $(if (Test-Path $sdk) { $sdk } else { '缺' }))
    Write-Host ("zsign     " + $(if (Test-Path $zsign) { $zsign } else { '缺' }))
    Write-Host ("wsl       " + $(if ($wsl) { '有，build 会借它' } else { '没有' }))
}

function Cmd-Info($path) {
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
    Write-Host "位置     $path"
    Write-Host "可执行   $(Get-Exe $app)"
    Write-Host "标识符   $(Get-Value $pl 'CFBundleIdentifier')"
    Write-Host "版本     $(Get-Value $pl 'CFBundleShortVersionString') build $(Get-Value $pl 'CFBundleVersion')"
    Write-Host "最低系统 $(Get-Value $pl 'MinimumOSVersion')"
    $exe = Get-Exe $app
    if ($exe -ne $null) {
        $bin = Join-Path $app $exe
        $bytes = [IO.File]::ReadAllBytes($bin)
        $cpu = [BitConverter]::ToInt32($bytes, 4)
        $arch = '?'
        if ($cpu -eq 16777228) { $arch = 'arm64' }
        if ($cpu -eq 12) { $arch = 'armv7' }
        if ($cpu -eq 16777223) { $arch = 'x86_64' }
        Write-Host "架构     Mach-O $arch"
        Write-Host ("大小     " + [math]::Round($bytes.Length / 1KB) + " KB")
        $hasSig = $false
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        if ($text.Contains('CodeDirectory')) { $hasSig = $true }
        Write-Host ("签名     " + $(if ($hasSig) { '有 CodeDirectory，是伪签名' } else { '没签' }))
    }
    if ($tmp -ne $null) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Cmd-Pack($argv) {
    if ($argv.Count -eq 0) { Die "用法: ipa.ps1 pack 某.app [-o 输出.ipa] [--bundle-id ...] [--name ...]" }
    $src = $argv[0]
    if (-not (Test-Path $src)) { Die "没有这个路径: $src" }
    $opt = Arg-Pairs @($argv[1..($argv.Count - 1)])

    $work = Join-Path ([IO.Path]::GetTempPath()) ('pack_' + [guid]::NewGuid().ToString('N'))
    $payload = Join-Path $work 'Payload'
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    if ((Split-Path -Leaf $src) -eq 'Payload') { Copy-Item (Join-Path $src '*') $payload -Recurse -Force }
    else { Copy-Item $src (Join-Path $payload (Split-Path -Leaf $src)) -Recurse -Force }

    $found = Find-App $payload
    if ($found -eq $null) { Die "Payload 里没有 .app" }
    $app = $found.FullName

    $pl = Read-Plist $app
    if ($pl -ne $null) {
        if ($opt['--bundle-id']) { Set-Value $pl 'CFBundleIdentifier' $opt['--bundle-id'] }
        if ($opt['--name']) {
            Set-Value $pl 'CFBundleDisplayName' $opt['--name']
            Set-Value $pl 'CFBundleExecutable' $opt['--name']
        }
        if ($opt['--version']) { Set-Value $pl 'CFBundleShortVersionString' $opt['--version'] }
        $pl.Save((Join-Path $app 'Info.plist'))
    }
    if ($opt['--icon'] -and (Test-Path $opt['--icon'])) {
        Copy-Item $opt['--icon'] (Join-Path $app 'AppIcon60x60@2x.png') -Force
    }

    $exe = Get-Exe $app
    if ($opt['--name'] -and $exe -ne $null -and $exe -ne $opt['--name']) {
        Rename-Item (Join-Path $app $exe) $opt['--name']
    }
    $old = Join-Path $app '_CodeSignature'
    if (Test-Path $old) { Remove-Item $old -Recurse -Force }

    $out = $opt['-o']
    if (-not $out) {
        $leaf = Split-Path -Leaf $app
        $leaf = $leaf.Substring(0, $leaf.Length - 4)
        $out = Join-Path (Get-Location) "dist\$leaf.ipa"
    }

    # 输出 zip 不能放在被压的目录里，否则边写边读会打架
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pack_' + [guid]::NewGuid().ToString('N') + '.ipa')
    Zip-Dir $work $tmp
    if (Test-Path $zsign) { Sign-Ipa $tmp $out } else {
        Copy-Item $tmp $out -Force
        Write-Host "没有 zsign，包出来了但没签名"
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "产物 $out"
}

function Cmd-Resign($argv) {
    if ($argv.Count -eq 0) { Die "用法: ipa.ps1 resign 某.ipa 或 某.app [-o 输出.ipa]" }
    $src = $argv[0]
    if (-not (Test-Path $src)) { Die "没有这个路径: $src" }
    if (-not (Test-Path $zsign)) { Die "没有 zsign.exe，先跑 scripts\bootstrap.ps1" }
    $opt = Arg-Pairs @($argv[1..($argv.Count - 1)])

    $in = $src
    $work = $null
    if ($src -like '*.app') {
        $work = Join-Path ([IO.Path]::GetTempPath()) ('resign_' + [guid]::NewGuid().ToString('N'))
        $payload = Join-Path $work 'Payload'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        Copy-Item $src (Join-Path $payload (Split-Path -Leaf $src)) -Recurse -Force
        $in = Join-Path ([IO.Path]::GetTempPath()) ('resign_' + [guid]::NewGuid().ToString('N') + '.ipa')
        Zip-Dir $work $in
    }

    if ($opt['--bundle-id']) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('bid_' + [guid]::NewGuid().ToString('N'))
        [IO.Compression.ZipFile]::ExtractToDirectory($in, $tmp)
        $a = Find-App (Join-Path $tmp 'Payload')
        $pl = Read-Plist $a.FullName
        if ($pl -ne $null) {
            Set-Value $pl 'CFBundleIdentifier' $opt['--bundle-id']
            $pl.Save((Join-Path $a.FullName 'Info.plist'))
        }
        $in = Join-Path ([IO.Path]::GetTempPath()) ('bid_' + [guid]::NewGuid().ToString('N') + '.ipa')
        Zip-Dir $tmp $in
    }

    $out = $opt['-o']
    if (-not $out) {
        $leaf = Split-Path -Leaf $src
        $leaf = [IO.Path]::GetFileNameWithoutExtension($leaf)
        $out = Join-Path (Get-Location) "dist\${leaf}_signed.ipa"
    }
    Sign-Ipa $in $out
    Write-Host "产物 $out"
}

function Cmd-Build($argv) {
    if ($argv.Count -eq 0) { Die "用法: ipa.ps1 build 源码目录 --name 名字 --bundle-id com.a.b" }
    $src = $argv[0]
    if (-not (Test-Path $src)) { Die "没有这个目录: $src" }
    $opt = Arg-Pairs @($argv[1..($argv.Count - 1)])

    $clang = Get-Command clang.exe -ErrorAction SilentlyContinue
    $lld = Get-Command ld64.lld.exe -ErrorAction SilentlyContinue

    # 本机没有 clang 就甩给 WSL 里的 bash 脚本，别在这里硬编
    if ($clang -eq $null -or $lld -eq $null) {
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if ($wsl -ne $null) {
            Write-Host "本机没有 clang，交给 WSL"
            $linux = $src -replace '\\', '/'
            if ($linux -match '^([A-Za-z]):') {
                $letter = $matches[1].ToLower()
                $linux = '/mnt/' + $letter + ($linux -replace '^[A-Za-z]:', '')
            }
            $extra = ''
            if ($argv.Count -gt 1) { $extra = $argv[1..($argv.Count - 1)] -join ' ' }
            $cmd = "bash '$here/ipa' build '$linux' $extra"
            & wsl.exe bash -lc $cmd
            exit $LASTEXITCODE
        }
        Die "没有 clang 也没有 WSL，这台机器编不了源码。`n要么装 LLVM（要带 ld64.lld），要么 wsl --install。`n只想打包或改签的话不用编译器，ipa.ps1 pack / resign 就能用。"
    }

    $name = $opt['--name']
    if (-not $name) { $name = Split-Path -Leaf $src }
    $bid = $opt['--bundle-id']
    if (-not $bid) { $bid = 'com.example.app' }
    $minios = $opt['--min-ios']
    if (-not $minios) { $minios = '14.0' }

    $work = Join-Path (Get-Location) ".build\$name"
    $app = Join-Path $work "Payload\$name.app"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Path $app -Force | Out-Null

    $files = @(Get-ChildItem $src -Recurse -File | Where-Object { $_.Extension -eq '.m' -or $_.Extension -eq '.mm' -or $_.Extension -eq '.c' -or $_.Extension -eq '.cpp' })
    if ($files.Count -eq 0) { Die "$src 里没有 .m/.mm/.c/.cpp" }

    $fw = @()
    if ($opt['--framework']) { $fw += @('-framework', $opt['--framework']) }
    else {
        $usesUIKit = Select-String -Path (Join-Path $src '*.*') -Pattern 'UIKit/' -SimpleMatch -ErrorAction SilentlyContinue
        if ($usesUIKit) { $fw = @('-framework', 'UIKit', '-framework', 'Foundation') }
        else { $fw = @('-framework', 'Foundation') }
    }
    $arc = @()
    foreach ($f in $files) { if ($f.Extension -eq '.m' -or $f.Extension -eq '.mm') { $arc = @('-fobjc-arc'); break } }

    Write-Host "编译 $($files.Count) 个文件，arm64 ios$minios"
    & $clang.Source -target ("arm64-apple-ios" + $minios) -isysroot $sdk `
        -F (Join-Path $sdk 'System\Library\Frameworks') `
        -fuse-ld=lld -O2 -fPIC $arc $fw -o (Join-Path $app $name) $files.FullName
    if ($LASTEXITCODE -ne 0) { Die "clang 编译失败" }

    $tpl = Get-Content (Join-Path $here 'templates\Info.plist') -Raw -Encoding UTF8
    $tpl = $tpl -replace '@NAME@', $name -replace '@BUNDLEID@', $bid -replace '@MINIOS@', $minios
    Set-Content (Join-Path $app 'Info.plist') $tpl -Encoding UTF8
    if ($opt['--icon'] -and (Test-Path $opt['--icon'])) {
        Copy-Item $opt['--icon'] (Join-Path $app 'AppIcon60x60@2x.png')
    }

    $pre = Join-Path ([IO.Path]::GetTempPath()) ('build_' + [guid]::NewGuid().ToString('N') + '.ipa')
    Zip-Dir $work $pre
    $out = $opt['-o']
    if (-not $out) { $out = Join-Path (Get-Location) "dist\$name.ipa" }
    if (Test-Path $zsign) { Sign-Ipa $pre $out } else { Copy-Item $pre $out; Write-Host "没签名，只是打了个包" }
    Write-Host "产物 $out"
}

if ($args.Count -eq 0) {
    Write-Host "ipa-build —— Windows 上打包 / 签名 iOS 安装包"
    Write-Host ""
    Write-Host "  doctor   看环境齐不齐"
    Write-Host "  info     看 ipa/app 的标识、版本、架构、签没签"
    Write-Host "  pack     .app 打成 ipa，可改标识/显示名/版本/图标"
    Write-Host "  resign   已有的 ipa 或 app 重做伪签名，可换标识"
    Write-Host "  build    .m/.c 编成 ipa，需要 clang + SDK，没有就借 WSL"
    exit 0
}

switch ($args[0]) {
    'doctor' { Cmd-Doctor }
    'info'   { Cmd-Info $args[1] }
    'build'  { Cmd-Build @($args[1..($args.Count - 1)]) }
    'pack'   { Cmd-Pack @($args[1..($args.Count - 1)]) }
    'resign' { Cmd-Resign @($args[1..($args.Count - 1)]) }
    default  { Write-Host "不认识的命令: $($args[0])"; exit 1 }
}
