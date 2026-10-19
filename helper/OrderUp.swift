// OrderUp: the tiny chef that tells you a Claude Code session finished (or needs
// you) somewhere you are not looking. The order-up mod writes one JSON order per
// session to ~/.claude/order-up/queue/ and a heartbeat per session to
// ~/.claude/order-up/sessions/; this app lists the orders in one bubble, jumps to
// the session on a click, drops an order once you are looking at its session, and
// keeps a kitchen in the menu bar while sessions run.

import AppKit

// ORDER_UP_HOME points a second copy elsewhere (screenshots with made-up sessions).
let home = ProcessInfo.processInfo.environment["ORDER_UP_HOME"].map { URL(fileURLWithPath: $0) }
  ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/order-up")
let queueDir = home.appendingPathComponent("queue")
let sessionsDir = home.appendingPathComponent("sessions")
let settingsFile = home.appendingPathComponent("settings.json")
let logFile = home.appendingPathComponent("order-up.log")
let claudeOrange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
// A session that has not written its heartbeat for this long is gone.
let staleAfter: TimeInterval = 180

struct Entry: Codable, Equatable {
  var tty: String? = nil
  var bundleId: String? = nil
  var app: String? = nil
  let title: String
  let color: String?
  var dish: String? = nil
  let summary: String?
  // The turn's bill: time, cost, files, commands.
  var bill: String? = nil
  // "done", "burnt" (the turn failed) or "needs" (waits on you).
  var kind: String? = nil
  let at: Double
  // A test order shows even when its session is the one in front.
  var isTest: Bool? = nil
  // A question's choices (a "needs" order): buttons that answer it from here.
  var options: [String]? = nil
  // Where the answer goes: ~/.claude/order-up/answers/<answerId>.json.
  var answerId: String? = nil
  // Put away until then (seconds since 1970); it comes back with a hop.
  var snoozeUntil: Double? = nil
  var file: String? = nil
}

struct Session: Codable {
  let key: String
  var tty: String? = nil
  var bundleId: String? = nil
  let title: String
  let color: String?
  var dish: String? = nil
  let state: String
  let since: Double
  var activity: String? = nil
  let updatedAt: Double
}

struct Settings: Codable {
  var corner: String? = nil
  var sound: Bool? = nil
  var menubar: Bool? = nil
  // Keep the menu bar chef even when no Claude session runs (it also starts at login).
  var stayOpen: Bool? = nil
}

func loadSettings() -> Settings {
  guard let data = try? Data(contentsOf: settingsFile), let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
  return s
}

// Why each order came and went, so an early exit can be explained afterwards.
func log(_ text: String) {
  let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
  guard let data = line.data(using: .utf8) else { return }
  if let h = try? FileHandle(forWritingTo: logFile) {
    h.seekToEndOfFile(); h.write(data); try? h.close()
  } else {
    try? data.write(to: logFile)
  }
}

func color(hex: String?) -> NSColor {
  guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return claudeOrange }
  return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

func runScript(_ source: String) -> String? {
  var error: NSDictionary?
  let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
  return error == nil ? out?.stringValue : nil
}

let TERMINAL = "com.apple.Terminal"
let ITERM = "com.googlecode.iterm2"

// Brings a session forward: the exact tab in Terminal.app and iTerm2, else its app.
func jump(tty: String?, bundleId: String?) {
  let safe = (tty ?? "").filter { $0.isLetter || $0.isNumber || $0 == "/" }
  if bundleId == TERMINAL, !safe.isEmpty {
    _ = runScript("""
      tell application "Terminal"
        repeat with w in windows
          try
            repeat with t in tabs of w
              if tty of t is "\(safe)" then
                set miniaturized of w to false
                set selected of t to true
                set index of w to 1
              end if
            end repeat
          end try
        end repeat
        activate
      end tell
      """)
  } else if bundleId == ITERM, !safe.isEmpty {
    _ = runScript("""
      tell application "iTerm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if tty of s is "\(safe)" then
                select w
                select t
                select s
              end if
            end repeat
          end repeat
        end repeat
        activate
      end tell
      """)
  } else if let bundleId, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
    app.activate()
  }
}

// What you are looking at: the front app, and its tab's tty where the app tells.
struct Front { let bundleId: String?; let tty: String? }

