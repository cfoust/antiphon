import Combine
import Foundation

// In-code localization. The bundle is assembled by make.sh (no Xcode, no
// lproj compilation), and the language must be switchable at RUNTIME for
// spot-checking translations — so strings live in a Swift table keyed by
// their English text, and views observe I18n.shared to re-render on switch.
//
// Usage: L("Start"), Lf("send to %@", name). A missing key returns the
// English key itself, so untranslated strings degrade gracefully.

enum AppLang: String, CaseIterable, Identifiable {
    case en
    case ru
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        }
    }
    /// Best match for the system's preferred language (first launch default).
    static func system() -> AppLang {
        for pref in Locale.preferredLanguages {
            let p = pref.lowercased()
            if p.hasPrefix("ru") { return .ru }
            if p.hasPrefix("zh") {
                return (p.contains("hant") || p.contains("tw") || p.contains("hk") || p.contains("mo"))
                    ? .zhHant : .zhHans
            }
            if p.hasPrefix("en") { return .en }
        }
        return .en
    }
}

final class I18n: ObservableObject {
    static let shared = I18n()
    @Published var lang: AppLang {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "ui.lang") }
    }
    private init() {
        if let saved = UserDefaults.standard.string(forKey: "ui.lang"),
           let l = AppLang(rawValue: saved) {
            lang = l
        } else {
            lang = AppLang.system()
        }
    }
}

/// Translate. The English string is the key.
func L(_ key: String) -> String {
    guard I18n.shared.lang != .en, let row = TBL[key] else { return key }
    switch I18n.shared.lang {
    case .en: return key
    case .ru: return row.0
    case .zhHans: return row.1
    case .zhHant: return row.2
    }
}

/// Translate a format string, then substitute.
func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// Russian needs three plural forms; Chinese needs none. `forms` is the
/// English (one, many) pair's key — the table stores "|"-separated variants.
func LPlural(_ n: Int, en: (String, String), ruForms: (String, String, String),
             zhHans: String, zhHant: String) -> String {
    switch I18n.shared.lang {
    case .en: return String(format: n == 1 ? en.0 : en.1, n)
    case .zhHans: return String(format: zhHans, n)
    case .zhHant: return String(format: zhHant, n)
    case .ru:
        let m10 = n % 10, m100 = n % 100
        let form: String
        if m10 == 1 && m100 != 11 { form = ruForms.0 }
        else if (2...4).contains(m10) && !(12...14).contains(m100) { form = ruForms.1 }
        else { form = ruForms.2 }
        return String(format: form, n)
    }
}

/// "N voices in the pool" with correct Russian plurals.
func LVoicePool(_ n: Int) -> String {
    LPlural(n, en: ("%d voice in the pool", "%d voices in the pool"),
            ruForms: ("%d голос в пуле", "%d голоса в пуле", "%d голосов в пуле"),
            zhHans: "声音池中共有 %d 个声音", zhHant: "聲音池中共有 %d 個聲音")
}

/// "N voices" (provider row) with correct Russian plurals.
func LVoiceCount(_ n: Int) -> String {
    LPlural(n, en: ("%d voice", "%d voices"),
            ruForms: ("%d голос", "%d голоса", "%d голосов"),
            zhHans: "%d 个声音", zhHant: "%d 個聲音")
}

