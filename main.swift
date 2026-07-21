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
//   - 節目 (100/50/30/7/1日) に一度だけ通知
//   - 試験期間中は1日1回 (朝8時以降) 応援通知

let configPath = ("~/ShihouCountdown/exam-date.txt" as NSString).expandingTildeInPath

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

// MARK: - アプリ本体

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var safetyTimer: Timer?
    var fileWatcher: DispatchSourceFileSystemObject?

    let dateLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let detailLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let progressLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var formatItems: [NSMenuItem] = []

    let milestones = [100, 50, 30, 7, 1]

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

        // 試験期間中は1日1回、朝8時以降に応援通知
        if cd.isExamPeriod {
            let today = dateFormatter().string(from: Date())
            let hour = calendar.component(.hour, from: Date())
            let key = "cheered-\(today)"
            if hour >= 8, !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                let content = UNMutableNotificationContent()
                content.title = "司法試験カウントダウン"
                content.body = "おつかれさまです。がんばってください。"
                content.sound = .default
                let req = UNNotificationRequest(identifier: "cheer-\(today)",
                                                content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
            }
            return
        }

        for m in milestones where cd.days == m {
            let key = "notified-\(examKey)-\(m)"
            guard !UserDefaults.standard.bool(forKey: key) else { continue }
            UserDefaults.standard.set(true, forKey: key)
            let content = UNMutableNotificationContent()
            content.title = "司法試験カウントダウン"
            content.body = m == 1 ? "いよいよ明日が試験1日目です。" : "試験まで残り \(m) 日です。"
            content.sound = .default
            let req = UNNotificationRequest(identifier: "milestone-\(examKey)-\(m)",
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

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dockに出さずメニューバーのみ
let delegate = AppDelegate()
app.delegate = delegate
app.run()
