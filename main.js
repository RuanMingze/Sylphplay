// Sylphplay 主进程 — Ruanftrix
// 负责创建窗口、文件/文件夹对话框、媒体目录扫描、自定义标题栏窗口控制
const { app, BrowserWindow, Menu, dialog, ipcMain, nativeImage, screen, powerSaveBlocker, Tray } = require('electron')
const path = require('path')
const fs = require('fs')

// 支持的媒体扩展名分类
const MEDIA_EXT = {
  image: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'avif', 'jpg2', 'j2k', 'jpf', 'ico', 'jfif'],
  video: ['mp4', 'webm', 'mkv', 'mov', 'm4v', 'ogv', 'avi', 'mpg', 'mpeg', '3gp', '3g2', 'ts', 'm2ts'],
  audio: ['mp3', 'wav', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'flac', 'wma', 'weba', 'amr', 'mid', 'midi']
}
const ALL_EXT = [...MEDIA_EXT.image, ...MEDIA_EXT.video, ...MEDIA_EXT.audio]

let win = null
// dev 模式：`electron . --dev` 时打开 DevTools 便于排查
const IS_DEV = process.argv.includes('--dev')

// 平台判定：跨平台适配用。
// 「强制对齐 DLC」与「设为默认打开方式」仅 Windows 可用（依赖 Windows 专用引擎 / assoc-helper.exe），
// 其他平台隐藏入口并由 IPC 守卫兜底。
const IS_WIN = process.platform === 'win32'
const IS_X86 = process.arch === 'ia32'
const IS_MAC = process.platform === 'darwin'
const IS_LINUX = process.platform === 'linux'

// 从启动参数中提取媒体文件（作为默认打开方式被调用时，系统会把文件路径传进来）
function mediaFromArgv(argv) {
  return (argv || []).filter(a => typeof a === 'string')
    .filter(a => !a.startsWith('-'))
    .filter(a => fs.existsSync(a) && isMedia(a))
    .map(p => ({ path: p, name: path.basename(p), type: classify(p) }))
}

// 单实例锁：再次用「打开方式」启动时把媒体转发给已运行的实例
const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
} else {
  app.on('second-instance', (_evt, argv) => {
    const files = mediaFromArgv(argv)
    showMainWin()   // 哪怕是隐藏到托盘，也唤回主窗口
    if (win && !win.isDestroyed() && files.length) win.webContents.send('open-files-launch', files)
  })
}

function isMedia(file) {
  const ext = path.extname(file).slice(1).toLowerCase()
  return MEDIA_EXT.image.includes(ext) || MEDIA_EXT.video.includes(ext) || MEDIA_EXT.audio.includes(ext)
}

// macOS：Finder「打开方式 / 拖到应用图标」通过 open-file 事件派发，不走命令行参数（argv）。
// 窗口/渲染层未就绪时先入队，待主窗口加载完成后补发，避免早期事件丢失。
const pendingOpenFiles = []
function deliverOpenFiles(files) {
  if (!files || !files.length) return
  if (win && !win.isDestroyed() && win.webContents) {
    const send = () => win.webContents.send('open-files-launch', files)
    if (win.webContents.isLoading()) win.webContents.once('did-finish-load', send)
    else send()
  } else {
    pendingOpenFiles.push(...files)
  }
}
app.on('open-file', (e, filePath) => {
  e.preventDefault()
  if (!isMedia(filePath)) return
  const item = { path: filePath, name: path.basename(filePath), type: classify(filePath) }
  if (!app.isReady()) { pendingOpenFiles.push(item); return }   // 就绪前触发，先入队
  showMainWin()                                                 // 哪怕是隐藏到托盘，也唤回主窗口
  deliverOpenFiles([item])
})

function classify(file) {
  const ext = path.extname(file).slice(1).toLowerCase()
  if (MEDIA_EXT.image.includes(ext)) return 'image'
  if (MEDIA_EXT.video.includes(ext)) return 'video'
  return 'audio'
}

/* ============================================================
   桌面歌词窗口：置顶、透明、无边、可拖动、不占任务栏
   ============================================================ */