func front() -> Front {
  let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
  var tty: String?
  if id == TERMINAL { tty = runScript(#"tell application "Terminal" to get tty of selected tab of front window"#) }
  if id == ITERM { tty = runScript(#"tell application "iTerm2" to get tty of current session of current window"#) }
  return Front(bundleId: id, tty: tty)
}

// Whether a session is the one in front: its app, and its tab where tabs are known.
func isInView(tty: String?, bundleId: String?, _ f: Front) -> Bool {
  guard let bundleId, bundleId == f.bundleId else { return false }
  if bundleId == TERMINAL || bundleId == ITERM { return tty != nil && tty == f.tty }
  return true
}

// The menu bar icon: a tiny chef, toque over an orange face, mustache.
func chefIcon() -> NSImage {
  let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
    NSColor.white.setFill()
    for (x, y, r) in [(6.0, 13.5, 3.2), (12.0, 13.5, 3.2), (9.0, 15.2, 3.6)] as [(CGFloat, CGFloat, CGFloat)] {
      NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
    }
    NSBezierPath(roundedRect: NSRect(x: 4.5, y: 9.5, width: 9, height: 3.5), xRadius: 1, yRadius: 1).fill()
    claudeOrange.setFill()
    NSBezierPath(ovalIn: NSRect(x: 4, y: 1, width: 10, height: 9.5)).fill()
    NSColor(white: 0.12, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 6.3, y: 6, width: 1.6, height: 1.8)).fill()
    NSBezierPath(ovalIn: NSRect(x: 10.1, y: 6, width: 1.6, height: 1.8)).fill()
    let stache = NSBezierPath()
    stache.move(to: NSPoint(x: 9, y: 4.6))
    stache.curve(to: NSPoint(x: 5.6, y: 4.8), controlPoint1: NSPoint(x: 8, y: 3.2), controlPoint2: NSPoint(x: 6.4, y: 3.4))
    stache.move(to: NSPoint(x: 9, y: 4.6))
    stache.curve(to: NSPoint(x: 12.4, y: 4.8), controlPoint1: NSPoint(x: 10, y: 3.2), controlPoint2: NSPoint(x: 11.6, y: 3.4))
    NSColor(white: 0.12, alpha: 1).setStroke()
    stache.lineWidth = 1.3
    stache.lineCapStyle = .round
    stache.stroke()
    return true
  }
  img.isTemplate = false
  return img
}

let DISHES = ["🍜", "🍕", "🍣", "🥗", "🍰", "🌮", "🥘", "🍔", "🥞", "🍝", "🍤", "🧁"]

func dish(for e: Entry) -> String {
  if let d = e.dish, !d.isEmpty { return d }
  let root = e.title.components(separatedBy: " · ")[0]
  let h = root.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
  return DISHES[Int(h % UInt32(DISHES.count))]
}

// The chef: Claude's orange face under a tall toque, a curly mustache, a silver
// cloche held out on a plate. It hops in and pops the lid on arrival, lifts it
// while hovered, and rattles it, more and more, the longer an order waits.
final class Chef: NSView {
  var phase: CGFloat = 0
  var hopUntil = Date.distantPast
  var popUntil = Date.distantPast
  var oldest: Date?
  var dish = "🍜"
  // The newest order failed: smoke instead of steam, a frown, a flame by the plate.
  var isBurnt = false
  var onClick: (() -> Void)?
  private var lid: CGFloat = 0
  private var hovering = false
  private var rattle: CGFloat = 0
  private var blink = false
  // Nothing cooking and nothing waiting: the chef dozes (eyes shut, z's drifting up).
  var isSleepy = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  required init?(coder: NSCoder) { nil }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
  override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }

  func step() {
    phase += 0.18
    blink = Int(phase * 10) % 53 == 0
    let target: CGFloat = hovering || Date() < popUntil ? 1 : 0
    lid += (target - lid) * 0.18
    // Impatience: a rattle now and then after a minute, often and with hops after five.
    rattle = 0
    if let oldest, lid < 0.3 {
      let wait = Date().timeIntervalSince(oldest)
      let every: Double = wait > 300 ? 3 : 6
      if wait > 60, Date().timeIntervalSince1970.truncatingRemainder(dividingBy: every) < 0.6 {
        rattle = sin(phase * 9) * 0.12
        if wait > 300 && Date() >= hopUntil { hopUntil = Date().addingTimeInterval(0.6) }
      }
    }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let hopping = Date() < hopUntil
    let lift = hopping ? abs(sin(phase * 1.6)) * 16 : (sin(phase * 0.5) + 1) * 2
    let ink = NSColor(srgbRed: 0.29, green: 0.17, blue: 0.1, alpha: 1)
    let line = NSColor(white: 0.78, alpha: 1)

    NSColor.black.withAlphaComponent(0.2).setFill()
    let shadowW = 70 * (1 - lift / 60)
    NSBezierPath(ovalIn: NSRect(x: 52 - shadowW / 2, y: 2, width: shadowW, height: 7)).fill()

    NSGraphicsContext.current?.saveGraphicsState()
    let hop = NSAffineTransform(); hop.translateX(by: 0, yBy: lift); hop.concat()

    // legs and jacket
    ink.setFill()
    for x: CGFloat in [40, 56] { NSBezierPath(roundedRect: NSRect(x: x, y: 6, width: 10, height: 12), xRadius: 4, yRadius: 4).fill() }
    let jacket = NSBezierPath(roundedRect: NSRect(x: 28, y: 14, width: 50, height: 44), xRadius: 18, yRadius: 18)
    NSColor.white.setFill(); jacket.fill()
    line.setStroke(); jacket.lineWidth = 1.5; jacket.stroke()
    NSColor(white: 0.6, alpha: 1).setFill()
    for y: CGFloat in [26, 38] { NSBezierPath(ovalIn: NSRect(x: 50, y: y, width: 5, height: 5)).fill() }
    // neckerchief
    claudeOrange.blended(withFraction: 0.35, of: .red)?.setFill()
    let scarf = NSBezierPath()
    scarf.move(to: NSPoint(x: 42, y: 56)); scarf.line(to: NSPoint(x: 64, y: 56)); scarf.line(to: NSPoint(x: 53, y: 46)); scarf.close()
    scarf.fill()

    // head
    claudeOrange.setFill()
    NSBezierPath(ovalIn: NSRect(x: 33, y: 52, width: 40, height: 38)).fill()
    NSColor(srgbRed: 1, green: 0.55, blue: 0.55, alpha: 0.55).setFill()
    for x: CGFloat in [36, 61] { NSBezierPath(ovalIn: NSRect(x: x, y: 63, width: 9, height: 6)).fill() }
    for x: CGFloat in [45, 61] {
      NSColor.white.setFill()
      let shut = blink || isSleepy
      let eye = NSRect(x: x - 5, y: shut ? 74 : 70, width: 10, height: shut ? 2 : 11)
      NSBezierPath(ovalIn: eye).fill()
      if !shut {
        ink.setFill()
        let look: CGFloat = hovering ? 2 : sin(phase * 0.35) * 1.5
        NSBezierPath(ovalIn: NSRect(x: eye.midX - 3 + look, y: eye.midY - 3, width: 6, height: 7)).fill()
      }
    }
    // the mustache, curling up, wiggling now and then
    let wiggle = sin(phase * 0.9) > 0.92 ? sin(phase * 6) * 2 : 0
    let stache = NSBezierPath()
    for side: CGFloat in [-1, 1] {
      stache.move(to: NSPoint(x: 53, y: 64))
      stache.curve(to: NSPoint(x: 53 + side * 15, y: 66 + wiggle),
                   controlPoint1: NSPoint(x: 53 + side * 5, y: 58),
                   controlPoint2: NSPoint(x: 53 + side * 13, y: 58))
      stache.curve(to: NSPoint(x: 53 + side * 10, y: 66 + wiggle),
                   controlPoint1: NSPoint(x: 53 + side * 17, y: 70 + wiggle),
                   controlPoint2: NSPoint(x: 53 + side * 12, y: 70 + wiggle))
    }
    ink.setStroke(); stache.lineWidth = 3.5; stache.lineCapStyle = .round; stache.stroke()
    let smile = NSBezierPath()
    let mouthY: CGFloat = isBurnt ? 54 : 58, bend: CGFloat = isBurnt ? 4 : -4
    smile.move(to: NSPoint(x: 48, y: mouthY)); smile.curve(to: NSPoint(x: 58, y: mouthY), controlPoint1: NSPoint(x: 50, y: mouthY + bend), controlPoint2: NSPoint(x: 56, y: mouthY + bend))
    smile.lineWidth = 1.8; smile.stroke()

    // the toque
    NSColor.white.setFill(); line.setStroke()
    for (x, y, r) in [(41.0, 100.0, 10.0), (65.0, 100.0, 10.0), (53.0, 106.0, 13.0)] as [(CGFloat, CGFloat, CGFloat)] {
      let puff = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
      puff.fill(); puff.lineWidth = 1.2; puff.stroke()
    }
    let band = NSBezierPath(roundedRect: NSRect(x: 36, y: 84, width: 34, height: 14), xRadius: 3, yRadius: 3)
    band.fill(); band.lineWidth = 1.2; band.stroke()

    // arm out to the plate
    let arm = NSBezierPath()
    arm.move(to: NSPoint(x: 74, y: 36)); arm.curve(to: NSPoint(x: 96, y: 48), controlPoint1: NSPoint(x: 86, y: 34), controlPoint2: NSPoint(x: 92, y: 40))
    NSColor.white.setStroke(); arm.lineWidth = 9; arm.lineCapStyle = .round; arm.stroke()
    claudeOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 92, y: 45, width: 9, height: 9)).fill()

    // plate, dish, steam
    let plate = NSRect(x: 82, y: 50, width: 48, height: 9)
    NSColor(white: 0.93, alpha: 1).setFill(); NSBezierPath(ovalIn: plate).fill()
    line.setStroke(); NSBezierPath(ovalIn: plate).stroke()
    if lid > 0.05 {
      NSAttributedString(string: dish, attributes: [.font: NSFont.systemFont(ofSize: 24)]).draw(at: NSPoint(x: 92, y: 53))
      for i in 0..<3 {
        let x = 96 + CGFloat(i) * 9
        let steam = NSBezierPath()
        steam.move(to: NSPoint(x: x, y: 82))
        for k in 1...4 {
          let y = 82 + CGFloat(k) * 6
          steam.line(to: NSPoint(x: x + sin(phase * 0.8 + CGFloat(k) + CGFloat(i)) * 3, y: y))
        }
        (isBurnt ? NSColor(white: 0.35, alpha: 0.85 * lid) : NSColor.white.withAlphaComponent(0.7 * lid)).setStroke()
        steam.lineWidth = isBurnt ? 3.5 : 2; steam.lineCapStyle = .round; steam.stroke()
      }
      if isBurnt { NSAttributedString(string: "🔥", attributes: [.font: NSFont.systemFont(ofSize: 13)]).draw(at: NSPoint(x: 116, y: 52)) }
    }
    // the cloche, hinged at the plate's right edge
    NSGraphicsContext.current?.saveGraphicsState()
    let pivot = NSPoint(x: 128, y: 55)
    let t = NSAffineTransform()
    t.translateX(by: pivot.x, yBy: pivot.y + lid * 6)
    t.rotate(byRadians: -lid * 0.75 + rattle)
    t.translateX(by: -pivot.x, yBy: -pivot.y)
    t.concat()
    let dome = NSBezierPath()
    dome.move(to: NSPoint(x: 84, y: 55))
    dome.curve(to: NSPoint(x: 128, y: 55), controlPoint1: NSPoint(x: 84, y: 86), controlPoint2: NSPoint(x: 128, y: 86))
    dome.close()
    NSGradient(starting: NSColor(white: 0.97, alpha: 1), ending: NSColor(white: 0.62, alpha: 1))?.draw(in: dome, angle: -60)
    NSColor(white: 0.5, alpha: 1).setStroke(); dome.lineWidth = 1.2; dome.stroke()
    NSColor.white.withAlphaComponent(0.8).setStroke()
    let shine = NSBezierPath(); shine.move(to: NSPoint(x: 92, y: 64)); shine.curve(to: NSPoint(x: 100, y: 76), controlPoint1: NSPoint(x: 92, y: 70), controlPoint2: NSPoint(x: 95, y: 74))
    shine.lineWidth = 2.5; shine.lineCapStyle = .round; shine.stroke()
    NSColor(white: 0.55, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 102, y: 77, width: 8, height: 7)).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.restoreGraphicsState()
    if isSleepy {
      for k in 0..<3 {
        let t = (phase * 0.25 + CGFloat(k) * 0.33).truncatingRemainder(dividingBy: 1)
        NSAttributedString(string: "z", attributes: [
          .font: NSFont.systemFont(ofSize: 9 + CGFloat(k) * 3, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.8 * (1 - t)),
        ]).draw(at: NSPoint(x: 72 + t * 18 + CGFloat(k) * 4, y: 92 + t * 26))
      }
    }
  }
}

