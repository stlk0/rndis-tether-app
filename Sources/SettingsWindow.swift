import AppKit

/// Esc closes the window, as in other settings windows; a button with Esc wins first.
private final class EscClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Until the setup is done, two steps (the service, then the options); afterwards the
/// settings. Closing only hides it.
final class SettingsWindow: NSObject, NSWindowDelegate {
    enum Page { case service, options, settings }

    /// A render comes every 1 to 10 s and `setViews` rebuilds the stack: the views are
    /// rearranged only when this changes.
    private struct Layout: Equatable {
        var page: Page
        var showsSecondParagraph, showsPrimary, showsCommand, showsCommandNote, showsLink: Bool
        var showsAfterCopyHint, showsInstallMessage, showsServiceDetail, showsPrefer, showsQuitSetting: Bool

        init(page: Page, model: SettingsModel, showsAfterCopyHint: Bool) {
            self.page = page
            showsSecondParagraph = model.paragraphs.count > 1
            showsPrimary = model.primary != nil
            showsCommand = model.command != nil
            showsCommandNote = model.commandNote != nil
            showsLink = model.linkTitle != nil
            self.showsAfterCopyHint = showsAfterCopyHint
            showsInstallMessage = model.installMessage != nil
            showsServiceDetail = model.serviceDetail != nil
            showsPrefer = model.preferShown
            showsQuitSetting = model.quitSettingShown
        }
    }

    private static let width: CGFloat = 440, inset: CGFloat = 20
    private static let contentWidth = width - 2 * inset
    /// The alerts quote the two checkboxes.
    static let preferPhoneTitle = "Prefer the phone over Wi-Fi"
    static let openAtLoginTitle = "Open at login"

