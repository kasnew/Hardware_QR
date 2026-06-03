param(
    [string]$Ticket = "",
    [string]$OutputPath = "",
    [switch]$NoOpen,
    [switch]$Invert
)

$ErrorActionPreference = "Stop"

function Test-BadValue {
    param([object]$Value)
    if ($null -eq $Value) { return $true }
    $s = ([string]$Value).Trim()
    if ($s.Length -eq 0) { return $true }
    $bad = @(
        "Not Specified",
        "Not Specified By O.E.M.",
        "To Be Filled By O.E.M.",
        "Default string",
        "Unknown",
        "None",
        "System Serial Number",
        "Base Board Serial Number"
    )
    return $bad -contains $s
}

function Clean-Value {
    param(
        [object]$Value,
        [string]$Fallback = "unk"
    )
    if (Test-BadValue $Value) { return $Fallback }
    $s = ([string]$Value) -replace "[\x00-\x1F\x7F]", ""
    $s = $s -replace "[/|]", "-"
    $s = ($s -replace "\s+", " ").Trim()
    if ($s.Length -eq 0) { return $Fallback }
    return $s
}

function Get-CimOne {
    param(
        [string]$ClassName,
        [string]$Namespace = "root/cimv2"
    )
    try {
        return Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop |
            Select-Object -First 1
    } catch {
        return $null
    }
}

function Get-CimMany {
    param(
        [string]$ClassName,
        [string]$Namespace = "root/cimv2"
    )
    try {
        $items = @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
        return ,$items
    } catch {
        $items = @()
        return ,$items
    }
}

function Format-Gi {
    param([UInt64]$Bytes, [string]$Fallback = "UNKNOWN_RAM")
    if ($Bytes -le 0) { return $Fallback }
    return ("{0}Gi" -f [Math]::Max(1, [Math]::Round($Bytes / 1GB)))
}

function Format-ModuleSize {
    param([UInt64]$Bytes)
    if ($Bytes -le 0) { return "UNKNOWN_SIZE" }
    if ($Bytes -ge 1GB) { return ("{0} GB" -f [Math]::Max(1, [Math]::Round($Bytes / 1GB))) }
    return ("{0} MB" -f [Math]::Max(1, [Math]::Round($Bytes / 1MB)))
}

function Format-DiskSize {
    param([UInt64]$Bytes)
    if ($Bytes -le 0) { return "UNKNOWN_SIZE" }
    if ($Bytes -ge 1TB) {
        $tb = [Math]::Round($Bytes / 1TB, 1)
        return (("{0:N1}" -f $tb) -replace "\.0$", "") + "T"
    }
    return ("{0}G" -f [Math]::Max(1, [Math]::Round($Bytes / 1GB)))
}

function Convert-WmiDate {
    param([object]$DateValue)
    if (Test-BadValue $DateValue) { return "UNKNOWN_BD" }
    try {
        return ([System.Management.ManagementDateTimeConverter]::ToDateTime([string]$DateValue)).ToString("MM-dd-yyyy")
    } catch {
        return (Clean-Value $DateValue "UNKNOWN_BD")
    }
}

function Get-TpmStatus {
    $tpm = Get-CimOne -Namespace "root/cimv2/security/microsofttpm" -ClassName "Win32_Tpm"
    if ($null -eq $tpm) { return "none" }
    $spec = Clean-Value $tpm.SpecVersion "present"
    if ($spec -match "2\.0") { return "2.0" }
    if ($spec -match "1\.2") { return "1.2" }
    return $spec
}

function New-QrPayload {
    param(
        [string]$Ticket,
        [string[]]$BaseSegments
    )
    $raw = @("V/1", ("T/{0}" -f (Clean-Value $Ticket "NO_TICKET"))) + $BaseSegments
    $rawText = $raw -join "|"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($rawText)
    $outStream = New-Object System.IO.MemoryStream
    $gzip = New-Object System.IO.Compression.GZipStream($outStream, [System.IO.Compression.CompressionMode]::Compress)
    $gzip.Write($bytes, 0, $bytes.Length)
    $gzip.Dispose()
    $wrapped = "V/1|Z/" + [Convert]::ToBase64String($outStream.ToArray())
    if ($wrapped.Length -lt $rawText.Length) {
        return [pscustomobject]@{ Text = $wrapped; Raw = $rawText; Mode = "gzip+base64" }
    }
    return [pscustomobject]@{ Text = $rawText; Raw = $rawText; Mode = "raw" }
}

function Add-Segment {
    param(
        [System.Collections.Generic.List[string]]$Segments,
        [string]$Tag,
        [object[]]$Fields
    )
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add((Clean-Value $Tag $Tag))
    foreach ($field in $Fields) {
        [void]$parts.Add((Clean-Value $field "unk"))
    }
    [void]$Segments.Add(($parts -join "/"))
}

$script:QrExp = New-Object int[] 512
$script:QrLog = New-Object int[] 256
$script:QrGfReady = $false

function Initialize-QrGalois {
    if ($script:QrGfReady) { return }
    $x = 1
    for ($i = 0; $i -lt 255; $i++) {
        $script:QrExp[$i] = $x
        $script:QrLog[$x] = $i
        $x = $x -shl 1
        if (($x -band 0x100) -ne 0) {
            $x = $x -bxor 0x11D
        }
    }
    for ($i = 255; $i -lt 512; $i++) {
        $script:QrExp[$i] = $script:QrExp[$i - 255]
    }
    $script:QrGfReady = $true
}

