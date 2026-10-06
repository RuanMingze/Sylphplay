/* ============ Sylphplay 渲染逻辑 — Ruanftrix ============ */
'use strict'

const $ = (sel) => document.querySelector(sel)
const settingsKey = 'sylph:settings'

// 当前平台：DLC（强制对齐）与「设为默认打开方式」为 Windows 专属，其他平台隐藏入口
const IS_WIN = window.sylph.platform === 'win32'
const IS_X86 = window.sylph.arch === 'ia32'

const DEFAULT_SETTINGS = {
  theme: 'system',   // system(跟随系统) | dark | light
  defaultVolume: 80,
  defaultSpeed: 1,
  playMode: 'all',   // off | one | all | sequence | shuffle_smart | shuffle
  autoNext: true,
  imgFit: 'contain',      // contain | width | actual | fill
  imgMap: false,          // 图片鹰眼图（右下角当前视野指示）
  vizEnabled: true,
  recursiveFolder: true,
  showHints: true,
  seekStep: 5,            // 方向键←→快进/退秒数（短步进）
  seekStepLong: 60,       // 方向键↑↓快进/退秒数（长步进）
  picBrightness: 100,     // 视频画面亮度 %
  picContrast: 100,       // 视频画面对比度 %
  picSaturation: 100,     // 视频画面饱和度 %
  vidFit: 'contain',      // 视频适应方式 contain(留边) | cover(铺满剪裁) | fill(失真铺满)
  videoTopmost: false,    // 播放视频时窗口置顶
  rememberProgress: true, // 记忆每个文件的播放位置（断点续播）
  lyricsLines: 7,            // 歌词页一屏显示的行数
  lyricsEnabled: true,        // 显示歌词（主开关；关闭则主窗口不显示歌词，桌面歌词亦强制关闭）
  desktopLyrics: false,       // 桌面歌词栏（置顶小窗）
  trayOnClose: true,          // 关闭时后台播放（到托盘）
  bgAlways: false,            // 后台永远刷新（关掉 Chromium 后台节流，可能更耗电/降低性能）
  accentColor: '',            // 主应用主题色（空=默认主题色）
  // —— 实验性功能 ——
  expSpeedSlider: false,      // 把倍速下拉换成连续滑块
  speedMin: 0.25,             // 倍速滑块最小值
  speedMax: 4,                // 倍速滑块最大值
  expLyricsFill: false,       // 歌词逐字渐变填充
  expAutoLyrics: false,        // 本地歌词缺失时自动联网查找（LRCLIB，免费无需账户）
  natQuiet: false,             // 国庆彩蛋：临时切回默认深浅主题
  _natActive: false            // 国庆彩蛋是否激活（真实日期 或 `--101` 触发，内存标志）
}

const TYPE_META = {
  image: { ico: 'fa-solid fa-image', label: '图片' },
  video: { ico: 'fa-solid fa-film', label: '视频' },
  audio: { ico: 'fa-solid fa-music', label: '音乐' }
}

/* ---------- 内部状态 ---------- */
const S = {
  queue: [],        // [{path,name,type,size}]
  current: -1,
  playing: false,
  settings: { ...DEFAULT_SETTINGS },
  imgZoom: 1,       // 图片缩放倍率
  imgRot: 0,
  imgFitActive: true,
  audioCtx: null,   // WebAudio
  analyser: null,
  vizRAF: null,
  volumeFill: '',
  curPath: null,    // 当前播放项路径（断点续播用）
  queueView: 'list' // list | grid
}
// 进度记忆存储（localStorage key → {path: seconds}）
const progressKey = 'sylph:progress'
let progressTimer = null
function getSavedProgress(path) {
  try { const m = JSON.parse(localStorage.getItem(progressKey) || '{}'); return m[path] || 0 } catch (e) { return 0 }
}
function saveProgress(path, sec) {
  if (!path || !sec || sec < 3) return
  try {
    const m = JSON.parse(localStorage.getItem(progressKey) || '{}')
    const keep = {}; let n = 0
    for (const k in m) { if (n++ < 400) keep[k] = m[k] }   // 限制条目，避免无限膨胀
    keep[path] = sec
    localStorage.setItem(progressKey, JSON.stringify(keep))
  } catch (e) { /* 忽略 */ }
}

/* ---------- 元素 ---------- */
const el = {
  media: $('#video-el'),
  audio: $('audio') || document.createElement('audio'),  // 占位，实际用 video+audio 策略见下
  image: $('#image-el'),
}
// 音乐也使用 audio 播放（独立不被视频干扰）。build audio via JS:
const audioEl = document.createElement('audio')
audioEl.preload = 'auto'

const UI = {
  views: { image: $('#view-image'), video: $('#view-video'), audio: $('#view-audio') },
  transport: $('#cb-transport'),
  imgControls: $('#cb-image'),
  cbRight: $('#cb-right'),
  playBtn: $('#btn-play'),
  seek: $('#seek'),
  timeCur: $('#time-cur'),
  timeTotal: $('#time-total'),
  volume: $('#volume'),
  volWrap: $('.vol-wrap'),
  speed: $('#speed'),
  modeBtn: $('#btn-mode'),
  modeMenu: $('#mode-menu'),
  infoBtn: $('#btn-info'),
  fsBtn: $('#btn-fs'),
  infoMask: $('#info-mask'),
  infoBody: $('#info-body'),
  stageWrap: $('#stage-wrap'),
  videoEl: $('#video-el'),
  qViewList: $('#q-view-list'),
  qViewGrid: $('#q-view-grid'),
  cbType: $('#cb-type'),
  cbName: $('#cb-name'),
  queuePanel: $('#queue-panel'),
  queueList: $('#queue-list'),
  qCount: $('#q-count'),
  qEmpty: $('#q-empty'),
  empty: $('#empty'),
  imageEl: $('#image-el'),
  imageStage: $('#image-stage'),
  imgMap: $('#img-map'),
  imgMapWrap: $('#img-map-wrap'),
  imgMapWin: $('#img-map-win'),
  zoomInfo: $('#zoom-info'),
  imgHint: $('#img-hint'),
  audioCover: $('#audio-cover'),
  audioArt: $('#audio-art'),
  audioTitle: $('#audio-title'),
  audioMeta: $('#audio-meta'),
  lyrics: $('#lyrics'),
  lyricsScroll: $('#lyrics-scroll'),
  lrcBtn: $('#btn-lrc'),
  viz: $('#viz'),
  settingsBody: $('#settings-body'),
  settingsMask: $('#settings-mask'),
  toast: $('#toast'),
  dropOverlay: $('#drop-overlay')
}

let currentMedia = null // 当前播放的 video 或 audio