let lyricsWin = null
let desktopLyricsOn = false
let lastLyricsText = ''
const lyricsStylePath = () => path.join(app.getPath('userData'), 'desktop-lyrics.json')
function loadLyricsStyle() {
  try {
    if (fs.existsSync(lyricsStylePath())) return JSON.parse(fs.readFileSync(lyricsStylePath(), 'utf8'))
  } catch (e) {}
  return { size: 30, color: '#ffffff', width: 920 }
}
function saveLyricsStyle(s) {
  try { fs.writeFileSync(lyricsStylePath(), JSON.stringify(s || {}), 'utf8') } catch (e) {}
}
// 按歌词字符数估算一条歌词所需的窗口宽度（智能模式）：中文约 1 字宽，ASCII 折半 + 内边距
function applyLyricsWidth(w) {
  if (!lyricsWin || lyricsWin.isDestroyed()) return
  const b = lyricsWin.getBounds()
  // resizable:false 在 Windows 会连程序内的 setSize 一并禁用，需临时放开再收回
  lyricsWin.setResizable(true)
  lyricsWin.setSize(Math.max(160, Math.min(1800, w | 0)) || 160, b.height)
  lyricsWin.setResizable(false)
}
function pushLyricsStyle(s) {
  if (lyricsWin && !lyricsWin.isDestroyed()) lyricsWin.webContents.send('lyrics:style', s)
}
function ensureLyricsWin() {
  if (lyricsWin && !lyricsWin.isDestroyed()) return lyricsWin
  const cw = (loadLyricsStyle().width) || 920
  lyricsWin = new BrowserWindow({
    width: cw, height: 92,
    frame: false, transparent: true, resizable: false,
    alwaysOnTop: true, skipTaskbar: true, hasShadow: false,
    fullscreenable: false,
    // 需可聚焦，否则透明无焦点窗口在部分 Chromium 下点击/悬停会被吞掉
    focusable: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      backgroundThrottling: false
    }
  })
  lyricsWin.setAlwaysOnTop(true, 'screen-saver')
  lyricsWin.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  // 默认停靠在主屏工作区底部中央
  const wa = screen.getPrimaryDisplay().workArea
  lyricsWin.setPosition(wa.x + Math.round((wa.width - cw) / 2), wa.y + wa.height - 170)
  lyricsWin.loadFile(path.join(__dirname, 'app', 'lyrics.html'))
  lyricsWin.on('closed', () => { lyricsWin = null })
  // 捕获歌词窗口的脚本报错/控制台消息，转发到主进程终端与主窗口 DevTools，便于在歌词栏内排查
  lyricsWin.webContents.on('console-message', (evt, levelOrDetails, maybeMsg, line, source) => {
    let level = typeof levelOrDetails === 'number' ? levelOrDetails : (levelOrDetails && levelOrDetails.level)
    let msg = typeof maybeMsg === 'string' ? maybeMsg : (levelOrDetails && levelOrDetails.message)
    console.log(`[歌词窗口 console] ${msg}`)
    if (win && !win.isDestroyed()) {
      const sev = (level === 2 || level === 'warning') ? 'warn' : (level >= 3 ? 'error' : 'log')
      try {
        win.webContents.executeJavaScript(
          `console.${sev}('[歌词窗口] ' + ${JSON.stringify(String(msg))})`).catch(() => {})
      } catch (e) {}
    }
  })
  lyricsWin.webContents.on('render-process-gone', (_e, details) => {
    console.log(`[歌词窗口] 页面进程崩溃: ${details && details.reason}`)
  })
  // 页面就绪后再补发样式与当前歌词（此前发送会因 webContents 未就绪而丢失）
  lyricsWin.webContents.on('did-finish-load', () => {
    lyricsWin.webContents.send('lyrics:style', loadLyricsStyle())
    lyricsWin.webContents.send('lyrics:playstate', lastPlayingState)
    if (lastLyricsText) lyricsWin.webContents.send('lyrics:set', lastLyricsText)
  })
  return lyricsWin
}
function setDesktopLyricsOn(on) {
  desktopLyricsOn = !!on
  if (!desktopLyricsOn && lyricsWin && !lyricsWin.isDestroyed() && lyricsWin.isVisible()) lyricsWin.hide()
  // 同步到主窗口，让设置开关回显（例如歌词窗口自身被关闭）
  if (win && !win.isDestroyed()) win.webContents.send('lyrics:state', desktopLyricsOn)
}
ipcMain.handle('lyrics:show', (_e, text) => {
  const t = (text == null) ? '' : text
  lastLyricsText = t
  // 延迟到页面就绪后设置，避免丢失
  if (t !== '') {
    const w = ensureLyricsWin()
    if (w.webContents.isLoading()) {
      w.webContents.once('did-finish-load', () => w.webContents.send('lyrics:set', t))
    } else {
      w.webContents.send('lyrics:set', t)
    }
    if (!w.isVisible()) w.showInactive()
  } else {
    if (lyricsWin && !lyricsWin.isDestroyed() && lyricsWin.isVisible()) lyricsWin.hide()
  }
})
// 桌面歌词逐字填充进度（渲染进程每帧推送，仅在窗口存在时转发）
ipcMain.on('lyrics:fill', (_e, s) => {
  if (lyricsWin && !lyricsWin.isDestroyed()) lyricsWin.webContents.send('lyrics:fill', s)
})
ipcMain.on('lyrics-ui-close', () => setDesktopLyricsOn(false))
// 桌面歌词悬停控制条 → 转发给主窗口执行播放控制
ipcMain.on('lyrics:control', (_e, act) => {
  if (win && !win.isDestroyed()) win.webContents.send('lyrics-ctl', act)
})
// 主窗口播放状态 → 转发给歌词小窗，用于切换播放/暂停图标
let lastPlayingState = false
ipcMain.on('lyrics:playstate', (_e, playing) => {
  lastPlayingState = !!playing
  if (lyricsWin && !lyricsWin.isDestroyed()) lyricsWin.webContents.send('lyrics:playstate', lastPlayingState)
})
ipcMain.on('lyrics-ui-style', (_e, patch) => {
  const s = Object.assign(loadLyricsStyle(), patch || {})
  saveLyricsStyle(s)
  pushLyricsStyle(s)
})
ipcMain.on('lyrics-ui-width', (_e, w) => {
  // 手动调宽
  const s = Object.assign(loadLyricsStyle(), { width: Math.max(160, Math.min(1800, (w | 0) || 920)) })
  saveLyricsStyle(s)
  applyLyricsWidth(s.width)
  pushLyricsStyle(s)
})
ipcMain.handle('lyrics:pos', () => {
  if (lyricsWin && !lyricsWin.isDestroyed()) { const b = lyricsWin.getBounds(); return { x: b.x, y: b.y } }
  return { x: 0, y: 0 }
})
ipcMain.on('lyrics:move', (_e, x, y) => {
  if (lyricsWin && !lyricsWin.isDestroyed()) lyricsWin.setPosition(Math.round(x), Math.round(y))
})
ipcMain.on('lyrics-center', () => {
  if (!lyricsWin || lyricsWin.isDestroyed()) return
  const b = lyricsWin.getBounds()
  const wa = screen.getPrimaryDisplay().workArea
  lyricsWin.setPosition(wa.x + Math.round((wa.width - b.width) / 2), b.y)
})

// 递归扫描目录收集媒体文件
function scanFolder(dir, recursive = true) {
  const out = []
  function walk(p, depthFirst = true) {
    let items = []
    try { items = fs.readdirSync(p, { withFileTypes: true }) } catch (e) { return }
    for (const it of items) {
      const full = path.join(p, it.name)
      if (it.isDirectory()) {
        if (recursive) walk(full)
      } else if (it.isFile() && isMedia(it.name)) {
        out.push({ path: full, name: it.name, type: classify(full) })
      }
    }
  }
  walk(dir)
  return out
}

/* ============================================================
   窗口尺寸/位置记忆：存于用户数据目录 window-state.json，下次启动恢复
   ============================================================ */
const windowStateFile = () => path.join(app.getPath('userData'), 'window-state.json')
function loadWindowState() {
  try {
    const d = JSON.parse(fs.readFileSync(windowStateFile(), 'utf8'))
    if (!d || !d.width || !d.height) return null
    // 确保窗口至少部分落在某个屏幕上
    const bounds = { x: Number.isFinite(d.x) ? d.x : 0, y: Number.isFinite(d.y) ? d.y : 0, width: d.width, height: d.height }
    let visible = false
    for (const disp of screen.getAllDisplays()) {
      const a = disp.workArea
      if (bounds.x < a.x + a.width && bounds.x + bounds.width > a.x &&
          bounds.y < a.y + a.height && bounds.y + bounds.height > a.y) { visible = true; break }
    }
    if (!visible) return null
    return bounds
  } catch (e) { return null }
}
function saveWindowState() {
  if (!win || win.isDestroyed()) return
  const b = win.getBounds()
  try {
    fs.writeFileSync(windowStateFile(), JSON.stringify({
      x: b.x, y: b.y, width: b.width, height: b.height, maximized: win.isMaximized()
    }), 'utf8')
  } catch (e) { /* 忽略写失败 */ }
}

/* ============================================================
   后台播放：关闭到托盘
   ============================================================ */
let tray = null
let isQuitting = false   // 处于显式退出流程时不再拦截关闭

// 「关闭时后台播放（到托盘）」开关：true=关闭最小化到托盘；false=关闭即完全退出
let trayOnClose = true
// closeAsk=true 时每次关闭都弹窗询问；用户在弹窗勾选「记住」或在设置里改过开关后置 false
let closeAsk = true
function trayOnClosePath() { return path.join(app.getPath('userData'), 'tray-on-close.json') }
function loadTrayOnClose() {
  try {
    const j = JSON.parse(fs.readFileSync(trayOnClosePath(), 'utf8'))
    closeAsk = j.ask !== false
    return j.on !== false
  } catch (e) { closeAsk = true; return true }
}
function saveCloseCfg() {
  try { fs.writeFileSync(trayOnClosePath(), JSON.stringify({ on: trayOnClose, ask: closeAsk })) } catch (e) {}
}
ipcMain.handle('set-tray-on-close', (_e, on) => {
  trayOnClose = !!on
  closeAsk = false   // 设置里手动改过 → 不再弹窗询问
  saveCloseCfg()
  return trayOnClose
})
// 关闭时弹窗询问：直接退出 or 最小化到托盘（可勾选记住）
// 不走 dialog.showMessageBox（那是原生 Tauri 风格），改用 WebView 内自定义弹窗
ipcMain.on('close-choice', (_e, payload) => {
  if (!payload || !payload.action) return
  trayOnClose = payload.action === 'tray'
  if (payload.remember) { closeAsk = false; saveCloseCfg() }
  if (win && !win.isDestroyed()) win.webContents.send('tray-on-close-state', { on: trayOnClose, ask: closeAsk })
  if (trayOnClose) {
    win.hide()
    setMacDockVisible(false)
    if (tray) tray.setToolTip && tray.setToolTip('Sylphplay · 已最小化到托盘，音乐仍在播放')
  } else {
    quitApp()
  }
})
function askCloseAction() {
  if (win && !win.isDestroyed()) win.webContents.send('ask-close')
}
// 系统深浅变化由渲染进程的 prefers-color-scheme 监听处理
// 视频窗口置顶开关
ipcMain.on('set-always-on-top', (_e, on) => {
  if (win && !win.isDestroyed()) win.setAlwaysOnTop(!!on)
})
// 后台节流开关：true=允许节流(默认)，false=禁止节流(后台永远刷新)
ipcMain.on('set-background-throttle', (_e, allowed) => {
  if (win && !win.isDestroyed() && win.webContents) win.webContents.setBackgroundThrottling(!!allowed)
})