function Invoke-GfMul {
    param([int]$X, [int]$Y)
    if ($X -eq 0 -or $Y -eq 0) { return 0 }
    return $script:QrExp[$script:QrLog[$X] + $script:QrLog[$Y]]
}

function New-RsGenerator {
    param([int]$Degree)
    Initialize-QrGalois
    [int[]]$poly = @(1)
    for ($i = 0; $i -lt $Degree; $i++) {
        $root = $script:QrExp[$i]
        $next = New-Object int[] ($poly.Length + 1)
        for ($j = 0; $j -lt $poly.Length; $j++) {
            $next[$j] = $next[$j] -bxor $poly[$j]
            $next[$j + 1] = $next[$j + 1] -bxor (Invoke-GfMul $poly[$j] $root)
        }
        $poly = $next
    }
    return ,$poly
}

function New-RsRemainder {
    param([int[]]$Data, [int]$EccLength)
    $gen = New-RsGenerator $EccLength
    $rem = New-Object int[] $EccLength
    foreach ($b in $Data) {
        $factor = $b -bxor $rem[0]
        for ($i = 0; $i -lt ($EccLength - 1); $i++) {
            $rem[$i] = $rem[$i + 1]
        }
        $rem[$EccLength - 1] = 0
        for ($i = 0; $i -lt $EccLength; $i++) {
            $rem[$i] = $rem[$i] -bxor (Invoke-GfMul $gen[$i + 1] $factor)
        }
    }
    return ,$rem
}

$script:QrEcL = @(
    [pscustomobject]@{Ecc=7;  Blocks=@([pscustomobject]@{Count=1;  Data=19})},
    [pscustomobject]@{Ecc=10; Blocks=@([pscustomobject]@{Count=1;  Data=34})},
    [pscustomobject]@{Ecc=15; Blocks=@([pscustomobject]@{Count=1;  Data=55})},
    [pscustomobject]@{Ecc=20; Blocks=@([pscustomobject]@{Count=1;  Data=80})},
    [pscustomobject]@{Ecc=26; Blocks=@([pscustomobject]@{Count=1;  Data=108})},
    [pscustomobject]@{Ecc=18; Blocks=@([pscustomobject]@{Count=2;  Data=68})},
    [pscustomobject]@{Ecc=20; Blocks=@([pscustomobject]@{Count=2;  Data=78})},
    [pscustomobject]@{Ecc=24; Blocks=@([pscustomobject]@{Count=2;  Data=97})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=2;  Data=116})},
    [pscustomobject]@{Ecc=18; Blocks=@([pscustomobject]@{Count=2;  Data=68},  [pscustomobject]@{Count=2; Data=69})},
    [pscustomobject]@{Ecc=20; Blocks=@([pscustomobject]@{Count=4;  Data=81})},
    [pscustomobject]@{Ecc=24; Blocks=@([pscustomobject]@{Count=2;  Data=92},  [pscustomobject]@{Count=2; Data=93})},
    [pscustomobject]@{Ecc=26; Blocks=@([pscustomobject]@{Count=4;  Data=107})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=3;  Data=115}, [pscustomobject]@{Count=1; Data=116})},
    [pscustomobject]@{Ecc=22; Blocks=@([pscustomobject]@{Count=5;  Data=87},  [pscustomobject]@{Count=1; Data=88})},
    [pscustomobject]@{Ecc=24; Blocks=@([pscustomobject]@{Count=5;  Data=98},  [pscustomobject]@{Count=1; Data=99})},
    [pscustomobject]@{Ecc=28; Blocks=@([pscustomobject]@{Count=1;  Data=107}, [pscustomobject]@{Count=5; Data=108})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=5;  Data=120}, [pscustomobject]@{Count=1; Data=121})},
    [pscustomobject]@{Ecc=28; Blocks=@([pscustomobject]@{Count=3;  Data=113}, [pscustomobject]@{Count=4; Data=114})},
    [pscustomobject]@{Ecc=28; Blocks=@([pscustomobject]@{Count=3;  Data=107}, [pscustomobject]@{Count=5; Data=108})},
    [pscustomobject]@{Ecc=28; Blocks=@([pscustomobject]@{Count=4;  Data=116}, [pscustomobject]@{Count=4; Data=117})},
    [pscustomobject]@{Ecc=28; Blocks=@([pscustomobject]@{Count=2;  Data=111}, [pscustomobject]@{Count=7; Data=112})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=4;  Data=121}, [pscustomobject]@{Count=5; Data=122})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=6;  Data=117}, [pscustomobject]@{Count=4; Data=118})},
    [pscustomobject]@{Ecc=26; Blocks=@([pscustomobject]@{Count=8;  Data=106}, [pscustomobject]@{Count=4; Data=107})},
    [pscustomobject]@{Ecc=28; Blocks=@([pscustomobject]@{Count=10; Data=114}, [pscustomobject]@{Count=2; Data=115})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=8;  Data=122}, [pscustomobject]@{Count=4; Data=123})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=3;  Data=117}, [pscustomobject]@{Count=10; Data=118})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=7;  Data=116}, [pscustomobject]@{Count=7; Data=117})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=5;  Data=115}, [pscustomobject]@{Count=10; Data=116})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=13; Data=115}, [pscustomobject]@{Count=3; Data=116})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=17; Data=115})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=17; Data=115}, [pscustomobject]@{Count=1; Data=116})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=13; Data=115}, [pscustomobject]@{Count=6; Data=116})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=12; Data=121}, [pscustomobject]@{Count=7; Data=122})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=6;  Data=121}, [pscustomobject]@{Count=14; Data=122})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=17; Data=122}, [pscustomobject]@{Count=4; Data=123})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=4;  Data=122}, [pscustomobject]@{Count=18; Data=123})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=20; Data=117}, [pscustomobject]@{Count=4; Data=118})},
    [pscustomobject]@{Ecc=30; Blocks=@([pscustomobject]@{Count=19; Data=118}, [pscustomobject]@{Count=6; Data=119})}
)

