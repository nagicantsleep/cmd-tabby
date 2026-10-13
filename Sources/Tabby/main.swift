import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit

private let tabKeyCode: Int64 = 48
private let escapeKeyCode: Int64 = 53

/// Private but long-stable Accessibility SPI that maps an `AXUIElement` window
/// to its CoreGraphics window id. This is the only exact way to tell sibling
/// windows of the same app apart (title and frame can both collide), so it is
/// tried first when resolving a window to its AX element.
@_silgen_name("_AXUIElementGetWindow")
private func AXUIElementGetWindowID(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// How the switcher renders each window when Command-Tab is pressed.
private enum PreviewMode: Int, CaseIterable {
    case preview = 0      // full screenshot of the selected window
    case blurred = 1      // screenshot, blurred
    case iconOnly = 2     // app icon only, no capture

    var title: String {
        switch self {
        case .preview: return "Window preview"
        case .blurred: return "Blurred preview"
        case .iconOnly: return "Icon only"
        }
    }

    static let defaultsKey = "PreviewMode"

    static func current(_ defaults: UserDefaults = .standard) -> PreviewMode {
        PreviewMode(rawValue: defaults.integer(forKey: defaultsKey)) ?? .preview
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: PreviewMode.defaultsKey)
    }
}

/// Per-window actions offered by the buttons in each cell's header.
private enum SwitcherAction {
    case quit       // terminate the whole application (power)
    case close      // close this window (red)
    case minimize   // minimize this window (yellow)
    case maximize   // zoom this window (green)