/* ---------- 工具 ---------- */
function fmtTime(sec) {
  if (!isFinite(sec) || sec < 0) sec = 0
  const s = Math.floor(sec % 60)
  const m = Math.floor((sec / 60) % 60)
  const h = Math.floor(sec / 3600)
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`
}
function humanSize(b) {
  if (b == null) return ''
  if (b < 1024) return b + ' B'
  const u = ['KB', 'MB', 'GB', 'TB']; let i = -1
  do { b /= 1024; i++ } while (b >= 1024 && i < u.length - 1)
  return b.toFixed(1) + ' ' + u[i]
}
function toast(msg) {
  UI.toast.textContent = msg
  UI.toast.classList.add('show')
  clearTimeout(toast._t)
  toast._t = setTimeout(() => UI.toast.classList.remove('show'), 1800)
}
function showHint(text) {
  if (!S.settings.showHints) return
  UI.imgHint.textContent = text
  UI.imgHint.style.opacity = 1
  clearTimeout(showHint._t)
  showHint._t = setTimeout(() => UI.imgHint.style.opacity = 0, 1600)
}

/* ---------- 设置持久化 ---------- */
function saveSettings() {
  localStorage.setItem(settingsKey, JSON.stringify(S.settings))
}
function loadSettings() {
  try {
    const raw = JSON.parse(localStorage.getItem(settingsKey) || '{}')
    // 迁移旧的 loopMode + shuffle → 新的 playMode
    if (raw.playMode == null) {
      if (raw.shuffle) raw.playMode = 'shuffle'
      else if (raw.loopMode === 'one') raw.playMode = 'one'
      else if (raw.loopMode === 'all') raw.playMode = 'all'
      else if (raw.loopMode === 'off') raw.playMode = 'off'
    }
    S.settings = { ...DEFAULT_SETTINGS, ...raw }
  } catch (e) { S.settings = { ...DEFAULT_SETTINGS } }
}
// 把 #rrggbb 混入白色，返回变浅后的 #rrggbb
function lighten(hex, amt) {
  const m = (hex || '').replace('#', '')
  if (!/^[0-9a-fA-F]{6}$/.test(m)) return hex
  const n = parseInt(m, 16), r = Math.min(255, (n >> 16) + amt), g = Math.min(255, ((n >> 8) & 255) + amt), b = Math.min(255, (n & 255) + amt)
  return '#' + ((r << 16) | (g << 8) | b).toString(16).padStart(6, '0')
}
// 应用主应用主题色：有自定义色用之；未设置则用默认（主题CSS内置）
function applyAccent() {
  const c = (S.settings.accentColor || '').trim()
  const el = document.documentElement
  if (/^#[0-9a-fA-F]{6}$/.test(c)) {
    el.style.setProperty('--accent', c)
    el.style.setProperty('--accent-2', lighten(c, 40))
  } else {
    el.style.removeProperty('--accent')
    el.style.removeProperty('--accent-2')
  }
}
// —— 国庆主题彩蛋 ——
// 双通道且互不简化：真实系统日期（10月1日）为同步判定；`--101` 为独立强制参数（异步补齐）。
// 任一成立即激活；由「natQuiet」开关临时切回默认深浅主题。
function isOct1Today() { const d = new Date(); return d.getMonth() === 9 && d.getDate() === 1 }
let nationalForce = false                            // --101 强制参数通道结果（异步求得）
function nationalActive() { return isOct1Today() || nationalForce }
function applyNationalTheme() {
  const el = document.documentElement
  const banner = $('#nat-banner')
  const on = nationalActive() && !S.settings.natQuiet
  if (on) {
    el.style.setProperty('--accent', '#e2231a')       // 中国红
    el.style.setProperty('--accent-2', '#ffd700')     // 帝王金
    if (banner) banner.hidden = false
  } else {
    applyAccent()                                     // 恢复正常深浅主题的用户色/默认
    if (banner) banner.hidden = true
  }
}
async function detectNationalForce() {
  try { nationalForce = !!(window.sylph && await window.sylph.nationalParam()) } catch { /* 无通道则仅日期生效 */ }
  S.settings._natActive = nationalActive()
  applyNationalTheme()
}
// 后台节流是否允许：桌面歌词逐字填充需要主窗口在后台持续推送时钟锚点 → 强制关闭节流(allow=false)；
// 否则按「后台永远刷新」用户偏好。
function bgThrottleAllowed() {
  const fillNeedsBg = !!(S.settings.desktopLyrics && S.settings.expLyricsFill)
  return fillNeedsBg || !!S.settings.bgAlways ? false : true
}
function applySettings() {
  const s = S.settings
  // theme: system 时跟随系统深浅
  const dark = s.theme === 'dark' || (s.theme !== 'light' && matchMedia('(prefers-color-scheme: dark)').matches)
  document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light')
  applyNationalTheme()
  const themeIco = $('#theme-ico')
  if (themeIco) themeIco.className = dark ? 'fa-solid fa-sun' : 'fa-solid fa-moon'
  UI.volume.value = s.defaultVolume
  setVolume(s.defaultVolume, false)
  UI.speed.value = String(s.defaultSpeed)
  applyAllRates()
  refreshPlayModeUI()
  applyImgFit()
  applyVideoPic()
  applyVideoFit()
  window.sylph.setAlwaysOnTop(!!s.videoTopmost)
  window.sylph.setBackgroundThrottle(bgThrottleAllowed())   // 逐字填充时后台保持推送；否则按用户偏好
  if (UI.imgMapWrap) UI.imgMapWrap.classList.toggle('show', !!s.imgMap)
  updateImgMap()
  if (!s.vizEnabled) stopViz(); else if (currentMedia) startViz()
}
// 视频画面调节：亮度/对比度/饱和度 → CSS filter（仅作用于视频）
function applyVideoPic() {
  const s = S.settings, el = UI.videoEl
  if (!el) return
  el.style.filter = `brightness(${s.picBrightness}%) contrast(${s.picContrast}%) saturate(${s.picSaturation}%)`
}
// 视频适应方式：适应(contain)=留信箱边 | 填满(cover)=铺满并裁剪 | 拉伸(fill)=失真铺满
function applyVideoFit() {
  const el = UI.videoEl
  if (!el) return
  const m = { contain: 'contain', cover: 'cover', fill: 'fill' }
  el.style.objectFit = m[S.settings.vidFit] || 'contain'
}

/** 各播放模式：图标 + 中文名（使用 FontAwesome Pro 图标） */
const MODES = {
  off:           { ico: 'fa-solid fa-ban',              label: '无' },
  one:           { ico: 'fa-solid fa-repeat-1',        label: '单曲循环' },
  all:           { ico: 'fa-solid fa-arrows-rotate',    label: '列表循环' },
  sequence:      { ico: 'fa-solid fa-arrow-right-long', label: '顺序播放' },
  shuffle_smart: { ico: 'fa-solid fa-wand-sparkles',    label: '随机播放(智能)' },
  shuffle:       { ico: 'fa-solid fa-shuffle',          label: '随机播放' }
}
function refreshPlayModeUI() {
  const mode = S.settings.playMode || 'all'
  const icon = UI.modeBtn ? UI.modeBtn.querySelector('i') : null
  if (icon && MODES[mode]) icon.className = MODES[mode].ico
  if (UI.modeBtn) UI.modeBtn.classList.toggle('state-on', mode === 'shuffle' || mode === 'shuffle_smart')
  // 同步下拉选中项
  if (UI.modeMenu) {
    const items = UI.modeMenu.querySelectorAll('.mode-item')
    for (const it of items) it.classList.toggle('active', it.dataset.mode === mode)
  }
}
function setPlayIcon(playing) {
  const i = $('#play-ico')
  if (i) i.className = playing ? 'fa-solid fa-pause' : 'fa-solid fa-play'
  // 同步给桌面歌词小窗，用于切换其控制条上的播放/暂停图标
  if (window.sylph && window.sylph.lyricsPlayState) window.sylph.lyricsPlayState(!!playing)
}
function applyAllRates() { if (el.media) el.media.playbackRate = S.settings.defaultSpeed; audioEl.playbackRate = S.settings.defaultSpeed }

let lastDeskFillSig = ''   // 桌面歌词逐字进度去重（避免每帧重复 IPC）
// 桌面歌词：把当前词句推给置顶小窗（开关关闭或文本为空时隐藏窗口）
// 开启逐字填充时，额外携带整行结构（卡拉OK 拆分逐词 / 普通 双层覆盖），由进度推送驱动
let lastDeskKey = null   // 桌面歌词结构去重：同一句只推一次，避免反复重建小窗
function pushDesktopLyric(text, line) {
  if (!window.sylph || !window.sylph.lyricsShow) return
  if (!S.settings.desktopLyrics || !text) {
    if (lastDeskKey !== null || !text) { window.sylph.lyricsShow(''); lastDeskKey = null }
    lastDeskFillSig = ''
    return
  }
  const useFill = S.settings.expLyricsFill && line
  // key 带上行起始时间：重复副歌（文本相同）也能识别为新行，避免沿用上一行的填充锚点
  const key = useFill ? ('fill:' + line.t + ':' + line.text) : ('plain:' + text)
  if (key === lastDeskKey) return   // 同一句已推送过，不再重复
  lastDeskKey = key
  lastDeskFillSig = ''
  if (useFill) {
    const nxt = Lyrics.lines ? Lyrics.lines.find(x => x.t > line.t) : null
    // 随行下发「分段折线模型」pts，供小窗按音频时钟精确求值（避免锚点间外推过冲）
    window.sylph.lyricsShow({ fill: true, mode: 'line', text: line.text, t: line.t, pts: lineBreakpoints(line, nxt) })
  } else window.sylph.lyricsShow(text)
}
// 桌面歌词逐字进度：由主窗口 setInterval（后台也可靠）推送「填充分数 + 音频秒」时钟锚点。
// 信号用填充分数+音频秒联合：播放推进时秒变化→持续发；暂停/卡住时静止→跳过，驱动歌词小窗停住。
let lastFillPush = null
function desktopFillPush(p, now) {
  if (!S.settings.desktopLyrics || !S.settings.expLyricsFill) return
  if (!window.sylph || !window.sylph.lyricsFill) return
  const sig = 'p' + Math.round(p * 1000) + ':' + Math.round(now * 1000)
  if (sig === lastFillPush) return
  lastFillPush = sig
  window.sylph.lyricsFill({ p, now })
}

/* ============================================================
   歌词（LRC 等时间轴文本）：导入后音乐视图中间显示、随播放高亮
   ============================================================ */
const Lyrics = {
  // 已解析的歌词行：{ t: 秒, text: 字符串 }
  lines: [],
  activeIdx: -1,
  curPath: null,

  // 解析常见 [mm:ss.xx] / [mm:ss:xx] LRC；也支持卡拉OK逐词（行内多个时间戳对文本切分）。
  // 每行输出 { t, text, words? }：
  //  - 普通行：一个时间戳一行 text；多前置时间戳按原样每时间戳一行
  //  - 卡拉OK行：整行只出一行 text（干净拼接），并附 words=[{t,text}] 供逐词高亮
  parse(raw) {
    const out = []
    if (!raw) return out
    const lines = String(raw).split(/\r?\n/)
    const TS = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]([^[]*)/g
    for (const line of lines) {
      if (!/\[(\d{1,3}):(\d{1,2})(?:[.:]\d+)?\]/.test(line)) continue
      const segs = []
      for (const m of line.matchAll(TS)) {
        const min = +m[1], sec = +m[2], frac = +m[3] || 0
        let t = min * 60 + sec + (m[3] && frac > 0 ? frac / Math.pow(10, m[3].length) : 0)
        segs.push({ t, text: m[4] })
      }
      if (!segs.length) continue
      // 非空文本段：只统计真正带文字的段。行尾的「结束时间戳」（如 [t]文本[00:37.015]）后面是空文本，
      // 属于空段，既不是歌词文字，也不能单独成行。
      const nonEmpty = segs.filter(s => s.text.trim())
      if (nonEmpty.length >= 2) {
        // 卡拉OK行：行内多个内联时间戳（[t]词[t]词…），整行只出一行干净拼接的 text，
        // 并附 words 供逐词高亮。
        out.push({ t: segs[0].t, text: segs.map(s => s.text).join('').trim() || segs[0].text,
          words: nonEmpty.map(s => ({ t: s.t, text: s.text })) })
      } else if (nonEmpty.length === 1) {
        // 普通行：文本之前的时间戳都指向同一段文字（重复副歌 [t1][t2]副歌 → 各出一行），
        // 文本之后的结束时间戳直接忽略。若把空段也出行，会得到一条与下一句起始时间相同的空行，
        // 分组时把它当成同组首行，导致整句都不高亮。
        const text = nonEmpty[0].text
        const idx = segs.findIndex(s => s === nonEmpty[0])
        for (let k = 0; k <= idx; k++) out.push({ t: segs[k].t, text })
      }
      // 全是空段（纯时间戳行）→ 忽略
    }
    out.sort((a, b) => a.t - b.t)
    return out
  },

  set(raw) {
    this.lines = this.parse(raw)
    this.activeIdx = -1
    if (!this.lines.length) { this.curPath = null; this.hideView(); return }
    // 有歌词 → 音乐视图中间切换成歌词（收起封面与频谱）
    this.curPath = null
    this.artOrg = UI.audioArt ? UI.audioArt.style.display : null
    this.cvOrg = UI.viz ? UI.viz.style.display : null
    if (UI.audioArt) UI.audioArt.style.display = 'none'
    if (UI.viz) UI.viz.style.display = 'none'
    UI.lyrics.hidden = false
    // 双语/KaraOK 配对：开始时间相同(±40ms)的相邻行归为一组，只高亮组内第一行(原词)，
    // 其余作为次级副歌词(译文)淡色展示
    this.lines.forEach((l, i) => {
      l._g = (i > 0 && Math.abs(l.t - this.lines[i - 1].t) < 0.04) ? this.lines[i - 1]._g : i
    })
    this.renderLines()
    this.applyLines()
    this.curPath = S.curPath || null
    this.dispose()
    this._raf = () => this.update(currentMedia ? currentMedia.currentTime : 0)
    this._tid = setInterval(this._raf, 250)
    this.startFill()
  },

  // 逐字填充：渲染歌词行。统一为「底字 + 同尺寸高亮覆盖层」（clip-path 从左向右揭示），
  // 填充进度由 lineFraction() 按行时间/词时间戳驱动
  renderLines() {
    if (!this.lines.length) return
    const fill = !!S.settings.expLyricsFill
    UI.lyricsScroll.innerHTML = this.lines.map((l, i) =>
      `<div class="lyrics-line${fill ? ' fill' : ''}" data-i="${i}">` +
      (fill
        ? `<span class="lyrl-base">${escapeHtml(l.text)}</span><span class="lyrl-fill" style="clip-path:inset(0 100% 0 0)">${escapeHtml(l.text)}</span>`
        : escapeHtml(l.text)) +
      `</div>`).join('')
    this.activeIdx = -1
  },
  // 逐字填充动画循环：rAF 驱动主窗口本地 clip 平滑；setInterval 驱动桌面歌词锚点推送（后台可靠）
  startFill() {
    this._fill = !!S.settings.expLyricsFill
    if (this._fillRAF) { cancelAnimationFrame(this._fillRAF); this._fillRAF = null }
    if (this._fillIid) { clearInterval(this._fillIid); this._fillIid = null }
    if (!this._fill) return
    const step = () => {
      if (!this._fill) return
      this.updateFill(currentMedia ? currentMedia.currentTime : 0)
      this._fillRAF = requestAnimationFrame(step)
    }
    this._fillRAF = requestAnimationFrame(step)
    this._fillIid = setInterval(() => this.pushFillIpc(), 100)
  },
  // 计算当前行（组内原词）的填充进度并应用：
  //  - 卡拉OK：用每词真实时间戳做「调速」——词与词间平滑推进，整体填满不卡顿
  //  - 普通行：整行线性揭示，到下一句起点刚好填满
  updateFill(time) {
    if (!this.lines.length || !S.settings.expLyricsFill) return
    const lead = this.activeIdx
    if (lead < 0 || this.lines[lead]._g !== lead) return
    const nodes = UI.lyricsScroll ? UI.lyricsScroll.children : null
    const node = nodes && nodes[lead]
    if (!node) return
    const line = this.lines[lead]
    const nxt = this.lines.find(x => x.t > line.t)
    const p = lineFraction(line, nxt, time)
    const fl = node.querySelector('.lyrl-fill')
    if (fl) fl.style.clipPath = 'inset(0 ' + (100 - p * 100).toFixed(2) + '% 0 0)'
  },
  // 推送桌面歌词填充锚点：由 setInterval 调用（不依赖 rAF，主窗口最小化/隐藏后依然可靠）
  pushFillIpc() {
    if (!this.lines.length || !S.settings.expLyricsFill) return
    const lead = this.activeIdx
    if (lead < 0 || this.lines[lead]._g !== lead) return
    const line = this.lines[lead]
    const nxt = this.lines.find(x => x.t > line.t)
    const time = currentMedia ? currentMedia.currentTime : 0
    desktopFillPush(lineFraction(line, nxt, time), time)
  },
  // 实验开关变化：重渲染歌词行并按当前状态启停 rAF 填充
  applyFill() {
    if (!this.lines.length) return
    this.renderLines()
    this.applyLines()
    if (S.settings.expLyricsFill) this.startFill()
    else this._fill = false
    this.update(currentMedia ? currentMedia.currentTime : 0)
  },

  // 根据当前进度高亮并居中当前行
  update(time) {
    if (!this.lines.length) return
    let idx = 0
    for (let i = 0; i < this.lines.length; i++) {
      if (time >= this.lines[i].t) idx = i; else break
    }
    if (idx === this.activeIdx) return
    const lead = this.lines[idx]._g
    this.activeIdx = lead
    const nodes = UI.lyricsScroll.children
    for (let i = 0; i < nodes.length; i++) {
      nodes[i].classList.toggle('active', i === lead)
      nodes[i].classList.toggle('sub', this.lines[i]._g === lead && i !== lead)
      // 上一句退出高亮：立刻清掉残留的逐字填充（避免橙色残留）
      if (i !== lead) clearLineFill(nodes[i])
    }
    lastDeskFillSig = ''
    const cur = nodes[lead]
    if (cur) cur.scrollIntoView({ block: 'center', behavior: 'smooth' })
    const L = this.lines[lead]
    pushDesktopLyric(L ? L.text : '', L)
  },

  dispose() { if (this._tid) { clearInterval(this._tid); this._tid = null } this._fill = false; if (this._fillRAF) { cancelAnimationFrame(this._fillRAF); this._fillRAF = null } if (this._fillIid) { clearInterval(this._fillIid); this._fillIid = null } },

  // 根据设置的行数调整歌词容器高度（一行 ≈ 37px）
  applyLines() {
    const n = Math.max(3, Math.min(12, parseInt(S.settings.lyricsLines) || 7))
    UI.lyrics.style.height = (n * 37) + 'px'
  },

  // 恢复封面与频谱显示
  hideView() {
    this.dispose()
    UI.lyrics.hidden = true
    UI.lyricsScroll.innerHTML = ''
    pushDesktopLyric('')
    if (UI.audioArt && UI.audioArt.style.display === 'none') UI.audioArt.style.display = this.artOrg || ''
    if (UI.viz && UI.viz.style.display === 'none') UI.viz.style.display = this.cvOrg || ''
    this.artOrg = null; this.cvOrg = null
  },

  // 结束/切换媒体时清理歌词与高亮
  clear(keepView) {
    this.dispose()
    this.lines = []
    this.activeIdx = -1
    this.curPath = null
    UI.lyrics.hidden = true
    pushDesktopLyric('')
    if (!keepView) UI.lyricsScroll.innerHTML = ''
    if (UI.audioArt && UI.audioArt.style.display === 'none') UI.audioArt.style.display = this.artOrg || ''
    if (UI.viz && UI.viz.style.display === 'none') UI.viz.style.display = this.cvOrg || ''
    this.artOrg = null; this.cvOrg = null
  }
}
// 计算单行歌词的填充进度(0~1)：
//  - 卡拉OK：用每词真实时间戳分段，词与词之间线性推进，返回连续渐变比例
//  - 普通行：在 [行起点, 下一句起点] 内线性推进
// 每字演唱估算秒数：填充节奏基准。用「句内字数」估算本句演唱时长，与到下一句的间隔无关——
// 句子越长填充越久；短句遇长间奏则快速填满后保持。不会把长句误判为间奏提前填满，也不会流得极慢
const LYRIC_PER_CHAR = 0.5
function lineFraction(line, nxt, time) {
  const lt = line.t
  const chars = String(line.text || '').length
    || ((line.words || []).reduce((s, w) => s + String(w.text).length, 0) || 1)
  let dur = Math.max(0.4, Math.min(chars * LYRIC_PER_CHAR, ((currentMedia && currentMedia.duration) || 30) - lt))
  if (line.words && line.words.length) {
    const ws = line.words
    const total = ws.reduce((s, w) => s + String(w.text).length, 0) || 1
    let done = 0
    for (let j = 0; j < ws.length; j++) {
      // 最后一个字的终点：优先用下一句实测起点（与词时间同源、单调不跳变）；
      // 只有无下一句时才回退到「按字数估算」的剩余时长，避免估算上限早于实测末字时间造成的卡慢+跳满
      const wEnd = (j + 1 < ws.length) ? ws[j + 1].t : (nxt ? nxt.t : (lt + dur))
      if (time < ws[j].t) break
      if (time < wEnd) {
        const f = Math.min(1, Math.max(0, (time - ws[j].t) / Math.max(0.05, wEnd - ws[j].t)))
        done += f * String(ws[j].text).length
        break
      }
      done += String(ws[j].text).length
    }
    return Math.min(1, Math.max(0, done / total))
  }
  // 已唱到下一句 → 整行强制填满；否则按字数估算的节奏线性揭示
  let p = nxt && time >= nxt.t ? 1 : (time - lt) / dur
  return Math.min(1, Math.max(0, p))
}
// 生成单行歌词的「分段折线模型」：[[音频秒, 填充分数], ...]，与 lineFraction() 完全同源。
// 作用：把模型的斜率变化点也交给桌面歌词小窗，使其在锚点之间按模型求值而非线性外推，
// 从而消除「末字遇到长间奏、斜率骤降」时的外推过冲与回缩跳动。
function lineBreakpoints(line, nxt) {
  const ws = (line.words && line.words.length) ? line.words : null
  const clamp01 = v => Math.min(1, Math.max(0, v))
  if (ws) {
    const lens = ws.map(w => String(w.text).length)
    const total = lens.reduce((s, n) => s + n, 0) || 1
    const dur = Math.max(0.4, total * LYRIC_PER_CHAR)
    const lastEnd = nxt ? nxt.t : (line.t + dur)
    const pts = []
    let done = 0
    for (let j = 0; j < ws.length; j++) {
      const wEnd = (j + 1 < ws.length) ? ws[j + 1].t : lastEnd
      pts.push([ws[j].t, done / total])
      done += lens[j]
      pts.push([wEnd, done / total])
    }
    return pts
  }
  // 普通行：与 lineFraction 的「按字数估算 + 到下一句强制填满」一致
  const chars = String(line.text || '').length || 1
  const dur = Math.max(0.4, Math.min(chars * LYRIC_PER_CHAR, ((currentMedia && currentMedia.duration) || 30) - line.t))
  const segEnd = nxt ? Math.min(line.t + dur, nxt.t) : (line.t + dur)
  const pts = [[line.t, 0], [segEnd, clamp01((segEnd - line.t) / dur)]]
  if (nxt) pts.push([Math.max(segEnd, nxt.t), 1])
  return pts
}
// 清空节点残留的逐字填充（复位 clip-path）
function clearLineFill(node) {
  if (!node) return
  const f = node.querySelector('.lyrl-fill')
  if (f) f.style.clipPath = 'inset(0 100% 0 0)'
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
}
// —— 实验性「自动寻找歌词」（LRCLIB：免费、无需 key、返回标准 LRC 时间轴、开放 CORS）——
// 本地歌词缺失时才联网；用「歌手 + 歌名 + 时长」同时匹配，避免搜到 remix / 翻唱 / 其他版本
const autoLyricsTried = new Set()   // 本次会话已联网尝试过且失败的路径（避免反复请求 / 触发限流）
const autoLyricCache = new Map()    // 联网成功的 LRC，切走再回直接应用，不再重复请求
const LRC_DURATION_TOLERANCE = 5    // 歌词版本与媒体时长的可接受偏差(秒)

// 网络歌词按「不可信输入」白名单清洗。即使 API 被投毒/篡改，也只放行结构合法的纯 LRC。
function sanitizeAutoLyrics(lrc) {
  if (typeof lrc !== 'string') return null
  if (lrc.length > 200_000) return null                          // 体积上限，防超大 payload
  const clean = lrc.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '') // 去控制字符(保留 \n\t)
  const lines = clean.split(/\r?\n/).filter(Boolean)
  if (!lines.length || lines.length > 3000) return null          // 行数上限
  // 至少一半行要以 [m:ss(.xx)] 时间戳开头，否则视为垃圾/恶意内容
  const tsRatio = lines.filter(l => /^\s*\[(\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?)\]/.test(l)).length / lines.length
  if (tsRatio < 0.4) return null
  return clean
}

async function fetchJson(url, signal) {
  try {
    // credentials:omit 不带 Cookie；redirect:error 拒绝重定向跳转，防止 hosts 篡改后被改道到恶意站点
    const r = await fetch(url, { signal, headers: { 'Accept': 'application/json' }, credentials: 'omit', redirect: 'error' })
    if (!r.ok) {
      console.warn('[自动歌词] HTTP', r.status, url)
      return null
    }
    const ct = r.headers.get('content-length')
    if (ct != null && +ct > 1_000_000) { console.warn('[自动歌词] 响应超过 1MB，拒绝'); return null }
    return await r.json()
  } catch (e) {
    console.error('[自动歌词] fetch 失败', url, e)
    return null
  }
}
// 解析文件名 → {artist, track}（支持 “歌手 - 歌曲名.xxx”）
function parseTrackName(name) {
  const base = String(name || '').replace(/\.[^.]+$/, '')
  const m = base.split(/[－\u2013\u2014\-]/)
  if (m.length >= 2) return { artist: m[0].trim(), track: m.slice(1).join('-').trim() }
  return { artist: '', track: base.trim() }
}
// 从 LRCLIB 拉取 LRC；duration 用于与媒体时长匹配校验，走不通再退化为纯文字匹配
async function fetchAutoLyrics(item, targetDur) {
  const { artist, track } = parseTrackName(item && item.name)
  if (!track) return null
  const durSec = (typeof targetDur === 'number' && isFinite(targetDur) && targetDur > 1)
    ? Math.round(targetDur) : null
  console.log('[自动歌词] 文件名→ artist:', JSON.stringify(artist), 'track:', JSON.stringify(track), '时长:', durSec)
  const ctl = new AbortController()
  const to = setTimeout(() => ctl.abort(), 6000)
  try {
    // 1) 精确匹配：服务端会同时校验 歌手/歌名/时长 时间窗，命中率最高
    let data = null
    const get = new URLSearchParams({ track_name: track })
    if (artist) get.set('artist_name', artist)
    if (durSec != null) get.set('duration', String(durSec))
    data = await fetchJson(`https://lrclib.net/api/get?${get}`, ctl.signal)
    console.log('[自动歌词] /api/get 结果:', data ? (data.syncedLyrics ? `有歌词(${data.syncedLyrics.length}字符)` : '命中但无syncedLyrics') : '未命中/HTTP非0', data ? data.trackName || data.artistName || '' : '')
    // 2) 候选搜索：多条候选，本地按 时长匹配 + 需带时间轴歌词 过滤
    if (!data || !data.syncedLyrics) {
      const sp = new URLSearchParams({ track_name: track })
      if (artist) sp.set('artist_name', artist)
      const list = await fetchJson(`https://lrclib.net/api/search?${sp}`, ctl.signal)
      console.log('[自动歌词] /api/search 候选数:', Array.isArray(list) ? list.length : '非数组', Array.isArray(list) ? `（带synced${list.filter(x=>x&&x.syncedLyrics).length}）` : '')
      if (Array.isArray(list)) {
        const cands = list.filter(x => x && x.syncedLyrics)
        if (durSec != null) {
          console.log('[自动歌词] 候选时长:', cands.map(x => `${x.trackName}(${x.duration})`).join(' | ') || '(无)')
        }
        cands.sort((a, b) => {
          const da = Math.abs((a.duration || 0) - (durSec || 0))
          const db = Math.abs((b.duration || 0) - (durSec || 0))
          return da - db
        })
        data = cands.find(x => durSec == null
          || Math.abs((x.duration || 0) - durSec) <= LRC_DURATION_TOLERANCE) || null
        if (!data && cands.length) {
          console.warn('[自动歌词] 候选都被时长过滤掉（容差±' + LRC_DURATION_TOLERANCE + 's，目标' + durSec + 's）→ 拒绝使用')
        }
      }
    }
    const lrc = sanitizeAutoLyrics((data && data.syncedLyrics) ? data.syncedLyrics : null)
    console.log('[自动歌词] 最终', lrc ? `取到歌词(${lrc.length}字符)` : ((data && data.syncedLyrics) ? '内容不合规已被清洗拒绝' : '未获取到可用歌词'))
    return lrc
  } catch (e) { console.error('[自动歌词] 异常', e); return null }
  finally { clearTimeout(to) }
}

