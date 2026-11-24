import AppKit
import CoreGraphics
import SwiftUI

/// Borderless Obsidian Island panel supporting BOTH:
/// 1) Bottom-right draggable floating micro-island (default)
/// 2) Top-bezel physical MacBook notch island (optional 1-click toggle)
final class NotchPanel: NSPanel {
    var allowsKeyFocus = false
    var allowsDrag = true
    var onEscape: (() -> Void)?
    var onMouseDownCollapsed: (() -> Void)?
    var onTapCollapsed: (() -> Void)?
    var onRightClickNotch: ((NSEvent) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragFinished: ((NSPoint) -> Void)?

    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var isDragging = false

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        guard !allowsKeyFocus else {
            super.sendEvent(event)
            return
        }

        switch event.type {
        case .leftMouseDown:
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = frame.origin
            isDragging = false
            onMouseDownCollapsed?()
            return
        case .leftMouseDragged:
            guard allowsDrag else { return }
            let cur = NSEvent.mouseLocation
            let dx = cur.x - dragStartMouse.x
            let dy = cur.y - dragStartMouse.y
            if !isDragging && hypot(dx, dy) > 3.5 {
                isDragging = true
                NSCursor.closedHand.set()
                onDragBegan?()
            }
            if isDragging {
                setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
            }
            return
        case .leftMouseUp:
            if isDragging {
                isDragging = false
                NSCursor.pointingHand.set()
                snapToVisibleEdgeIfClose()
                onDragFinished?(frame.origin)
            } else {
                onTapCollapsed?()
            }
            return
        case .rightMouseUp:
            onRightClickNotch?(event)
            return
        default:
            super.sendEvent(event)
        }
    }

    private func snapToVisibleEdgeIfClose() {
        guard let screen = (self.screen ?? NSScreen.main)?.visibleFrame else { return }
        let threshold: CGFloat = 18
        let margin: CGFloat = 16
        var origin = frame.origin

        if abs(origin.x - screen.minX) < threshold {
            origin.x = screen.minX + margin
        } else if abs((origin.x + frame.width) - screen.maxX) < threshold {
            origin.x = screen.maxX - frame.width - margin
        }

        if abs(origin.y - screen.minY) < threshold {
            origin.y = screen.minY + margin
        } else if abs((origin.y + frame.height) - screen.maxY) < threshold {
            origin.y = screen.maxY - frame.height - margin
        }

        origin.x = max(screen.minX + 8, min(origin.x, screen.maxX - frame.width - 8))
        origin.y = max(screen.minY + 8, min(origin.y, screen.maxY - frame.height - 8))
        setFrameOrigin(origin)
    }
}

