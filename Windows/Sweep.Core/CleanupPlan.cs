namespace Sweep.Core;

public sealed record Candidate(string Path, long Length, DateTime ModifiedUtc, DateTime CreatedUtc, string Category = "")
{
    internal WindowsFileIdentity? Identity { get; init; }
}

internal readonly record struct WindowsFileIdentity(uint Volume, ulong FileIndex, string ResolvedPath);

public sealed record CleanupLocation(string Category, string RelativePath, int MinimumDays);

public sealed record CleanupLocationResult(CleanupLocation Location, bool WasScanned);

public sealed record CleanupScan(IReadOnlyList<Candidate> Candidates, IReadOnlyList<CleanupLocationResult> Locations);

public sealed class CleanupPlan
{
    internal const FileAttributes Excluded = FileAttributes.ReparsePoint | FileAttributes.Offline |
        FileAttributes.System | FileAttributes.Hidden;
    internal const FileAttributes ExcludedFile = Excluded | FileAttributes.Directory | FileAttributes.ReadOnly;

    private readonly Root[] roots;

    public static IReadOnlyList<CleanupLocation> Locations { get; } = Array.AsReadOnly<CleanupLocation>(
    [
        new("Temporary files", "Temp", 7),
        new("npm logs", Path.Combine("npm-cache", "_logs"), 30),
        new("npm download cache", Path.Combine("npm-cache", "_cacache", "content-v2"), 30),
        new("NuGet HTTP cache", Path.Combine("NuGet", "v3-cache"), 30)
    ]);

    public CleanupPlan(string localAppData)
    {
        if (!Path.IsPathFullyQualified(localAppData))
            throw new ArgumentException("A full per-user data folder is required.", nameof(localAppData));

        string profileData = Path.TrimEndingDirectorySeparator(Path.GetFullPath(localAppData));
        string volume = Path.GetPathRoot(profileData)!;
        if (profileData == volume || (OperatingSystem.IsWindows() && new DriveInfo(volume).DriveType != DriveType.Fixed))
            throw new ArgumentException("A per-user folder on a fixed local drive is required.", nameof(localAppData));

        roots = Locations.Select(location => new Root(Path.Combine(profileData, location.RelativePath), location)).ToArray();
    }

    public IReadOnlyList<Candidate> Scan(DateTime now) => ScanWithLocations(now).Candidates;

    public CleanupScan ScanWithLocations(DateTime now, CancellationToken cancellationToken = default)
    {
        var candidates = new List<Candidate>();
        var locations = new List<CleanupLocationResult>(roots.Length);
        foreach (Root root in roots)
        {
            bool wasScanned = ScanRoot(root, now, candidates, cancellationToken);
            locations.Add(new CleanupLocationResult(root.Location, wasScanned));
        }

        cancellationToken.ThrowIfCancellationRequested();
        var ordered = candidates.OrderByDescending(file => file.Length)
            .ThenBy(file => file.Path, StringComparer.Ordinal).ToArray();
        cancellationToken.ThrowIfCancellationRequested();
        return new CleanupScan(ordered, locations.AsReadOnly());
    }

    private static bool ScanRoot(Root root, DateTime now, List<Candidate> candidates, CancellationToken cancellationToken)
    {
        var options = new EnumerationOptions { AttributesToSkip = Excluded, IgnoreInaccessible = false };
        var pending = new Stack<string>();
        bool wasScanned = false;
        pending.Push(root.Path);
        while (pending.TryPop(out string? directory))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsSafeDirectory(directory, root.Path))
                continue;

            try
            {
                foreach (FileSystemInfo entry in new DirectoryInfo(directory).EnumerateFileSystemInfos("*", options))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (entry is DirectoryInfo)
                        pending.Push(entry.FullName);
                    else if (ReadCandidate((FileInfo)entry, root, now) is { } file)
                    {
                        Candidate? reviewed = OperatingSystem.IsWindows() ? WindowsCleanup.Identify(file) : file;
                        if (reviewed is not null)
                            candidates.Add(reviewed);
                    }
                }
                if (directory == root.Path)
                    wasScanned = true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // An inaccessible directory or a changing temp folder can interrupt enumeration.
            }
        }
        return wasScanned;
    }

    public bool IsCurrent(Candidate candidate, DateTime now)
    {
        string path = candidate.Path;
        if (!Path.IsPathFullyQualified(path) || path != Path.GetFullPath(path))
            return false;

        Root? root = roots.FirstOrDefault(root => path.StartsWith(root.Path + Path.DirectorySeparatorChar, StringComparison.Ordinal));
        if (root is null || !IsSafeDirectory(Path.GetDirectoryName(path)!, root.Path))
            return false;

        Candidate? current = ReadCandidate(new FileInfo(path), root, now);
        return current is not null && Matches(candidate, current.Length, current.ModifiedUtc, current.CreatedUtc);
    }

    internal static bool Matches(Candidate candidate, long length, DateTime modifiedUtc, DateTime createdUtc) =>
        candidate.Length == length && candidate.ModifiedUtc == modifiedUtc && candidate.CreatedUtc == createdUtc;

    private static Candidate? ReadCandidate(FileInfo info, Root root, DateTime now)
    {
        try
        {
            if ((info.Attributes & ExcludedFile) != 0 || info.LastWriteTimeUtc > now.AddDays(-root.Location.MinimumDays) || info.Length == 0)
                return null;

            return new Candidate(info.FullName, info.Length, info.LastWriteTimeUtc, info.CreationTimeUtc, root.Location.Category);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static bool IsSafeDirectory(string path, string root)
    {
        // Start at the volume so a linked parent never leads us into an unrelated directory.
        var chain = new Stack<string>();
        for (string? directory = path; directory is not null; directory = Path.GetDirectoryName(directory))
            chain.Push(directory);

        // Windows' AppData ancestor is normally hidden.
        FileAttributes excluded = FileAttributes.ReparsePoint | FileAttributes.Offline;
        while (chain.TryPop(out string? directory))
        {
            if (directory == root)
                excluded = Excluded;

            try
            {
                FileAttributes attributes = File.GetAttributes(directory);
                if ((attributes & (FileAttributes.Directory | excluded)) != FileAttributes.Directory)
                    return false;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return false;
            }
        }

        return true;
    }

    private sealed record Root(string Path, CleanupLocation Location);
}