let SNOOZE_SECONDS: Double = 600

// A small pill button inside an order: an answer, or the snooze.
final class TinyButton: NSView {
  let text: NSAttributedString
  let action: () -> Void
  let isQuiet: Bool
  // Wide: a full-width answer whose words wrap onto up to two lines, left aligned.
  let isWide: Bool
  private var hovering = false

  static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
  static let pillMax: CGFloat = 150

  // The height a wide button needs for `label` at `width`: one line, or two.
  static func wideHeight(_ label: String, width: CGFloat) -> CGFloat {
    let r = NSAttributedString(string: label, attributes: [.font: font]).boundingRect(
      with: NSSize(width: width - 20, height: 400), options: [.usesLineFragmentOrigin])
    return min(ceil(r.height), 30) + 9
  }

  init(_ label: String, quiet: Bool = false, wide: CGFloat? = nil, tip: String? = nil, action: @escaping () -> Void) {
    text = NSAttributedString(string: label, attributes: [
      .font: TinyButton.font, .foregroundColor: NSColor.white.withAlphaComponent(quiet ? 0.6 : 0.92),
    ])
    self.action = action
    isQuiet = quiet
    isWide = wide != nil
    let size = wide.map { NSSize(width: $0, height: TinyButton.wideHeight(label, width: $0)) }
      ?? NSSize(width: min(text.size().width + 18, TinyButton.pillMax), height: 22)
    super.init(frame: NSRect(origin: .zero, size: size))
    toolTip = tip
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  required init?(coder: NSCoder) { nil }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { action() }
  override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; NSCursor.pointingHand.set() }
  override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; NSCursor.arrow.set() }

  override func draw(_ dirtyRect: NSRect) {
    let radius: CGFloat = isWide ? 8 : 11
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    (isQuiet ? NSColor.white.withAlphaComponent(hovering ? 0.16 : 0.0) : claudeOrange.withAlphaComponent(hovering ? 0.55 : 0.3)).setFill()
    shape.fill()
    if !isQuiet {
      claudeOrange.withAlphaComponent(0.8).setStroke()
      shape.lineWidth = 1
      shape.stroke()
    }
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = isWide ? .byWordWrapping : .byTruncatingTail
    para.alignment = isWide ? .left : .center
    let m = NSMutableAttributedString(attributedString: text)
    m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
    if isWide {
      m.draw(with: NSRect(x: 10, y: 4, width: bounds.width - 20, height: bounds.height - 8),
             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    } else {
      m.draw(in: NSRect(x: 6, y: 3, width: bounds.width - 12, height: 16))
    }
  }
}

