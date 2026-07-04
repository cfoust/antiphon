// Site-wide i18n: en / ru / zh-Hans / zh-Hant, runtime-switchable.
// The marketing copy is deliberately written per language (not machine-keyed):
// the voice matters more than string reuse. The hero demo's spoken lines live
// in hero-timeline.<lang>.json (they must match the rendered soundtrack, so the
// generator owns them); everything visual lives here.

export type Lang = "en" | "ru" | "zh-Hans" | "zh-Hant";
export const LANGS: Lang[] = ["en", "ru", "zh-Hans", "zh-Hant"];
export const LANG_LABELS: Record<Lang, string> = {
  en: "EN",
  ru: "РУ",
  "zh-Hans": "简",
  "zh-Hant": "繁",
};

const KEY = "antiphon.lang";

export function detectLang(): Lang {
  const q = new URLSearchParams(location.search).get("lang");
  if (q && (LANGS as string[]).includes(q)) return q as Lang;
  const saved = localStorage.getItem(KEY);
  if (saved && (LANGS as string[]).includes(saved)) return saved as Lang;
  const nav = navigator.language || "";
  if (nav.startsWith("ru")) return "ru";
  if (/^zh\b/.test(nav)) {
    return /Hant|TW|HK|MO/i.test(nav) ? "zh-Hant" : "zh-Hans";
  }
  return "en";
}

export function saveLang(l: Lang): void {
  localStorage.setItem(KEY, l);
}

interface Bubble {
  label: string;
  text: string;
  you?: boolean;
}

interface Tenet {
  title: string;
  body: string;
}

interface EngCard {
  index: string;
  title: string;
  body: string;
}

export interface HeroStrings {
  watching: string;
  eyesClosed: string;
  tracked: string;
  hint: string;
  idleTitle: string;
  begin: string;
  idleNote: string;
  done: string;
  unmute: string;
  soundOn: string;
  replay: string;
}

export interface SiteStrings {
  title: string;
  nav: { sounds: string; feels: string; engineering: string; download: string };
  hero: { h1: string; sub: string; download: string; browser: string; fineprint: string };
  listen: { eyebrow: string; h2: string; intro: string; note: string; cta: string };
  feel: { eyebrow: string; h2: string; bubbles: Bubble[]; tenets: Tenet[] };
  choir: {
    eyebrow: string;
    h2: string;
    intro: string;
    full: string;
    fullTalkback: string;
    presence: string;
    yourAgent: string;
    openProtocol: string;
    link: string;
  };
  eng: { eyebrow: string; h2: string; cards: EngCard[] };
  get: { h2: string; sub: string; download: string; demo: string; fineprint: string };
  footer: { greek: string; docs: string };
  hx: HeroStrings;
}

