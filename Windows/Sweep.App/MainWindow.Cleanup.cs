using Sweep.Core;

namespace Sweep.App;

internal sealed partial class MainWindow
{
    private async Task ScanFiles()
    {
        SetBusy(true, "Scanning…");
        ShowCandidates([]);
        try
        {
            var results = await Task.Run(() => new CleanupPlan(localData).Scan(DateTime.UtcNow));
            ShowCandidates(results);
            status.Text = results.Count == 0
                ? "No eligible files found."
                : $"Found {results.Count:N0} files ({FormatBytes(results.Sum(file => file.Length))}). Select the files to delete.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            status.Text = "Scan could not be completed.";
            MessageBox.Show(this, error.Message, "Scan failed", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task DeleteSelected()
    {
        Candidate[] reviewed = selected.Order().Select(index => candidates[index]).ToArray();
        if (reviewed.Length == 0)
            return;

        var confirm = MessageBox.Show(this,
            $"Permanently delete {reviewed.Length:N0} selected files ({FormatBytes(reviewed.Sum(file => file.Length))})?",
            "Delete files", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
        if (confirm != DialogResult.Yes)
            return;

        SetBusy(true, "Deleting selected files…");
        try
        {
            var result = await Task.Run(() => DeleteFiles(reviewed));
            ShowCandidates(candidates.Where(file => !result.Deleted.Contains(file)).ToArray());
            status.Text = $"Deleted {result.Deleted.Count:N0} files ({FormatBytes(result.Deleted.Sum(file => file.Length))}). " +
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
        files.RowCount = 0;
        candidates = results;
        selected.Clear();
        files.RowCount = results.Count;
        UpdateSelection();
    }

    private void SetSelection(bool select)
    {
        selected.Clear();
        if (select)
            selected.UnionWith(Enumerable.Range(0, candidates.Count));
        files.Invalidate();
        UpdateSelection();
    }

    private void SetBusy(bool value, string? message = null)
    {
        busy = value;
        scan.Enabled = !busy;
        files.ReadOnly = busy;
        if (message is not null)
            status.Text = message;
        UpdateSelection();
    }

    private void UpdateSelection()
    {
        selectAll.Enabled = !busy && selected.Count < candidates.Count;
        clear.Enabled = !busy && selected.Count > 0;
        remove.Enabled = !busy && selected.Count > 0;
        remove.Text = selected.Count == 0 ? "&Delete selected…" : $"&Delete selected ({selected.Count:N0})…";
    }
}