// 自动查找歌词：先本地同名师，缺失且开启实验「自动寻找歌词」时联网兜底（LRCLIB）
async function autoLoadLyrics(item) {
  if (!item || item.type !== 'audio') return
  Lyrics.clear(true)
  // 会话内已联网抓到的歌词 → 直接应用
  if (autoLyricCache.has(item.path)) {
    Lyrics.curPath = item.path
    Lyrics.set(autoLyricCache.get(item.path))
    return
  }
  if (!window.sylph || !window.sylph.findSidecarLrc) return
  try {
    const content = await window.sylph.findSidecarLrc(item.path)
    if (content && Lyrics.curPath !== item.path) {
      Lyrics.curPath = item.path
      Lyrics.set(content)
      return
    }
  } catch (e) { /* 忽略 */ }
  // 本地歌词缺失 → 实验性「自动寻找歌词」联网兜底（失败/匹配不到则保持默认频谱页）
  // 先在「时长就绪」后才请求：刚设 src 时 duration 还是 NaN，等 loadedmetadata / durationchange 拿到真实时长再做严格匹配
  if (S.settings.expAutoLyrics && !autoLyricsTried.has(item.path)) {
    autoLyricsTried.add(item.path)   // 先标记，避免并发/失败后的重复请求
    const dur = await waitMediaDuration()
    const lrc = await fetchAutoLyrics(item, dur)
    if (lrc && Lyrics.curPath !== item.path) {
      autoLyricCache.set(item.path, lrc)
      Lyrics.curPath = item.path
      Lyrics.set(lrc)
      toast('已联网获取歌词')
    }
  } else if (!S.settings.expAutoLyrics || autoLyricsTried.has(item.path)) {
    console.log('[自动歌词] 跳过联网：expAutoLyrics=', S.settings.expAutoLyrics, '此路径已在本次会话尝试过=', autoLyricsTried.has(item.path))
  }
}

// 等待当前媒体时长就绪（最多 4s），供自动歌词做严谨的时长匹配
function waitMediaDuration() {
  return new Promise(resolve => {
    const ms = currentMedia
    if (!ms) return resolve(null)
    if (ms.duration && isFinite(ms.duration) && ms.duration > 1) return resolve(ms.duration)
    const t = setTimeout(() => { cleanup(); resolve(currentMedia && currentMedia.duration) }, 4000)
    ms.addEventListener('loadedmetadata', on)
    ms.addEventListener('durationchange', on)
    function on() {
      const d = currentMedia && currentMedia.duration
      if (d && isFinite(d) && d > 1) { cleanup(); resolve(d) }
    }
    function cleanup() { clearTimeout(t); ms.removeEventListener('loadedmetadata', on); ms.removeEventListener('durationchange', on) }
  })
}

// 「显示歌词」主开关的实际效果：开启→重载当前音频歌词；关闭→清空歌词回频谱并连坐桌面歌词
function applyLyricsVisibility() {
  if (S.settings.lyricsEnabled) {
    const it = S.queue && S.queue[S.current]
    if (it && it.type === 'audio') autoLoadLyrics(it)
  } else {
    Lyrics.clear()      // 清空歌词 → 回到频谱默认页
    pushDesktopLyric('')
  }
}

// 手动导入歌词
async function importLyrics() {
  if (!window.sylph || !window.sylph.openLrc) return
  const res = await window.sylph.openLrc()
  if (!res || res.content == null) return
  Lyrics.set(res.content)
  toast('已导入歌词')
}

/* ============================================================
   媒体加载 / 播放控制
   ============================================================ */
function activeType() {
  const it = S.queue[S.current]
  return it ? it.type : null
}

/* ---------- 渐变（淡入淡出）切换 / 淡出暂停 ---------- */
const FX = { outMs: 360, inMs: 300 }   // 淡出 / 淡入时长(ms)
const FadeCtl = {
  timer: null,
  stop() { if (this.timer) { clearTimeout(this.timer); this.timer = null } }
}
let switchFades = { active: false, tgt: null }
// 将媒体 m 的音量在 ms 内渐变到 target；中途再次调用会取消上一次渐变
function fadeVol(m, target, ms, onDone) {
  FadeCtl.stop()
  const start = m.volume
  const dur = Math.max(1, ms || 300)
  const t0 = performance.now()
  const tick = () => {
    const p = Math.min(1, (performance.now() - t0) / dur)
    m.volume = start + (target - start) * p
    if (p < 1) FadeCtl.timer = setTimeout(tick, 16)
    else { FadeCtl.timer = null; if (onDone) onDone() }
  }
  tick()
}
function isAv(m) { return !!(m && (m === audioEl || m === el.media)) }

// 渐变切换：先把当前音频/视频淡出，再真正加载新媒体（快速连点时合并为跳到最后一次目标）
function loadMedia(idx) {
  if (idx < 0 || idx >= S.queue.length) { stopAll(); showEmpty(); return }
  switchFades.tgt = idx
  const m = currentMedia
  if (isAv(m) && !m.paused && m.volume > 0.02) {
    if (switchFades.active) return          // 已在淡出，最新目标由淡出完成时读取
    switchFades.active = true
    fadeVol(m, 0, FX.outMs, () => {
      switchFades.active = false
      const t = switchFades.tgt
      switchFades.tgt = null
      loadMediaNow(t)
    })
  } else {
    loadMediaNow(idx)
  }
}
function loadMediaNow(idx) {
  if (idx < 0 || idx >= S.queue.length) { stopAll(); showEmpty(); return }
  stopCurrent()
  const item = S.queue[idx]
  S.current = idx
  S.curPath = item.path
  const type = item.type

  // 显示对应视图
  Object.keys(UI.views).forEach(k => UI.views[k].classList.toggle('show', k === type))
  UI.empty.classList.remove('active')
  UI.transport.style.display = type === 'image' ? 'none' : 'flex'
  UI.imgControls.style.display = type === 'image' ? 'flex' : 'none'
  UI.cbRight.style.display = type === 'image' ? 'none' : 'flex'
  // 仅音乐（音频）可导入歌词，视频/图片隐藏该按钮
  if (UI.lrcBtn) UI.lrcBtn.style.display = type === 'audio' ? '' : 'none'

  UI.cbType.textContent = TYPE_META[type].label
  UI.cbName.textContent = item.name
  UI.cbName.title = item.path

  const url = item.url ? item.path : window.sylph.toFileUrl(item.path)

  if (type === 'audio') {
    audioEl.src = url
    UI.audioTitle.textContent = item.name
    UI.audioMeta.textContent = TYPE_META.audio.label
    currentMedia = audioEl
    playMedia()
    autoLoadLyrics(item)
  } else if (type === 'video') {
    el.media.src = url
    currentMedia = el.media
    playMedia()
  } else if (type === 'image') {
    resetImgState()
    UI.imageEl.style.objectFit = ''
    UI.imageEl.src = url
    UI.imageEl.onload = () => { applyImgFit(); updateImgMap() }
    currentMedia = null
  }
  if (type !== 'audio') Lyrics.clear()
  if (type !== 'image') startViz()
  renderQueue()
}

function playMedia() {
  const m = currentMedia
  if (!m || !m.src) return
  UI.seek.max = isFinite(m.duration) ? m.duration : 0
  const target = S.settings.defaultVolume / 100
  applyAllRates()
  m.volume = 0
  m.play().then(() => {
    S.playing = true
    setPlayIcon(true)
    fadeVol(m, target, FX.inMs)   // 淡入
  }).catch(() => {
    m.volume = target
    S.playing = false
    setPlayIcon(false)
  })
}
let pausing = false   // 正在淡出暂停中（再按可继续）
function togglePlay() {
  const m = currentMedia
  if (!m) return
  if (switchFades.active) return   // 正在渐变切换中，忽略暂停/播放，避免打断切换
  if (m.paused) {
    FadeCtl.stop(); pausing = false
    const target = S.settings.defaultVolume / 100
    m.volume = 0
    m.play().then(() => { S.playing = true; setPlayIcon(true); fadeVol(m, target, FX.inMs) })
      .catch(() => { m.volume = target; S.playing = false; setPlayIcon(false) })
  } else if (pausing) {
    // 正在淡出暂停，再次按下改为立即继续播放
    FadeCtl.stop(); pausing = false
    m.volume = 0
    const target = S.settings.defaultVolume / 100
    m.play().then(() => { S.playing = true; setPlayIcon(true); fadeVol(m, target, FX.inMs) })
      .catch(() => { m.volume = target; S.playing = false; setPlayIcon(false) })
  } else {
    pausing = true
    S.playing = false
    fadeVol(m, 0, FX.outMs, () => { pausing = false; m.pause(); setPlayIcon(false) })  // 淡出暂停
  }
}
function stopCurrent() {
  FadeCtl.stop(); pausing = false; switchFades.active = false; switchFades.tgt = null
  if (audioEl) { audioEl.pause(); audioEl.removeAttribute('src'); audioEl.load() }
  if (el.media) { el.media.pause(); el.media.removeAttribute('src'); el.media.load() }
  currentMedia = null
  S.playing = false
  setPlayIcon(false)
  UI.seek.value = 0; UI.seek.max = 0
  UI.timeCur.textContent = '0:00'; UI.timeTotal.textContent = '0:00'
  stopViz()
}
function stopAll() {
  stopCurrent()
  Object.keys(UI.views).forEach(k => UI.views[k].classList.remove('show'))
}
function showEmpty() {
  UI.empty.classList.add('active')
  UI.transport.style.display = 'flex'
  UI.imgControls.style.display = 'none'
  UI.cbRight.style.display = 'flex'
  if (UI.lrcBtn) UI.lrcBtn.style.display = 'none'   // 无媒体时也无歌词可导
  UI.cbType.textContent = '—'
  UI.cbName.textContent = ''
}

/* ---------- 播放模式：下一曲 ---------- */
// 智能随机「洗牌袋」：一整袋播完才重洗，并规避把刚播过的放回开头
let shuffleBag = null
function resetShuffleBag() { shuffleBag = null }
function buildShuffleBag() {
  const n = S.queue.length
  const idx = []
  for (let i = 0; i < n; i++) if (i !== S.current) idx.push(i)
  // Fisher-Yates
  for (let i = idx.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1)); [idx[i], idx[j]] = [idx[j], idx[i]]
  }
  return { items: idx, pos: 0 }
}
function nextSmart() {
  const n = S.queue.length
  if (!n) return
  if (!shuffleBag || shuffleBag.pos >= shuffleBag.items.length) shuffleBag = buildShuffleBag()
  if (!shuffleBag.items.length) return  // 单曲列表，无法随机下一页
  loadMedia(shuffleBag.items[shuffleBag.pos++])
}
function next() {
  const n = S.queue.length
  if (!n) return
  const mode = S.settings.playMode
  if (mode === 'shuffle_smart') { nextSmart(); return }
  if (mode === 'shuffle') {
    // 纯随机：每次独立选一个，避免立即重复当前项
    let ni = S.current
    while (ni === S.current && n > 1) ni = Math.floor(Math.random() * n)
    loadMedia(ni); return
  }
  // 顺序类（无/单曲/列表/顺序）都按 index 前进，单曲循环只影响自动结束
  if (S.current < n - 1) { loadMedia(S.current + 1); return }
  if (mode === 'all') { loadMedia(0); return }
  // 无 / 顺序播放 / 单曲循环 到末尾则停止
  toast('队列已播放完毕')
  if (currentMedia) { currentMedia.pause(); setPlayIcon(false) }
}
function prev() {
  if (S.queue.length === 0) return
  // 若已播放超过 3 秒则回到开头
  if (S.current >= 0 && currentMedia && currentMedia.currentTime > 3) {
    currentMedia.currentTime = 0; return
  }
  loadMedia(S.current > 0 ? S.current - 1 : S.queue.length - 1)
}

