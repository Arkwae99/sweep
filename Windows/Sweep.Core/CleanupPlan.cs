namespace Sweep.Core;

public sealed record Candidate(string Path, long Length, DateTime ModifiedUtc, DateTime CreatedUtc, string Category = "");

public sealed class CleanupPlan
{
    internal const FileAttributes Excluded = FileAttributes.ReparsePoint | FileAttributes.Offline |
        FileAttributes.System | FileAttributes.Hidden;
    internal const FileAttributes ExcludedFile = Excluded | FileAttributes.Directory | FileAttributes.ReadOnly;

    private readonly Root[] roots;

    public CleanupPlan(string localAppData)
    {
        if (!Path.IsPathFullyQualified(localAppData))
            throw new ArgumentException("A full per-user data folder is required.", nameof(localAppData));

        string profileData = Path.TrimEndingDirectorySeparator(Path.GetFullPath(localAppData));
        string volume = Path.GetPathRoot(profileData)!;
        if (profileData == volume || (OperatingSystem.IsWindows() && new DriveInfo(volume).DriveType != DriveType.Fixed))
            throw new ArgumentException("A per-user folder on a fixed local drive is required.", nameof(localAppData));

        roots =
        [
            new(Path.Combine(profileData, "Temp"), "Temporary files", 7),
            new(Path.Combine(profileData, "npm-cache", "_logs"), "npm logs", 30),
            new(Path.Combine(profileData, "npm-cache", "_cacache", "content-v2"), "npm download cache", 30),
            new(Path.Combine(profileData, "NuGet", "v3-cache"), "NuGet HTTP cache", 30)
        ];
    }

    public IReadOnlyList<Candidate> Scan(DateTime now)
    {
        var candidates = new List<Candidate>();
        foreach (Root root in roots)
            ScanRoot(root, now, candidates);

        return candidates.OrderByDescending(file => file.Length)
            .ThenBy(file => file.Path, StringComparer.Ordinal).ToArray();
    }

    private static void ScanRoot(Root root, DateTime now, List<Candidate> candidates)
    {
        var options = new EnumerationOptions { AttributesToSkip = Excluded, IgnoreInaccessible = true };
        var pending = new Stack<string>();
        pending.Push(root.Path);
        while (pending.TryPop(out string? directory))
        {
            if (!IsSafeDirectory(directory, root.Path))
                continue;

            try
            {
                foreach (FileSystemInfo entry in new DirectoryInfo(directory).EnumerateFileSystemInfos("*", options))
                {
                    if (entry is DirectoryInfo)
                        pending.Push(entry.FullName);
                    else if (ReadCandidate((FileInfo)entry, root, now) is { } file)
                        candidates.Add(file);
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // An inaccessible directory or a changing temp folder can interrupt enumeration.
            }
        }
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
            if ((info.Attributes & ExcludedFile) != 0 || info.LastWriteTimeUtc > now.AddDays(-root.MinimumDays) || info.Length == 0)
                return null;

            return new Candidate(info.FullName, info.Length, info.LastWriteTimeUtc, info.CreationTimeUtc, root.Category);
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

    private sealed record Root(string Path, string Category, int MinimumDays);
}
