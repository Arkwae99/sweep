namespace Sweep.Core;

public enum CleanupSort { File, Category, Size, Modified }

public sealed class CleanupReview
{
    private readonly HashSet<Candidate> selected = [];

    public IReadOnlyList<Candidate> Results { get; private set; } = [];
    public IReadOnlyList<Candidate> Visible { get; private set; } = [];
    public int SelectedCount => selected.Count;
    public long SelectedBytes { get; private set; }

    public void Load(IReadOnlyList<Candidate> candidates)
    {
        Results = Visible = candidates;
        ClearSelection();
    }

    public void Show(string? category, string query, CleanupSort sort, bool descending)
    {
        query = query.Trim();
        IEnumerable<Candidate> filtered = Results.Where(file =>
            (category is null || file.Category == category) && file.Path.Contains(query, StringComparison.OrdinalIgnoreCase));
        IOrderedEnumerable<Candidate> Order<TKey>(Func<Candidate, TKey> key, IComparer<TKey>? comparer = null) =>
            descending ? filtered.OrderByDescending(key, comparer) : filtered.OrderBy(key, comparer);

        var ordered = sort switch
        {
            CleanupSort.File => Order(file => Path.GetFileName(file.Path), StringComparer.OrdinalIgnoreCase),
            CleanupSort.Category => Order(file => file.Category, StringComparer.CurrentCultureIgnoreCase),
            CleanupSort.Size => Order(file => file.Length),
            CleanupSort.Modified => Order(file => file.ModifiedUtc),
            _ => throw new ArgumentOutOfRangeException(nameof(sort))
        };
        Visible = ordered.ThenBy(file => file.Path, StringComparer.Ordinal).ToArray();
        selected.IntersectWith(Visible);
        SelectedBytes = selected.Sum(file => file.Length);
    }

    public bool IsSelected(int index) => selected.Contains(Visible[index]);

    public void SetSelected(int index, bool value)
    {
        Candidate file = Visible[index];
        if (value && selected.Add(file))
            SelectedBytes += file.Length;
        else if (!value && selected.Remove(file))
            SelectedBytes -= file.Length;
    }

    public void SelectVisible()
    {
        selected.UnionWith(Visible);
        SelectedBytes = selected.Sum(file => file.Length);
    }

    public void ClearSelection()
    {
        selected.Clear();
        SelectedBytes = 0;
    }

    public Candidate[] GetSelected() => Visible.Where(selected.Contains).ToArray();
}
