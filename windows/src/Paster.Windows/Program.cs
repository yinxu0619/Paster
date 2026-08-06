using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using System.Threading;

namespace Paster.Windows;

public static class Program
{
    private static Mutex? _singleInstanceMutex;

    [STAThread]
    public static void Main(string[] args)
    {
        Directory.SetCurrentDirectory(AppContext.BaseDirectory);
        _singleInstanceMutex = new Mutex(initiallyOwned: true, @"Global\Paster.Windows.SingleInstance", out var createdNew);
        if (!createdNew)
        {
            Services.AppLog.Info("Second instance blocked. Existing instance is already running.");
            return;
        }

        Services.AppLog.Info("Program.Main entered.");
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            // Without this, every await continuation resumes on a thread pool thread and any
            // XAML object touched afterwards throws RPC_E_WRONG_THREAD. The generated WinUI
            // entry point installs it; a hand-written Main has to do it too.
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new App();
        });
    }
}