    private unowned let app: AppDelegate
    private let window = EscClosingWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: true)
    private let stack = NSStackView()
    private var page = Page.settings
    private var centered = false
    private var layout: Layout?
    private var model = SettingsModel()
    /// True from show(setup:) until the window closes; only then is it filled at every render.
    private(set) var isOpen = false
    /// Not Now on the service step: the second step says what is still to do.
    private var skippedService = false
    /// The command last copied; cleared when the page offers another one or the window closes.
    private var copiedText: String?
    private var showsAfterCopyHint: Bool { copiedText != nil && !model.afterCopyHint.isEmpty }

    private let heading = SettingsWindow.label(bold: true)
    private let firstParagraph = SettingsWindow.wrapping()
    private let secondParagraph = SettingsWindow.wrapping()
    private let command = NSTextField(labelWithString: "")
    private let commandNote = SettingsWindow.wrapping(small: true)
    private lazy var link = NSButton(title: "", target: self, action: #selector(copyCommand))
    private let afterCopyHint = SettingsWindow.wrapping(small: true)
    private let installMessage = SettingsWindow.wrapping()
    private lazy var primaryButton = NSButton(title: "", target: self, action: #selector(performPrimary))
    private lazy var notNowButton = NSButton(title: "Not Now", target: self, action: #selector(notNow))
    private lazy var doneButton = NSButton(title: "Done", target: self, action: #selector(done))
    private let serviceLine = SettingsWindow.label()
    private let serviceDetail = SettingsWindow.wrapping()
    private lazy var preferBox = NSButton(
        checkboxWithTitle: Self.preferPhoneTitle, target: self,
        action: #selector(togglePrefer(_:)))
    private let preferHint = SettingsWindow.wrapping(small: true)
    private let iconLabel = SettingsWindow.label("Show the menu bar icon:")
    private lazy var iconWhileConnectedRadio = NSButton(
        radioButtonWithTitle: "Only while a phone is connected", target: self,
        action: #selector(chooseIconVisibility(_:)))
    private lazy var iconAlwaysRadio = NSButton(
        radioButtonWithTitle: "Always", target: self, action: #selector(chooseIconVisibility(_:)))
    private lazy var loginBox = NSButton(
        checkboxWithTitle: Self.openAtLoginTitle, target: self, action: #selector(toggleLogin))
    private let loginHint = SettingsWindow.wrapping(
        "Without it, the icon appears only after you open RNDIS Tether yourself.",
        small: true)
    private let quitLabel = SettingsWindow.label("When RNDIS Tether quits:")
    private lazy var disconnectRadio = NSButton(
        radioButtonWithTitle: "Disconnect the phone (recommended)", target: self,
        action: #selector(chooseQuit(_:)))
    private lazy var keepRadio = NSButton(
        radioButtonWithTitle: "Keep the connection", target: self,
        action: #selector(chooseQuit(_:)))
    private let laterHint = SettingsWindow.wrapping(
        "To change these settings later, choose \(settingsMenuTitle) in the menu bar "
            + "icon; while the icon is hidden, open RNDIS Tether again.", small: true)
    private let footer = SettingsWindow.label(small: true)
    private let appliesHint = SettingsWindow.label("Changes apply right away.", small: true)
    private lazy var iconRadios = indented([iconWhileConnectedRadio, iconAlwaysRadio])
    private lazy var loginHintRow = indented([loginHint])
    private lazy var quitRadios = indented([disconnectRadio, keepRadio])
    private lazy var preferHintRow = indented([preferHint])

    init(app: AppDelegate) {
        self.app = app
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        window.contentView = stack
        command.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        command.isSelectable = true
        // A path with spaces can be long: wrap anywhere rather than cut it off.
        command.lineBreakMode = .byCharWrapping
        command.maximumNumberOfLines = 0
        command.preferredMaxLayoutWidth = Self.contentWidth
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notNowButton.keyEquivalent = "\u{1b}"
        doneButton.keyEquivalent = "\r"
        primaryButton.keyEquivalent = "\r"  // never on the same page as Done
    }

    private static func label(_ text: String = "", bold: Bool = false, small: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        if bold { label.font = .boldSystemFont(ofSize: 15) }
        if small { makeSmall(label) }
        return label
    }

    private static func wrapping(_ text: String = "", small: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = contentWidth
        if small { makeSmall(label) }
        return label
    }

    private static func makeSmall(_ label: NSTextField) {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
    }

    private static func state(_ on: Bool) -> NSControl.StateValue { on ? .on : .off }

    func show(setup: Bool) {
        isOpen = true
        if setup && page == .settings {
            page = .service
        } else if !setup && page == .options {
            page = .settings
        }
        app.render()
        if !centered {
            window.center()
            centered = true
        }
        bringForward()
        app.poll()
    }

    /// Also after the password dialog, which hands the focus back to the app used before.
    func bringForward() {
        activateApp()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()  // in front even when activation is refused
    }

    var isVisible: Bool { window.isVisible }

    /// Back from Terminal, say: show the service as it is now.
    func windowDidBecomeKey(_ notification: Notification) { app.poll() }

    func update(_ model: SettingsModel, alwaysShowIcon: Bool, keepConnectionOnQuit: Bool, openAtLogin: Bool) {
        self.model = model
        if copiedText != model.copyText { copiedText = nil }
        if page == .service && !model.needsService {
            // The install finished, perhaps in the background.
            showOptions()
            if window.isVisible { bringForward() }
        }
        fill(alwaysShowIcon: alwaysShowIcon, keepConnectionOnQuit: keepConnectionOnQuit, openAtLogin: openAtLogin)
        let next = Layout(page: page, model: model, showsAfterCopyHint: showsAfterCopyHint)
        if next != layout {
            layout = next
            relayout(next)
        }
        fit()
    }

    /// Reaching the second step completes the setup: a later launch opens nothing.
    private func showOptions() {
        page = .options
        app.markSetUp()
    }

    private func fill(alwaysShowIcon: Bool, keepConnectionOnQuit: Bool, openAtLogin: Bool) {
        window.title = page == .settings ? "RNDIS Tether Settings" : "RNDIS Tether Setup"
        switch page {
        case .service:
            heading.stringValue = model.heading
            firstParagraph.stringValue = model.paragraphs.first ?? ""
            secondParagraph.stringValue = model.paragraphs.dropFirst().first ?? ""
        case .options:
            let notReady = skippedService ? model.notReady : nil
            heading.stringValue = notReady?.heading ?? SettingsModel.readyHeading
            firstParagraph.stringValue = notReady?.text ?? SettingsModel.readyText
        case .settings:
            break
        }
        command.stringValue = model.command ?? ""
        commandNote.stringValue = model.commandNote ?? ""
        link.title = model.linkTitle ?? ""
        afterCopyHint.stringValue = model.afterCopyHint
        installMessage.stringValue = model.installMessage ?? ""
        primaryButton.title = model.primaryTitle ?? ""
        serviceLine.stringValue = model.serviceLine
        serviceDetail.stringValue = model.serviceDetail ?? ""
        preferBox.state = Self.state(model.preferOn)
        preferBox.isEnabled = model.preferEnabled
        preferHint.stringValue = model.preferHint
        iconWhileConnectedRadio.state = Self.state(!alwaysShowIcon)
        iconAlwaysRadio.state = Self.state(alwaysShowIcon)
        disconnectRadio.state = Self.state(!keepConnectionOnQuit)
        keepRadio.state = Self.state(keepConnectionOnQuit)
        loginBox.state = Self.state(openAtLogin)
        footer.stringValue = model.footer
    }

    /// The views of a page, top to bottom.
    private func arrangedViews(_ l: Layout) -> [NSView] {
        var instructions: [NSView] = []
        if l.showsCommand { instructions.append(command) }
        if l.showsCommandNote { instructions.append(commandNote) }
        // The link stays after a copy: the keyboard and VoiceOver can use it to copy again.
        if l.showsLink { instructions.append(link) }
        if l.showsAfterCopyHint { instructions.append(afterCopyHint) }
        if l.showsInstallMessage { instructions.append(installMessage) }
        let iconViews: [NSView] = [iconLabel, iconRadios, loginBox, loginHintRow]
        switch l.page {
        case .service:
            var views: [NSView] = [heading, firstParagraph]
            if l.showsSecondParagraph { views.append(secondParagraph) }
            return views + instructions + [buttonRow(l.showsPrimary ? [notNowButton, primaryButton] : [notNowButton])]
        case .options:
            var views: [NSView] = [heading, firstParagraph] + iconViews
            if l.showsQuitSetting { views += [quitLabel, quitRadios] }
            return views + [laterHint, buttonRow([doneButton])]
        case .settings:
            var views: [NSView] = [serviceLine]
            if l.showsServiceDetail { views.append(serviceDetail) }
            views += instructions
            // The button gets a row of its own: next to it the service line would be cut off.
            if l.showsPrimary { views.append(buttonRow([primaryButton])) }
            if l.showsPrefer { views += [separator(), preferBox, preferHintRow] }
            views += [separator()] + iconViews
            if l.showsQuitSetting { views += [separator(), quitLabel, quitRadios] }
            return views + [separator(), appliesHint, footer]
        }
    }

    private func relayout(_ l: Layout) {
        let views = arrangedViews(l)
        // Emptied first: reused views would keep their old places among the subviews, which
        // VoiceOver reads in order.
        stack.setViews([], in: .top)
        stack.setViews(views, in: .top)
        // Hints sit close to their checkbox; "Open at login" stands apart from the radios.
        // Custom spacing asserts for a view that is not arranged.
        let spacings: [(NSView, CGFloat)] = [(preferBox, 2), (loginBox, 2), (iconRadios, 16), (appliesHint, 4)]
        for (view, spacing) in spacings where views.contains(view) {
            stack.setCustomSpacing(spacing, after: view)
        }
        window.recalculateKeyViewLoop()  // Tab reaches the views of the new layout
    }

    /// Keeps the top edge in place.
    private func fit() {
        stack.layoutSubtreeIfNeeded()
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: stack.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if frame.size != window.frame.size { window.setFrame(frame, display: true) }
    }

    private func indented(_ views: [NSView]) -> NSStackView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return column
    }

    /// Buttons on the right, as in a dialog.
    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: [NSView()] + buttons)
        row.orientation = .horizontal
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return box
    }

    @objc private func performPrimary() {
        switch model.primary {
        case .run(let action)?: app.install(action)
        case .copy?: copyCommand()
        case nil: break
        }
    }

    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.copyText, forType: .string)
        copiedText = model.copyText
        app.render()
    }

    @objc private func togglePrefer(_ sender: NSButton) { app.setPreferPhone(sender.state == .on) }
    @objc private func toggleLogin() { app.toggleLogin() }
    @objc private func chooseIconVisibility(_ sender: NSButton) { app.setAlwaysShowIcon(sender == iconAlwaysRadio) }
    @objc private func chooseQuit(_ sender: NSButton) { app.setKeepConnectionOnQuit(sender == keepRadio) }

    @objc private func notNow() {
        skippedService = true
        showOptions()
        app.render()
    }

    @objc private func done() { window.close() }

    /// Closing the setup at any step finishes it with what is chosen so far.
    func windowWillClose(_ notification: Notification) {
        isOpen = false
        copiedText = nil
        layout = nil
        guard page != .settings else { return }
        page = .settings
        app.markSetUp()
        app.render()
    }
}