/* ---------- 媒体事件 ---------- */
function bindMediaEvents(m) {
  m.addEventListener('durationchange', () => {
    UI.seek.max = isFinite(m.duration) ? m.duration : 0
    UI.timeTotal.textContent = fmtTime(m.duration)
  })
  m.addEventListener('timeupdate', () => {
    if (!isSeeking) {
      UI.seek.value = m.currentTime
      UI.timeCur.textContent = fmtTime(m.currentTime)
      const pct = m.duration ? (m.currentTime / m.duration) * 100 : 0
      UI.seek.style.setProperty('--fill', pct + '%')
    }
    // 断点续播：节流保存进度
    if (S.settings.rememberProgress && S.curPath && isFinite(m.currentTime)) {
      clearTimeout(progressTimer)
      progressTimer = setTimeout(() => saveProgress(S.curPath, m.currentTime), 1500)
    }
    S.playing = !m.paused
    setPlayIcon(!m.paused)
  })
  m.addEventListener('loadedmetadata', () => {
    UI.seek.max = isFinite(m.duration) ? m.duration : 0
    UI.timeTotal.textContent = fmtTime(m.duration)
    applyAllRates()
    if (m === audioEl) UI.audioMeta.textContent = `${TYPE_META.audio.label} · ${fmtTime(m.duration)}`
    // 断点续播：从记忆位置恢复
    if (S.settings.rememberProgress && S.curPath && isFinite(m.duration) && m.duration > 3) {
      const p = getSavedProgress(S.curPath)
      if (p > 2 && p < m.duration - 1) {
        m.currentTime = p
        UI.seek.value = p
        UI.timeCur.textContent = fmtTime(p)
        const ppct = p / m.duration * 100
        UI.seek.style.setProperty('--fill', ppct + '%')
      }
    }
  })
  m.addEventListener('ended', () => {
    const mode = S.settings.playMode
    if (mode === 'one') { m.currentTime = 0; m.play(); return }
    // 播放真正结束（不再续播）时，收起桌面歌词，避免停留在最后一句
    if (mode === 'off') { m.currentTime = 0; setPlayIcon(false); pushDesktopLyric(''); return }
    if (S.settings.autoNext) next(); else { m.currentTime = 0; setPlayIcon(false); pushDesktopLyric('') }
  })
  m.addEventListener('error', () => toast('无法播放：' + (S.queue[S.current] || {}).name))
}
let isSeeking = false
bindMediaEvents(el.media)
bindMediaEvents(audioEl)

// 桌面歌词悬停控制条：接收小窗发来的控制指令
if (window.sylph && window.sylph.onLyricsControl) {
  window.sylph.onLyricsControl((act) => {
    if (act === 'toggle') togglePlay()
    else if (act === 'next') next()
    else if (act === 'prev') prev()
  })
}
// 关闭行为弹窗勾选「记住」后，同步设置面板开关
if (window.sylph && window.sylph.onTrayOnCloseState) {
  window.sylph.onTrayOnCloseState((v) => {
    S.settings.trayOnClose = !!v.on
    const c = UI.settingsBody && UI.settingsBody.querySelector('[data-k="trayOnClose"]')
    if (c) c.checked = !!v.on
  })
}

/* ============================================================
   图片查看器
   ============================================================ */
function resetImgState() {
  S.imgZoom = 1; S.imgRot = 0; S.imgFitActive = true
  updateZoomUI()
}
// 中心锚定 + 旋转 + 缩放
function applyImgTransform() {
  const r = S.imgRot, z = S.imgZoom
  UI.imageEl.style.position = 'absolute'
  UI.imageEl.style.left = '50%'
  UI.imageEl.style.top = '50%'
  if (S.imgFitActive && z <= 1) {
    UI.imageEl.style.maxWidth = '100%'
    UI.imageEl.style.maxHeight = '100%'
    UI.imageEl.style.width = 'auto'
    UI.imageEl.style.height = 'auto'
    UI.imageEl.style.transform = `translate(-50%,-50%) rotate(${r}deg)`
  } else {
    UI.imageEl.style.maxWidth = 'none'
    UI.imageEl.style.maxHeight = 'none'
    UI.imageEl.style.width = 'auto'
    UI.imageEl.style.height = 'auto'
    UI.imageEl.style.transform = `translate(-50%,-50%) rotate(${r}deg) scale(${z})`
  }
  updateImgMap()
}
function fitToContain() {
  S.imgFitActive = true; S.imgZoom = 1
  applyImgTransform(); updateZoomUI()
}
// 根据设置切换图片初始视图
function applyImgFit() {
  const fit = S.settings.imgFit
  if (fit === 'contain') { setImageFlow('contain'); return }
  if (fit === 'actual') { setImageFlow('manual'); return }
  if (fit === 'fill') {
    // 填满：交给 object-fit
    UI.imageEl.style.maxWidth = '100%'
    UI.imageEl.style.maxHeight = '100%'
    UI.imageEl.style.width = '100%'
    UI.imageEl.style.height = '100%'
    UI.imageEl.style.position = ''
    UI.imageEl.style.left = ''
    UI.imageEl.style.top = ''
    UI.imageEl.style.transform = ''
    UI.imageEl.style.objectFit = 'fill'
    updateImgMap()
    return
  }
}
// 手动/适应 两种流动样式
function setImageFlow(mode) {
  UI.imageEl.style.objectFit = ''
  if (mode === 'contain') {
    if (S.imgFitActive && S.imgZoom <= 1) {
      UI.imageEl.style.position = 'absolute'
      UI.imageEl.style.left = '50%'
      UI.imageEl.style.top = '50%'
      UI.imageEl.style.maxWidth = '100%'; UI.imageEl.style.maxHeight = '100%'
      UI.imageEl.style.width = 'auto'; UI.imageEl.style.height = 'auto'
      UI.imageEl.style.transform = `translate(-50%,-50%) rotate(${S.imgRot}deg)`
    } else {
      applyImgTransform()
    }
  } else {
    S.imgFitActive = false
    applyImgTransform()
  }
}
function zoomTo(z) {
  S.imgFitActive = false
  S.imgZoom = Math.min(8, Math.max(0.05, Math.round(z * 100) / 100))
  applyImgTransform(); updateZoomUI()
}
function zoomToSmooth(dir) { zoomTo(S.imgZoom + dir * 0.15) }
function updateZoomUI() { UI.zoomInfo.textContent = Math.round(S.imgZoom * 100) + '%' }
function rotateImg() {
  S.imgRot = (S.imgRot + 90) % 360
  S.imgFitActive = false
  applyImgTransform()
  showHint('已旋转 ' + S.imgRot + '°')
}

// 图片鹰眼图：右下角绘制整图缩略（canvas 底图）+ 独立视野框（DOM 层）
function updateImgMap() {
  const M = UI.imgMap
  if (!M) return
  const img = UI.imageEl
  const ctx = M.getContext('2d')
  const cw = M.width, ch = M.height
  ctx.clearRect(0, 0, cw, ch)
  if (!S.settings.imgMap || !img || !img.naturalWidth) { UI.imgMapWrap.classList.remove('show'); return }
  const natW = img.naturalWidth, natH = img.naturalHeight
  const s = Math.min(cw / natW, ch / natH)
  const dw = natW * s, dh = natH * s
  const rx = (cw - dw) / 2, ry = (ch - dh) / 2
  ctx.drawImage(img, 0, 0, natW, natH, rx, ry, dw, dh)
  UI.imgMapWrap.classList.add('show')
  updateMapWin()
}
// 根据当前主图视野定位独立视野框（不影响底图，拖动可只动框）
function mapGeom() {
  const M = UI.imgMap, img = UI.imageEl
  const cw = M.width, ch = M.height
  const natW = img.naturalWidth, natH = img.naturalHeight
  const s = Math.min(cw / natW, ch / natH)
  const dw = natW * s, dh = natH * s
  const rx = (cw - dw) / 2, ry = (ch - dh) / 2
  const dispW = img.clientWidth || natW, dispH = img.clientHeight || natH
  const vz = (S.imgFitActive && S.imgZoom <= 1) ? 1 : S.imgZoom
  const VW = dispW * vz, VH = dispH * vz
  const sw = UI.imageStage.clientWidth || cw, sh = UI.imageStage.clientHeight || ch
  const wR = Math.min(1, sw / VW), hR = Math.min(1, sh / VH)
  const lPct = parseFloat(img.style.left || 50), tPct = parseFloat(img.style.top || 50)
  // 图片以 (left%, top%) 为圆心、绘制尺寸 VW×VH 居中，因此视口中心需 +0.5
  let nx = (sw / 2 - (lPct / 100) * sw) / VW + 0.5
  let ny = (sh / 2 - (tPct / 100) * sh) / VH + 0.5
  nx = Math.max(0, Math.min(1, nx))
  ny = Math.max(0, Math.min(1, ny))
  return { cw, ch, dw, dh, rx, ry, wR, hR, nx, ny, sw, sh }
}
function updateMapWin() {
  const win = UI.imgMapWin, M = UI.imgMap
  if (!win || !M) return
  const g = mapGeom()
  if (!S.settings.imgMap) { win.classList.remove('show'); return }
  // 视野框始终显示（即使未放大时覆盖整图，也画一圈贴在图上）
  const bx = g.rx + g.dw * (g.nx - g.wR / 2)
  const by = g.ry + g.dh * (g.ny - g.hR / 2)
  const css = M.getBoundingClientRect().width / M.width   // canvas 逻辑尺寸 → 实际像素缩放
  win.style.left = (bx * css) + 'px'
  win.style.top = (by * css) + 'px'
  win.style.width = Math.max(4, g.dw * g.wR * css) + 'px'
  win.style.height = Math.max(4, g.dh * g.hR * css) + 'px'
  win.classList.add('show')
}
window.addEventListener('resize', updateImgMap)

// 鹰眼图交互：点击/拖动视野框，主图视野跟着移动
let imgMapDragging = false
function clamp(n, a, b) { return Math.min(b, Math.max(a, n)) }
function setImgViewportFromMap(clientX, clientY) {
  const M = UI.imgMap, img = UI.imageEl
  if (!S.settings.imgMap || !img || !img.naturalWidth) return
  const rect = M.getBoundingClientRect()
  const cw = M.width, ch = M.height
  const px = (clientX - rect.left) * (cw / rect.width)
  const py = (clientY - rect.top) * (ch / rect.height)
  const natW = img.naturalWidth, natH = img.naturalHeight
  const s = Math.min(cw / natW, ch / natH)
  const dw = natW * s, dh = natH * s
  const rx = (cw - dw) / 2, ry = (ch - dh) / 2
  // 点击点映射为图内归一化视口中心，并钳制使视野框不越出图
  let nx = (px - rx) / dw, ny = (py - ry) / dh
  const dispW = img.clientWidth || natW, dispH = img.clientHeight || natH
  const vz = (S.imgFitActive && S.imgZoom <= 1) ? 1 : S.imgZoom
  const VW = dispW * vz, VH = dispH * vz
  const sw = UI.imageStage.clientWidth, sh = UI.imageStage.clientHeight
  const wR = Math.min(1, sw / VW), hR = Math.min(1, sh / VH)
  nx = wR < 1 ? clamp(nx, wR / 2, 1 - wR / 2) : 0.5
  ny = hR < 1 ? clamp(ny, hR / 2, 1 - hR / 2) : 0.5
  img.style.left = (50 + (VW / 2 - nx * VW) / sw * 100) + '%'
  img.style.top  = (50 + (VH / 2 - ny * VH) / sh * 100) + '%'
  S.imgFitActive = false
  updateMapWin()   // 只移动视野框，不重绘底图
}
// 只在视野框上按下才启动拖动（未放大、无局部框时不响应）
UI.imgMapWin.addEventListener('mousedown', (e) => {
  if (!UI.imgMapWrap.classList.contains('show')) return
  e.preventDefault(); e.stopPropagation()
  imgMapDragging = true
  UI.imgMapWin.classList.add('dragging')
  setImgViewportFromMap(e.clientX, e.clientY)
})
window.addEventListener('mousemove', (e) => {
  if (!imgMapDragging) return
  setImgViewportFromMap(e.clientX, e.clientY)
})
window.addEventListener('mouseup', () => {
  if (!imgMapDragging) return
  imgMapDragging = false
  UI.imgMapWin.classList.remove('dragging')
})

// 滚轮缩放（Ctrl）+ 拖动平移
UI.imageStage.addEventListener('wheel', (e) => {
  if (e.ctrlKey) { e.preventDefault(); zoomToSmooth(e.deltaY < 0 ? 1 : -1) }
}, { passive: false })
let pan = null
UI.imageStage.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return
  pan = { x: e.clientX, y: e.clientY, l: parseFloat(UI.imageEl.style.left || 50), t: parseFloat(UI.imageEl.style.top || 50) }
})
window.addEventListener('mousemove', (e) => {
  if (!pan) return
  const dx = ((e.clientX - pan.x) / Math.max(1, UI.imageEl.clientWidth)) * 100
  const dy = ((e.clientY - pan.y) / Math.max(1, UI.imageEl.clientHeight)) * 100
  UI.imageEl.style.left = (pan.l + dx) + '%'
  UI.imageEl.style.top = (pan.t + dy) + '%'
  S.imgFitActive = false
  updateImgMap()
})
window.addEventListener('mouseup', () => { pan = null })

/* ============================================================
   音频可视化（WebAudio 频谱）
   ============================================================ */
function ensureAudioCtx() {
  if (!S.audioCtx) {
    const AC = window.AudioContext || window.webkitAudioContext
    if (!AC) return false
    S.audioCtx = new AC()
  }
  if (S.audioCtx.state === 'suspended') S.audioCtx.resume()
  return true
}
function sourceFor(m) {
  const src = m === el.media ? el.media : audioEl
  return src
}
let connected = []
function startViz() {
  if (!S.settings.vizEnabled) return
  if (!ensureAudioCtx()) return
  const m = currentMedia
  if (!m || !m.src) return
  try {
    if (!m._srcNode) {
      m._srcNode = S.audioCtx.createMediaElementSource(m)
      m._analyser = S.audioCtx.createAnalyser()
      m._analyser.fftSize = 128
      m._srcNode.connect(m._analyser)
      m._analyser.connect(S.audioCtx.destination)
    }
    S.analyser = m._analyser
    drawViz()
  } catch (e) { /* 已连接或重复调用忽略 */ }
}
function stopViz() {
  cancelAnimationFrame(S.vizRAF)
  S.vizRAF = null
  drawEmptyViz()
}
function drawViz() {
  const canvas = UI.viz.getContext('2d')
  const W = canvas.canvas.width, H = canvas.canvas.height
  const g = 72
  const analyser = S.analyser
  const render = () => {
    canvas.clearRect(0, 0, W, H)
    if (!analyser) return
    const data = new Uint8Array(analyser.frequencyBinCount)
    analyser.getByteFrequencyData(data)
    const bars = 64
    const bw = (W - 8) / bars
    const ac = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#ff7a00'
    const ac2 = getComputedStyle(document.documentElement).getPropertyValue('--accent-2').trim() || '#ff9a3d'
    for (let i = 0; i < bars; i++) {
      // 取中频能量，视觉更好看
      const v = data[Math.floor((i / bars) * data.length)] / 255
      const bh = Math.max(2, v * (H - g))
      const x = 4 + i * bw
      const grd = canvas.createLinearGradient(0, H - g - bh, 0, H - g)
      grd.addColorStop(0, ac2); grd.addColorStop(1, ac)
      canvas.fillStyle = grd
      canvas.beginPath()
      canvas.roundRect(x, H - g - bh, bw - 3, bh, 3)
      canvas.fill()
    }
  }
  const loop = () => { render(); S.vizRAF = requestAnimationFrame(loop) }
  if (S.vizRAF) cancelAnimationFrame(S.vizRAF)
  loop()
}
function drawEmptyViz() {
  const canvas = UI.viz.getContext('2d')
  canvas.clearRect(0, 0, canvas.canvas.width, canvas.canvas.height)
}

