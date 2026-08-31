# Deep process characterization â€” PE/binary analysis, modules, parent chain, bounded memory strings.
# Read-only; no process mutation. Used when catalog/cache/metadata are insufficient.

$script:ForensicsLimits = @{
    MaxFileStringBytes = 262144
    MaxMemoryReadBytes = 262144
    MaxMemoryRegions = 12
    MaxModules = 24
    MaxParentDepth = 8
    MinStringLength = 8
    MaxStringsReturned = 40
}

function Get-ProcessForensicsConfig {
    param([string]$HubRoot)

    $path = Join-Path $HubRoot 'config\process-forensics.json'
    if (-not (Test-Path -LiteralPath $path)) { return $script:ForensicsLimits.Clone() }
    try {
        $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $merged = @{}
        foreach ($k in $script:ForensicsLimits.Keys) { $merged[$k] = $script:ForensicsLimits[$k] }
        foreach ($prop in $cfg.PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
        return $merged
    } catch {
        return $script:ForensicsLimits.Clone()
    }
}

function Initialize-ProcessMemoryReader {
if (-not ('HubProcessMemoryReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class HubProcessMemoryReader
{
    const int PROCESS_QUERY_INFORMATION = 0x0400;
    const int PROCESS_VM_READ = 0x0010;
    const uint MEM_COMMIT = 0x1000;
    const uint PAGE_NOACCESS = 0x01;
    const uint PAGE_GUARD = 0x100;

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_BASIC_INFORMATION
    {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public IntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int VirtualQueryEx(IntPtr hProcess, IntPtr lpAddress, out MEMORY_BASIC_INFORMATION lpBuffer, uint dwLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int dwSize, out int lpNumberOfBytesRead);

    public static List<string> ExtractAsciiStrings(byte[] data, int minLen)
    {
        var results = new List<string>();
        if (data == null || data.Length == 0) return results;
        var sb = new StringBuilder();
        for (int i = 0; i < data.Length; i++)
        {
            byte b = data[i];
            if (b >= 32 && b <= 126)
            {
                sb.Append((char)b);
            }
            else
            {
                if (sb.Length >= minLen) results.Add(sb.ToString());
                sb.Clear();
            }
        }
        if (sb.Length >= minLen) results.Add(sb.ToString());
        return results;
    }

    public static List<string> ReadProcessStrings(int pid, int maxBytes, int maxRegions, int minLen, int maxStrings)
    {
        var strings = new List<string>();
        IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
        if (h == IntPtr.Zero) return strings;
        try
        {
            int totalRead = 0;
            IntPtr addr = IntPtr.Zero;
            int regions = 0;
            while (regions < maxRegions && totalRead < maxBytes)
            {
                MEMORY_BASIC_INFORMATION mbi;
                int q = VirtualQueryEx(h, addr, out mbi, (uint)Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION)));
                if (q == 0) break;
                long regionSize = mbi.RegionSize.ToInt64();
                if (regionSize <= 0) break;
                bool readable = (mbi.State & MEM_COMMIT) != 0
                    && (mbi.Protect & PAGE_NOACCESS) == 0
                    && (mbi.Protect & PAGE_GUARD) == 0;
                if (readable)
                {
                    int chunk = (int)Math.Min(regionSize, Math.Min(65536, maxBytes - totalRead));
                    if (chunk > 0)
                    {
                        byte[] buf = new byte[chunk];
                        int read;
                        if (ReadProcessMemory(h, mbi.BaseAddress, buf, chunk, out read) && read > 0)
                        {
                            totalRead += read;
                            foreach (var s in ExtractAsciiStrings(buf, minLen))
                            {
                                if (strings.Count >= maxStrings) return strings;
                                if (!strings.Contains(s)) strings.Add(s);
                            }
                        }
                    }
                }
                long next = mbi.BaseAddress.ToInt64() + regionSize;
                if (next <= addr.ToInt64()) break;
                addr = new IntPtr(next);
                regions++;
            }
        }
        finally
        {
            CloseHandle(h);
        }
        return strings;
    }
}
'@ -ErrorAction Stop
    }
}

function Get-PeHeaderSummary {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            $mz = $br.ReadUInt16()
            if ($mz -ne 0x5A4D) { return $null }
            $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
            $peOffset = $br.ReadInt32()
            $fs.Seek($peOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $peSig = $br.ReadUInt32()
            if ($peSig -ne 0x00004550) { return $null }
            $machine = $br.ReadUInt16()
            $machineName = switch ($machine) {
                0x8664 { 'AMD64' }
                0x014c { 'I386' }
                0xAA64 { 'ARM64' }
                default { "0x{0:X4}" -f $machine }
            }
            $fs.Seek($peOffset + 24, [System.IO.SeekOrigin]::Begin) | Out-Null
            $magic = $br.ReadUInt16()
            $isPe32Plus = ($magic -eq 0x20B)
            if ($isPe32Plus) {
                $fs.Seek($peOffset + 24 + 112, [System.IO.SeekOrigin]::Begin) | Out-Null
            } else {
                $fs.Seek($peOffset + 24 + 96, [System.IO.SeekOrigin]::Begin) | Out-Null
            }
            $entryPoint = $br.ReadUInt32()
            $subsystemOffset = if ($isPe32Plus) { 44 } else { 28 }
            $fs.Seek($peOffset + 24 + $subsystemOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $subsystem = $br.ReadUInt16()
            $subsystemName = switch ($subsystem) {
                1 { 'Native' }
                2 { 'WindowsGUI' }
                3 { 'WindowsCUI' }
                default { "Subsys$subsystem" }
            }
            return [ordered]@{
                Machine = $machineName
                Subsystem = $subsystemName
                EntryPointRva = ('0x{0:X8}' -f $entryPoint)
                Is64Bit = $isPe32Plus
            }
        } finally {
            $fs.Close()
        }
    } catch {
        return $null
    }
}

function Get-BinaryStringsSample {
    param(
        [string]$Path,
        [int]$MaxBytes = 262144,
        [int]$MinLength = 8,
        [int]$MaxStrings = 40
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $len = [Math]::Min([int]$fs.Length, $MaxBytes)
            $buf = New-Object byte[] $len
            [void]$fs.Read($buf, 0, $len)
        } finally {
            $fs.Close()
        }
        $type = [HubProcessMemoryReader]
        $method = $type.GetMethod('ExtractAsciiStrings', [System.Reflection.BindingFlags]'Public,Static')
        $raw = $method.Invoke($null, @($buf, $MinLength))
        $filtered = [System.Collections.Generic.List[string]]::new()
        foreach ($s in @($raw)) {
            if ($s -match '(?i)(password|secret|token|apikey|http://|https://|\\\.exe|system32|program files)') {
                [void]$filtered.Add([string]$s)
            } elseif ($s.Length -ge 12) {
                [void]$filtered.Add([string]$s)
            }
            if ($filtered.Count -ge $MaxStrings) { break }
        }
        return @($filtered)
    } catch {
        return @()
    }
}

