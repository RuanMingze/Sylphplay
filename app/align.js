// 强制对齐窗口 — 界面逻辑移植自 DLC 里的 C# GUI，引擎仍用 DLC 的 align_engine.exe
const $ = (s) => document.querySelector(s)
const S = { audio: '', lrc: '', folder: '', running: false, batch: false, total: 0, okCount: 0 }

/* —— 窗口按钮 —— */
$('#wc-min').addEventListener('click', () => window.sylph.windowControl('minimize'))
$('#wc-close').addEventListener('click', () => window.sylph.windowControl('close'))

/* —— 主题 / 引擎状态 —— */
window.sylph.onAlignTheme((t) => document.documentElement.setAttribute('data-theme', t === 'light' ? 'light' : 'dark'))
window.sylph.onAlignEngine((s) => {
  if (!s || !s.ready) setStatus('未找到对齐引擎，请先在设置里下载 DLC')
})

function setStatus(t) { $('#status').textContent = t }
function setTick(t) { $('#tick').textContent = t || '' }
function setPath(el, p, empty) {
  el.textContent = p || empty
  el.classList.toggle('set', !!p)
  el.title = p || ''
}

/* —— 选择文件 / 文件夹 —— */
$('#pick-audio').addEventListener('click', async () => {
  const r = await window.sylph.alignPick('audio')
  if (!r.ok) return
  S.audio = r.path; S.folder = ''
  setPath($('#path-audio'), S.audio, '未选择音频')
  setPath($('#path-folder'), '', '未选择文件夹')
  setStatus('已选择音频')
})
$('#pick-lrc').addEventListener('click', async () => {
  const r = await window.sylph.alignPick('lrc')
  if (!r.ok) return
  S.lrc = r.path; S.folder = ''
  setPath($('#path-lrc'), S.lrc, '未选择歌词')
  setPath($('#path-folder'), '', '未选择文件夹')
  setStatus('已选择歌词')
})
$('#pick-folder').addEventListener('click', async () => {
  const r = await window.sylph.alignPick('folder', $('#opt-recursive').checked)
  if (!r.ok) return
  S.folder = r.dir; S.audio = ''; S.lrc = ''
  setPath($('#path-audio'), '', '未选择音频')
  setPath($('#path-lrc'), '', '未选择歌词')
  setPath($('#path-folder'), S.folder, '未选择文件夹')
  setStatus(`已选择文件夹：扫描到 ${r.count} 个音频，其中 ${r.paired} 个有同名歌词`)
})

/* —— 进度 —— */
function resetProgress(batch) {
  $('#bar-wrap').classList.toggle('indet', !batch)
  $('#bar-inner').style.width = batch ? '0%' : ''
}
window.sylph.onAlignStart((s) => {
  S.running = true; S.batch = !!s.batch; S.total = s.total || 1
  $('#run').disabled = true; $('#cancel').disabled = false; $('#save').disabled = true
  $('#result').textContent = '对齐进行中…'
  setTick('')
  resetProgress(S.batch)
})
window.sylph.onAlignProgress((p) => {
  if (!p) return
  if (p.status) setStatus(p.status)
  if (S.batch) {
    const pct = S.total > 0 ? Math.round((p.done || 0) * 100 / S.total) : 0
    $('#bar-inner').style.width = pct + '%'
  }
})
window.sylph.onAlignTick((t) => { if (t && t.file) setTick(t.file + ' · ' + t.line) })
window.sylph.onAlignLog((line) => {
  const el = $('#log')
  el.textContent += line.endsWith('\n') ? line : line + '\n'
  // tqdm 会不停刷进度，日志只保留最近一段，避免无限增长拖慢窗口
  if (el.textContent.length > 200000) el.textContent = el.textContent.slice(-100000)
  el.scrollTop = el.scrollHeight
})
window.sylph.onAlignFinish((s) => {
  S.running = false
  $('#run').disabled = false; $('#cancel').disabled = true
  $('#bar-wrap').classList.remove('indet')
  $('#bar-inner').style.width = '100%'
  setTick('')
  const sum = s.summary || {}
  S.okCount = sum.ok || 0
  $('#save').disabled = S.okCount === 0
  setStatus(s.status || '')
  renderResult(sum)
})