$script:QrAlign = @(
    @(), @(6,18), @(6,22), @(6,26), @(6,30), @(6,34), @(6,22,38), @(6,24,42),
    @(6,26,46), @(6,28,50), @(6,30,54), @(6,32,58), @(6,34,62),
    @(6,26,46,66), @(6,26,48,70), @(6,26,50,74), @(6,30,54,78),
    @(6,30,56,82), @(6,30,58,86), @(6,34,62,90), @(6,28,50,72,94),
    @(6,26,50,74,98), @(6,30,54,78,102), @(6,28,54,80,106),
    @(6,32,58,84,110), @(6,30,58,86,114), @(6,34,62,90,118),
    @(6,26,50,74,98,122), @(6,30,54,78,102,126), @(6,26,52,78,104,130),
    @(6,30,56,82,108,134), @(6,34,60,86,112,138), @(6,30,58,86,114,142),
    @(6,34,62,90,118,146), @(6,30,54,78,102,126,150), @(6,24,50,76,102,128,154),
    @(6,28,54,80,106,132,158), @(6,32,58,84,110,136,162), @(6,26,54,82,110,138,166),
    @(6,30,58,86,114,142,170)
)

function Get-QrDataCodewords {
    param([int]$Version)
    $info = $script:QrEcL[$Version - 1]
    $sum = 0
    foreach ($g in $info.Blocks) {
        $sum += $g.Count * $g.Data
    }
    return $sum
}

function Add-Bits {
    param(
        [System.Collections.Generic.List[int]]$Bits,
        [int]$Value,
        [int]$Length
    )
    for ($i = $Length - 1; $i -ge 0; $i--) {
        [void]$Bits.Add(($Value -shr $i) -band 1)
    }
}

function New-QrCodewords {
    param([string]$Text, [int]$Version)
    $dataBytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $dataCwCount = Get-QrDataCodewords $Version
    $capacityBits = $dataCwCount * 8
    $countBits = if ($Version -le 9) { 8 } else { 16 }
    $bits = New-Object System.Collections.Generic.List[int]
    Add-Bits $bits 0x4 4
    Add-Bits $bits $dataBytes.Length $countBits
    foreach ($b in $dataBytes) { Add-Bits $bits ([int]$b) 8 }
    $remaining = $capacityBits - $bits.Count
    if ($remaining -lt 0) { throw "Payload is too large for QR version $Version." }
    for ($i = 0; $i -lt [Math]::Min(4, $remaining); $i++) { [void]$bits.Add(0) }
    while (($bits.Count % 8) -ne 0) { [void]$bits.Add(0) }

    $data = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $bits.Count; $i += 8) {
        $cw = 0
        for ($j = 0; $j -lt 8; $j++) {
            $cw = ($cw -shl 1) -bor $bits[$i + $j]
        }
        [void]$data.Add($cw)
    }
    $pad = @(0xEC, 0x11)
    $padIndex = 0
    while ($data.Count -lt $dataCwCount) {
        [void]$data.Add($pad[$padIndex % 2])
        $padIndex++
    }

    $info = $script:QrEcL[$Version - 1]
    $blocks = New-Object System.Collections.Generic.List[object]
    $offset = 0
    foreach ($group in $info.Blocks) {
        for ($i = 0; $i -lt $group.Count; $i++) {
            $blockData = New-Object int[] $group.Data
            for ($j = 0; $j -lt $group.Data; $j++) {
                $blockData[$j] = $data[$offset + $j]
            }
            $offset += $group.Data
            $ecc = New-RsRemainder $blockData $info.Ecc
            [void]$blocks.Add([pscustomobject]@{ Data = $blockData; Ecc = $ecc })
        }
    }

    $all = New-Object System.Collections.Generic.List[int]
    $maxData = 0
    foreach ($block in $blocks) {
        if ($block.Data.Length -gt $maxData) { $maxData = $block.Data.Length }
    }
    for ($i = 0; $i -lt $maxData; $i++) {
        foreach ($block in $blocks) {
            if ($i -lt $block.Data.Length) { [void]$all.Add($block.Data[$i]) }
        }
    }
    for ($i = 0; $i -lt $info.Ecc; $i++) {
        foreach ($block in $blocks) { [void]$all.Add($block.Ecc[$i]) }
    }
    return ,[int[]]$all.ToArray()
}

function Test-QrMask {
    param([int]$Mask, [int]$X, [int]$Y)
    switch ($Mask) {
        0 { return (($X + $Y) % 2) -eq 0 }
        1 { return ($Y % 2) -eq 0 }
        2 { return ($X % 3) -eq 0 }
        3 { return (($X + $Y) % 3) -eq 0 }
        4 { return ((([Math]::Floor($Y / 2) + [Math]::Floor($X / 3)) % 2) -eq 0) }
        5 { return (((($X * $Y) % 2) + (($X * $Y) % 3)) -eq 0) }
        6 { return (((($X * $Y) % 2) + (($X * $Y) % 3)) % 2) -eq 0 }
        7 { return (((($X + $Y) % 2) + (($X * $Y) % 3)) % 2) -eq 0 }
    }
}

