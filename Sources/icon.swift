// Draws Photo Sync's app icon FROM CODE, at build time. No binary asset is
// checked in: build.sh compiles this file, runs it, and feeds what it writes to
// actool/iconutil. A .png in the repo would be a blob nobody can diff and that
// nothing regenerates; a hundred lines of drawing code is reviewable and edits
// like source, which is the whole reason this app has no Xcode project either.
//
// Usage: icon <output-dir>
// Writes, into <output-dir>:
//   AppIcon.icon/      an Icon Composer package (icon.json + Assets/) -- the
//                      ONLY format that carries light/dark appearance variants,
//                      compiled to Assets.car by actool
//   AppIcon.iconset/   the ten legacy tiles, for `iconutil -c icns` when actool
//                      is absent (it ships with Xcode, not with the Command Line
//                      Tools, which is all a fresh Mac has during bootstrap)
//
// The glyph is the app's own subject: the progress ring it draws in the menu
// bar, part-way round, its arc split into the three stages of the pipeline in
// the SAME muted yellow (the device), blue (Google Photos confirming) and purple
// (iCloud being reclaimed). A single thick stroke was chosen over concentric
// rings because at 16 pt -- the size Finder's list view actually uses --
// concentric 1 px rings turn to mush.

import AppKit

// MARK: - Palette

// The three stage colours: `muted(.systemYellow/.systemBlue/.systemPurple)` from
// main.swift, evaluated in sRGB (that blend is c * 0.62 + 0.2204 per channel).
// They are literals rather than a live call because a headless render has no
// window and so no appearance to resolve a dynamic system colour against -- the
// values would depend on whatever appearance the build happened to inherit.
let stages: [NSColor] = [
    NSColor(srgbRed: 0.8404, green: 0.7164, blue: 0.2204, alpha: 1),   // muted systemYellow: on the device
    NSColor(srgbRed: 0.2204, green: 0.5168, blue: 0.8404, alpha: 1),   // muted systemBlue: confirming in the cloud
    NSColor(srgbRed: 0.6457, green: 0.4200, blue: 0.7604, alpha: 1),   // muted systemPurple: reclaiming iCloud
]

struct Appearance {
    let name: String
    let tileTop: NSColor
    let tileBottom: NSColor
    let track: NSColor
    let lift: CGFloat        // how far the arcs are blended toward white
}

// Slate in light, graphite in dark. The dark tile goes darker and the arcs get
// lifted toward white, which is what the appearance variant is FOR: the same
// artwork at the same contrast against two different desktops.
let light = Appearance(
    name: "light",
    tileTop: NSColor(srgbRed: 0.32, green: 0.36, blue: 0.47, alpha: 1),
    tileBottom: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.28, alpha: 1),
    track: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20),
    lift: 0)
let dark = Appearance(
    name: "dark",
    tileTop: NSColor(srgbRed: 0.15, green: 0.16, blue: 0.20, alpha: 1),
    tileBottom: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.10, alpha: 1),
    track: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
    lift: 0.22)

func lifted(_ c: NSColor, _ f: CGFloat) -> NSColor {
    f <= 0 ? c : (c.blended(withFraction: f, of: .white) ?? c)
}

// MARK: - Drawing primitives

// Apple's icon corner is a continuous curve, not a circular arc, and AppKit has
// no public API for one. A superellipse |x|^n + |y|^n = 1 at n = 5 tracks it
// closely enough that the difference is invisible below 512 pt, and it costs a
// loop instead of a dependency.
func squircle(in r: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let p = NSBezierPath()
    let a = r.width / 2, b = r.height / 2
    let cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) }
    }
    p.close()
    return p
}

func render(_ px: Int, _ body: (CGFloat) -> Void) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("cannot allocate a \(px)x\(px) bitmap") }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.shouldAntialias = true
    body(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode a \(px)x\(px) PNG")
    }
    return png
}

// MARK: - The glyph