// macOS：切换到非激活态（隐藏 Dock 图标）或常规态（显示 Dock 图标）。
// 关闭窗口隐藏到菜单栏时隐藏 Dock，唤回主窗口时还原，符合 mac 后台常驻类应用习惯。
function setMacDockVisible(visible) {
  if (!IS_MAC || !app.dock) return
  try { visible ? app.dock.show() : app.dock.hide() } catch (e) {}
}

function showMainWin() {
  setMacDockVisible(true)   // macOS：唤回窗口时还原 Dock 图标
  if (!win || win.isDestroyed()) { createWindow(); return }
  if (win.isMinimized()) win.restore()
  win.show()
  win.focus()
}
function quitApp() {
  if (isQuitting) return
  isQuitting = true
  if (lyricsWin && !lyricsWin.isDestroyed()) lyricsWin.close()
  if (win && !win.isDestroyed()) win.close()
  app.quit()
}
function createTray() {
  try {
    const iconPath = path.join(__dirname, 'assets', 'icon.png')
    let icon = fs.existsSync(iconPath) ? nativeImage.createFromPath(iconPath) : nativeImage.createEmpty()
    if (icon.isEmpty()) icon = nativeImage.createFromDataURL('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
    // 平台差异化尺寸：macOS 菜单栏 16pt；Linux 各 DE 托盘 22px 更清晰；Windows 16px
    const traySize = IS_MAC ? 16 : (IS_LINUX ? 22 : 16)
    const trayIcon = icon.resize({ width: traySize, height: traySize })
    // macOS：标记为 template image，由系统按菜单栏深浅自动反色，避免图标看不见
    if (IS_MAC) { try { trayIcon.setTemplateImage(true) } catch (e) {} }
    tray = new Tray(trayIcon)
    tray.setToolTip('Sylphplay · 后台播放中，点击恢复')
    const menu = Menu.buildFromTemplate([
      { label: '显示主界面', click: () => showMainWin() },
      { type: 'separator' },
      { label: '退出 Sylphplay', click: () => quitApp() }
    ])
    tray.setContextMenu(menu)
    // 交互差异：Windows 单击图标恢复窗口；
    // macOS 设了菜单后单击即弹出菜单（系统惯例），不再绑定 click 恢复；
    // Linux 多数 DE（AppIndicator）下 click 事件不可靠，统一依赖右键/左键菜单。
    if (IS_WIN) {
      tray.on('click', () => showMainWin())
    } else if (IS_MAC) {
      tray.on('double-click', () => showMainWin())
    }
    console.log('[tray] created ok, platform=', process.platform)
  } catch (e) {
    console.error('[tray] create error:', e)
  }
}

function createWindow() {
  // 应用图标（窗口 + 任务栏）
  const icon = path.join(__dirname, 'assets', 'icon.png')
  const appIcon = fs.existsSync(icon) ? nativeImage.createFromPath(icon) : undefined

  const st = loadWindowState()

  win = new BrowserWindow({
    width: (st && st.width) || 1280,
    height: (st && st.height) || 800,
    x: st && st.x, y: st && st.y,
    minWidth: 820,
    minHeight: 560,
    show: false,
    // 自定义标题栏：去掉系统标题栏
    frame: false,
    backgroundColor: '#17120c',
    icon: appIcon,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      webSecurity: true,
      sandbox: false,
      // 禁止后台标签页节流/休眠，保证后台播放（音频/视频）不中断
      backgroundThrottling: false
    }
  })

  win.loadFile(path.join(__dirname, 'app', 'index.html'))
  win.once('ready-to-show', () => {
    win.show()
    if (st && st.maximized) win.maximize()
    if (IS_DEV) win.webContents.openDevTools({ mode: 'detach' })
  })
  // 显式退出时才真正关闭主窗口时同步销毁桌面歌词窗口（否则它作为独立窗口会残留并阻止退出）
  win.on('closed', () => { if (lyricsWin && !lyricsWin.isDestroyed()) lyricsWin.close() })
  // 关闭时保存窗口状态；根据「后台播放」开关决定：隐藏到托盘继续播放，或真正退出
  win.on('close', (e) => {
    saveWindowState()
    if (isQuitting) return
    e.preventDefault()   // 先拦下，由「询问 / 记住的选择」决定后续
    if (closeAsk) { askCloseAction(); return }
    if (trayOnClose) {
      win.hide()
      setMacDockVisible(false)   // macOS：隐藏到菜单栏后一并隐藏 Dock 图标
      if (tray) tray.setToolTip && tray.setToolTip('Sylphplay · 已最小化到托盘，音乐仍在播放')
    } else {
      quitApp()
    }
  })

  // 关闭默认菜单（Windows/Linux 保持简洁）；
  // macOS 必须保留标准应用菜单，否则 Cmd+C/V/A/Q 等系统级快捷键全部失效。
  if (IS_MAC) {
    Menu.setApplicationMenu(Menu.buildFromTemplate([
      { role: 'appMenu' },
      { role: 'editMenu' },
      { role: 'windowMenu' }
    ]))
  } else {
    Menu.setApplicationMenu(null)
  }

  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))

  // 推送最大化状态变化，供渲染层切换「最大化 / 还原」图标
  win.on('maximize', () => win.webContents.send('win-maximize-change', true))
  win.on('unmaximize', () => win.webContents.send('win-maximize-change', false))
}

// ---------- 自定义标题栏窗口控制 ----------
ipcMain.handle('window-control', (_e, act) => {
  const w = BrowserWindow.getFocusedWindow() || win
  if (!w) return false
  if (act === 'minimize') w.minimize()
  else if (act === 'maximize') (w.isMaximized() ? w.unmaximize() : w.maximize())
  else if (act === 'close') w.close()
  return w.isMaximized()
})
ipcMain.handle('win-is-maximized', () => (win ? win.isMaximized() : false))

// ---------- 文件 / 文件夹对话框 ----------
function fileFilters() {
  return [
    { name: '所有媒体', extensions: ALL_EXT },
    { name: '图片', extensions: MEDIA_EXT.image },
    { name: '视频', extensions: MEDIA_EXT.video },
    { name: '音频', extensions: MEDIA_EXT.audio },
    { name: '所有文件', extensions: ['*'] }
  ]
}

ipcMain.handle('open-files', async () => {
  const r = await dialog.showOpenDialog(win, {
    title: 'Sylphplay — 选择要添加的媒体',
    properties: ['openFile', 'multiSelections'],
    filters: fileFilters()
  })
  if (r.canceled) return []
  return r.filePaths.map(p => ({ path: p, name: path.basename(p), type: classify(p) }))
})

ipcMain.handle('open-folder', async () => {
  const r = await dialog.showOpenDialog(win, {
    title: 'Sylphplay — 选择媒体文件夹',
    properties: ['openDirectory']
  })
  if (r.canceled) return []
  return scanFolder(r.filePaths[0])
})