/* ============================================================
   队列管理
   ============================================================ */
const QUEUE_KEY = 'sylph:queue'
let queueRestored = false   // restoreQueue 完成前禁止写盘：否则启动早期的一次 renderQueue 会把已有队列当成「空」清掉
// 持久化队列到 localStorage（仅保留可序列化的字段）
function saveQueue() {
  if (!queueRestored) return
  const arr = S.queue.map(q => ({ path: q.path, name: q.name, type: q.type, size: q.size || 0, url: !!q.url }))
  try {
    if (arr.length) localStorage.setItem(QUEUE_KEY, JSON.stringify(arr))
    else localStorage.removeItem(QUEUE_KEY)
  } catch (e) {}
}
// 启动时恢复上次队列
function restoreQueue() {
  try {
    const raw = localStorage.getItem(QUEUE_KEY)
    if (raw) {
      const arr = JSON.parse(raw)
      if (Array.isArray(arr)) S.queue = arr.filter(q => q && q.path && q.type)
    }
  } catch (e) {}
  queueRestored = true
}
function addToQueue(items) {
  if (!items || !items.length) return
  const added = []
  for (const it of items) {
    if (it && it.path && !S.queue.find(q => q.path === it.path) && it.type) {
      S.queue.push({ path: it.path, name: it.name, type: it.type, size: it.size || 0, url: !!it.url })
      added.push(S.queue.length - 1)
    }
  }
  renderQueue()
  if (added.length === 0) { toast('所选内容已在队列中'); return }
  // 新增文件直接播放/显示
  loadMedia(added[0])
  toast(`已添加 ${added.length} 项到队列`)
}
// 按搜索词（文件名，不分大小写）与类型筛选出要显示的条目，并保留各自的真实索引：
// 点击播放 / 删除 / 拖拽排序都沿用 S.queue 的真实索引，避免筛选状态下操作错项。
function filteredQueue() {
  const kw = (S.qSearch || '').trim().toLowerCase()
  const f = S.qFilter || 'all'
  const rows = []
  S.queue.forEach((it, qi) => {
    if (f !== 'all' && it.type !== f) return
    if (kw && !String(it.name || '').toLowerCase().includes(kw)) return
    rows.push({ it, qi })
  })
  return rows
}
function renderQueue() {
  saveQueue()   // 队列持久化：每次变更（增删/排序/清空）后写入 localStorage
  UI.queueList.innerHTML = ''
  const rows = filteredQueue()
  const filtering = rows.length !== S.queue.length
  UI.qCount.textContent = filtering ? rows.length + '/' + S.queue.length : String(S.queue.length)
  const isEmpty = S.queue.length === 0
  UI.qEmpty.style.display = (isEmpty || rows.length === 0) ? 'block' : 'none'
  UI.qEmpty.textContent = isEmpty ? '队列为空，拖入媒体或点击添加' : '没有符合条件的项目'
  UI.queueList.className = S.queueView === 'grid' ? 'q-list q-grid' : 'q-list'
  // 视图切换按钮高亮
  if (UI.qViewList) UI.qViewList.classList.toggle('active', S.queueView !== 'grid')
  if (UI.qViewGrid) UI.qViewGrid.classList.toggle('active', S.queueView === 'grid')
  if (rows.length === 0) return
  if (S.queueView === 'grid') renderQueueGrid(rows)
  else renderQueueList(rows)
  setupDrag(UI.queueList)
}
function renderQueueList(rows) {
  rows.forEach(({ it, qi }) => {
    const li = document.createElement('li')
    li.className = 'q-item' + (qi === S.current ? ' active' : '')
    li.draggable = true
    li.dataset.qindex = qi
    li.innerHTML = `
      <span class="q-ico"><i class="${TYPE_META[it.type].ico}"></i></span>
      <span class="q-txt">
        <span class="q-name">${escapeHtml(it.name)}</span>
        <span class="q-sub">${TYPE_META[it.type].label}${it.size ? ' · ' + humanSize(it.size) : ''}</span>
      </span>
      <button class="q-del" data-del="${qi}" title="从队列移除"><i class="fa-solid fa-xmark"></i></button>`
    li.addEventListener('click', (e) => {
      if (e.target.closest('.q-del')) return
      loadMedia(qi)
    })
    li.querySelector('.q-del').addEventListener('click', (e) => { e.stopPropagation(); removeFromQueue(qi) })
    UI.queueList.appendChild(li)
  })
}
function renderQueueGrid(rows) {
  rows.forEach(({ it, qi }) => {
    const li = document.createElement('li')
    li.className = 'q-grid-item' + (qi === S.current ? ' active' : '')
    li.draggable = true
    li.dataset.qindex = qi
    const thumb = thumbFor(it)
    li.innerHTML = `
      <div class="qg-thumb">${thumb}
        <button class="q-del qg-del" data-del="${qi}" title="从队列移除"><i class="fa-solid fa-xmark"></i></button>
        ${qi === S.current ? '<span class="qg-cur"><i class="fa-solid fa-volume-high"></i></span>' : ''}
      </div>
      <span class="qg-name">${escapeHtml(it.name)}</span>
      <span class="qg-sub">${TYPE_META[it.type].label}${it.size ? ' · ' + humanSize(it.size) : ''}</span>`
    li.addEventListener('click', (e) => { if (!e.target.closest('.q-del')) loadMedia(qi) })
    li.querySelector('.q-del').addEventListener('click', (e) => { e.stopPropagation(); removeFromQueue(qi) })
    UI.queueList.appendChild(li)
  })
  // 图片/视频缩略图由 img 自然加载；视频缩略图异步补采
}
// ---- 缩略图：图片直接用源图；视频异步抽帧；音频/加载中显示图标 ----
const _thumbCache = new Map()      // path -> dataURL | 'loading' | null
function thumbFor(item) {
  const cached = _thumbCache.get(item.path)
  if (cached) return cached === 'loading' ? iconThumb(item) : `<img class="qg-img" src="${cached}" alt="" draggable="false">`
  if (item.type === 'image') {
    const url = item.url ? item.path : window.sylph.toFileUrl(item.path)
    _thumbCache.set(item.path, url)
    return `<img class="qg-img" src="${url}" alt="" draggable="false">`
  }
  if (item.type === 'audio') return iconThumb(item)
  // video：抽帧
  _thumbCache.set(item.path, 'loading')
  captureVideoThumb(item)
  return iconThumb(item)
}
function iconThumb(item) {
  return `<span class="qg-ico"><i class="${TYPE_META[item.type].ico}"></i></span>`
}
function captureVideoThumb(item) {
  // 远程 URL 视频：跨域会污染 canvas，无法抽帧 → 放弃缩略图（沿用图标）
  if (item.url) { _thumbCache.set(item.path, null); return }
  const url = window.sylph.toFileUrl(item.path)
  const v = document.createElement('video')
  v.muted = true; v.playsInline = true; v.preload = 'metadata'
  v.src = url
  const canvas = document.createElement('canvas'); canvas.width = 160; canvas.height = 90
  let done = false
  const finish = (dataURL) => {
    if (done) return; done = true
    _thumbCache.set(item.path, dataURL || null)
    if (S.queueView === 'grid') renderQueue()
    v.removeAttribute('src'); v.load()
  }
  v.addEventListener('error', () => finish(null))
  v.addEventListener('loadeddata', () => {
    try {
      const dur = v.duration || 0
      // 抽内容帧而非首帧，避开开头黑屏：seek 到视频前 25% 处（等效"第 60 帧"所在中前段）
      let t = dur ? dur * 0.25 : 0
      if (dur && t > dur - 0.5) t = dur / 2
      v.currentTime = t
    } catch (e) {}
  })
  v.addEventListener('seeked', () => {
    try {
      const ctx = canvas.getContext('2d')
      ctx.drawImage(v, 0, 0, 160, 90)
      finish(canvas.toDataURL('image/jpeg', 0.55))
    } catch (e) { finish(null) }
  })
  setTimeout(() => finish(null), 4000)   // 超时兜底
}
function escapeHtml(s) { return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])) }
function removeFromQueue(i) {
  S.queue.splice(i, 1)
  if (S.queue.length === 0) { stopAll(); showEmpty(); }
  else if (i === S.current) loadMedia(Math.min(i, S.queue.length - 1))
  else if (i < S.current) S.current--
  renderQueue()
}
function setupDrag(list) {
  let dragIdx = null
  list.addEventListener('dragstart', (e) => {
    const li = e.target.closest('.q-item'); if (!li) return
    dragIdx = parseInt(li.dataset.qindex)
    li.classList.add('drag-ghost')
    e.dataTransfer.effectAllowed = 'move'
    e.dataTransfer.setData('application/x-sylph-queue', String(dragIdx))   // 内部排序标记，让全局 drop 忽略
  })
  list.addEventListener('dragend', (e) => {
    const li = e.target.closest('.q-item'); if (li) li.classList.remove('drag-ghost')
    dragIdx = null
  })
  list.addEventListener('dragover', (e) => { e.preventDefault(); e.dataTransfer.dropEffect = 'move' })
  list.addEventListener('drop', (e) => {
    e.preventDefault()
    const li = e.target.closest('.q-item'); if (!li || dragIdx == null) return
    const toIdx = parseInt(li.dataset.qindex)
    if (dragIdx === toIdx) return
    const [moved] = S.queue.splice(dragIdx, 1)
    S.queue.splice(toIdx, 0, moved)
    if (S.current === dragIdx) S.current = toIdx
    else if (S.current > dragIdx && S.current <= toIdx) S.current--
    else if (S.current < dragIdx && S.current >= toIdx) S.current++
    renderQueue()
  })
}

/* ============================================================
   打开文件 / 文件夹
   ============================================================ */
async function openFiles() {
  const items = await window.sylph.openFiles()
  if (items.length) addToQueue(items)
}
async function openFolder() {
  const items = await window.sylph.openFolder()
  if (items.length) addToQueue(items)
}
// 添加 URL：弹窗输入，按扩展名归类后入队（如 https://…/xxx.png）
function promptAddUrl() {
  const mask = document.createElement('div')
  mask.className = 'url-mask'
  mask.innerHTML = `
    <div class="url-box">
      <div class="url-title"><i class="fa-solid fa-link"></i> 添加 URL</div>
      <input type="text" class="url-input" placeholder="https://…/图片.png 或 音频/视频链接" spellcheck="false">
      <div class="url-actions">
        <button class="btn" id="url-cancel">取消</button>
        <button class="btn primary" id="url-ok">添加到队列</button>
      </div>
    </div>`
  document.body.appendChild(mask)
  const inp = mask.querySelector('.url-input'); inp.focus()
  let done = false
  const finish = async () => {
    if (done) return; done = true
    mask.remove()
    const u = inp.value.trim()
    if (!u) return
    const type = await window.sylph.classifyUrl(u).catch(() => null)
    if (!type) { toast('不支持该 URL 的媒体格式'); return }
    let name = u
    try {
      const p = new URL(u).pathname
      const seg = p.split('/').filter(Boolean).pop()
      if (seg) name = decodeURIComponent(seg)
    } catch (e) {}
    addToQueue([{ path: u, name, type, size: 0, url: true }])
  }
  mask.querySelector('#url-ok').onclick = finish
  mask.querySelector('#url-cancel').onclick = () => { done = true; mask.remove() }
  mask.addEventListener('mousedown', (e) => { if (e.target === mask) { done = true; mask.remove() } })
  inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') finish(); if (e.key === 'Escape') { done = true; mask.remove() } })
}

/* ============================================================
   拖放（导入媒体）
   ============================================================ */
const isQueueDrag = (dt) => dt && dt.types && Array.prototype.includes.call(dt.types, 'application/x-sylph-queue')
document.addEventListener('dragover', (e) => {
  e.preventDefault()
  if (isQueueDrag(e.dataTransfer)) return   // 队列内部排序，不弹拖放遮罩
  UI.dropOverlay.classList.add('show')
})
document.addEventListener('dragleave', (e) => {
  if (!document.elementFromPoint(e.clientX, e.clientY)) UI.dropOverlay.classList.remove('show')
})
document.addEventListener('drop', async (e) => {
  e.preventDefault()
  UI.dropOverlay.classList.remove('show')
  if (isQueueDrag(e.dataTransfer)) return   // 内部排序由列表自身 drop 处理
  const fileList = e.dataTransfer.files
  if (fileList && fileList.length) {
    const paths = []
    for (let i = 0; i < fileList.length; i++) {
      const f = fileList[i]
      // Electron 给拖入文件注入 .path；目录我们通过 webUtils 也可探测，但文件里目录 .path 指向目录
      const p = f.path
      if (p) paths.push(p)
    }
    await importPaths(paths)
  } else {
    // 无本地文件：尝试从浏览器标签页/链接拖入的 URL 文本
    await importDroppedUrl(e.dataTransfer)
  }
})
// 处理拖入的 URL（如从浏览器地址栏/标签页拖出的视频或图片链接）
async function importDroppedUrl(dt) {
  if (!dt) return
  let raw = ''
  try { raw = dt.getData('text/uri-list') || dt.getData('text/plain') || '' } catch (e) {}
  const urls = raw.split(/\r?\n/).map(s => s.trim()).filter(s => s && !s.startsWith('#'))
  if (!urls.length) return
  // 取第一条可用且分类成功的媒体链接
  for (const u of urls) {
    const type = await window.sylph.classifyUrl(u).catch(() => null)
    if (!type) continue
    let name = u
    try { const seg = u.split('/').filter(Boolean).pop(); if (seg) name = decodeURIComponent(seg) } catch (e) {}
    addToQueue([{ path: u, name, type, size: 0, url: true }])
    return
  }
  toast('该链接不是支持的媒体格式')
}
async function importPaths(paths) {
  const files = [], dirs = []
  let invalid = 0
  for (const p of paths) {
    const meta = await window.sylph.getFileMeta(p).catch(() => null)
    if (!meta) { invalid++; continue }          // 二进制/不被支持的格式 → 不加入队列
    if (meta.dir) dirs.push(meta.path)
    else files.push(meta)
  }
  if (files.length) addToQueue(files)
  if (dirs.length) {
    for (const d of dirs) {
      const list = await window.sylph.listDir(d, S.settings.recursiveFolder)
      if (list && list.length) addToQueue(list)
      else toast('文件夹中没有识别到媒体文件')
    }
  }
  if (invalid) toast(`无法播放：${invalid} 个文件是二进制/不支持的格式，未加入队列`)
}

/* ============================================================
   控制条交互
   ============================================================ */