function Get-QrFormatBits {
    param([int]$Mask)
    $data = (1 -shl 3) -bor $Mask
    $rem = $data -shl 10
    for ($i = 14; $i -ge 10; $i--) {
        if (((($rem -shr $i) -band 1) -ne 0)) {
            $rem = $rem -bxor (0x537 -shl ($i - 10))
        }
    }
    return ((($data -shl 10) -bor ($rem -band 0x3FF)) -bxor 0x5412)
}

function Get-QrVersionBits {
    param([int]$Version)
    $rem = $Version -shl 12
    for ($i = 17; $i -ge 12; $i--) {
        if (((($rem -shr $i) -band 1) -ne 0)) {
            $rem = $rem -bxor (0x1F25 -shl ($i - 12))
        }
    }
    return (($Version -shl 12) -bor ($rem -band 0xFFF))
}

function Set-MatrixModule {
    param([int[,]]$Matrix, [int]$X, [int]$Y, [bool]$Dark)
    $Matrix[$X, $Y] = $(if ($Dark) { 1 } else { 0 })
}

function Add-QrFormatInfo {
    param([int[,]]$Matrix, [int]$Mask)
    $size = $Matrix.GetLength(0)
    $bits = Get-QrFormatBits $Mask
    for ($i = 0; $i -le 5; $i++) { Set-MatrixModule $Matrix 8 $i (((($bits -shr $i) -band 1) -ne 0)) }
    Set-MatrixModule $Matrix 8 7 (((($bits -shr 6) -band 1) -ne 0))
    Set-MatrixModule $Matrix 8 8 (((($bits -shr 7) -band 1) -ne 0))
    Set-MatrixModule $Matrix 7 8 (((($bits -shr 8) -band 1) -ne 0))
    for ($i = 9; $i -le 14; $i++) { Set-MatrixModule $Matrix (14 - $i) 8 (((($bits -shr $i) -band 1) -ne 0)) }
    for ($i = 0; $i -le 7; $i++) { Set-MatrixModule $Matrix ($size - 1 - $i) 8 (((($bits -shr $i) -band 1) -ne 0)) }
    for ($i = 8; $i -le 14; $i++) { Set-MatrixModule $Matrix 8 ($size - 15 + $i) (((($bits -shr $i) -band 1) -ne 0)) }
    Set-MatrixModule $Matrix 8 ($size - 8) $true
}

function Add-QrVersionInfo {
    param([int[,]]$Matrix, [int]$Version)
    if ($Version -lt 7) { return }
    $size = $Matrix.GetLength(0)
    $bits = Get-QrVersionBits $Version
    for ($i = 0; $i -lt 18; $i++) {
        $dark = ((($bits -shr $i) -band 1) -ne 0)
        $a = $size - 11 + ($i % 3)
        $b = [Math]::Floor($i / 3)
        Set-MatrixModule $Matrix $a $b $dark
        Set-MatrixModule $Matrix $b $a $dark
    }
}

function Copy-QrMatrix {
    param([int[,]]$Matrix)
    $size = $Matrix.GetLength(0)
    $copy = New-Object "int[,]" $size, $size
    for ($y = 0; $y -lt $size; $y++) {
        for ($x = 0; $x -lt $size; $x++) {
            $copy[$x, $y] = $Matrix[$x, $y]
        }
    }
    return ,$copy
}

function Get-QrPenalty {
    param([int[,]]$Matrix)
    $size = $Matrix.GetLength(0)
    $penalty = 0
    for ($y = 0; $y -lt $size; $y++) {
        $runColor = $Matrix[0, $y]
        $runLen = 1
        for ($x = 1; $x -lt $size; $x++) {
            if ($Matrix[$x, $y] -eq $runColor) {
                $runLen++
            } else {
                if ($runLen -ge 5) { $penalty += 3 + ($runLen - 5) }
                $runColor = $Matrix[$x, $y]
                $runLen = 1
            }
        }
        if ($runLen -ge 5) { $penalty += 3 + ($runLen - 5) }
    }
    for ($x = 0; $x -lt $size; $x++) {
        $runColor = $Matrix[$x, 0]
        $runLen = 1
        for ($y = 1; $y -lt $size; $y++) {
            if ($Matrix[$x, $y] -eq $runColor) {
                $runLen++
            } else {
                if ($runLen -ge 5) { $penalty += 3 + ($runLen - 5) }
                $runColor = $Matrix[$x, $y]
                $runLen = 1
            }
        }
        if ($runLen -ge 5) { $penalty += 3 + ($runLen - 5) }
    }
    for ($y = 0; $y -lt ($size - 1); $y++) {
        for ($x = 0; $x -lt ($size - 1); $x++) {
            $c = $Matrix[$x, $y]
            if ($Matrix[$x + 1, $y] -eq $c -and $Matrix[$x, $y + 1] -eq $c -and $Matrix[$x + 1, $y + 1] -eq $c) {
                $penalty += 3
            }
        }
    }
    $p1 = @(1,0,1,1,1,0,1,0,0,0,0)
    $p2 = @(0,0,0,0,1,0,1,1,1,0,1)
    for ($y = 0; $y -lt $size; $y++) {
        for ($x = 0; $x -le ($size - 11); $x++) {
            $m1 = $true; $m2 = $true
            for ($k = 0; $k -lt 11; $k++) {
                if ($Matrix[$x + $k, $y] -ne $p1[$k]) { $m1 = $false }
                if ($Matrix[$x + $k, $y] -ne $p2[$k]) { $m2 = $false }
            }
            if ($m1 -or $m2) { $penalty += 40 }
        }
    }
    for ($x = 0; $x -lt $size; $x++) {
        for ($y = 0; $y -le ($size - 11); $y++) {
            $m1 = $true; $m2 = $true
            for ($k = 0; $k -lt 11; $k++) {
                if ($Matrix[$x, $y + $k] -ne $p1[$k]) { $m1 = $false }
                if ($Matrix[$x, $y + $k] -ne $p2[$k]) { $m2 = $false }
            }
            if ($m1 -or $m2) { $penalty += 40 }
        }
    }
    $dark = 0
    for ($y = 0; $y -lt $size; $y++) {
        for ($x = 0; $x -lt $size; $x++) {
            if ($Matrix[$x, $y] -eq 1) { $dark++ }
        }
    }
    $total = $size * $size
    $penalty += [Math]::Floor([Math]::Abs($dark * 20 - $total * 10) / $total) * 10
    return $penalty
}

