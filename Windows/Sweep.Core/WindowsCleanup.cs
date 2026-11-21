using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Sweep.Core;

[SupportedOSPlatform("windows")]
public static class WindowsCleanup
{
    private const uint DeleteAccess = 0x00010000;
    private const uint ReadAttributes = 0x00000080;
    private const uint OpenExisting = 3;
    private const uint OpenReparsePoint = 0x00200000;
    private const int FileDispositionInfo = 4;
    private const string ExtendedPath = @"\\?\";

    public static void Delete(CleanupPlan plan, Candidate candidate, DateTime now)
    {
        if (!plan.IsCurrent(candidate, now))
            throw new IOException("The file changed since the scan or is no longer eligible.");

        string expected = ExtendedPath + candidate.Path;
        using SafeFileHandle handle = CreateFileW(expected, DeleteAccess | ReadAttributes,
            0, IntPtr.Zero, OpenExisting, OpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid || !GetFileInformationByHandle(handle, out var info))
            throw LastError();

        // Resolve the opened handle to catch redirected ancestors, then delete that same file handle.
        var resolved = new StringBuilder(expected.Length + 1);
        uint result = GetFinalPathNameByHandleW(handle, resolved, (uint)resolved.Capacity, 0);
        if (result == 0)
            throw LastError();

        if (result >= resolved.Capacity || !string.Equals(expected, resolved.ToString(), StringComparison.OrdinalIgnoreCase) ||
            (info.Attributes & CleanupPlan.ExcludedFile) != 0 || info.Links != 1 ||
            !CleanupPlan.Matches(candidate, Combine(info.SizeHigh, info.SizeLow),
                AsDate(info.LastWriteTime), AsDate(info.CreationTime)))
            throw new IOException("The opened file changed, was redirected, or is linked elsewhere.");

        if (!SetFileInformationByHandle(handle, FileDispositionInfo, 1, 1))
            throw LastError();
    }

    private static IOException LastError() => new(new Win32Exception(Marshal.GetLastPInvokeError()).Message);

    private static long Combine(uint high, uint low) => ((long)high << 32) | low;

    private static DateTime AsDate(System.Runtime.InteropServices.ComTypes.FILETIME time) =>
        DateTime.FromFileTimeUtc(Combine((uint)time.dwHighDateTime, (uint)time.dwLowDateTime));

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public FileAttributes Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint SizeHigh;
        public uint SizeLow;
        public uint Links;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint mode, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, [Out] StringBuilder path, uint length, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle file, int infoClass, in byte delete, uint size);
}