// (ru, zh-Hans, zh-Hant)
private let TBL: [String: (String, String, String)] = [
    // ---- welcome (copy from the marketing-site handoff) ----
    "Your agents, speaking. You, listening.":
        ("Ваши агенты говорят. Вы слушаете.",
         "你的智能体在诉说。你在聆听。",
         "你的智能體在訴說。你在聆聽。"),
    "Antiphon gives every coding agent a voice, placed in the room around you. Put on headphones and overhear the work.":
        ("Antiphon даёт каждому агенту голос, размещённый в комнате вокруг вас. Наденьте наушники и слушайте, как идёт работа.",
         "Antiphon 为每个编程智能体赋予声音，安放在你周围的房间里。戴上耳机，聆听工作的进行。",
         "Antiphon 為每個編程智能體賦予聲音，安放在你周圍的房間裡。戴上耳機，聆聽工作的進行。"),
    "By Caleb Foust": ("Автор — Caleb Foust", "作者：Caleb Foust", "作者：Caleb Foust"),
    "Turn your head to face agents. Video never leaves your device.":
        ("Поворачивайте голову к агентам. Видео не покидает ваше устройство.",
         "转头面向智能体。视频不会离开你的设备。",
         "轉頭面向智能體。影片不會離開你的裝置。"),
    "Enable camera & continue": ("Включить камеру и продолжить", "启用摄像头并继续", "啟用攝影機並繼續"),
    "Start": ("Начать", "开始", "開始"),
    "Calibration restored": ("Калибровка восстановлена", "已恢复校准", "已恢復校準"),
    "Head tracking ready": ("Трекинг головы готов", "头部追踪已就绪", "頭部追蹤已就緒"),
    "Looking for your face…": ("Ищем ваше лицо…", "正在寻找你的面部…", "正在尋找你的臉部…"),
    "Recalibrate": ("Перекалибровать", "重新校准", "重新校準"),
    "Set up again": ("Настроить заново", "重新设置", "重新設定"),
    "Debug tracking →": ("Отладка трекинга →", "追踪调试 →", "追蹤除錯 →"),

    // ---- onboarding (on-screen copy matches the spoken cues 1:1 —
    //      tools/gen-onboarding-voices.py keeps the same texts) ----
    "Camera": ("Камера", "摄像头", "攝影機"),
    "Pick the camera that watches you.": ("Выберите камеру, которая будет за вами наблюдать.", "选择用来观察你的摄像头。", "選擇用來觀察你的攝影機。"),
    "Continue": ("Продолжить", "继续", "繼續"),
    "Skip": ("Пропустить", "跳过", "跳過"),
    "Turn your head all the way to the left… and hold still.":
        ("Поверните голову до упора влево… и замрите.", "把头一直转到最左边……保持不动。", "把頭一直轉到最左邊……保持不動。"),
    "Now all the way to the right… and hold still.":
        ("Теперь до упора вправо… и замрите.", "现在转到最右边……保持不动。", "現在轉到最右邊……保持不動。"),
    "Done. You're calibrated.": ("Готово. Калибровка завершена.", "好了，校准完成。", "好了，校準完成。"),
    "Hold still…": ("Замрите…", "保持不动……", "保持不動……"),
    "Fit": ("Подгонка", "适配", "適配"),
    "Move the slider until my voice sits just ahead of you, out in the room.":
        ("Двигайте ползунок, пока мой голос не окажется прямо перед вами, в глубине комнаты.",
         "移动滑块，直到我的声音悬在你正前方的空间里。",
         "移動滑塊，直到我的聲音懸在你正前方的空間裡。"),
    "Adjust until my voice sits straight ahead of you":
        ("Настраивайте, пока мой голос не окажется прямо перед вами",
         "调节直到我的声音位于你的正前方",
         "調節直到我的聲音位於你的正前方"),

    // ---- main window ----
    "Wake": ("Разбудить", "唤醒", "喚醒"),
    "Settings": ("Настройки", "设置", "設定"),

    // ---- camera-denied recovery (welcome) ----
    "Camera access is off for Antiphon.":
        ("Доступ к камере для Antiphon выключен.",
         "Antiphon 的摄像头访问权限已关闭。",
         "Antiphon 的攝影機存取權限已關閉。"),
    "Open System Settings": ("Открыть Системные настройки", "打开系统设置", "打開系統設定"),
    "Try again": ("Попробовать снова", "重试", "重試"),

    // ---- settings: startup + about ----
    "Startup": ("Автозапуск", "启动", "啟動"),
    "Start at login": ("Запускать при входе", "登录时启动", "登入時啟動"),
    "Antiphon opens quietly when you log in":
        ("Antiphon будет тихо открываться при входе в систему",
         "登录后 Antiphon 会安静地自动打开",
         "登入後 Antiphon 會安靜地自動打開"),
    "About": ("О приложении", "关于", "關於"),
    "Version": ("Версия", "版本", "版本"),
    "Support": ("Поддержка", "支持", "支援"),
    "Guides, the protocol, and a place to report problems":
        ("Руководства, протокол и место, где можно сообщить о проблеме",
         "指南、协议，以及报告问题的地方",
         "指南、協定，以及回報問題的地方"),
    "Documentation": ("Документация", "文档", "文件"),
    "Report an issue": ("Сообщить о проблеме", "报告问题", "回報問題"),
    "Antiphon Documentation": ("Документация Antiphon", "Antiphon 文档", "Antiphon 文件"),
    "About Antiphon": ("Об Antiphon", "关于 Antiphon", "關於 Antiphon"),
    "Settings…": ("Настройки…", "设置…", "設定…"),
    "Quit Antiphon": ("Завершить Antiphon", "退出 Antiphon", "結束 Antiphon"),
    "Check for Updates…": ("Проверить обновления…", "检查更新…", "檢查更新…"),
    "Updates": ("Обновления", "更新", "更新"),
    "Up to date": ("У вас последняя версия", "已是最新版本", "已是最新版本"),
    "New version: %@": ("Новая версия: %@", "新版本：%@", "新版本：%@"),
    "Download": ("Скачать", "下载", "下載"),
    "Check now": ("Проверить сейчас", "立即检查", "立即檢查"),

    // ---- settings: immersion + language ----
    "Immersion": ("Погружение", "沉浸", "沉浸"),
    "Fade-in delay": ("Задержка появления", "淡入延迟", "淡入延遲"),
    "How long your eyes stay closed before the room fades in — raise it if blinks trigger it":
        ("Сколько глаза должны быть закрыты, прежде чем комната проявится — увеличьте, если срабатывает от морганий",
         "闭眼多久后房间才淡入——如果眨眼就会误触发，请调大",
         "閉眼多久後房間才淡入——如果眨眼就會誤觸發，請調大"),
    "send": ("отправить", "发送", "傳送"),
    "Waiting cue": ("Сигнал ожидания", "等待提示音", "等待提示音"),
    "With your eyes open, agents that finished build a quiet chord over minutes":
        ("Пока глаза открыты, закончившие агенты за несколько минут наращивают тихий аккорд",
         "睁眼时，已完成的智能体会在几分钟里慢慢积累一段安静的和声",
         "睜眼時，已完成的代理會在幾分鐘裡慢慢累積一段安靜的和聲"),
    "Menus, statuses, and the spoken cues":
        ("Меню, статусы и голосовые подсказки", "菜单、状态与语音提示", "選單、狀態與語音提示"),
    "Check automatically": ("Проверять автоматически", "自动检查", "自動檢查"),
    "Once a day, from GitHub — nothing is sent":
        ("Раз в день, через GitHub — ничего не отправляется",
         "每天一次，向 GitHub 查询——不发送任何数据",
         "每天一次，向 GitHub 查詢——不傳送任何資料"),
    "Not checked yet": ("Ещё не проверялось", "尚未检查", "尚未檢查"),

    // ---- menu bar ----
    "Antiphon is watching — click to close its eyes (camera off, silent)":
        ("Antiphon наблюдает — нажмите, чтобы закрыть ему глаза (камера выключится, звук пропадёт)",
         "Antiphon 正在观察——点击让它闭上眼睛（关闭摄像头并静音）",
         "Antiphon 正在觀察——點擊讓它閉上眼睛（關閉攝影機並靜音）"),
    "Antiphon is asleep — click to wake it":
        ("Antiphon спит — нажмите, чтобы разбудить",
         "Antiphon 正在休眠——点击唤醒",
         "Antiphon 正在休眠——點擊喚醒"),
    "Antiphon is watching": ("Antiphon наблюдает", "Antiphon 正在观察", "Antiphon 正在觀察"),
    "Antiphon is asleep": ("Antiphon спит", "Antiphon 正在休眠", "Antiphon 正在休眠"),

    // ---- sidebar ----
    "IN THE ROOM": ("В КОМНАТЕ", "房间成员", "房間成員"),
    "SNOOZED": ("СПЯТ", "已休眠", "已休眠"),
    "No agents yet — sessions appear here as they join.":
        ("Агентов пока нет — сессии появятся здесь по мере подключения.",
         "还没有智能体——会话加入后会显示在这里。",
         "還沒有智能體——工作階段加入後會顯示在這裡。"),
    "Waiting for antiphond — running the canned demo.":
        ("Ожидание antiphond — идёт встроенная демонстрация.",
         "等待 antiphond——正在运行内置演示。",
         "等待 antiphond——正在執行內建演示。"),
    "Snooze — out of the room, keeps updating":
        ("Усыпить — вне комнаты, но обновления продолжаются",
         "休眠——移出房间，仍继续接收更新",
         "休眠——移出房間，仍繼續接收更新"),
    "Wake — back into the room": ("Разбудить — вернуть в комнату", "唤醒——回到房间", "喚醒——回到房間"),

    // status codes (engine → sidebar)
    "status.working": ("работает", "工作中", "工作中"),
    "status.idle": ("простаивает", "空闲", "閒置"),
    "status.reporting": ("докладывает", "汇报中", "回報中"),
    "status.resting": ("отдыхает", "休息中", "休息中"),
    "status.waiting": ("закончил — ждёт, чтобы доложить", "已完成——等待汇报", "已完成——等待回報"),
    "status.waiting.gone": ("закончил — сводка ждёт", "已完成——摘要待听", "已完成——摘要待聽"),

    // ---- settings ----
    "SETTINGS": ("НАСТРОЙКИ", "设置", "設定"),
    "General": ("Основные", "通用", "一般"),
    "Voices": ("Голоса", "语音", "語音"),
    "Sound": ("Звук", "声音", "聲音"),
    "Tracking": ("Трекинг", "追踪", "追蹤"),
    "Calibration": ("Калибровка", "校准", "校準"),
    "Re-run the look-left / look-right sweep in the main window":
        ("Повторить проход «влево-вправо» в главном окне",
         "在主窗口重新执行左右转头校准",
         "在主視窗重新執行左右轉頭校準"),
    "Diagnostics": ("Диагностика", "诊断", "診斷"),
    "Landmarks, latency and the eye-closure signal, live":
        ("Ориентиры лица, задержка и сигнал закрытия глаз — вживую",
         "实时查看面部特征点、延迟与闭眼信号",
         "即時查看臉部特徵點、延遲與閉眼訊號"),
    "Open tracking debug": ("Открыть отладку трекинга", "打开追踪调试", "打開追蹤除錯"),
    "Language": ("Язык", "语言", "語言"),
    "For spot-checking the translations": ("Для проверки переводов", "用于抽查翻译", "用於抽查翻譯"),

    // ---- voices pane ----
    "Each agent draws a voice at random from the pool below when it first joins, and keeps it for the life of the session.":
        ("Каждый агент при первом подключении получает случайный голос из пула ниже и сохраняет его до конца сессии.",
         "每个智能体首次加入时会从下方的声音池中随机抽取一个声音，并在整个会话期间保持不变。",
         "每個智能體首次加入時會從下方的聲音池中隨機抽取一個聲音，並在整個工作階段期間保持不變。"),
    "The audio daemon couldn't be started — see ~/.antiphon/antiphond.log.":
        ("Не удалось запустить звуковой демон — см. ~/.antiphon/antiphond.log.",
         "无法启动音频守护进程——请查看 ~/.antiphon/antiphond.log。",
         "無法啟動音訊常駐程式——請查看 ~/.antiphon/antiphond.log。"),
    "Refresh": ("Обновить", "刷新", "重新整理"),
    "ElevenLabs": ("ElevenLabs", "ElevenLabs", "ElevenLabs"),
    "OpenAI": ("OpenAI", "OpenAI", "OpenAI"),
    "macOS": ("macOS", "macOS", "macOS"),
    "Your voice library, discovered from the account":
        ("Ваша библиотека голосов, обнаруженная в аккаунте", "从账户中发现的你的声音库", "從帳戶中發現的你的聲音庫"),
    "The speech API's built-in voices":
        ("Встроенные голоса Speech API", "语音 API 的内置声音", "語音 API 的內建聲音"),
    "The system voices — free, offline, always the fallback":
        ("Системные голоса — бесплатно, офлайн, всегда запасной вариант",
         "系统声音——免费、离线、始终作为兜底",
         "系統聲音——免費、離線、始終作為後備"),
    "API key": ("API-ключ", "API 密钥", "API 金鑰"),
    "A key is saved — enter a new one to replace it":
        ("Ключ сохранён — введите новый, чтобы заменить", "已保存密钥——输入新密钥可替换", "已儲存金鑰——輸入新金鑰可替換"),
    "No key yet": ("Ключа пока нет", "尚无密钥", "尚無金鑰"),
    "paste key": ("вставьте ключ", "粘贴密钥", "貼上金鑰"),
    "needs an API key": ("нужен API-ключ", "需要 API 密钥", "需要 API 金鑰"),
    "off": ("выключен", "已关闭", "已關閉"),
    "discovery failed: %@": ("обнаружение не удалось: %@", "发现失败：%@", "發現失敗：%@"),
    "active": ("активен", "已启用", "已啟用"),
    "inactive": ("неактивен", "未启用", "未啟用"),
    "Apply": ("Применить", "应用", "套用"),
    "Applying…": ("Применяем…", "正在应用…", "正在套用…"),

    // ---- talk-back panel ----
    "tell %@…": ("скажите %@…", "对 %@ 说…", "對 %@ 說…"),
    "%@ has no input path — it isn’t in a pane Antiphon can type into":
        ("%@ недоступен для ввода — он не в панели, куда Antiphon может печатать",
         "%@ 没有输入通道——它不在 Antiphon 能输入文字的窗格里",
         "%@ 沒有輸入通道——它不在 Antiphon 能輸入文字的窗格裡"),
    "can’t hear you": ("вас не слышит", "听不到你", "聽不到你"),
    "send to %@": ("отправить %@", "发送给 %@", "傳送給 %@"),
    "listening only": ("только прослушивание", "只能旁听", "只能旁聽"),
    "let go": ("отпустить", "放开", "放開"),
    "tag.task": ("ЗАДАЧА", "任务", "任務"),
    "tag.progress": ("ХОД", "进展", "進展"),
    "tag.done": ("ГОТОВО", "完成", "完成"),
    "tag.blocked": ("БЛОК", "受阻", "受阻"),
    "tag.tool": ("ИНСТР.", "工具", "工具"),
]

