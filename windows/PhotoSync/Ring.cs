// The ring, drawn from pixels -- the Windows twin of ring() in Sources/main.swift.
//
// A tray icon is 16 px at 100% scaling and 24-32 px at the common laptop
// scalings, so it is rendered at exactly the size the shell asks for (no
// bitmap stretched after the fact), with 4x4 supersampling for the edges. Same
// geometry as the macOS ring: a track, an arc from twelve o'clock clockwise by
// the fraction (or a short spinning arc for a step with no count), and a check
// or an exclamation inside.
//
// COLOUR, as on the Mac: saturated hues are blended about a third of the way to
// mid-grey, because a meter is furniture, not an alert box; the MARK carries
// the alarm and colour only names it. The track is the neutral the taskbar's
// own glyphs use -- white or black at low opacity, by the taskbar's theme.
using System.Runtime.InteropServices;

namespace PhotoSync;

internal enum Tint { Dim, Red, Orange, Yellow, Green, Blue, Purple }
internal enum Mark { None, Check, Exclaim }

/// <param name="Fraction">0..1 of the ring filled, clockwise from twelve o'clock.</param>
/// <param name="Spin">When set, a 100-degree arc starting this many degrees clockwise of twelve.</param>
internal readonly record struct RingSpec(double Fraction, Tint Tint, Mark Mark = Mark.None, double? Spin = null);

internal static class Ring
{
    private static (double R, double G, double B) Base(Tint t) => t switch
    {
        Tint.Red => (255, 59, 48),
        Tint.Orange => (255, 149, 0),
        Tint.Yellow => (255, 204, 0),
        Tint.Green => (52, 199, 89),
        Tint.Blue => (0, 122, 255),
        Tint.Purple => (175, 82, 222),
        _ => (148, 148, 148),
    };

    // muted() in main.swift: 38% of the way toward a 0.58 grey.
    private static (double R, double G, double B, double A) Color(Tint t, bool dark)
    {
        if (t == Tint.Dim) return Neutral(dark);
        var (r, g, b) = Base(t);
        const double f = 0.38, grey = 0.58 * 255;
        return (r + (grey - r) * f, g + (grey - g) * f, b + (grey - b) * f, 1.0);
    }

    // tertiaryLabelColor's role: visible on the bar, never louder than a glyph.
    private static (double R, double G, double B, double A) Neutral(bool dark) =>
        dark ? (255, 255, 255, 0.36) : (0, 0, 0, 0.32);

    /// <summary>Straight-alpha BGRA pixels, <paramref name="n"/> x <paramref name="n"/>, top row first.</summary>
    public static byte[] Render(RingSpec spec, int n, bool darkBackground)
    {
        double c = n / 2.0;
        double lw = Math.Max(1.5, n * 0.125);          // stroke: 2 px at 16 px
        double r = n * 0.46 - lw / 2;                  // centre-line radius
        double mw = Math.Max(1.3, r * 0.26);           // the mark's stroke
        var track = Neutral(darkBackground);
        var tint = Color(spec.Tint, darkBackground);

        // The arc, in clock degrees: start and sweep.
        double start = 0, sweep = 0;
        if (spec.Spin is double s) { start = Norm(s); sweep = 100; }
        else if (spec.Fraction > 0) sweep = 360 * Math.Min(1, spec.Fraction);
        var capA = OnCircle(c, r, start);
        var capB = OnCircle(c, r, start + sweep);

        // The marks, in units of r around the centre, y DOWN (main.swift's
        // points with y flipped).
        (double, double)[] check = { (-0.42, -0.02), (-0.10, 0.32), (0.48, -0.36) };

        var px = new byte[n * n * 4];
        const int ss = 4;
        for (int y = 0; y < n; y++)
        for (int x = 0; x < n; x++)
        {
            double ar = 0, ag = 0, ab = 0, aa = 0;       // premultiplied accumulator
            for (int sy = 0; sy < ss; sy++)
            for (int sx = 0; sx < ss; sx++)
            {
                double qx = x + (sx + 0.5) / ss, qy = y + (sy + 0.5) / ss;
                double dx = qx - c, dy = qy - c;
                double dist = Math.Sqrt(dx * dx + dy * dy);
                (double R, double G, double B, double A)? col = null;

                if (Math.Abs(dist - r) <= lw / 2) col = track;
                if (sweep > 0)
                {
                    bool on = false;
                    if (Math.Abs(dist - r) <= lw / 2)
                    {
                        if (sweep >= 360) on = true;
                        else
                        {
                            double theta = Norm(Math.Atan2(dx, -dy) * 180 / Math.PI);
                            on = Norm(theta - start) <= sweep;
                        }
                    }
                    // round caps
                    if (!on && sweep < 360)
                        on = Hyp(qx - capA.X, qy - capA.Y) <= lw / 2 || Hyp(qx - capB.X, qy - capB.Y) <= lw / 2;
                    if (on) col = tint;
                }
                if (spec.Mark == Mark.Check)
                {
                    for (int i = 0; i < check.Length - 1 && col != tint; i++)
                        if (SegDist(qx, qy, c + check[i].Item1 * r, c + check[i].Item2 * r,
                                    c + check[i + 1].Item1 * r, c + check[i + 1].Item2 * r) <= mw / 2) col = tint;
                }
                else if (spec.Mark == Mark.Exclaim)
                {
                    if (SegDist(qx, qy, c, c - 0.5 * r, c, c + 0.1 * r) <= mw / 2) col = tint;
                    if (Hyp(qx - c, qy - (c + 0.55 * r)) <= 0.14 * r + mw * 0.25) col = tint;
                }
                if (col is { } k)
                {
                    ar += k.R * k.A; ag += k.G * k.A; ab += k.B * k.A; aa += k.A;
                }
            }
            double samples = ss * ss;
            double a = aa / samples;
            int o = (y * n + x) * 4;
            if (aa > 0)
            {
                px[o + 0] = (byte)Math.Round(ab / aa);   // B
                px[o + 1] = (byte)Math.Round(ag / aa);   // G
                px[o + 2] = (byte)Math.Round(ar / aa);   // R
                px[o + 3] = (byte)Math.Round(a * 255);   // A
            }
        }
        return px;
    }

