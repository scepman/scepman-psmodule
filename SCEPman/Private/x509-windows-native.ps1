$cSharpCodeToMergeCertificateAndPrivateKey = @'
using System;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Win32.SafeHandles;

internal sealed class SafeCertContextHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    [SecuritySafeCritical]
    private SafeCertContextHandle() : base(true)
    {
    }

    [SecuritySafeCritical]
    internal SafeCertContextHandle(IntPtr handle) : base(true)
    {
        base.SetHandle(handle);
    }

    internal static SafeCertContextHandle InvalidHandle
    {
        [SecuritySafeCritical]
        get
        {
            SafeCertContextHandle safeCertContextHandle = new SafeCertContextHandle(IntPtr.Zero);
            GC.SuppressFinalize(safeCertContextHandle);
            return safeCertContextHandle;
        }
    }

    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CertFreeCertificateContext(IntPtr pCertContext);

    [SecuritySafeCritical]
    protected override bool ReleaseHandle()
    {
        return SafeCertContextHandle.CertFreeCertificateContext(this.handle);
    }
}

internal static class X509Native
{
    internal struct CRYPT_KEY_PROV_INFO
    {
        [MarshalAs(UnmanagedType.LPWStr)]
        internal string pwszContainerName;

        [MarshalAs(UnmanagedType.LPWStr)]
        internal string pwszProvName;

        internal int dwProvType;
        internal int dwFlags;
        internal int cProvParam;
        internal IntPtr rgProvParam;
        internal int dwKeySpec;
    }

    [SecurityCritical]
    internal static bool SetCertificateKeyProvInfo(SafeCertContextHandle certificateContext, ref X509Native.CRYPT_KEY_PROV_INFO provInfo)
    {
        return X509Native.UnsafeNativeMethods.CertSetCertificateContextProperty(certificateContext, X509Native.CertificateProperty.KeyProviderInfo, X509Native.CertSetPropertyFlags.None, ref provInfo);
    }

    [SecuritySafeCritical]
    internal static SafeCertContextHandle DuplicateCertContext(IntPtr context)
    {
        return X509Native.UnsafeNativeMethods.CertDuplicateCertificateContext(context);
    }

    [SecuritySafeCritical]
    internal static SafeCertContextHandle GetCertificateContext(X509Certificate certificate)
    {
        SafeCertContextHandle result = X509Native.DuplicateCertContext(certificate.Handle);
        GC.KeepAlive(certificate);
        return result;
    }

    internal enum CertificateProperty
    {
        KeyProviderInfo = 2,
        KeyContext = 5,
        NCryptKeyHandle = 78
    }

    [Flags]
    internal enum CertSetPropertyFlags
    {
        CERT_SET_PROPERTY_INHIBIT_PERSIST_FLAG = 1073741824,
        None = 0
    }

    [SuppressUnmanagedCodeSecurity]
    public static class UnsafeNativeMethods
    {
        [DllImport("crypt32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CertSetCertificateContextProperty(SafeCertContextHandle pCertContext, X509Native.CertificateProperty dwPropId, X509Native.CertSetPropertyFlags dwFlags, [In] ref X509Native.CRYPT_KEY_PROV_INFO pvData);

        [DllImport("crypt32.dll")]
        internal static extern SafeCertContextHandle CertDuplicateCertificateContext(IntPtr certContext);
    }
}

public static class CertificateExtensionsCommon
{
    public static bool IsMachineKey(CngKey cngKey)
    {
        // the IsMachineKey property seem to be fixed on Win11
        if (Environment.OSVersion.Version.Build >= 22000)
            return cngKey.IsMachineKey;

        // the following logic don't work on Win11 where GetProperty("Key Type"..) returns [32, 0, 0, 0] for LocalMachine keys
        CngProperty propMT = cngKey.GetProperty("Key Type", CngPropertyOptions.None);
        byte[] baMT = propMT.GetValue();
        return (baMT[0] & 1) == 1; // according to https://docs.microsoft.com/en-us/windows/win32/seccng/key-storage-property-identifiers, which defines NCRYPT_MACHINE_KEY_FLAG differently than ncrypt.h
    }

    [SecurityCritical]
    public static void AddCngKey(X509Certificate2 x509Certificate, CngKey cngKey)
    {
        if (string.IsNullOrEmpty(cngKey.KeyName))
            return;

        CngKeyOpenOptions keyOptions = IsMachineKey(cngKey) ? CngKeyOpenOptions.MachineKey : CngKeyOpenOptions.None;
        X509Native.CRYPT_KEY_PROV_INFO crypt_KEY_PROV_INFO = default;
        crypt_KEY_PROV_INFO.pwszContainerName = cngKey.KeyName;
        crypt_KEY_PROV_INFO.pwszProvName = cngKey.Provider.Provider;
        crypt_KEY_PROV_INFO.dwProvType = 0;
        crypt_KEY_PROV_INFO.dwFlags = (int)keyOptions;
        crypt_KEY_PROV_INFO.cProvParam = 0;
        crypt_KEY_PROV_INFO.rgProvParam = System.IntPtr.Zero;
        crypt_KEY_PROV_INFO.dwKeySpec = 0;
        using SafeCertContextHandle certificateContext = X509Native.GetCertificateContext(x509Certificate);
        if (!X509Native.SetCertificateKeyProvInfo(certificateContext, ref crypt_KEY_PROV_INFO))
        {
            int lastWin32Error = Marshal.GetLastWin32Error();
            throw new CryptographicException(lastWin32Error);
        }
    }
}
'@

function AddCngKey([System.Security.Cryptography.X509Certificates.X509Certificate2]$x509Certificate, [System.Security.Cryptography.CngKey]$cngKey) {
    if ($IsWindows) {
        Add-Type -TypeDefinition $cSharpCodeToMergeCertificateAndPrivateKey -Language CSharp
        [CertificateExtensionsCommon]::AddCngKey($x509Certificate, $cngKey)
    } else {
        throw "This function is only supported on Windows"
    }
}