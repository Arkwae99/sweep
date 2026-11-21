using System.ComponentModel;
using System.Diagnostics;

namespace Sweep.App;

internal sealed partial class MainWindow : Form
{
    private static readonly bool HighContrast = SystemInformation.HighContrast;
    private static readonly Color Surface = HighContrast ? SystemColors.Window : Color.FromArgb(242, 246, 250);
    private static readonly Color Paper = HighContrast ? SystemColors.Window : Color.White;
    private static readonly Color Ink = HighContrast ? SystemColors.WindowText : Color.FromArgb(23, 46, 63);
    private static readonly Color Muted = HighContrast ? SystemColors.WindowText : Color.FromArgb(78, 98, 116);
    private static readonly Color Line = HighContrast ? SystemColors.WindowText : Color.FromArgb(219, 229, 235);
    private static readonly Color Accent = Color.FromArgb(6, 104, 92);
    private static readonly Color Selection = HighContrast ? SystemColors.Highlight : Color.FromArgb(214, 237, 231);
    private static readonly Color SelectionText = HighContrast ? SystemColors.HighlightText : Ink;

    private readonly string localData;
    private readonly List<Font> displayFonts = [];
    private readonly ToolTip hints = new();
    private readonly Label disk = CreateLabel("Reading…");
    private readonly Label memory = CreateLabel("Reading…");
    private readonly DataGridView processes = CreateGrid("Processes by RAM usage");

    public MainWindow(string localData, bool refreshOnShow = true)
    {
        this.localData = localData;
        Text = "Sweep";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(1100, 700);
        MinimumSize = new Size(870, 580);
        BackColor = Surface;
        ForeColor = Ink;

        var layout = CreateLayout(SizeType.AutoSize, SizeType.Percent);
        var tabs = new TabControl { Dock = DockStyle.Fill, Margin = new Padding(16, 12, 16, 12), AccessibleName = "Sweep views" };
        tabs.TabPages.Add(CreateCleanupPage());
        tabs.TabPages.Add(CreateMemoryPage());
        layout.Controls.Add(CreateHeader(), 0, 0);
        layout.Controls.Add(tabs, 0, 1);
        Controls.Add(layout);

        UpdateReview();
        if (refreshOnShow)
            Shown += async (_, _) => await RefreshOverview();
        FormClosing += (_, e) => e.Cancel = busy && e.CloseReason == CloseReason.UserClosing;
    }

    private Control CreateHeader()
    {
        var header = CreateLayout(SizeType.AutoSize);
        header.ColumnCount = 3;
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.AutoSize = true;
        header.BackColor = HighContrast ? SystemColors.Window : Color.FromArgb(20, 44, 61);
        header.Padding = new Padding(22, 12, 22, 13);
        header.Margin = Padding.Empty;

        var brand = CreateLabel("Sweep", 24, FontStyle.Bold);
        var description = CreateLabel("Scan, review, then clean.");
        header.Controls.Add(CreateHeaderBlock(brand, description, boldFirst: true), 0, 0);
        header.Controls.Add(CreateHeaderBlock(CreateLabel("Disk space"), disk), 1, 0);
        header.Controls.Add(CreateHeaderBlock(CreateLabel("Available memory"), memory), 2, 0);
        return header;
    }

    private Control CreateHeaderBlock(Label first, Label second, bool boldFirst = false)
    {
        Color main = HighContrast ? SystemColors.WindowText : Color.White;
        Color supporting = HighContrast ? SystemColors.WindowText : Color.FromArgb(202, 220, 229);
        var block = CreateLayout(SizeType.AutoSize, SizeType.AutoSize);
        block.AutoSize = true;
        block.Margin = boldFirst ? Padding.Empty : new Padding(24, 0, 0, 0);
        first.ForeColor = boldFirst ? main : supporting;
        second.ForeColor = boldFirst ? supporting : main;
        if (!boldFirst)
            second.Font = DisplayFont(11, FontStyle.Bold);
        block.Controls.Add(first, 0, 0);
        block.Controls.Add(second, 0, 1);
        return block;
    }