// ---------- 歌词（LRC 等文本）----------
// 智能解码：优先 UTF-8，失败（GBK/GB2312 等中文歌词常见）回退 gb18030
function decodeText(buf) {
  let text = null
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(buf)
  } catch (e) {
    try { text = new TextDecoder('gb18030').decode(buf) }
    catch (e2) { text = buf.toString('utf8') }
  }
  return text
}
function readText(p) {
  if (!p || typeof p !== 'string') return null
  try { return decodeText(fs.readFileSync(p)) } catch (e) { return null }
}

ipcMain.handle('open-lrc', async () => {
  const r = await dialog.showOpenDialog(win, {
    title: 'Sylphplay — 选择歌词文件',
    properties: ['openFile'],
    filters: [
      { name: '歌词文件', extensions: ['lrc', 'txt'] },
      { name: '所有文件', extensions: ['*'] }
    ]
  })
  if (r.canceled || !r.filePaths.length) return null
  return { path: r.filePaths[0], content: readText(r.filePaths[0]) }
})

// 读取歌词文件文本（供手动导入 / 自动查找同名 lrc 共用）
ipcMain.handle('read-lrc', (_e, p) => readText(p))

// 查找与媒体同名的相邻歌词（同 basename、.lrc/.txt），全平台可用
function findSidecarLrc(filePath) {
  const dir = path.dirname(filePath)
  const base = path.basename(filePath, path.extname(filePath))
  for (const ext of ['.lrc', '.txt']) {
    const cand = path.join(dir, base + ext)
    if (fs.existsSync(cand)) { try { return decodeText(fs.readFileSync(cand)) } catch (e) { } }
  }
  return null
}
ipcMain.handle('find-sidecar-lrc', (_e, p) => findSidecarLrc(p))

ipcMain.handle('get-file-meta', (_e, filePath) => {
  try {
    const st = fs.statSync(filePath)
    if (st.isDirectory()) return { dir: true, path: filePath, name: path.basename(filePath), size: st.size }
    if (!isMedia(filePath)) return null
    return { path: filePath, name: path.basename(filePath), size: st.size, type: classify(filePath) }
  } catch (e) {
    return null
  }
})

ipcMain.handle('list-dir', (_e, dirPath, recursive) => {
  return scanFolder(dirPath, recursive !== false)
})

ipcMain.handle('classify-url', (_e, url) => {
  try {
    const ext = new URL(String(url)).pathname.split('.').pop().toLowerCase()
    for (const [type, exts] of Object.entries(MEDIA_EXT)) if (exts.includes(ext)) return type
  } catch (e) {}
  return null
})

// 设为默认打开方式：按需调用 .NET 助手写注册表关联（mp4 / png / mp3 等）。
// 仅在打包版可用（开发环境没有真正的 Sylphplay.exe，直接拒绝）；
// 且只在此 IPC 被触发时才运行，启动时绝不调用、也绝不拉起应用。
// 国庆彩蛋：`--101` 强制参数通道（真实日期通道在渲染层检测；两条独立，均如实响应）
ipcMain.handle('national-flag', () => process.argv.includes('--101'))
ipcMain.handle('set-default-app', async () => {
  const { execFile } = require('child_process')
  if (!IS_WIN || IS_X86) return { ok: false, unsupported: true }   // 关联助手仅 Windows x64 版提供
  if (!app.isPackaged) return { ok: false, dev: true }                    // 开发环境不识别
  const exe = process.execPath                                             // 打包后即 Sylphplay.exe
  const helper = path.join(process.resourcesPath, 'assoc-helper.exe')      // extraResources 打包位置
  if (!fs.existsSync(helper)) return { ok: false, missing: true }
  return new Promise((resolve) => {
    execFile(helper, [exe], { windowsHide: true }, (err, stdout, stderr) => {
      if (err) resolve({ ok: false, error: String(stderr || err.message || err) })
      else resolve({ ok: true, message: String(stdout || '').trim() })
    })
  })
})

app.whenReady().then(() => {
  trayOnClose = loadTrayOnClose()
  // Windows 任务栏图标正确归组（需与打包后 productName 一致）；仅 Windows 有效
  if (IS_WIN) app.setAppUserModelId('com.ruanftrix.sylphplay')
  // 阻止系统进入节能休眠，保证后台播放持续（播放时由渲染层通过 IPC 动态启用/释放更优，这里兜底启用）
  powerSaveBlocker.start('prevent-app-suspension')
  createWindow()
  createTray()   // 托盘：关闭到托盘后提供恢复与退出入口
  // 首次启动即作为默认打开方式被调用：Windows/Linux 走 argv，
  // macOS 走 open-file 事件（就绪前已入队 pendingOpenFiles），两者合并后发给渲染层
  const startupFiles = [...pendingOpenFiles.splice(0), ...mediaFromArgv(process.argv)]
  if (startupFiles.length) {
    win.webContents.once('did-finish-load', () => win.webContents.send('open-files-launch', startupFiles))
  }
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  // 关闭到托盘时主窗口只是隐藏并未销毁，不会走到这里；只有显式退出才会真正关窗并退出
  if (isQuitting) app.quit()
})

/* ==================== 强制对齐 DLC ====================
 * 下载的 zip / 解压产物都放在 userData/dlc 下（可写、且不在 asar 内），保持
 * 「GUI exe 与 engine 目录相邻」的结构，C# 端会自动把 exe 所在目录识别为 DLC 根。
 */
// DLC 下载源：多镜像自动竞速 + 失败自动换源。
// 镜像统一为「前缀 + 完整 GitHub 地址」形式；运行时先并发探测、按延迟排序，再逐个尝试下载，
// 自建节点放最后做兜底。增删镜像只改这个数组即可（正式发布换公司服务器时也只改这里）。
const DLC_GH_PATH = 'https://github.com/ruanmz/Sylphplay/releases/download/1.0.0/Sylphplay-AlignDLC-x86_64.zip'
const DLC_MIRRORS = [
  'https://gh.dpik.top/',
  'https://github.starrlzy.cn/',
  'https://github.tbap.top/',
  'https://git.yylx.win/',
  'https://ghfile.geekertao.top/',
  'https://gh.llkk.cc/',
  'https://ghfast.top/',
  'https://ghproxy.ruanftrix.cn/'   // 自建兜底
]
const dlcCandidateUrls = () => DLC_MIRRORS.map(m => m + DLC_GH_PATH)

// 探测单个镜像是否可达：发一个 1 字节 Range 请求，拿到响应头即算通，随即取消 body
// （不真正下载文件）。返回「响应延迟(ms)」，不可达返回 null。
async function probeMirror(url, timeoutMs) {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), timeoutMs)
  const t0 = Date.now()
  try {
    const res = await fetch(url, { headers: { Range: 'bytes=0-0' }, signal: ctrl.signal, redirect: 'follow' })
    const ok = res.ok || res.status === 206
    try { if (res.body) res.body.cancel() } catch (e) {}
    return ok ? (Date.now() - t0) : null
  } catch (e) {
    return null
  } finally {
    clearTimeout(timer)
  }
}
// 并发探测所有镜像，按延迟升序返回；不可达的排在最后（仍作为兜底尝试一次）
async function orderMirrorsByLatency() {
  const urls = dlcCandidateUrls()
  const results = await Promise.all(urls.map(async (u) => ({ u, ms: await probeMirror(u, 4000) })))
  results.sort((a, b) => (a.ms == null ? Infinity : a.ms) - (b.ms == null ? Infinity : b.ms))
  return results.map(r => r.u)
}

function dlcRootDir() {
  return path.join(app.getPath('userData'), 'dlc')
}
function dlcZipPath() { return path.join(dlcRootDir(), 'align-dlc.zip') }
const dlcExtractedDir = () => path.join(dlcRootDir(), 'SylphplayAlignDLC')

