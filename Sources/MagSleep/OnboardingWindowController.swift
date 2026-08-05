import AppKit
import MagSleepCore

/// First-run setup window: install the helper, pick a mode, and optionally
/// enable Launch at Login — one step instead of three stacked alerts.
/// Non-modal: the app keeps working while the window is open.
///
/// Onboarding is **mandatory**: the only two ways out are installing the
/// helper or quitting the app (a declined admin prompt shows an in-window
/// error and lets the user retry; "Cancel & Quit" terminates the app, which
/// cannot function without the helper).
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let helper: HelperManager
    /// Called when the window closes after the helper is installed.
    private let onComplete: () -> Void

    // Header
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Welcome to MagSleep")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")

    // Mode cards
    private let sleepCard = ModeCardView(
        symbol: "moon.zzz.fill",
        title: "Sleep Mode",
        subtitle: "LED off while the Mac sleeps, back on when you wake"
    )
    private let alwaysOffCard = ModeCardView(
        symbol: "bolt.slash.fill",
        title: "Always Off",
        subtitle: "LED stays off at all times"
    )
    private let behaviorLabel = NSTextField(labelWithString: "LED behavior")

    // Launch at Login
    private let launchAtLoginSwitch = NSSwitch()
    private let launchAtLoginLabel = NSTextField(labelWithString: "Launch at Login")
    private let launchAtLoginCaption = NSTextField(labelWithString: "Start MagSleep automatically when you log in")

    // Footer
    private let installButton = NSButton(title: "Install & Start", target: nil, action: nil)
    private let cancelAndQuitButton = NSButton(title: "Cancel & Quit", target: nil, action: nil)
    private let footnoteLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    /// Guards against `finish()` firing the completion twice (e.g. the window
    /// closing through any path while an install is still in flight).
    private var didFinish = false
    /// The window delegate vetoes all close attempts (Cmd+W included) unless
    /// `finish()` has flipped this — otherwise a closed window would leave the
    /// app running helper-less with the startup chain marked "onboarding shown".
    private var allowsClose = false

    init(helper: HelperManager, onComplete: @escaping () -> Void) {
        self.helper = helper
        self.onComplete = onComplete

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            // Not .closable: onboarding is mandatory, so there is no red close
            // button to skip it (Cmd+Q quits, and the next launch shows it again).
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        // Closing the window (red button) must also finish the flow — otherwise
        // the controller is retained and the startup chain stalls.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        let content = NSView()
        configureViews()
        addSubviews(to: content)
        activateConstraints(in: content)
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Actions

    @objc private func installAndStart() {
        let mode: OperationMode = alwaysOffCard.isSelected ? .alwaysOff : .sleep
        installButton.isEnabled = false
        cancelAndQuitButton.isEnabled = false
        statusLabel.isHidden = true

        helper.enable { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    // Register Launch at Login only after the helper is
                    // confirmed installed — a declined install must not leave
                    // a login item pointing at a helper-less app.
                    if self.launchAtLoginSwitch.state == .on, self.helper.canManageLaunchAtLogin {
                        try? self.helper.setLaunchesAtLogin(true)
                    }
                    self.helper.setMode(mode) { _ in
                        self.finish()
                    }
                } else {
                    // Mandatory: a declined install keeps the window open with
                    // the error — the user must retry or quit. A canceled admin
                    // prompt is a user decision, not a failure: say so instead
                    // of reporting "unknown error".
                    self.installButton.isEnabled = true
                    self.cancelAndQuitButton.isEnabled = true
                    self.statusLabel.isHidden = false
                    let message: String
                    if self.helper.lastAttemptWasCancelled {
                        message = "Installation was canceled. MagSleep needs the helper to function — "
                            + "retry Install & Start, or Cancel & Quit."
                    } else if let detail = self.helper.lastError {
                        message = "Could not install the helper: \(detail)"
                    } else {
                        message = "Could not install the helper."
                    }
                    self.statusLabel.stringValue = message
                }
            }
        }
    }

    private func selectMode(_ mode: OperationMode) {
        sleepCard.isSelected = (mode == .sleep)
        alwaysOffCard.isSelected = (mode == .alwaysOff)
    }

    /// The app cannot function without the helper, so refusing the install is
    /// an explicit quit rather than a dead-end state (the next launch shows
    /// onboarding again).
    @objc private func cancelAndQuit() {
        NSApp.terminate(nil)
    }

    func windowWillClose(_: Notification) {
        // Safety net: with the delegate veto below, only finish() can close the
        // window. Idempotent so a close during an in-flight install cannot
        // fire the completion twice.
        finish()
    }

    /// NSWindowDelegate: veto every close attempt except the one finish()
    /// performs — Cmd+W and any other path must not dismiss the mandatory
    /// onboarding without installing the helper or quitting the app.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        allowsClose
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        allowsClose = true
        window?.close()
        onComplete()
    }

    // MARK: - Setup

    private func configureViews() {
        iconView.image = NSImage(named: NSImage.applicationIconName)
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.alignment = .center

        subtitleLabel.stringValue =
            "Turn the MagSafe LED off while your Mac sleeps — or keep it off completely."
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.preferredMaxLayoutWidth = 380

        behaviorLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        behaviorLabel.textColor = .secondaryLabelColor

        launchAtLoginSwitch.state = helper.canManageLaunchAtLogin ? .on : .off
        launchAtLoginSwitch.isEnabled = helper.canManageLaunchAtLogin
        launchAtLoginLabel.font = .systemFont(ofSize: 13)
        launchAtLoginLabel.textColor = helper.canManageLaunchAtLogin ? .labelColor : .tertiaryLabelColor
        launchAtLoginCaption.font = .systemFont(ofSize: 11)
        launchAtLoginCaption.textColor = .secondaryLabelColor

        footnoteLabel.stringValue = "MagSleep installs a small helper to control the LED. "
            + "You'll be asked for your administrator password once."
        footnoteLabel.font = .systemFont(ofSize: 11)
        footnoteLabel.textColor = .secondaryLabelColor
        footnoteLabel.preferredMaxLayoutWidth = 420
        footnoteLabel.maximumNumberOfLines = 2

        statusLabel.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 420
        statusLabel.isHidden = true

        installButton.target = self
        installButton.action = #selector(installAndStart)
        installButton.keyEquivalent = "\r" // default button (Return)
        installButton.bezelColor = .controlAccentColor

        cancelAndQuitButton.target = self
        cancelAndQuitButton.action = #selector(cancelAndQuit)
        cancelAndQuitButton.isBordered = false
        cancelAndQuitButton.contentTintColor = .secondaryLabelColor
        cancelAndQuitButton.font = .systemFont(ofSize: 13)

        sleepCard.onSelect = { [weak self] in self?.selectMode(.sleep) }
        alwaysOffCard.onSelect = { [weak self] in self?.selectMode(.alwaysOff) }
        sleepCard.isSelected = true
    }

    private func addSubviews(to content: NSView) {
        let subviews: [NSView] = [
            iconView, titleLabel, subtitleLabel, behaviorLabel,
            sleepCard, alwaysOffCard,
            launchAtLoginSwitch, launchAtLoginLabel, launchAtLoginCaption,
            footnoteLabel, statusLabel, installButton, cancelAndQuitButton,
        ]
        for view in subviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
    }

    private func activateConstraints(in content: NSView) {
        let cardHeight: CGFloat = 84
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            iconView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 40),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -40),

            behaviorLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            behaviorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),

            sleepCard.topAnchor.constraint(equalTo: behaviorLabel.bottomAnchor, constant: 8),
            sleepCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            sleepCard.heightAnchor.constraint(equalToConstant: cardHeight),
            sleepCard.widthAnchor.constraint(equalTo: alwaysOffCard.widthAnchor),

            alwaysOffCard.topAnchor.constraint(equalTo: sleepCard.topAnchor),
            alwaysOffCard.leadingAnchor.constraint(equalTo: sleepCard.trailingAnchor, constant: 12),
            alwaysOffCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            alwaysOffCard.heightAnchor.constraint(equalToConstant: cardHeight),

            launchAtLoginLabel.topAnchor.constraint(equalTo: sleepCard.bottomAnchor, constant: 22),
            launchAtLoginLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),

            launchAtLoginCaption.topAnchor.constraint(equalTo: launchAtLoginLabel.bottomAnchor, constant: 2),
            launchAtLoginCaption.leadingAnchor.constraint(equalTo: launchAtLoginLabel.leadingAnchor),

            launchAtLoginSwitch.centerYAnchor.constraint(equalTo: launchAtLoginLabel.centerYAnchor),
            launchAtLoginSwitch.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            footnoteLabel.topAnchor.constraint(equalTo: launchAtLoginCaption.bottomAnchor, constant: 16),
            footnoteLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footnoteLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: footnoteLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            cancelAndQuitButton.trailingAnchor.constraint(equalTo: installButton.leadingAnchor, constant: -12),
            cancelAndQuitButton.centerYAnchor.constraint(equalTo: installButton.centerYAnchor),
            cancelAndQuitButton.topAnchor.constraint(greaterThanOrEqualTo: statusLabel.bottomAnchor, constant: 16),

            installButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            installButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            installButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }
}