    private TabPage CreateMemoryPage()
    {
        processes.ReadOnly = true;
        processes.Columns.Add(TextColumn("Process", 140, fill: true));
        processes.Columns.Add(TextColumn("PID", 95));
        processes.Columns.Add(TextColumn("RAM (working set)", 155));
        var refresh = CreateButton("&Refresh usage");
        refresh.Click += async (_, _) =>
        {
            refresh.Enabled = false;
            await RefreshOverview();
            if (!IsDisposed)
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

        var page = new TabPage("Memory") { BackColor = Paper };
        var layout = CreateLayout(SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize, SizeType.Percent);
        layout.Padding = new Padding(18);
        layout.Controls.Add(CreateLabel("Memory usage", 16, FontStyle.Bold), 0, 0);
        var description = CreateLabel("Processes with the largest working sets.");
        description.ForeColor = Muted;
        layout.Controls.Add(description, 0, 1);
        var actions = CreateActions(refresh, taskManager);
        actions.Margin = new Padding(0, 10, 0, 12);
        layout.Controls.Add(actions, 0, 2);
        layout.Controls.Add(processes, 0, 3);
        page.Controls.Add(layout);
        return page;
    }

    private async Task RefreshOverview()
    {
        try
        {
            var overview = await Task.Run(() => SystemOverview.Read(localData));
            if (IsDisposed)
                return;
            disk.Text = $"{FormatBytes(overview.DiskFree)} free of {FormatBytes(overview.DiskTotal)} ({overview.Drive})";
            memory.Text = $"{FormatBytes((long)overview.MemoryAvailable)} of {FormatBytes((long)overview.MemoryTotal)}";
            processes.Rows.Clear();
            foreach (var process in overview.Processes)
                processes.Rows.Add(process.Name, process.Id, FormatBytes(process.WorkingSet));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Win32Exception)
        {
            if (IsDisposed)
                return;
            disk.Text = memory.Text = "Unavailable";
            processes.Rows.Clear();
            MessageBox.Show(this, error.Message, "Could not read usage", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private static DataGridView CreateGrid(string name) => new()
    {
        AccessibleName = name,
        AllowUserToAddRows = false,
        AllowUserToDeleteRows = false,
        AllowUserToResizeRows = false,
        BackgroundColor = Paper,
        BorderStyle = BorderStyle.FixedSingle,
        CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal,
        ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.Single,
        ColumnHeadersHeight = 32,
        ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.DisableResizing,
        ColumnHeadersDefaultCellStyle = new DataGridViewCellStyle
        {
            BackColor = Surface, ForeColor = Ink, SelectionBackColor = Surface, SelectionForeColor = Ink
        },
        DefaultCellStyle = new DataGridViewCellStyle
        {
            BackColor = Paper, ForeColor = Ink, SelectionBackColor = Selection, SelectionForeColor = SelectionText
        },
        Dock = DockStyle.Fill,
        EnableHeadersVisualStyles = false,
        GridColor = Line,
        Margin = Padding.Empty,
        MultiSelect = false,
        RowHeadersVisible = false,
        RowTemplate = new DataGridViewRow { Height = 29 }
    };

    private static DataGridViewTextBoxColumn TextColumn(string title, int width, bool fill = false) => new()
    {
        HeaderText = title,
        Width = width,
        AutoSizeMode = fill ? DataGridViewAutoSizeColumnMode.Fill : DataGridViewAutoSizeColumnMode.None,
        MinimumWidth = fill ? 124 : 40,
        ReadOnly = true,
        SortMode = DataGridViewColumnSortMode.NotSortable
    };

    private static Button CreateButton(string title, bool primary = false)
    {
        var button = new Button
        {
            Text = title,
            AutoSize = true,
            MinimumSize = new Size(82, 32),
            Padding = new Padding(8, 0, 8, 0),
            Margin = new Padding(0, 0, 7, 0)
        };
        if (primary && !HighContrast)
        {
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 0;
            button.BackColor = Accent;
            button.ForeColor = Color.White;
        }
        return button;
    }

    private static FlowLayoutPanel CreateActions(params Control[] controls)
    {
        var panel = new FlowLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Fill,
            WrapContents = false
        };
        panel.Controls.AddRange(controls);
        return panel;
    }

    private static TableLayoutPanel CreateLayout(params SizeType[] rows)
    {
        var layout = new TableLayoutPanel { ColumnCount = 1, RowCount = rows.Length, Dock = DockStyle.Fill };
        foreach (SizeType size in rows)
            layout.RowStyles.Add(new RowStyle(size, size == SizeType.Percent ? 100 : 0));
        return layout;
    }

    private static Label CreateLabel(string text) => new()
    {
        AutoSize = true,
        ForeColor = Ink,
        Text = text,
        UseMnemonic = false
    };

    private Label CreateLabel(string text, float size, FontStyle style) =>
        new() { AutoSize = true, ForeColor = Ink, Text = text, UseMnemonic = false, Font = DisplayFont(size, style) };

    private Font DisplayFont(float size, FontStyle style)
    {
        var font = new Font(Font.FontFamily, size, style);
        displayFonts.Add(font);
        return font;
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (!disposing)
            return;
        hints.Dispose();
        foreach (Font font in displayFonts)
            font.Dispose();
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
