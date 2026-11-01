import AppKit

extension AppDelegate {
    static func menuBarImage(symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        image?.isTemplate = true
        return image
    }

    func buildStatusMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(.separator())
        let settingsItem = menu.addItem(
            withTitle: settingsMenuTitle, action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    /// The deferred render lands just past the deadline, so Visibility finds the delay over.
    private static let hideMargin = 0.05

    func renderStatusItem(_ model: MenuModel) {
        guard let statusItem else { return }  // nil until applicationDidFinishLaunching creates it
        let hideDelay = visibility.update(want: model.visible || menuOpen, now: uptime)
        if let hideDelay, !hidePending {  // one deferred render; later ones before it add none
            hidePending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay + Self.hideMargin) {
                self.hidePending = false
                self.render()
            }
        }
        if statusItem.isVisible != visibility.visible { statusItem.isVisible = visibility.visible }
        if let button = statusItem.button {
            let image: NSImage?
            let dimmed: Bool
            switch model.glyph {
            case .online: (image, dimmed) = (hotspotImage, false)
            case .dimmed: (image, dimmed) = (hotspotImage, true)
            case .offline where hotspotSlashImage != nil: (image, dimmed) = (hotspotSlashImage, false)
            case .offline: (image, dimmed) = (hotspotImage, true)  // macOS 13 and 14 have no slashed symbol
            }
            button.image = image
            button.appearsDisabled = dimmed
            button.setAccessibilityLabel("RNDIS Tether: \(model.summary)")
        }
        // The menu items only while the menu is open: updating them every few seconds costs energy.
        if menuOpen { renderMenu(model.rows) }
    }

    func renderMenu(_ rows: [MenuRow]) {
        if rowItems.count != rows.count {
            rowItems.forEach(menu.removeItem)
            rowItems = rows.map { _ in NSMenuItem() }
            for (index, item) in rowItems.enumerated() { menu.insertItem(item, at: index) }
        }
        for (item, row) in zip(rowItems, rows) { configure(item, with: row) }
    }

    func configure(_ item: NSMenuItem, with row: MenuRow) {
        item.title = row.accessibilityLabel ?? row.title
        item.toolTip = row.tooltip
        item.target = self
        guard let action = row.action else {
            let view = item.view as? InfoRowView ?? InfoRowView()
            view.show(row)
            item.view = view
            item.tag = 0
            item.action = nil
            item.isEnabled = false
            return
        }
        item.view = nil
        item.tag = action.rawValue
        item.action = #selector(performRowAction(_:))
        item.isEnabled = !row.disabled
    }
}

/// An info row: text in readable colors that cannot be clicked or highlighted, like the
/// details in macOS's Wi-Fi menu. A disabled item would grey its text and ignore colors.
final class InfoRowView: NSView {
    private static let inset: CGFloat = 14
    private static let height: CGFloat = 22
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ row: MenuRow) {
        label.attributedStringValue = Self.attributedText(row.title, style: row.style)
        label.cell?.setAccessibilityValue(row.accessibilityLabel ?? row.title)  // the cell answers for the label
        label.sizeToFit()
        toolTip = row.tooltip
        setFrameSize(NSSize(width: label.frame.width + 2 * Self.inset, height: Self.height))
        label.setFrameOrigin(NSPoint(x: Self.inset, y: ((Self.height - label.frame.height) / 2).rounded()))
    }

    private static func attributedText(_ text: String, style: MenuRow.Style) -> NSAttributedString {
        let size = NSFont.menuFont(ofSize: 0).pointSize
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.labelColor,
        ]
        switch style {
        case .primary: break
        case .title: attributes[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
        case .secondary: attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .speed:
            let digits = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            attributes[.font] = digits
            attributes[.paragraphStyle] = speedColumns(digits)
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// "↓ value ↑ value" in fixed columns: each value ends at the same x whatever its width,
    /// so the row and the menu keep their width while the speeds change.
    private static func speedColumns(_ font: NSFont) -> NSParagraphStyle {
        func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let arrow = width("↓ ")
        let value = width(speedText(999.9e6))
        let gap = width("   ")
        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: arrow + value),
            NSTextTab(textAlignment: .left, location: arrow + value + gap),
            NSTextTab(textAlignment: .right, location: 2 * (arrow + value) + gap),
        ]
        return style
    }
}