const Ctrl = {
  init() {
    $('#btn-play').onclick = togglePlay
    $('#btn-prev').onclick = prev
    $('#btn-next').onclick = next

    UI.seek.addEventListener('input', () => {
      isSeeking = true
      if (currentMedia) {
        const pct = UI.seek.max ? (UI.seek.value / UI.seek.max) * 100 : 0
        UI.seek.style.setProperty('--fill', pct + '%')
        UI.timeCur.textContent = fmtTime(UI.seek.value)
      }
    })
    UI.seek.addEventListener('change', () => {
      if (currentMedia && isFinite(currentMedia.duration)) {
        currentMedia.currentTime = parseFloat(UI.seek.value)
      }
      isSeeking = false
    })

    UI.volume.addEventListener('input', () => setVolume(parseFloat(UI.volume.value), true))
    UI.speed.addEventListener('change', () => {
      S.settings.defaultSpeed = parseFloat(UI.speed.value)
      saveSettings()
      applyAllRates()
    })

    $('#btn-mode').onclick = (e) => { e.stopPropagation(); toggleModeMenu() }
    $('#btn-fs').onclick = toggleFullscreen
    $('#btn-info').onclick = openInfo
    $('#btn-lrc').onclick = importLyrics
    // 播放模式下拉：由 MODES 生成（含图标），并绑定选中/关闭
    if (UI.modeMenu) {
      for (const k of Object.keys(MODES)) {
        const li = document.createElement('div')
        li.className = 'mode-item'
        li.dataset.mode = k
        li.innerHTML = `<i class="${MODES[k].ico}"></i><span>${MODES[k].label}</span>`
        UI.modeMenu.appendChild(li)
      }
      UI.modeMenu.addEventListener('click', (e) => { e.stopPropagation(); const it = e.target.closest('.mode-item'); if (it) setPlayMode(it.dataset.mode) })
    }
    window.addEventListener('click', () => closeModeMenu())

    // 信息面板关闭
    $('#info-close').onclick = closeInfo
    $('#info-done').onclick = closeInfo
    UI.infoMask.addEventListener('click', (e) => { if (e.target === UI.infoMask) closeInfo() })

    // 队列视图切换（列表 / 缩略图网格）
    $('#q-view-list').onclick = () => { S.queueView = 'list'; localStorage.setItem('sylph:qview', 'list'); renderQueue() }
    $('#q-view-grid').onclick = () => { S.queueView = 'grid'; localStorage.setItem('sylph:qview', 'grid'); renderQueue() }

    // 队列搜索 + 类型筛选（综合 = 不限类型；类型选择持久化）
    const qSearch = $('#q-search')
    const qSearchBox = qSearch.closest('.q-search')
    const syncQSearch = () => qSearchBox.classList.toggle('has-text', !!qSearch.value)
    S.qSearch = S.qSearch || ''
    const savedQF = localStorage.getItem('sylph:qfilter')
    S.qFilter = ['all', 'image', 'audio', 'video'].includes(savedQF) ? savedQF : 'all'
    const applyFilterBtn = () => document.querySelectorAll('[data-qf]').forEach(b => b.classList.toggle('active', b.dataset.qf === S.qFilter))
    qSearch.addEventListener('input', () => { S.qSearch = qSearch.value; syncQSearch(); renderQueue() })
    qSearch.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { qSearch.value = ''; S.qSearch = ''; syncQSearch(); renderQueue() }
    })
    $('#q-search-clear').onclick = () => { qSearch.value = ''; S.qSearch = ''; syncQSearch(); renderQueue(); qSearch.focus() }
    document.querySelectorAll('[data-qf]').forEach(b => {
      b.onclick = () => { S.qFilter = b.dataset.qf; localStorage.setItem('sylph:qfilter', S.qFilter); applyFilterBtn(); renderQueue() }
    })
    applyFilterBtn()

    // 图片控件
    $('#img-prev').onclick = prev
    $('#img-next').onclick = next
    $('#img-in').onclick = () => zoomToSmooth(1)
    $('#img-out').onclick = () => zoomToSmooth(-1)
    $('#img-fit').onclick = fitToContain
    $('#img-rotate').onclick = rotateImg
    $('#img-info').onclick = openInfo

    // 顶栏
    // 顶栏「+」：弹出「选择文件 / 添加文件夹」下拉（空界面消失后仍可添加文件夹）
    const addMenu = $('#add-menu')
    $('#btn-add').onclick = (e) => { e.stopPropagation(); addMenu.hidden = !addMenu.hidden }
    addMenu.querySelectorAll('.mode-item').forEach(it => {
      it.onclick = () => {
        addMenu.hidden = true
        if (it.dataset.add === 'files') openFiles()
        else if (it.dataset.add === 'folder') openFolder()
        else if (it.dataset.add === 'url') promptAddUrl()
      }
    })
    document.addEventListener('click', () => { addMenu.hidden = true })
    $('#empty-add-files').onclick = openFiles
    $('#empty-add-folder').onclick = openFolder
    $('#btn-theme').onclick = toggleTheme
    function setQueueOpen(open) {
  UI.queuePanel.classList.toggle('open', open)
  document.body.classList.toggle('with-queue', open)
}
$('#btn-queue').onclick = () => setQueueOpen(!UI.queuePanel.classList.contains('open'))
$('#q-close').onclick = () => setQueueOpen(false)
$('#q-clear').onclick = () => { S.queue = []; stopAll(); showEmpty(); renderQueue() }

    // 设置
    $('#btn-settings').onclick = openSettings
    $('#settings-close').onclick = closeSettings
    $('#settings-done').onclick = closeSettings
    $('#settings-mask').addEventListener('click', (e) => { if (e.target === UI.settingsMask) closeSettings() })

    // 自定义标题栏窗口控制
    $('#wc-min').onclick = () => window.sylph.windowControl('minimize')
    $('#wc-close').onclick = () => window.sylph.windowControl('close')
    $('#wc-max').onclick = () => window.sylph.windowControl('maximize')
    // 双击标题栏左侧品牌图标关闭窗口（Windows 行为）
    $('#brand').addEventListener('dblclick', (e) => {
      e.stopPropagation()
      window.sylph.windowControl('close')
    })
    // 双击标题栏空白处切换最大化（Windows 习惯）
    $('#topbar').addEventListener('dblclick', (e) => {
      if (e.target.closest('button') || e.target.closest('.brand')) return
      window.sylph.windowControl('maximize')
    })
    window.sylph.onMaximizeChange(setMaxIcon)
    window.sylph.isMaximized().then(setMaxIcon)

    // 作为默认打开方式被调用：接收系统传入的媒体文件 → 加入队列并播放
    if (window.sylph.onOpenFilesLaunch) {
      window.sylph.onOpenFilesLaunch((files) => { if (files && files.length) addToQueue(files) })
    }

    /* 最大化 / 还原 图标切换（SVG） */
const ICON_MAX = '<rect class="hollow" x="3" y="3" width="10" height="10" rx="1.5" />'
const ICON_RESTORE =
  '<rect class="hollow" x="2.5" y="4.5" width="9" height="9" rx="1" />' +
  '<rect x="4.5" y="2.5" width="9" height="9" rx="1" transform="translate(0,-0.5)" style="fill:var(--bg-elev)" />'
function setMaxIcon(isMax) {
  const svg = $('#wc-max-svg')
  if (!svg) return
  svg.innerHTML = isMax ? ICON_RESTORE : ICON_MAX
  $('#wc-max').title = isMax ? '还原' : '最大化'
}

/* 键盘 */
    document.addEventListener('keydown', onKey)
  }
}

function setVolume(v, remember) {
  S.settings.defaultVolume = v
  const m = currentMedia || audioEl
  m.volume = v / 100
  const fill = getComputedStyle(UI.volWrap).direction === 'rtl' ? (100 - v) + '%' : v + '%'
  UI.volWrap.style.setProperty('--fill', fill)
  UI.volume.className = ''
  void UI.volume.offsetWidth
  UI.volume.style.setProperty('--fill', v + '%')
  if (remember) saveSettings()
}
function toggleModeMenu() {
  if (UI.modeMenu.hidden) {
    UI.modeMenu.hidden = false
  } else {
    UI.modeMenu.hidden = true
  }
}
function closeModeMenu() { if (UI.modeMenu) UI.modeMenu.hidden = true }
function setPlayMode(mode) {
  if (!mode || !MODES[mode]) return
  S.settings.playMode = mode
  saveSettings()
  refreshPlayModeUI()
  // 切换到智能随机时重新洗牌；切换离开时释放袋
  if (mode === 'shuffle_smart') resetShuffleBag()
  closeModeMenu()
  toast('播放模式：' + MODES[mode].label)
}
function toggleFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen()
  else document.documentElement.requestFullscreen()
}

/* ============================================================
   全屏自动隐藏工具栏
   ============================================================ */
const FsAutoHide = {
  active: false,
  idleTimer: null,
  onMoveRef: null,            // 保持引用以便解绑
  EDGE_H: 24,            // 鼠标距离顶/底多近算"靠近边缘"
  IDLE_MS: 2500,         // 鼠标在中间停留多久后隐藏
  lastX: -1, lastY: -1,  // 最近一次鼠标位置（用于判断隐藏时是否停留在栏上）
  enter() {
    this.active = true
    document.body.classList.add('is-fs')
    this.scheduleHide()
    this.onMoveRef = (e) => this.onMove(e)
    window.addEventListener('mousemove', this.onMoveRef)
  },
  exit() {
    this.active = false
    document.body.classList.remove('is-fs', 'fs-top-show', 'fs-bottom-show')
    clearTimeout(this.idleTimer)
    if (this.onMoveRef) window.removeEventListener('mousemove', this.onMoveRef)
    this.onMoveRef = null
  },
  // 鼠标是否落在顶栏 / 底栏上
  _overBar(x, y) {
    const el = document.elementFromPoint(x, y)
    if (!el || !el.closest) return false
    return !!(el.closest('#topbar') || el.closest('#controlbar'))
  },
  onMove(e) {
    if (!this.active) return
    this.lastX = e.clientX
    this.lastY = e.clientY
    const y = e.clientY
    const h = window.innerHeight
    const overBar = this._overBar(e.clientX, e.clientY)
    const topShown = document.body.classList.contains('fs-top-show')
    const bottomShown = document.body.classList.contains('fs-bottom-show')
    // 靠近边缘显示；若栏已显示且鼠标停在栏上，则不因上移越过边缘而"逃走"
    const nearTop = y <= this.EDGE_H || (topShown && overBar)
    const nearBottom = y >= h - this.EDGE_H || (bottomShown && overBar)
    document.body.classList.toggle('fs-top-show', nearTop)
    document.body.classList.toggle('fs-bottom-show', nearBottom)
    this.scheduleHide()
  },
  scheduleHide() {
    clearTimeout(this.idleTimer)
    this.idleTimer = setTimeout(() => {
      if (!this.active) return
      // 鼠标仍停留在已显示的栏上则继续等待，不隐藏
      if (this._overBar(this.lastX, this.lastY)) { this.scheduleHide(); return }
      document.body.classList.remove('fs-top-show', 'fs-bottom-show')
    }, this.IDLE_MS)
  }
}
// F11 键（在非全屏时原生不触发 requestFullscreen，需要手动）
window.addEventListener('keydown', (e) => {
  if (e.key === 'F11') { e.preventDefault(); toggleFullscreen() }
})
document.addEventListener('fullscreenchange', () => {
  const fs = !!document.fullscreenElement
  if (fs) FsAutoHide.enter(); else FsAutoHide.exit()
  const fi = UI.fsBtn.querySelector('i')
  if (fi) fi.className = fs ? 'fa-solid fa-compress' : 'fa-solid fa-expand'
})
function toggleTheme() {
  S.settings.theme = S.settings.theme === 'dark' ? 'light' : 'dark'
  applySettings(); saveSettings()
  handleThemeChange()
}
function handleThemeChange() {
  drawEmptyViz(); if (S.vizRAF) { /* 重新绘制由于字体/颜色变化由动画循环自动处理 */ }
}
function onKey(e) {
  if (UI.settingsMask.classList.contains('open') || UI.infoMask.classList.contains('open')) return
  const t = e.target
  if (t.tagName === 'SELECT' || t.tagName === 'INPUT' || t.tagName === 'TEXTAREA') return
  const k = e.key
  const type = activeType()
  // 修饰键组合：Ctrl+O 打开文件，Ctrl+Shift+O 打开文件夹
  if (e.ctrlKey || e.metaKey) {
    if (e.shiftKey && (k === 'O' || k === 'o')) { e.preventDefault(); openFolder(); return }
    if (k === 'o' || k === 'O') { e.preventDefault(); openFiles(); return }
    return
  }
  switch (k) {
    case ' ': if (t === document.body) { e.preventDefault(); togglePlay() } break
    case 'Enter':
    case 'ArrowRight': seekBy(S.settings.seekStep); break
    case 'ArrowLeft': seekBy(-S.settings.seekStep); break
    case 'ArrowUp': e.preventDefault(); seekBy(S.settings.seekStepLong); break
    case 'ArrowDown': e.preventDefault(); seekBy(-S.settings.seekStepLong); break
    case 'PageUp': seekBy(S.settings.seekStep * 6); break
    case 'PageDown': seekBy(-S.settings.seekStep * 6); break
    case 'Home': if (currentMedia) { currentMedia.currentTime = 0; } break
    case 'End': if (currentMedia) { currentMedia.currentTime = (currentMedia.duration || 0) } break
    case 'n': case 'N': next(); break
    case 'p': case 'P': prev(); break
    case 'f': case 'F': toggleFullscreen(); break
    case 'm': case 'M': toggleMute(); break
    case 'l': case 'L': toggleModeMenu(); break
    case 'r': case 'R': if (type === 'image') rotateImg(); break
    case '+': case '=': if (type === 'image') zoomToSmooth(1); else seekBy(S.settings.seekStep); break
    case '-': case '_': if (type === 'image') zoomToSmooth(-1); else seekBy(-S.settings.seekStep); break
    case '0': fitToContain(); break
    case 'i': case 'I': if (type === 'image') zoomIn(); break
    case 'o': case 'O': if (type === 'image') zoomOut(); break
    case 's': case 'S': if (type === 'image') fitToContain(); break
    case 'Delete': if (S.current >= 0) removeFromQueue(S.current); break
  }
}
let _muted = false
function toggleMute() {
  _muted = !_muted
  const m = currentMedia || audioEl
  m.volume = _muted ? 0 : S.settings.defaultVolume / 100
  toast(_muted ? '已静音' : '已恢复音量')
}
function zoomIn() { if (activeType() === 'image') zoomToSmooth(1) }
function zoomOut() { if (activeType() === 'image') zoomToSmooth(-1) }
function seekBy(d) {
  if (!currentMedia) return
  currentMedia.currentTime = Math.max(0, Math.min(currentMedia.duration || 0, currentMedia.currentTime + d))
}

/* ============================================================
   文件信息面板
   ============================================================ */
async function openInfo() {
  const it = S.queue[S.current]
  if (!it) { toast('当前没有媒体'); return }
  const rows = []
  const add = (k, v) => rows.push(`<div class="set-row"><span class="set-label">${k}</span><span class="info-val">${v}</span></div>`)
  add('名称', escapeHtml(it.name))
  add('类型', TYPE_META[it.type].label)
  add('路径', `<span class="info-path">${escapeHtml(it.path)}</span>`)
  // 大小
  let size = it.size
  if (!size) { const meta = await window.sylph.getFileMeta(it.path).catch(() => null); size = meta && meta.size }
  add('大小', size ? humanSize(size) : '—')
  // 时长 / 分辨率
  const m = currentMedia
  if (it.type === 'video') {
    add('时长', m && isFinite(m.duration) ? fmtTime(m.duration) : '—')
    add('分辨率', m && m.videoWidth ? m.videoWidth + ' × ' + m.videoHeight : '—')
  } else if (it.type === 'audio') {
    add('时长', m && isFinite(m.duration) ? fmtTime(m.duration) : '—')
  } else if (it.type === 'image') {
    const img = UI.imageEl
    add('分辨率', img && img.naturalWidth ? img.naturalWidth + ' × ' + img.naturalHeight : '—')
  }
  UI.infoBody.innerHTML = `<div class="info-block">${rows.join('')}</div>`
  UI.infoMask.classList.add('open')
}
function closeInfo() { UI.infoMask.classList.remove('open') }

/* ============================================================
   舞台交互：滚轮音量/进度、点击视频暂停、拖动视频快进
   ============================================================ */
