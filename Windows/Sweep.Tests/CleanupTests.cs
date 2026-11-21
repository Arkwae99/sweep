using System.Diagnostics;
using System.Runtime.Versioning;
using Sweep.Core;
using Xunit;

namespace Sweep.Tests;

public sealed class CleanupTests : IDisposable
{
    private readonly string profile = Directory.CreateDirectory(
        Path.Combine(AppContext.BaseDirectory, $"sweep-test-{Guid.NewGuid():N}")).FullName;
    private static readonly DateTime Now = DateTime.UtcNow;

    private string AddFile(string relativePath, int daysOld, int bytes = 128)
    {
        string path = Path.GetFullPath(Path.Combine(profile, relativePath));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, new byte[bytes]);
        File.SetLastWriteTimeUtc(path, Now.AddDays(-daysOld));
        return path;
    }

    [Fact]
    public void ScanListsOnlyOldFilesInKnownLocationsAndLeavesThemInPlace()
    {
        string small = AddFile("Temp/nested/[old].tmp", 10);
        string large = AddFile("NuGet/v3-cache/package.dat", 31, 256);
        AddFile("Temp/fresh.tmp", 3);
        AddFile("NuGet/v3-cache/recent.dat", 15);
        string personal = AddFile("Downloads/report.docx", 90);
        AddFile("Temp backup/outside.tmp", 90);
        AddFile("pip/Cache/wheels/source.whl", 90);

        var results = new CleanupPlan(profile).Scan(Now);

        Assert.Equal(new[] { large, small }, results.Select(file => file.Path));
        Assert.Equal(384L, results.Sum(file => file.Length));
        Assert.All(results, file => Assert.True(File.Exists(file.Path)));
        Assert.True(File.Exists(personal));
    }

    [Fact]
    public void ScanReportsEmptyAndUnavailableLocationsAlongsideResults()
    {
        string eligible = AddFile("Temp/old.tmp", 8);
        AddFile("npm-cache/_logs/recent.log", 3);

        var report = new CleanupPlan(profile).ScanWithLocations(Now);

        Assert.Equal(eligible, Assert.Single(report.Candidates).Path);
        Assert.Collection(report.Locations,
            temp =>
            {
                Assert.Equal("Temporary files", temp.Location.Category);
                Assert.Equal(7, temp.Location.MinimumDays);
                Assert.True(temp.WasScanned);
            },
            logs =>
            {
                Assert.Equal(Path.Combine("npm-cache", "_logs"), logs.Location.RelativePath);
                Assert.Equal(30, logs.Location.MinimumDays);
                Assert.True(logs.WasScanned);
            },
            downloads => Assert.False(downloads.WasScanned),
            nuget => Assert.False(nuget.WasScanned));
    }

    [Fact]
    public void ScanCanBeCanceledWithoutReturningPartialResults()
    {
        AddFile("Temp/old.tmp", 8);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        Assert.Throws<OperationCanceledException>(() => new CleanupPlan(profile).ScanWithLocations(Now, cancellation.Token));
    }

    [Fact]
    public void ReviewRejectsFilesThatChangedAndPathsNextToAllowedRoots()
    {
        string eligible = AddFile("Temp/old.tmp", 10);
        string outside = AddFile("Temp backup/old.tmp", 10);
        var plan = new CleanupPlan(profile);
        var candidate = Assert.Single(plan.Scan(Now));

        Assert.True(plan.IsCurrent(candidate, Now));
        Assert.False(plan.IsCurrent(candidate with { Path = outside }, Now));
        File.AppendAllText(eligible, "changed");
        File.SetLastWriteTimeUtc(eligible, Now.AddDays(-10));
        Assert.False(plan.IsCurrent(candidate, Now));
        File.Delete(eligible);
        Assert.False(plan.IsCurrent(candidate, Now));
    }

    [Fact]
    public void ScanSkipsDirectoryLinksIncludingAnAllowlistedRoot()
    {
        string personal = AddFile("Documents/report.docx", 90);
        Directory.CreateDirectory(Path.Combine(profile, "Temp"));
        string parent = Path.Combine(profile, "NuGet");
        Directory.CreateDirectory(parent);
        string[] links = [Path.Combine(profile, "Temp", "linked"), Path.Combine(parent, "v3-cache")];
        foreach (string link in links)
            LinkDirectory(link, Path.GetDirectoryName(personal)!);

        try
        {
            var plan = new CleanupPlan(profile);
            Assert.Empty(plan.Scan(Now));
            foreach (string link in links)
            {
                var item = new Candidate(Path.Combine(link, "report.docx"), 128,
                    File.GetLastWriteTimeUtc(personal), File.GetCreationTimeUtc(personal));
                Assert.False(plan.IsCurrent(item, Now));
            }
            Assert.True(File.Exists(personal));
        }
        finally
        {
            foreach (string link in links)
                Directory.Delete(link);
        }
    }

    [Fact]
    public void MissingCacheDirectoriesAreFineAndDriveRootsAreRejected()
    {
        Assert.Empty(new CleanupPlan(profile).Scan(Now));
        Assert.Throws<ArgumentException>(() => new CleanupPlan(Path.GetPathRoot(profile)!));
        Assert.Throws<ArgumentException>(() => new CleanupPlan("relative"));
    }

    [WindowsFact]
    [SupportedOSPlatform("windows")]
    public void WindowsDeletesOnlyTheReviewedFileAndRefusesLockedFiles()
    {
        string purge = AddFile("Temp/purge.tmp", 10, 512);
        string locked = AddFile("Temp/locked.tmp", 10, 256);
        string keep = AddFile("Temp/keep.tmp", 10);
        var plan = new CleanupPlan(profile);
        var results = plan.Scan(Now);

        using (File.Open(locked, FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.ThrowsAny<IOException>(() => WindowsCleanup.Delete(plan, results[1], Now));

        WindowsCleanup.Delete(plan, results[0], Now);
        Assert.False(File.Exists(purge));
        Assert.True(File.Exists(locked));
        Assert.True(File.Exists(keep));
    }

    [WindowsFact]
    public void HiddenProfileParentDoesNotHideTempFilesButHiddenCacheEntriesAreSkipped()
    {
        string parent = Path.Combine(profile, "AppData");
        string local = Path.Combine(parent, "Local");
        string file = AddFile("AppData/Local/Temp/visible.tmp", 10);
        string hidden = AddFile("AppData/Local/Temp/hidden.tmp", 10);
        File.SetAttributes(parent, File.GetAttributes(parent) | FileAttributes.Hidden);
        File.SetAttributes(hidden, File.GetAttributes(hidden) | FileAttributes.Hidden);

        Assert.Equal(file, Assert.Single(new CleanupPlan(local).Scan(Now)).Path);
    }

    [WindowsFact]
    [SupportedOSPlatform("windows")]
    public void WindowsRefusesAReplacementEvenIfItsTimestampsAndSizeMatch()
    {
        string original = AddFile("Temp/old.tmp", 10);
        var plan = new CleanupPlan(profile);
        var reviewed = Assert.Single(plan.Scan(Now));
        string moved = Path.Combine(profile, "original.tmp");
        File.Move(original, moved);
        AddFile("Temp/old.tmp", 10);
        File.SetCreationTimeUtc(original, reviewed.CreatedUtc);
        File.SetLastWriteTimeUtc(original, reviewed.ModifiedUtc);

        Assert.ThrowsAny<IOException>(() => WindowsCleanup.Delete(plan, reviewed, Now));
        Assert.True(File.Exists(original));
        Assert.True(File.Exists(moved));
    }

    private static void LinkDirectory(string link, string target)
    {
        if (!OperatingSystem.IsWindows())
        {
            Directory.CreateSymbolicLink(link, target);
            return;
        }

        var start = new ProcessStartInfo("cmd.exe", $"/d /c mklink /J \"{link}\" \"{target}\"")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using var process = Process.Start(start)!;
        process.WaitForExit();
        Assert.True(process.ExitCode == 0, process.StandardError.ReadToEnd());
    }

    public void Dispose() => Directory.Delete(profile, recursive: true);

    private sealed class WindowsFactAttribute : FactAttribute
    {
        public WindowsFactAttribute()
        {
            if (!OperatingSystem.IsWindows())
                Skip = "Uses the Windows filesystem and native delete API.";
        }
    }
}