export const SITE: Record<Lang, SiteStrings> = {
  en: {
    title: "Antiphon — your agents, speaking",
    nav: {
      sounds: "How it sounds",
      feels: "How it feels",
      engineering: "Engineering",
      download: "Download for macOS",
    },
    hero: {
      h1: "Your agents, speaking.<br>You, listening.",
      sub: "Antiphon gives every coding agent a voice, placed in the room around you. Put on headphones and overhear the work.",
      download: "Download for macOS",
      browser: "Try it in the browser",
      fineprint: "Free &amp; open source · Headphones recommended",
    },
    listen: {
      eyebrow: "How it sounds",
      h2: "Close your eyes.",
      intro:
        "When you do, the terminals disappear and another room appears — voices placed in real space, each exactly where its work is. This is the whole pitch, in fifteen seconds.",
      note: "In the app, voices are real speech — synthesized, spatialized, and yours to answer. Here, a sketch in tone and caption.",
      cta: "Try the web demo",
    },
    feel: {
      eyebrow: "How it feels",
      h2: "Overhear the workshop.",
      bubbles: [
        { label: "agent · to your left", text: "“Reworking the auth token flow. Tests next.”" },
        { label: "you", text: "“Keep the refresh logic. Just tighten expiry.”", you: true },
        { label: "agent · behind, slightly right", text: "“Tests are failing — digging in.”" },
      ],
      tenets: [
        {
          title: "Placed in space",
          body: "Each agent has a position — left, right, near, far. Turn your head and the voices stay put in the room.",
        },
        {
          title: "Gentle by design",
          body: "A waiting agent builds a soft harmonic cue in one ear rather than interrupting. Nothing pings. Nothing flashes.",
        },
        {
          title: "Talk back",
          body: "Answer in a keystroke — or just speak, with voice input like Wispr Flow. Call and response, across the room.",
        },
      ],
    },
    choir: {
      eyebrow: "Voices in the choir",
      h2: "Sings with your agents.",
      intro:
        "Antiphon listens to agent sessions through a small plugin and a local daemon. Open source, open protocol.",
      full: "Full fidelity",
      fullTalkback: "Full fidelity + talk-back",
      presence: "Presence + nudges",
      yourAgent: "Your agent here",
      openProtocol: "Open protocol · PRs welcome",
      link: "Write an adapter on GitHub →",
    },
    eng: {
      eyebrow: "Engineering",
      h2: "Built like an instrument.",
      cards: [
        {
          index: "01 · spatial engine",
          title: "Research-grade binaural rendering",
          body: "A real spatial-audio engine written from scratch in Rust: HRTF rendering, early reflections, room reverb. Voices have position, distance, and presence — over ordinary headphones.",
        },
        {
          index: "02 · head tracking",
          title: "The room holds still",
          body: "Your webcam tracks your head. Turn to look at a voice and it stays exactly where it was — anchored to the room, not to your ears.",
        },
        {
          index: "03 · one core",
          title: "Native and web, byte-identical",
          body: "The macOS app and the browser demo run the same DSP core, verified to produce byte-identical output. What you hear in the demo is the product.",
        },
        {
          index: "04 · attention, composed",
          title: "Voices, not notifications",
          body: "Waiting agents build gentle harmonic cues instead of firing alerts. The soundscape is mixed like music — so ten agents feel like a workshop, not a slot machine.",
        },
      ],
    },
    get: {
      h2: "Let something keep watch.",
      sub: "Antiphon lives in your menu bar — a small eye, always listening on your behalf. Free and open source.",
      download: "Download for macOS",
      demo: "Open the web demo",
      fineprint: "macOS 14+ · Apple silicon · MIT license",
    },
    footer: {
      greek: "ἀντίφωνον — voices, answering across a space",
      docs: "Docs",
    },
    hx: {
      watching: "watching",
      eyesClosed: "eyes closed",
      tracked: "head &amp; eyes tracked",
      hint: "the room, from above — voices stay put as you turn",
      idleTitle: "Put on headphones.",
      begin: "Close your eyes ↵",
      idleNote: "The real workflow, in half a minute · rendered by the real engine · sound on",
      done: "DONE",
      unmute: "🔇 unmute",
      soundOn: "🔊 sound on",
      replay: "replay ⟳",
    },
  },

  ru: {
    title: "Antiphon — ваши агенты говорят",
    nav: {
      sounds: "Как это звучит",
      feels: "Каково это",
      engineering: "Инженерия",
      download: "Скачать для macOS",
    },
    hero: {
      h1: "Ваши агенты говорят.<br>Вы — слушаете.",
      sub: "Antiphon даёт каждому кодинг-агенту голос и место в комнате вокруг вас. Наденьте наушники — и просто слушайте, как идёт работа.",
      download: "Скачать для macOS",
      browser: "Попробовать в браузере",
      fineprint: "Бесплатно и открыто · Рекомендуются наушники",
    },
    listen: {
      eyebrow: "Как это звучит",
      h2: "Закройте глаза.",
      intro:
        "Стоит закрыть глаза — терминалы исчезают, и появляется другая комната: голоса, расставленные в настоящем пространстве, каждый ровно там, где его работа. Вся суть — за пятнадцать секунд.",
      note: "В приложении голоса — настоящая речь: синтезированная, размещённая в пространстве, и ей можно ответить. Здесь — набросок тоном и подписью.",
      cta: "Открыть веб-демо",
    },
    feel: {
      eyebrow: "Каково это",
      h2: "Подслушайте мастерскую.",
      bubbles: [
        { label: "агент · слева от вас", text: "«Переделываю поток auth-токенов. Дальше — тесты.»" },
        { label: "вы", text: "«Оставь логику refresh. Только подтяни срок действия.»", you: true },
        { label: "агент · сзади, чуть правее", text: "«Тесты падают — разбираюсь.»" },
      ],
      tenets: [
        {
          title: "Место в пространстве",
          body: "У каждого агента есть позиция — слева, справа, ближе, дальше. Поверните голову — и голоса останутся там же, в комнате.",
        },
        {
          title: "Деликатность по умолчанию",
          body: "Ожидающий агент медленно наращивает мягкий гармонический сигнал в одном ухе — вместо того чтобы перебивать. Ничего не пищит. Ничего не мигает.",
        },
        {
          title: "Разговор в обе стороны",
          body: "Ответьте одним нажатием — или просто скажите вслух, через голосовой ввод вроде Wispr Flow. Зов и отклик, через всю комнату.",
        },
      ],
    },
    choir: {
      eyebrow: "Голоса в хоре",
      h2: "Поёт вместе с вашими агентами.",
      intro:
        "Antiphon слушает сессии агентов через небольшой плагин и локальный демон. Открытый код, открытый протокол.",
      full: "Полная поддержка",
      fullTalkback: "Полная поддержка + ответы",
      presence: "Присутствие + напоминания",
      yourAgent: "Ваш агент здесь",
      openProtocol: "Открытый протокол · PR приветствуются",
      link: "Написать адаптер на GitHub →",
    },
    eng: {
      eyebrow: "Инженерия",
      h2: "Собран как инструмент.",
      cards: [
        {
          index: "01 · пространственный движок",
          title: "Бинауральный рендеринг исследовательского уровня",
          body: "Настоящий движок пространственного звука, написанный с нуля на Rust: HRTF-рендеринг, ранние отражения, реверберация комнаты. У голосов есть позиция, расстояние и присутствие — в обычных наушниках.",
        },
        {
          index: "02 · трекинг головы",
          title: "Комната стоит на месте",
          body: "Веб-камера следит за вашей головой. Повернитесь к голосу — он останется ровно там же: привязан к комнате, а не к вашим ушам.",
        },
        {
          index: "03 · одно ядро",
          title: "Нативно и в вебе — байт в байт",
          body: "Приложение для macOS и браузерное демо работают на одном DSP-ядре, и их вывод совпадает с точностью до байта. То, что вы слышите в демо, — и есть продукт.",
        },
        {
          index: "04 · внимание, сведённое как музыка",
          title: "Голоса, а не уведомления",
          body: "Ожидающие агенты наращивают мягкие гармонические сигналы вместо алертов. Звуковая сцена сведена как музыка — десять агентов ощущаются мастерской, а не игровым автоматом.",
        },
      ],
    },
    get: {
      h2: "Пусть кто-то присматривает.",
      sub: "Antiphon живёт в строке меню — маленький глаз, который всегда слушает за вас. Бесплатно и с открытым кодом.",
      download: "Скачать для macOS",
      demo: "Открыть веб-демо",
      fineprint: "macOS 14+ · Apple silicon · Лицензия MIT",
    },
    footer: {
      greek: "ἀντίφωνον — голоса, отвечающие друг другу через пространство",
      docs: "Документация",
    },
    hx: {
      watching: "слежу",
      eyesClosed: "глаза закрыты",
      tracked: "голова и глаза отслеживаются",
      hint: "комната сверху — голоса остаются на месте, когда вы поворачиваетесь",
      idleTitle: "Наденьте наушники.",
      begin: "Закройте глаза ↵",
      idleNote: "Настоящий рабочий процесс за полминуты · отрендерено настоящим движком · со звуком",
      done: "ГОТОВО",
      unmute: "🔇 включить звук",
      soundOn: "🔊 звук включён",
      replay: "ещё раз ⟳",
    },
  },

  "zh-Hans": {
    title: "Antiphon——你的智能体在开口",
    nav: {
      sounds: "听起来如何",
      feels: "用起来如何",
      engineering: "工程",
      download: "下载 macOS 版",
    },
    hero: {
      h1: "你的智能体在开口。<br>你在聆听。",
      sub: "Antiphon 给每个编程智能体一个声音，安放在你周围的房间里。戴上耳机，听工作自己发生。",
      download: "下载 macOS 版",
      browser: "在浏览器里试试",
      fineprint: "免费开源 · 建议佩戴耳机",
    },
    listen: {
      eyebrow: "听起来如何",
      h2: "闭上眼睛。",
      intro:
        "闭上眼睛，终端消失，另一个房间浮现——声音安放在真实的空间里，每一个都正好在它工作的位置。十五秒，讲完整个故事。",
      note: "在应用里，声音是真正的语音——合成、空间化、可以应答。这里只是音调与字幕的速写。",
      cta: "试试网页演示",
    },
    feel: {
      eyebrow: "用起来如何",
      h2: "听见你的工坊。",
      bubbles: [
        { label: "智能体 · 在你左边", text: "“正在重做鉴权令牌流程。接下来跑测试。”" },
        { label: "你", text: "“保留刷新逻辑，只收紧过期时间。”", you: true },
        { label: "智能体 · 身后偏右", text: "“测试挂了——正在查。”" },
      ],
      tenets: [
        {
          title: "安放于空间",
          body: "每个智能体都有位置——左、右、近、远。转过头去，声音仍留在房间原处。",
        },
        {
          title: "温和为本",
          body: "等待中的智能体在一只耳朵里慢慢积累一段柔和的和声，而不是打断你。没有提示音，没有闪烁。",
        },
        {
          title: "随口应答",
          body: "一次按键就能回复——或者直接开口，用 Wispr Flow 这样的语音输入。一呼一应，隔着房间。",
        },
      ],
    },
    choir: {
      eyebrow: "合唱团里的声音",
      h2: "与你的智能体同声歌唱。",
      intro: "Antiphon 通过一个小插件和一个本地守护进程聆听智能体会话。开源，开放协议。",
      full: "完整支持",
      fullTalkback: "完整支持 + 对话回传",
      presence: "在场 + 轻提醒",
      yourAgent: "你的智能体",
      openProtocol: "开放协议 · 欢迎 PR",
      link: "在 GitHub 上写一个适配器 →",
    },
    eng: {
      eyebrow: "工程",
      h2: "像乐器一样打造。",
      cards: [
        {
          index: "01 · 空间引擎",
          title: "研究级双耳渲染",
          body: "一个从零用 Rust 写成的空间音频引擎：HRTF 渲染、早期反射、房间混响。声音有位置、有距离、有存在感——用普通耳机就能听到。",
        },
        {
          index: "02 · 头部追踪",
          title: "房间纹丝不动",
          body: "摄像头追踪你的头部。转头看向一个声音，它仍在原处——锚定在房间里，而不是你的耳朵上。",
        },
        {
          index: "03 · 同一内核",
          title: "原生与网页，逐字节一致",
          body: "macOS 应用和浏览器演示运行同一个 DSP 内核，输出经验证逐字节一致。你在演示里听到的，就是产品本身。",
        },
        {
          index: "04 · 编排注意力",
          title: "是声音，不是通知",
          body: "等待中的智能体累积温和的和声提示，而不是弹出警报。整个声景像音乐一样混音——十个智能体听起来像一间工坊，而不是一台老虎机。",
        },
      ],
    },
    get: {
      h2: "让一双眼睛替你守望。",
      sub: "Antiphon 住在菜单栏里——一只小小的眼睛，始终替你聆听。免费且开源。",
      download: "下载 macOS 版",
      demo: "打开网页演示",
      fineprint: "macOS 14+ · Apple 芯片 · MIT 许可证",
    },
    footer: {
      greek: "ἀντίφωνον——隔着空间彼此应答的声音",
      docs: "文档",
    },
    hx: {
      watching: "注视中",
      eyesClosed: "眼睛已闭",
      tracked: "追踪头部与眼睛",
      hint: "俯瞰房间——转头时，声音留在原地",
      idleTitle: "戴上耳机。",
      begin: "闭上眼睛 ↵",
      idleNote: "真实工作流，半分钟 · 由真实引擎渲染 · 建议开声音",
      done: "完成",
      unmute: "🔇 开启声音",
      soundOn: "🔊 声音已开",
      replay: "重播 ⟳",
    },
  },

  "zh-Hant": {
    title: "Antiphon——你的代理在說話",
    nav: {
      sounds: "聽起來如何",
      feels: "用起來如何",
      engineering: "工程",
      download: "下載 macOS 版",
    },
    hero: {
      h1: "你的代理在說話。<br>你在聆聽。",
      sub: "Antiphon 給每個程式代理一個聲音，安放在你周圍的房間裡。戴上耳機，聽工作自己發生。",
      download: "下載 macOS 版",
      browser: "在瀏覽器裡試試",
      fineprint: "免費開源 · 建議佩戴耳機",
    },
    listen: {
      eyebrow: "聽起來如何",
      h2: "閉上眼睛。",
      intro:
        "閉上眼睛，終端機消失，另一個房間浮現——聲音安放在真實的空間裡，每一個都正好在它工作的位置。十五秒，說完整個故事。",
      note: "在應用程式裡，聲音是真正的語音——合成、空間化、可以應答。這裡只是音調與字幕的速寫。",
      cta: "試試網頁展示",
    },
    feel: {
      eyebrow: "用起來如何",
      h2: "聽見你的工坊。",
      bubbles: [
        { label: "代理 · 在你左邊", text: "「正在重做驗證權杖流程。接下來跑測試。」" },
        { label: "你", text: "「保留 refresh 邏輯，只要收緊過期時間。」", you: true },
        { label: "代理 · 身後偏右", text: "「測試掛了——正在查。」" },
      ],
      tenets: [
        {
          title: "安放於空間",
          body: "每個代理都有位置——左、右、近、遠。轉過頭去，聲音仍留在房間原處。",
        },
        {
          title: "溫和為本",
          body: "等待中的代理在一隻耳朵裡慢慢累積一段柔和的和聲，而不是打斷你。沒有提示音，沒有閃爍。",
        },
        {
          title: "隨口應答",
          body: "一個按鍵就能回覆——或者直接開口，用 Wispr Flow 這類語音輸入。一呼一應，隔著房間。",
        },
      ],
    },
    choir: {
      eyebrow: "合唱團裡的聲音",
      h2: "與你的代理同聲歌唱。",
      intro: "Antiphon 透過一個小外掛和一個本機常駐程式聆聽代理工作階段。開放原始碼，開放協定。",
      full: "完整支援",
      fullTalkback: "完整支援 + 對話回傳",
      presence: "在場 + 輕提醒",
      yourAgent: "你的代理",
      openProtocol: "開放協定 · 歡迎 PR",
      link: "到 GitHub 上寫一個 adapter →",
    },
    eng: {
      eyebrow: "工程",
      h2: "像樂器一樣打造。",
      cards: [
        {
          index: "01 · 空間引擎",
          title: "研究等級的雙耳渲染",
          body: "一個從零用 Rust 寫成的空間音訊引擎：HRTF 渲染、早期反射、房間殘響。聲音有位置、有距離、有存在感——用普通耳機就能聽到。",
        },
        {
          index: "02 · 頭部追蹤",
          title: "房間紋絲不動",
          body: "攝影機追蹤你的頭部。轉頭看向一個聲音，它仍在原處——錨定在房間裡，而不是你的耳朵上。",
        },
        {
          index: "03 · 同一核心",
          title: "原生與網頁，逐位元組一致",
          body: "macOS 應用程式和瀏覽器展示執行同一個 DSP 核心，輸出經驗證逐位元組一致。你在展示裡聽到的，就是產品本身。",
        },
        {
          index: "04 · 編排注意力",
          title: "是聲音，不是通知",
          body: "等待中的代理累積溫和的和聲提示，而不是跳出警示。整個聲景像音樂一樣混音——十個代理聽起來像一間工坊，而不是一台吃角子老虎機。",
        },
      ],
    },
    get: {
      h2: "讓一雙眼睛替你守望。",
      sub: "Antiphon 住在選單列裡——一隻小小的眼睛，始終替你聆聽。免費且開放原始碼。",
      download: "下載 macOS 版",
      demo: "打開網頁展示",
      fineprint: "macOS 14+ · Apple 晶片 · MIT 授權",
    },
    footer: {
      greek: "ἀντίφωνον——隔著空間彼此應答的聲音",
      docs: "文件",
    },
    hx: {
      watching: "注視中",
      eyesClosed: "眼睛已閉",
      tracked: "追蹤頭部與眼睛",
      hint: "俯瞰房間——轉頭時，聲音留在原地",
      idleTitle: "戴上耳機。",
      begin: "閉上眼睛 ↵",
      idleNote: "真實工作流程，半分鐘 · 由真實引擎渲染 · 建議開聲音",
      done: "完成",
      unmute: "🔇 開啟聲音",
      soundOn: "🔊 聲音已開",
      replay: "重播 ⟳",
    },
  },
};