window.addEventListener('wheel', (e) => {
  // 图片区域滚轮已由 imageStage 处理 Ctrl 缩放；此处处理视频/音频的普通滚轮与 Shift 滚动
  const t = e.target
  const onControls = t.closest && (t.closest('#controlbar') || t.closest('#topbar') || t.closest('.panel') || t.closest('.modal-mask'))
  if (onControls) return
  if (!S.settings) return
  const type = activeType()
  if (type !== 'video' && type !== 'audio') return
  e.preventDefault()
  if (e.shiftKey) seekBy(e.deltaY > 0 ? S.settings.seekStep : -S.settings.seekStep)
  else setVolume(Math.max(0, Math.min(100, S.settings.defaultVolume + (e.deltaY > 0 ? -5 : 5))), true)
}, { passive: false })
// 点击视频切换播放/暂停；双击全屏
if (UI.videoEl) {
  UI.videoEl.addEventListener('click', () => { if (activeType() === 'video') togglePlay() })
  UI.videoEl.addEventListener('dblclick', toggleFullscreen)
  // 视频左下角「已暂停」指示器：暂停时显示（全屏友好），播放时隐藏
  const badge = $('#vid-pause-badge')
  const setVidPausedBadge = (p) => { if (badge) badge.hidden = !p }
  UI.videoEl.addEventListener('play', () => setVidPausedBadge(false))
  UI.videoEl.addEventListener('pause', () => setVidPausedBadge(true))
  setVidPausedBadge(!!UI.videoEl.paused)
  // 水平拖动视频快进/退
  let vDrag = null
  UI.videoEl.addEventListener('mousedown', (e) => {
    if (activeType() !== 'video') return
    vDrag = { x: e.clientX, t: UI.videoEl.currentTime || 0 }
  })
  window.addEventListener('mousemove', (e) => {
    if (!vDrag || !currentMedia) return
    const dx = e.clientX - vDrag.x
    const pct = dx / Math.max(1, UI.videoEl.clientWidth)
    UI.videoEl.currentTime = Math.max(0, Math.min(currentMedia.duration || 0, vDrag.t + pct * (currentMedia.duration || 0)))
  })
  window.addEventListener('mouseup', () => { vDrag = null })
}

/* ============================================================
   设置面板
   ============================================================ */
const SETTING_DEFS = [
  // 通用
  { tab: 'general', key: 'theme', label: '界面主题', desc: '跟随系统 / 深色 / 浅色', render: s => seg('theme', [['system', '跟随系统'], ['dark', '深色'], ['light', '浅色']], s.theme) },
  { tab: 'general', key: 'accentColor', label: '主题色', desc: '默认用界面主题色，拖动取色自定义；点重置恢复默认', render: s => `<span class="accent-pick"><input class="accent-color" type="color" data-k="accentColor" value="${s.accentColor || '#ff7a00'}"><button class="btn ghost sm accent-reset" type="button"><i class="fa-solid fa-rotate-left"></i> 重置</button></span>` },
  { tab: 'general', key: 'defaultVolume', label: '默认音量', desc: '新播放项的音量', render: () => `<input class="set-range rng-out" type="range" min="0" max="100" value="${S.settings.defaultVolume}"><span class="set-val" id="val-defaultVolume">${S.settings.defaultVolume}%</span>` },
  { tab: 'general', key: 'defaultSpeed', label: '默认播放速度', desc: '全局速度', render: () => sel('defaultSpeed', [[0.5, '0.5×'], [0.75, '0.75×'], [1, '1×'], [1.25, '1.25×'], [1.5, '1.5×'], [2, '2×']], S.settings.defaultSpeed) },
  { tab: 'general', key: 'playMode', label: '播放模式', desc: '无 / 单曲循环 / 列表循环 / 顺序 / 智能随机 / 随机', render: () => sel('playMode', [['off', '无'], ['one', '单曲循环'], ['all', '列表循环'], ['sequence', '顺序播放'], ['shuffle_smart', '随机播放(智能)'], ['shuffle', '随机播放']], S.settings.playMode) },
  { tab: 'general', key: 'autoNext', label: '自动播放下一项', desc: '媒体结束自动切换', render: s => toggle('autoNext', s.autoNext) },
  { tab: 'general', key: 'rememberProgress', label: '记忆播放进度', desc: '从上次暂停位置继续播放', render: s => toggle('rememberProgress', s.rememberProgress) },
  { tab: 'general', key: 'recursiveFolder', label: '递归扫描文件夹', desc: '添加文件夹时包含子目录', render: s => toggle('recursiveFolder', s.recursiveFolder) },
  { tab: 'general', key: 'trayOnClose', label: '关闭时后台播放', desc: '关闭窗口时最小化到托盘继续播放；关闭此开关则直接退出。改动后不再弹窗询问', render: s => toggle('trayOnClose', s.trayOnClose) },
  { tab: 'general', key: 'bgAlways', label: '后台永远刷新', desc: '打开高负载程序/频繁切换时避免音乐卡顿断音。注意：常驻后台持续刷新，可能更耗电并降低整体性能', render: s => toggle('bgAlways', s.bgAlways) },
  { tab: 'general', key: 'natQuiet', label: '切换为默认深浅主题', desc: '国庆彩蛋激活中：临时关闭国庆红金配色与横幅，恢复正常深浅主题外观', when: s => s._natActive, render: s => toggle('natQuiet', s.natQuiet) },
  // 图片
  { tab: 'image', key: 'imgFit', label: '图片适应方式', desc: '打开图片时的默认缩放', render: () => sel('imgFit', [['contain', '适应窗口'], ['actual', '原始大小'], ['fill', '填满']], S.settings.imgFit) },
  { tab: 'image', key: 'imgMap', label: '图片鹰眼图', desc: '右下角显示整图与当前视野框', render: s => toggle('imgMap', s.imgMap) },
  { tab: 'image', key: 'showHints', label: '显示图片操作提示', desc: '', render: s => toggle('showHints', s.showHints) },
  // 音乐
  { tab: 'music', key: 'lyricsEnabled', label: '显示歌词', desc: '主歌词开关；关闭时主窗口不显示歌词（回到频谱），桌面歌词也一并关闭', render: s => toggle('lyricsEnabled', s.lyricsEnabled) },
  { tab: 'music', key: 'vizEnabled', label: '音频可视化', desc: '播放时显示频谱；歌曲没有可用歌词（或「显示歌词」已关闭）时也会显示频谱 —— 属正常现象', render: s => toggle('vizEnabled', s.vizEnabled) },
  { tab: 'music', key: 'lyricsLines', label: '歌词显示行数', desc: '歌词页一屏显示多少行', render: () => `<input class="set-range rng-lines" type="range" min="3" max="12" value="${S.settings.lyricsLines}"><span class="set-val" id="val-lyricsLines">${S.settings.lyricsLines} 行</span>` },
  { tab: 'music', key: 'desktopLyrics', label: '桌面歌词栏', desc: '置顶小窗显示当前歌词，可拖动，悬停调节字号/颜色；需先开启「显示歌词」', render: s => toggle('desktopLyrics', s.desktopLyrics, !s.lyricsEnabled) },
  // 视频
  { tab: 'video', key: 'seekStep', label: '方向键步进·短(秒)', desc: '←→ 快进/退', render: () => sel('seekStep', [[3, '3 秒'], [5, '5 秒'], [10, '10 秒'], [30, '30 秒']], S.settings.seekStep) },
  { tab: 'video', key: 'seekStepLong', label: '方向键步进·长(秒)', desc: '↑↓ 快进/退', render: () => sel('seekStepLong', [[30, '30 秒'], [60, '1 分钟'], [120, '2 分钟'], [300, '5 分钟']], S.settings.seekStepLong) },
  { tab: 'video', key: 'vidFit', label: '视频适应方式', desc: '仅作用于视频，不影响图片', render: () => sel('vidFit', [['contain', '适应'], ['cover', '填满'], ['fill', '拉伸']], S.settings.vidFit) },
  { tab: 'video', key: 'picBrightness', label: '画面亮度', desc: '视频画面亮度调节', render: () => vidRng('picBrightness', 50, 150, 100) },
  { tab: 'video', key: 'picContrast', label: '画面对比度', desc: '视频画面对比度', render: () => vidRng('picContrast', 50, 150, 100) },
  { tab: 'video', key: 'picSaturation', label: '画面饱和度', desc: '视频画面色彩饱和度', render: () => vidRng('picSaturation', 0, 200, 100) },
  { tab: 'video', key: 'videoTopmost', label: '播放视频时窗口置顶', desc: '看视频时窗口始终在最前', render: s => toggle('videoTopmost', s.videoTopmost) },
  // 实验性
  { tab: 'experimental', key: 'expSpeedSlider', label: '实验：倍速滑块', desc: '把控制条里的倍速下拉换成连续滑块（可自定义范围）', render: s => toggle('expSpeedSlider', s.expSpeedSlider) },
  { tab: 'experimental', key: 'speedMin', label: '倍速滑块·最小值', desc: '滑块拖动到最左的速度', render: s => `<div class="exp-io">× <input class="set-text rng-speedmin" data-k="speedMin" type="number" min="0.05" step="0.05" value="${S.settings.speedMin}"></div>` },
  { tab: 'experimental', key: 'speedMax', label: '倍速滑块·最大值', desc: '滑块拖动到最右的速度', render: s => `<div class="exp-io">× <input class="set-text rng-speedmax" data-k="speedMax" type="number" min="0.05" step="0.05" value="${S.settings.speedMax}"></div>` },
  { tab: 'experimental', key: 'expLyricsFill', label: '实验：歌词逐字渐变填充', desc: '歌词逐条播放，当前行文字自左向右逐字填充高亮（非卡拉OK歌词也生效）', render: s => toggle('expLyricsFill', s.expLyricsFill) },
  { tab: 'experimental', key: 'expAutoLyrics', label: '实验：自动寻找缺失歌词', desc: '本地歌词缺失时，联网从 LRCLIB（免费、无需账户）查找，且要求歌词版本与歌曲时长匹配；未找到或请求失败则保持默认频谱页', render: s => toggle('expAutoLyrics', s.expAutoLyrics) },
  { tab: 'experimental', key: 'dlc', label: '实验：强制对齐 DLC', desc: '字级歌词强制对齐工具（Python 引擎），下载后即可在主播放器中使用', when: () => IS_WIN && !IS_X86, render: () => `
    <div class="dlc-box">
      <div id="dlc-control" class="dlc-control"></div>
      <div id="dlc-progress" class="dlc-progress" hidden></div>
    </div>` }
]
const SETTING_TABS = [['general', '通用'], ['image', '图片'], ['music', '音乐'], ['video', '视频'], ['experimental', '实验性']]
let settingsTab = 'general'   // 当前激活的设置标签页
function seg(key, opts, val) {
  return `<div class="seg" data-k="${key}">${opts.map(([v, l]) => `<button class="seg-bar ${v === val ? 'active' : ''}" data-v="${v}">${l}</button>`).join('')}</div>`
}
function sel(key, opts, val) {
  return `<select class="set-select" data-k="${key}">${opts.map(([v, l]) => `<option value="${v}" ${String(v) === String(val) ? 'selected' : ''}>${l}</option>`).join('')}</select>`
}
function toggle(key, val, dis) {
  return `<label class="switch"${dis ? ' style="opacity:.45"' : ''}><input type="checkbox" data-k="${key}" ${val ? 'checked' : ''} ${dis ? 'disabled' : ''}><span class="sw-slider"></span></label>`
}
// 视频画面调节滑块（亮度/对比度/饱和度），实时作用于 CSS filter
function vidRng(key, min, max, def) {
  return `<span class="vid-rng"><input class="set-range rng-vid" type="range" data-k="${key}" min="${min}" max="${max}" step="1" value="${S.settings[key] ?? def}"><span class="set-val" id="val-${key}">${S.settings[key] ?? def}%</span></span>`
}
function openSettings() {
  const tabs = SETTING_TABS.map(([id, label]) =>
    `<button class="set-tab ${id === settingsTab ? 'active' : ''}" data-tab="${id}">${label}</button>`).join('')
  const panels = SETTING_TABS.map(([id]) => {
    const rows = SETTING_DEFS.filter(d => d.tab === id && (!d.when || d.when(S.settings))).map(d => `
      <div class="set-row${d.key === 'dlc' ? ' dlc-row' : ''}">
        <div><div class="set-label">${d.label}</div>${d.desc ? `<div class="set-desc">${d.desc}</div>` : ''}</div>
        <div class="set-control">${d.render(S.settings)}</div>
      </div>`).join('')
    const extra = ((id === 'general' && IS_WIN && !IS_X86)) ? `
      <div class="set-row">
        <div><div class="set-label">设为默认打开方式</div><div class="set-desc">用 Sylphplay 打开 mp4 / png / mp3 等媒体文件</div></div>
        <div class="set-control"><button class="btn primary sm" id="set-default-app"><i class="fa-solid fa-link"></i> 立即设置</button></div>
      </div>` : ''
    return `<div class="set-panel" data-panel="${id}" ${id === settingsTab ? '' : 'hidden'}>${rows}${extra}</div>`
  }).join('')

  UI.settingsBody.innerHTML = `<div class="set-tabs">${tabs}</div>${panels}`
  bindSettingEvents()
  UI.settingsMask.classList.add('open')
  // 标签页切换
  UI.settingsBody.querySelectorAll('.set-tab').forEach(btn => {
    btn.addEventListener('click', () => {
      settingsTab = btn.dataset.tab
      UI.settingsBody.querySelectorAll('.set-tab').forEach(b => b.classList.toggle('active', b === btn))
      UI.settingsBody.querySelectorAll('.set-panel').forEach(p => p.hidden = p.dataset.panel !== settingsTab)
    })
  })
  // 设默认按钮：仅在打包版可用，开发环境提示
  const btn = document.getElementById('set-default-app')
  if (btn) btn.addEventListener('click', async () => {
    btn.disabled = true
    try {
      const r = await window.sylph.setDefaultApp()
      if (r.unsupported) toast('当前平台不支持设置默认打开方式')
      else if (r.dev) toast('仅打包版支持设置默认打开方式（开发环境不可用）')
      else if (r.missing) toast('未找到关联助手，请重新打包')
      else if (r.ok) toast('已设为默认打开方式：mp4 / png / mp3 等媒体将用 Sylphplay 打开')
      else toast('设置失败：' + (r.error || '未知错误'))
    } catch (e) {
      toast('设置失败：' + (e && e.message ? e.message : e))
    } finally {
      btn.disabled = false
    }
  })
  // 强制对齐 DLC：初始化状态 + 事件绑定
  initDlcControl()
  initAlignButton()
}
function closeSettings() { UI.settingsMask.classList.remove('open') }

/* —— 顶栏「强制对齐」按钮：DLC 就绪（引擎存在）时才显示 —— */
function currentThemeName() {
  const s = S.settings
  const dark = s.theme === 'dark' || (s.theme !== 'light' && matchMedia('(prefers-color-scheme: dark)').matches)
  return dark ? 'dark' : 'light'
}
async function refreshAlignButton() {
  const btn = document.getElementById('btn-align')
  if (!btn) return
  if (!IS_WIN || IS_X86) { btn.hidden = true; return }   // x86 也隐藏：.NET 10 已砍 win-x86 RID
  let ready = false
  try { const st = await window.sylph.alignStatus(); ready = !!(st && st.ready) } catch (e) {}
  btn.hidden = !ready
}
let alignBtnBound = false
function initAlignButton() {
  const btn = document.getElementById('btn-align')
  if (btn && !alignBtnBound) {
    alignBtnBound = true
    btn.addEventListener('click', () => window.sylph.alignOpen(currentThemeName()))
  }
  refreshAlignButton()
}

