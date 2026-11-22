# ============================================================
# FIVE BLUETOOTH CONTROLLER PAIRING UTILITY
# Windows PowerShell 5.1
# ============================================================

$ErrorActionPreference = "Stop"

$MacAddresses = @(
    "98:B6:E9:02:C3:46",
    "98:B6:E9:C2:00:13",
    "98:B6:E9:E3:C0:18",
    "98:B6:E9:04:5D:54",
    "98:B6:E9:BB:B4:88"
)

# SETTINGS
$RemoveExistingPairings = $true
$TimeoutMinutes = 10
$ScanIntervalSeconds = 5
$RetryIntervalSeconds = 20
$InquiryMultiplier = 8        # inquiry length in units of 1.28 s (8 = about 10 s, max 48)
$AuthRequirement = 2         # 2 = MITMProtectionNotRequiredBonding (Just Works), used by the Win32 fallback
$PairInParallel = $true      # start all pairings at once (set $false to pair one at a time)
$UseWin32Fallback = $true    # if automatic WinRT pairing fails, try the Win32 method (may show a Windows prompt)

$LogPath = Join-Path $PSScriptRoot "Pairing-Log.txt"
$AddressProperty = "System.Devices.Aep.DeviceAddress"

function Write-Log {
    param([string]$Message)
    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Write-Host $Line
    Add-Content -LiteralPath $LogPath -Value $Line
}

function Normalize-MAC {
    param([string]$Address)
    return ($Address -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}

# Convert a WinRT IAsyncOperation<T> into a normal .NET Task and wait for it.
function Wait-WinRT {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][type]$ResultType
    )

    if ($null -eq $Operation) {
        throw "A null Windows Runtime async operation was supplied."
    }
    if ($Operation -is [System.Management.Automation.PSObject]) { $Operation = $Operation.BaseObject }

    # WinRT operations are exposed by PowerShell as System.__ComObject.
    # Their generic interfaces are not reliably visible through GetInterfaces(),
    # so use the known result type for each API call instead.
    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq "AsTask" -and
            $_.IsGenericMethodDefinition -and
            $_.GetGenericArguments().Length -eq 1 -and
            $_.GetParameters().Length -eq 1 -and
            $_.GetParameters()[0].ParameterType.IsGenericType -and
            $_.GetParameters()[0].ParameterType.GetGenericTypeDefinition().FullName -eq 'Windows.Foundation.IAsyncOperation`1'
        } |
        Select-Object -First 1

    if ($null -eq $asTaskMethod) {
        throw "Could not locate the WinRT AsTask<T>(IAsyncOperation<T>) method."
    }

    $closedMethod = $asTaskMethod.MakeGenericMethod([type[]]@($ResultType))
    try {
        $task = $closedMethod.Invoke($null, [object[]]@($Operation))
        return $task.GetAwaiter().GetResult()
    }
    catch {
        $detail = $_.Exception
        if ($detail.InnerException) { $detail = $detail.InnerException }
        throw "Windows Runtime operation failed: $($detail.Message)"
    }
}

function Get-DeviceAddress {
    param([Parameter(Mandatory = $true)][object]$Device)

    try {
        $value = $Device.Properties[$AddressProperty]
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }
    catch { }

    # Fallback: Bluetooth device IDs end with the device address.
    if ($Device.Id -match '([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5})$') {
        return $Matches[1]
    }
    return $null
}

function Find-BluetoothDevices {
    param([Parameter(Mandatory = $true)][string]$Selector)

    # Explicitly request the Bluetooth address property. Without this,
    # DeviceInformation.Properties may not contain the address.
    $properties = [System.Collections.Generic.List[string]]::new()
    $properties.Add($AddressProperty)
    return Wait-WinRT -Operation ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($Selector, $properties)) -ResultType ([Windows.Devices.Enumeration.DeviceInformationCollection])
}