/// A tappable, selectable card used for the mode choice in the onboarding
/// window — a modern alternative to plain radio buttons. The selected card
/// gets an accent border and a checkmark badge.
final class ModeCardView: NSView {
    var isSelected = false {
        didSet { updateAppearance() }
    }
    var onSelect: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let checkmarkView = NSImageView()
    private var isFocused = false

    init(symbol: String, title: String, subtitle: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.preferredMaxLayoutWidth = 130
        subtitleLabel.maximumNumberOfLines = 2

        checkmarkView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")
        checkmarkView.contentTintColor = .controlAccentColor

        for view in [iconView, titleLabel, subtitleLabel, checkmarkView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            checkmarkView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            checkmarkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            checkmarkView.widthAnchor.constraint(equalToConstant: 18),
            checkmarkView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmarkView.leadingAnchor, constant: -6),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func handleClick() {
        onSelect?()
    }

    // MARK: - Accessibility & keyboard

    /// The mode cards are a radio-button group: expose that so VoiceOver can
    /// announce and activate them (setup is mandatory, so screen-reader users
    /// must be able to complete it).
    override func accessibilityRole() -> NSAccessibility.Role? {
        .radioButton
    }

    override func accessibilityLabel() -> String? {
        "\(titleLabel.stringValue), \(subtitleLabel.stringValue)"
    }

    override func accessibilityValue() -> Any? {
        isSelected ? "1" : "0"
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            isFocused = true
            updateAppearance()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        updateAppearance()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            onSelect?()
        case 49: // Space
            onSelect?()
        default:
            super.keyDown(with: event)
        }
    }

    private func updateAppearance() {
        guard let layer else { return }
        let accent = NSColor.controlAccentColor
        layer.borderWidth = isFocused ? 2.5 : 1.5
        if isSelected {
            layer.borderColor = accent.cgColor
            iconView.contentTintColor = accent
            titleLabel.textColor = accent
        } else {
            layer.borderColor = (isFocused ? accent : NSColor.separatorColor).cgColor
            iconView.contentTintColor = isFocused ? accent : .secondaryLabelColor
            titleLabel.textColor = .labelColor
        }
        checkmarkView.isHidden = !isSelected
    }
}
