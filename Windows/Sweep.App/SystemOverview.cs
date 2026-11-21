using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Sweep.App;

internal sealed record ProcessUsage(string Name, int Id, long WorkingSet);

internal sealed record SystemOverview(string Drive, long DiskTotal, long DiskFree,
    ulong MemoryTotal, ulong MemoryAvailable, IReadOnlyList<ProcessUsage> Processes)
{
    public static SystemOverview Read(string localData)
    {
        string volume = Path.GetPathRoot(localData) ?? throw new IOException("The profile drive is unavailable.");
        var disk = new DriveInfo(volume);
        var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        if (!GlobalMemoryStatusEx(ref memory))
            throw new Win32Exception(Marshal.GetLastPInvokeError());

        var processes = new List<ProcessUsage>();
        foreach (Process process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    processes.Add(new ProcessUsage(process.ProcessName, process.Id, process.WorkingSet64));
                }
                catch (Exception error) when (error is InvalidOperationException or Win32Exception)
                {
                    // A process may exit or become inaccessible while the snapshot is being taken.
                }
            }
        }

        return new SystemOverview(disk.Name.TrimEnd('\\'), disk.TotalSize, disk.AvailableFreeSpace,
            memory.TotalPhysical, memory.AvailablePhysical,
            processes.OrderByDescending(process => process.WorkingSet).Take(15).ToArray());
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length;
        public uint Load;
        public ulong TotalPhysical;
        public ulong AvailablePhysical;
        public ulong TotalPageFile;
        public ulong AvailablePageFile;
        public ulong TotalVirtual;
        public ulong AvailableVirtual;
        public ulong AvailableExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
}
