using Sweep.Core;

namespace Sweep.App;

internal sealed partial class MainWindow
{
    private CancellationTokenSource? scanCancellation;
    private bool busy;

    private async Task ScanFiles()
    {
        if (scanCancellation is { } activeScan)
        {
            activeScan.Cancel();
            scan.Enabled = false;
            status.Text = "Canceling scan…";
            return;
        }

        using var cancellation = new CancellationTokenSource();
        scanCancellation = cancellation;
        SetBusy(true, "Scanning for eligible files…");
        try
        {
            var results = await Task.Run(() => new CleanupPlan(localData).ScanWithLocations(DateTime.UtcNow, cancellation.Token));
            cancellation.Token.ThrowIfCancellationRequested();
            scannedLocations = results.Locations;
            ShowCandidates(results.Candidates);
            status.Text = $"Scan finished at {DateTime.Now:t}.";
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            status.Text = scannedLocations is null ? "Scan canceled." : "Scan canceled. Showing the previous results.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            status.Text = "Scan could not be completed.";
            MessageBox.Show(this, error.Message, "Scan failed", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            scanCancellation = null;
            SetBusy(false);
        }
    }

    private async Task DeleteSelected()
    {
        Candidate[] reviewed = review.GetSelected();
        if (reviewed.Length == 0)
            return;

        var confirm = MessageBox.Show(this,
            $"Permanently delete {FormatFileCount(reviewed.Length, "selected ")} ({FormatBytes(review.SelectedBytes)})?",
            "Delete files", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
        if (confirm != DialogResult.Yes)
            return;

        SetBusy(true, "Deleting selected files…");
        try
        {
            var result = await Task.Run(() => DeleteFiles(reviewed));
            ShowCandidates(review.Results.Where(file => !result.Deleted.Contains(file)).ToArray());
            status.Text = $"Deleted {FormatFileCount(result.Deleted.Count)} ({FormatBytes(result.Deleted.Sum(file => file.Length))}). " +
                $"Skipped {result.Failed:N0}.";
            if (result.Failed > 0)
            {
                MessageBox.Show(this, string.Join(Environment.NewLine + Environment.NewLine, result.Errors),
                    $"Could not delete {result.Failed:N0} files (first {result.Errors.Count:N0} shown)",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            await RefreshOverview();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            status.Text = "Cleanup stopped. Scan again to refresh the file list.";
            MessageBox.Show(this, error.Message, "Cleanup failed", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private (HashSet<Candidate> Deleted, int Failed, List<string> Errors) DeleteFiles(IEnumerable<Candidate> reviewed)
    {
        var plan = new CleanupPlan(localData);
        var deleted = new HashSet<Candidate>();
        var errors = new List<string>();
        int failed = 0;
        DateTime now = DateTime.UtcNow;
        foreach (Candidate file in reviewed)
        {
            try
            {
                WindowsCleanup.Delete(plan, file, now);
                deleted.Add(file);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                failed++;
                if (errors.Count < 5)
                    errors.Add($"{file.Path}{Environment.NewLine}{error.Message}");
            }
        }
        return (deleted, failed, errors);
    }

    private void ShowCandidates(IReadOnlyList<Candidate> results)
    {
        review.Load(results);
        UpdateLocations();
        UpdateReview();
    }

    private void SetSelection(bool select)
    {
        if (select)
            review.SelectVisible();
        else
            review.ClearSelection();
        files.Invalidate();
        UpdateSelection();
    }

    private void SetBusy(bool value, string? message = null)
    {
        busy = value;
        scan.Text = scanCancellation is null ? "&Scan now" : "Cancel &scan";
        scan.Enabled = !value || scanCancellation is not null;
        files.ReadOnly = value;
        allLocations.Enabled = !value;
        foreach (RadioButton button in locationButtons.Values)
            button.Enabled = !value;
        if (message is not null)
            status.Text = message;
        UpdateReviewDetails();
        UpdateSelection();
    }

    private void UpdateSelection()
    {
        search.Enabled = !busy && review.Results.Count > 0;
        open.Enabled = !busy && FocusedFile is not null;
        selectAll.Enabled = !busy && review.SelectedCount < review.Visible.Count;
        clear.Enabled = !busy && review.SelectedCount > 0;
        remove.Enabled = clear.Enabled;
        selection.Text = review.SelectedCount == 0 ? "No files selected" :
            $"{review.SelectedCount:N0} selected ({FormatBytes(review.SelectedBytes)})";
    }
}
