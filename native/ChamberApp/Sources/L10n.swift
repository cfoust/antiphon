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
    // ---- intro gate ----
    "A team of agents, working around you in space. You hear them murmur as they work, and chime when they finish — turn to face one to listen.":
        ("Команда агентов работает вокруг вас в пространстве. Вы слышите их бормотание за работой и перезвон, когда они заканчивают, — повернитесь к агенту, чтобы послушать.",
         "一支智能体团队在你周围的空间中工作。工作时你能听到他们的低语，完成时会响起提示音——转头面向某个智能体即可聆听。",
         "一支智能體團隊在你周圍的空間中工作。工作時你能聽到他們的低語，完成時會響起提示音——轉頭面向某個智能體即可聆聽。"),
    "Headphones required": ("Нужны наушники", "需要耳机", "需要耳機"),
    "The audio is positioned in 3D — it only works over headphones.":
        ("Звук позиционируется в 3D — работает только в наушниках.",
         "音频以 3D 方式定位——只有戴耳机才有效。",
         "音訊以 3D 方式定位——只有戴耳機才有效。"),
    "Camera access": ("Доступ к камере", "摄像头权限", "攝影機權限"),
    "Turn your head to face agents. Video never leaves your device.":
        ("Поворачивайте голову к агентам. Видео не покидает ваше устройство.",
         "转头面向智能体。视频不会离开你的设备。",
         "轉頭面向智能體。影片不會離開你的裝置。"),
    "Enable camera & continue": ("Включить камеру и продолжить", "启用摄像头并继续", "啟用攝影機並繼續"),
    "Calibrate & start": ("Откалибровать и начать", "校准并开始", "校準並開始"),
    "Start": ("Начать", "开始", "開始"),
    "Calibration restored": ("Калибровка восстановлена", "已恢复校准", "已恢復校準"),
    "Head tracking ready": ("Трекинг головы готов", "头部追踪已就绪", "頭部追蹤已就緒"),
    "Looking for your face…": ("Ищем ваше лицо…", "正在寻找你的面部…", "正在尋找你的臉部…"),
    "Recalibrate": ("Перекалибровать", "重新校准", "重新校準"),
    "Debug tracking →": ("Отладка трекинга →", "追踪调试 →", "追蹤除錯 →"),

    // ---- calibration overlay ----
    "Look all the way left… and hold": ("Посмотрите до упора влево… и задержитесь", "把头转到最左边…保持不动", "把頭轉到最左邊…保持不動"),
    "Now all the way right… and hold": ("Теперь до упора вправо… и задержитесь", "再转到最右边…保持不动", "再轉到最右邊…保持不動"),
    "Calibrated": ("Откалибровано", "校准完成", "校準完成"),

    // ---- main window ----
    "Wake": ("Разбудить", "唤醒", "喚醒"),
    "Chamber settings": ("Настройки Chamber", "Chamber 设置", "Chamber 設定"),

    // ---- menu bar ----
    "Chamber is watching — click to close its eyes (camera off, silent)":
        ("Chamber наблюдает — нажмите, чтобы закрыть ему глаза (камера выключится, звук пропадёт)",
         "Chamber 正在观察——点击让它闭上眼睛（关闭摄像头并静音）",
         "Chamber 正在觀察——點擊讓它閉上眼睛（關閉攝影機並靜音）"),
    "Chamber is asleep — click to wake it":
        ("Chamber спит — нажмите, чтобы разбудить",
         "Chamber 正在休眠——点击唤醒",
         "Chamber 正在休眠——點擊喚醒"),
    "Chamber is watching": ("Chamber наблюдает", "Chamber 正在观察", "Chamber 正在觀察"),
    "Chamber is asleep": ("Chamber спит", "Chamber 正在休眠", "Chamber 正在休眠"),

    // ---- sidebar ----
    "IN THE ROOM": ("В КОМНАТЕ", "房间成员", "房間成員"),
    "SNOOZED": ("СПЯТ", "已休眠", "已休眠"),
    "No agents yet — sessions appear here as they join.":
        ("Агентов пока нет — сессии появятся здесь по мере подключения.",
         "还没有智能体——会话加入后会显示在这里。",
         "還沒有智能體——工作階段加入後會顯示在這裡。"),
    "Waiting for chamberd — running the canned demo.":
        ("Ожидание chamberd — идёт встроенная демонстрация.",
         "等待 chamberd——正在运行内置演示。",
         "等待 chamberd——正在執行內建演示。"),
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
    "Room": ("Комната", "房间", "房間"),
    "The acoustic the agents live in": ("Акустика, в которой живут агенты", "智能体所在的声学空间", "智能體所在的聲學空間"),
    "room.dry": ("сухая", "无混响", "無混響"),
    "room.fdn": ("комната (FDN)", "房间 (FDN)", "房間 (FDN)"),
    "hall.fdn": ("зал (FDN)", "大厅 (FDN)", "大廳 (FDN)"),
    "cathedral.fdn": ("собор (FDN)", "大教堂 (FDN)", "大教堂 (FDN)"),
    "room.brir": ("комната (BRIR)", "房间 (BRIR)", "房間 (BRIR)"),
    "hall.brir": ("зал (BRIR)", "大厅 (BRIR)", "大廳 (BRIR)"),
    "Reverb tail": ("Хвост реверберации", "混响尾音", "混響尾音"),
    "Blend the parametric tail with the measured one":
        ("Смешение параметрического хвоста с измеренным",
         "在参数化尾音与实测尾音之间混合",
         "在參數化尾音與實測尾音之間混合"),
    "HRTF fit": ("Подгонка HRTF", "HRTF 适配", "HRTF 適配"),
    "Dial until a voice straight ahead sits out in front at ear level":
        ("Крутите, пока голос прямо перед вами не окажется впереди, на уровне ушей",
         "调节直到正前方的声音真正悬在耳平线前方",
         "調節直到正前方的聲音真正懸在耳平線前方"),
    "Presence": ("Присутствие", "沉浸", "沉浸"),
    "Immersion fade": ("Эффект погружения", "沉浸淡入", "沉浸淡入"),
    "Close your eyes and the scene fills in; open them and it recedes":
        ("Закройте глаза — сцена проявится; откройте — отступит",
         "闭上眼睛场景浮现，睁开眼睛场景退去",
         "閉上眼睛場景浮現，睜開眼睛場景退去"),
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
    "chamberd isn't running — start the app's live mode and come back.":
        ("chamberd не запущен — запустите живой режим приложения и вернитесь.",
         "chamberd 未运行——请先启动应用的实时模式再回来。",
         "chamberd 未執行——請先啟動應用的即時模式再回來。"),
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
    "%@ has no input path — it isn’t in a pane chamber can type into":
        ("%@ недоступен для ввода — он не в панели, куда chamber может печатать",
         "%@ 没有输入通道——它不在 chamber 能输入文字的窗格里",
         "%@ 沒有輸入通道——它不在 chamber 能輸入文字的窗格裡"),
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

/// Localized room-preset names, index-aligned with the engine's rooms.
func localizedRoomNames() -> [String] {
    ["room.dry", "room.fdn", "hall.fdn", "cathedral.fdn", "room.brir", "hall.brir"].map {
        I18n.shared.lang == .en ? ROOM_NAMES_EN[$0] ?? $0 : L($0)
    }
}

private let ROOM_NAMES_EN: [String: String] = [
    "room.dry": "dry", "room.fdn": "room (FDN)", "hall.fdn": "hall (FDN)",
    "cathedral.fdn": "cathedral (FDN)", "room.brir": "room (BRIR)", "hall.brir": "hall (BRIR)",
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
