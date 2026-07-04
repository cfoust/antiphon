// Web-demo strings, en/ru/zh-Hans/zh-Hant. Where a string also exists in the
// native app, the translation mirrors L10n.swift EXACTLY — the spoken
// onboarding cues (public/audio/*.<lang>.mp3, copied from the app bundle)
// speak these same sentences, and screen and voice must agree.

import { detectLang, type Lang } from "./site/i18n";
export { detectLang, saveLang, LANGS, LANG_LABELS, type Lang } from "./site/i18n";

export interface DemoStrings {
  title: string;
  tag: string;
  body: string;
  headphonesNote: string;
  enable: string;
  start: string;
  camNote: string;
  recal: string;
  foot: string;
  // statuses
  startingAudio: string;
  cantStartAudio: string;
  requestingCamera: string;
  loadingModel: string;
  lookingFace: string;
  calRestored: string;
  trackingReady: string;
  startAnyway: string;
  continueLabel: string;
  cameraDenied: string;
  noTracking: string;
  startWithout: string;
  willSetupAgain: string;
  // calibration
  calLeft: string;
  calRight: string;
  calDone: string;
  holdStill: string;
  // fit
  fitTitle: string;
  fitSub: string;
  // room UI
  sayPlaceholder: string;
  sayPlaceholderSeat: string;
  wakeTip: string;
  snoozeTip: string;
  noAgents: string;
  waitingAgents: string;
  status: Record<string, string>;
}