/// Sidebar status text from the engine's locale-independent code.
func LStatus(_ code: String) -> String {
    if I18n.shared.lang == .en {
        switch code {
        case "waiting": return "finished — waiting to report"
        case "waiting.gone": return "finished — summary waiting"
        default: return code // working / idle / reporting / resting read as-is
        }
    }
    return L("status.\(code)")
}

/// Transcript tag label (task/progress/done/blocked), localized + uppercased style.
func LTag(_ kind: String) -> String {
    let key = "tag.\(kind)"
    let v = L(key)
    return v == key ? kind.uppercased() : v
}

/// Compact age: "42s" / "3m" / "2h", localized unit letters.
func LAge(_ at: TimeInterval) -> String {
    let d = max(0, Date().timeIntervalSince1970 - at)
    let (s, m, h): (String, String, String)
    switch I18n.shared.lang {
    case .en: (s, m, h) = ("s", "m", "h")
    case .ru: (s, m, h) = ("с", "м", "ч")
    case .zhHans: (s, m, h) = ("秒", "分", "时")
    case .zhHant: (s, m, h) = ("秒", "分", "時")
    }
    if d < 60 { return "\(Int(d))\(s)" }
    if d < 3600 { return "\(Int(d / 60))\(m)" }
    return "\(Int(d / 3600))\(h)"
}
