// The tray app's controller: collects the status, paints the icon, owns the
// flyout and runs its actions. It collects nothing itself -- avd-photos-status
// emits the JSON and avd-photos-sync writes every number in it -- exactly as
// the macOS menu-bar app does.
//
// GLANCEABLE, NOT A WALL: the notification area carries the ring alone (a
// tooltip adds the one short count the Mac shows beside it); the detail lives
// in the flyout, rebuilt every time it opens so its ages are computed when
// eyes are on them.
using System.Diagnostics;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace PhotoSync;

public partial class App : Application
{
    private TrayIcon? _tray;
    private FlyoutWindow? _flyout;
    private Pipeline? _pipe;
    private string? _pipeError;
    private DispatcherQueue? _dq;
    private DispatcherQueueTimer? _timer, _spinner;

    internal Stats Stats { get; private set; } = new();
    internal bool HaveStats { get; private set; }
    internal string? LastError { get; private set; }
    internal DateTime? LastGood { get; private set; }
    internal bool Offloading { get; private set; }
    internal bool HasPipeline => _pipe != null;

    private int _failStreak;
    private bool _collecting;
    private double _spinAngle;
    private RingSpec? _lastIconSpec;
    private string _lastTip = "";

    public App()
    {
        InitializeComponent();
        // A tray app has no main window; it lives until Quit says otherwise.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        // A crash must leave a reason behind: there is no console, and Windows
        // Error Reporting records only "stowed exception in Microsoft.UI.Xaml".
        UnhandledException += (_, e) => Pipeline.TaskLog("tray", $"unhandled: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Pipeline.TaskLog("tray", $"unhandled: {e.ExceptionObject}");
        DebugSettings.XamlResourceReferenceFailed += (_, e) => Pipeline.TaskLog("tray", $"XAML resource: {e.Message}");
    }

    // The meter's own health, distinct from the pipeline's: three missed 30 s
    // ticks means the collector itself is failing or wedged.
    internal bool CollectorSick => _failStreak >= 3 || (LastGood is DateTime g && (DateTime.Now - g).TotalSeconds > 150);

    internal View CurrentView() => Presenter.Decide(Stats, HaveStats, CollectorSick, LastError, _spinAngle);

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _dq = DispatcherQueue.GetForCurrentThread();
        _pipe = Pipeline.Load(out _pipeError);

        _tray = new TrayIcon();
        _tray.Invoked += anchor => _flyout?.Toggle(anchor, _tray.Bounds());
        _tray.AppearanceChanged += () => { _lastIconSpec = null; Render(); };
        _tray.Resumed += Refresh;

        _flyout = new FlyoutWindow(this);
        Render();
        Refresh();

        _timer = _dq.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(30);
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();

        // A second launch (the Start-menu shortcut) asks this one to show itself.
        if (Program.ShowRequests is { } show)
        {
            new Thread(() =>
            {
                while (show.WaitOne())
                    _dq.TryEnqueue(() => _flyout?.ShowNearTray(_tray.Bounds()));
            }) { IsBackground = true, Name = "show-requests" }.Start();
        }
        // Launched by hand (not by the logon task): show where it lives.
        if (!Program.StartedInBackground)
            _dq.TryEnqueue(DispatcherQueuePriority.Low, () => _flyout.ShowNearTray(_tray.Bounds()));
    }

    // -- Collect ----------------------------------------------------------------

    internal void Refresh()
    {
        if (_pipe == null) { LastError = _pipeError; _failStreak++; Render(); return; }
        var script = _pipe.Script("avd-photos-status");
        if (script == null) { LastError = "avd-photos-status not found"; _failStreak++; Render(); return; }
        // One collection at a time: a wedged run must not pile new processes on
        // top of itself every tick.
        if (_collecting) return;
        _collecting = true;
        var psi = _pipe.StartInfo(script, Array.Empty<string>());
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        Task.Run(() =>
        {
            Stats? parsed = null; string? err = null;
            try
            {
                using var p = Process.Start(psi)!;
                var output = p.StandardOutput.ReadToEndAsync();
                _ = p.StandardError.ReadToEndAsync();
                // Watchdog. The script bounds its own slow path (one adb call,
                // 6 s); 25 s only trips when something is genuinely wedged, and
                // killing it turns a silent freeze into a visible error state.
                if (!p.WaitForExit(25_000))
                {
                    try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                    err = "collector timed out";
                }
                // Bounded too: a grandchild that inherited the pipe would hold
                // stdout open after bash itself has exited.
                else if (!output.Wait(5_000)) err = "collector output never ended";
                else
                {
                    var text = output.Result;
                    parsed = Stats.Parse(text);
                    if (parsed == null) err = text.Length == 0 ? "collector printed nothing" : "collector output unparseable";
                }
            }
            catch (Exception e) { err = $"collector failed to start: {e.Message}"; }
            _dq!.TryEnqueue(() =>
            {
                _collecting = false;
                if (parsed != null)
                {
                    Stats = parsed; HaveStats = true;
                    LastError = null; LastGood = DateTime.Now; _failStreak = 0;
                }
                else { LastError = err; _failStreak++; }
                Render();
                _flyout?.RefreshIfOpen();
            });
        });
    }

