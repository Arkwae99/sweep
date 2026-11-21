using System.ComponentModel;
using System.Diagnostics;
using Sweep.Core;

namespace Sweep.App;

internal sealed partial class MainWindow : Form
{
    private readonly string localData;
    private readonly Label disk = new() { AutoSize = true, Text = "Disk: reading usage…" };
    private readonly Label memory = new() { AutoSize = true, Text = "RAM: reading usage…" };
    private readonly Label status = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft };
    private readonly DataGridView files = CreateGrid("Cleanup results");
    private readonly DataGridView processes = CreateGrid("Processes by RAM usage");
    private readonly Button scan = CreateButton("&Scan");
    private readonly Button selectAll = CreateButton("Select &all");
    private readonly Button clear = CreateButton("C&lear selection");
    private readonly Button remove = CreateButton("&Delete selected…");
    private IReadOnlyList<Candidate> candidates = [];
    private readonly HashSet<int> selected = [];
    private bool busy;

    public MainWindow(string localData, bool refreshOnShow = true)
    {
        this.localData = localData;
        Text = "Sweep";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(960, 620);
        MinimumSize = new Size(660, 450);

        var layout = CreateLayout(3);
        layout.Padding = new Padding(16);
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        var stats = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(0, 4, 0, 12) };
        disk.Margin = new Padding(0, 0, 24, 0);
        stats.Controls.AddRange([disk, memory]);

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(CreateCleanupPage());
        tabs.TabPages.Add(CreateMemoryPage());
        layout.Controls.Add(stats, 0, 0);
        layout.Controls.Add(tabs, 0, 1);
        layout.Controls.Add(status, 0, 2);
        Controls.Add(layout);

        status.Text = "Scan to find old temporary files and developer caches.";
        UpdateSelection();
        if (refreshOnShow)
            Shown += async (_, _) => await RefreshOverview();
        FormClosing += (_, e) => e.Cancel = busy && e.CloseReason == CloseReason.UserClosing;
    }

    private TabPage CreateCleanupPage()
    {
        files.VirtualMode = true;
        files.Columns.Add(new DataGridViewCheckBoxColumn { HeaderText = "Select", Width = 58, SortMode = DataGridViewColumnSortMode.NotSortable });
        files.Columns.Add(TextColumn("Category", 152));
        files.Columns.Add(TextColumn("Size", 86));
        files.Columns.Add(TextColumn("Last modified", 144));
        files.Columns.Add(TextColumn("File", 180, fill: true));
        files.CellValueNeeded += (_, e) =>
        {
            if (e.RowIndex < 0 || e.RowIndex >= candidates.Count)
                return;
            Candidate file = candidates[e.RowIndex];
            e.Value = e.ColumnIndex switch
            {
                0 => selected.Contains(e.RowIndex),
                1 => file.Category,
                2 => FormatBytes(file.Length),
                3 => file.ModifiedUtc.ToLocalTime().ToString("g"),
                4 => Path.GetRelativePath(localData, file.Path),
                _ => null
            };
        };
        files.CellToolTipTextNeeded += (_, e) =>
        {
            if (e.ColumnIndex == 4 && e.RowIndex >= 0 && e.RowIndex < candidates.Count)
                e.ToolTipText = candidates[e.RowIndex].Path;
        };
        files.CurrentCellDirtyStateChanged += (_, _) =>
        {
            if (files.IsCurrentCellDirty)
                files.CommitEdit(DataGridViewDataErrorContexts.Commit);
        };
        files.CellValuePushed += (_, e) =>
        {
            if (e.ColumnIndex != 0 || e.RowIndex < 0 || e.RowIndex >= candidates.Count)
                return;
            if (e.Value is true)
                selected.Add(e.RowIndex);
            else
                selected.Remove(e.RowIndex);
            UpdateSelection();
        };
        scan.Click += async (_, _) => await ScanFiles();
        selectAll.Click += (_, _) => SetSelection(select: true);
        clear.Click += (_, _) => SetSelection(select: false);
        remove.Click += async (_, _) => await DeleteSelected();
        return CreatePage("Cleanup", files, scan, selectAll, clear, remove);
    }

    private TabPage CreateMemoryPage()
    {
        processes.ReadOnly = true;
        processes.Columns.Add(TextColumn("Process", 120, fill: true));
        processes.Columns.Add(TextColumn("PID", 100));
        processes.Columns.Add(TextColumn("RAM (working set)", 150));
        var refresh = CreateButton("&Refresh usage");
        refresh.Click += async (_, _) =>
        {
            refresh.Enabled = false;
            await RefreshOverview();
            refresh.Enabled = true;
        };
        var taskManager = CreateButton("Open Task &Manager");
        taskManager.Click += (_, _) =>
        {
            try
            {
                using var process = Process.Start(Path.Combine(Environment.SystemDirectory, "Taskmgr.exe"));
            }
            catch (Win32Exception error)
            {
                MessageBox.Show(this, error.Message, "Could not open Task Manager", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        };
        return CreatePage("Memory", processes, refresh, taskManager);
    }

    private async Task RefreshOverview()
    {
        try
        {
            var overview = await Task.Run(() => SystemOverview.Read(localData));
            if (IsDisposed)
                return;
            disk.Text = $"Disk ({overview.Drive}): {FormatBytes(overview.DiskFree)} free of {FormatBytes(overview.DiskTotal)}";
            memory.Text = $"RAM: {FormatBytes((long)overview.MemoryAvailable)} available of {FormatBytes((long)overview.MemoryTotal)}";
            processes.Rows.Clear();
            foreach (var process in overview.Processes)
                processes.Rows.Add(process.Name, process.Id, FormatBytes(process.WorkingSet));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Win32Exception)
        {
            disk.Text = "Disk and RAM usage unavailable";
            memory.Text = "";
            processes.Rows.Clear();
            MessageBox.Show(this, error.Message, "Could not read usage", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private static DataGridView CreateGrid(string label) => new()
    {
        AccessibleName = label,
        AllowUserToAddRows = false,
        AllowUserToDeleteRows = false,
        AllowUserToResizeRows = false,
        BackgroundColor = SystemColors.Window,
        Dock = DockStyle.Fill,
        MultiSelect = false,
        RowHeadersVisible = false
    };

    private static DataGridViewTextBoxColumn TextColumn(string title, int width, bool fill = false) => new()
    {
        HeaderText = title,
        Width = width,
        AutoSizeMode = fill ? DataGridViewAutoSizeColumnMode.Fill : DataGridViewAutoSizeColumnMode.None,
        MinimumWidth = fill ? 100 : 30,
        ReadOnly = true,
        SortMode = DataGridViewColumnSortMode.NotSortable
    };

    private static Button CreateButton(string title) => new() { Text = title, AutoSize = true, MinimumSize = new Size(82, 30) };

    private static TableLayoutPanel CreateLayout(int rows) => new() { ColumnCount = 1, RowCount = rows, Dock = DockStyle.Fill };

    private static TabPage CreatePage(string title, DataGridView grid, params Button[] buttons)
    {
        var page = new TabPage(title) { UseVisualStyleBackColor = true };
        var layout = CreateLayout(2);
        layout.Padding = new Padding(8);
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Padding = new Padding(0, 0, 0, 6) };
        actions.Controls.AddRange(buttons);
        layout.Controls.Add(actions, 0, 0);
        layout.Controls.Add(grid, 0, 1);
        page.Controls.Add(layout);
        return page;
    }

    private static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KiB", "MiB", "GiB", "TiB"];
        double amount = bytes;
        int index = 0;
        while (amount >= 1024 && index < units.Length - 1)
        {
            amount /= 1024;
            index++;
        }
        return $"{amount:0.#} {units[index]}";
    }
}
