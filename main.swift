import AppKit
import UserNotifications

// 司法試験カウントダウン — メニューバー常駐アプリ
//
// 日程の自動推定 (R1-R3):
//   海の日 = 7月の第3月曜日 (ハッピーマンデー制度)
//   最終日 = 海の日の前日の日曜日
//   初日   = 最終日の4日前の水曜日 (= 海の日 - 5日)
//   試験期間 = 初日〜最終日の5日間 (「試験中」表示・残0日)
//   今年の最終日を過ぎたら自動的に翌年の推定日程へ切替
//
// 手動オーバーライド (R4):
//   exam-date.txt に YYYY-MM-DD を書くとその日を初日として優先。
//   "auto" と書く(またはメニューの「自動推定に戻す」)と推定に戻る。
//   手動指定した試験の最終日を過ぎたら自動推定に復帰。
//
// カウント表示 (R5):
//   常に「次の試験の初日までの実日数」。試験終了翌日から翌年推定日への
//   実カウント(例: 359日)が始まる。360固定は廃止。
//
// その他の機能:
//   - 0時ちょうどに自動更新 / スリープ復帰時更新 / 30分ごとの保険更新
//   - exam-date.txt の保存を検知して即時反映 (ファイル監視)
//   - 残100日以内オレンジ / 残30日以内赤 / 試験期間中は赤で「試験中」
//   - 表示形式の切替 (残n日 / D-n / 数字のみ) — UserDefaults に保存
//   - 通知はルールベース (notifications.json)。メニューの「通知設定…」から
//     タイミング (残n日 / 当日 / 期間中毎日) と文言を追加・変更・削除できる。
//     文言中の {n} は残日数に置換。通知時刻 (n時以降) も設定可能。

let configPath = ("~/ShihouCountdown/exam-date.txt" as NSString).expandingTildeInPath
let notifConfigPath = ("~/ShihouCountdown/notifications.json" as NSString).expandingTildeInPath

var calendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    return cal
}()

func dateFormatter() -> DateFormatter {
    let fmt = DateFormatter()
    fmt.calendar = calendar
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone.current
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt
}

// MARK: - 日程推定

enum ExamSource {
    case auto     // 海の日から推定
    case manual   // exam-date.txt の日付
}

struct ExamTarget {
    let firstDay: Date
    let lastDay: Date
    let source: ExamSource
}

/// 7月の第3月曜日 (海の日)
func marineDay(year: Int) -> Date {
    var comp = DateComponents()
    comp.year = year
    comp.month = 7
    comp.weekday = 2          // 月曜
    comp.weekdayOrdinal = 3   // 第3
    return calendar.startOfDay(for: calendar.date(from: comp)!)
}

/// 推定初日 = 海の日 - 5日 (水曜)
func estimatedFirstDay(year: Int) -> Date {
    calendar.date(byAdding: .day, value: -5, to: marineDay(year: year))!
}

/// exam-date.txt を読む。日付なら手動指定、"auto"・欠落・不正なら nil (=自動推定)
func readManualDate() -> Date? {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
    let line = text
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
    if line.lowercased() == "auto" { return nil }
    return dateFormatter().date(from: line)
}

/// 今日を基準に、カウント対象の試験 (初日・最終日・出所) を決める
func currentTarget(today: Date) -> ExamTarget {
    let t = calendar.startOfDay(for: today)

    // 手動指定があり、その試験がまだ終わっていなければ優先
    if let manual = readManualDate() {
        let first = calendar.startOfDay(for: manual)
        let last = calendar.date(byAdding: .day, value: 4, to: first)!
        if t <= last {
            return ExamTarget(firstDay: first, lastDay: last, source: .manual)
        }
        // 手動指定の試験が終了 → 自動推定に復帰
    }

    let year = calendar.component(.year, from: t)
    for y in [year, year + 1] {
        let first = estimatedFirstDay(year: y)
        let last = calendar.date(byAdding: .day, value: 4, to: first)!
        if t <= last {
            return ExamTarget(firstDay: first, lastDay: last, source: .auto)
        }
    }
    // 到達しないが安全側
    let first = estimatedFirstDay(year: year + 1)
    return ExamTarget(firstDay: first,
                      lastDay: calendar.date(byAdding: .day, value: 4, to: first)!,
                      source: .auto)
}