    /// <summary>The same pixels premultiplied, which is what a WinUI WriteableBitmap holds.</summary>
    public static byte[] Premultiply(byte[] straight)
    {
        var p = new byte[straight.Length];
        for (int i = 0; i < straight.Length; i += 4)
        {
            int a = straight[i + 3];
            p[i] = (byte)(straight[i] * a / 255);
            p[i + 1] = (byte)(straight[i + 1] * a / 255);
            p[i + 2] = (byte)(straight[i + 2] * a / 255);
            p[i + 3] = (byte)a;
        }
        return p;
    }

    /// <summary>An HICON from straight-alpha BGRA pixels. The caller owns it (DestroyIcon).</summary>
    public static IntPtr ToIcon(byte[] bgra, int n)
    {
        var header = new Native.BITMAPV5HEADER
        {
            bV5Size = Marshal.SizeOf<Native.BITMAPV5HEADER>(),
            bV5Width = n,
            bV5Height = -n,                     // top-down
            bV5Planes = 1,
            bV5BitCount = 32,
            bV5Compression = 3,                 // BI_BITFIELDS
            bV5RedMask = 0x00FF0000,
            bV5GreenMask = 0x0000FF00,
            bV5BlueMask = 0x000000FF,
            bV5AlphaMask = 0xFF000000,
        };
        var hdc = Native.GetDC(IntPtr.Zero);
        var color = Native.CreateDIBSection(hdc, ref header, 0, out var bits, IntPtr.Zero, 0);
        Native.ReleaseDC(IntPtr.Zero, hdc);
        if (color == IntPtr.Zero) return IntPtr.Zero;
        Marshal.Copy(bgra, 0, bits, bgra.Length);
        // With a 32-bit colour bitmap the alpha channel decides; the mask only
        // has to exist.
        var mask = Native.CreateBitmap(n, n, 1, 1, new byte[((n + 15) / 16) * 2 * n]);
        var info = new Native.ICONINFO { fIcon = true, hbmMask = mask, hbmColor = color };
        var icon = Native.CreateIconIndirect(ref info);
        Native.DeleteObject(color);
        Native.DeleteObject(mask);
        return icon;
    }

    private static double Norm(double deg) => ((deg % 360) + 360) % 360;
    private static double Hyp(double x, double y) => Math.Sqrt(x * x + y * y);

    private static (double X, double Y) OnCircle(double c, double r, double clockDeg)
    {
        double a = clockDeg * Math.PI / 180;
        return (c + r * Math.Sin(a), c - r * Math.Cos(a));
    }

    private static double SegDist(double px, double py, double ax, double ay, double bx, double by)
    {
        double vx = bx - ax, vy = by - ay;
        double t = ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy);
        t = Math.Clamp(t, 0, 1);
        return Hyp(px - (ax + t * vx), py - (ay + t * vy));
    }
}
