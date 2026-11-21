using Sweep.Core;
using Xunit;

namespace Sweep.Tests;

public sealed class CleanupReviewTests
{
    private static readonly DateTime Older = new(2026, 10, 1, 0, 0, 0, DateTimeKind.Utc);
    private static readonly Candidate Small = new("Temp/small.log", 9, Older, Older, "Temporary files");
    private static readonly Candidate Large = new("Temp/nested/large.LOG", 120, Older.AddDays(3), Older, "Temporary files");
    private static readonly Candidate Cached = new("npm-cache/_logs/large.log", 40, Older.AddDays(1), Older, "npm logs");

    [Fact]
    public void CategoryAndPathSearchTogetherMatchOnlyVisibleFiles()
    {
        var review = new CleanupReview();
        review.Load([Small, Large, Cached]);
        review.Show("Temporary files", " LARGE.log ", CleanupSort.Size, descending: true);

        Assert.Same(Large, Assert.Single(review.Visible));
    }

    [Fact]
    public void SortingUsesNumericSizeAndPreservesTheReviewedFile()
    {
        var review = new CleanupReview();
        review.Load([Large, Small, Cached]);
        review.SetSelected(0, true);
        review.Show(null, "", CleanupSort.Size, descending: false);

        Assert.Equal(new[] { Small, Cached, Large }, review.Visible);
        Assert.Same(Large, Assert.Single(review.GetSelected()));
        Assert.Equal(120, review.SelectedBytes);
        Assert.True(review.IsSelected(2));
        Assert.False(review.IsSelected(0));
    }

    [Fact]
    public void SortingByFileUsesTheDisplayedNameBeforeTheFolder()
    {
        var review = new CleanupReview();
        review.Load([Small, Cached, Large]);
        review.Show(null, "", CleanupSort.File, descending: false);

        Assert.Equal(new[] { Large, Cached, Small }, review.Visible);
    }

    [Fact]
    public void FilteringDropsHiddenSelectionsAndBulkSelectionUsesVisibleFiles()
    {
        var review = new CleanupReview();
        review.Load([Small, Large, Cached]);
        review.SelectVisible();
        review.Show("npm logs", "", CleanupSort.Modified, descending: true);

        Assert.Same(Cached, Assert.Single(review.GetSelected()));
        Assert.Equal(40, review.SelectedBytes);
        review.ClearSelection();
        review.SelectVisible();
        review.Show(null, "", CleanupSort.Modified, descending: true);

        Assert.Equal(new[] { Large, Cached, Small }, review.Visible);
        Assert.Same(Cached, Assert.Single(review.GetSelected()));
    }

    [Fact]
    public void LoadingAReplacementScanClearsTheSelection()
    {
        var review = new CleanupReview();
        review.Load([Small]);
        review.SelectVisible();
        var replacement = Small with { Length = 11 };
        review.Load([replacement]);

        Assert.Same(replacement, Assert.Single(review.Visible));
        Assert.Empty(review.GetSelected());
        Assert.Equal(0, review.SelectedBytes);
    }
}