// One finished session: the place in its tint, what got done under it.
final class Row: NSView {
  let entry: Entry
  var onClick: ((Entry) -> Void)?
  private var hovering = false

  var onAnswer: ((Entry, String) -> Void)?
  var onSnooze: ((Entry) -> Void)?

  static func answers(_ e: Entry) -> [String] {
    e.kind == "needs" && e.answerId != nil ? Array((e.options ?? []).prefix(4)) : []
  }

  // The answer buttons, placed from the bottom of the row up: short answers as pills
  // that wrap in lines; an answer too long for a pill gets a full-width button of
  // its own, its words on up to two lines, and the short ones follow as pills.
  static func answerLayout(_ e: Entry, width: CGFloat = 308) -> (items: [(String, NSRect, Bool)], height: CGFloat) {
    let labels = answers(e)
    guard !labels.isEmpty else { return ([], 0) }
    let fits = { (l: String) in NSAttributedString(string: l, attributes: [.font: TinyButton.font]).size().width + 18 <= TinyButton.pillMax }
    let wideW = width - 60
    var rows: [[(String, CGFloat, Bool)]] = []  // per line: (label, width, isWide)
    var line: [(String, CGFloat, Bool)] = []
    var x: CGFloat = 10
    for l in labels.filter({ !fits($0) }) { rows.append([(l, wideW, true)]) }
    for l in labels.filter(fits) {
      let w = min(NSAttributedString(string: l, attributes: [.font: TinyButton.font]).size().width + 18, TinyButton.pillMax)
      if x + w > width - 14 && !line.isEmpty { rows.append(line); line = []; x = 10 }
      line.append((l, w, false))
      x += w + 6
    }
    if !line.isEmpty { rows.append(line) }
    // Top to bottom in the order asked; heights from the wrapped text.
    var items: [(String, NSRect, Bool)] = []
    var y: CGFloat = 0
    for row in rows.reversed() {
      let h = row.contains { $0.2 } ? TinyButton.wideHeight(row[0].0, width: wideW) : 22
      var cx: CGFloat = 10
      for (l, w, wide) in row {
        items.append((l, NSRect(x: cx, y: y, width: w, height: h), wide))
        cx += w + 6
      }
      y += h + 6
    }
    return (items, max(0, y - 6))
  }

