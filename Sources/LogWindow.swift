import AppKit
import OSLog

enum LogKind: String {
    case sleep, wake, connected, problem, connection

    var color: NSColor {
        switch self {
        case .sleep: return .systemPurple
        case .wake: return .systemBlue
        case .connected: return .systemGreen
        case .problem: return .systemRed
        case .connection: return .labelColor
        }
    }

    func write(_ message: String, persistent: Bool = false) {
        Logger(subsystem: "local.devicenap", category: rawValue)
            .log(level: persistent ? .default : .info, "\(message, privacy: .public)")
    }
}

struct LogEntry: Decodable {
    let timestamp: String
    let eventMessage: String
    let category: String

    var time: String { String(timestamp.dropFirst(11).prefix(12)) }

    var message: String {
        switch eventMessage {
        case "Bluetooth authorization: 0": return localized("等待蓝牙授权")
        case "Bluetooth authorization: 1": return localized("系统限制了蓝牙权限")
        case "Bluetooth authorization: 2": return localized("蓝牙权限已拒绝")
        case "Bluetooth authorization: 3": return localized("蓝牙权限已允许")
        default: return eventMessage
        }
    }

    var kind: LogKind {
        if let kind = LogKind(rawValue: category), kind != .connection { return kind }
        // Logs written by earlier versions all used the connection category.
        if ["收到系统睡眠通知", "System sleep notification received"].contains(eventMessage) { return .sleep }
        if ["收到系统唤醒通知", "System wake notification received"].contains(eventMessage) { return .wake }
        if eventMessage.contains("失败") || eventMessage.hasPrefix("未能") ||
            eventMessage.hasPrefix("Could not") || eventMessage == "Bluetooth authorization: 2" {
            return .problem
        }
        if eventMessage.contains(" 已连接") || eventMessage.contains(" connected") { return .connected }
        return .connection
    }
}

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
                self.display(result)
            }
        }
    }

    private func display(_ entries: [LogEntry]?) {
        guard let entries, !entries.isEmpty else {
            contents = ""
            copyButton.isEnabled = false
            logText.string = entries == nil
                ? localized("无法读取 DeviceNap 日志，请重试。")
                : localized("最近 30 分钟没有日志")
            return
        }

        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 5
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let messageFont = NSFont.systemFont(ofSize: 13)
        for (index, entry) in entries.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n")) }
            output.append(NSAttributedString(string: "\(entry.time)  ", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: timeFont,
            ]))
            output.append(NSAttributedString(string: entry.message, attributes: [
                .foregroundColor: entry.kind.color, .font: messageFont,
            ]))
        }
        output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length))
        contents = output.string
        copyButton.isEnabled = true
        logText.textStorage?.setAttributedString(output)
        logText.scrollRangeToVisible(NSRange(location: output.length, length: 0))
    }

    @objc private func copyLog() {
        guard !contents.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents, forType: .string)
    }

    static func recentLog() -> [LogEntry]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "30m", "--info", "--style", "ndjson",
                             "--predicate", "subsystem == \"local.devicenap\""]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let decoder = JSONDecoder()
        return data.split(separator: 10).compactMap { line in
            try? decoder.decode(LogEntry.self, from: Data(line))
        }
    }
}