// 返回 DLC 是否已准备好（能找到对齐引擎）+ 是否正在下载（供渲染层持久还原状态）
ipcMain.handle('dlc:status', () => {
  if (!IS_WIN) return { ok: true, installed: false, downloading: false, unsupported: true }  // 非 Windows 不提供 DLC
  try { return { ok: true, installed: !!alignEngine(), downloading: dlcBusy } }
  catch (e) { return { ok: true, installed: false, downloading: dlcBusy, error: String(e && e.message || e) } }
})

const axios = require('axios')

// 用 axios 在主进程内流式下载：写入 <zip>.part，失败/取消都保留它，
// 下次（或换源后）发 Range 请求从断点续传，不会从 0 开始。
// 失败 reject；err.fatal=true 表示「线路不可用」（DNS 挂、403/404），只有它会触发换源。
async function axiosDownload(url, zipPath, onProgress, signal) {
  const part = zipPath + '.part'
  let start = 0
  try { start = fs.statSync(part).size } catch (e) { start = 0 }
  const headers = { 'User-Agent': 'Sylphplay/1.0' }
  if (start > 0) headers.Range = 'bytes=' + start + '-'
  let res
  try {
    res = await axios.get(url, {
      responseType: 'stream', headers, signal,
      timeout: 60000,          // 60s 无数据即中断（卡住检测），而不是无限等待
      maxRedirects: 5,
      validateStatus: (s) => s >= 200 && s < 300
    })
  } catch (e) {
    throw classifyAxios(e)
  }
  // 服务器忽略 Range 返回 200：断点无效，整段重写
  const resume = res.status === 206 && start > 0
  if (start > 0 && !resume) start = 0
  const total = (Number(res.headers['content-length']) || 0) + start
  let got = start
  if (total && got) onProgress(got, total)
  await new Promise((resolve, reject) => {
    const ws = fs.createWriteStream(part, { flags: resume ? 'a' : 'w' })
    let settled = false
    const fail = (e) => { if (settled) return; settled = true; try { res.data.destroy() } catch (_) {}; reject(e) }
    res.data.on('data', (chunk) => { got += chunk.length; onProgress(got, total) })
    res.data.on('error', fail)
    ws.on('error', fail)
    ws.on('finish', () => { if (!settled) { settled = true; resolve() } })
    res.data.pipe(ws)
  })
  if (total && got < total) throw new Error('下载中断（' + got + ' / ' + total + ' 字节）')
  fs.renameSync(part, zipPath)
}

// axios 错误 → 普通中断 / 「线路不可用」（fatal）
function classifyAxios(e) {
  const status = e && e.response && e.response.status
  if (status) {
    const err = new Error('HTTP ' + status)
    err.fatal = [400, 401, 403, 404, 410].includes(status)
    return err
  }
  const err = new Error((e && e.message) || String(e))
  err.fatal = ['ENOTFOUND', 'ECONNREFUSED', 'EAI_AGAIN', 'ERR_NAME_NOT_RESOLVED'].includes(e && e.code)
  return err
}
// 当前下载的取消控制器（供「取消下载」中断），null 表示当前没有下载在跑
let dlcAbort = null
// 应用退出时中断下载
app.on('before-quit', () => {
  dlcCancelled = true
  if (dlcAbort) { try { dlcAbort.abort() } catch (e) {} }
})

// 清理下载中间产物：zip 本体、断点文件与历史分片残留
function cleanDlcTmp(zipPath) {
  const dir = path.dirname(zipPath)
  const base = path.basename(zipPath)
  try {
    for (const f of fs.readdirSync(dir)) {
      if (f === base || f === base + '.part' || f.startsWith(base + '.tmp')) fs.rmSync(path.join(dir, f), { force: true })
    }
  } catch (e) {}
}

// 单次下载保护，避免重复并发触发
let dlcBusy = false
let dlcCancelled = false
ipcMain.handle('dlc:download', async () => {
  if (!IS_WIN || IS_X86) return { ok: false, unsupported: true, message: '强制对齐功能仅支持 Windows x64（.NET 10 已砍 win-x86 RID）' }
  if (dlcBusy) return { ok: false, busy: true, message: '下载进行中，请稍候' }
  dlcBusy = true
  dlcCancelled = false
  dlcAbort = new AbortController()
  const { execFile } = require('child_process')
  let timer = null
  try {
    const zipPath = dlcZipPath()
    const target = dlcExtractedDir()
    fs.mkdirSync(dlcRootDir(), { recursive: true })
    // 清理旧 zip 与旧解压产物，确保干净、不残留过期版本（保留 .part 以支持断点续传）
    for (const p of [zipPath, target]) { try { fs.rmSync(p, { recursive: true, force: true }) } catch (e) {} }
    fs.mkdirSync(path.dirname(zipPath), { recursive: true })

    const send = (phase, pct, msg, extra) => {
      try { win && win.webContents.send('dlc:progress', Object.assign({ phase, pct, message: msg }, extra || {})) } catch (e) {}
    }

    // —— 下载统计：下载层每个数据块只更新内部状态，主进程每 800ms 统一推给界面 ——
    // 瞬时速度做指数平滑避免数字乱跳；1.5s 没有新数据就显示为 0（卡住时能看出来）。
    const stat = { pct: 0, got: 0, total: 0, speed: 0 }
    let phaseMsg = '正在选择最快镜像…'
    let lastDataAt = 0, sampleAt = 0, sampleGot = 0
    const onProgress = (got, total) => {
      if (total > 0) stat.total = total
      stat.got = got
      stat.pct = total > 0 ? Math.min(99, Math.round(got * 100 / total)) : 0
      lastDataAt = Date.now()
    }
    const pushStat = () => send('download', stat.pct, phaseMsg,
      { got: stat.got, total: stat.total, speed: Math.max(0, stat.speed) })
    timer = setInterval(() => {
      const now = Date.now()
      if (sampleAt && now > sampleAt) {
        const inst = (stat.got - sampleGot) / ((now - sampleAt) / 1000)
        stat.speed = stat.speed ? stat.speed * 0.6 + inst * 0.4 : inst
      }
      if (!lastDataAt || now - lastDataAt > 1500) stat.speed = 0
      sampleAt = now; sampleGot = stat.got
      pushStat()
    }, 800)
    send('download', 0, phaseMsg)

    // —— 在主进程内用 axios 流式下载 ——
    // 先并发探测所有镜像按延迟排序，再用最快的那个下载。
    // 只有「线路本身不可用」（域名挂了、HTTP 403/404）才换源；普通中断不换源。
    const urls = await orderMirrorsByLatency()
    let lastErr = null
    let downloaded = false
    for (let i = 0; i < urls.length && !downloaded; i++) {
      if (dlcCancelled) break
      const url = urls[i]
      let host = url
      try { host = new URL(url).host } catch (e) {}
      phaseMsg = `下载中（${host}）`
      stat.pct = 0; stat.got = 0; stat.speed = 0
      lastDataAt = 0; sampleAt = 0; sampleGot = 0
      pushStat()
      try {
        await axiosDownload(url, zipPath, onProgress, dlcAbort.signal)
        downloaded = true
      } catch (e) {
        lastErr = e
        if (dlcCancelled) break
        // 只有「线路本身不可用」（域名挂了、HTTP 403/404）才换源。
        // 普通中断不换源：换源等于从 0 重下，得不偿失，直接失败让用户重试即可。
        if (!e.fatal) break
        if (i + 1 < urls.length) {
          phaseMsg = `${host} 不可用，切换备用镜像…`
          send('download', 0, phaseMsg)
        }
      }
    }
    if (dlcCancelled) {
      cleanDlcTmp(zipPath)
      return { ok: false, cancelled: true, message: '已取消下载' }
    }
    if (!downloaded) throw lastErr || new Error('所有镜像均下载失败')

    clearInterval(timer); timer = null
    send('download', 95, '下载完成，正在解压…')

    // —— 解压：Windows 自带 Expand-Archive（免第三方依赖，与 asar 无关）——
    await new Promise((resolve, reject) => {
      execFile('powershell', ['-NoProfile', '-Command', `Expand-Archive -LiteralPath '${zipPath}' -DestinationPath '${target}' -Force`], { windowsHide: true }, (err) => err ? reject(new Error('解压失败：' + (err && err.message || err))) : resolve())
    })

    // 清掉下载的 zip（按需求：解压好就删掉 zip）
    try { fs.rmSync(zipPath, { force: true }) } catch (e) {}

    if (!alignEngine()) throw new Error('解压完成但未找到对齐引擎，请检查 DLC 包结构')
    send('done', 100, '完成')
    return { ok: true, installed: true }
  } catch (e) {
    return { ok: false, message: String(e && e.message || e) }
  } finally {
    if (timer) clearInterval(timer)
    dlcAbort = null
    dlcBusy = false
  }
})

