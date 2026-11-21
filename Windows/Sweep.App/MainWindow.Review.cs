using System.ComponentModel;
using System.Diagnostics;
using Sweep.Core;

namespace Sweep.App;

internal sealed partial class MainWindow
{
    private readonly CleanupReview review = new();
    private readonly Dictionary<CleanupLocation, RadioButton> locationButtons = [];
    private readonly RadioButton allLocations = CreateLocationButton();
    private readonly DataGridView files = CreateGrid("Cleanup results");
    private readonly TextBox search = new() { PlaceholderText = "Search file paths", AccessibleName = "Search file paths", Dock = DockStyle.Fill };
    private readonly Button scan = CreateButton("&Scan now", primary: true);
    private readonly Button open = CreateButton("Open in &Explorer");
    private readonly Button selectAll = CreateButton("Select s&hown");
    private readonly Button clear = CreateButton("C&lear selection");
    private readonly Button remove = CreateButton("&Delete selected…");
    private readonly Label reviewHeading = CreateLabel("Review files");
    private readonly Label reviewDetails = CreateLabel("Scan for old temporary files and developer caches.");
    private readonly Label selection = CreateLabel("No files selected");
    private readonly Label status = CreateLabel("");
    private readonly Label emptyTitle = CreateLabel("Ready to scan");
    private readonly Label emptyDetails = CreateLabel("Run a scan to see which files are eligible for cleanup.");
    private readonly TableLayoutPanel emptyResults = CreateLayout(SizeType.Percent);
    private IReadOnlyList<CleanupLocationResult>? scannedLocations;
    private string? category;
    private CleanupSort sort = CleanupSort.Size;
    private bool descending = true;

