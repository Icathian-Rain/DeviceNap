import AppKit

final class LogWindow: NSWindowController {
    private let textView = NSTextView.scrollableTextView()
    private let worker = DispatchQueue(label: "local.devicenap.log-reader", qos: .userInitiated)
    private lazy var refreshButton = NSButton(title: localized("刷新日志"), target: self, action: #selector(refresh))
    private lazy var copyButton = NSButton(title: localized("复制全部"), target: self, action: #selector(copyLog))
    private var contents = ""

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.title = localized("DeviceNap 日志")
        window.minSize = NSSize(width: 470, height: 250)
        window.center()

        let text = logText
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        textView.borderType = .bezelBorder

        copyButton.isEnabled = false
        let period = NSTextField(labelWithString: localized("最近 30 分钟"))
        period.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [period, NSView(), refreshButton, copyButton])
        controls.orientation = .horizontal
        controls.spacing = 8

        guard let content = window.contentView else { return }
        for view in [controls, textView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            textView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private var logText: NSTextView { textView.documentView as! NSTextView }

    func open() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc private func refresh() {
        guard refreshButton.isEnabled else { return }
        refreshButton.isEnabled = false
        if contents.isEmpty { logText.string = localized("正在读取日志…") }

        worker.async {
            let result = Self.recentLog()
            DispatchQueue.main.async {
                self.refreshButton.isEnabled = true
                self.contents = result ?? ""
                self.copyButton.isEnabled = !self.contents.isEmpty
                self.logText.string = result.map {
                    $0.isEmpty ? localized("最近 30 分钟没有日志") : $0
                } ?? localized("无法读取 DeviceNap 日志，请重试。")
                let end = (self.logText.string as NSString).length
                self.logText.scrollRangeToVisible(NSRange(location: end, length: 0))
            }
        }
    }

    @objc private func copyLog() {
        guard !contents.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents, forType: .string)
    }

    static func recentLog() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "30m", "--info", "--style", "compact",
                             "--predicate", "subsystem == \"local.devicenap\""]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { $0.contains("[local.devicenap:") }
            .joined(separator: "\n")
    }
}