// 取消下载：中断 axios 请求，下载循环看到 cancelled 标记后清理半成品
ipcMain.handle('dlc:cancel', () => {
  if (!IS_WIN) return { ok: false, unsupported: true }
  if (!dlcBusy || !dlcAbort) return { ok: false, message: '当前没有正在进行的下载' }
  dlcCancelled = true
  try { dlcAbort.abort() } catch (e) {}
  return { ok: true }
})

// DLC 菜单入口：打开内置强制对齐窗口（不再启动 DLC 里的 C# GUI）
ipcMain.handle('dlc:open', () => {
  if (!IS_WIN) return { ok: false, unsupported: true }
  openAlignWin(alignTheme); return { ok: true }
})

// 删除已解压的 DLC（保留目录，删除内容）
ipcMain.handle('dlc:remove', () => {
  if (!IS_WIN) return { ok: false, unsupported: true }
  try {
    const dir = dlcExtractedDir()
    if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true })
    try { fs.rmSync(dlcZipPath(), { force: true }) } catch (e) {}
    try { fs.rmSync(dlcZipPath() + '.part', { force: true }) } catch (e) {}
    return { ok: true }
  } catch (e) { return { ok: false, message: String(e && e.message || e) } }
})

/* ==================== 强制对齐（内置 GUI） ====================
 * 界面逻辑移植自 DLC 里的 C# GUI，引擎仍然用 DLC 的 align_engine.exe。
 * 引擎用法：align_engine.exe --audio <音频> --lrc <歌词> --out <结果json> [--language zh]
 * 结果 JSON：{ lines: [{ text, start, words: [{ char, start }] }] }
 */
const os = require('os')
const crypto = require('crypto')
const { spawn } = require('child_process')

const ALIGN_AUDIO_EXT = ['.mp3', '.flac', '.wav', '.m4a', '.aac', '.ogg', '.opus', '.wma', '.mp4']
const ALIGN_LANG_CODE = { '中文 (zh)': 'zh', '英语 (en)': 'en', '日语 (ja)': 'ja', '韩语 (ko)': 'ko' }

// 语言标签 -> 引擎语言代码（自动检测返回 null）
const alignLangCode = (label) => ALIGN_LANG_CODE[label] || null

// 在已解压的 DLC 里定位引擎；找不到返回 null
function alignEngine() {
  const root = dlcExtractedDir()
  if (!fs.existsSync(root)) return null
  const hits = []
  const walk = (d) => {
    let ents = []
    try { ents = fs.readdirSync(d, { withFileTypes: true }) } catch (e) { return }
    for (const en of ents) {
      const p = path.join(d, en.name)
      if (en.isDirectory()) walk(p)
      else if (en.name.toLowerCase() === 'align_engine.exe') hits.push(p)
    }
  }
  walk(root)
  if (hits.length) return { cmd: hits[0], args: [], packed: true }
  // 回退：Python 源码 / venv
  const script = path.join(root, 'python', 'align_engine.py')
  if (fs.existsSync(script)) {
    const venv = path.join(root, 'python', '.venv', 'Scripts', 'python.exe')
    return fs.existsSync(venv) ? { cmd: venv, args: [script], packed: false }
                              : { cmd: 'python', args: [script], packed: false }
  }
  return null
}

// 编码识别：BOM / 严格 UTF-8 → UTF-8；否则 GB18030（兼容 GBK 中文歌词）
function alignDecode(buf) {
  if (buf.length >= 3 && buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) {
    return new TextDecoder('utf-8').decode(buf.subarray(3))
  }
  try { return new TextDecoder('utf-8', { fatal: true }).decode(buf) }
  catch (e) {
    try { return new TextDecoder('gb18030').decode(buf) } catch (e2) { return new TextDecoder('utf-8').decode(buf) }
  }
}
function alignReadText(p) {
  try { return alignDecode(fs.readFileSync(p)) } catch (e) { return '' }
}

// 元信息标签（[ti:][ar:][offset:] 等），排除 [mm:ss] 时间行
function alignIsMetadataTag(line) {
  const t = line.trim()
  if (t.length < 3 || t[0] !== '[') return false
  const close = t.indexOf(']')
  if (close < 2) return false
  const key = t.slice(1, close)
  if (key.startsWith(':')) return false
  if (/^\d{1,2}[:：]\d{2}/.test(key)) return false
  return true
}
// 提取原歌词头部（保留 [ti:][ar:] 等，输出时拼回去）
function alignReadHeader(p) {
  const text = alignReadText(p)
  if (!text) return ''
  let out = ''
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '')
    if (alignIsMetadataTag(line)) out += line + '\n'
  }
  return out
}

const ALIGN_TIME_TAG = /\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]/g

// 是否已是导出后的逐字（增强）格式：时间标签出现在文字之间
function alignIsAlreadyAligned(p) {
  if (!p || !fs.existsSync(p)) return false
  const text = alignReadText(p)
  if (!text) return false
  let timed = 0, wordLevel = 0
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (!line || alignIsMetadataTag(line)) continue
    let hasTag = false, midTag = false
    ALIGN_TIME_TAG.lastIndex = 0
    let m
    while ((m = ALIGN_TIME_TAG.exec(line))) {
      hasTag = true
      if (m.index > 0 && line[m.index - 1] !== ']') { midTag = true; break }
    }
    if (!hasTag) continue
    timed++
    if (midTag) wordLevel++
  }
  return timed >= 3 && wordLevel * 2 >= timed
}

// 秒 -> [mm:ss.xx]
function alignFormatTime(sec) {
  if (!(sec > 0)) sec = 0
  let mm = Math.floor(sec / 60)
  let ss = Math.floor(sec % 60)
  let cs = Math.round((sec - Math.floor(sec)) * 100)
  if (cs >= 100) { cs = 0; ss++; if (ss >= 60) { ss = 0; mm++ } }
  const p2 = (n) => String(n).padStart(2, '0')
  return `${p2(mm)}:${p2(ss)}.${p2(cs)}`
}

// 解析引擎 JSON 的 lines（取行文本 + 逐字时间轴）
function alignParseLines(json) {
  const list = []
  let doc
  try { doc = JSON.parse(json) } catch (e) { return list }
  if (!doc || !Array.isArray(doc.lines)) return list
  for (const e of doc.lines) {
    const text = ((e && e.text) || '').trim()
    if (!text) continue
    const units = []
    if (e && Array.isArray(e.words)) {
      for (const w of e.words) {
        const ch = (w && w.char) || ''
        if (!ch) continue
        units.push({ char: ch, start: Number(w.start) || 0 })
      }
    }
    list.push({ start: Number(e.start) || 0, text, units })
  }
  return list
}

