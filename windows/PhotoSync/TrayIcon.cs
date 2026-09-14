// The notification-area icon, through Shell_NotifyIcon directly.
//
// ITS OWN HIDDEN WINDOW, AND NOT A MESSAGE-ONLY ONE. The icon reports clicks as
// messages to a window, and two messages this app must hear are BROADCASTS,
// which a message-only (HWND_MESSAGE) window never receives: "TaskbarCreated",
// sent when Explorer restarts -- every notify icon is gone at that moment and
// must be added again, or the ring silently disappears until the next logon --
// and WM_SETTINGCHANGE, which is how a light/dark switch of the taskbar arrives.
// So it is an invisible tool window, created on the UI thread, whose messages
// the WinUI dispatcher pumps like any other.
//
// NOTIFYICON_VERSION_4: a left click arrives as NIN_SELECT, the keyboard's
// Enter/Space as NIN_KEYSELECT and a right click as WM_CONTEXTMENU, each with
// the anchor point in wParam. All three open the same flyout -- it holds every
// action, as a Windows 11 flyout does.
using System.Runtime.InteropServices;

namespace PhotoSync;

internal sealed class TrayIcon : IDisposable
{
    private const int CallbackMessage = Native.WM_APP + 1;
    private const int IconId = 1;
    private const string ClassName = "PhotoSync.TrayWindow";

    // The delegate must outlive the window, or the GC collects it out from under
    // the class registration.
    private static readonly Native.WndProc s_proc = WindowProc;
    private static TrayIcon? s_instance;

    private readonly IntPtr _hwnd;
    private readonly uint _taskbarCreated;
    private IntPtr _icon;
    private string _tip = "Photo Sync";
    private bool _added;
    private DateTime _lastKeySelect = DateTime.MinValue;

    /// <summary>The icon was clicked or chosen from the keyboard; the anchor is in screen pixels.</summary>
    public event Action<Native.POINT>? Invoked;
    /// <summary>Theme, DPI or display layout changed: repaint the icon.</summary>
    public event Action? AppearanceChanged;
    /// <summary>The PC woke from sleep.</summary>
    public event Action? Resumed;

    public TrayIcon()
    {
        s_instance = this;
        var instance = Native.GetModuleHandleW(null);
        var wc = new Native.WNDCLASSEXW
        {
            cbSize = Marshal.SizeOf<Native.WNDCLASSEXW>(),
            lpfnWndProc = s_proc,
            hInstance = instance,
            lpszClassName = ClassName,
        };
        Native.RegisterClassExW(ref wc);
        _hwnd = Native.CreateWindowExW(Native.WS_EX_TOOLWINDOW, ClassName, "Photo Sync", Native.WS_POPUP,
            0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        _taskbarCreated = Native.RegisterWindowMessageW("TaskbarCreated");
    }

    /// <summary>The icon's pixel size for the current system DPI (16 at 100%, 20 at 125%, ...).</summary>
    public static int IconSize() => Math.Max(16, Native.GetSystemMetricsForDpi(Native.SM_CXSMICON, Native.GetDpiForSystem()));

    /// <summary>Replace the icon and tooltip. Takes ownership of <paramref name="hicon"/>.</summary>
    public void Update(IntPtr hicon, string tip)
    {
        var old = _icon;
        _icon = hicon;
        _tip = tip.Length > 127 ? tip[..126] + "…" : tip;
        Apply();
        if (old != IntPtr.Zero && old != hicon) Native.DestroyIcon(old);
    }

    /// <summary>
    /// Add the icon again if the shell does not have it. The logon task can
    /// start this app before the taskbar exists, when NIM_ADD fails; Explorer's
    /// "TaskbarCreated" broadcast normally repairs that, but a missed one would
    /// leave the ring gone for the whole session. Cheap: a no-op once added.
    /// </summary>
    public void EnsureShown()
    {
        if (!_added && _icon != IntPtr.Zero) Apply();
    }

    /// <summary>The icon's rectangle on screen, when the shell will say.</summary>
    public Native.RECT? Bounds()
    {
        var id = new Native.NOTIFYICONIDENTIFIER { cbSize = Marshal.SizeOf<Native.NOTIFYICONIDENTIFIER>(), hWnd = _hwnd, uID = IconId };
        return Native.Shell_NotifyIconGetRect(ref id, out var r) == 0 ? r : null;
    }

    private Native.NOTIFYICONDATAW Data() => new()
    {
        cbSize = Marshal.SizeOf<Native.NOTIFYICONDATAW>(),
        hWnd = _hwnd,
        uID = IconId,
        uFlags = Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP,
        uCallbackMessage = CallbackMessage,
        hIcon = _icon,
        szTip = _tip,
        szInfo = "",
        szInfoTitle = "",
    };

    private void Apply()
    {
        var d = Data();
        if (_added && Native.Shell_NotifyIconW(Native.NIM_MODIFY, ref d)) return;
        // Not added yet, or the shell forgot it (Explorer restarted between two
        // updates): add it, then opt in to the version-4 message set.
        if (Native.Shell_NotifyIconW(Native.NIM_ADD, ref d))
        {
            _added = true;
            d.uVersion = Native.NOTIFYICON_VERSION_4;
            Native.Shell_NotifyIconW(Native.NIM_SETVERSION, ref d);
            return;
        }
        // ADD fails when the icon is still there: a MODIFY that merely timed out
        // (Explorer busy) lands here. Without this second MODIFY the icon would
        // be retried with ADD forever and never change again.
        _added = Native.Shell_NotifyIconW(Native.NIM_MODIFY, ref d);
    }

    private static IntPtr WindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        var self = s_instance;
        if (self != null && hWnd == self._hwnd)
        {
            if (msg == CallbackMessage)
            {
                int ev = Native.LoWord(lParam);
                // The shell can send NIN_KEYSELECT twice for one Enter; the second
                // would close what the first just opened.
                if (ev == Native.NIN_KEYSELECT && (DateTime.Now - self._lastKeySelect).TotalMilliseconds < 250)
                    return IntPtr.Zero;
                if (ev == Native.NIN_KEYSELECT) self._lastKeySelect = DateTime.Now;
                if (ev is Native.NIN_SELECT or Native.NIN_KEYSELECT or Native.WM_CONTEXTMENU)
                    self.Invoked?.Invoke(new Native.POINT { X = Native.LoWord(wParam), Y = Native.HiWord(wParam) });
                return IntPtr.Zero;
            }
            if (msg == self._taskbarCreated)
            {
                self._added = false;
                self.Apply();
                self.AppearanceChanged?.Invoke();
                return IntPtr.Zero;
            }
            switch (msg)
            {
                case Native.WM_SETTINGCHANGE:
                case Native.WM_DISPLAYCHANGE:
                case Native.WM_DPICHANGED:
                    self.AppearanceChanged?.Invoke();
                    break;
                case Native.WM_POWERBROADCAST when (long)wParam == Native.PBT_APMRESUMEAUTOMATIC:
                    self.Resumed?.Invoke();
                    break;
            }
        }
        return Native.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        if (_added)
        {
            var d = Data();
            Native.Shell_NotifyIconW(Native.NIM_DELETE, ref d);
            _added = false;
        }
        if (_icon != IntPtr.Zero) { Native.DestroyIcon(_icon); _icon = IntPtr.Zero; }
        Native.DestroyWindow(_hwnd);
    }
}
