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
    if (-not (Test-Path $dir)) { return $null }
    Get-ChildItem $dir -Recurse -Directory -Filter '*.app' |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
}

function Zip-Dir($src, $out) {
    $parent = Split-Path -Parent $out
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path $out) { Remove-Item $out -Force }
    # 传目录名进去，条目就是 Payload/xxx.app/...，正是 ipa 要的层级
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $out, [IO.Compression.CompressionLevel]::Optimal, $false)
}

# 有 p12 就走真证书签名（zsign -k / -m / -p），没有就走 -a ad-hoc。
# 真证书签名 zsign 会联网查 OCSP 吊销状态，离线时可能变慢或告警，这是它本来行为。
function Sign-Ipa($in, $out, $p12, $prov, $pass) {
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
        $a += @('-o', $out, $in)
    } else {
        if ($prov) { Write-Host "只有描述文件没有 p12，还是按伪签处理" }
        $a = @('-a', '-o', $out, $in)
    }

    # 直接用调用运算符传数组，PowerShell 会给带空格的参数自己加引号；
    # Start-Process 是把数组拼成一行再交给系统，密码里有空格就被拆成两个参数了
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
        Write-Host ("签名     " + $(if ($hasSig) { '有 CodeDirectory' } else { '没签' }))
    }
    if (Test-Path (Join-Path $app '_CodeSignature')) { Write-Host "签名目录 有 _CodeSignature" }
    if ($tmp -ne $null) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Cmd-Pack($argv) {
    if ($argv.Count -eq 0) { Die "用法: ipa.ps1 pack 某.app [-o 输出.ipa] [--bundle-id ...] [--p12 证书 --prov 描述文件 --password 密码]" }
    $src = $argv[0]
    if (-not (Test-Path $src)) { Die "没有这个路径: $src" }
    $opt = Opts @($argv[1..($argv.Count - 1)])

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
    $pl = Read-Plist $app
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
        Sign-Ipa $tmp $out (Opt $opt @('--p12') $null) (Opt $opt @('--prov') $null) (Opt $opt @('--password', '--pass') $null)
    } else {
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
    $opt = Opts @($argv[1..($argv.Count - 1)])

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
        $pl = Read-Plist $a.FullName
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
        $out = Join-Path (Get-Location) "dist/${leaf}_signed.ipa"
    }
    Sign-Ipa $in $out (Opt $opt @('--p12') $null) (Opt $opt @('--prov') $null) (Opt $opt @('--password', '--pass') $null)
    Write-Host "产物 $out"
}

# WSL 里拼命令，每个参数单独用单引号包住，带空格的路径不会被拆开
function Q($s) { "'" + ($s -replace "'", "'\\''") + "'" }

function To-WslPath($p) {
    $s = $p -replace '\\', '/'
    if ($s -match '^([A-Za-z]):') { $s = '/mnt/' + $matches[1].ToLower() + ($s -replace '^[A-Za-z]:', '') }
    return $s
}

function Cmd-Build($argv) {
    if ($argv.Count -eq 0) { Die "用法: ipa.ps1 build 源码目录 --name 名字 --bundle-id com.a.b [--p12 证书 --prov 描述文件 --password 密码]" }
    $src = $argv[0]
    if (-not (Test-Path $src)) { Die "没有这个目录: $src" }
    $opt = Opts @($argv[1..($argv.Count - 1)])

    $clang = Get-Command clang.exe -ErrorAction SilentlyContinue
    $lld = Get-Command ld64.lld.exe -ErrorAction SilentlyContinue

    # 本机没有 clang 就甩给 WSL 里的 bash 脚本，别在这里硬编
    if ($clang -eq $null -or $lld -eq $null) {
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if ($wsl -ne $null) {
            Write-Host "本机没 clang，交给 WSL 编"
            $parts = @('bash', (Q (Join-Path $here 'ipa')), 'build', (Q (To-WslPath (Resolve-Path $src).Path)))
            foreach ($a in $argv[1..($argv.Count - 1)]) {
                if ($a -match '^[A-Za-z]:\\' -or $a -match '^\.\w') { $parts += (Q (To-WslPath $a)) }
                else { $parts += (Q $a) }
            }
            $cmd = $parts -join ' '
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
        Sign-Ipa $pre $out (Opt $opt @('--p12') $null) (Opt $opt @('--prov') $null) (Opt $opt @('--password', '--pass') $null)
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
    'info'   { Cmd-Info $args[1] }
    'build'  { Cmd-Build @($args[1..($args.Count - 1)]) }
    'pack'   { Cmd-Pack @($args[1..($args.Count - 1)]) }
    'resign' { Cmd-Resign @($args[1..($args.Count - 1)]) }
    default  { Write-Host "不认识的命令: $($args[0])"; exit 1 }
}