// 组装 LRC：增强=每字内联 [mm:ss.xx]；简单=[行时间]整行
function alignBuildLrc(lines, enhanced) {
  let out = ''
  for (const line of lines) {
    if (enhanced && line.units.length) {
      for (const u of line.units) out += `[${alignFormatTime(u.start)}]${u.char}`
    } else {
      out += `[${alignFormatTime(line.start)}]${line.text}`
    }
    out += '\n'
  }
  return out
}

// 批量扫描音频 / 找同名歌词
function alignScanAudio(dir, recursive) {
  const out = []
  const walk = (d) => {
    let ents = []
    try { ents = fs.readdirSync(d, { withFileTypes: true }) } catch (e) { return }
    for (const en of ents) {
      const p = path.join(d, en.name)
      if (en.isDirectory()) { if (recursive) walk(p) }
      else if (en.isFile() && ALIGN_AUDIO_EXT.includes(path.extname(en.name).toLowerCase())) out.push(p)
    }
  }
  walk(dir)
  out.sort((a, b) => a.localeCompare(b))
  return out
}
function alignFindPairedLrc(audio) {
  const guess = audio.replace(/\.[^.\\/]+$/, '.lrc')
  if (fs.existsSync(guess)) return guess
  const dir = path.dirname(audio)
  const base = path.basename(audio).replace(/\.[^.]+$/, '').toLowerCase()
  try {
    const hit = fs.readdirSync(dir).find(f =>
      f.toLowerCase().endsWith('.lrc') && path.basename(f, path.extname(f)).toLowerCase() === base)
    return hit ? path.join(dir, hit) : null
  } catch (e) { return null }
}

/* —— 运行状态 —— */
let alignWin = null
let alignTheme = 'dark'
let alignBusy = false
let alignCancelled = false
const alignChildren = new Set()
let alignResults = []      // [{ audio, lrc, ok, skipped, note, outLrc, json }]

function alignSend(channel, payload) {
  try { if (alignWin && !alignWin.isDestroyed()) alignWin.webContents.send(channel, payload) } catch (e) {}
}