  // A question gets two lines; everything else one.
  static func summaryExtra(_ e: Entry, width: CGFloat = 308) -> CGFloat {
    guard e.kind == "needs", let text = e.summary else { return 0 }
    let w = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11.5)]).size().width
    return w > width - 44 ? 15 : 0
  }

  static func height(_ e: Entry) -> CGFloat {
    let buttons = answerLayout(e).height
    return (e.bill == nil || e.kind == "session" ? 44 : 58) + summaryExtra(e) + (buttons > 0 ? buttons + 10 : 0)
  }

  init(entry: Entry, width: CGFloat) {
    self.entry = entry
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: Row.height(entry)))
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    // The question's choices: answer it from here, without going to the tab.
    for (label, rect, wide) in Row.answerLayout(entry, width: width).items {
      let b = TinyButton(label, wide: wide ? rect.width : nil, tip: "Answer \"\(label)\" without leaving where you are") { [weak self] in
        guard let self else { return }
        self.onAnswer?(self.entry, label)
      }
      b.frame.origin = NSPoint(x: rect.minX, y: 6 + rect.minY)
      addSubview(b)
    }
    let snooze = TinyButton("⏰", quiet: true, tip: "Snooze 10 minutes") { [weak self] in
      guard let self else { return }
      self.onSnooze?(self.entry)
    }
    snooze.frame = NSRect(x: width - 56, y: bounds.height - 25, width: 26, height: 22)
    addSubview(snooze)
  }
  required init?(coder: NSCoder) { nil }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { onClick?(entry) }
  override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; NSCursor.pointingHand.set() }
  override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; NSCursor.arrow.set() }

  override func draw(_ dirtyRect: NSRect) {
    if hovering {
      NSColor.white.withAlphaComponent(0.08).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    // The project alone (not its subfolder), so the verb always fits.
    let name = entry.title.components(separatedBy: " · ")[0]
    let head: String
    switch entry.kind {
    case "needs": head = "✋  \(name) needs you"
    case "burnt": head = "🔥  \(name) got burnt"
    case "session": head = "\(dish(for: entry))  \(name)  ·  \(entry.bill ?? "")"
    default: head = "\(dish(for: entry))  \(name) is cooked!"
    }
    let top = bounds.height
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingTail
    NSAttributedString(string: head, attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: color(hex: entry.color), .paragraphStyle: para,
    ]).draw(in: NSRect(x: 10, y: top - 22, width: bounds.width - 70, height: 18))
    let extra = Row.summaryExtra(entry, width: bounds.width)
    let wrap = NSMutableParagraphStyle()
    wrap.lineBreakMode = .byWordWrapping
    NSAttributedString(string: entry.summary ?? (entry.kind == "burnt" ? "The turn ended with an error" : "Finished"), attributes: [
      .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.white.withAlphaComponent(0.72), .paragraphStyle: extra > 0 ? wrap : para,
    ]).draw(with: NSRect(x: 10, y: top - 39 - extra, width: bounds.width - 44, height: 16 + extra), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    if let bill = entry.bill, entry.kind != "session" {
      NSAttributedString(string: "🧾 \(bill)", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.45), .paragraphStyle: para,
      ]).draw(in: NSRect(x: 10, y: top - 54 - extra, width: bounds.width - 44, height: 14))
    }
    let arrow = NSAttributedString(string: "→", attributes: [
      .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(hovering ? 0.95 : 0.45),
    ])
    arrow.draw(at: NSPoint(x: bounds.width - 26, y: bounds.height / 2 - 10))
  }
}

final class CloseButton: NSView {
  var onClick: (() -> Void)?
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func draw(_ dirtyRect: NSRect) {
    NSAttributedString(string: "✕", attributes: [
      .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.55),
    ]).draw(at: NSPoint(x: 4, y: 3))
  }
}

// The speech bubble: a dark rounded card with a tail toward the mascot.
final class Bubble: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let card = NSRect(x: 0, y: 10, width: bounds.width, height: bounds.height - 10)
    let path = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bounds.width - 110, y: 11))
    tail.line(to: NSPoint(x: bounds.width - 96, y: 0))
    tail.line(to: NSPoint(x: bounds.width - 88, y: 11))
    tail.close()
    path.append(tail)
    NSColor(srgbRed: 0.11, green: 0.1, blue: 0.1, alpha: 1).setFill()
    path.fill()
    claudeOrange.withAlphaComponent(0.55).setStroke()
    path.lineWidth = 1.5
    path.stroke()
  }
}

// How long ago a moment (in ms) was, short: "just now", "4m", "1h 5m", "3d"; empty for no moment.
func ago(_ ms: Double) -> String {
  guard ms > 0 else { return "" }
  let m = max(0, Int((Date().timeIntervalSince1970 - ms / 1000) / 60))
  if m < 1 { return "just now" }
  if m < 60 { return "\(m)m" }
  if m < 1440 { return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }
  return "\(m / 1440)d"
}

// A state's pill: its words and color.
func pill(_ s: Session) -> (String, NSColor) {
  let t = ago(s.since)
  switch s.state {
  case "needs": return ("needs you\(t.isEmpty ? "" : " · \(t)")", NSColor(srgbRed: 0.96, green: 0.68, blue: 0.2, alpha: 1))
  case "cooking": return ("cooking\(t.isEmpty ? "" : " · \(t)")", claudeOrange)
  case "ready": return (t.isEmpty || t == "just now" ? "ready" : "ready · \(t) ago", NSColor(srgbRed: 0.42, green: 0.78, blue: 0.5, alpha: 1))
  default: return ("resting", NSColor(white: 0.55, alpha: 1))
  }
}

// One session in the kitchen: dish and project on the left, its state as a pill in a
// fixed column on the right (never cut off), what it is doing underneath.
final class SessionRow: NSView {
  let session: Session
  var onClick: ((Session) -> Void)?
  private var hovering = false
  static let height: CGFloat = 46

  init(session: Session, width: CGFloat) {
    self.session = session
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: SessionRow.height))
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  required init?(coder: NSCoder) { nil }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { onClick?(session) }
  override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; NSCursor.pointingHand.set() }
  override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; NSCursor.arrow.set() }

  override func draw(_ dirtyRect: NSRect) {
    if hovering {
      NSColor.white.withAlphaComponent(0.08).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    let clip = NSMutableParagraphStyle()
    clip.lineBreakMode = .byTruncatingTail
    // The pill, measured first so the name gets the rest of the line.
    let (words, tint) = pill(session)
    let pillText = NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: tint])
    let pw = pillText.size().width + 14
    let pillRect = NSRect(x: bounds.width - pw - 8, y: bounds.height - 22, width: pw, height: 17)
    tint.withAlphaComponent(0.16).setFill()
    NSBezierPath(roundedRect: pillRect, xRadius: 8.5, yRadius: 8.5).fill()
    pillText.draw(at: NSPoint(x: pillRect.minX + 7, y: pillRect.minY + 2))

    let name = session.title
    NSAttributedString(string: "\(session.state == "needs" ? "✋" : session.dish ?? "🍽")  \(name)", attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: color(hex: session.color), .paragraphStyle: clip,
    ]).draw(in: NSRect(x: 10, y: bounds.height - 23, width: pillRect.minX - 16, height: 18))
    let fallback: String
    switch session.state {
    case "cooking": fallback = "working…"
    case "needs": fallback = "waiting for your answer"
    case "ready": fallback = "finished, waiting for your next prompt"
    default: fallback = "waiting for your next prompt"
    }
    let line = (session.activity?.isEmpty == false ? session.activity! : fallback)
    NSAttributedString(string: line, attributes: [
      .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.white.withAlphaComponent(session.activity?.isEmpty == false ? 0.72 : 0.42), .paragraphStyle: clip,
    ]).draw(in: NSRect(x: 33, y: 5, width: bounds.width - 33 - 12, height: 16))
  }
}