function New-QrMatrix {
    param([string]$Text)
    $dataBytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $version = 0
    for ($v = 1; $v -le 40; $v++) {
        $countBits = if ($v -le 9) { 8 } else { 16 }
        $needed = 4 + $countBits + ($dataBytes.Length * 8)
        if ($needed -le ((Get-QrDataCodewords $v) * 8)) {
            $version = $v
            break
        }
    }
    if ($version -eq 0) { throw "QR payload is too large for version 40-L." }

    $codewords = New-QrCodewords $Text $version
    $size = 17 + 4 * $version
    $matrix = New-Object "int[,]" $size, $size
    $isFunc = New-Object "bool[,]" $size, $size

    function SetFunc([int]$X, [int]$Y, [bool]$Dark) {
        if ($X -lt 0 -or $Y -lt 0 -or $X -ge $size -or $Y -ge $size) { return }
        $matrix[$X, $Y] = $(if ($Dark) { 1 } else { 0 })
        $isFunc[$X, $Y] = $true
    }
    function AddFinder([int]$Cx, [int]$Cy) {
        for ($dy = -4; $dy -le 4; $dy++) {
            for ($dx = -4; $dx -le 4; $dx++) {
                $dist = [Math]::Max([Math]::Abs($dx), [Math]::Abs($dy))
                $dark = ($dist -ne 2 -and $dist -ne 4)
                SetFunc ($Cx + $dx) ($Cy + $dy) $dark
            }
        }
    }
    function AddAlignment([int]$Cx, [int]$Cy) {
        for ($dy = -2; $dy -le 2; $dy++) {
            for ($dx = -2; $dx -le 2; $dx++) {
                $dist = [Math]::Max([Math]::Abs($dx), [Math]::Abs($dy))
                SetFunc ($Cx + $dx) ($Cy + $dy) ($dist -ne 1)
            }
        }
    }
    function ReserveFormat() {
        for ($i = 0; $i -le 5; $i++) { SetFunc 8 $i $false; SetFunc $i 8 $false }
        SetFunc 8 7 $false; SetFunc 8 8 $false; SetFunc 7 8 $false
        for ($i = 9; $i -le 14; $i++) { SetFunc (14 - $i) 8 $false }
        for ($i = 0; $i -le 7; $i++) { SetFunc ($size - 1 - $i) 8 $false }
        for ($i = 8; $i -le 14; $i++) { SetFunc 8 ($size - 15 + $i) $false }
        SetFunc 8 ($size - 8) $true
    }
    function ReserveVersion() {
        if ($version -lt 7) { return }
        for ($i = 0; $i -lt 18; $i++) {
            $a = $size - 11 + ($i % 3)
            $b = [Math]::Floor($i / 3)
            SetFunc $a $b $false
            SetFunc $b $a $false
        }
    }

    AddFinder 3 3
    AddFinder ($size - 4) 3
    AddFinder 3 ($size - 4)
    for ($i = 8; $i -lt ($size - 8); $i++) {
        SetFunc 6 $i (($i % 2) -eq 0)
        SetFunc $i 6 (($i % 2) -eq 0)
    }
    $align = $script:QrAlign[$version - 1]
    foreach ($cy in $align) {
        foreach ($cx in $align) {
            if (($cx -le 8 -and $cy -le 8) -or ($cx -ge ($size - 9) -and $cy -le 8) -or ($cx -le 8 -and $cy -ge ($size - 9))) {
                continue
            }
            AddAlignment $cx $cy
        }
    }
    ReserveFormat
    ReserveVersion

    $bitIndex = 0
    $upward = $true
    for ($right = $size - 1; $right -ge 1; $right -= 2) {
        if ($right -eq 6) { $right-- }
        for ($vert = 0; $vert -lt $size; $vert++) {
            $y = if ($upward) { $size - 1 - $vert } else { $vert }
            for ($j = 0; $j -lt 2; $j++) {
                $x = $right - $j
                if (-not $isFunc[$x, $y]) {
                    $bit = 0
                    if ($bitIndex -lt ($codewords.Length * 8)) {
                        $bit = ($codewords[[Math]::Floor($bitIndex / 8)] -shr (7 - ($bitIndex % 8))) -band 1
                        $bitIndex++
                    }
                    $matrix[$x, $y] = $bit
                }
            }
        }
        $upward = -not $upward
    }

    $best = $null
    $bestPenalty = [int]::MaxValue
    $bestMask = 0
    for ($mask = 0; $mask -lt 8; $mask++) {
        $candidate = Copy-QrMatrix $matrix
        for ($y = 0; $y -lt $size; $y++) {
            for ($x = 0; $x -lt $size; $x++) {
                if (-not $isFunc[$x, $y] -and (Test-QrMask $mask $x $y)) {
                    $candidate[$x, $y] = $candidate[$x, $y] -bxor 1
                }
            }
        }
        Add-QrFormatInfo $candidate $mask
        Add-QrVersionInfo $candidate $version
        $penalty = Get-QrPenalty $candidate
        if ($penalty -lt $bestPenalty) {
            $bestPenalty = $penalty
            $best = $candidate
            $bestMask = $mask
        }
    }

    return [pscustomobject]@{ Matrix = $best; Size = $size; Version = $version; Mask = $bestMask }
}