    // -- Paint ----------------------------------------------------------------

    internal void Render()
    {
        if (_tray == null) return;
        var view = CurrentView();
        var tip = "Photo Sync — " + view.Headline + (view.Count.Length > 0 ? $" ({view.Count})" : "");
        if (_lastIconSpec != view.Ring || tip != _lastTip)
        {
            int n = TrayIcon.IconSize();
            var icon = Ring.ToIcon(Ring.Render(view.Ring, n, TaskbarIsDark()), n);
            if (icon != IntPtr.Zero) _tray.Update(icon, tip);
            _lastIconSpec = view.Ring;
            _lastTip = tip;
        }
        _tray.EnsureShown();
        if (view.Spinning) StartSpinner(); else StopSpinner();
    }

    // 8 fps is plenty for a 16 px arc; the timer exists only while a spinning
    // step is on screen.
    private void StartSpinner()
    {
        if (_spinner != null || _dq == null) return;
        _spinner = _dq.CreateTimer();
        _spinner.Interval = TimeSpan.FromMilliseconds(125);
        _spinner.Tick += (_, _) => { _spinAngle = (_spinAngle + 20) % 360; Render(); _flyout?.RefreshRingIfOpen(); };
        _spinner.Start();
    }

    private void StopSpinner()
    {
        _spinner?.Stop();
        _spinner = null;
    }

    // The taskbar has its own theme, separate from the apps' (Settings >
    // Personalization > Colors > "Choose your default Windows mode").
    internal static bool TaskbarIsDark()
    {
        using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return k?.GetValue("SystemUsesLightTheme") is not int v || v == 0;
    }

    // -- Actions ----------------------------------------------------------------

    /// <summary>
    /// The manual trigger: run the scheduled sync task, so the run is Task
    /// Scheduler's rather than this app's and a restart of the tray cannot kill
    /// it mid-push. Spawning --sync directly is the fallback when the task is
    /// not registered; the script's lock turns a race with a scheduled tick
    /// into one skipped line.
    /// </summary>
    internal void CheckNow()
    {
        // Off the UI thread: schtasks can take seconds, and the flyout must not
        // freeze while it does.
        Task.Run(() =>
        {
            bool kicked = false;
            try
            {
                var psi = new ProcessStartInfo("schtasks.exe") { UseShellExecute = false, CreateNoWindow = true };
                foreach (var a in new[] { "/Run", "/TN", Pipeline.TaskFolder + "sync" }) psi.ArgumentList.Add(a);
                psi.RedirectStandardOutput = psi.RedirectStandardError = true;
                using var p = Process.Start(psi)!;
                _ = p.StandardOutput.ReadToEndAsync();
                _ = p.StandardError.ReadToEndAsync();
                kicked = p.WaitForExit(10_000) && p.ExitCode == 0;
            }
            catch (Exception) { }
            if (!kicked) SpawnSelf("--sync");
            Thread.Sleep(3000);
            _dq?.TryEnqueue(Refresh);
        });
    }

    /// <summary>
    /// The sync with reclaim forced on, detached and non-blocking: an offload run
    /// downloads, pushes and waits on Google Photos, so it is minutes long. The
    /// in-flight flag keeps a second click from starting an overlapping run.
    /// </summary>
    internal void Offload()
    {
        if (Offloading || _pipe?.Script("avd-photos-sync") is not { } script) return;
        Offloading = true;
        var psi = _pipe.StartInfo(script, new[] { "--offload" });
        Task.Run(() =>
        {
            try { using var p = Process.Start(psi)!; p.WaitForExit(); } catch (Exception) { }
            _dq?.TryEnqueue(() => { Offloading = false; Refresh(); });
        });
        _flyout?.RefreshIfOpen();
    }

    internal void OpenPhotos() => SpawnSelf("--open-photos");

    internal void OpenLogs()
    {
        Directory.CreateDirectory(Pipeline.LogDir);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Pipeline.LogDir}\"") { UseShellExecute = true });
    }

    internal void Quit()
    {
        StopSpinner();
        _timer?.Stop();
        _tray?.Dispose();
        _tray = null;
        _flyout?.Shutdown();
        Exit();
    }

    // A separate, windowless copy of this exe, so the work outlives the tray.
    private static void SpawnSelf(string mode)
    {
        var exe = Environment.ProcessPath;
        if (exe == null) return;
        try { Process.Start(new ProcessStartInfo(exe, mode) { UseShellExecute = false, CreateNoWindow = true }); }
        catch (Exception) { }
    }
}
