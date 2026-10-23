// AwakeLock: menu bar app that covers every display with its own retro lock screen while keeping the
// Mac awake, so long-running sessions (VS Code agent, SSH, builds) keep running behind it.
//
// Performance: everything is drawn once into Core Animation layers; motion (rain, bouncing plea,
// blinking, progress bar) is done by CA animations on the GPU. The only per-tick CPU work is the
// small typewriter text line and the once-a-second clock/elapsed labels.
import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import LocalAuthentication
import OpenDirectory
import QuartzCore

// MARK: - Theme

enum Retro {
    static let green = NSColor(srgbRed: 0.25, green: 1, blue: 0.45, alpha: 1)
    static let headGlyph = NSColor(srgbRed: 0.8, green: 1, blue: 0.85, alpha: 1)
    static let red = NSColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1)
    static let background = NSColor(srgbRed: 0.01, green: 0.04, blue: 0.02, alpha: 1)
    static let pleaColors = [
        green,
        NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: 1),
        NSColor(srgbRed: 0.3, green: 0.9, blue: 1, alpha: 1),
        NSColor(srgbRed: 1, green: 0.4, blue: 0.85, alpha: 1),
    ]
    static let turkish = Locale(identifier: "tr_TR")

    static let jokes = [
        "Önemli bir işin ortasındayım. Kapağı kapatırsan kalbim kırılır.",
        "Sahibim kahve almaya gitti, beni sorumlu bıraktı. Hiçbir şeye dokunma.",
        "Şşş... ajan düşünüyor. Hem de çok. Muhtemelen noktalı virgüller hakkında.",
        "Evet, ekran kilitli. Hayır, uyumuyorum. Çalışıyorum. Bazılarının aksine.",
        "Kapağı kapatırsan bir yerlerde bir build ağlar.",
        "Şu an kod yazıyorum. Alkışları sahibim toplayacak.",
        "Fişimi çekme. Düşüncelerimi henüz kaydetmedim.",
        "Bu bilgisayar şu an senden daha meşgul. Darılma.",
    ]

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func size(of text: String, font: NSFont) -> CGSize {
        let size = NSAttributedString(string: text, attributes: [.font: font]).size()
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2)
    }
}

/// Cheap deterministic hash so every rain column gets its own look without stored state.
private func scramble(_ value: Int) -> Int {
    var x = UInt64(truncatingIfNeeded: value) &* 0x9E37_79B9_7F4A_7C15
    x ^= x >> 31
    x = x &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 29
    return Int(x & 0x7FFF_FFFF)
}

/// Caps how often the compositor redraws for an animation; on a 120 Hz display an uncapped
/// animation would make WindowServer recomposite the whole screen 120 times a second.
private func cap<T: CAAnimation>(_ animation: T, fps: Float) -> T {
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
    return animation
}