    private TabPage CreateCleanupPage()
    {
        var page = new TabPage("Cleanup") { BackColor = Paper };
        var layout = CreateLayout(SizeType.Percent);
        layout.ColumnCount = 2;
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 248));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.Padding = new Padding(14);

        layout.Controls.Add(CreateLocations(), 0, 0);
        layout.Controls.Add(CreateReviewWorkspace(), 1, 0);
        page.Controls.Add(layout);
        UpdateLocations();
        return page;
    }

    private Control CreateLocations()
    {
        var locations = CreateLayout([.. Enumerable.Repeat(SizeType.AutoSize, CleanupPlan.Locations.Count + 3), SizeType.Percent]);
        locations.BackColor = Surface;
        locations.Margin = new Padding(0, 0, 13, 0);
        locations.Padding = new Padding(10, 12, 10, 10);
        locations.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var header = CreateLabel("Scan locations", 13, FontStyle.Bold);
        header.Margin = new Padding(7, 0, 0, 1);
        var note = CreateLabel("Select a location to filter files.");
        note.ForeColor = Muted;
        note.MaximumSize = new Size(190, 0);
        note.Margin = new Padding(7, 0, 0, 11);
        locations.Controls.Add(header, 0, 0);
        locations.Controls.Add(note, 0, 1);
        locations.Controls.Add(allLocations, 0, 2);
        allLocations.Checked = true;
        allLocations.CheckedChanged += (_, _) => ChangeCategory(allLocations, null);

        foreach (var location in CleanupPlan.Locations)
        {
            RadioButton button = CreateLocationButton();
            button.MinimumSize = new Size(0, 62);
            locationButtons.Add(location, button);
            hints.SetToolTip(button, $"%LOCALAPPDATA%\\{location.RelativePath}");
            locations.Controls.Add(button, 0, locationButtons.Count + 2);
            button.CheckedChanged += (_, _) => ChangeCategory(button, location.Category);
        }
        return locations;
    }

    private void ChangeCategory(RadioButton button, string? selectedCategory)
    {
        if (!button.Checked)
            return;
        category = selectedCategory;
        UpdateReview();
    }

    private static RadioButton CreateLocationButton()
    {
        var button = new RadioButton
        {
            Appearance = Appearance.Button,
            AutoSize = true,
            Dock = DockStyle.Fill,
            ForeColor = Ink,
            Margin = new Padding(0, 0, 0, 5),
            MinimumSize = new Size(0, 48),
            Padding = new Padding(8, 1, 4, 1),
            TextAlign = ContentAlignment.MiddleLeft,
            UseMnemonic = false
        };
        if (!HighContrast)
        {
            button.FlatStyle = FlatStyle.Flat;
            button.BackColor = Surface;
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.CheckedBackColor = Selection;
            button.FlatAppearance.MouseOverBackColor = Line;
        }
        return button;
    }

    private Control CreateReviewWorkspace()
    {
        ConfigureFilesGrid();
        search.Margin = new Padding(0, 5, 10, 0);
        search.TextChanged += (_, _) => UpdateReview();
        scan.Click += async (_, _) => await ScanFiles();
        open.Click += (_, _) => OpenInExplorer();
        selectAll.Click += (_, _) => SetSelection(select: true);
        clear.Click += (_, _) => SetSelection(select: false);
        remove.Click += async (_, _) => await DeleteSelected();

        reviewHeading.Font = DisplayFont(16, FontStyle.Bold);
        reviewDetails.ForeColor = Muted;
        reviewDetails.Margin = new Padding(3, 1, 0, 11);
        var title = CreateLayout(SizeType.AutoSize);
        title.AutoSize = true;
        title.ColumnCount = 2;
        title.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        title.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        scan.Anchor = AnchorStyles.Right;
        scan.Margin = Padding.Empty;
        title.Controls.Add(reviewHeading, 0, 0);
        title.Controls.Add(scan, 1, 0);

        var toolbar = CreateLayout(SizeType.AutoSize);
        toolbar.AutoSize = true;
        toolbar.ColumnCount = 2;
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        toolbar.Margin = new Padding(0, 0, 0, 10);
        open.Margin = Padding.Empty;
        toolbar.Controls.Add(search, 0, 0);
        toolbar.Controls.Add(open, 1, 0);

        var actions = CreateLayout(SizeType.AutoSize);
        actions.AutoSize = true;
        actions.ColumnCount = 3;
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        actions.Margin = new Padding(0, 10, 0, 0);
        actions.Controls.Add(CreateActions(selectAll, clear), 0, 0);
        selection.Anchor = AnchorStyles.Right;
        selection.Margin = new Padding(4, 0, 12, 0);
        actions.Controls.Add(selection, 1, 0);
        remove.Margin = Padding.Empty;
        actions.Controls.Add(remove, 2, 0);

        status.ForeColor = Muted;
        status.Margin = new Padding(3, 3, 0, 0);
        var workspace = CreateLayout(SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize,
            SizeType.Percent, SizeType.AutoSize, SizeType.AutoSize);
        workspace.Margin = Padding.Empty;
        workspace.Controls.Add(title, 0, 0);
        workspace.Controls.Add(reviewDetails, 0, 1);
        workspace.Controls.Add(toolbar, 0, 2);
        workspace.Controls.Add(CreateResultsPane(), 0, 3);
        workspace.Controls.Add(actions, 0, 4);
        workspace.Controls.Add(status, 0, 5);
        return workspace;
    }

    private Control CreateResultsPane()
    {
        emptyResults.BackColor = Surface;
        emptyResults.Margin = Padding.Empty;
        emptyTitle.Font = DisplayFont(14, FontStyle.Bold);
        emptyTitle.Anchor = AnchorStyles.None;
        emptyDetails.Anchor = AnchorStyles.None;
        emptyDetails.ForeColor = Muted;
        emptyDetails.MaximumSize = new Size(330, 0);
        emptyDetails.TextAlign = ContentAlignment.MiddleCenter;

        var message = CreateLayout(SizeType.AutoSize, SizeType.AutoSize);
        message.AutoSize = true;
        message.Dock = DockStyle.None;
        message.Anchor = AnchorStyles.None;
        message.Controls.Add(emptyTitle, 0, 0);
        message.Controls.Add(emptyDetails, 0, 1);
        emptyResults.Controls.Add(message, 0, 0);

        var panel = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
        panel.Controls.Add(files);
        panel.Controls.Add(emptyResults);
        return panel;
    }

    private void ConfigureFilesGrid()
    {
        files.VirtualMode = true;
        files.Columns.Add(new DataGridViewCheckBoxColumn { HeaderText = "Select", Width = 58 });
        files.Columns.Add(TextColumn("File", 150, fill: true));
        files.Columns.Add(TextColumn("Category", 131));
        files.Columns.Add(TextColumn("Size", 75));
        files.Columns.Add(TextColumn("Modified", 143));
        for (int index = 1; index < files.Columns.Count; index++)
        {
            var column = files.Columns[index];
            column.SortMode = DataGridViewColumnSortMode.Programmatic;
            column.HeaderCell.ToolTipText = $"Sort by {column.HeaderText.ToLowerInvariant()}";
        }

        files.ColumnHeaderMouseClick += (_, e) =>
        {
            if (busy || e.ColumnIndex < 1 || e.Button != MouseButtons.Left)
                return;
            var column = (CleanupSort)(e.ColumnIndex - 1);
            descending = column == sort ? !descending : column is CleanupSort.Size or CleanupSort.Modified;
            sort = column;
            UpdateReview();
        };
        files.CellValueNeeded += (_, e) =>
        {
            if (e.RowIndex < 0 || e.RowIndex >= review.Visible.Count)
                return;
            Candidate file = review.Visible[e.RowIndex];
            e.Value = e.ColumnIndex switch
            {
                0 => review.IsSelected(e.RowIndex),
                1 => DescribeFile(file.Path),
                2 => file.Category,
                3 => FormatBytes(file.Length),
                4 => file.ModifiedUtc.ToLocalTime().ToString("g"),
                _ => null
            };
        };
        files.CellToolTipTextNeeded += (_, e) =>
        {
            if (e.ColumnIndex == 1 && e.RowIndex >= 0 && e.RowIndex < review.Visible.Count)
                e.ToolTipText = review.Visible[e.RowIndex].Path;
        };
        files.CurrentCellDirtyStateChanged += (_, _) =>
        {
            if (files.IsCurrentCellDirty)
                files.CommitEdit(DataGridViewDataErrorContexts.Commit);
        };
        files.CellValuePushed += (_, e) =>
        {
            if (busy || e.ColumnIndex != 0 || e.RowIndex < 0 || e.RowIndex >= review.Visible.Count)
                return;
            review.SetSelected(e.RowIndex, e.Value is true);
            UpdateSelection();
        };
        files.CurrentCellChanged += (_, _) => UpdateSelection();
    }

    private void UpdateReview()
    {
        files.RowCount = 0;
        review.Show(category, search.Text, sort, descending);
        files.RowCount = review.Visible.Count;
        for (int index = 1; index < files.Columns.Count; index++)
            files.Columns[index].HeaderCell.SortGlyphDirection = index - 1 == (int)sort
                ? (descending ? SortOrder.Descending : SortOrder.Ascending) : SortOrder.None;
        UpdateReviewDetails();
        if (review.Visible.Count > 0 && files.CurrentCell is null)
            files.CurrentCell = files.Rows[0].Cells[1];
        UpdateSelection();
    }

    private void UpdateReviewDetails()
    {
        bool anyFiles = review.Visible.Count != 0;
        files.Visible = anyFiles;
        emptyResults.Visible = !anyFiles;
        string eligibleFiles = FormatFileCount(review.Results.Count, "eligible ");
        reviewDetails.Text = scannedLocations is null ? "Scan for old temporary files and developer caches."
            : review.Visible.Count == review.Results.Count ? eligibleFiles
            : $"Showing {review.Visible.Count:N0} of {eligibleFiles}";

        if (scanCancellation is not null)
        {
            emptyTitle.Text = "Scanning…";
            emptyDetails.Text = "Sweep is checking the locations listed here.";
        }
        else if (scannedLocations is null)
        {
            emptyTitle.Text = "Ready to scan";
            emptyDetails.Text = "Run a scan to see which files are eligible for cleanup.";
        }
        else if (review.Results.Count == 0)
        {
            emptyTitle.Text = "No eligible files found";
            emptyDetails.Text = "Check the scan locations for age limits and results.";
        }
        else
        {
            emptyTitle.Text = "No matching files";
            emptyDetails.Text = "Try a different search or scan location.";
        }
    }

    private void UpdateLocations()
    {
        allLocations.Text = scannedLocations is null ? "All locations" :
            $"All locations{Environment.NewLine}{FormatFileCount(review.Results.Count)} ({FormatBytes(review.Results.Sum(file => file.Length))})";

        var totals = review.Results.GroupBy(file => file.Category).ToDictionary(
            group => group.Key, group => (Count: group.Count(), Bytes: group.Sum(file => file.Length)));

        foreach (var (location, button) in locationButtons)
        {
            var total = totals.GetValueOrDefault(location.Category);
            string details = scannedLocations?.FirstOrDefault(item => item.Location == location)?.WasScanned switch
            {
                true => $"{FormatFileCount(total.Count)} ({FormatBytes(total.Bytes)})",
                false when total.Count > 0 => $"{FormatFileCount(total.Count)} (partial scan)",
                false => "Unavailable",
                null => "Not scanned"
            };
            button.Text = $"{location.Category}{Environment.NewLine}Modified {location.MinimumDays}+ days ago{Environment.NewLine}{details}";
        }
    }

    private string DescribeFile(string path)
    {
        string name = Path.GetFileName(path);
        string? folder = Path.GetDirectoryName(Path.GetRelativePath(localData, path));
        return string.IsNullOrEmpty(folder) ? name : $"{name} ({folder})";
    }

    private static string FormatFileCount(int count, string prefix = "") =>
        $"{count:N0} {prefix}{(count == 1 ? "file" : "files")}";

    private Candidate? FocusedFile => files.CurrentCell is { RowIndex: >= 0 } cell && cell.RowIndex < review.Visible.Count
        ? review.Visible[cell.RowIndex] : null;

    private void OpenInExplorer()
    {
        if (FocusedFile is not { } file)
            return;
        if (!File.Exists(file.Path))
        {
            status.Text = "This file has moved or is unavailable. Scan again to refresh the list.";
            return;
        }

        try
        {
            using var process = Process.Start(new ProcessStartInfo(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"),
                $"/select,\"{file.Path}\"") { UseShellExecute = false });
        }
        catch (Win32Exception error)
        {
            MessageBox.Show(this, error.Message, "Could not open File Explorer", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }
}