function Save-QrBmp {
    param(
        [int[,]]$Matrix,
        [string]$Path,
        [int]$Scale = 8,
        [int]$QuietZone = 4,
        [switch]$Invert
    )
    $size = $Matrix.GetLength(0)
    $width = ($size + $QuietZone * 2) * $Scale
    $height = $width
    $stride = [int]([Math]::Ceiling(($width * 3) / 4.0) * 4)
    $imageSize = $stride * $height
    $fileSize = 54 + $imageSize
    $padding = New-Object byte[] ($stride - ($width * 3))

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $bw = $null
    try {
        $bw = New-Object System.IO.BinaryWriter($fs)
        $bw.Write([byte[]][System.Text.Encoding]::ASCII.GetBytes("BM"))
        $bw.Write([UInt32]$fileSize)
        $bw.Write([UInt16]0)
        $bw.Write([UInt16]0)
        $bw.Write([UInt32]54)
        $bw.Write([UInt32]40)
        $bw.Write([Int32]$width)
        $bw.Write([Int32]$height)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]24)
        $bw.Write([UInt32]0)
        $bw.Write([UInt32]$imageSize)
        $bw.Write([Int32]2835)
        $bw.Write([Int32]2835)
        $bw.Write([UInt32]0)
        $bw.Write([UInt32]0)

        for ($py = $height - 1; $py -ge 0; $py--) {
            for ($px = 0; $px -lt $width; $px++) {
                $mx = [Math]::Floor($px / $Scale) - $QuietZone
                $my = [Math]::Floor($py / $Scale) - $QuietZone
                $dark = $false
                if ($mx -ge 0 -and $my -ge 0 -and $mx -lt $size -and $my -lt $size) {
                    $dark = $Matrix[$mx, $my] -eq 1
                }
                $blackPixel = if ($Invert) { -not $dark } else { $dark }
                $v = if ($blackPixel) { [byte]0 } else { [byte]255 }
                $bw.Write($v); $bw.Write($v); $bw.Write($v)
            }
            if ($padding.Length -gt 0) { $bw.Write($padding) }
        }
    } finally {
        if ($bw) { $bw.Dispose() }
        $fs.Dispose()
    }
}

function Show-QrConsole {
    param(
        [int[,]]$Matrix,
        [switch]$Invert
    )
    $size = $Matrix.GetLength(0)
    $quiet = 2
    for ($y = -$quiet; $y -lt ($size + $quiet); $y++) {
        $sb = New-Object System.Text.StringBuilder
        for ($x = -$quiet; $x -lt ($size + $quiet); $x++) {
            $dark = $false
            if ($x -ge 0 -and $y -ge 0 -and $x -lt $size -and $y -lt $size) {
                $dark = $Matrix[$x, $y] -eq 1
            }
            if ($Invert) { $dark = -not $dark }
            [void]$sb.Append($(if ($dark) { "██" } else { "  " }))
        }
        Write-Host $sb.ToString()
    }
}

if ([string]::IsNullOrWhiteSpace($Ticket)) {
    $Ticket = Read-Host "Enter Ticket Number"
}
if ([string]::IsNullOrWhiteSpace($Ticket)) { $Ticket = "NO_TICKET" }

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $scriptDir "hardware-qr.bmp"
}
$payloadPath = [System.IO.Path]::ChangeExtension($OutputPath, ".payload.txt")

$cpuRows = Get-CimMany "Win32_Processor"
$cpuName = if ($cpuRows.Count -gt 0) { Clean-Value $cpuRows[0].Name "UNKNOWN_CPU" } else { "UNKNOWN_CPU" }
$cores = 0
$threads = 0
foreach ($cpu in $cpuRows) {
    $cores += [int]($cpu.NumberOfCores)
    $threads += [int]($cpu.NumberOfLogicalProcessors)
}
if ($cores -le 0) { $cores = "UNKNOWN_CT" }
if ($threads -le 0) { $threads = "UNKNOWN_CT" }

$computer = Get-CimOne "Win32_ComputerSystem"
$bios = Get-CimOne "Win32_BIOS"
$product = Get-CimOne "Win32_ComputerSystemProduct"
$baseBoard = Get-CimOne "Win32_BaseBoard"
$enclosure = Get-CimOne "Win32_SystemEnclosure"

