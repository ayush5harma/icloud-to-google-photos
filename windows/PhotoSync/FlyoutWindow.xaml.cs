// The flyout: a borderless, always-on-top window with the Desktop Acrylic
// backdrop and Windows 11's rounded corners, placed against the taskbar next to
// the notification area -- the look of the system's own flyouts. It is never
// closed, only hidden, and it hides the moment it loses focus, as a flyout does.
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.System;

namespace PhotoSync;

public sealed partial class FlyoutWindow : Window
{
    private const double WidthDip = 360;
    private const double RingDip = 36;

    private readonly App _app;
    private readonly IntPtr _hwnd;
    private bool _open, _loaded, _shutdown;
    private DateTime _hiddenAt = DateTime.MinValue;
    private Native.POINT _anchor;

    internal FlyoutWindow(App app)
    {
        _app = app;
        InitializeComponent();
        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);

        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;          // no taskbar button, no Alt+Tab entry
        SystemBackdrop = new DesktopAcrylicBackdrop();
        int round = Native.DWMWCP_ROUND;
        Native.DwmSetWindowAttribute(_hwnd, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));

        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated && _open) Hide();
        };
        // Alt+F4 hides it too; only Quit ends the app.
        AppWindow.Closing += (_, e) => { if (!_shutdown) { e.Cancel = true; Hide(); } };
        Root.KeyDown += (_, e) => { if (e.Key == VirtualKey.Escape) Hide(); };
        // The measured height is an estimate until the tree has laid out (an
        // InfoBar or a wrapped headline settles a pass later); the real one
        // arrives here, and the window is fitted to it.
        Root.SizeChanged += (_, _) => { if (_open) Place(); };
        RefreshButton.Click += (_, _) => _app.Refresh();
        LogsButton.Click += (_, _) => { Hide(); _app.OpenLogs(); };
        QuitButton.Click += (_, _) => _app.Quit();
    }

    /// <summary>A click on the tray icon: open it, or close it if it is open.</summary>
    internal void Toggle(Native.POINT click, Native.RECT? iconBounds)
    {
        if (_open) { Hide(); return; }
        // The click that just took focus away (and so hid it) must not reopen it.
        if ((DateTime.Now - _hiddenAt).TotalMilliseconds < 350) return;
        ShowAt(iconBounds is { } r ? new Native.POINT { X = (r.Left + r.Right) / 2, Y = (r.Top + r.Bottom) / 2 } : click);
    }

    internal void ShowNearTray(Native.RECT? iconBounds)
    {
        if (iconBounds is { } r) ShowAt(new Native.POINT { X = (r.Left + r.Right) / 2, Y = (r.Top + r.Bottom) / 2 });
        else { Native.GetCursorPos(out var p); ShowAt(p); }
    }

    private void ShowAt(Native.POINT anchor)
    {
        _anchor = anchor;
        Rebuild();
        if (!_loaded)
        {
            // The first show happens off-screen and unactivated, so the tree is
            // loaded (templates applied) before it is measured for real.
            AppWindow.Move(new PointInt32(-32000, -32000));
            AppWindow.Show(false);
            _loaded = true;
        }
        Place();
        // Open BEFORE activation: the Deactivated that hides it must find it open.
        _open = true;
        AppWindow.Show(true);
        Activate();
        Native.SetForegroundWindow(_hwnd);
        // An open is a moment the numbers are actually read: collect now, so the
        // flyout repaints with fresh ones a second later.
        _app.Refresh();
    }

    internal void Hide()
    {
        if (!_open) return;
        _open = false;
        _hiddenAt = DateTime.Now;
        AppWindow.Hide();
    }

    internal void RefreshIfOpen()
    {
        if (!_open) return;
        Rebuild();
        Place();
    }

    internal void RefreshRingIfOpen()
    {
        if (_open) RingImage.Source = RingBitmap(_app.CurrentView().Ring);
    }

    internal void Shutdown()
    {
        _shutdown = true;
        Close();
    }

    // -- Placement --------------------------------------------------------------

    private static double MonitorScale(Native.POINT p)
    {
        var mon = Native.MonitorFromPoint(p, Native.MONITOR_DEFAULTTONEAREST);
        return Native.GetDpiForMonitor(mon, 0, out uint dpi, out _) == 0 ? dpi / 96.0 : 1.0;
    }

    // Against the taskbar, whichever edge it is on, centred on the icon and kept
    // inside the work area; 12 px from the edge, like the system's flyouts.
    private void Place()
    {
        double scale = MonitorScale(_anchor);
        Root.Measure(new Windows.Foundation.Size(WidthDip, double.PositiveInfinity));
        int w = (int)Math.Ceiling(WidthDip * scale);
        int h = (int)Math.Ceiling(Root.DesiredSize.Height * scale);
        int m = (int)Math.Round(12 * scale);

        var area = DisplayArea.GetFromPoint(new PointInt32(_anchor.X, _anchor.Y), DisplayAreaFallback.Nearest);
        var wa = area.WorkArea;
        var ob = area.OuterBounds;
        int x, y;
        if (wa.Y + wa.Height < ob.Y + ob.Height) { y = wa.Y + wa.Height - h - m; x = _anchor.X - w / 2; }      // bottom
        else if (wa.Y > ob.Y) { y = wa.Y + m; x = _anchor.X - w / 2; }                                         // top
        else if (wa.X > ob.X) { x = wa.X + m; y = _anchor.Y - h / 2; }                                         // left
        else if (wa.X + wa.Width < ob.X + ob.Width) { x = wa.X + wa.Width - w - m; y = _anchor.Y - h / 2; }    // right
        else { x = wa.X + wa.Width - w - m; y = wa.Y + wa.Height - h - m; }                                    // auto-hide
        x = Math.Clamp(x, wa.X + m, Math.Max(wa.X + m, wa.X + wa.Width - w - m));
        y = Math.Clamp(y, wa.Y + m, Math.Max(wa.Y + m, wa.Y + wa.Height - h - m));
        // Onto the target monitor FIRST: moving between monitors of different
        // scaling rescales the window by the DPI ratio, so a size set before the
        // move would come out wrong -- and nothing would correct it, because in
        // DIPs it is unchanged.
        AppWindow.Move(new PointInt32(x, y));
        // ResizeClient alone overshoots: with the title bar hidden, AppWindow
        // still sizes as if a caption strip sat above the content, and the XAML
        // then fills that strip too -- 38 px of empty acrylic under the footer
        // at 125% (measured). So size the OUTER window by what actually came out.
        AppWindow.ResizeClient(new SizeInt32(w, h));
        var client = AppWindow.ClientSize;
        if (client.Width != w || client.Height != h)
        {
            var outer = AppWindow.Size;
            AppWindow.Resize(new SizeInt32(outer.Width - (client.Width - w), outer.Height - (client.Height - h)));
        }
        AppWindow.Move(new PointInt32(x, y));
    }

    // -- Content ----------------------------------------------------------------

    private void Rebuild()
    {
        var s = _app.Stats;
        var view = _app.CurrentView();
        RingImage.Source = RingBitmap(view.Ring);
        Headline.Text = view.Headline;
        Headline.Foreground = ToneBrush(view.HeadlineTone);

        Notes.Children.Clear();
        if (_app.HaveStats && !s.Armed)
            Notes.Children.Add(new InfoBar
            {
                IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning,
                Title = "Dormant", Message = "Run avd-photos-arm to enable the sync.",
            });

        Ledger.Children.Clear();
        Ledger.RowDefinitions.Clear();
        var rows = Presenter.Ledger(s);
        for (int i = 0; i < rows.Count; i++)
        {
            Ledger.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = rows[i].Label, Foreground = Res("TextFillColorSecondaryBrush") };
            var value = new TextBlock { Text = rows[i].Value, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetRow(label, i); Grid.SetRow(value, i); Grid.SetColumn(value, 1);
            Ledger.Children.Add(label); Ledger.Children.Add(value);
        }

        // The actions, each offered only in a state where it is safe (the
        // macOS menu's rules). Offload deletes from the real photo library, so it
        // exists only once Google Photos' own database has confirmed a batch --
        // and the script checks the same stamp again before deleting anything.
        Actions.Children.Clear();
        if (_app.HasPipeline && s.Armed)
        {
            if (!s.Running) Actions.Children.Add(ActionButton("Check iCloud now", "\uE895", _app.CheckNow, accent: true));
            else Actions.Children.Add(Note("Checking — a sync run is in progress"));
            if (_app.Offloading) Actions.Children.Add(Note("Offloading from iCloud…"));
            else if (s.Running) Actions.Children.Add(Note("Offload unavailable while a sync is running"));
            else if (s.Confirmed) Actions.Children.Add(ActionButton("Offload from iCloud", "\uE74D", _app.Offload));
            else Actions.Children.Add(Note("Offload unavailable — no confirmed upload yet"));
        }
        if (_app.HasPipeline)
            Actions.Children.Add(ActionButton("Open Google Photos (emulator)", "\uE91B", () => { Hide(); _app.OpenPhotos(); }));

        Footer.Text = _app.LastGood is DateTime g
            ? $"Updated {Fmt.RelAge((int)(DateTime.Now - g).TotalSeconds)}"
            : "Not updated yet";
    }

    private static Button ActionButton(string text, string glyph, Action onClick, bool accent = false)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 16 });
        content.Children.Add(new TextBlock { Text = text });
        var b = new Button
        {
            Content = content,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(12, 7, 12, 7),
        };
        if (accent && Application.Current.Resources.TryGetValue("AccentButtonStyle", out var style))
            b.Style = (Style)style;
        b.Click += (_, _) => onClick();
        return b;
    }

    private static TextBlock Note(string text) => new()
    {
        Text = text,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = Res("TextFillColorSecondaryBrush"),
        Margin = new Thickness(2, 2, 0, 2),
        TextWrapping = TextWrapping.WrapWholeWords,
    };

    private ImageSource RingBitmap(RingSpec spec)
    {
        // Before the first load there is no XamlRoot; the monitor's own scale
        // keeps that first ring from being drawn at 100% and stretched.
        double scale = Root.XamlRoot?.RasterizationScale ?? MonitorScale(_anchor);
        int n = Math.Max(16, (int)Math.Round(RingDip * scale));
        bool dark = Root.ActualTheme == ElementTheme.Dark;
        var bytes = Ring.Premultiply(Ring.Render(spec, n, dark));
        var bmp = new WriteableBitmap(n, n);
        using (var stream = bmp.PixelBuffer.AsStream()) stream.Write(bytes, 0, bytes.Length);
        bmp.Invalidate();
        return bmp;
    }

    private static Brush ToneBrush(Tone t) => Res(t switch
    {
        Tone.Red => "SystemFillColorCriticalBrush",
        Tone.Orange => "SystemFillColorCautionBrush",
        Tone.Green => "SystemFillColorSuccessBrush",
        Tone.Blue => "AccentTextFillColorPrimaryBrush",
        _ => "TextFillColorSecondaryBrush",
    });

    private static Brush Res(string key) =>
        Application.Current.Resources.TryGetValue(key, out var v) && v is Brush b ? b : new SolidColorBrush(Microsoft.UI.Colors.Gray);
}