/// Transparent wrapper providing `.activeAlways` hover tracking even when Antigravity is frontmost.
final class NotchTrackingContainerView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let vm = HUDViewModel()
    private var notchPanel: NotchPanel!
    private var containerView: NotchTrackingContainerView!
    private var hostingView: NSHostingView<DynamicNotchRootView>!
    private var hostingConstraints: [NSLayoutConstraint] = []
    private var statusItem: NSStatusItem!

    /// Saved collapsed origin (computed live from Antigravity window bottom-right + user offset)
    private var floatingAnchorOrigin: NSPoint = .zero
    private var relativeInsetRight: CGFloat = 16
    private var relativeInsetBottom: CGFloat = 14
    private var lastAgyWindowRect: NSRect? = nil
    private var windowTrackTimer: Timer?
    private var isUserDragging = false
    private var dragCooldownUntil: Date = .distantPast
    private var openedByHover = false

    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var hoverEnterWork: DispatchWorkItem?
    private var hoverExitWork: DispatchWorkItem?
    private var hoverWatchdogTimer: Timer?
    private var outsideTickCount = 0
    private var collapseFrameWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        setupPanel()

        vm.onPlacementChanged = { [weak self] in self?.handlePlacementChanged() }
        vm.onVisibilityPrefChanged = { [weak self] in self?.updateNotchVisibility() }
        vm.onSnapshotUpdated = { [weak self] in self?.updateMenuBarTooltip() }
        vm.onLayoutNeeded = { [weak self] in
            DispatchQueue.main.async { self?.syncPanelFrame(animated: false) }
        }
        vm.onRequestCollapse = { [weak self] in self?.collapseToIsland() }
        vm.onQuit = { NSApp.terminate(nil) }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appResignedActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        vm.startPolling()
        startAgyWindowTracking()
    }

    /// Reads the frontmost on-screen Antigravity main window bounds in AppKit screen coordinates.
    /// Uses public CoreGraphics window bounds (zero Accessibility prompt, zero injection).
    private func findAntigravityWindowRect() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? vm.geometry.screenFrame.height
        for info in list {
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let layer = (info[kCGWindowLayer as String] as? Int) ?? -1
            guard layer == 0, owner.lowercased().contains("antigravity") else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgRect.width >= 360, cgRect.height >= 240 else { continue }
            // Convert Quartz top-left global coords -> AppKit bottom-left global coords
            let appKitY = primaryHeight - (cgRect.origin.y + cgRect.size.height)
            return NSRect(x: cgRect.origin.x, y: appKitY, width: cgRect.size.width, height: cgRect.size.height)
        }
        return nil
    }

    private func startAgyWindowTracking() {
        guard windowTrackTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.trackAntigravityWindowTick()
            }
        }
        t.tolerance = 0.08
        windowTrackTimer = t
    }

    private func stopAgyWindowTracking() {
        windowTrackTimer?.invalidate()
        windowTrackTimer = nil
    }

    private func isAntigravityOrSelfFrontmost() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        let bid = front?.bundleIdentifier?.lowercased() ?? ""
        let name = front?.localizedName?.lowercased() ?? ""
        return bid.contains("antigravity")
            || name.contains("antigravity")
            || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func trackAntigravityWindowTick() {
        guard vm.placement == .bottomRight, !isUserDragging, vm.notchState == .collapsed else { return }
        if vm.onlyWhenAgyActive && !isAntigravityOrSelfFrontmost() {
            stopAgyWindowTracking()
            setPanelVisible(false)
            return
        }
        guard let agyRect = findAntigravityWindowRect() else {
            if lastAgyWindowRect != nil {
                lastAgyWindowRect = nil
                updateNotchVisibility()
            }
            return
        }
        let changed = lastAgyWindowRect.map {
            abs($0.origin.x - agyRect.origin.x) > 0.5
                || abs($0.origin.y - agyRect.origin.y) > 0.5
                || abs($0.width - agyRect.width) > 0.5
                || abs($0.height - agyRect.height) > 0.5
        } ?? true

        if changed {
            lastAgyWindowRect = agyRect
            floatingAnchorOrigin = computeAnchoredOrigin(for: agyRect)
            updateFloatingExpansionDirection()
            applyHostingAnchors()
            syncPanelFrame(animated: false)
        }
        if !notchPanel.isVisible {
            updateNotchVisibility()
        }
    }

    private func computeAnchoredOrigin(for agyRect: NSRect) -> NSPoint {
        let w = vm.geometry.floatingCollapsedWidth
        let h = vm.geometry.floatingCollapsedHeight
        // Keep the pill cleanly inside whichever screen currently holds Antigravity
        let hostScreen = NSScreen.screens.first(where: { $0.frame.intersects(agyRect) }) ?? NSScreen.main
        let vf = hostScreen?.visibleFrame ?? vm.geometry.visibleFrame
        let rawX = agyRect.maxX - w - relativeInsetRight
        let rawY = agyRect.minY + relativeInsetBottom
        let clampedX = max(vf.minX + 6, min(rawX, vf.maxX - w - 6))
        let clampedY = max(vf.minY + 6, min(rawY, vf.maxY - h - 6))
        return NSPoint(x: round(clampedX), y: round(clampedY))
    }

    // MARK: Subtle Menu Bar Anchor

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Token Lens")
            img?.isTemplate = true
            btn.image = img
            btn.toolTip = "Token Lens · 左键展开面板 / 右键菜单退出"
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.action = #selector(menuBarClicked)
            btn.target = self
        }
    }

    private func updateMenuBarTooltip() {
        guard let btn = statusItem.button else { return }
        let m = vm.snapshot.metrics
        if m.hasData {
            let pct = m.ctxPercent != nil ? "\(Int(m.ctxPercent!.rounded()))%" : "—"
            btn.toolTip = "Token Lens · \(fmtRate(m.speed)) tok/s · 上下文 \(pct)"
        } else {
            btn.toolTip = "Token Lens"
        }
    }

    @objc private func menuBarClicked() {
        if let ev = NSApp.currentEvent, ev.type == .rightMouseUp, let btn = statusItem.button {
            let menu = buildContextMenu()
            NSMenu.popUpContextMenu(menu, with: ev, for: btn)
            return
        }
        if vm.notchState == .expanded {
            collapseToIsland()
        } else {
            expandCommandCenter(triggeredByHover: false)
        }
    }

    // MARK: Panel Setup & Placement

    private func defaultBottomRightOrigin(geo: NotchGeometry) -> NSPoint {
        let vf = geo.visibleFrame
        return NSPoint(
            x: round(vf.maxX - geo.floatingCollapsedWidth - 18),
            y: round(vf.minY + 18)
        )
    }

    private func loadFloatingOrigin(geo: NotchGeometry) -> NSPoint {
        if UserDefaults.standard.object(forKey: "tl.agyInsetR") != nil {
            relativeInsetRight = CGFloat(UserDefaults.standard.double(forKey: "tl.agyInsetR"))
            relativeInsetBottom = CGFloat(UserDefaults.standard.double(forKey: "tl.agyInsetB"))
        } else {
            relativeInsetRight = 16
            relativeInsetBottom = 14
        }
        if let agyRect = findAntigravityWindowRect() {
            lastAgyWindowRect = agyRect
            return computeAnchoredOrigin(for: agyRect)
        }
        return defaultBottomRightOrigin(geo: geo)
    }

    private func setupPanel() {
        vm.geometry = NotchGeometry.detect(preferNotch: vm.placement == .topNotch)
        floatingAnchorOrigin = loadFloatingOrigin(geo: vm.geometry)
        updateFloatingExpansionDirection()

        hostingView = NSHostingView(rootView: DynamicNotchRootView(vm: vm))
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        containerView = NotchTrackingContainerView(frame: .zero)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)

        applyHostingAnchors()

        containerView.onHoverChanged = { [weak self] hovering in
            self?.handleHoverChange(hovering)
        }

        let initialFrame = targetFrame(for: .collapsed)
        notchPanel = NotchPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.acceptsMouseMovedEvents = true
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        notchPanel.hidesOnDeactivate = false
        notchPanel.delegate = self
        notchPanel.contentView = containerView

        configureWindowStyleForPlacement()

        notchPanel.onMouseDownCollapsed = { [weak self] in
            self?.hoverEnterWork?.cancel()
        }
        notchPanel.onTapCollapsed = { [weak self] in
            self?.expandCommandCenter(triggeredByHover: false)
        }
        notchPanel.onRightClickNotch = { [weak self] event in
            self?.showContextMenu(event)
        }
        notchPanel.onEscape = { [weak self] in
            self?.collapseToIsland()
        }
        notchPanel.onDragBegan = { [weak self] in
            guard let self else { return }
            self.isUserDragging = true
            self.hoverEnterWork?.cancel()
            self.hoverExitWork?.cancel()
        }
        notchPanel.onDragFinished = { [weak self] newOrigin in
            guard let self else { return }
            self.isUserDragging = false
            self.dragCooldownUntil = Date().addingTimeInterval(0.5)
            self.floatingAnchorOrigin = newOrigin
            if let agyRect = self.findAntigravityWindowRect() ?? self.lastAgyWindowRect {
                self.lastAgyWindowRect = agyRect
                let w = self.vm.geometry.floatingCollapsedWidth
                let h = self.vm.geometry.floatingCollapsedHeight
                let insetR = max(6, min(agyRect.width - w - 6, agyRect.maxX - (newOrigin.x + w)))
                let insetB = max(6, min(agyRect.height - h - 6, newOrigin.y - agyRect.minY))
                self.relativeInsetRight = round(insetR)
                self.relativeInsetBottom = round(insetB)
                UserDefaults.standard.set(Double(self.relativeInsetRight), forKey: "tl.agyInsetR")
                UserDefaults.standard.set(Double(self.relativeInsetBottom), forKey: "tl.agyInsetB")
            }
            self.updateFloatingExpansionDirection()
            self.applyHostingAnchors()
        }

        notchPanel.orderFrontRegardless()
        updateNotchVisibility()
    }

    private func updateFloatingExpansionDirection() {
        let hostScreen = NSScreen.screens.first(where: { $0.frame.contains(floatingAnchorOrigin) }) ?? NSScreen.main
        let vf = hostScreen?.visibleFrame ?? vm.geometry.visibleFrame
        let anchorMidY = floatingAnchorOrigin.y + vm.geometry.floatingCollapsedHeight / 2.0
        vm.floatingExpandsUpward = anchorMidY <= vf.midY
    }

    private func applyHostingAnchors() {
        NSLayoutConstraint.deactivate(hostingConstraints)
        if vm.placement == .topNotch {
            hostingConstraints = [
                hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
                hostingView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor)
            ]
        } else {
            let hostScreen = NSScreen.screens.first(where: { $0.frame.contains(floatingAnchorOrigin) }) ?? NSScreen.main
            let vf = hostScreen?.visibleFrame ?? vm.geometry.visibleFrame
            let anchorMidX = floatingAnchorOrigin.x + vm.geometry.floatingCollapsedWidth / 2.0
            let alignRight = anchorMidX >= vf.midX
            let hConstraint = alignRight
                ? hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
                : hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor)
            let vConstraint = vm.floatingExpandsUpward
                ? hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
                : hostingView.topAnchor.constraint(equalTo: containerView.topAnchor)
            hostingConstraints = [hConstraint, vConstraint]
        }
        NSLayoutConstraint.activate(hostingConstraints)
    }

    private func configureWindowStyleForPlacement() {
        if vm.placement == .topNotch {
            notchPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
            notchPanel.allowsDrag = false
            notchPanel.hasShadow = (vm.notchState != .collapsed)
        } else {
            notchPanel.level = .floating
            notchPanel.allowsDrag = (vm.notchState == .collapsed)
            notchPanel.hasShadow = true
        }
    }

    private func handlePlacementChanged() {
        hoverEnterWork?.cancel()
        hoverExitWork?.cancel()
        collapseFrameWork?.cancel()

        vm.geometry = NotchGeometry.detect(preferNotch: vm.placement == .topNotch)
        if vm.placement == .bottomRight {
            floatingAnchorOrigin = loadFloatingOrigin(geo: vm.geometry)
            updateFloatingExpansionDirection()
        }
        applyHostingAnchors()
        configureWindowStyleForPlacement()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncPanelFrame(animated: false)
            self.notchPanel.invalidateShadow()
        }
    }

    // MARK: Pure 2-State Transitions (Collapsed ⇄ Full 652pt Obsidian Command Center)

    private func handleHoverChange(_ hovering: Bool) {
        hoverEnterWork?.cancel()
        hoverExitWork?.cancel()

        if vm.notchState == .collapsed {
            vm.isHoveringCollapsed = hovering && !isUserDragging
            if !isUserDragging {
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        } else {
            vm.isHoveringCollapsed = false
            if hovering {
                NSCursor.arrow.set()
            }
        }

        guard !isUserDragging, vm.hoverDirectExpand else { return }

        if hovering {
            guard vm.notchState == .collapsed, Date() >= dragCooldownUntil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      !self.isUserDragging,
                      self.vm.hoverDirectExpand,
                      self.vm.notchState == .collapsed,
                      Date() >= self.dragCooldownUntil else { return }
                let pt = NSEvent.mouseLocation
                if self.notchPanel.frame.insetBy(dx: -3, dy: -3).contains(pt) {
                    self.expandCommandCenter(triggeredByHover: true)
                }
            }
            hoverEnterWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
        } else {
            // Only auto-collapse on mouse exit when opened via hover AND session picker dropdown isn't open
            guard vm.notchState == .expanded, openedByHover, !vm.showSessionPicker else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.vm.notchState == .expanded,
                      self.openedByHover,
                      !self.vm.showSessionPicker else { return }
                let pt = NSEvent.mouseLocation
                if !self.notchPanel.frame.insetBy(dx: -12, dy: -12).contains(pt) {
                    self.collapseToIsland()
                }
            }
            hoverExitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        }
    }

    private func startHoverExitWatchdog() {
        stopHoverExitWatchdog()
        outsideTickCount = 0
        hoverWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.vm.notchState == .expanded, self.openedByHover else {
                    self.stopHoverExitWatchdog()
                    return
                }
                if self.vm.showSessionPicker {
                    self.outsideTickCount = 0
                    return
                }
                let pt = NSEvent.mouseLocation
                if self.notchPanel.frame.insetBy(dx: -14, dy: -14).contains(pt) {
                    self.outsideTickCount = 0
                } else {
                    self.outsideTickCount += 1
                    if self.outsideTickCount >= 2 {
                        self.collapseToIsland()
                    }
                }
            }
        }
    }

    private func stopHoverExitWatchdog() {
        hoverWatchdogTimer?.invalidate()
        hoverWatchdogTimer = nil
        outsideTickCount = 0
    }

    private func expandCommandCenter(triggeredByHover: Bool) {
        hoverEnterWork?.cancel()
        hoverExitWork?.cancel()
        collapseFrameWork?.cancel()

        openedByHover = triggeredByHover
        vm.isHoveringCollapsed = false
        vm.showSessionPicker = false
        vm.refreshNow()
        vm.refreshQuota(force: false, maxAge: 90)
        NSCursor.arrow.set()

        notchPanel.ignoresMouseEvents = false
        notchPanel.allowsKeyFocus = true
        notchPanel.allowsDrag = false
        notchPanel.hasShadow = true
        if vm.placement == .bottomRight {
            notchPanel.level = .popUpMenu
        }

        applyHostingAnchors()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.87)) {
            vm.notchState = .expanded
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.vm.notchState == .expanded else { return }
            self.syncPanelFrame(animated: false)
            if !triggeredByHover {
                NSApp.activate(ignoringOtherApps: true)
                self.notchPanel.makeKeyAndOrderFront(nil)
                self.stopHoverExitWatchdog()
            } else {
                self.notchPanel.orderFrontRegardless()
                self.startHoverExitWatchdog()
            }
            self.notchPanel.invalidateShadow()
            self.installDismissMonitors()
        }
    }

    private func collapseToIsland() {
        hoverEnterWork?.cancel()
        hoverExitWork?.cancel()
        stopHoverExitWatchdog()
        collapseFrameWork?.cancel()
        removeDismissMonitors()

        let wasExpanded = (vm.notchState == .expanded)
        openedByHover = false
        vm.isHoveringCollapsed = false
        vm.showSessionPicker = false
        notchPanel.allowsKeyFocus = false

        if wasExpanded {
            notchPanel.ignoresMouseEvents = true
        }

        withAnimation(.spring(response: 0.24, dampingFraction: 0.90)) {
            vm.notchState = .collapsed
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.vm.notchState == .collapsed else { return }
            self.configureWindowStyleForPlacement()
            self.notchPanel.setFrame(self.targetFrame(for: .collapsed), display: true)
            self.notchPanel.ignoresMouseEvents = false
            self.notchPanel.invalidateShadow()
            self.updateNotchVisibility()
        }
        collapseFrameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func targetFrame(for state: NotchState) -> NSRect {
        let g = vm.geometry

        if vm.placement == .topNotch {
            let width: CGFloat
            let height: CGFloat
            switch state {
            case .collapsed:
                width = g.notchCollapsedWidth
                height = g.notchHeight
            case .expanded:
                hostingView.invalidateIntrinsicContentSize()
                hostingView.layoutSubtreeIfNeeded()
                let measured = hostingView.fittingSize
                width = max(g.expandedWidth, measured.width)
                height = min(g.screenFrame.height - 48, max(440, measured.height))
            }
            let x = round(g.screenFrame.midX - width / 2.0)
            let y = g.screenFrame.maxY - height
            return NSRect(x: x, y: y, width: width, height: height)
        } else {
            let hostScreen = NSScreen.screens.first(where: { $0.frame.contains(floatingAnchorOrigin) }) ?? NSScreen.main
            let vf = hostScreen?.visibleFrame ?? g.visibleFrame
            let collapsedW = g.floatingCollapsedWidth
            let collapsedH = g.floatingCollapsedHeight

            let width: CGFloat
            let height: CGFloat
            switch state {
            case .collapsed:
                width = collapsedW
                height = collapsedH
            case .expanded:
                hostingView.invalidateIntrinsicContentSize()
                hostingView.layoutSubtreeIfNeeded()
                let measured = hostingView.fittingSize
                width = max(g.expandedWidth, measured.width)
                height = min(vf.height - 24, max(440, measured.height))
            }

            let anchorRight = floatingAnchorOrigin.x + collapsedW
            let anchorTop = floatingAnchorOrigin.y + collapsedH
            let alignRight = (floatingAnchorOrigin.x + collapsedW / 2.0) >= vf.midX

            var x = alignRight ? (anchorRight - width) : floatingAnchorOrigin.x
            var y = vm.floatingExpandsUpward ? floatingAnchorOrigin.y : (anchorTop - height)

            x = round(max(vf.minX + 10, min(x, vf.maxX - width - 10)))
            y = round(max(vf.minY + 10, min(y, vf.maxY - height - 10)))
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }

    private func syncPanelFrame(animated: Bool) {
        let frame = targetFrame(for: vm.notchState)
        if abs(notchPanel.frame.width - frame.width) > 0.5
            || abs(notchPanel.frame.height - frame.height) > 0.5
            || abs(notchPanel.frame.origin.x - frame.origin.x) > 0.5
            || abs(notchPanel.frame.origin.y - frame.origin.y) > 0.5 {
            notchPanel.setFrame(frame, display: true, animate: animated)
            notchPanel.invalidateShadow()
        }
    }

    // MARK: Instant Auto-Dismiss Monitors

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.vm.notchState == .expanded else { return }
                let pt = NSEvent.mouseLocation
                if !self.notchPanel.frame.contains(pt) {
                    self.collapseToIsland()
                }
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor [weak self] in self?.collapseToIsland() }
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let m = globalMouseMonitor {
            NSEvent.removeMonitor(m)
            globalMouseMonitor = nil
        }
        if let k = localKeyMonitor {
            NSEvent.removeMonitor(k)
            localKeyMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === notchPanel && vm.notchState == .expanded {
            collapseToIsland()
        }
    }

    @objc private func appResignedActive() {
        if vm.notchState == .expanded {
            collapseToIsland()
        }
    }

    @objc private func systemDidWake() {
        vm.refreshNow()
        vm.refreshQuota(force: false, maxAge: 60)
    }

    @objc private func screensChanged() {
        vm.geometry = NotchGeometry.detect(preferNotch: vm.placement == .topNotch)
        if vm.placement == .bottomRight {
            floatingAnchorOrigin = loadFloatingOrigin(geo: vm.geometry)
            updateFloatingExpansionDirection()
            applyHostingAnchors()
        }
        syncPanelFrame(animated: false)
    }

    @objc private func activeAppChanged() {
        let front = NSWorkspace.shared.frontmostApplication
        if vm.notchState == .expanded && front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            collapseToIsland()
        }
        updateNotchVisibility()
    }

    private func setPanelVisible(_ visible: Bool) {
        if visible {
            if !notchPanel.isVisible {
                notchPanel.orderFrontRegardless()
            }
        } else {
            if notchPanel.isVisible {
                notchPanel.orderOut(nil)
            }
        }
    }

    private func updateNotchVisibility() {
        guard notchPanel != nil else { return }
        if !vm.showNotchIsland && vm.notchState != .expanded {
            setPanelVisible(false)
            stopAgyWindowTracking()
            vm.pausePolling()
            return
        }
        if !vm.onlyWhenAgyActive || vm.notchState == .expanded {
            setPanelVisible(true)
            vm.resumePolling()
            if vm.placement == .bottomRight { startAgyWindowTracking() }
            return
        }
        let isAgy = isAntigravityOrSelfFrontmost()
        if isAgy {
            let hasAgyWindow = (vm.placement == .topNotch) || (lastAgyWindowRect != nil) || (findAntigravityWindowRect() != nil)
            setPanelVisible(hasAgyWindow)
            vm.resumePolling()
            vm.refreshNow()
            if vm.placement == .bottomRight {
                startAgyWindowTracking()
                trackAntigravityWindowTick()
            } else {
                stopAgyWindowTracking()
            }
        } else {
            setPanelVisible(false)
            stopAgyWindowTracking()
            vm.pausePolling()
        }
    }

    // MARK: Context Menu

    private func buildContextMenu() -> NSMenu {
        let zh = vm.isChinese
        let menu = NSMenu()
        menu.addItem(withTitle: zh ? "展开详情与官方额度" : "Open Details & Quota", action: #selector(ctxOpen), keyEquivalent: "")
        menu.addItem(withTitle: zh ? "立即刷新官方额度" : "Refresh Official Quota", action: #selector(ctxRefreshQuota), keyEquivalent: "")
        menu.addItem(withTitle: vm.placement == .bottomRight ? (zh ? "切换为顶部刘海灵动岛" : "Move to Top Notch") : (zh ? "吸附到 AGY 窗口右下角" : "Attach to AGY Bottom-Right"), action: #selector(ctxTogglePlacement), keyEquivalent: "")
        if vm.placement == .bottomRight {
            menu.addItem(withTitle: zh ? "重置到 AGY 右下角" : "Reset to AGY Bottom-Right", action: #selector(ctxResetCorner), keyEquivalent: "")
        }
        let hoverItem = NSMenuItem(title: zh ? "悬停直展完整详情" : "Hover to Expand Full Details", action: #selector(ctxToggleHover), keyEquivalent: "")
        hoverItem.state = vm.hoverDirectExpand ? .on : .off
        menu.addItem(hoverItem)
        let agyItem = NSMenuItem(title: zh ? "仅在 Antigravity 前台显示" : "Only Show Over Antigravity", action: #selector(ctxToggleOnlyAgy), keyEquivalent: "")
        agyItem.state = vm.onlyWhenAgyActive ? .on : .off
        menu.addItem(agyItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: zh ? "退出 Token Lens" : "Quit Token Lens", action: #selector(ctxQuit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }

    private func showContextMenu(_ event: NSEvent) {
        let menu = buildContextMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: containerView)
    }

    @objc private func ctxOpen() { expandCommandCenter(triggeredByHover: false) }
    @objc private func ctxRefreshQuota() { vm.refreshQuota(force: true) }
    @objc private func ctxTogglePlacement() { vm.placement = (vm.placement == .bottomRight) ? .topNotch : .bottomRight }
    @objc private func ctxResetCorner() {
        UserDefaults.standard.removeObject(forKey: "tl.agyInsetR")
        UserDefaults.standard.removeObject(forKey: "tl.agyInsetB")
        relativeInsetRight = 16
        relativeInsetBottom = 14
        if let agyRect = findAntigravityWindowRect() {
            lastAgyWindowRect = agyRect
            floatingAnchorOrigin = computeAnchoredOrigin(for: agyRect)
        } else {
            floatingAnchorOrigin = defaultBottomRightOrigin(geo: vm.geometry)
        }
        updateFloatingExpansionDirection()
        applyHostingAnchors()
        syncPanelFrame(animated: true)
    }
    @objc private func ctxToggleHover() { vm.hoverDirectExpand.toggle() }
    @objc private func ctxToggleOnlyAgy() { vm.onlyWhenAgyActive.toggle() }
    @objc private func ctxQuit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