export const DEMO: Record<Lang, DemoStrings> = {
  en: {
    title: "Antiphon — web demo",
    tag: "Your agents, speaking. You, listening.",
    body: "Antiphon gives every coding agent a voice, placed in the room around you. Put on headphones and overhear the work.",
    headphonesNote: "Headphones required — the audio is positioned in 3D.",
    enable: "Enable camera & continue",
    start: "Start",
    camNote: "Turn your head to face agents. Video never leaves your device.",
    recal: "Set up again",
    foot: "By Caleb Foust",
    startingAudio: "Starting audio…",
    cantStartAudio: "Couldn't start audio: ",
    requestingCamera: "Requesting camera…",
    loadingModel: "Loading head-tracking model…",
    lookingFace: "Looking for your face…",
    calRestored: "Calibration restored",
    trackingReady: "Head tracking ready",
    startAnyway: "Start anyway",
    continueLabel: "Continue",
    cameraDenied: "Camera denied — starting without head tracking.",
    noTracking: "No head tracking — the room still works.",
    startWithout: "Start without head tracking",
    willSetupAgain: "Will set up again on start",
    calLeft: "Turn your head all the way to the left… and hold still.",
    calRight: "Now all the way to the right… and hold still.",
    calDone: "Done. You're calibrated.",
    holdStill: "Hold still…",
    fitTitle: "Fit",
    fitSub: "Move the slider until my voice sits just ahead of you, out in the room.",
    sayPlaceholder: "Face an agent, then type to send…",
    sayPlaceholderSeat: "Type a message to this agent…",
    wakeTip: "Wake — back into the room",
    snoozeTip: "Snooze — out of the room, keeps updating",
    noAgents: "No agents yet — sessions appear here as they join.",
    waitingAgents: "Waiting for agents…",
    status: {
      "finished — summary waiting": "finished — summary waiting",
      "finished — waiting to report": "finished — waiting to report",
      reporting: "reporting",
      resting: "resting",
      working: "working",
      idle: "idle",
    },
  },

  ru: {
    title: "Antiphon — веб-демо",
    tag: "Ваши агенты говорят. Вы слушаете.",
    body: "Antiphon даёт каждому агенту голос, размещённый в комнате вокруг вас. Наденьте наушники и слушайте, как идёт работа.",
    headphonesNote: "Нужны наушники — звук позиционируется в 3D.",
    enable: "Включить камеру и продолжить",
    start: "Начать",
    camNote: "Поворачивайте голову к агентам. Видео не покидает ваше устройство.",
    recal: "Настроить заново",
    foot: "Автор — Caleb Foust",
    startingAudio: "Запускаем звук…",
    cantStartAudio: "Не удалось запустить звук: ",
    requestingCamera: "Запрашиваем камеру…",
    loadingModel: "Загружаем модель трекинга головы…",
    lookingFace: "Ищем ваше лицо…",
    calRestored: "Калибровка восстановлена",
    trackingReady: "Трекинг головы готов",
    startAnyway: "Начать всё равно",
    continueLabel: "Продолжить",
    cameraDenied: "Камера недоступна — начинаем без трекинга головы.",
    noTracking: "Трекинга головы нет — комната всё равно работает.",
    startWithout: "Начать без трекинга головы",
    willSetupAgain: "Настройка запустится заново при старте",
    calLeft: "Поверните голову до упора влево… и замрите.",
    calRight: "Теперь до упора вправо… и замрите.",
    calDone: "Готово. Калибровка завершена.",
    holdStill: "Замрите…",
    fitTitle: "Подгонка",
    fitSub: "Двигайте ползунок, пока мой голос не окажется прямо перед вами, в глубине комнаты.",
    sayPlaceholder: "Повернитесь к агенту и напишите…",
    sayPlaceholderSeat: "Напишите сообщение этому агенту…",
    wakeTip: "Разбудить — вернуть в комнату",
    snoozeTip: "Усыпить — вне комнаты, но обновления идут",
    noAgents: "Агентов пока нет — сессии появятся здесь по мере подключения.",
    waitingAgents: "Ждём агентов…",
    status: {
      "finished — summary waiting": "закончил — отчёт ждёт",
      "finished — waiting to report": "закончил — ждёт, чтобы отчитаться",
      reporting: "отчитывается",
      resting: "отдыхает",
      working: "работает",
      idle: "простаивает",
    },
  },

  "zh-Hans": {
    title: "Antiphon——网页演示",
    tag: "你的智能体在诉说。你在聆听。",
    body: "Antiphon 为每个编程智能体赋予声音，安放在你周围的房间里。戴上耳机，聆听工作的进行。",
    headphonesNote: "需要耳机——声音是 3D 定位的。",
    enable: "启用摄像头并继续",
    start: "开始",
    camNote: "转头面向智能体。视频不会离开你的设备。",
    recal: "重新设置",
    foot: "作者：Caleb Foust",
    startingAudio: "正在启动音频……",
    cantStartAudio: "无法启动音频：",
    requestingCamera: "正在请求摄像头……",
    loadingModel: "正在加载头部追踪模型……",
    lookingFace: "正在寻找你的面部…",
    calRestored: "已恢复校准",
    trackingReady: "头部追踪已就绪",
    startAnyway: "直接开始",
    continueLabel: "继续",
    cameraDenied: "摄像头被拒绝——将在没有头部追踪的情况下开始。",
    noTracking: "没有头部追踪——房间照常工作。",
    startWithout: "在没有头部追踪的情况下开始",
    willSetupAgain: "开始时将重新设置",
    calLeft: "把头一直转到最左边……保持不动。",
    calRight: "现在转到最右边……保持不动。",
    calDone: "好了，校准完成。",
    holdStill: "保持不动……",
    fitTitle: "适配",
    fitSub: "移动滑块，直到我的声音悬在你正前方的空间里。",
    sayPlaceholder: "面向一个智能体，然后输入发送……",
    sayPlaceholderSeat: "给这个智能体发一条消息……",
    wakeTip: "唤醒——回到房间",
    snoozeTip: "小睡——移出房间，但仍持续更新",
    noAgents: "还没有智能体——会话加入后会出现在这里。",
    waitingAgents: "正在等待智能体……",
    status: {
      "finished — summary waiting": "已完成——总结等待中",
      "finished — waiting to report": "已完成——等着向你汇报",
      reporting: "汇报中",
      resting: "休息中",
      working: "工作中",
      idle: "空闲",
    },
  },

  "zh-Hant": {
    title: "Antiphon——網頁展示",
    tag: "你的智能體在訴說。你在聆聽。",
    body: "Antiphon 為每個編程智能體賦予聲音，安放在你周圍的房間裡。戴上耳機，聆聽工作的進行。",
    headphonesNote: "需要耳機——聲音是 3D 定位的。",
    enable: "啟用攝影機並繼續",
    start: "開始",
    camNote: "轉頭面向智能體。影片不會離開你的裝置。",
    recal: "重新設定",
    foot: "作者：Caleb Foust",
    startingAudio: "正在啟動音訊……",
    cantStartAudio: "無法啟動音訊：",
    requestingCamera: "正在要求使用攝影機……",
    loadingModel: "正在載入頭部追蹤模型……",
    lookingFace: "正在尋找你的臉部…",
    calRestored: "已恢復校準",
    trackingReady: "頭部追蹤已就緒",
    startAnyway: "直接開始",
    continueLabel: "繼續",
    cameraDenied: "攝影機被拒絕——將在沒有頭部追蹤的情況下開始。",
    noTracking: "沒有頭部追蹤——房間照常運作。",
    startWithout: "在沒有頭部追蹤的情況下開始",
    willSetupAgain: "開始時將重新設定",
    calLeft: "把頭一直轉到最左邊……保持不動。",
    calRight: "現在轉到最右邊……保持不動。",
    calDone: "好了，校準完成。",
    holdStill: "保持不動……",
    fitTitle: "適配",
    fitSub: "移動滑塊，直到我的聲音懸在你正前方的空間裡。",
    sayPlaceholder: "面向一個智能體，然後輸入發送……",
    sayPlaceholderSeat: "給這個智能體發一則訊息……",
    wakeTip: "喚醒——回到房間",
    snoozeTip: "小睡——移出房間，但仍持續更新",
    noAgents: "還沒有智能體——工作階段加入後會出現在這裡。",
    waitingAgents: "正在等待智能體……",
    status: {
      "finished — summary waiting": "已完成——總結等待中",
      "finished — waiting to report": "已完成——等著向你回報",
      reporting: "回報中",
      resting: "休息中",
      working: "工作中",
      idle: "閒置",
    },
  },
};

/** The demo's active language — chosen on the welcome screen, read everywhere. */
export let lang: Lang = detectLang();
export let D: DemoStrings = DEMO[lang];

export function setDemoLang(l: Lang): void {
  lang = l;
  D = DEMO[l];
}