// The resting sessions, folded into one line of small chips; each chip jumps there.
final class Chip: NSView {
  let session: Session
  var onClick: ((Session) -> Void)?
  private var hovering = false
  let text: NSAttributedString

  init(session: Session, count: Int = 1) {
    self.session = session
    let name = session.title.components(separatedBy: " · ")[0]
    text = NSAttributedString(string: count > 1 ? "\(name) ×\(count)" : name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color(hex: session.color)])
    super.init(frame: NSRect(x: 0, y: 0, width: text.size().width + 22, height: 20))
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    toolTip = count > 1 ? "\(count) resting sessions in \(name) — click for the most recent" : "\(session.title) — resting \(ago(session.since))"
  }
  required init?(coder: NSCoder) { nil }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { onClick?(session) }
  override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; NSCursor.pointingHand.set() }
  override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; NSCursor.arrow.set() }

  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    NSColor.white.withAlphaComponent(hovering ? 0.14 : 0.07).setFill()
    shape.fill()
    color(hex: session.color).setFill()
    NSBezierPath(ovalIn: NSRect(x: 8, y: 7.5, width: 5, height: 5)).fill()
    text.draw(at: NSPoint(x: 16, y: 3))
  }
}

// A quiet line of text in the bubble: the empty states.
func note(_ title: String, _ body: String, width: CGFloat) -> NSView {
  let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 58))
  let t = NSTextField(labelWithString: title)
  t.font = .systemFont(ofSize: 13, weight: .semibold)
  t.textColor = NSColor.white.withAlphaComponent(0.85)
  t.frame = NSRect(x: 10, y: 36, width: width - 20, height: 18)
  let b = NSTextField(wrappingLabelWithString: body)
  b.font = .systemFont(ofSize: 11.5)
  b.textColor = NSColor.white.withAlphaComponent(0.55)
  b.frame = NSRect(x: 10, y: 2, width: width - 20, height: 32)
  v.addSubview(t)
  v.addSubview(b)
  return v
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let width: CGFloat = 320
  var panel: NSPanel!
  var status: NSStatusItem?
  let mascot = Chef(frame: NSRect(x: 0, y: 0, width: 136, height: 124))
  var entries: [Entry] = []
  var sessions: [Session] = []
  var seen = Set<String>()
  var snoozed: [Entry] = []
  // Called out from the menu bar: the chef stays out (with the kitchen when no
  // order waits) until the icon or ✕ sends it back.
  var isSummoned = false
  let menu = NSMenu()
  var removedHere = Set<String>()
  var settings = Settings()

  func applicationDidFinishLaunching(_ note: Notification) {
    try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    mascot.onClick = { [weak self] in if let last = self?.entries.last { self?.open(last) } }
    // `open OrderUp.app --args --kitchen` starts with the chef called out.
    isSummoned = CommandLine.arguments.contains("--kitchen")

    Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.mascot.step() }
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.dropVisited() }
    poll()
  }

  func decode<T: Decodable>(_ dir: URL, as: T.Type) -> [(URL, T)] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { url in
      guard let data = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(T.self, from: data) else { return nil }
      return (url, v)
    }
  }

  func loadOrders() -> [Entry] {
    decode(queueDir, as: Entry.self).map { url, e in
      var e = e
      e.file = url.path
      return e
    }.sorted { $0.at < $1.at }
  }

  func loadSessions() -> [Session] {
    let now = Date().timeIntervalSince1970
    var live: [Session] = []
    for (url, s) in decode(sessionsDir, as: Session.self) {
      if now - s.updatedAt / 1000 > staleAfter { try? FileManager.default.removeItem(at: url) } else { live.append(s) }
    }
    let rank = ["needs": 0, "cooking": 1, "ready": 2, "idle": 3]
    return live.sorted { a, b in
      let ra = rank[a.state] ?? 4, rb = rank[b.state] ?? 4
      return ra != rb ? ra < rb : a.since > b.since
    }
  }

  func key(_ e: Entry) -> String { "\(e.tty ?? e.bundleId ?? e.title)@\(e.at)" }

  func remove(_ e: Entry, _ why: String) {
    log("removed \(e.title): \(why)")
    removedHere.insert(key(e))
    if let f = e.file { try? FileManager.default.removeItem(atPath: f) }
  }

  func poll() {
    settings = loadSettings()
    sessions = loadSessions()
    var next = loadOrders()
    let isNew = { (e: Entry) in !self.seen.contains(self.key(e)) }
    // Ask the front app only when something new landed; dropVisited covers the rest.
    let f = next.contains(where: isNew) ? front() : Front(bundleId: nil, tty: nil)
    var fresh: String?
    for e in next where isNew(e) {
      seen.insert(key(e))
      log("order \(e.title) (\(e.kind ?? "done")), front: \(f.bundleId ?? "-") \(f.tty ?? "")")
      // Finished where you are looking: nothing to tell you (a test order shows anyway).
      if e.isTest != true && isInView(tty: e.tty, bundleId: e.bundleId, f) {
        remove(e, "its session was in front when it finished")
      } else if fresh != "needs" {
        fresh = e.kind ?? "done"
      }
    }
    next.removeAll { removedHere.contains(key($0)) }
    // Snoozed orders wait out of sight; one whose time is up comes back like a new one.
    let now = Date().timeIntervalSince1970
    let wasAsleep = Set(snoozed.map { key($0) })
    snoozed = next.filter { ($0.snoozeUntil ?? 0) > now }
    next.removeAll { ($0.snoozeUntil ?? 0) > now }
    for e in next where wasAsleep.contains(key(e)) && fresh == nil { fresh = e.kind ?? "done" }
    if next != entries {
      entries = next
      mascot.oldest = entries.first.map { Date(timeIntervalSince1970: $0.at) }
      mascot.dish = entries.last.map { $0.kind == "needs" ? "✋" : dish(for: $0) } ?? "🍜"
      mascot.isBurnt = entries.last?.kind == "burnt"
      layout()
    }
    if let fresh {
      mascot.hopUntil = Date().addingTimeInterval(2.4)
      mascot.popUntil = Date().addingTimeInterval(3.2)
      if settings.sound != false { NSSound(named: fresh == "needs" ? "Ping" : fresh == "burnt" ? "Funk" : "Glass")?.play() }
    }
    updateStatus()
    // Stay while there is an order to show, or a kitchen to keep in the menu bar.
    if isSummoned { layout() }
    if entries.isEmpty && snoozed.isEmpty && !isSummoned && !(settings.menubar != false && (settings.stayOpen == true || !sessions.isEmpty)) {
      log("nothing to show, leaving")
      NSApp.terminate(nil)
    }
  }

  // An order leaves once you are looking at its session, however you got there.
  func dropVisited() {
    guard !entries.isEmpty else { return }
    let f = front()
    for e in entries where e.isTest != true && isInView(tty: e.tty, bundleId: e.bundleId, f) { remove(e, "you are looking at its session") }
    poll()
  }

  func open(_ e: Entry) {
    jump(tty: e.tty, bundleId: e.bundleId)
    remove(e, "clicked")
    poll()
  }

  // The menu bar kitchen: 🔔 and the orders waiting, else ✋ or 🍳 and the sessions busy.
  // The menu bar kitchen: a tiny chef, with the count of orders waiting (or ✋ for
  // sessions that need you). Click it to call the chef out; right-click for the menu.
  func updateStatus() {
    guard settings.menubar != false else {
      if let status { NSStatusBar.system.removeStatusItem(status); self.status = nil }
      return
    }
    if status == nil {
      status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      menu.delegate = self
      status?.button?.image = chefIcon()
      status?.button?.imagePosition = .imageLeft
      status?.button?.target = self
      status?.button?.action = #selector(statusClicked)
      status?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
      status?.button?.toolTip = "order-up: click for the chef, right-click for the menu"
    }
    let cooking = sessions.filter { $0.state == "cooking" }.count
    let needs = sessions.filter { $0.state == "needs" }.count
    let title = !entries.isEmpty ? " \(entries.count)" : needs > 0 ? " ✋\(needs)" : !snoozed.isEmpty ? " 💤\(snoozed.count)" : cooking > 0 ? " \(cooking)🍳" : ""
    if status?.button?.title != title { status?.button?.title = title }
  }

  @objc func statusClicked() {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      status?.menu = menu
      status?.button?.performClick(nil)
      status?.menu = nil
      return
    }
    isSummoned.toggle()
    if isSummoned {
      mascot.hopUntil = Date().addingTimeInterval(1.2)
      mascot.popUntil = Date().addingTimeInterval(1.6)
    }
    layout()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let head = NSMenuItem(title: sessions.isEmpty ? "No Claude sessions running" : "Kitchen", action: nil, keyEquivalent: "")
    head.isEnabled = false
    menu.addItem(head)
    let now = Date().timeIntervalSince1970
    let names = ["cooking": "🍳 cooking", "needs": "✋ needs you", "ready": "✓ ready", "idle": "· idle"]
    for (i, s) in sessions.enumerated() {
      let mins = max(0, Int((now - s.since / 1000) / 60))
      let item = NSMenuItem(title: "\(s.dish ?? "🍽") \(s.title)  —  \(names[s.state] ?? s.state) \(mins)m", action: #selector(jumpTo(_:)), keyEquivalent: i < 9 ? String(i + 1) : "")
      item.target = self
      item.representedObject = s.key
      if let a = s.activity, !a.isEmpty { item.toolTip = a }
      menu.addItem(item)
    }
    menu.addItem(.separator())
    if !entries.isEmpty {
      let later = NSMenuItem(title: "Snooze \(entries.count == 1 ? "it" : "all") 10 minutes", action: #selector(snoozeAll), keyEquivalent: "")
      later.target = self
      menu.addItem(later)
      let clear = NSMenuItem(title: "Clear \(entries.count) order\(entries.count == 1 ? "" : "s")", action: #selector(clearOrders), keyEquivalent: "")
      clear.target = self
      menu.addItem(clear)
    }
    let hint = NSMenuItem(title: "Settings: run /order-up setup in Claude Code", action: nil, keyEquivalent: "")
    hint.isEnabled = false
    menu.addItem(hint)
    menu.addItem(NSMenuItem(title: "Quit order-up", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  }

  @objc func jumpTo(_ item: NSMenuItem) {
    guard let key = item.representedObject as? String, let s = sessions.first(where: { $0.key == key }) else { return }
    jump(tty: s.tty, bundleId: s.bundleId)
  }

  // Answers a waiting question from the chef: the session's mod picks up the file.
  func answer(_ e: Entry, _ label: String) {
    guard let id = e.answerId?.filter({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), !id.isEmpty else { return }
    let dir = home.appendingPathComponent("answers")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: ["answer": label]) {
      try? data.write(to: dir.appendingPathComponent("\(id).json"))
    }
    remove(e, "answered from the chef: \(label)")
    poll()
  }

  func snooze(_ list: [Entry]) {
    let until = Date().timeIntervalSince1970 + SNOOZE_SECONDS
    for e in list {
      guard let f = e.file, let data = try? Data(contentsOf: URL(fileURLWithPath: f)),
            var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      obj["snoozeUntil"] = until
      if let out = try? JSONSerialization.data(withJSONObject: obj) { try? out.write(to: URL(fileURLWithPath: f)) }
      log("snoozed \(e.title) for \(Int(SNOOZE_SECONDS / 60))m")
    }
    poll()
  }

  @objc func snoozeAll() { snooze(entries) }

  @objc func clearOrders() {
    entries.forEach { remove($0, "cleared from the menu bar") }
    poll()
  }

  // The bubble's body: the orders, else (called out) the kitchen, as views with their heights.
  func body() -> (header: String, views: [NSView]) {
    let inner = width - 12
    if !entries.isEmpty {
      let waiting = entries.filter { $0.kind == "needs" }.count
      let header = waiting == entries.count
        ? (waiting == 1 ? "✋ A session needs you" : "✋ \(waiting) sessions need you")
        : entries.count == 1 ? "🔔 Order up!" : "🔔 Order up! ×\(entries.count)\(waiting > 0 ? " · ✋\(waiting)" : "")"
      let rows: [NSView] = entries.reversed().map { e in
        let row = Row(entry: e, width: inner)
        row.onClick = { [weak self] in self?.open($0) }
        row.onAnswer = { [weak self] in self?.answer($0, $1) }
        row.onSnooze = { [weak self] in self?.snooze([$0]) }
        return row
      }
      return (header, rows)
    }
    let busy = sessions.filter { $0.state != "idle" }
    let resting = sessions.filter { $0.state == "idle" }
    var counts: [String] = []
    let cooking = busy.filter { $0.state == "cooking" }.count
    let needs = busy.filter { $0.state == "needs" }.count
    let ready = busy.filter { $0.state == "ready" }.count
    if needs > 0 { counts.append("\(needs) needs you") }
    if cooking > 0 { counts.append("\(cooking) cooking") }
    if ready > 0 { counts.append("\(ready) ready") }
    let header = "👨‍🍳 Kitchen" + (counts.isEmpty ? "" : " · " + counts.joined(separator: " · "))
    var views: [NSView] = []
    if sessions.isEmpty {
      views.append(note("Kitchen's quiet", "Start Claude Code in any tab and I'll keep an eye on it.", width: inner))
      return (header, views)
    }
    if busy.isEmpty { views.append(note("All caught up", "Nothing cooking. Your sessions are resting.", width: inner)) }
    for s in busy {
      let row = SessionRow(session: s, width: inner)
      row.onClick = { [weak self] in self?.jumpTo(session: $0) }
      views.append(row)
    }
    if !resting.isEmpty {
      // "💤 Resting" then chips, wrapping onto more lines as needed.
      let strip = NSView(frame: NSRect(x: 0, y: 0, width: inner, height: 0))
      let label = NSAttributedString(string: "💤 Resting", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.45)])
      var placed: [(NSView, CGFloat, CGFloat)] = []
      var x: CGFloat = 10 + label.size().width + 8, line: CGFloat = 0
      // One chip per project: its tabs counted, a click going to the most recent.
      var groups: [(Session, Int)] = []
      for s in resting.sorted(by: { $0.since > $1.since }) {
        let name = s.title.components(separatedBy: " · ")[0]
        if let i = groups.firstIndex(where: { $0.0.title.components(separatedBy: " · ")[0] == name }) { groups[i].1 += 1 } else { groups.append((s, 1)) }
      }
      for (s, n) in groups {
        let chip = Chip(session: s, count: n)
        chip.onClick = { [weak self] in self?.jumpTo(session: $0) }
        if x + chip.frame.width > inner - 8 { x = 10; line += 1 }
        placed.append((chip, x, line))
        x += chip.frame.width + 6
      }
      let h = (line + 1) * 26 + 8
      strip.frame.size.height = h
      let tag = NSTextField(labelWithAttributedString: label)
      tag.frame = NSRect(x: 10, y: h - 25, width: label.size().width + 4, height: 16)
      strip.addSubview(tag)
      for (chip, cx, l) in placed {
        chip.frame.origin = NSPoint(x: cx, y: h - 27 - l * 26)
        strip.addSubview(chip)
      }
      views.append(strip)
    }
    return (header, views)
  }

  func jumpTo(session s: Session) {
    jump(tty: s.tty, bundleId: s.bundleId)
    isSummoned = false
    layout()
  }

  func layout() {
    guard !entries.isEmpty || isSummoned else {
      panel.orderOut(nil)
      return
    }
    mascot.isSleepy = entries.isEmpty && !sessions.contains { $0.state == "cooking" || $0.state == "needs" }
    let (headerText, views) = body()
    let header: CGFloat = 26, pad: CGFloat = 8
    let rowsH = views.reduce(CGFloat(0)) { $0 + $1.frame.height }
    let bubbleH = 10 + pad + header + rowsH + pad
    let total = NSSize(width: width, height: bubbleH + mascot.frame.height - 6)
    let root = NSView(frame: NSRect(origin: .zero, size: total))

    let bubble = Bubble(frame: NSRect(x: 0, y: mascot.frame.height - 6, width: width, height: bubbleH))
    let label = NSTextField(labelWithString: headerText)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = NSColor.white.withAlphaComponent(0.5)
    label.lineBreakMode = .byTruncatingTail
    label.frame = NSRect(x: 12, y: bubbleH - pad - 20, width: width - 50, height: 16)
    bubble.addSubview(label)
    let close = CloseButton(frame: NSRect(x: width - 30, y: bubbleH - pad - 22, width: 22, height: 20))
    close.onClick = { [weak self] in
      self?.entries.forEach { self?.remove($0, "closed with ✕") }
      self?.isSummoned = false
      self?.poll()
      self?.layout()
    }
    bubble.addSubview(close)
    var y = bubbleH - pad - header
    for v in views {
      y -= v.frame.height
      v.frame.origin = NSPoint(x: 6, y: y)
      bubble.addSubview(v)
    }
    root.addSubview(bubble)
    mascot.frame.origin = NSPoint(x: width - mascot.frame.width - 14, y: 0)
    root.addSubview(mascot)

    panel.setContentSize(total)
    panel.contentView = root
    if let screen = NSScreen.main?.visibleFrame {
      let x = settings.corner == "bottom-left" ? screen.minX + 20 : screen.maxX - total.width - 20
      let y = settings.corner == "top-right" ? screen.maxY - total.height - 20 : screen.minY + 20
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    panel.orderFrontRegardless()
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