# Validate target addresses.
$Targets = @{}
foreach ($Address in $MacAddresses) {
    $mac = Normalize-MAC $Address
    if ($mac.Length -ne 12) { throw "Invalid MAC address: $Address" }
    if ($Targets.ContainsKey($mac)) { throw "Duplicate MAC address: $Address" }
    $Targets[$mac] = $false
}
if ($Targets.Count -ne 5) { throw "Exactly five MAC addresses are required." }

# Load Windows Runtime Bluetooth APIs.
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationCollection, Windows, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DevicePairingResult, Windows, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceUnpairingResult, Windows, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationKind, Windows, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DevicePairingKinds, Windows, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceWatcher, Windows, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationUpdate, Windows, ContentType=WindowsRuntime]
}
catch {
    Write-Host "Bluetooth API loading failed: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Log "=========================================="
Write-Log "FIVE CONTROLLER PAIRING UTILITY STARTED"
Write-Log "=========================================="
Write-Log "PowerShell: $($PSVersionTable.PSVersion)"
Write-Log "Run elevated only if Windows specifically requires it; normal user mode is preferred."

# Stage 1: remove existing pairings for the five target MAC addresses.
if ($RemoveExistingPairings) {
    Write-Log "Starting existing pairing cleanup."
    try {
        $pairedSelector = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromPairingState($true)
        $pairedDevices = @(Find-BluetoothDevices -Selector $pairedSelector)
        Write-Log "Paired device records found: $($pairedDevices.Count)"

        # Start every removal first, then wait for them, so they run at the same time.
        $pending = New-Object System.Collections.ArrayList
        foreach ($device in $pairedDevices) {
            $address = Get-DeviceAddress -Device $device
            if (-not $address) { continue }

            $mac = Normalize-MAC $address
            if (-not $Targets.ContainsKey($mac)) { continue }

            Write-Log "Removing existing pairing: $mac ($($device.Name))"
            try {
                $null = $pending.Add(@{ Mac = $mac; Op = $device.Pairing.UnpairAsync() })
            }
            catch {
                Write-Log "REMOVAL ERROR for ${mac}: $($_.Exception.Message)"
            }
        }
        foreach ($item in $pending) {
            try {
                $result = Wait-WinRT -Operation $item.Op -ResultType ([Windows.Devices.Enumeration.DeviceUnpairingResult])
                Write-Log "Removal result for $($item.Mac): $($result.Status)"
            }
            catch {
                Write-Log "REMOVAL ERROR for $($item.Mac): $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Log "CLEANUP ERROR: $($_.Exception.Message)"
    }
    Write-Log "Cleanup stage finished."
}

# Stage 2: discover with a real inquiry scan and pair using the Win32
# Bluetooth API (bthprops.cpl). No WinRT events are needed.
Write-Log "Starting Bluetooth discovery (Win32 inquiry)."
Write-Log "Put the controllers into pairing mode. Keep them close to the PC."

$csharp = @'
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;

public class BtDev {
    public ulong Address;
    public string Mac;
    public string Name;
    public bool Authenticated;
    public bool Remembered;
}

public static class BtNative {
    [StructLayout(LayoutKind.Sequential)]
    struct SYSTEMTIME { public ushort wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct BLUETOOTH_DEVICE_INFO {
        public int dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        public int fConnected;
        public int fRemembered;
        public int fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
        public string szName;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SEARCH_PARAMS {
        public int dwSize;
        public int fReturnAuthenticated;
        public int fReturnRemembered;
        public int fReturnUnknown;
        public int fReturnConnected;
        public int fIssueInquiry;
        public byte cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FIND_RADIO { public int dwSize; }

    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern IntPtr BluetoothFindFirstRadio(ref FIND_RADIO p, out IntPtr hRadio);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern bool BluetoothFindRadioClose(IntPtr h);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern IntPtr BluetoothFindFirstDevice(ref SEARCH_PARAMS p, ref BLUETOOTH_DEVICE_INFO info);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern bool BluetoothFindNextDevice(IntPtr h, ref BLUETOOTH_DEVICE_INFO info);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern bool BluetoothFindDeviceClose(IntPtr h);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern uint BluetoothAuthenticateDeviceEx(IntPtr hwnd, IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO info, IntPtr oob, int req);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern uint BluetoothSetServiceState(IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO info, ref Guid svc, uint flags);

    delegate bool AuthCallback(IntPtr pvParam, IntPtr pParams);

    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern uint BluetoothRegisterForAuthenticationEx(IntPtr pbtdi, out IntPtr hReg, AuthCallback cb, IntPtr pvParam);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern uint BluetoothSendAuthenticationResponseEx(IntPtr hRadio, IntPtr pResp);

    static AuthCallback authDelegate = OnAuth;   // static so it is never garbage collected
    static IntPtr authReg = IntPtr.Zero;
    static List<string> logLines = new List<string>();

    internal static void Log(string s) { lock (logLines) { logLines.Add(s); } }

    public static string[] DrainLog() {
        lock (logLines) { string[] a = logLines.ToArray(); logLines.Clear(); return a; }
    }

    // Answers Windows' pairing prompts automatically (Just Works / numeric comparison / legacy PIN 0000).
    // Offsets below are for 64-bit Windows PowerShell.
    static bool OnAuth(IntPtr pv, IntPtr p) {
        try {
            long addr = Marshal.ReadInt64(p, 8);
            int method = Marshal.ReadInt32(p, 560);
            int numeric = Marshal.ReadInt32(p, 572);
            Log("Auth prompt from " + addr.ToString("X12") + " method=" + method + " numeric=" + numeric);
            // Reply from another thread: replying inside the callback returned ERROR_NOT_READY (21).
            System.Threading.ThreadPool.QueueUserWorkItem(delegate(object o) { Respond(addr, method, numeric); });
        }
        catch (Exception e) { Log("Auth callback error: " + e.Message); }
        return true;
    }

    static void Respond(long addr, int method, int numeric) {
        for (int attempt = 0; attempt < 4; attempt++) {
            try {
                // Numeric comparison: try "1" (accept) first, then the number Windows supplied.
                int value = (attempt % 2 == 0) ? 1 : numeric;
                IntPtr resp = Marshal.AllocHGlobal(64);
                for (int i = 0; i < 64; i += 8) Marshal.WriteInt64(resp, i, 0);
                Marshal.WriteInt64(resp, 0, addr);
                Marshal.WriteInt32(resp, 8, method);
                if (method == 1) {
                    for (int i = 0; i < 4; i++) Marshal.WriteByte(resp, 12 + i, (byte)'0');
                    Marshal.WriteByte(resp, 28, 4);
                } else {
                    Marshal.WriteInt32(resp, 12, value);
                }
                uint r = BluetoothSendAuthenticationResponseEx(radio, resp);
                Marshal.FreeHGlobal(resp);
                Log("  reply attempt " + (attempt + 1) + " (value " + value + ") for " + addr.ToString("X12") + " -> result " + r);
                if (r == 0) return;
            }
            catch (Exception e) { Log("  reply error: " + e.Message); }
            System.Threading.Thread.Sleep(250);
        }
    }

    public static uint RegisterAuto() {
        if (authReg != IntPtr.Zero) return 0;
        return BluetoothRegisterForAuthenticationEx(IntPtr.Zero, out authReg, authDelegate, IntPtr.Zero);
    }

    static IntPtr radio = IntPtr.Zero;
    static Dictionary<ulong, BLUETOOTH_DEVICE_INFO> cache = new Dictionary<ulong, BLUETOOTH_DEVICE_INFO>();

    public static int LastError = 0;
    public static uint LastServiceResult = 0;

    public static bool OpenRadio() {
        FIND_RADIO p = new FIND_RADIO();
        p.dwSize = Marshal.SizeOf(typeof(FIND_RADIO));
        IntPtr h = BluetoothFindFirstRadio(ref p, out radio);
        if (h == IntPtr.Zero) { LastError = Marshal.GetLastWin32Error(); return false; }
        BluetoothFindRadioClose(h);
        return true;
    }

    public static List<BtDev> Scan(byte multiplier) {
        List<BtDev> list = new List<BtDev>();
        SEARCH_PARAMS sp = new SEARCH_PARAMS();
        sp.dwSize = Marshal.SizeOf(typeof(SEARCH_PARAMS));
        sp.fReturnAuthenticated = 0;
        sp.fReturnRemembered = 1;
        sp.fReturnUnknown = 1;
        sp.fReturnConnected = 0;
        sp.fIssueInquiry = 1;
        sp.cTimeoutMultiplier = multiplier;
        sp.hRadio = radio;

        BLUETOOTH_DEVICE_INFO info = new BLUETOOTH_DEVICE_INFO();
        info.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));

        IntPtr h = BluetoothFindFirstDevice(ref sp, ref info);
        if (h == IntPtr.Zero) { LastError = Marshal.GetLastWin32Error(); return list; }
        LastError = 0;
        do {
            BtDev d = new BtDev();
            d.Address = info.Address;
            d.Mac = info.Address.ToString("X12");
            d.Name = info.szName;
            d.Authenticated = info.fAuthenticated != 0;
            d.Remembered = info.fRemembered != 0;
            list.Add(d);
            cache[info.Address] = info;
        } while (BluetoothFindNextDevice(h, ref info));
        BluetoothFindDeviceClose(h);
        return list;
    }

    // Enables the HID (input) service for a device seen in the last scan. Returns a Win32 result code.
    public static uint EnableHid(ulong address) {
        BLUETOOTH_DEVICE_INFO info;
        if (!cache.TryGetValue(address, out info)) return 0xFFFFFFFE;
        Guid hid = new Guid("00001124-0000-1000-8000-00805f9b34fb");
        return BluetoothSetServiceState(radio, ref info, ref hid, 1);
    }

    // Pairs several devices at the same time (one thread each). Returns one Win32 code per address.
    public static uint[] PairMany(ulong[] addrs, int requirement) {
        uint[] res = new uint[addrs.Length];
        System.Threading.Thread[] ts = new System.Threading.Thread[addrs.Length];
        for (int i = 0; i < addrs.Length; i++) {
            int idx = i;
            ts[i] = new System.Threading.Thread(delegate() { res[idx] = Pair(addrs[idx], requirement); });
            ts[i].Start();
        }
        for (int i = 0; i < ts.Length; i++) ts[i].Join();
        return res;
    }

    // Returns 0 on success, otherwise a Win32 error code.
    public static uint Pair(ulong address, int requirement) {
        BLUETOOTH_DEVICE_INFO info;
        if (!cache.TryGetValue(address, out info)) return 0xFFFFFFFE;
        uint r = BluetoothAuthenticateDeviceEx(IntPtr.Zero, radio, ref info, IntPtr.Zero, requirement);
        if (r == 0) {
            Guid hid = new Guid("00001124-0000-1000-8000-00805f9b34fb");
            LastServiceResult = BluetoothSetServiceState(radio, ref info, ref hid, 1);
        }
        return r;
    }
}
public static class BtPairHandler {
    // Attaches an automatic-accept PairingRequested handler to a DeviceInformationCustomPairing.
    // Reflection on the event itself is blocked for WinRT events, so this calls
    // WindowsRuntimeMarshal.AddEventHandler with the raw add_/remove_ methods (what the C# compiler emits).
    public static void Attach(object custom) {
        BindingFlags f = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
        Type t = custom.GetType();
        MethodInfo add = t.GetMethod("add_PairingRequested", f);
        MethodInfo remove = t.GetMethod("remove_PairingRequested", f);
        if (add == null || remove == null) {
            string names = "";
            foreach (MethodInfo mi in t.GetMethods(f)) {
                if (mi.Name.IndexOf("Pairing", StringComparison.OrdinalIgnoreCase) >= 0) names += mi.Name + "; ";
            }
            throw new Exception("add_/remove_PairingRequested not found on " + t.FullName + ". Methods: " + names);
        }
        Type handlerType = add.GetParameters()[0].ParameterType;
        Type tokenType = add.ReturnType;
        Type funcType = typeof(Func<,>).MakeGenericType(handlerType, tokenType);
        Type actionType = typeof(Action<>).MakeGenericType(tokenType);
        Delegate addDel = Delegate.CreateDelegate(funcType, custom, add);
        Delegate removeDel = Delegate.CreateDelegate(actionType, custom, remove);
        MethodInfo onReq = typeof(BtPairHandler).GetMethod("OnRequested", BindingFlags.Static | BindingFlags.Public);
        Delegate handler = Delegate.CreateDelegate(handlerType, onReq);
        MethodInfo adder = typeof(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeMarshal).GetMethod("AddEventHandler");
        adder.MakeGenericMethod(handlerType).Invoke(null, new object[] { addDel, removeDel, handler });
    }

    public static void OnRequested(object sender, object args) {
        try {
            Type t = args.GetType();
            string kind = t.GetProperty("PairingKind").GetValue(args, null).ToString();
            if (kind.Contains("ProvidePin")) {
                t.GetMethod("Accept", new Type[] { typeof(string) }).Invoke(args, new object[] { "0000" });
            } else {
                t.GetMethod("Accept", Type.EmptyTypes).Invoke(args, null);
            }
            BtNative.Log("Pairing request accepted automatically (kind: " + kind + ")");
        }
        catch (Exception e) { BtNative.Log("Pairing request handler error: " + e.Message); }
    }
}
'@

try {
    if (-not ('BtNative' -as [type])) {
        Add-Type -TypeDefinition $csharp -Language CSharp
    }
    if (-not [BtNative]::OpenRadio()) {
        throw "No Bluetooth radio found (Win32 error $([BtNative]::LastError)). Is Bluetooth turned on?"
    }
    if ([IntPtr]::Size -ne 8) { Write-Log "WARNING: 32-bit PowerShell detected; automatic prompt handling needs 64-bit." }
}
catch {
    Write-Log "BLUETOOTH API SETUP ERROR: $($_.Exception.Message)"
    Read-Host "Press Enter to exit"
    exit 1
}

$startTime = Get-Date
$attempted = @{}
$kinds = [Windows.Devices.Enumeration.DevicePairingKinds]"ConfirmOnly,DisplayPin,ProvidePin,ConfirmPinMatch"

function Complete-WinRtPair {
    param([hashtable]$Entry)
    $mac = $Entry.Dev.Mac
    if ($null -eq $Entry.Op) { return $false }
    try {
        $result = Wait-WinRT -Operation $Entry.Op -ResultType ([Windows.Devices.Enumeration.DevicePairingResult])
        $status = $result.Status.ToString()
        Write-Log "Pairing status for ${mac}: $status"
        return ($status -in @("Paired", "AlreadyPaired"))
    }
    catch {
        Write-Log "WINRT PAIRING ERROR for ${mac}: $($_.Exception.Message)"
        return $false
    }
}

while (((Get-Date) - $startTime).TotalMinutes -lt $TimeoutMinutes) {
    $remaining = @($Targets.Keys | Where-Object { -not $Targets[$_] })
    if ($remaining.Count -eq 0) {
        Write-Log "ALL FIVE CONTROLLERS PAIRED."
        break
    }

    try {
        $found = @([BtNative]::Scan([byte]$InquiryMultiplier))
        Write-Log "Inquiry finished: $($found.Count) device(s) found."
    }
    catch {
        Write-Log "DISCOVERY ERROR: $($_.Exception.Message)"
        Start-Sleep -Seconds $ScanIntervalSeconds
        continue
    }

    # Decide which target controllers to pair this round.
    $batch = @()
    foreach ($dev in $found) {
        $mac = $dev.Mac
        if (-not $Targets.ContainsKey($mac) -or $Targets[$mac]) { continue }

        if ($attempted.ContainsKey($mac) -and
            ((Get-Date) - $attempted[$mac]).TotalSeconds -lt $RetryIntervalSeconds) {
            continue
        }

        Write-Log "CONTROLLER DETECTED: $mac ($($dev.Name))"
        $attempted[$mac] = Get-Date
        $batch += $dev
    }

    # Start pairing (all at once if $PairInParallel) with an automatic-accept handler.
    $entries = @()
    foreach ($dev in $batch) {
        $mac = $dev.Mac
        $entry = @{ Dev = $dev; Op = $null; Ok = $false; Done = $false }
        try {
            $bd = Wait-WinRT -Operation ([Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync([uint64]$dev.Address)) -ResultType ([Windows.Devices.Bluetooth.BluetoothDevice])
            if ($null -eq $bd) { throw "Windows returned no device object for this address." }
            $custom = $bd.DeviceInformation.Pairing.Custom
            [BtPairHandler]::Attach($custom)
            $entry.Op = $custom.PairAsync($kinds)
            Write-Log "Pairing started (automatic confirm): $mac"
        }
        catch {
            Write-Log "WINRT PAIRING SETUP ERROR for ${mac}: $($_.Exception.Message)"
        }

        if (-not $PairInParallel) {
            $entry.Ok = Complete-WinRtPair -Entry $entry
            $entry.Done = $true
        }
        $entries += $entry
    }

    $needFallback = @()
    foreach ($entry in $entries) {
        $mac = $entry.Dev.Mac
        if (-not $entry.Done) { $entry.Ok = Complete-WinRtPair -Entry $entry }

        if ($entry.Ok) {
            $Targets[$mac] = $true
            $hid = [BtNative]::EnableHid($entry.Dev.Address)
            Write-Log "SUCCESS: $mac (HID service enable result: $hid)"
            continue
        }

        Write-Log "PAIRING UNSUCCESSFUL (WinRT): $mac"
        $needFallback += $entry
    }

    if ($UseWin32Fallback -and $needFallback.Count -gt 0) {
        $addrs = [uint64[]]@($needFallback | ForEach-Object { [uint64]$_.Dev.Address })
        Write-Log "Win32 fallback for $($needFallback.Count) controller(s), all at once. Confirm each Windows pairing notification promptly."
        try {
            $codes = [BtNative]::PairMany($addrs, $AuthRequirement)
            for ($i = 0; $i -lt $needFallback.Count; $i++) {
                $m = $needFallback[$i].Dev.Mac
                if ($codes[$i] -eq 0) {
                    $Targets[$m] = $true
                    Write-Log "SUCCESS (Win32): $m"
                }
                else {
                    Write-Log "PAIRING UNSUCCESSFUL (Win32): $m (error $($codes[$i]))"
                }
            }
        }
        catch {
            Write-Log "WIN32 PAIRING ERROR: $($_.Exception.Message)"
        }
    }

    foreach ($line in [BtNative]::DrainLog()) { Write-Log $line }
    $remaining = @($Targets.Keys | Where-Object { -not $Targets[$_] })
    Write-Log "Controllers remaining: $($remaining.Count)"
    if ($remaining.Count -gt 0) {
        Start-Sleep -Seconds $ScanIntervalSeconds
    }
}

# Stage 3: final report.
Write-Log "=========================================="
Write-Log "FINAL PAIRING REPORT"
Write-Log "=========================================="

$successCount = 0
foreach ($mac in ($Targets.Keys | Sort-Object)) {
    if ($Targets[$mac]) {
        Write-Log "PAIRED: $mac"
        $successCount++
    }
    else {
        Write-Log "NOT PAIRED: $mac"
    }
}

Write-Log "SUCCESSFUL PAIRINGS: $successCount / 5"
Write-Log "PAIRING SESSION FINISHED."
Write-Host ""
Write-Host "Finished. See Pairing-Log.txt for details."
Read-Host "Press Enter to close"