// One stroked arc segment, in degrees, drawn clockwise from `from`.
func arc(_ c: NSPoint, _ r: CGFloat, _ from: CGFloat, _ sweep: CGFloat,
         _ w: CGFloat, _ color: NSColor) {
    let p = NSBezierPath()
    p.appendArc(withCenter: c, radius: r, startAngle: from, endAngle: from - sweep, clockwise: true)
    p.lineWidth = w
    p.lineCapStyle = .round
    color.setStroke()
    p.stroke()
}

// The ring, drawn into an `s` x `s` canvas. Every measurement is a fraction of
// the canvas so the same code renders the 1024 pt layer and a 16 pt tile.
func drawGlyph(_ s: CGFloat, _ ap: Appearance) {
    let c = NSPoint(x: s / 2, y: s / 2)
    let r = s * 0.312
    let w = s * 0.116

    // The full track, then three consecutive stage segments clockwise from the
    // top, leaving the last stretch open: a ring part-way round, which is what
    // this app looks like nearly all the time. The fractions are illustrative,
    // not live data -- an app icon is a portrait of the app, not a readout.
    let p = NSBezierPath()
    p.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    p.lineWidth = w
    ap.track.setStroke()
    p.stroke()

    let sweeps: [CGFloat] = [120, 84, 48]
    let gap: CGFloat = 7
    var angle: CGFloat = 90
    for (i, sweep) in sweeps.enumerated() {
        arc(c, r, angle, sweep, w, lifted(stages[i], ap.lift))
        angle -= sweep + gap
    }
}

func drawTile(_ s: CGFloat, _ ap: Appearance) {
    let inset = s * 0.008
    let path = squircle(in: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset))
    let g = NSGradient(starting: ap.tileTop, ending: ap.tileBottom)
    g?.draw(in: path, angle: -90)
    drawGlyph(s, ap)
}

// MARK: - Output

let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : { FileHandle.standardError.write(Data("usage: icon <output-dir>\n".utf8)); exit(2) }()

let fm = FileManager.default
let iconPkg = out.appendingPathComponent("AppIcon.icon")
let assets = iconPkg.appendingPathComponent("Assets")
let iconset = out.appendingPathComponent("AppIcon.iconset")
for d in [assets, iconset] {
    try? fm.removeItem(at: d)
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
}

// The Icon Composer layers: the tile is the package's `fill`, so the layer PNG
// carries only the glyph on transparency and the system masks, shadows and
// glazes it. One PNG per appearance, swapped by `image-name-specializations`.
for ap in [light, dark] {
    let png = render(1024) { s in drawGlyph(s, ap) }
    try! png.write(to: assets.appendingPathComponent("glyph-\(ap.name).png"))
}

func fill(_ ap: Appearance) -> String {
    func c(_ x: NSColor) -> String {
        let s = x.usingColorSpace(.sRGB)!
        return String(format: "srgb:%.5f,%.5f,%.5f,%.5f",
                      s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }
    return "{ \"linear-gradient\" : [ \"\(c(ap.tileTop))\", \"\(c(ap.tileBottom))\" ] }"
}

// Hand-written rather than JSONSerialization so the file reads like the ones
// Icon Composer saves. Two schema notes, both learned by compiling and reading
// the result back with assetutil:
//   - a `*-specializations` array must carry the BASE value as an entry with no
//     `appearance` key. A top-level `fill` plus a dark-only specialization
//     compiles without a word of complaint and silently drops the dark colour.
//   - `shadow`/`translucency` are pinned here rather than left to actool's
//     defaults, so the look cannot drift with the toolchain.
let json = """
{
  "fill-specializations" : [
    { "value" : \(fill(light)) },
    { "appearance" : "dark", "value" : \(fill(dark)) }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "name" : "Ring",
          "image-name-specializations" : [
            { "value" : "glyph-light.png" },
            { "appearance" : "dark", "value" : "glyph-dark.png" }
          ]
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}

"""
try! Data(json.utf8).write(to: iconPkg.appendingPathComponent("icon.json"))

// The legacy set. Each tile is drawn at its own pixel size rather than
// downsampled from 1024, so the 16 pt one keeps its stroke instead of blurring.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(px) { s in drawTile(s, light) }
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
