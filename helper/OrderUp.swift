// OrderUp: the tiny chef that tells you a Claude Code session finished (or needs
// you) somewhere you are not looking. The order-up mod writes one JSON order per
// session to ~/.claude/order-up/queue/ and a heartbeat per session to
// ~/.claude/order-up/sessions/; this app lists the orders in one bubble, jumps to
// the session on a click, drops an order once you are looking at its session, and
// keeps a kitchen in the menu bar while sessions run.

import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/order-up")
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
      let eye = NSRect(x: x - 5, y: blink ? 74 : 70, width: 10, height: blink ? 2 : 11)
      NSBezierPath(ovalIn: eye).fill()
      if !blink {
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
  }
}

// One finished session: the place in its tint, what got done under it.
final class Row: NSView {
  let entry: Entry
  var onClick: ((Entry) -> Void)?
  private var hovering = false

  static func height(_ e: Entry) -> CGFloat { e.bill == nil || e.kind == "session" ? 44 : 58 }

  init(entry: Entry, width: CGFloat) {
    self.entry = entry
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: Row.height(entry)))
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
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
    NSAttributedString(string: head, attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: color(hex: entry.color),
    ]).draw(in: NSRect(x: 10, y: top - 22, width: bounds.width - 44, height: 18))
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingTail
    NSAttributedString(string: entry.summary ?? (entry.kind == "burnt" ? "The turn ended with an error" : "Finished"), attributes: [
      .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.white.withAlphaComponent(0.72), .paragraphStyle: para,
    ]).draw(in: NSRect(x: 10, y: top - 39, width: bounds.width - 44, height: 16))
    if let bill = entry.bill, entry.kind != "session" {
      NSAttributedString(string: "🧾 \(bill)", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.45), .paragraphStyle: para,
      ]).draw(in: NSRect(x: 10, y: 4, width: bounds.width - 44, height: 14))
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

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let width: CGFloat = 300
  var panel: NSPanel!
  var status: NSStatusItem?
  let mascot = Chef(frame: NSRect(x: 0, y: 0, width: 136, height: 124))
  var entries: [Entry] = []
  var sessions: [Session] = []
  var seen = Set<String>()
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
    if entries.isEmpty && !isSummoned && !(settings.menubar != false && (settings.stayOpen == true || !sessions.isEmpty)) {
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
    if e.kind == "session" {
      isSummoned = false
      layout()
      return
    }
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
    let title = !entries.isEmpty ? " \(entries.count)" : needs > 0 ? " ✋\(needs)" : cooking > 0 ? " \(cooking)🍳" : ""
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

  @objc func clearOrders() {
    entries.forEach { remove($0, "cleared from the menu bar") }
    poll()
  }

  // The rows the bubble shows: the orders, or (called out with none waiting) the kitchen.
  func shown() -> [Entry] {
    if !entries.isEmpty || !isSummoned { return entries }
    let now = Date().timeIntervalSince1970
    let names = ["cooking": "🍳 cooking", "needs": "✋ needs you", "ready": "✓ ready", "idle": "· idle"]
    return sessions.reversed().map { s in
      let mins = max(0, Int((now - s.since / 1000) / 60))
      return Entry(tty: s.tty, bundleId: s.bundleId, title: s.title, color: s.color, dish: s.dish, summary: s.activity ?? "", bill: "\(names[s.state] ?? s.state) \(mins)m", kind: "session", at: s.since / 1000)
    }
  }

  func layout() {
    let rows = shown()
    guard !rows.isEmpty || isSummoned else {
      panel.orderOut(nil)
      return
    }
    let header: CGFloat = 26, pad: CGFloat = 8
    let rowsH = rows.isEmpty ? 44 : rows.reduce(CGFloat(0)) { $0 + Row.height($1) }
    let bubbleH = 10 + pad + header + rowsH + pad
    let total = NSSize(width: width, height: bubbleH + mascot.frame.height - 6)
    let root = NSView(frame: NSRect(origin: .zero, size: total))

    let bubble = Bubble(frame: NSRect(x: 0, y: mascot.frame.height - 6, width: width, height: bubbleH))
    let waiting = entries.filter { $0.kind == "needs" }.count
    let label = NSTextField(labelWithString: entries.isEmpty ? "👨‍🍳 Kitchen" : waiting == entries.count
      ? (waiting == 1 ? "✋ A session needs you" : "✋ \(waiting) sessions need you")
      : entries.count == 1 ? "🔔 Order up!" : "🔔 Order up! ×\(entries.count)\(waiting > 0 ? " · ✋\(waiting)" : "")")
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = NSColor.white.withAlphaComponent(0.5)
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
    if rows.isEmpty {
      let none = NSTextField(labelWithString: "Nothing cooking. Start Claude Code in a tab and I'll keep watch.")
      none.font = .systemFont(ofSize: 11.5)
      none.textColor = NSColor.white.withAlphaComponent(0.6)
      none.frame = NSRect(x: 16, y: y - 32, width: width - 32, height: 18)
      bubble.addSubview(none)
    }
    for e in rows.reversed() {
      let row = Row(entry: e, width: width - 12)
      y -= Row.height(e)
      row.frame.origin = NSPoint(x: 6, y: y)
      row.onClick = { [weak self] in self?.open($0) }
      bubble.addSubview(row)
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