struct Countdown {
    let days: Int
    let isExamPeriod: Bool
}

func computeCountdown(today: Date, target: ExamTarget) -> Countdown {
    let t = calendar.startOfDay(for: today)
    if t >= target.firstDay && t <= target.lastDay {
        return Countdown(days: 0, isExamPeriod: true)
    }
    let days = calendar.dateComponents([.day], from: t, to: target.firstDay).day ?? 0
    return Countdown(days: max(0, days), isExamPeriod: false)
}

/// 進捗表示用: 前回試験の翌日から初日までの全日数
func totalCycleDays(target: ExamTarget) -> Int {
    let year = calendar.component(.year, from: target.firstDay)
    let prevLast = calendar.date(byAdding: .day, value: 4,
                                 to: estimatedFirstDay(year: year - 1))!
    let cycleStart = calendar.date(byAdding: .day, value: 1, to: prevLast)!
    return calendar.dateComponents([.day], from: cycleStart, to: target.firstDay).day ?? 360
}

// MARK: - 通知ルール設定

struct NotifRule: Codable {
    var enabled: Bool = true
    var kind: String = "before"   // "before"(残n日, days=0なら当日) | "examDay"(期間中毎日)
    var days: Int = 30
    var message: String = ""
}

struct NotifConfig: Codable {
    var notifyHour: Int = 8       // この時刻(時)以降に通知する
    var rules: [NotifRule]
}

func defaultNotifConfig() -> NotifConfig {
    NotifConfig(notifyHour: 8, rules: [
        NotifRule(kind: "before", days: 100, message: "試験まで残り {n} 日です。"),
        NotifRule(kind: "before", days: 50,  message: "試験まで残り {n} 日です。"),
        NotifRule(kind: "before", days: 30,  message: "試験まで残り {n} 日です。"),
        NotifRule(kind: "before", days: 7,   message: "試験まで残り {n} 日です。"),
        NotifRule(kind: "before", days: 1,   message: "いよいよ明日が試験1日目です。"),
        NotifRule(kind: "examDay", days: 0,  message: "おつかれさまです。がんばってください。"),
    ])
}

func loadNotifConfig() -> NotifConfig {
    if let data = FileManager.default.contents(atPath: notifConfigPath),
       let cfg = try? JSONDecoder().decode(NotifConfig.self, from: data) {
        return cfg
    }
    let cfg = defaultNotifConfig()
    saveNotifConfig(cfg)   // 初回はファイルを作って手編集もできるようにする
    return cfg
}

func saveNotifConfig(_ cfg: NotifConfig) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(cfg) {
        try? data.write(to: URL(fileURLWithPath: notifConfigPath))
    }
}

