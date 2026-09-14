// Photo Sync for Windows -- the tray face of the iCloud -> Google Photos
// pipeline, and the windowless launcher its scheduled tasks run.
//
// THE CLI IS HANDLED BEFORE WINUI EXISTS, as on the Mac (where NSStatusBar
// would register the process as a running copy of the app). Here the reason is
// the console: Task Scheduler gives a console program a visible window, so every
// task runs THIS exe -- a GUI-subsystem program with no window at all -- which
// starts bash hidden and waits. It spawns and waits rather than handing off, so
// the task's own status is the script's exit code.
//
//   PhotoSync.exe                    the tray (a second launch opens the flyout
//                                    of the one already running)
//   PhotoSync.exe --background       the tray, silently (the logon task)
//   PhotoSync.exe --sync [args...]   avd-photos-sync, args passed through
//   PhotoSync.exe --setup [--headless|--bootstrap]
//                                    avd-photos-setup with only those flags
//   PhotoSync.exe --open-photos      avd-photos-app --launch (the Start-menu
//                                    "Google Photos (AVD)" shortcut)
//
// Each mode names ONE fixed script; there is no general "run this". Arguments
// are passed through for --sync only (its own flags: --offload,
// --reclaim-dry-run), because that is the one the tray itself calls with flags.
using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace PhotoSync;

public static class Program
{
    private const string MutexName = @"Local\icloud-to-google-photos.tray";
    private const string ShowEventName = @"Local\icloud-to-google-photos.tray.show";

    internal static EventWaitHandle? ShowRequests;
    internal static bool StartedInBackground;

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0 && !(args.Length == 1 && args[0] == "--background"))
            return Cli(args);
        StartedInBackground = args.Length == 1;

        // SINGLE INSTANCE. A second tray icon is not a rendering bug that can be
        // drawn away: each process owns its own. A launch while one is running
        // asks that one to open its flyout (the Start-menu shortcut's job) and
        // leaves; the logon task's --background launch just leaves. An upgrade
        // stops the old process itself before swapping the files (build.ps1).
        using var mutex = new Mutex(true, MutexName, out bool first);
        if (!first)
        {
            if (!StartedInBackground && EventWaitHandle.TryOpenExisting(ShowEventName, out var show))
            {
                // This launch came from the user (a Start-menu click) and so may
                // take the foreground; the running tray may not, until it is
                // handed that right -- or its flyout opens behind everything.
                Native.AllowSetForegroundWindow(Native.ASFW_ANY);
                show.Set();
                show.Dispose();
            }
            return 0;
        }
        ShowRequests = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(init =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        GC.KeepAlive(mutex);
        return 0;
    }

    private static int Cli(string[] args)
    {
        string mode = args[0];
        string script;
        string[] pass;
        switch (mode)
        {
            case "--sync":
                script = "avd-photos-sync"; pass = args[1..]; break;
            case "--setup":
                if (args[1..].Any(a => a is not ("--headless" or "--bootstrap")))
                    return Usage("--setup takes only --headless and --bootstrap");
                script = "avd-photos-setup"; pass = args[1..]; break;
            case "--open-photos":
                if (args.Length != 1) return Usage("--open-photos takes no arguments");
                // Launched by a Start-menu click, this process may take the
                // foreground; the bash -> PowerShell chain that finally raises
                // the emulator's window may not, and Windows would leave that
                // window behind whatever was in front (measured). Pass the right on.
                Native.AllowSetForegroundWindow(Native.ASFW_ANY);
                script = "avd-photos-app"; pass = new[] { "--launch" }; break;
            default:
                return Usage($"unknown argument {mode}");
        }
        string log = mode.TrimStart('-');

        var pipe = Pipeline.Load(out var error);
        if (pipe == null) { Pipeline.TaskLog(log, $"PhotoSync {mode}: {error}"); return 127; }
        var path = pipe.Script(script);
        if (path == null) { Pipeline.TaskLog(log, $"PhotoSync {mode}: {script} not found in {pipe.BinDir} — re-run install.ps1"); return 127; }

        var psi = pipe.StartInfo(path, pass);
        // The scripts own their logs; stdout is the human-readable echo of the
        // same lines and is dropped. stderr is where a script's own failure to
        // start lands, so it is kept.
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        try
        {
            using var p = Process.Start(psi)!;
            p.OutputDataReceived += (_, _) => { };
            p.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Pipeline.TaskLog(log, e.Data); };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.WaitForExit();
            return p.ExitCode;
        }
        catch (Exception e)
        {
            Pipeline.TaskLog(log, $"PhotoSync {mode}: cannot run {pipe.Bash}: {e.Message}");
            return 126;
        }
    }

    private static int Usage(string why)
    {
        Pipeline.TaskLog("cli", $"PhotoSync: {why}; usage: PhotoSync [--background | --sync [args] | --setup [--headless|--bootstrap] | --open-photos]");
        return 64;
    }
}