$scanDt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$ramTotal = if ($computer -and $computer.TotalPhysicalMemory) { Format-Gi ([UInt64]$computer.TotalPhysicalMemory) } else { "UNKNOWN_RAM" }
$systemManufacturer = if ($computer) { Clean-Value $computer.Manufacturer "UNKNOWN_SM" } else { "UNKNOWN_SM" }
$productName = if ($computer) { Clean-Value $computer.Model "UNKNOWN_PN" } else { "UNKNOWN_PN" }
$systemSerial = if ($bios) { Clean-Value $bios.SerialNumber "UNKNOWN_SS" } else { "UNKNOWN_SS" }
$systemUuid = if ($product) { Clean-Value $product.UUID "UNKNOWN_UUID" } else { "UNKNOWN_UUID" }
$assetTag = if ($enclosure) { Clean-Value $enclosure.SMBIOSAssetTag "UNKNOWN_AT" } else { "UNKNOWN_AT" }
$boardName = if ($baseBoard) { ((Clean-Value $baseBoard.Manufacturer "") + " " + (Clean-Value $baseBoard.Product "")).Trim() } else { "" }
if ($boardName.Length -eq 0) { $boardName = "UNKNOWN_MB" }
$boardSerial = if ($baseBoard) { Clean-Value $baseBoard.SerialNumber "UNKNOWN_MB_SN" } else { "UNKNOWN_MB_SN" }
$biosVersion = if ($bios) { Clean-Value $bios.SMBIOSBIOSVersion "UNKNOWN_BIOS" } else { "UNKNOWN_BIOS" }
$biosDate = if ($bios) { Convert-WmiDate $bios.ReleaseDate } else { "UNKNOWN_BD" }
$biosFull = if ($bios) {
    Clean-Value ((Clean-Value $bios.Manufacturer "") + " " + (Clean-Value $bios.SMBIOSBIOSVersion "") + " " + (Clean-Value $bios.Version "")).Trim() "UNKNOWN_BF"
} else { "UNKNOWN_BF" }
$tpmStatus = Get-TpmStatus

$segments = New-Object System.Collections.Generic.List[string]
Add-Segment $segments "DT" @($scanDt)
Add-Segment $segments "C" @($cpuName)
Add-Segment $segments "CT" @($cores, $threads)
Add-Segment $segments "R" @($ramTotal)
Add-Segment $segments "SM" @($systemManufacturer)
Add-Segment $segments "PN" @($productName)
Add-Segment $segments "SS" @($systemSerial)
Add-Segment $segments "UUID" @($systemUuid)
Add-Segment $segments "AT" @($assetTag)
Add-Segment $segments "M" @($boardName)
Add-Segment $segments "MS" @($boardSerial)
Add-Segment $segments "B" @($biosVersion)
Add-Segment $segments "BD" @($biosDate)
Add-Segment $segments "BF" @($biosFull)
Add-Segment $segments "TPM" @($tpmStatus)

$ramModules = Get-CimMany "Win32_PhysicalMemory"
foreach ($module in $ramModules) {
    if (-not $module.Capacity) { continue }
    $slot = Clean-Value $(if ($module.DeviceLocator) { $module.DeviceLocator } else { $module.BankLabel }) "UNKNOWN_SLOT"
    $speed = if ($module.ConfiguredClockSpeed) { "$($module.ConfiguredClockSpeed)MT" } elseif ($module.Speed) { "$($module.Speed)MT" } else { "UNK" }
    Add-Segment $segments "RM" @(
        $slot,
        (Format-ModuleSize ([UInt64]$module.Capacity)),
        $speed,
        (Clean-Value $module.PartNumber "UNKNOWN_PN"),
        (Clean-Value $module.SerialNumber "UNKNOWN_SN")
    )
}

$gpus = Get-CimMany "Win32_VideoController"
foreach ($gpu in $gpus) {
    $name = Clean-Value $gpu.Name ""
    if ($name.Length -gt 0) { Add-Segment $segments "G" @($name) }
}

$physicalDisks = @()
try { $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $physicalDisks = @() }
$disks = Get-CimMany "Win32_DiskDrive"
foreach ($disk in $disks) {
    $serial = Clean-Value $disk.SerialNumber "UNKNOWN_SERIAL"
    $pd = $null
    if ($serial -ne "UNKNOWN_SERIAL") {
        $pd = $physicalDisks | Where-Object { (Clean-Value $_.SerialNumber "") -eq $serial } | Select-Object -First 1
    }
    $bus = if ($pd -and $pd.BusType) { Clean-Value $pd.BusType "unk" } else { Clean-Value $disk.InterfaceType "unk" }
    $media = "unk"
    if ($pd -and $pd.MediaType -and "$($pd.MediaType)" -ne "Unspecified") {
        $media = (Clean-Value $pd.MediaType "unk").ToLowerInvariant()
    } elseif ($disk.Model -match "SSD|NVMe") {
        $media = "ssd"
    }
    $smart = "UNKNOWN"
    if ($pd -and $pd.HealthStatus) {
        switch ("$($pd.HealthStatus)") {
            "Healthy" { $smart = "PASSED" }
            "Unhealthy" { $smart = "FAILED" }
            default { $smart = "UNKNOWN" }
        }
    }
    Add-Segment $segments "D" @(
        (Clean-Value $disk.Model "UNKNOWN_MODEL"),
        $serial,
        (Format-DiskSize ([UInt64]$disk.Size)),
        $bus.ToLowerInvariant(),
        $media,
        $smart
    )
}

