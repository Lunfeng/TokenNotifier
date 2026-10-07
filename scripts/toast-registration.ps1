$script:TokenNotifierAppId = 'Lunfeng.TokenNotifier'

if (-not ('TokenNotifier.ShellIntegration' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TokenNotifier {
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey {
        public Guid FormatId;
        public uint PropertyId;

        public PropertyKey(Guid formatId, uint propertyId) {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    internal struct PropVariant {
        [FieldOffset(0)] public ushort VariantType;
        [FieldOffset(8)] public IntPtr PointerValue;

        public static PropVariant FromString(string value) {
            return new PropVariant {
                VariantType = (ushort)VarEnum.VT_LPWSTR,
                PointerValue = Marshal.StringToCoTaskMemUni(value)
            };
        }

        public string GetString() {
            return PointerValue == IntPtr.Zero ? null : Marshal.PtrToStringUni(PointerValue);
        }
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore {
        [PreserveSig] int GetCount(out uint propertyCount);
        [PreserveSig] int GetAt(uint propertyIndex, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    public static class ShellIntegration {
        private static readonly PropertyKey AppUserModelIdKey = new PropertyKey(
            new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SHGetPropertyStoreFromParsingName(
            string path,
            IntPtr bindingContext,
            uint flags,
            ref Guid interfaceId,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

        public static void SetCurrentProcessAppId(string appId) {
            Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(appId));
        }

        private static IPropertyStore OpenPropertyStore(string shortcutPath, uint flags) {
            Guid interfaceId = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
            IPropertyStore propertyStore;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(
                shortcutPath, IntPtr.Zero, flags, ref interfaceId, out propertyStore));
            return propertyStore;
        }

        public static void SetShortcutAppId(string shortcutPath, string appId) {
            IPropertyStore propertyStore = OpenPropertyStore(shortcutPath, 2);
            try {
                PropertyKey key = AppUserModelIdKey;
                PropVariant value = PropVariant.FromString(appId);
                try {
                    Marshal.ThrowExceptionForHR(propertyStore.SetValue(ref key, ref value));
                    Marshal.ThrowExceptionForHR(propertyStore.Commit());
                } finally {
                    PropVariantClear(ref value);
                }
            } finally {
                Marshal.FinalReleaseComObject(propertyStore);
            }
        }

        public static string GetShortcutAppId(string shortcutPath) {
            IPropertyStore propertyStore = OpenPropertyStore(shortcutPath, 0);
            try {
                PropertyKey key = AppUserModelIdKey;
                PropVariant value;
                Marshal.ThrowExceptionForHR(propertyStore.GetValue(ref key, out value));
                try {
                    return value.GetString();
                } finally {
                    PropVariantClear(ref value);
                }
            } finally {
                Marshal.FinalReleaseComObject(propertyStore);
            }
        }
    }
}
'@ -ErrorAction Stop
}

function Initialize-ToastRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$NotifierPath,
        [Parameter(Mandatory = $true)][string]$IconPath,
        [string]$StartMenuRoot = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        [switch]$SkipRegistry
    )

    $resolvedNotifier = (Resolve-Path -LiteralPath $NotifierPath).Path
    $resolvedIcon = (Resolve-Path -LiteralPath $IconPath).Path
    New-Item -ItemType Directory -Force -Path $StartMenuRoot | Out-Null
    $shortcutPath = Join-Path $StartMenuRoot 'TokenNotifier.lnk'
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "' + $resolvedNotifier + '"'
    $workingDirectory = Split-Path -Parent $resolvedNotifier
    $iconLocation = $resolvedIcon + ',0'
    $shell = New-Object -ComObject WScript.Shell
    try {
        $rewrite = -not (Test-Path -LiteralPath $shortcutPath)
        if (-not $rewrite) {
            $existing = $shell.CreateShortcut($shortcutPath)
            try {
                $existingAppId = [TokenNotifier.ShellIntegration]::GetShortcutAppId($shortcutPath)
                $rewrite = $existing.TargetPath -ne $powerShellPath -or
                    $existing.Arguments -ne $arguments -or
                    $existing.WorkingDirectory -ne $workingDirectory -or
                    $existing.IconLocation -ne $iconLocation -or
                    $existingAppId -ne $script:TokenNotifierAppId
            } finally {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($existing) | Out-Null
            }
        }
        if ($rewrite) {
            $shortcut = $shell.CreateShortcut($shortcutPath)
            try {
                $shortcut.TargetPath = $powerShellPath
                $shortcut.Arguments = $arguments
                $shortcut.WorkingDirectory = $workingDirectory
                $shortcut.IconLocation = $iconLocation
                $shortcut.Description = 'TokenNotifier Windows notifications'
                $shortcut.WindowStyle = 7
                $shortcut.Save()
            } finally {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
            }
            [TokenNotifier.ShellIntegration]::SetShortcutAppId($shortcutPath, $script:TokenNotifierAppId)
        }
    } finally {
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    }
    if (-not $SkipRegistry) {
        $registrationPath = 'HKCU:\Software\Classes\AppUserModelId\' + $script:TokenNotifierAppId
        New-Item -Path $registrationPath -Force | Out-Null
        New-ItemProperty -Path $registrationPath -Name DisplayName -Value 'TokenNotifier' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $registrationPath -Name IconUri -Value $resolvedIcon -PropertyType String -Force | Out-Null
    }
}

function Remove-ToastRegistration {
    param(
        [string]$StartMenuRoot = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        [switch]$SkipRegistry
    )

    Remove-Item -LiteralPath (Join-Path $StartMenuRoot 'TokenNotifier.lnk') -Force -ErrorAction SilentlyContinue
    if (-not $SkipRegistry) {
        $registrationPath = 'HKCU:\Software\Classes\AppUserModelId\' + $script:TokenNotifierAppId
        Remove-Item -LiteralPath $registrationPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