    var symbolName: String {
        switch self {
        case .quit: return "power"
        case .close: return "xmark"
        case .minimize: return "minus"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var color: NSColor {
        switch self {
        case .quit: return NSColor(calibratedRed: 0.44, green: 0.46, blue: 0.53, alpha: 1)
        case .close: return NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.32, alpha: 1)
        case .minimize: return NSColor(calibratedRed: 0.97, green: 0.76, blue: 0.20, alpha: 1)
        case .maximize: return NSColor(calibratedRed: 0.30, green: 0.79, blue: 0.34, alpha: 1)
        }
    }

    /// Glyph colour drawn on top of the coloured circle. Bright traffic-light
    /// colours take a dark glyph (as macOS does); the neutral quit button takes
    /// a white glyph so it reads as a button rather than a smudge.
    var glyphColor: NSColor {
        switch self {
        case .quit: return NSColor(calibratedWhite: 1.0, alpha: 1)
        default: return NSColor(calibratedWhite: 0.13, alpha: 1)
        }
    }
}

/// A clickable action button laid out inside a cell header.
private struct CellButton {
    let action: SwitcherAction
    let rect: NSRect
    let index: Int
    let windowID: CGWindowID
}

private struct SwitchableWindow {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let icon: NSImage?
}

private protocol EventTapDelegate: AnyObject {
    func commandTabPressed(backwards: Bool)
    func commandReleased()
    func escapePressed()
    /// Handles a physical mouse-down that arrives while the switcher is open.
    /// Returns `true` when the event landed on a header action button and was
    /// consumed; `false` lets it pass through to the panel as usual.
    func mouseDown(atGlobalPoint point: CGPoint) -> Bool
}

fileprivate enum EventTapStatus: Equatable {
    case idle
    case waitingForInputMonitoring
    case creating
    case active
    case disabled
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Not started"
        case .waitingForInputMonitoring: return "Input Monitoring required"
        case .creating: return "Starting…"
        case .active: return "Active"
        case .disabled: return "Disabled; retrying"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

private final class EventTapController {
    weak var delegate: EventTapDelegate?
    private var tap: CFMachPort?
    private var isSwitching = false
    /// True when the tap consumed a mouse-down that hit an action button, so the
    /// matching mouse-up must be swallowed too.
    private var swallowedMouseDown = false
    fileprivate private(set) var status: EventTapStatus = .idle
    fileprivate var displayedStatus: EventTapStatus {
        guard let enabled = tap.map({ CGEvent.tapIsEnabled(tap: $0) }) else {
            return status
        }
        return enabled ? .active : .disabled
    }


    func requestAccess() {
        guard CGPreflightListenEventAccess() else {
            status = .waitingForInputMonitoring
            _ = CGRequestListenEventAccess()
            return
        }
        if tap == nil {
            status = .idle
        }
    }

    func start() {
        guard tap == nil else { return }
        guard CGPreflightListenEventAccess() else {
            status = .waitingForInputMonitoring
            return
        }

        status = .creating
        var mask: CGEventMask = 0
        mask |= CGEventMask(1) << CGEventType.keyDown.rawValue
        mask |= CGEventMask(1) << CGEventType.keyUp.rawValue
        mask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue
        mask |= CGEventMask(1) << CGEventType.leftMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.leftMouseUp.rawValue

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            status = .failed("CGEvent.tapCreate returned nil")
            return
        }

        tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        status = CGEvent.tapIsEnabled(tap: newTap) ? .active : .disabled
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                status = CGEvent.tapIsEnabled(tap: tap) ? .active : .disabled
            } else {
                status = .failed("event tap was disabled")
            }

            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let commandDown = event.flags.contains(.maskCommand)

        // A click while the switcher is open must reach the panel even though it
        // is a non-activating, non-key window. Routing it through the tap is the
        // only reliable delivery path, so consume the event when it hits a
        // header action button.
        if type == .leftMouseDown, isSwitching {
            let point = event.location
            if delegate?.mouseDown(atGlobalPoint: point) == true {
                swallowedMouseDown = true
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseUp, swallowedMouseDown {
            swallowedMouseDown = false
            return nil
        }

        if type == .keyDown, keyCode == escapeKeyCode, isSwitching {
            isSwitching = false
            swallowedMouseDown = false
            delegate?.escapePressed()
            return nil
        }

        if type == .keyDown, keyCode == tabKeyCode, commandDown {
            let backwards = event.flags.contains(.maskShift)
            if !isSwitching {
                isSwitching = true
            }
            delegate?.commandTabPressed(backwards: backwards)
            return nil
        }

        if type == .keyUp, keyCode == tabKeyCode, isSwitching {
            return nil
        }

        if type == .flagsChanged, isSwitching, !commandDown {
            isSwitching = false
            swallowedMouseDown = false
            delegate?.commandReleased()
        }

        return Unmanaged.passUnretained(event)
    }

    fileprivate func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = nil
        status = .idle
    }
}

private func eventTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

private final class WindowCatalog {
    func windows() -> [SwitchableWindow] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        return rawWindows.compactMap { raw in
            guard
                let ownerPID = (raw[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                ownerPID != ownPID,
                let ownerName = raw[kCGWindowOwnerName as String] as? String,
                (raw[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                (raw[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                (raw[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                let windowID = (raw[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let boundsValue = raw[kCGWindowBounds as String] as? NSDictionary
            else {
                return nil
            }

            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsValue, &bounds), bounds.width >= 80, bounds.height >= 60 else {
                return nil
            }

            let title = (raw[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Window"
            let icon = NSRunningApplication(processIdentifier: ownerPID)?.icon
            return SwitchableWindow(
                id: windowID,
                pid: ownerPID,
                appName: ownerName,
                title: title,
                bounds: bounds,
                icon: icon
            )
        }
    }

    func frontmostIndex(in windows: [SwitchableWindow]) -> Int? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return windows.firstIndex { $0.pid == pid }
    }
}

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Grid geometry for the switcher panel. Cells are laid out top-left first in
/// reading order so every window gets a fixed slot; the highlight moves with
/// the selection instead of the list scrolling underneath it.
private struct SwitcherLayout {
    let columns: Int
    let rows: Int
    let cell: NSSize
    let panel: NSSize
    let padding: CGFloat
    let gap: CGFloat
    let barHeight: CGFloat

    static func compute(count: Int, maxSize: NSSize) -> SwitcherLayout {
        let padding: CGFloat = 20
        let gap: CGFloat = 12
        let bar: CGFloat = 36
        let baseW: CGFloat = 210
        let baseH: CGFloat = 158

        func build(_ cw: CGFloat, _ ch: CGFloat) -> SwitcherLayout? {
            // Score every grid that fits and keep the one with the fewest empty
            // slots; break ties toward fewer rows (flatter), then more columns.
            var best: (score: Int, rows: Int, columns: Int, size: NSSize)?
            for cols in 1...max(1, count) {
                let rows = Int(ceil(Double(count) / Double(cols)))
                let w = padding * 2 + CGFloat(cols) * cw + CGFloat(cols - 1) * gap
                let h = padding * 2 + bar + gap + CGFloat(rows) * ch + CGFloat(rows - 1) * gap
                guard w <= maxSize.width, h <= maxSize.height else { continue }
                let empty = rows * cols - count
                let candidate = (score: empty, rows: rows, columns: cols, size: NSSize(width: w, height: h))
                if let current = best {
                    let better = empty < current.score
                        || (empty == current.score && rows < current.rows)
                        || (empty == current.score && rows == current.rows && cols > current.columns)
                    if !better { continue }
                }
                best = candidate
            }
            guard let best else { return nil }
            return SwitcherLayout(columns: best.columns, rows: best.rows, cell: NSSize(width: cw, height: ch),
                                  panel: best.size, padding: padding, gap: gap, barHeight: bar)
        }

        if let layout = build(baseW, baseH) { return layout }
        var scale: CGFloat = 0.9
        while scale > 0.35 {
            if let layout = build(baseW * scale, baseH * scale) { return layout }
            scale -= 0.08
        }
        return build(baseW * 0.35, baseH * 0.35)
            ?? SwitcherLayout(columns: 1, rows: max(1, count), cell: NSSize(width: baseW * 0.35, height: baseH * 0.35),
                              panel: maxSize, padding: padding, gap: gap, barHeight: bar)
    }

    func cellRect(_ index: Int, in bounds: NSRect) -> NSRect {
        let column = index % columns
        let row = index / columns
        let gridWidth = CGFloat(columns) * cell.width + CGFloat(columns - 1) * gap
        let originX = (bounds.width - gridWidth) / 2
        let gridTop = bounds.height - padding
        let y = gridTop - cell.height - CGFloat(row) * (cell.height + gap)
        let x = originX + CGFloat(column) * (cell.width + gap)
        return NSRect(x: x, y: y, width: cell.width, height: cell.height)
    }
}

private final class SwitcherView: NSView {
    var windows: [SwitchableWindow] = [] {
        didSet { needsDisplay = true }
    }
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }
    var previews: [CGWindowID: NSImage] = [:] {
        didSet { needsDisplay = true }
    }
    var screenCaptureAllowed = false {
        didSet { needsDisplay = true }
    }
    var previewMode: PreviewMode = .preview {
        didSet { needsDisplay = true }
    }
    var maxPanelSize = NSSize(width: 1400, height: 900) {
        didSet { needsDisplay = true }
    }

    /// Hit regions for the per-cell action buttons, rebuilt on every draw.
    private var cellButtons: [CellButton] = []
    var onAction: ((SwitcherAction, Int, CGWindowID) -> Void)?

    var layout: SwitcherLayout {
        SwitcherLayout.compute(count: max(1, windows.count), maxSize: maxPanelSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let panelRect = bounds.insetBy(dx: 1, dy: 1)
        NSColor(calibratedWhite: 0.055, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: panelRect, xRadius: 18, yRadius: 18).fill()

        guard !windows.isEmpty else {
            drawMessage("No switchable windows found.")
            return
        }

        let layout = self.layout
        cellButtons.removeAll(keepingCapacity: true)
        for (index, window) in windows.enumerated() {
            drawCell(for: window, in: layout.cellRect(index, in: bounds), selected: index == selectedIndex, layout: layout, index: index)
        }

        // Bottom bar: selected window title on the left, key hint on the right.
        if windows.indices.contains(selectedIndex) {
            let selected = windows[selectedIndex]
            drawText(selected.title, at: NSPoint(x: layout.padding, y: layout.padding + 8), font: .systemFont(ofSize: 12, weight: .medium), color: .white, maxWidth: bounds.width / 2 - layout.padding)
            drawText(selected.appName, at: NSPoint(x: layout.padding, y: layout.padding - 8), font: .systemFont(ofSize: 11), color: .secondaryLabelColor, maxWidth: bounds.width / 2 - layout.padding)
        }
        drawText("Release ⌘ to switch  •  Esc to cancel", at: NSPoint(x: bounds.width - layout.padding, y: layout.padding - 2), font: .systemFont(ofSize: 12), color: .secondaryLabelColor, alignment: .right)
    }

    private func drawCell(for window: SwitchableWindow, in rect: NSRect, selected: Bool, layout: SwitcherLayout, index: Int) {
        NSColor(calibratedWhite: selected ? 0.24 : 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        if selected {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            border.lineWidth = 3
            border.stroke()
        }

        // Header sits on TOP (AppKit origin is bottom-left, so top == maxY);
        // the preview fills everything below it, so the cell has no dead space.
        let headerHeight: CGFloat = 24
        let headerRect = NSRect(x: rect.minX + 6, y: rect.maxY - headerHeight, width: rect.width - 12, height: headerHeight)
        let imageRect = NSRect(x: rect.minX + 6, y: rect.minY + 6, width: rect.width - 12, height: rect.height - headerHeight - 12)
        NSColor(calibratedWhite: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6).fill()

        switch previewMode {
        case .iconOnly:
            drawLargeIcon(window.icon, in: imageRect)
        case .preview, .blurred:
            if let preview = previews[window.id] {
                drawImage(preview, in: imageRect.insetBy(dx: 2, dy: 2))
            } else if selected, !screenCaptureAllowed {
                drawMessage("Allow Screen Recording", in: imageRect)
            } else {
                drawLargeIcon(window.icon, in: imageRect.insetBy(dx: imageRect.width * 0.25, dy: imageRect.height * 0.25))
            }
        }

        // App icon + name on the left of the header.
        let iconSize: CGFloat = 14
        var textX = headerRect.minX
        if let icon = window.icon {
            icon.draw(in: NSRect(x: headerRect.minX, y: headerRect.midY - iconSize / 2, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1)
            textX += iconSize + 4
        }
        drawText(window.appName, at: NSPoint(x: textX, y: headerRect.midY - 7), font: .systemFont(ofSize: 10, weight: .medium), color: .white, maxWidth: max(20, rect.width - (textX - rect.minX) - buttonRowWidth - 12))

        // Action buttons on the right of the header.
        for button in actionButtons(in: headerRect, index: index, windowID: window.id) {
            cellButtons.append(button)
            drawActionButton(button.action, in: button.rect)
        }
    }

    private var buttonRowWidth: CGFloat { 4 * 18 + 3 * 4 }

    private func actionButtons(in headerRect: NSRect, index: Int, windowID: CGWindowID) -> [CellButton] {
        let order: [SwitcherAction] = [.quit, .close, .minimize, .maximize]
        let size: CGFloat = 18
        let spacing: CGFloat = 4
        var buttons: [CellButton] = []
        var x = headerRect.maxX - CGFloat(order.count) * size - CGFloat(order.count - 1) * spacing
        for action in order {
            let rect = NSRect(x: x, y: headerRect.midY - size / 2, width: size, height: size)
            buttons.append(CellButton(action: action, rect: rect, index: index, windowID: windowID))
            x += size + spacing
        }
        return buttons
    }

    private func drawActionButton(_ action: SwitcherAction, in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect)

        // Soft vertical gradient gives the dot a subtle glassy look instead of
        // a flat fill.
        let base = action.color
        let top = base.blended(withFraction: 0.28, of: .white) ?? base
        let bottom = base.blended(withFraction: 0.18, of: .black) ?? base
        if let gradient = NSGradient(starting: top, ending: bottom) {
            gradient.draw(in: circle, angle: -90)
        } else {
            base.setFill()
            circle.fill()
        }

        // Hairline rim keeps the edge crisp on the dark panel.
        (base.blended(withFraction: 0.35, of: .black) ?? base).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        // Symbol glyph, configured to a fixed point size with a bold weight so
        // it stays sharp and centred rather than stretching with the rect.
        let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.5, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [action.glyphColor]))
        guard let symbol = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let inset = rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.26)
        symbol.draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawLargeIcon(_ icon: NSImage?, in rect: NSRect) {
        guard let icon else { return }
        let side = min(rect.width, rect.height) * 0.6
        let target = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        icon.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// Buttons live inside the panel, which is `ignoresMouseEvents = false`
    /// only while a button is under the pointer (see WindowSwitcher.trackMouse).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = cellButtons.first(where: { $0.rect.contains(point) }) else { return }
        onAction?(hit.action, hit.index, hit.windowID)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func button(at point: NSPoint) -> CellButton? {
        cellButtons.first { $0.rect.contains(point) }
    }

    /// The index of the cell containing `point`, if any. Used so a click
    /// anywhere on a window's tile switches straight to that window.
    func cellIndex(at point: NSPoint) -> Int? {
        guard !windows.isEmpty else { return nil }
        let layout = self.layout
        for index in windows.indices where layout.cellRect(index, in: bounds).contains(point) {
            return index
        }
        return nil
    }

    private func drawImage(_ image: NSImage, in rect: NSRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let imageRect = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    private func drawMessage(_ message: String, in rect: NSRect? = nil) {
        let target = rect ?? bounds
        drawText(message, at: NSPoint(x: target.midX, y: target.midY - 6), font: .systemFont(ofSize: 13), color: .secondaryLabelColor, alignment: .center, maxWidth: target.width - 24)
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left, maxWidth: CGFloat = .greatestFiniteMagnitude) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let natural = attributed.size()
        let width = min(ceil(natural.width) + 1, maxWidth)
        let originX: CGFloat
        switch alignment {
        case .center: originX = point.x - width / 2
        case .right: originX = point.x - width
        default: originX = point.x
        }
        attributed.draw(in: NSRect(x: originX, y: point.y, width: width, height: ceil(natural.height)))
    }
}

private final class WindowSwitcher: EventTapDelegate {
    private let catalog = WindowCatalog()
    private let panel: SwitcherPanel
    private let switcherView: SwitcherView
    private var windows: [SwitchableWindow] = []
    private var selectedIndex = 0
    private var captureGeneration = 0
    private var previewCache: [CGWindowID: NSImage] = [:]
    private var previewMode: PreviewMode = .current()
    /// Set when a header action ran during this session, so releasing ⌘ hides
    /// the panel instead of activating the (possibly just-closed) selection.
    private var didPerformAction = false
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init() {
        switcherView = SwitcherView(frame: NSRect(x: 0, y: 0, width: 920, height: 260))
        panel = SwitcherPanel(
            contentRect: switcherView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = switcherView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        switcherView.onAction = { [weak self] action, index, windowID in
            self?.perform(action, at: index, windowID: windowID)
        }
    }

    func commandTabPressed(backwards: Bool) {
        runOnMain { [weak self] in
            guard let self else { return }
            if !self.isVisible {
                self.begin(backwards: backwards)
            } else {
                self.cycle(backwards: backwards)
            }
        }
    }

    func commandReleased() {
        runOnMain { [weak self] in self?.commit() }
    }

    func escapePressed() {
        runOnMain { [weak self] in self?.cancel() }
    }

    /// Routes a physical click to the header action buttons and to the window
    /// tiles. `CGEvent.location` is measured from the top-left of the primary
    /// display while AppKit uses the bottom-left, so the point is flipped
    /// against the primary display's height before hit-testing.
    func mouseDown(atGlobalPoint point: CGPoint) -> Bool {
        guard panel.isVisible else { return false }
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main ?? NSScreen.screens.first
        let primaryHeight = primary?.frame.height ?? 0
        let appKitPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        let windowPoint = panel.convertPoint(fromScreen: appKitPoint)
        let viewPoint = switcherView.convert(windowPoint, from: nil)

        // Header action buttons take priority: they sit inside the cell.
        if let hit = switcherView.button(at: viewPoint) {
            let action = hit.action, index = hit.index, windowID = hit.windowID
            runOnMain { [weak self] in
                self?.perform(action, at: index, windowID: windowID)
            }
            return true
        }

        // A click anywhere else on a tile switches straight to that window and
        // dismisses the grid (a deliberate click is a commit, not a hover).
        if let index = switcherView.cellIndex(at: viewPoint), windows.indices.contains(index) {
            let window = windows[index]
            runOnMain { [weak self] in
                guard let self else { return }
                self.panel.orderOut(nil)
                self.activate(window)
            }
            return true
        }

        return false
    }

    private var isVisible: Bool { panel.isVisible }

    private func begin(backwards: Bool) {
        previewMode = .current()
        previewCache.removeAll()
        captureGeneration += 1
        didPerformAction = false
        windows = catalog.windows()
        guard !windows.isEmpty else {
            switcherView.windows = []
            positionPanel()
            panel.orderFrontRegardless()
            return
        }

        let current = catalog.frontmostIndex(in: windows) ?? 0
        selectedIndex = (current + (backwards ? windows.count - 1 : 1)) % windows.count
        updateView()
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func cycle(backwards: Bool) {
        guard !windows.isEmpty else { return }
        // Navigating after an action means the user moved on; a normal ⌘-release
        // should activate the newly selected window again.
        didPerformAction = false
        selectedIndex = (selectedIndex + (backwards ? windows.count - 1 : 1)) % windows.count
        updateView()
    }

    private func commit() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // If a header action already ran this session, ⌘-release must only
        // dismiss the grid — never activate the window we just closed or
        // minimized.
        guard !didPerformAction else { return }
        guard windows.indices.contains(selectedIndex) else { return }
        activate(windows[selectedIndex])
    }

    private func cancel() {
        panel.orderOut(nil)
    }

    private func updateView() {
        switcherView.windows = windows
        switcherView.selectedIndex = selectedIndex
        switcherView.screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        switcherView.previewMode = previewMode
        switcherView.previews = previewCache
        guard previewMode != .iconOnly, !windows.isEmpty else { return }
        captureAll(generation: captureGeneration)
    }

    /// Captures every window that does not have a cached preview yet. One
    /// SCShareableContent fetch feeds all captures; results stream in and the
    /// grid repaints as each arrives.
    private func captureAll(generation: Int) {
        let pending = windows.filter { previewCache[$0.id] == nil }
        guard !pending.isEmpty else { return }

        if #available(macOS 14.0, *) {
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, _ in
                guard let self, let content else { return }
                for window in pending {
                    guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else { continue }
                    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    let config = SCStreamConfiguration()
                    // The preview cell is small; a modest cap keeps captures cheap
                    // so the whole grid fills quickly without stutter.
                    let maxDimension: CGFloat = 640
                    let frame = scWindow.frame
                    let scale = min(2, maxDimension / max(frame.width, frame.height, 1))
                    config.width = max(1, Int(frame.width * scale))
                    config.height = max(1, Int(frame.height * scale))
                    config.showsCursor = false
                    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, _ in
                        guard let self, let image else { return }
                        let preview = self.makePreview(from: image)
                        self.runOnMain {
                            guard generation == self.captureGeneration else { return }
                            self.previewCache[window.id] = preview
                            self.switcherView.previews = self.previewCache
                        }
                    }
                }
            }
            return
        }

        var captured: [CGWindowID: NSImage] = [:]
        for window in pending {
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, window.id, [.bestResolution, .boundsIgnoreFraming]) else { continue }
            captured[window.id] = makePreview(from: image)
        }
        runOnMain {
            guard generation == self.captureGeneration else { return }
            for (id, image) in captured { self.previewCache[id] = image }
            self.switcherView.previews = self.previewCache
        }
    }

    private func makePreview(from image: CGImage) -> NSImage {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard previewMode == .blurred else { return nsImage }
        let ciImage = CIImage(cgImage: image)
        let blurred = ciImage.clampedToExtent().applyingGaussianBlur(sigma: 18)
        guard let output = Self.ciContext.createCGImage(blurred, from: ciImage.extent) else { return nsImage }
        return NSImage(cgImage: output, size: NSSize(width: image.width, height: image.height))
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        switcherView.maxPanelSize = NSSize(width: max(420, visible.width - 80), height: max(320, visible.height - 80))
        let size = switcherView.layout.panel
        switcherView.setFrameSize(size)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }

    /// Runs a header action against the window identified by `windowID`. Quit
    /// terminates the whole app; the rest act on the single window through the
    /// AX API. The id is resolved against the live catalog so a stale index can
    /// never hit the wrong window.
    private func perform(_ action: SwitcherAction, at index: Int, windowID: CGWindowID) {
        let window = WindowCatalog().windows().first { $0.id == windowID }
            ?? (windows.indices.contains(index) && windows[index].id == windowID ? windows[index] : nil)
        guard let window else {
            // The window is already gone; refresh so the grid reflects reality
            // and stay open in case ⌘ is still held.
            didPerformAction = true
            refreshAfterAction()
            return
        }
        switch action {
        case .quit:
            NSRunningApplication(processIdentifier: window.pid)?.terminate()
        case .close:
            if let axWindow = axWindow(for: window),
               let button = Self.elementAttribute(axWindow, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        case .minimize:
            if let axWindow = axWindow(for: window) {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        case .maximize:
            if let axWindow = axWindow(for: window),
               let button = Self.elementAttribute(axWindow, kAXZoomButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        }
        // Keep the grid on screen while ⌘ is still held; releasing ⌘ then just
        // dismisses it instead of activating the window we just acted on.
        didPerformAction = true
        refreshAfterAction()
    }

    /// Re-reads the window list after a header action so closed, quit or
    /// minimized windows disappear from the grid, then keeps the panel visible.
    /// A second pass runs shortly after because quit and close are asynchronous
    /// and the window may still be listed on the first read.
    private func refreshAfterAction() {
        applyRefreshedWindows()
        runOnMain(after: 0.45) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.applyRefreshedWindows()
        }
    }

    private func applyRefreshedWindows() {
        let previousID = windows.indices.contains(selectedIndex) ? windows[selectedIndex].id : nil
        windows = catalog.windows()
        if let previousID, let newIndex = windows.firstIndex(where: { $0.id == previousID }) {
            selectedIndex = newIndex
        } else if !windows.isEmpty {
            selectedIndex = min(selectedIndex, windows.count - 1)
        } else {
            selectedIndex = 0
        }
        previewCache = previewCache.filter { id, _ in windows.contains { $0.id == id } }
        updateView()
        if windows.isEmpty {
            panel.orderOut(nil)
        } else {
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    /// Returns an `AXUIElement` attribute without force-casting, so a missing
    /// or unexpected attribute can never crash the switcher.
    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Finds the AX window matching a captured window. `AXWindowNumber` is
    /// unsupported by many apps (returns -25205), so matching falls back to the
    /// window frame and title. The frame is checked first because it is the most
    /// reliable discriminator between same-app siblings.
    private func axWindow(for window: SwitchableWindow) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID() else {
            return nil
        }
        let array = value as! CFArray
        var axWindows: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            axWindows.append(Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue())
        }
        guard !axWindows.isEmpty else { return nil }

        // 1. Exact match via the AX→CGWindowID SPI. This is authoritative, so
        //    it is the only reliable way to disambiguate same-app siblings.
        for axWindow in axWindows {
            var candidateID: CGWindowID = 0
            if AXUIElementGetWindowID(axWindow, &candidateID) == .success, candidateID == window.id {
                return axWindow
            }
        }

        // 2. Exact match on AXWindowNumber where the app supports it.
        for axWindow in axWindows {
            var idValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, "AXWindowNumber" as CFString, &idValue) == .success,
               let id = idValue as? NSNumber, id.uint32Value == window.id {
                return axWindow
            }
        }

        // 2. Match by title. Titles distinguish sibling windows far more
        //    reliably than position: two maximized windows of the same app
        //    share the same frame, so a position match would resolve both
        //    siblings to the same AX element (and the second window could
        //    never be raised). Skip the generic placeholder title.
        if window.title != "Window" {
            let titleMatches = axWindows.filter { axWindow -> Bool in
                var titleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
                      let title = titleValue as? String else { return false }
                return title == window.title
            }
            if titleMatches.count == 1 { return titleMatches[0] }
        }

        // 3. Match by frame position, but only when it is unambiguous.
        //    CGWindow bounds and AX position share a top-left global origin.
        let positionMatches = axWindows.filter { axWindow -> Bool in
            var positionValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
                  let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID() else { return false }
            var point = CGPoint.zero
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point) else { return false }
            return abs(point.x - window.bounds.minX) <= 2 && abs(point.y - window.bounds.minY) <= 2
        }
        if positionMatches.count == 1 { return positionMatches[0] }

        return axWindows.count == 1 ? axWindows[0] : nil
    }

    private func activate(_ window: SwitchableWindow) {
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateIgnoringOtherApps])

        guard let axWindow = axWindow(for: window) else { return }
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    private func runOnMain(after delay: TimeInterval, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
}


private final class PermissionView: NSView {
    private let eventTap: EventTapController
    private let eventTapStatus = NSTextField(labelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let inputMonitoringStatus = NSTextField(labelWithString: "")
    private let screenRecordingStatus = NSTextField(labelWithString: "")
    private var refreshTimer: Timer?

    init(frame frameRect: NSRect, eventTap: EventTapController) {
        self.eventTap = eventTap
        super.init(frame: frameRect)
        setup()
    }

    override init(frame frameRect: NSRect) {
        fatalError("PermissionView requires an EventTapController")
    }

    required init?(coder: NSCoder) {
        fatalError("PermissionView requires an EventTapController")
    }


    private func setup() {
        let title = NSTextField(labelWithString: "Tabby Window Switcher")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: "Tabby uses Input Monitoring to observe Command-Tab, Accessibility to raise the selected window, and Screen Recording for previews.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let accessibilityButton = NSButton(title: "Open Settings", target: self, action: #selector(openAccessibility))
        let inputButton = NSButton(title: "Open Settings", target: self, action: #selector(openInputMonitoring))
        let screenButton = NSButton(title: "Open Settings", target: self, action: #selector(openScreenRecording))
        let requestButton = NSButton(title: "Request Permissions", target: self, action: #selector(requestPermissions))
        requestButton.keyEquivalent = "\r"

        for status in [eventTapStatus, accessibilityStatus, inputMonitoringStatus, screenRecordingStatus] {
            status.alignment = .right
            status.font = .systemFont(ofSize: 13, weight: .medium)
        }

        let tapRow = makeStatusRow(label: "Command-Tab event tap", status: eventTapStatus)
        let accessibilityRow = makeRow(label: "Accessibility · raise selected window", status: accessibilityStatus, button: accessibilityButton)
        let inputRow = makeRow(label: "Input Monitoring · observe Command-Tab", status: inputMonitoringStatus, button: inputButton)
        let screenRow = makeRow(label: "Screen Recording · window previews", status: screenRecordingStatus, button: screenButton)
        let stack = NSStackView(views: [title, subtitle, tapRow, accessibilityRow, inputRow, screenRow, requestButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -26),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tapRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accessibilityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            screenRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func makeStatusRow(label: String, status: NSTextField) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        let row = NSStackView(views: [labelField, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        status.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func makeRow(label: String, status: NSTextField, button: NSButton) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        let row = NSStackView(views: [labelField, status, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        status.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    @objc private func openAccessibility() {
        openPrivacyPane("Privacy_Accessibility")
    }

    @objc private func openInputMonitoring() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    @objc private func openScreenRecording() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    @objc private func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = CGRequestListenEventAccess()
        _ = CGRequestScreenCaptureAccess()
        // CGRequestScreenCaptureAccess() never prompts (tccd: "does not allow
        // prompting") and does not register the app. A real capture attempt is
        // what makes macOS add the app to System Settings > Screen Recording,
        // so fire one throwaway SCK query here.
        if #available(macOS 14.0, *) {
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { _, _ in }
        }
        eventTap.start()
        refresh()
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refresh() {
        let tapStatus = eventTap.displayedStatus
        update(eventTapStatus, text: tapStatus.label, good: tapStatus == .active)
        let accessibilityGranted = AXIsProcessTrusted()
        update(accessibilityStatus, text: accessibilityGranted ? "Granted" : "Not granted", good: accessibilityGranted)
        let inputMonitoringGranted = CGPreflightListenEventAccess()
        update(inputMonitoringStatus, text: inputMonitoringGranted ? "Granted" : "Not granted", good: inputMonitoringGranted)
        let screenRecordingGranted = CGPreflightScreenCaptureAccess()
        update(screenRecordingStatus, text: screenRecordingGranted ? "Granted" : "Not granted", good: screenRecordingGranted)
    }

    private func update(_ status: NSTextField, text: String, good: Bool) {
        status.stringValue = text
        status.textColor = good ? .systemGreen : .systemOrange
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let eventTap = EventTapController()
    private let switcher = WindowSwitcher()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        eventTap.delegate = switcher
        setupStatusItem()
        eventTap.requestAccess()
        eventTap.start()
        registerForScreenRecording()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.eventTap.start()
        }
    }

    /// A real capture attempt is what makes macOS list the app under
    /// System Settings > Screen Recording (tccd refuses to prompt for
    /// kTCCServiceScreenCapture on its own). Fire one throwaway SCK query so
    /// the app is discoverable and grantable without waiting for a first
    /// Command-Tab.
    private func registerForScreenRecording() {
        guard #available(macOS 14.0, *) else { return }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { _, _ in }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        eventTap.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Tabby Window Switcher")
        statusItem.button?.toolTip = "Tabby Window Switcher"

        let menu = NSMenu()
        let previewItem = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        let previewMenu = NSMenu()
        for mode in PreviewMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectPreviewMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = PreviewMode.current() == mode ? .on : .off
            previewMenu.addItem(item)
        }
        previewItem.submenu = previewMenu
        menu.addItem(previewItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Permissions…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Tabby", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func selectPreviewMode(_ sender: NSMenuItem) {
        guard let mode = PreviewMode(rawValue: sender.tag) else { return }
        mode.save()
        for item in sender.menu?.items ?? [] {
            item.state = item.tag == mode.rawValue ? .on : .off
        }
    }

    @MainActor @objc private func showSettings() {
        if settingsWindow == nil {
            let content = PermissionView(frame: NSRect(x: 0, y: 0, width: 680, height: 400), eventTap: eventTap)
            let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Tabby Permissions"
            window.contentView = content
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