$batteryStatus = @{
    1 = "Discharging"; 2 = "AC"; 3 = "Fully Charged"; 4 = "Low"; 5 = "Critical";
    6 = "Charging"; 7 = "Charging High"; 8 = "Charging Low"; 9 = "Charging Critical";
    10 = "Undefined"; 11 = "Partially Charged"
}
$batteries = Get-CimMany "Win32_Battery"
foreach ($battery in $batteries) {
    $status = if ($batteryStatus.ContainsKey([int]$battery.BatteryStatus)) { $batteryStatus[[int]$battery.BatteryStatus] } else { "unk" }
    Add-Segment $segments "BAT" @(
        (Clean-Value $battery.DeviceID "BAT"),
        $status,
        (Clean-Value $battery.EstimatedChargeRemaining "unk"),
        "unk",
        "unk",
        (Clean-Value $battery.Name "unk"),
        "unk",
        "unk"
    )
}

$payload = New-QrPayload -Ticket $Ticket -BaseSegments ([string[]]$segments.ToArray())

Clear-Host
Write-Host "--- Hardware Data Collected ---"
Write-Host ("Ticket      : {0}" -f $Ticket)
Write-Host ("Scanned     : {0}" -f $scanDt)
Write-Host ("CPU         : {0} ({1}/{2} cores/threads)" -f $cpuName, $cores, $threads)
Write-Host ("RAM         : {0}" -f $ramTotal)
if ($ramModules.Count -gt 0) {
    foreach ($module in $ramModules) {
        if (-not $module.Capacity) { continue }
        Write-Host ("  DIMM      : {0} {1} {2} {3}" -f (Clean-Value $module.DeviceLocator "UNKNOWN_SLOT"), (Format-ModuleSize ([UInt64]$module.Capacity)), (Clean-Value $module.PartNumber "UNKNOWN_PN"), (Clean-Value $module.SerialNumber "UNKNOWN_SN"))
    }
} else {
    Write-Host "  DIMM      : (not available)"
}
Write-Host ("System      : {0} {1} (SN: {2})" -f $systemManufacturer, $productName, $systemSerial)
Write-Host ("Asset tag   : {0}" -f $assetTag)
Write-Host ("UUID        : {0}" -f $systemUuid)
Write-Host ("Motherboard : {0} (SN: {1})" -f $boardName, $boardSerial)
Write-Host ("BIOS        : {0} ({1})" -f $biosVersion, $biosDate)
Write-Host ("BIOS full   : {0}" -f $biosFull)
Write-Host ("TPM         : {0}" -f $tpmStatus)
if ($gpus.Count -gt 0) {
    foreach ($gpu in $gpus) { Write-Host ("  GPU       : {0}" -f (Clean-Value $gpu.Name "UNKNOWN_GPU")) }
} else {
    Write-Host "  GPU       : (not detected)"
}
if ($batteries.Count -gt 0) {
    foreach ($battery in $batteries) { Write-Host ("  Battery   : {0} {1}%" -f (Clean-Value $battery.DeviceID "BAT"), (Clean-Value $battery.EstimatedChargeRemaining "unk")) }
} else {
    Write-Host "  Battery   : (none)"
}
if ($disks.Count -gt 0) {
    foreach ($disk in $disks) { Write-Host ("  Drive     : {0} {1} {2}" -f (Clean-Value $disk.Model "UNKNOWN_MODEL"), (Clean-Value $disk.SerialNumber "UNKNOWN_SERIAL"), (Format-DiskSize ([UInt64]$disk.Size))) }
} else {
    Write-Host "  Drive     : (none)"
}
Write-Host ("QR schema   : v1 ({0})" -f $payload.Mode)
Write-Host "-------------------------------"
Read-Host "Press Enter to generate QR Code" | Out-Null

$qr = New-QrMatrix $payload.Text
Save-QrBmp -Matrix $qr.Matrix -Path $OutputPath -Scale 8 -QuietZone 4 -Invert:$Invert
Set-Content -Path $payloadPath -Value $payload.Text -Encoding ASCII
$resolvedOutputPath = (Resolve-Path $OutputPath).Path
$resolvedPayloadPath = (Resolve-Path $payloadPath).Path

Clear-Host
Write-Host ("Ticket      : {0}" -f $Ticket)
Write-Host ("QR version  : {0}-L, mask {1}" -f $qr.Version, $qr.Mask)
Write-Host ("QR payload  : {0}" -f $payload.Mode)
Write-Host ("QR image    : {0}" -f $resolvedOutputPath)
Write-Host ("Payload txt : {0}" -f $resolvedPayloadPath)
Write-Host ""

$neededWidth = ($qr.Size + 4) * 2
$consoleWidth = 0
try { $consoleWidth = [Console]::WindowWidth } catch { $consoleWidth = 0 }
if ($consoleWidth -eq 0 -or $neededWidth -le $consoleWidth) {
    Show-QrConsole -Matrix $qr.Matrix -Invert:$Invert
} else {
    Write-Host ("Console is too narrow for terminal QR ({0} columns needed)." -f $neededWidth)
    Write-Host "Scan the generated BMP image instead."
}

if (-not $NoOpen) {
    try { Start-Process -FilePath $resolvedOutputPath | Out-Null } catch { }
}