// 用系统对话框选文件/文件夹（挂在对齐窗口上）
async function alignPick(kind, recursive) {
  const parent = (alignWin && !alignWin.isDestroyed()) ? alignWin : win
  if (kind === 'folder') {
    const r = await dialog.showOpenDialog(parent, { title: '选择文件夹（批量对齐）', properties: ['openDirectory'] })
    if (r.canceled || !r.filePaths.length) return { ok: false, cancelled: true }
    const dir = r.filePaths[0]
    const audios = alignScanAudio(dir, !!recursive)
    return { ok: true, dir, count: audios.length, paired: audios.filter(a => alignFindPairedLrc(a)).length }
  }
  const filters = kind === 'audio'
    ? [{ name: '音频文件', extensions: ['mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'wma', 'mp4'] }]
    : [{ name: 'LRC 歌词', extensions: ['lrc'] }]
  const r = await dialog.showOpenDialog(parent, {
    title: kind === 'audio' ? '选择音频' : '选择歌词（可选）',
    properties: ['openFile'], filters
  })
  if (r.canceled || !r.filePaths.length) return { ok: false, cancelled: true }
  return { ok: true, path: r.filePaths[0] }
}

// 处理单个文件：读头部 → 判断是否已对齐 → 调引擎 → 组装 LRC
async function alignRunOne(it, engine, opts) {
  const tag = path.basename(it.audio)
  if (!fs.existsSync(it.lrc)) { it.note = '歌词文件不存在'; return }
  if (alignIsAlreadyAligned(it.lrc)) { it.skipped = true; it.note = '已是导出后的逐字格式，跳过'; return }
  const header = alignReadHeader(it.lrc)
  const outJson = path.join(os.tmpdir(), 'sylph_align_' + crypto.randomUUID().replace(/-/g, '') + '.json')
  // 模型缓存目录显式指定到可写的 userData，避免继承 Sylphplay 的工作目录（打包后可能不可写）
  const workDir = path.join(dlcRootDir(), '.dlc_work')
  try { fs.mkdirSync(workDir, { recursive: true }) } catch (e) {}
  const args = [...engine.args, '--audio', it.audio, '--lrc', it.lrc, '--out', outJson, '--work', workDir]
  const lang = alignLangCode(opts.language)
  if (lang) args.push('--language', lang)

  let stdout = '', lastPush = 0
  const env = Object.assign({}, process.env, {
    // 模型走国内镜像；本机常缺 CA，关掉 SSL 校验与证书包
    HF_ENDPOINT: 'https://hf-mirror.com',
    HF_HUB_DISABLE_SSL_VERIFICATION: '1',
    CURL_CA_BUNDLE: '',
    // 关键：Python 被管道捕获时 stdout/stderr 会变成块缓冲，进度要等到进程结束才吐出来，
    // 看起来就是「捕获不到引擎输出」。强制无缓冲 + UTF-8，才能实时拿到 whisperx/tqdm 的进度。
    PYTHONUNBUFFERED: '1',
    PYTHONIOENCODING: 'utf-8',
    PYTHONUTF8: '1'
  })
  // 按 UTF-8 流式解码（多字节字符可能被拆到两个 chunk）
  const decOut = new TextDecoder('utf-8')
  const decErr = new TextDecoder('utf-8')
  const noteChunk = (isErr, s) => {
    if (!s) return
    alignSend('align:log', '[' + tag + ']' + (isErr ? '[err] ' : ' ') + s)
    const parts = s.split(/[\r\n]+/).filter(Boolean)
    if (!parts.length) return
    const now = Date.now()
    if (now - lastPush > 400) {
      lastPush = now
      alignSend('align:tick', { file: tag, line: parts[parts.length - 1].slice(0, 120) })
    }
  }
  // 引擎启动到出第一行输出之间可能很久（首次还要下模型），先给个明确提示，别让界面看起来没反应
  alignSend('align:tick', { file: tag, line: '已启动引擎，首次运行需下载模型，请耐心等待…' })
  const code = await new Promise((resolve) => {
    let child
    try { child = spawn(engine.cmd, args, { windowsHide: true, env }) }
    catch (e) { it.note = e.message; return resolve(-1) }
    alignChildren.add(child)
    const finish = (c) => { alignChildren.delete(child); resolve(c) }
    child.stdout.on('data', (d) => { const s = decOut.decode(d, { stream: true }); if (s) { stdout += s; noteChunk(false, s) } })
    child.stderr.on('data', (d) => noteChunk(true, decErr.decode(d, { stream: true })))
    child.on('error', (e) => { it.note = e.message; finish(-1) })
    child.on('close', (c) => finish(c))
  })

  try {
    if (code === 0 && fs.existsSync(outJson)) {
      const json = fs.readFileSync(outJson, 'utf8')
      const lines = alignParseLines(json)
      if (!lines.length) { it.note = '引擎未返回可用的歌词行'; return }
      it.json = json
      it.outLrc = header + alignBuildLrc(lines, opts.enhanced)
      it.ok = true
    } else if (alignCancelled) {
      it.note = '已取消'
    } else {
      // 引擎失败时会把原因写在最后一行 stdout 的 JSON（notice 字段）里，退出码本身没信息量
      let notice = ''
      try { notice = (JSON.parse(stdout.trim().split('\n').pop()) || {}).notice || '' } catch (e) {}
      it.note = notice || ('引擎退出码 ' + code)
      if (stdout.trim()) alignSend('align:log', '[' + tag + '][stdout] ' + stdout.trim())
    }
  } finally {
    try { if (fs.existsSync(outJson)) fs.rmSync(outJson, { force: true }) } catch (e) {}
  }
}

// 组装任务清单；返回 null 表示前置条件不满足（reason 已写明原因）
function alignBuildList(opts) {
  const list = [], noLrc = []
  if (opts.folder) {
    const audios = alignScanAudio(opts.folder, !!opts.recursive)
    if (!audios.length) return { error: '该文件夹内没有找到音频文件' }
    for (const a of audios) {
      const lrc = alignFindPairedLrc(a)
      if (!lrc) { noLrc.push(a); continue }
      list.push({ audio: a, lrc, ok: false, skipped: false, note: '', outLrc: '', json: '' })
    }
    if (!list.length) return { error: `扫描到 ${audios.length} 个音频，但没有找到同名 .lrc，无法对齐` }
    return { list, noLrc, batch: true }
  }
  if (!opts.audio) return { error: '请先选择音频，或选择一个文件夹' }
  if (!opts.lrc) return { error: '必须选择原歌词文件（用于保留头部与逐字对齐）' }
  return { list: [{ audio: opts.audio, lrc: opts.lrc, ok: false, skipped: false, note: '', outLrc: '', json: '' }], noLrc, batch: false }
}

ipcMain.handle('align:status', () => {
  if (!IS_WIN) return { ok: true, ready: false, engine: null, busy: false, unsupported: true }
  const en = alignEngine()
  return { ok: true, ready: !!en, engine: en ? en.cmd : null, busy: alignBusy }
})

// 打开内置对齐窗口（已开着就唤到前台）
function openAlignWin(theme) {
  alignTheme = theme === 'light' ? 'light' : 'dark'
  if (alignWin && !alignWin.isDestroyed()) { alignWin.show(); alignWin.focus(); return alignWin }
  alignWin = new BrowserWindow({
    width: 980, height: 680, minWidth: 780, minHeight: 540,
    frame: false, show: false, backgroundColor: alignTheme === 'light' ? '#fbf4ea' : '#17120c',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true
    }
  })
  alignWin.loadFile(path.join(__dirname, 'app', 'align.html'))
  alignWin.once('ready-to-show', () => alignWin.show())
  alignWin.webContents.on('did-finish-load', () => {
    alignWin.webContents.send('align:theme', alignTheme)
    const en = alignEngine()
    alignWin.webContents.send('align:engine', { ready: !!en, engine: en ? en.cmd : null })
  })
  alignWin.on('closed', () => {
    alignWin = null
    // 关窗即视为放弃本次处理，顺手结束还在跑的引擎进程
    if (alignBusy) {
      alignCancelled = true
      for (const c of alignChildren) { try { c.kill() } catch (e) {} }
    }
  })
  return alignWin
}

ipcMain.handle('align:open', (_e, theme) => {
  if (!IS_WIN) return { ok: false, unsupported: true }
  openAlignWin(theme); return { ok: true }
})

ipcMain.handle('align:pick', (_e, kind, recursive) => alignPick(kind, recursive))

ipcMain.handle('align:run', async (_e, opts) => {
  if (alignBusy) return { ok: false, message: '对齐进行中，请稍候' }
  const engine = alignEngine()
  if (!engine) return { ok: false, message: '未找到对齐引擎，请先下载 DLC' }
  const built = alignBuildList(opts || {})
  if (built.error) return { ok: false, message: built.error }

  const list = built.list
  alignBusy = true
  alignCancelled = false
  alignResults = list
  alignSend('align:start', { total: list.length, batch: built.batch })

  const total = list.length
  const maxPar = opts.parallel ? Math.max(2, Math.min(4, Math.round((os.cpus().length || 4) / 2))) : 1
  let done = 0
  const queue = list.slice()
  try {
    alignSend('align:progress', { done: 0, total, status: '正在处理…' })
    const workers = new Array(Math.max(1, Math.min(maxPar, total))).fill(0).map(async () => {
      while (queue.length && !alignCancelled) {
        const it = queue.shift()
        alignSend('align:progress', { done, total, status: `正在处理 ${done + 1}/${total}：${path.basename(it.audio)}` })
        await alignRunOne(it, engine, {
          language: opts.language,
          enhanced: opts.format !== '简单(逐行)'
        })
        done++
        alignSend('align:progress', { done, total, status: `已完成 ${done}/${total}` })
      }
    })
    await Promise.all(workers)
  } catch (e) {
    return { ok: false, message: String(e && e.message || e) }
  } finally {
    alignBusy = false
  }

  const ok = list.filter(i => i.ok).length
  const skip = list.filter(i => i.skipped).length
  const fail = list.length - ok - skip
  const summary = {
    total: list.length, ok, skip, fail, cancelled: alignCancelled,
    items: list.map(i => ({
      name: path.basename(i.audio),
      audio: i.audio,
      status: i.ok ? 'ok' : (i.skipped ? 'skip' : 'fail'),
      note: i.note
    })),
    noLrc: built.noLrc.map(p => path.basename(p)),
    // 单文件模式仍把引擎原始 JSON 回显，保持与原 GUI 一致的使用习惯
    json: (!built.batch && list.length === 1 && list[0].ok) ? list[0].json : ''
  }
  const text = alignCancelled ? '已取消' : `完成：成功 ${ok}，跳过 ${skip}，失败 ${fail}`
  alignSend('align:finish', { summary, status: text })
  return { ok: true, cancelled: alignCancelled, summary, status: text }
})

ipcMain.handle('align:cancel', () => {
  if (!alignBusy) return { ok: false, message: '当前没有正在进行的对齐' }
  alignCancelled = true
  for (const c of alignChildren) { try { c.kill() } catch (e) {} }
  return { ok: true }
})

// 保存对齐结果：单文件另存为 / 批量覆盖原文件 / 批量输出到文件夹
ipcMain.handle('align:save', async (_e, mode) => {
  const done = alignResults.filter(i => i.ok)
  if (!done.length) {
    return { ok: false, message: alignResults.some(i => i.skipped) ? '全部文件已是导出后的格式，无需保存' : '当前没有可保存的对齐结果' }
  }
  const parent = (alignWin && !alignWin.isDestroyed()) ? alignWin : win
  // 统一以 UTF-8（无 BOM）写出：主程序读取时优先按 UTF-8 解码，中文不会乱码
  if (mode === 'saveas') {
    const r = await dialog.showSaveDialog(parent, {
      title: '保存为 LRC',
      defaultPath: path.basename(done[0].audio).replace(/\.[^.]+$/, '') + '.lrc',
      filters: [{ name: 'LRC 歌词', extensions: ['lrc'] }]
    })
    if (r.canceled || !r.filePath) return { ok: false, cancelled: true }
    try { fs.writeFileSync(r.filePath, done[0].outLrc, 'utf8') }
    catch (e) { return { ok: false, message: String(e.message || e) } }
    return { ok: true, message: '已保存：' + r.filePath }
  }
  if (mode === 'overwrite') {
    let n = 0
    for (const it of done) { try { fs.writeFileSync(it.lrc, it.outLrc, 'utf8'); n++ } catch (e) {} }
    return { ok: true, message: `已覆盖 ${n}/${done.length} 个原歌词文件` }
  }
  const r = await dialog.showOpenDialog(parent, { title: '选择输出文件夹', properties: ['openDirectory', 'createDirectory'] })
  if (r.canceled || !r.filePaths.length) return { ok: false, cancelled: true }
  const dir = r.filePaths[0]
  let n = 0
  for (const it of done) {
    const name = path.basename(it.audio).replace(/\.[^.]+$/, '') + '.lrc'
    try { fs.writeFileSync(path.join(dir, name), it.outLrc, 'utf8'); n++ } catch (e) {}
  }
  return { ok: true, message: `已输出 ${n}/${done.length} 个歌词到 ${dir}` }
})