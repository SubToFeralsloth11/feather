import AppKit
import WebKit

/// Thin loading bar drawn over the top of the page.
final class ProgressBar: NSView {
    private let fill = CALayer()

    var progress: Double = 0 {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(progress == 0)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shown instead of a web view for new (empty) tabs and sleeping tabs. Costs no web process.
final class PlaceholderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func show(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
    }
}

/// Find-in-page bar (⌘F).
@MainActor
final class FindBar: NSView {
    let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    var onFind: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = "Find on page"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(next)
        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")!, target: self, action: #selector(previousMatch))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")!, target: self, action: #selector(next))
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        for button in [previous, next] { button.bezelStyle = .texturedRounded }
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [field, previous, next, status, NSView(), done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFound(_ found: Bool) {
        status.stringValue = found || field.stringValue.isEmpty ? "" : "Not found"
    }

    @objc func next() { onFind?(field.stringValue, false) }
    @objc func previousMatch() { onFind?(field.stringValue, true) }
    @objc func close() { onClose?() }

    override func cancelOperation(_ sender: Any?) { close() }
}

/// Records which item of a pop-up menu was chosen.
final class MenuPicker: NSObject {
    private(set) var selected: Int?

    @objc func pick(_ sender: NSMenuItem) {
        selected = sender.tag
    }
}