function Get-ProcessParentChain {
    param([int]$ProcessId, [int]$MaxDepth = 8)

    $chain = [System.Collections.Generic.List[object]]::new()
    $current = $ProcessId
    $depth = 0
    while ($current -gt 0 -and $depth -lt $MaxDepth) {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
        if (-not $wmi) { break }
        [void]$chain.Add([ordered]@{
            PID = [int]$wmi.ProcessId
            Name = [string]$wmi.Name
            CommandLine = if ($wmi.CommandLine) { [string]$wmi.CommandLine.Substring(0, [Math]::Min(240, $wmi.CommandLine.Length)) } else { '' }
            ParentPID = [int]$wmi.ParentProcessId
        })
        $current = [int]$wmi.ParentProcessId
        $depth++
    }
    return @($chain)
}

function Get-ProcessModulesSample {
    param([int]$ProcessId, [int]$MaxModules = 24)

    $mods = [System.Collections.Generic.List[string]]::new()
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        foreach ($m in $proc.Modules) {
            [void]$mods.Add([string]$m.FileName)
            if ($mods.Count -ge $MaxModules) { break }
        }
    } catch { }
    return @($mods)
}

function Get-ProcessForensicProfile {
    param(
        [int]$ProcessId = 0,
        [string]$ProcessName = '',
        [string]$ImagePath = '',
        [string]$CommandLine = '',
        [string]$HubRoot = '',
        [switch]$Deep,
        [switch]$IncludeMemory
    )

    $limits = if ($HubRoot) { Get-ProcessForensicsConfig -HubRoot $HubRoot } else { $script:ForensicsLimits }

    $path = [string]$ImagePath
    $cmd = [string]$CommandLine
    $pidVal = [int]$ProcessId
    $name = [string]$ProcessName

    if ($pidVal -gt 0) {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$pidVal" -ErrorAction SilentlyContinue
        if ($wmi) {
            if (-not $name) { $name = [string]$wmi.Name }
            if (-not $path) { $path = [string]$wmi.ExecutablePath }
            if (-not $cmd) { $cmd = [string]$wmi.CommandLine }
        }
        if (-not $path) {
            try {
                $p = Get-Process -Id $pidVal -ErrorAction Stop
                $path = [string]$p.Path
            } catch { }
        }
    }

    $sha256 = $null
    $sig = $null
    $pe = $null
    $fileStrings = @()
    if ($path -and (Test-Path -LiteralPath $path)) {
        try {
            $sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch { }
        try {
            $auth = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
            $sig = [ordered]@{
                Status = [string]$auth.Status
                Signer = if ($auth.SignerCertificate) { [string]$auth.SignerCertificate.Subject } else { '' }
            }
        } catch { }
        $pe = Get-PeHeaderSummary -Path $path
        if ($Deep) {
            $fileStrings = @(Get-BinaryStringsSample -Path $path `
                -MaxBytes ([int]$limits.MaxFileStringBytes) `
                -MinLength ([int]$limits.MinStringLength) `
                -MaxStrings ([int]$limits.MaxStringsReturned))
        }
    }

    $parentChain = @()
    $modules = @()
    $memoryStrings = @()
    $memoryAvailable = $false

    if ($pidVal -gt 0) {
        $parentChain = @(Get-ProcessParentChain -ProcessId $pidVal -MaxDepth ([int]$limits.MaxParentDepth))
        if ($Deep) {
            $modules = @(Get-ProcessModulesSample -ProcessId $pidVal -MaxModules ([int]$limits.MaxModules))
        }
        if (($Deep -or $IncludeMemory) -and -not $path) {
            $IncludeMemory = $true
        }
        if ($IncludeMemory -and $pidVal -gt 0) {
            try {
                Initialize-ProcessMemoryReader
                $type = [HubProcessMemoryReader]
                $method = $type.GetMethod('ReadProcessStrings', [System.Reflection.BindingFlags]'Public,Static')
                $rawMem = $method.Invoke($null, @(
                    $pidVal,
                    [int]$limits.MaxMemoryReadBytes,
                    [int]$limits.MaxMemoryRegions,
                    [int]$limits.MinStringLength,
                    [int]$limits.MaxStringsReturned
                ))
                $memoryStrings = @($rawMem)
                $memoryAvailable = (@($memoryStrings).Count -gt 0)
            } catch { }
        }
    }

    $confidenceBoost = 0.0
    $inferences = [System.Collections.Generic.List[string]]::new()
    if ($pe) {
        $confidenceBoost += 0.08
        [void]$inferences.Add(("PE {0}/{1} entry {2}" -f $pe.Machine, $pe.Subsystem, $pe.EntryPointRva))
    }
    if ($sig -and $sig.Status -eq 'Valid') {
        $confidenceBoost += 0.12
        [void]$inferences.Add("Authenticode valid: $($sig.Signer)")
    }
    if (@($parentChain).Count -gt 1) {
        $confidenceBoost += 0.05
        [void]$inferences.Add(("Parent chain depth {0}, root {1}" -f $parentChain.Count, $parentChain[-1].Name))
    }
    if (@($modules).Count -gt 0) {
        $confidenceBoost += 0.06
        [void]$inferences.Add(("Loaded modules sample: {0}" -f (@($modules | Select-Object -Last 3) -join '; ')))
    }
    if ($memoryAvailable) {
        $confidenceBoost += 0.04
        [void]$inferences.Add(("Memory strings sample: {0} hits" -f @($memoryStrings).Count))
    }
    if (@($fileStrings).Count -gt 0) {
        $confidenceBoost += 0.05
        [void]$inferences.Add(("Binary strings sample: {0} hits" -f @($fileStrings).Count))
    }

    return [ordered]@{
        SchemaVersion = 'ProcessForensicProfile.v1'
        ProcessName = ($name -replace '\.exe$','')
        PID = $pidVal
        ImagePath = $path
        CommandLine = if ($cmd) { $cmd.Substring(0, [Math]::Min(400, $cmd.Length)) } else { '' }
        Sha256 = $sha256
        Authenticode = $sig
        PeHeader = $pe
        ParentChain = $parentChain
        ModulesSample = $modules
        BinaryStringsSample = $fileStrings
        MemoryStringsSample = $memoryStrings
        MemoryReadAvailable = $memoryAvailable
        Inferences = @($inferences)
        ConfidenceBoost = [math]::Round([math]::Min(0.35, $confidenceBoost), 2)
        DeepScan = [bool]$Deep
    }
}

function Merge-ForensicsIntoHint {
    param(
        [hashtable]$Hint,
        $Forensics
    )

    if (-not $Forensics) { return $Hint }

    $Hint['Forensics'] = $Forensics
    $boost = [double]$Forensics.ConfidenceBoost
    if ($boost -gt 0) {
        $Hint['Confidence'] = [math]::Round([math]::Min(0.92, [double]$Hint['Confidence'] + $boost), 2)
    }

    if ([double]$Hint['Confidence'] -lt 0.75 -and @($Forensics.Inferences).Count -gt 0) {
        $extra = ($Forensics.Inferences -join ' | ')
        if (-not $Hint['BusinessHint']) {
            $Hint['BusinessHint'] = $extra
        } elseif ($Hint['BusinessHint'] -notmatch [regex]::Escape($extra.Substring(0, [Math]::Min(20, $extra.Length)))) {
            $Hint['BusinessHint'] = ($Hint['BusinessHint'] + ' | Forensics: ' + $extra)
        }
    }

    if ([string]$Hint['WhatItIs'] -match 'insufficient local facts' -and $Forensics.PeHeader) {
        $Hint['WhatItIs'] = ("Unclassified {0} binary ({1}/{2})" -f $Forensics.ProcessName, $Forensics.PeHeader.Machine, $Forensics.PeHeader.Subsystem)
    }
    if ($Forensics.CommandLine -and [string]$Hint['WhatItDoes'] -match 'operator review') {
        $Hint['WhatItDoes'] = ("Cmdline sample: {0}" -f $Forensics.CommandLine.Substring(0, [Math]::Min(180, $Forensics.CommandLine.Length)))
    }

    if ([double]$Hint['Confidence'] -ge 0.9) { $Hint['TrustLevel'] = 'T1_Delegated' }
    elseif ([double]$Hint['Confidence'] -ge 0.75) { $Hint['TrustLevel'] = 'T2_Review' }
    else { $Hint['TrustLevel'] = 'T3_Unknown' }

    return $Hint
}
