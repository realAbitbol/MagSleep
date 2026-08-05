import AppKit
import MagSleepCore

/// First-run setup window: install the helper, pick a mode, and optionally
/// enable Launch at Login — one step instead of three stacked alerts.
/// Non-modal: the app keeps working while the window is open.
final class OnboardingWindowController: NSWindowController {
    private let helper: HelperManager
    /// Called when the window closes (after install or on cancel).
    private let onComplete: () -> Void

    private let modeSleepButton = NSButton(radioButtonWithTitle: "Sleep Mode", target: nil, action: nil)
    private let modeAlwaysOffButton = NSButton(radioButtonWithTitle: "Always Off", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch MagSleep at login", target: nil, action: nil)
    private let installButton = NSButton(title: "Install & Start", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    /// Guards against `finish()` firing the completion twice (e.g. the user
    /// closes the window while an install is still in flight).
    private var didFinish = false

    init(helper: HelperManager, onComplete: @escaping () -> Void) {
        self.helper = helper
        self.onComplete = onComplete

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to MagSleep"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        // Closing the window (red button) must also finish the flow — otherwise
        // the controller is retained and the startup chain stalls.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        configureControls()
        window.contentView = buildContentView()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func configureControls() {
        modeSleepButton.state = .on
        modeSleepButton.toolTip = "LED off while the Mac sleeps, restored to macOS on wake"
        modeAlwaysOffButton.toolTip = "LED stays off at all times"

        launchAtLoginCheckbox.state = helper.canManageLaunchAtLogin ? .on : .off
        launchAtLoginCheckbox.isEnabled = helper.canManageLaunchAtLogin

        statusLabel.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isHidden = true

        installButton.keyEquivalent = "\r" // default button (Return)
        installButton.target = self
        installButton.action = #selector(installAndStart)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
    }

    // MARK: - Actions

    @objc private func installAndStart() {
        let mode: OperationMode = modeAlwaysOffButton.state == .on ? .alwaysOff : .sleep
        installButton.isEnabled = false
        cancelButton.isEnabled = false
        statusLabel.isHidden = true

        helper.enable { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    // Register Launch at Login only after the helper is
                    // confirmed installed — a declined install must not leave
                    // a login item pointing at a helper-less app.
                    if self.launchAtLoginCheckbox.state == .on, self.helper.canManageLaunchAtLogin {
                        try? self.helper.setLaunchesAtLogin(true)
                    }
                    self.helper.setMode(mode) { _ in
                        self.finish()
                    }
                } else {
                    self.installButton.isEnabled = true
                    self.cancelButton.isEnabled = true
                    self.statusLabel.isHidden = false
                    self.statusLabel.stringValue = "Could not install the helper: \(self.helper.lastError ?? "unknown error")"
                }
            }
        }
    }

    @objc private func cancel() {
        finish()
    }

    @objc private func windowWillClose(_: Notification) {
        // Red close button: treat as cancel. Idempotent so a close during an
        // in-flight install cannot fire the completion twice.
        finish()
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        window?.close()
        onComplete()
    }

    // MARK: - Layout

    private func buildContentView() -> NSView {
        let content = NSView()

        let title = NSTextField(labelWithString: "Welcome to MagSleep")
        title.font = .boldSystemFont(ofSize: 17)

        let body = NSTextField(wrappingLabelWithString: """
        Turn the MagSafe LED off while your Mac sleeps — or keep it off completely. \
        MagSleep installs a small helper so it can control the LED even when you quit the app.
        """)
        body.preferredMaxLayoutWidth = 380

        let modeLabel = NSTextField(labelWithString: "How should the LED behave?")
        modeLabel.font = .boldSystemFont(ofSize: 13)

        let subviews: [NSView] = [
            title, body, modeLabel,
            modeSleepButton, modeAlwaysOffButton, launchAtLoginCheckbox,
            statusLabel, installButton, cancelButton,
        ]
        for view in subviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            modeLabel.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
            modeLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            modeSleepButton.topAnchor.constraint(equalTo: modeLabel.bottomAnchor, constant: 6),
            modeSleepButton.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 4),

            modeAlwaysOffButton.topAnchor.constraint(equalTo: modeSleepButton.bottomAnchor, constant: 2),
            modeAlwaysOffButton.leadingAnchor.constraint(equalTo: modeSleepButton.leadingAnchor),

            launchAtLoginCheckbox.topAnchor.constraint(equalTo: modeAlwaysOffButton.bottomAnchor, constant: 10),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            statusLabel.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            cancelButton.trailingAnchor.constraint(equalTo: installButton.leadingAnchor, constant: -8),
            cancelButton.topAnchor.constraint(greaterThanOrEqualTo: statusLabel.bottomAnchor, constant: 16),

            installButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
            installButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        return content
    }
}