// MARK: - アプリ本体

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var safetyTimer: Timer?
    var fileWatcher: DispatchSourceFileSystemObject?

    let dateLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let detailLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let progressLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var formatItems: [NSMenuItem] = []

    var notifConfig = loadNotifConfig()
    var settingsController: SettingsWindowController?
    var settingsWindow: NSWindow? { settingsController?.window }

    var displayFormat: String {
        get { UserDefaults.standard.string(forKey: "displayFormat") ?? "kanji" }
        set { UserDefaults.standard.set(newValue, forKey: "displayFormat") }
    }

    // 通知はバンドル内で動いている時のみ使える (素のバイナリだとクラッシュするためガード)
    var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.addItem(dateLabel)
        menu.addItem(detailLabel)
        menu.addItem(progressLabel)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "試験日を手動設定…",
                                action: #selector(setExamDate), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "自動推定に戻す",
                                action: #selector(useAutoEstimate), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "通知設定…",
                                action: #selector(openNotifSettings), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "設定ファイルを編集",
                                action: #selector(editConfig), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "再読み込み",
                                action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())

        // 表示形式サブメニュー
        let formatMenu = NSMenu()
        for (key, label) in [("kanji", "残n日"), ("dday", "D-n"), ("number", "数字のみ")] {
            let item = NSMenuItem(title: label, action: #selector(chooseFormat(_:)), keyEquivalent: "")
            item.representedObject = key
            item.target = self
            formatMenu.addItem(item)
            formatItems.append(item)
        }
        let formatRoot = NSMenuItem(title: "表示形式", action: nil, keyEquivalent: "")
        formatRoot.submenu = formatMenu
        menu.addItem(formatRoot)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        updateFormatChecks()
        refresh()
        setupFileWatcher()

        // 自己テスト用: --test-settings で通知設定画面を開いて生存確認
        if CommandLine.arguments.contains("--test-settings") {
            openNotifSettings()
        }
        // 自己テスト用: --selftest-save で「テキスト欄編集→保存→ファイル反映」を検証
        if CommandLine.arguments.contains("--selftest-save") {
            runSaveSelfTest()
        }

        // 0時ちょうどの日付変更で更新
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: .NSCalendarDayChanged, object: nil)
        // スリープ復帰時に即更新
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didWakeNotification, object: nil)
        // 保険として30分ごとにも更新
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        if notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: - 表示更新

    @objc func refresh() {
        // 設定ウィンドウが開いていない時はディスクの最新設定を反映（手編集も拾う）
        if settingsWindow == nil { notifConfig = loadNotifConfig() }
        let target = currentTarget(today: Date())
        let cd = computeCountdown(today: Date(), target: target)

        // メニューバーのタイトルと色
        let title: String
        if cd.isExamPeriod {
            title = "試験中"
        } else {
            switch displayFormat {
            case "dday":   title = "D-\(cd.days)"
            case "number": title = "\(cd.days)"
            default:       title = "残\(cd.days)日"
            }
        }
        let color: NSColor
        if cd.isExamPeriod || cd.days <= 30 {
            color = .systemRed
        } else if cd.days <= 100 {
            color = .systemOrange
        } else {
            color = .labelColor
        }
        setTitle(title, color: color)

        // メニュー内の情報表示
        let jfmt = DateFormatter()
        jfmt.locale = Locale(identifier: "ja_JP")
        jfmt.dateFormat = "yyyy/MM/dd"
        let sourceLabel = target.source == .auto ? "自動推定" : "手動設定"
        dateLabel.title = cd.isExamPeriod
            ? "司法試験 試験期間中"
            : "司法試験まで残り \(cd.days) 日"
        detailLabel.title = "試験1日目: \(jfmt.string(from: target.firstDay))（\(sourceLabel)）"
        if cd.isExamPeriod {
            progressLabel.title = "■■■■■■■■■■ 本番!"
        } else {
            let total = max(totalCycleDays(target: target), 1)
            let elapsed = max(0, total - min(cd.days, total))
            let pct = Int((Double(elapsed) / Double(total) * 100).rounded())
            let filled = min(10, max(0, Int((Double(pct) / 10.0).rounded())))
            let bar = String(repeating: "■", count: filled)
                    + String(repeating: "□", count: 10 - filled)
            progressLabel.title = "\(bar) \(pct)%（経過 \(elapsed)/\(total) 日）"
        }

        checkMilestones(cd, examKey: dateFormatter().string(from: target.firstDay))
    }

    func setTitle(_ title: String, color: NSColor) {
        statusItem.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.menuBarFont(ofSize: 0),
            ])
    }

    // MARK: - 通知

    func checkMilestones(_ cd: Countdown, examKey: String) {
        guard notificationsAvailable else { return }

        // 通知時刻(n時)より前は通知しない
        let hour = calendar.component(.hour, from: Date())
        guard hour >= notifConfig.notifyHour else { return }

        let today = dateFormatter().string(from: Date())

        for (idx, rule) in notifConfig.rules.enumerated() {
            guard rule.enabled else { continue }

            let matches: Bool
            let dedupeKey: String
            switch rule.kind {
            case "examDay":
                // 試験期間中(初日〜最終日の5日間)は毎日通知。日付単位で重複防止
                matches = cd.isExamPeriod
                dedupeKey = "notif-\(idx)-\(today)"
            default: // "before"
                matches = !cd.isExamPeriod && cd.days == rule.days
                dedupeKey = "notif-\(idx)-\(examKey)-\(rule.days)"
            }
            guard matches else { continue }
            guard !UserDefaults.standard.bool(forKey: dedupeKey) else { continue }
            UserDefaults.standard.set(true, forKey: dedupeKey)

            let content = UNMutableNotificationContent()
            content.title = "司法試験カウントダウン"
            content.body = rule.message.replacingOccurrences(of: "{n}", with: "\(cd.days)")
            content.sound = .default
            let req = UNNotificationRequest(identifier: "\(dedupeKey)-\(UUID().uuidString)",
                                            content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    // MARK: - 設定ファイル監視 (保存を検知して即反映)

    func setupFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else {
            // ファイルが無くても自動推定で動くが、作成されたら拾えるよう再試行
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.setupFileWatcher()
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.fileWatcher?.data ?? []
            self.refresh()
            // エディタの多くは保存時にファイルを置き換えるため監視を張り直す
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.setupFileWatcher()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatcher = src
    }

    func writeConfig(_ line: String) {
        let content = "# \"auto\" = 海の日(7月第3月曜)から自動推定 / YYYY-MM-DD = 初日を手動指定\n\(line)\n"
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        refresh()
        setupFileWatcher()   // atomic書き込みでinodeが変わるため張り直し
    }

    // MARK: - メニュー操作

    @objc func setExamDate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "司法試験の1日目を手動設定"
        alert.informativeText = "公式日程が推定とズレた場合に使います。この日から5日間が試験期間になります。その試験が終わると自動推定に戻ります。"
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.dateValue = currentTarget(today: Date()).firstDay
        alert.accessoryView = picker
        alert.window.initialFirstResponder = picker
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            writeConfig(dateFormatter().string(from: picker.dateValue))
        }
    }

    @objc func useAutoEstimate() {
        writeConfig("auto")
    }

    @objc func chooseFormat(_ sender: NSMenuItem) {
        displayFormat = sender.representedObject as? String ?? "kanji"
        updateFormatChecks()
        refresh()
    }

    func updateFormatChecks() {
        for item in formatItems {
            item.state = (item.representedObject as? String == displayFormat) ? .on : .off
        }
    }

    @objc func editConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc func openNotifSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let controller = settingsController {
            controller.window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController(config: notifConfig) { [weak self] newConfig in
            guard let self else { return }
            saveNotifConfig(newConfig)
            self.notifConfig = newConfig
            self.refresh()
        }
        controller.onClose = { [weak self] in self?.settingsController = nil }
        settingsController = controller
        controller.window.makeKeyAndOrderFront(nil)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    /// 「最終行を追加→残日数と文言をキーボード編集→保存」までを実際のUI経路で再現し、
    /// notifications.json に反映されるか検証する。
    func runSaveSelfTest() {
        let c = SettingsWindowController(config: loadNotifConfig()) { cfg in
            saveNotifConfig(cfg)
        }
        c.window.makeKeyAndOrderFront(nil)
        c.addRule()                                   // 末尾に新規ルール
        let last = c.rules.count - 1
        // 残日数フィールドを実際に取得して編集イベントを発火
        guard let daysView = c.table.view(atColumn: 2, row: last, makeIfNecessary: true) as? NSTextField,
              let msgView  = c.table.view(atColumn: 3, row: last, makeIfNecessary: true) as? NSTextField else {
            print("SELFTEST: FAIL (cell views not found)"); exit(2)
        }
        daysView.stringValue = "330"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: daysView))
        msgView.stringValue = "司法試験から1ヶ月経ちました。"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: msgView))
        c.saveAndClose()

        let saved = loadNotifConfig()
        let ok = saved.rules.contains { $0.days == 330 && $0.message == "司法試験から1ヶ月経ちました。" }
        print("SELFTEST: \(ok ? "PASS" : "FAIL") — saved rules=\(saved.rules.count)")
        exit(ok ? 0 : 1)
    }
}

