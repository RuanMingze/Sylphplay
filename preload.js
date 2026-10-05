// Sylphplay 预加载 — 在隔离的渲染进程里安全暴露 IPC
const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('sylph', {
  // 当前平台标识：渲染层据此隐藏 Windows 专属入口（DLC / 设为默认打开方式）
  platform: process.platform,
  openFiles: () => ipcRenderer.invoke('open-files'),
  openFolder: () => ipcRenderer.invoke('open-folder'),
  getFileMeta: (p) => ipcRenderer.invoke('get-file-meta', p),
  listDir: (p, recursive) => ipcRenderer.invoke('list-dir', p, recursive),
  // 本地文件转 file:// URL
  toFileUrl: (p) => {
    return 'file:///' + p.split(/[\\/]/).map(encodeURIComponent).join('/')
  },
  // 自定义标题栏窗口控制
  windowControl: (act) => ipcRenderer.invoke('window-control', act),
  isMaximized: () => ipcRenderer.invoke('win-is-maximized'),
  onMaximizeChange: (cb) => ipcRenderer.on('win-maximize-change', (_e, v) => cb(v)),
  // 歌词（LRC 等）
  openLrc: () => ipcRenderer.invoke('open-lrc'),
  readLrc: (p) => ipcRenderer.invoke('read-lrc', p),
  findSidecarLrc: (p) => ipcRenderer.invoke('find-sidecar-lrc', p),
  classifyUrl: (url) => ipcRenderer.invoke('classify-url', url),
  setTrayOnClose: (on) => ipcRenderer.invoke('set-tray-on-close', on),
  setAlwaysOnTop: (on) => ipcRenderer.send('set-always-on-top', on),
  setBackgroundThrottle: (allowed) => ipcRenderer.send('set-background-throttle', allowed),
  onOpenFilesLaunch: (cb) => ipcRenderer.on('open-files-launch', (_e, files) => cb(files)),
  // 设为默认打开方式（mp4 / png / mp3 等）
  setDefaultApp: () => ipcRenderer.invoke('set-default-app'),
  // 国庆彩蛋：是否带 --101 强制参数（日期通道在渲染层本地判断）
  nationalParam: () => ipcRenderer.invoke('national-flag'),
  // 桌面歌词（歌词小窗）
  lyricsShow: (text) => ipcRenderer.invoke('lyrics:show', text),
  onLyricsState: (cb) => ipcRenderer.on('lyrics:state', (_e, on) => cb(on)),
  onLyricsSet: (cb) => ipcRenderer.on('lyrics:set', (_e, t) => cb(t)),
  lyricsFill: (s) => ipcRenderer.send('lyrics:fill', s),
  onLyricsFill: (cb) => ipcRenderer.on('lyrics:fill', (_e, s) => cb(s)),
  onLyricsStyle: (cb) => ipcRenderer.on('lyrics:style', (_e, s) => cb(s)),
  lyricsClose: () => ipcRenderer.send('lyrics-ui-close'),
  lyricsStyle: (s) => ipcRenderer.send('lyrics-ui-style', s),
  lyricsWidth: (w) => ipcRenderer.send('lyrics-ui-width', w),
  lyricsCenter: () => ipcRenderer.send('lyrics-center'),
  lyricsPos: () => ipcRenderer.invoke('lyrics:pos'),
  lyricsMove: (x, y) => ipcRenderer.send('lyrics:move', x, y),
  // 桌面歌词悬停控制条：控制指令上行 / 播放状态下行
  lyricsControl: (act) => ipcRenderer.send('lyrics:control', act),
  onLyricsControl: (cb) => ipcRenderer.on('lyrics-ctl', (_e, a) => cb(a)),
  lyricsPlayState: (p) => ipcRenderer.send('lyrics:playstate', p),
  onLyricsPlayState: (cb) => ipcRenderer.on('lyrics:playstate', (_e, p) => cb(p)),
  // 关闭行为被弹窗「记住」改写时同步设置开关
  onTrayOnCloseState: (cb) => ipcRenderer.on('tray-on-close-state', (_e, v) => cb(v)),
  // —— 强制对齐 DLC ——
  dlcStatus: () => ipcRenderer.invoke('dlc:status'),
  dlcDownload: () => ipcRenderer.invoke('dlc:download'),
  dlcOpen: () => ipcRenderer.invoke('dlc:open'),
  dlcRemove: () => ipcRenderer.invoke('dlc:remove'),
  dlcCancel: () => ipcRenderer.invoke('dlc:cancel'),
  onDlcProgress: (cb) => ipcRenderer.on('dlc:progress', (_e, p) => cb(p)),
  // —— 内置强制对齐 GUI ——
  alignOpen: (theme) => ipcRenderer.invoke('align:open', theme),
  alignStatus: () => ipcRenderer.invoke('align:status'),
  alignPick: (kind, recursive) => ipcRenderer.invoke('align:pick', kind, recursive),
  alignRun: (opts) => ipcRenderer.invoke('align:run', opts),
  alignCancel: () => ipcRenderer.invoke('align:cancel'),
  alignSave: (mode) => ipcRenderer.invoke('align:save', mode),
  onAlignTheme: (cb) => ipcRenderer.on('align:theme', (_e, t) => cb(t)),
  onAlignEngine: (cb) => ipcRenderer.on('align:engine', (_e, s) => cb(s)),
  onAlignStart: (cb) => ipcRenderer.on('align:start', (_e, s) => cb(s)),
  onAlignProgress: (cb) => ipcRenderer.on('align:progress', (_e, s) => cb(s)),
  onAlignTick: (cb) => ipcRenderer.on('align:tick', (_e, s) => cb(s)),
  onAlignLog: (cb) => ipcRenderer.on('align:log', (_e, s) => cb(s)),
  onAlignFinish: (cb) => ipcRenderer.on('align:finish', (_e, s) => cb(s))
})