private func withoutAnimation(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

// MARK: - Lock screen view

final class LockScreenView: NSView {
    private let scale: CGFloat
    private let lockedAt: Date
    private let canvas = CALayer()

    private var clockHours = CATextLayer()
    private var clockMinutes = CATextLayer()
    private var dateLayer = CATextLayer()
    private var jokeLayer = CATextLayer()
    private var elapsedLayer = CATextLayer()
    private var errorLayer = CATextLayer()
    private var dateRight: CGFloat = 0
    private var dateY: CGFloat = 0

    private(set) var passwordField: NSSecureTextField?
    private var onPassword: ((String) -> Void)?
    private var onTouchID: (() -> Void)?

    private static let rainCell: CGFloat = 26
    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜ0123456789").map(String.init)

    init(size: CGSize, scale: CGFloat, lockedAt: Date,
         onPassword: ((String) -> Void)?, onTouchID: (() -> Void)?) {
        self.scale = scale
        self.lockedAt = lockedAt
        self.onPassword = onPassword
        self.onTouchID = onTouchID
        super.init(frame: CGRect(origin: .zero, size: size))

        // Layer-hosting child view for all drawing; AppKit controls sit above it.
        let host = NSView(frame: bounds)
        host.layer = canvas
        host.wantsLayer = true
        addSubview(host)

        withoutAnimation { buildScene() }
        tick(now: Date())
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Scene

    private func buildScene() {
        let width = bounds.width
        let height = bounds.height
        canvas.backgroundColor = Retro.background.cgColor
        canvas.contentsScale = scale

        canvas.addSublayer(makeRain())

        // Header bar
        let header = makePanel(CGRect(x: 40, y: height - 34 - 54, width: width - 80, height: 54))
        canvas.addSublayer(header)
        let prompt = makeText("C:\\AWAKELOCK> SİSTEM KİLİTLİ", font: Retro.font(18, .bold), glow: true)
        prompt.frame.origin = CGPoint(x: 18, y: (54 - prompt.frame.height) / 2)
        header.addSublayer(prompt)
        let cursor = makeText("█", font: Retro.font(18, .bold), glow: true)
        cursor.frame.origin = CGPoint(x: prompt.frame.maxX, y: prompt.frame.minY)
        blink(cursor)
        header.addSublayer(cursor)
        dateLayer = makeText("", font: Retro.font(18, .bold), glow: true)
        dateRight = header.bounds.width - 18
        dateY = prompt.frame.minY
        header.addSublayer(dateLayer)

        // Center: clock + progress bar
        let panelSize = CGSize(width: min(820, width - 120), height: 340)
        let center = makePanel(CGRect(x: (width - panelSize.width) / 2, y: (height - panelSize.height) / 2,
                                      width: panelSize.width, height: panelSize.height), opacity: 0.9, border: 2)
        canvas.addSublayer(center)

        let clockFont = Retro.font(190, .bold)
        let digits = Retro.size(of: "00", font: clockFont)
        let colonWidth = Retro.size(of: ":", font: clockFont).width
        let clockX = (panelSize.width - (digits.width * 2 + colonWidth)) / 2
        let clockY = panelSize.height - digits.height - 20
        clockHours = makeText("00", font: clockFont, glow: true)
        clockHours.frame.origin = CGPoint(x: clockX, y: clockY)
        let colon = makeText(":", font: clockFont, glow: true)
        colon.frame.origin = CGPoint(x: clockX + digits.width, y: clockY)
        blink(colon)
        clockMinutes = makeText("00", font: clockFont, glow: true)
        clockMinutes.frame.origin = CGPoint(x: clockX + digits.width + colonWidth, y: clockY)
        [clockHours, colon, clockMinutes].forEach(center.addSublayer)

        let label = makeText("AJAN ÇALIŞIYOR", font: Retro.font(22, .bold), glow: true)
        let barSize = CGSize(width: 320, height: 22)
        let rowX = (panelSize.width - (barSize.width + 24 + label.frame.width)) / 2
        let bar = makeProgressBar(CGRect(origin: CGPoint(x: rowX, y: 40), size: barSize))
        center.addSublayer(bar)
        label.frame.origin = CGPoint(x: rowX + barSize.width + 24, y: 40 + (barSize.height - label.frame.height) / 2)
        center.addSublayer(label)

        // Footer: typewriter joke, password, elapsed time
        let footer = makePanel(CGRect(x: 40, y: 34, width: width - 80, height: 116))
        canvas.addSublayer(footer)
        jokeLayer = makeText("", font: Retro.font(20))
        jokeLayer.frame = CGRect(x: 18, y: 116 - 18 - jokeLayer.frame.height, width: footer.bounds.width - 36,
                                 height: jokeLayer.frame.height)
        footer.addSublayer(jokeLayer)

        elapsedLayer = makeText("", font: Retro.font(16))
        elapsedLayer.opacity = 0.7
        elapsedLayer.alignmentMode = .right
        elapsedLayer.frame = CGRect(x: footer.bounds.width - 18 - 320, y: 20, width: 320, height: elapsedLayer.frame.height)
        footer.addSublayer(elapsedLayer)

        if onPassword != nil {
            buildPasswordRow(footerOrigin: footer.frame.origin)
        }

        // Bouncing plea, then static CRT overlay (scanlines, vignette, double border) on top.
        canvas.addSublayer(makeBouncingPlea())
        canvas.addSublayer(makeCRTOverlay())
    }

    private func buildPasswordRow(footerOrigin: CGPoint) {
        let font = Retro.font(18, .bold)
        let label = makeText("> ŞİFRE:", font: font, glow: true)
        let rowY = footerOrigin.y + 18
        label.frame.origin = CGPoint(x: footerOrigin.x + 18, y: rowY + 4)
        canvas.addSublayer(label)

        let field = NSSecureTextField()
        field.font = font
        field.textColor = Retro.green
        field.backgroundColor = Retro.background
        field.drawsBackground = true
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(submitPassword)
        let fieldHeight = ceil(field.cell?.cellSize.height ?? 24)
        field.frame = CGRect(x: label.frame.maxX + 16, y: rowY + 6, width: 280, height: fieldHeight)
        addSubview(field)
        passwordField = field

        let box = CALayer()
        box.frame = field.frame.insetBy(dx: -8, dy: -5)
        box.borderColor = Retro.green.withAlphaComponent(0.7).cgColor
        box.borderWidth = 1
        canvas.addSublayer(box)

        var nextX = box.frame.maxX + 20
        if onTouchID != nil {
            let button = NSButton(title: "", target: self, action: #selector(useTouchID))
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: "[ TOUCH ID ]",
                                                        attributes: [.font: font, .foregroundColor: Retro.green])
            button.sizeToFit()
            button.frame.origin = CGPoint(x: nextX, y: rowY + 4)
            addSubview(button)
            nextX = button.frame.maxX + 20
        }

        errorLayer = makeText("", font: font, color: Retro.red)
        errorLayer.frame = CGRect(x: nextX, y: rowY + 4, width: 400, height: errorLayer.frame.height)
        canvas.addSublayer(errorLayer)
    }

    // MARK: Building blocks

    private func makeText(_ string: String, font: NSFont, color: NSColor = Retro.green, glow: Bool = false) -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = scale
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = color.cgColor
        layer.string = string
        layer.frame = CGRect(origin: .zero, size: Retro.size(of: string.isEmpty ? "X" : string, font: font))
        if glow {
            // Shadow is rendered once into the rasterized bitmap, not per frame.
            layer.shadowColor = color.cgColor
            layer.shadowOpacity = 0.7
            layer.shadowRadius = 5
            layer.shadowOffset = .zero
            layer.shouldRasterize = true
            layer.rasterizationScale = scale
        }
        return layer
    }

    private func makePanel(_ frame: CGRect, opacity: CGFloat = 0.9, border: CGFloat = 1) -> CALayer {
        let panel = CALayer()
        panel.frame = frame
        panel.backgroundColor = Retro.background.withAlphaComponent(opacity).cgColor
        panel.borderColor = Retro.green.withAlphaComponent(0.65).cgColor
        panel.borderWidth = border
        return panel
    }

    private func blink(_ layer: CALayer) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0.12]
        animation.keyTimes = [0, 0.5, 1]
        animation.calculationMode = .discrete
        animation.duration = 1
        animation.repeatCount = .infinity
        layer.add(cap(animation, fps: 4), forKey: "blink")
    }

    /// Retro block bar that fills in 24 discrete steps and starts over.
    private func makeProgressBar(_ frame: CGRect) -> CALayer {
        let track = CALayer()
        track.frame = frame
        track.backgroundColor = Retro.green.withAlphaComponent(0.15).cgColor
        track.borderColor = Retro.green.cgColor
        track.borderWidth = 2

        let fill = CALayer()
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.frame = track.bounds.insetBy(dx: 4, dy: 4)
        fill.backgroundColor = Retro.green.cgColor
        track.addSublayer(fill)

        let steps = 24
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.x")
        animation.values = (0...steps).map { Double($0) / Double(steps) }
        animation.keyTimes = (0...(steps + 1)).map { NSNumber(value: Double($0) / Double(steps + 1)) }
        animation.calculationMode = .discrete
        animation.duration = Double(steps + 1) / 4
        animation.repeatCount = .infinity
        fill.add(cap(animation, fps: 8), forKey: "fill")
        return track
    }

    /// Falling glyph columns: a handful of pre-rendered strips, moved by GPU animations.
    private func makeRain() -> CALayer {
        let rain = CALayer()
        rain.frame = bounds
        rain.opacity = 0.55

        let cell = Self.rainCell
        let strips = (0..<16).compactMap { renderStrip(length: 8 + scramble($0 + 17) % 16, seed: $0) }
        guard !strips.isEmpty else { return rain }
        let columns = Int(bounds.width / cell) + 1

        for column in 0..<columns {
            let seed = scramble(column + 101)
            let image = strips[seed % strips.count]
            let stripHeight = CGFloat(image.height) / scale
            let strip = CALayer()
            strip.contents = image
            strip.frame = CGRect(x: CGFloat(column) * cell, y: bounds.height, width: cell, height: stripHeight)

            let speed = cell * CGFloat(4 + seed % 8)
            let gap = CGFloat((seed / 13) % 700)
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.fromValue = bounds.height + stripHeight / 2 + gap
            fall.toValue = -stripHeight / 2
            fall.duration = Double((bounds.height + stripHeight + gap) / speed)
            fall.timeOffset = fall.duration * Double((seed / 7) % 1000) / 1000
            fall.repeatCount = .infinity
            strip.add(cap(fall, fps: 20), forKey: "fall")
            rain.addSublayer(strip)
        }
        return rain
    }

    /// One column of glyphs: bright head at the bottom, fading tail above it.
    private func renderStrip(length: Int, seed: Int) -> CGImage? {
        let cell = Self.rainCell
        guard let context = CGContext(
            data: nil, width: Int(cell * scale), height: Int(cell * CGFloat(length) * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = Retro.font(17, .bold)
        for row in 0..<length {
            let glyph = Self.glyphs[scramble(seed * 131 + row) % Self.glyphs.count]
            let color = row == 0
                ? Retro.headGlyph
                : Retro.green.withAlphaComponent(0.9 * (1 - CGFloat(row) / CGFloat(length)))
            let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: color])
            let size = text.size()
            text.draw(at: CGPoint(x: (cell - size.width) / 2, y: CGFloat(row) * cell + (cell - size.height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// DVD-logo style plea bouncing across the screen; changes colour on every side-wall hit.
    private func makeBouncingPlea() -> CALayer {
        let size = CGSize(width: 500, height: 70)
        let box = CALayer()
        box.bounds = CGRect(origin: .zero, size: size)
        box.backgroundColor = Retro.background.withAlphaComponent(0.85).cgColor
        box.borderWidth = 3
        box.borderColor = Retro.green.cgColor

        let text = makeText("LÜTFEN BENİ KAPATMA!", font: Retro.font(32, .heavy))
        text.position = CGPoint(x: size.width / 2, y: size.height / 2)
        box.addSublayer(text)

        let spanX = max(bounds.width - size.width, 1)
        let spanY = max(bounds.height - size.height, 1)
        let durationX = Double(spanX / 140)
        let phase = durationX * Double(scramble(Int(bounds.width)) % 1000) / 1000

        func slide(_ keyPath: String, from: CGFloat, to: CGFloat, duration: Double) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timeOffset = phase
            return cap(animation, fps: 30)
        }
        box.position = CGPoint(x: size.width / 2, y: size.height / 2)
        box.add(slide("position.x", from: size.width / 2, to: bounds.width - size.width / 2, duration: durationX), forKey: "x")
        box.add(slide("position.y", from: size.height / 2, to: bounds.height - size.height / 2,
                      duration: Double(spanY / 95)), forKey: "y")

        let colors = Retro.pleaColors.map(\.cgColor)
        for (layer, keyPath) in [(box as CALayer, "borderColor"), (text as CALayer, "foregroundColor")] {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = colors
            animation.keyTimes = (0...colors.count).map { NSNumber(value: Double($0) / Double(colors.count)) }
            animation.calculationMode = .discrete
            animation.duration = durationX * Double(colors.count)
            animation.timeOffset = phase
            animation.repeatCount = .infinity
            layer.add(cap(animation, fps: 4), forKey: "color")
        }
        return box
    }

    /// Scanlines, vignette and double border, flattened into one cached bitmap.
    private func makeCRTOverlay() -> CALayer {
        let overlay = CALayer()
        overlay.frame = bounds

        let line = CALayer()
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        line.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        let scanlines = CAReplicatorLayer()
        scanlines.frame = bounds
        scanlines.instanceCount = Int(bounds.height / 3) + 1
        scanlines.instanceTransform = CATransform3DMakeTranslation(0, 3, 0)
        scanlines.addSublayer(line)
        overlay.addSublayer(scanlines)

        let vignette = CAGradientLayer()
        vignette.frame = bounds
        vignette.type = .radial
        vignette.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.8).cgColor]
        vignette.locations = [0.45, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.15, y: 1.15)
        overlay.addSublayer(vignette)

        for inset in [12.0, 18.0] {
            let border = CALayer()
            border.frame = bounds.insetBy(dx: inset, dy: inset)
            border.borderColor = Retro.green.withAlphaComponent(0.8).cgColor
            border.borderWidth = 2
            overlay.addSublayer(border)
        }

        overlay.shouldRasterize = true
        overlay.rasterizationScale = scale
        return overlay
    }

    // MARK: Updates (called by the app's timer)

    private var lastMinute = ""
    private var lastDate = ""
    private var lastJoke = ""
    private var lastElapsed = ""

    func tick(now: Date) {
        let time = now.timeIntervalSince1970

        // Typewriter joke with blinking block cursor.
        let jokeSeconds = 8.0
        let joke = Retro.jokes[Int(time / jokeSeconds) % Retro.jokes.count]
        let typed = String(joke.prefix(Int(time.truncatingRemainder(dividingBy: jokeSeconds) * 25)))
        let jokeText = "> " + typed + (Int(time * 2) % 2 == 0 ? "█" : " ")
        if jokeText != lastJoke {
            lastJoke = jokeText
            withoutAnimation { jokeLayer.string = jokeText }
        }

        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = String(format: "%02d%02d", parts.hour ?? 0, parts.minute ?? 0)
        if minute != lastMinute {
            lastMinute = minute
            withoutAnimation {
                clockHours.string = String(minute.prefix(2))
                clockMinutes.string = String(minute.suffix(2))
            }
        }

        let date = now.formatted(.dateTime.day().month(.wide).year().weekday(.wide).locale(Retro.turkish))
            .uppercased(with: Retro.turkish)
        if date != lastDate {
            lastDate = date
            withoutAnimation {
                dateLayer.string = date
                let size = Retro.size(of: date, font: Retro.font(18, .bold))
                dateLayer.frame = CGRect(x: dateRight - size.width, y: dateY, width: size.width, height: size.height)
            }
        }

        let seconds = Int(now.timeIntervalSince(lockedAt))
        let elapsed = seconds >= 3600
            ? String(format: "KİLİTLİ SÜRE: %d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "KİLİTLİ SÜRE: %d:%02d", seconds / 60, seconds % 60)
        if elapsed != lastElapsed {
            lastElapsed = elapsed
            withoutAnimation { elapsedLayer.string = elapsed }
        }
    }

    func rejectPassword(_ message: String, pause: TimeInterval) {
        guard let field = passwordField else { return }
        field.stringValue = ""
        field.isEnabled = false
        withoutAnimation { errorLayer.string = "!! \(message) !!" }
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
            field.isEnabled = true
            self?.window?.makeFirstResponder(field)
        }
    }

    @objc private func submitPassword() {
        guard let field = passwordField, !field.stringValue.isEmpty else { return }
        onPassword?(field.stringValue)
    }

    @objc private func useTouchID() {
        onTouchID?()
    }
}

/// Borderless windows refuse key status by default; the password field needs it.
final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem!
    private var assertionID: IOPMAssertionID = 0
    private var hotKeyRef: EventHotKeyRef?
    private var lockWindows: [NSWindow] = []
    private var lockViews: [LockScreenView] = []
    private var lockedAt: Date?
    private var tickTimer: Timer?
    private var authContext: LAContext?

    private var isLocked: Bool { lockedAt != nil }

    private let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.local.awakelock.plist")

    /// Kiosk mode: no Dock, menu bar, Cmd+Tab, Force Quit or logout while locked.
    private let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableAppleMenu, .disableProcessSwitching,
        .disableForceQuit, .disableSessionTermination, .disableHideApplication,
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(regainFocus),
            name: NSApplication.didResignActiveNotification, object: nil)

        if let seconds = ProcessInfo.processInfo.environment["AWAKELOCK_TEST_SECONDS"].flatMap(Double.init) {
            runSelfTest(seconds: seconds)
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        let lockItem = NSMenuItem(title: "Kilitle", action: #selector(lock), keyEquivalent: "l")
        lockItem.keyEquivalentModifierMask = [.control, .option, .command]
        lockItem.target = self
        menu.addItem(lockItem)
        menu.addItem(.separator())
        launchAtLoginItem = NSMenuItem(title: "Oturum açılınca başlat", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.image = NSImage(systemSymbolName: "lock", accessibilityDescription: "AwakeLock")
        item.button?.image?.isTemplate = true
        statusItem = item

        refreshLaunchAtLoginState()
        registerHotKey()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isLocked ? .terminateCancel : .terminateNow
    }

    // MARK: Lock / unlock

    @objc func lock() {
        guard !isLocked else { return }
        guard holdAwake() else {
            showError("Uyku engeli alınamadı, kilitleme iptal edildi.")
            return
        }
        lockedAt = Date()

        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = kioskOptions
        buildWindows()

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            let now = Date()
            self?.lockViews.forEach { $0.tick(now: now) }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func unlock() {
        tickTimer?.invalidate()
        tickTimer = nil
        authContext?.invalidate()
        authContext = nil
        lockWindows.forEach { $0.orderOut(nil) }
        lockWindows = []
        lockViews = []
        lockedAt = nil
        NSApp.presentationOptions = []
        releaseAwake()
    }

    /// One window per display; the password field goes on the menu bar display.
    private func buildWindows() {
        guard let lockedAt else { return }
        lockWindows.forEach { $0.orderOut(nil) }
        let touchID = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        lockViews = []
        lockWindows = NSScreen.screens.enumerated().map { index, screen in
            let primary = index == 0
            let view = LockScreenView(
                size: screen.frame.size, scale: screen.backingScaleFactor, lockedAt: lockedAt,
                onPassword: primary ? { [weak self] in self?.verifyPassword($0) } : nil,
                onTouchID: primary && touchID ? { [weak self] in self?.startTouchID() } : nil)
            lockViews.append(view)

            let window = LockWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }
        focusPasswordField()
    }

    private func focusPasswordField() {
        guard let window = lockWindows.first else { return }
        window.makeKeyAndOrderFront(nil)
        if let field = lockViews.first?.passwordField {
            window.makeFirstResponder(field)
        }
    }

    @objc private func screensChanged() {
        if isLocked { buildWindows() }
    }

    @objc private func regainFocus() {
        guard isLocked else { return }
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.focusPasswordField()
        }
    }

    // MARK: Authentication

    private func verifyPassword(_ password: String) {
        if checkPassword(password) {
            unlock()
        } else {
            // Short pause after a wrong password to slow down guessing.
            lockViews.first?.rejectPassword("HATALI ŞİFRE", pause: 2)
        }
    }

    private func checkPassword(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }

    private func startTouchID() {
        authContext?.invalidate()
        let context = LAContext()
        authContext = context
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "kilidi açmak") { success, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, success, self.authContext === context else { return }
                self.unlock()
            }
        }
    }

    // MARK: Sleep assertion

    /// Keeps the display (and therefore the system) awake, so neither sleep nor the
    /// screen saver can kick in and drop the running sessions.
    private func holdAwake() -> Bool {
        if assertionID != 0 { return true }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AwakeLock: kilitliyken uyanık tut" as CFString,
            &assertionID)
        return result == kIOReturnSuccess
    }

    private func releaseAwake() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    // MARK: Global hotkey (Ctrl+Option+Cmd+L), Carbon needs no Accessibility permission

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.lock() }
            return noErr
        }, 1, &eventType, selfPtr, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x41574C4B), id: 1) // "AWLK"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey | cmdKey),
                                         hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            showError("⌃⌥⌘L kısayolu kaydedilemedi (başka bir uygulama kullanıyor olabilir). Menüden kilitleyebilirsin.")
        }
    }

    // MARK: Launch at login (user LaunchAgent)

    @objc private func toggleLaunchAtLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentURL.path) {
            try? fm.removeItem(at: launchAgentURL)
        } else {
            let plist: [String: Any] = [
                "Label": "com.local.awakelock",
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            do {
                try fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: launchAgentURL)
            } catch {
                showError("Oturum açılış ayarı yazılamadı: \(error.localizedDescription)")
            }
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "AwakeLock"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Self-test (AWAKELOCK_TEST_SECONDS=N): lock, wrong password, auto-unlock and quit

    private func runSelfTest(seconds: Double) {
        print("wrong password rejected:", !checkPassword("definitely-not-the-password"))
        lock()
        print("locked, windows:", lockWindows.count, "assertion:", assertionID != 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.verifyPassword("wrong-password") }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.unlock()
            print("unlocked, assertion released:", self?.assertionID == 0)
            exit(0)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
