namespace Sweep.App;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        string localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (args.SequenceEqual(new[] { "--smoke-test" }))
        {
            var overview = SystemOverview.Read(localData);
            if (overview.MemoryTotal == 0 || overview.MemoryAvailable > overview.MemoryTotal || overview.DiskTotal <= 0)
                return 1;

            using var window = new MainWindow(localData, refreshOnShow: false);
            window.Shown += (_, _) => window.BeginInvoke(window.Close);
            Application.Run(window);
            return 0;
        }

        Application.Run(new MainWindow(localData));
        return 0;
    }
}