// MARK: - 通知設定ウィンドウ

final class SettingsWindowController: NSObject, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate,
                                      NSTextFieldDelegate {
    // テキスト欄の種別 (tag)
    static let tagDays = 1
    static let tagMessage = 2
    static let tagHour = 3

    let window: NSWindow
    let onSave: (NotifConfig) -> Void
    var onClose: (() -> Void)?

    var rules: [NotifRule]
    var notifyHour: Int
    let table = NSTableView()
    let hourField = NSTextField()
    let hourStepper = NSStepper()

    init(config: NotifConfig, onSave: @escaping (NotifConfig) -> Void) {
        self.rules = config.rules
        self.notifyHour = config.notifyHour
        self.onSave = onSave
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "通知設定"
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        buildUI()
    }

    func buildUI() {
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        // 説明
        let help = NSTextField(labelWithString:
            "通知のタイミングと文言を編集できます。文言の {n} は残日数に置き換わります。")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 16, y: 428, width: 588, height: 18)
        help.autoresizingMask = [.width, .minYMargin]
        content.addSubview(help)

        // 通知時刻
        let hourLabel = NSTextField(labelWithString: "通知する時刻:")
        hourLabel.frame = NSRect(x: 16, y: 398, width: 90, height: 20)
        hourLabel.autoresizingMask = [.minYMargin]
        content.addSubview(hourLabel)

        hourField.frame = NSRect(x: 108, y: 396, width: 46, height: 22)
        hourField.alignment = .right
        hourField.integerValue = notifyHour
        hourField.tag = Self.tagHour
        hourField.delegate = self
        hourField.autoresizingMask = [.minYMargin]
        content.addSubview(hourField)

        hourStepper.frame = NSRect(x: 156, y: 395, width: 19, height: 24)
        hourStepper.minValue = 0
        hourStepper.maxValue = 23
        hourStepper.integerValue = notifyHour
        hourStepper.valueWraps = true
        hourStepper.target = self
        hourStepper.action = #selector(hourStepperChanged)
        hourStepper.autoresizingMask = [.minYMargin]
        content.addSubview(hourStepper)

        let hourSuffix = NSTextField(labelWithString: "時以降（0時に鳴らないための設定）")
        hourSuffix.font = .systemFont(ofSize: 11)
        hourSuffix.textColor = .secondaryLabelColor
        hourSuffix.frame = NSRect(x: 180, y: 398, width: 380, height: 18)
        hourSuffix.autoresizingMask = [.minYMargin]
        content.addSubview(hourSuffix)

        // テーブル
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 92, width: 588, height: 296))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        func col(_ id: String, _ title: String, _ width: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            return c
        }
        table.addTableColumn(col("enabled", "有効", 42))
        table.addTableColumn(col("kind", "タイミング", 150))
        table.addTableColumn(col("days", "残日数", 64))
        table.addTableColumn(col("message", "メッセージ（{n}=残日数）", 300))
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        content.addSubview(scroll)

        // ＋／－ ボタン
        let addBtn = NSButton(title: "＋ 追加", target: self, action: #selector(addRule))
        addBtn.bezelStyle = .rounded
        addBtn.frame = NSRect(x: 16, y: 52, width: 90, height: 28)
        addBtn.autoresizingMask = [.maxYMargin]
        content.addSubview(addBtn)

        let removeBtn = NSButton(title: "－ 削除", target: self, action: #selector(removeRule))
        removeBtn.bezelStyle = .rounded
        removeBtn.frame = NSRect(x: 112, y: 52, width: 90, height: 28)
        removeBtn.autoresizingMask = [.maxYMargin]
        content.addSubview(removeBtn)

        let resetBtn = NSButton(title: "初期設定に戻す", target: self, action: #selector(resetRules))
        resetBtn.bezelStyle = .rounded
        resetBtn.frame = NSRect(x: 208, y: 52, width: 130, height: 28)
        resetBtn.autoresizingMask = [.maxYMargin]
        content.addSubview(resetBtn)

        // 保存／キャンセル
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveAndClose))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 514, y: 14, width: 90, height: 30)
        saveBtn.autoresizingMask = [.maxYMargin]
        content.addSubview(saveBtn)

        let cancelBtn = NSButton(title: "キャンセル", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.frame = NSRect(x: 410, y: 14, width: 100, height: 30)
        cancelBtn.autoresizingMask = [.maxYMargin]
        content.addSubview(cancelBtn)
    }

    // MARK: テーブル データ

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let rule = rules[row]
        switch id {
        case "enabled":
            let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            cb.state = rule.enabled ? .on : .off
            return cb
        case "kind":
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            pop.addItems(withTitles: ["残n日前", "試験期間中（毎日）"])
            pop.selectItem(at: rule.kind == "examDay" ? 1 : 0)
            pop.target = self
            pop.action = #selector(kindChanged(_:))
            return pop
        case "days":
            let tf = NSTextField()
            tf.alignment = .right
            tf.isEnabled = (rule.kind != "examDay")
            tf.stringValue = rule.kind == "examDay" ? "—" : "\(rule.days)"
            tf.tag = Self.tagDays
            tf.delegate = self          // 1文字ごとにモデルへ反映
            return tf
        case "message":
            let tf = NSTextField()
            tf.stringValue = rule.message
            tf.tag = Self.tagMessage
            tf.delegate = self          // 1文字ごとにモデルへ反映
            return tf
        default:
            return nil
        }
    }

    // MARK: 行編集ハンドラ（row(for:) で行を特定し、reload後のズレを防ぐ）

    @objc func toggleEnabled(_ sender: NSButton) {
        let r = table.row(for: sender); guard r >= 0 else { return }
        rules[r].enabled = (sender.state == .on)
    }

    @objc func kindChanged(_ sender: NSPopUpButton) {
        let r = table.row(for: sender); guard r >= 0 else { return }
        rules[r].kind = sender.indexOfSelectedItem == 1 ? "examDay" : "before"
        table.reloadData()
    }

    // テキスト欄は1文字ごとに controlTextDidChange でモデルへ即反映する。
    // これにより「入力しただけで保存を押すと取りこぼす」問題を防ぐ。
    func controlTextDidChange(_ notification: Notification) {
        guard let tf = notification.object as? NSTextField else { return }
        if tf === hourField {
            if let v = Int(tf.stringValue) { notifyHour = min(23, max(0, v)) }
            return
        }
        let r = table.row(for: tf); guard r >= 0, r < rules.count else { return }
        switch tf.tag {
        case Self.tagDays:
            if let v = Int(tf.stringValue), v >= 0 { rules[r].days = v }
        case Self.tagMessage:
            rules[r].message = tf.stringValue
        default:
            break
        }
    }

    // MARK: ボタン

    @objc func addRule() {
        commitFields()
        rules.append(NotifRule(enabled: true, kind: "before", days: 10, message: "試験まで残り {n} 日です。"))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: rules.count - 1), byExtendingSelection: false)
    }

    @objc func removeRule() {
        commitFields()
        let r = table.selectedRow
        guard r >= 0 && r < rules.count else { NSSound.beep(); return }
        rules.remove(at: r)
        table.reloadData()
    }

    @objc func resetRules() {
        let def = defaultNotifConfig()
        rules = def.rules
        notifyHour = def.notifyHour
        hourField.integerValue = notifyHour
        hourStepper.integerValue = notifyHour
        table.reloadData()
    }

    @objc func hourStepperChanged() {
        notifyHour = hourStepper.integerValue
        hourField.integerValue = notifyHour
    }

    /// 編集中のテキスト欄を確定させる (保険。実データは controlTextDidChange で反映済み)
    func commitFields() {
        window.makeFirstResponder(nil)
        notifyHour = min(23, max(0, notifyHour))
        hourField.integerValue = notifyHour
        hourStepper.integerValue = notifyHour
    }

    @objc func saveAndClose() {
        commitFields()
        onSave(NotifConfig(notifyHour: notifyHour, rules: rules))
        window.close()
    }

    @objc func cancel() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dockに出さずメニューバーのみ
let delegate = AppDelegate()
app.delegate = delegate
app.run()