/* —— 强制对齐 DLC 控件 —— */
// 渲染侧持久锁：一次下载未完成前保持 true，重渲染也会被它压成「下载中」，
// 避免下载途中因瞬时 status(downloading=false) 把按钮重新亮起。
let _dlcLocalBusy = false
function fmtBytes(n) {
  n = Number(n) || 0
  if (n < 1024) return Math.round(n) + ' B'
  if (n < 1048576) return (n / 1024).toFixed(1) + ' KB'
  if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB'
  return (n / 1073741824).toFixed(2) + ' GB'
}
function fmtSpeed(bps) {
  bps = Math.max(0, Number(bps) || 0)
  if (bps < 1024) return Math.round(bps) + ' B/s'
  if (bps < 1048576) return (bps / 1024).toFixed(1) + ' KB/s'
  return (bps / 1048576).toFixed(1) + ' MB/s'
}
async function initDlcControl() {
  const host = document.getElementById('dlc-control')
  if (!host) return
  let st
  try { st = await window.sylph.dlcStatus() } catch (e) { st = { installed: false, downloading: false, error: e } }
  const downloading = _dlcLocalBusy || !!st.downloading
  // 持久还原状态：正在下载（重开/刷新仍保留）→ 显示统计 + 取消；已安装 → 打开/删除；否则 → 下载
  if (downloading) {
    host.innerHTML = `<span class="dlc-stat" id="dlc-stat"></span>
       <button class="btn sm danger" id="dlc-cancel">取消下载</button>`
  } else if (st.installed) {
    host.innerHTML = `<button class="btn primary sm" id="dlc-open">打开强制对齐GUI</button>
       <button class="btn sm danger" id="dlc-remove">删除DLC</button>`
  } else {
    host.innerHTML = `<button class="btn primary sm" id="dlc-download">下载DLC</button>`
  }
  const go = document.getElementById('dlc-open'), rm = document.getElementById('dlc-remove')
  const dn = document.getElementById('dlc-download'), cc = document.getElementById('dlc-cancel')
  if (go) go.addEventListener('click', async () => {
    const r = await window.sylph.dlcOpen()
    if (!r.ok) toast(r.message || '启动失败')
  })
  if (rm) rm.addEventListener('click', async () => {
    const r = await window.sylph.dlcRemove()
    if (r.ok) { toast('已删除 DLC'); initDlcControl(); refreshAlignButton() }
    else toast('删除失败：' + (r.message || ''))
  })
  if (cc) cc.addEventListener('click', async () => {
    cc.disabled = true; cc.textContent = '正在取消…'
    const r = await window.sylph.dlcCancel()
    if (!r.ok) { cc.disabled = false; cc.textContent = '取消下载'; toast(r.message || '取消失败') }
  })
  if (dn) dn.addEventListener('click', async () => {
    const box = document.getElementById('dlc-progress'); if (box) box.hidden = false
    _dlcLocalBusy = true
    await initDlcControl()   // 立刻切换成「统计 + 取消下载」
    const r = await window.sylph.dlcDownload()
    _dlcLocalBusy = false
    if (r.ok) toast('DLC 下载并安装完成')
    else if (r.cancelled) toast('已取消下载')
    else toast('下载失败：' + (r.message || ''))
    initDlcControl()
    refreshAlignButton()
  })
}
// 下载进度：下方小字显示当前阶段，右侧统计显示「速度 · 已下载 / 总大小」
window.sylph.onDlcProgress((p) => {
  if (!p || p.phase === 'done') return
  const box = document.getElementById('dlc-progress')
  if (box) { box.textContent = '· ' + (p.message || ''); box.hidden = false }
  const el = document.getElementById('dlc-stat')
  if (!el) return
  const parts = []
  if (p.total > 0) {
    parts.push(fmtSpeed(p.speed))
    parts.push(fmtBytes(p.got) + ' / ' + fmtBytes(p.total))
  } else if (p.pct != null) {
    parts.push(p.pct + '%')
  }
  el.textContent = parts.join('   ')
})
function bindSettingEvents() {
  UI.settingsBody.querySelectorAll('[data-k]').forEach(c => {
    c.addEventListener('change', (e) => {
      const key = c.dataset.k
      if (c.type === 'checkbox') {
        // 桌面歌词依赖「显示歌词」主开关：主开关关闭时强制无法开启
        if (key === 'desktopLyrics' && c.checked && !S.settings.lyricsEnabled) {
          S.settings.desktopLyrics = false; c.checked = false; toast('请先开启「显示歌词」'); return
        }
        S.settings[key] = c.checked
        if (key === 'lyricsEnabled') {
          // 关闭主歌词开关 → 强制关闭桌面歌词（就地禁用开关）
          if (!c.checked && S.settings.desktopLyrics) {
            S.settings.desktopLyrics = false
            pushDesktopLyric('')
            const dc = UI.settingsBody.querySelector('[data-k="desktopLyrics"]')
            if (dc) { dc.checked = false; dc.disabled = true; const w = dc.closest('.switch'); if (w) w.style.opacity = '.45' }
          }
          applyLyricsVisibility()
        }
        if (key === 'vizEnabled') { if (c.checked) startViz(); else stopViz() }
        if (key === 'imgMap') updateImgMap()
        if (key === 'desktopLyrics') {
          const idx = Lyrics.activeIdx
          const L = (Lyrics.lines.length && idx >= 0) ? Lyrics.lines[idx] : null
          if (L) { pushDesktopLyric(L.text, L); Lyrics.updateFill(currentMedia ? currentMedia.currentTime : 0) }
          else pushDesktopLyric('')
        }
        if (key === 'trayOnClose') window.sylph.setTrayOnClose(c.checked)
        if (key === 'videoTopmost') window.sylph.setAlwaysOnTop(c.checked)
        if (key === 'expSpeedSlider') applySpeedControl()
        if (key === 'expLyricsFill') Lyrics.applyFill()
        if (key === 'natQuiet') applyNationalTheme()   // 国庆彩蛋：切回/恢复默认深浅主题
        if (key === 'bgAlways' || key === 'desktopLyrics' || key === 'expLyricsFill')
          window.sylph.setBackgroundThrottle(bgThrottleAllowed())   // 逐字填充/全局偏好 → 同步后台节流
      } else if (c.type === 'color') {
        S.settings[key] = c.value
        applyAccent()
      } else if (c.tagName === 'SELECT') {
        let v = c.value
        S.settings[key] = isNaN(v) ? v : parseFloat(v)
        if (key === 'playMode') refreshPlayModeUI()
        if (key === 'defaultVolume') updatesDefaultVolume()
        if (key === 'defaultSpeed') applyAllRates()
        if (key === 'imgFit') applyImgFit()
        if (key === 'vidFit') applyVideoFit()
      }
      saveSettings()
    })
    // seg buttons
    if (c.classList.contains('seg')) {
      c.querySelectorAll('.seg-bar').forEach(b => b.addEventListener('click', () => {
        c.querySelectorAll('.seg-bar').forEach(x => x.classList.remove('active'))
        b.classList.add('active')
        let v = b.dataset.v
        S.settings[c.dataset.k] = v
        if (c.dataset.k === 'theme') applySettings()
        saveSettings()
      }))
    }
  })
  // range
  UI.settingsBody.querySelectorAll('.rng-out').forEach(r => {
    r.addEventListener('input', () => {
      S.settings.defaultVolume = parseInt(r.value)
      const v = UI.settingsBody.querySelector('#val-defaultVolume')
      if (v) v.textContent = r.value + '%'
      setVolume(r.value, true)
    })
  })
  // 歌词行数
  UI.settingsBody.querySelectorAll('.rng-lines').forEach(r => {
    r.addEventListener('input', () => {
      S.settings.lyricsLines = parseInt(r.value)
      const v = UI.settingsBody.querySelector('#val-lyricsLines')
      if (v) v.textContent = r.value + ' 行'
      Lyrics.applyLines()
    })
  })
  // 视频画面调节（亮度/对比度/饱和度）实时预览
  UI.settingsBody.querySelectorAll('.rng-vid').forEach(r => {
    r.addEventListener('input', () => {
      S.settings[r.dataset.k] = parseInt(r.value)
      const v = UI.settingsBody.querySelector('#val-' + r.dataset.k)
      if (v) v.textContent = r.value + '%'
      applyVideoPic()
    })
  })
  // 倍速滑块范围（min/max）：实时校验并重建滑块
  UI.settingsBody.querySelectorAll('.rng-speedmin, .rng-speedmax').forEach(r => {
    r.addEventListener('change', () => {
      let v = parseFloat(r.value)
      if (!isFinite(v) || v < 0.05) v = 0.05   // 最小倍速下限
      r.value = v
      S.settings[r.dataset.k] = v
      const min = Math.max(0.05, Number(S.settings.speedMin) || 0.05)
      const max = Math.max(min, Number(S.settings.speedMax) || min)
      S.settings.speedMin = min
      S.settings.speedMax = max
      if (r.classList.contains('rng-speedmin')) {
        const m = UI.settingsBody.querySelector('.rng-speedmax')
        if (m) { m.value = max; m.min = min }
      } else {
        const m = UI.settingsBody.querySelector('.rng-speedmin')
        if (m) { m.max = max }
      }
      applySpeedControl()
      saveSettings()
    })
  })
  function updatesDefaultVolume() { UI.volume.value = S.settings.defaultVolume }
  // 主题色：拖动取色实时预览；点击重置还原默认
  UI.settingsBody.querySelectorAll('.accent-color').forEach(c => {
    c.addEventListener('input', () => {
      S.settings.accentColor = c.value
      applyAccent()
    })
  })
  UI.settingsBody.querySelectorAll('.accent-reset').forEach(btn => {
    btn.addEventListener('click', () => {
      S.settings.accentColor = ''
      applyAccent()
      const c = UI.settingsBody.querySelector('.accent-color')
      if (c) c.value = '#ff7a00'
      saveSettings()
    })
  })
}

/* ============================================================
   视频进度条悬停缩略图
   ============================================================ */
const SeekPrv = { v: null, shown: false }
function initSeekPreview() {
  const pv = $('#seek-pv'), pvC = $('#seek-pv-c'), pvT = $('#seek-pv-t')
  if (!pv || !pvC) return
  const ctx = pvC.getContext('2d')
  function mk() {
    if (!SeekPrv.v) {
      const v = document.createElement('video')
      v.muted = true; v.preload = 'auto'; v.playsInline = true
      const draw = () => {
        if (v.readyState < 2) return
        const w = pvC.width, h = pvC.height
        const vr = v.videoWidth / Math.max(1, v.videoHeight)
        const cwr = w / h
        let sw, sh, sx = 0, sy = 0
        if (vr > cwr) { sh = v.videoHeight; sw = sh * cwr; sx = (v.videoWidth - sw) / 2 }
        else { sw = v.videoWidth; sh = sw / cwr; sy = (v.videoHeight - sh) / 2 }
        ctx.clearRect(0, 0, w, h)
        ctx.drawImage(v, sx, sy, sw, sh, 0, 0, w, h)
      }
      v.addEventListener('seeked', draw)
      v.addEventListener('loadeddata', draw)
      SeekPrv.v = v
    }
    return SeekPrv.v
  }
  function hide() { if (SeekPrv.shown) { pv.hidden = true; SeekPrv.shown = false } }
  function move(e) {
    if (activeType() !== 'video' || !currentMedia || !currentMedia.src) { hide(); return }
    const rect = UI.seek.getBoundingClientRect()
    const row = pv.offsetParent ? pv.offsetParent.getBoundingClientRect() : rect
    const r = Math.min(1, Math.max(0, (e.clientX - rect.left) / Math.max(1, rect.width)))
    const dur = isFinite(currentMedia.duration) ? currentMedia.duration : (Number(UI.seek.max) || 0)
    const t = r * dur
    pvT.textContent = fmtTime(t)
    pv.style.left = `${Math.min(Math.max(0, e.clientX - row.left), Math.max(0, row.width))}px`
    if (!SeekPrv.shown) {
      const v = mk()
      if (v.src !== currentMedia.src) { v.src = currentMedia.src }
      pv.hidden = false; SeekPrv.shown = true
    }
    const v = SeekPrv.v
    if (v && v.src && Math.abs(v.currentTime - t) > 0.4) { try { v.currentTime = t } catch (err) {} }
  }
  UI.seek.addEventListener('pointermove', move)
  UI.seek.addEventListener('pointerdown', move)
  UI.seek.addEventListener('pointerleave', hide)
}

/* ============================================================
   启动
   ============================================================ */
function init() {
  loadSettings()
  applySettings()
  // 启动即检查 DLC 状态：就绪才显示顶栏「强制对齐」按钮（不必等用户打开设置）
  initAlignButton()
  detectNationalForce()   // 国庆彩蛋：异步补齐 `--101` 强制参数通道，并应用主题
  // 跟随系统深浅：系统深浅切换时实时刷新（仅在 mode=system 时生效）
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applySettings)
  Ctrl.init()
  initSeekPreview()
  S.queueView = localStorage.getItem('sylph:qview') === 'grid' ? 'grid' : 'list'
  restoreQueue()   // 恢复上次的队列
  renderQueue()
  // 队列有内容则自动展开队列面板，否则收拢（同时让主内容让位，不覆盖右侧）
  UI.queuePanel.classList.toggle('open', S.queue.length > 0)
  document.body.classList.toggle('with-queue', S.queue.length > 0)
  // 桌面歌词被其小窗关闭时，回显设置开关
  if (window.sylph.onLyricsState) {
    window.sylph.onLyricsState((on) => {
      if (!on && S.settings.desktopLyrics) {
        S.settings.desktopLyrics = false
        saveSettings()
        const c = UI.settingsBody.querySelector('[data-k="desktopLyrics"]')
        if (c) c.checked = false
      }
    })
  }
  // 无媒体：显示空状态
  showEmpty()
}

/* 沙箱插件系统已移除：倍速滑块、歌词逐字填充已改为内置实验性功能 */

function setPlaybackRate(v) {
  v = isFinite(v) ? v : 1
  S.settings.defaultSpeed = v
  if (el.media) el.media.playbackRate = v
  audioEl.playbackRate = v
  return v
}
// 实验性功能：把「倍数下拉」换成连续滑块（范围 min~max 由设置控制）
let injectedSpeedControl = null
function replaceSpeedControl() {
  removeSpeedControl()
  if (!UI.speed) return
  let lo = Number(S.settings.speedMin) || 0.25
  let hi = Number(S.settings.speedMax) || 4
  if (lo < 0.05) lo = 0.05
  if (hi < lo) hi = lo
  const step = 0.05
  const sel = UI.speed
  sel.style.display = 'none'
  const clamp = (v) => Math.min(hi, Math.max(lo, v))
  const wrap = document.createElement('div')
  wrap.className = 'spd-slider'
  wrap.innerHTML = '<span class="fa-solid fa-gauge-high"></span><input type="range"><span class="spd-slider-val"></span>'
  const rng = wrap.querySelector('input'), lab = wrap.querySelector('.spd-slider-val')
  rng.min = lo; rng.max = hi; rng.step = step
  rng.value = clamp(S.settings.defaultSpeed)
  const sync = (save) => {
    const v = clamp(parseFloat(rng.value))
    setPlaybackRate(v)
    if (save) saveSettings()
    lab.textContent = v.toFixed(2) + '×'
  }
  rng.addEventListener('input', () => sync(false))
  rng.addEventListener('change', () => sync(true))
  sel.insertAdjacentElement('afterend', wrap)
  injectedSpeedControl = wrap
  sync(false)
}
function removeSpeedControl() {
  if (injectedSpeedControl) { injectedSpeedControl.remove(); injectedSpeedControl = null }
  if (UI.speed) UI.speed.style.display = ''
  if (el.media) el.media.playbackRate = S.settings.defaultSpeed
  audioEl.playbackRate = S.settings.defaultSpeed
}
// 依据实验开关决定是否用滑块替换控制条里的倍速下拉
function applySpeedControl() {
  if (S.settings.expSpeedSlider) replaceSpeedControl()
  else removeSpeedControl()
}

// ========== 启动 ==========
// 脚本位于 body 末尾，DOM 已就绪
init()
applySpeedControl()