function renderResult(sum) {
  const lines = []
  if (!S.batch && sum.json) {
    // 单文件：保持与原 GUI 一致，回显引擎原始 JSON
    try { lines.push(JSON.stringify(JSON.parse(sum.json), null, 2)) } catch (e) { lines.push(sum.json) }
  } else {
    lines.push(`[结果] 共 ${sum.total || 0} 个任务 —— 成功 ${sum.ok || 0}，跳过 ${sum.skip || 0}，失败 ${sum.fail || 0}`)
    for (const it of (sum.items || [])) {
      const tag = it.status === 'ok' ? '[完成]' : (it.status === 'skip' ? '[跳过]' : '[失败]')
      lines.push(`${tag} ${it.name}${it.note ? ' —— ' + it.note : ''}`)
    }
    if ((sum.noLrc || []).length) {
      lines.push('')
      lines.push(`[跳过] 以下 ${sum.noLrc.length} 个音频没有同名 .lrc，未处理：`)
      for (const n of sum.noLrc) lines.push('    ' + n)
    }
  }
  $('#result').textContent = lines.join('\n')
}

/* —— 开始 / 取消 / 保存 —— */
$('#run').addEventListener('click', async () => {
  if (S.running) return
  if (!S.folder && (!S.audio || !S.lrc)) {
    setStatus(S.audio ? '必须选择原歌词文件（用于保留头部与逐字对齐）' : '请先选择音频，或选择一个文件夹')
    return
  }
  $('#log').textContent = ''
  await alignRun()
})

async function alignRun() {
  const r = await window.sylph.alignRun({
    audio: S.audio,
    lrc: S.lrc,
    folder: S.folder,
    recursive: $('#opt-recursive').checked,
    parallel: $('#opt-parallel').checked,
    debug: $('#opt-debug').checked,
    language: $('#opt-lang').value,
    format: $('#opt-format').value,
    strength: parseFloat($('#opt-strength').value) || 0.9
  })
  if (!r.ok) {
    $('#run').disabled = false; $('#cancel').disabled = true
    $('#bar-wrap').classList.remove('indet')
    setStatus(r.message || '对齐失败')
    $('#result').textContent = r.message || '对齐失败'
  }
}

$('#cancel').addEventListener('click', async () => {
  $('#cancel').disabled = true
  const r = await window.sylph.alignCancel()
  if (!r.ok) { $('#cancel').disabled = false; setStatus(r.message || '取消失败') }
  else setStatus('正在取消…')
})

// 调试日志区显隐
$('#opt-debug').addEventListener('change', () => {
  $('#log-card').classList.toggle('show', $('#opt-debug').checked)
})

// 匹配强度滑块实时回显
$('#opt-strength').addEventListener('input', () => {
  $('#strength-val').textContent = parseFloat($('#opt-strength').value).toFixed(2)
})

$('#save').addEventListener('click', async () => {
  // 单文件走「另存为」；批量先问保存去向
  if (!S.batch) return doSave('saveas')
  $('#save-dlg-text').textContent = `共 ${S.okCount} 个文件对齐完成，保存到哪里？`
  $('#save-dlg').showModal()
})
$('#sv-overwrite').addEventListener('click', () => { $('#save-dlg').close(); doSave('overwrite') })
$('#sv-folder').addEventListener('click', () => { $('#save-dlg').close(); doSave('folder') })
$('#sv-cancel').addEventListener('click', () => $('#save-dlg').close())

async function doSave(mode) {
  const r = await window.sylph.alignSave(mode)
  if (r.cancelled) return
  setStatus(r.ok ? r.message : (r.message || '保存失败'))
}

// 恢复上次选择（引擎状态与主题由主进程推送）
;(async () => {
  try {
    const st = await window.sylph.alignStatus()
    if (st && !st.ready) setStatus('未找到对齐引擎，请先在设置里下载 DLC')
  } catch (e) {}
})()