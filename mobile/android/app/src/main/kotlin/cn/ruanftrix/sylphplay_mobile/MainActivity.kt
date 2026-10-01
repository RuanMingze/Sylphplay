package cn.ruanftrix.sylphplay_mobile

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.media.audiofx.Visualizer
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Sylphplay 移动端原生侧：音频频谱通道
 *
 * - MethodChannel  sylph/visualizer        start / stop
 * - EventChannel   sylph/visualizer/bands  推 64 段归一化幅度（0~1）
 * - MethodChannel  sylph/thumb             视频抽帧缩略图
 * - MethodChannel  sylph/probe             按内容嗅探媒体类型（扩展名不可用时的兜底）
 *
 * 对应桌面版 WebAudio AnalyserNode.getByteFrequencyData。设备不支持或权限不足时
 * 本类静默失败，Dart 侧 [visualizer.dart] 会保持空频谱（绝不伪造波形）。
 * 本类继承 [AudioServiceActivity]（后台播放需要；它本身即 FlutterActivity 子类），
 * 因此清单里仍写 .MainActivity 即可。
 */
class MainActivity : AudioServiceActivity() {
    private val methodChannelName = "sylph/visualizer"
    private val eventChannelName = "sylph/visualizer/bands"
    private val thumbChannelName = "sylph/thumb"
    private val probeChannelName = "sylph/probe"

    private var visualizer: Visualizer? = null
    private var sink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        startVisualizer()
                        result.success(true)
                    }
                    "stop" -> {
                        stopVisualizer()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })

        // 视频抽帧缩略图（原生 MediaMetadataRetriever，替代停维护的 video_thumbnail）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, thumbChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "frame") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val atMs = (call.argument<Number>("atMs") ?: 0).toLong()
                if (path == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                // 抽帧是阻塞 IO，放到后台线程，完成后回主线程回传
                Thread {
                    val bytes = extractFrame(path, atMs)
                    runOnUiThread { result.success(bytes) }
                }.start()
            }

        // 按内容嗅探媒体类型：Android SAF 会把文件复制到缓存并丢掉扩展名
        // （实测 path/name 都只剩歌曲标题），此时只能靠平台解码器判定。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, probeChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "kind") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                Thread {
                    val kind = probeKind(path)
                    runOnUiThread { result.success(kind) }
                }.start()
            }
    }

    /**
     * 内容嗅探：返回 image / video / audio，无法判定返回 null。
     *
     * 先用 MediaMetadataRetriever 读容器元数据（音视频通吃，靠 HAS_VIDEO 区分）；
     * 它读不了（图片）再退回 BitmapFactory 只读头部解尺寸。
     */
    private fun probeKind(path: String): String? {
        var mmr: MediaMetadataRetriever? = null
        try {
            val r = MediaMetadataRetriever()
            mmr = r
            r.setDataSource(path)
            val hasVideo = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO)
            val hasAudio = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
            if (hasVideo == "yes") return "video"
            if (hasAudio == "yes") return "audio"
        } catch (_: Exception) {
            // 不是音视频容器，继续往下试图片
        } finally {
            try {
                mmr?.release()
            } catch (_: Exception) {
            }
        }
        try {
            val opts = BitmapFactory.Options()
            opts.inJustDecodeBounds = true
            BitmapFactory.decodeFile(path, opts)
            if (opts.outWidth > 0 && opts.outHeight > 0) return "image"
        } catch (_: Exception) {
        }
        return null
    }

    /** 抽帧并压成 JPEG；[atMs] <= 0 时按「前 25% 处」定位（对应桌面版 captureVideoThumb） */
    private fun extractFrame(path: String, atMs: Long): ByteArray? {
        var mmr: MediaMetadataRetriever? = null
        try {
            val r = MediaMetadataRetriever()
            mmr = r
            r.setDataSource(path)

            var tMs = atMs
            if (tMs <= 0) {
                val durMs = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L
                tMs = if (durMs > 0) {
                    var t = (durMs * 0.25).toLong()
                    if (t > durMs - 500) t = durMs / 2
                    t
                } else {
                    1000L
                }
            }

            val bmp = r.getFrameAtTime(tMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: r.getFrameAtTime(1000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return null

            val w = 240
            val h = (bmp.height.toFloat() * w / bmp.width).toInt().coerceAtLeast(1)
            val scaled = Bitmap.createScaledBitmap(bmp, w, h, true)
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 70, out)
            return out.toByteArray()
        } catch (e: Exception) {
            return null
        } finally {
            try {
                mmr?.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun startVisualizer() {
        if (visualizer != null) return
        try {
            @Suppress("DEPRECATION")
            val v = Visualizer(0) // session 0 = 全局输出混音
            v.captureSize = Visualizer.getCaptureSizeRange()[0] // 最小 128 字节，够 64 段
            v.setDataCaptureListener(
                object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(
                        visualizer: Visualizer?,
                        waveform: ByteArray?,
                        samplingRate: Int,
                    ) {
                        // 不做波形，仅用 FFT
                    }

                    override fun onFftDataCapture(
                        visualizer: Visualizer?,
                        fft: ByteArray?,
                        samplingRate: Int,
                    ) {
                        if (fft == null || fft.isEmpty()) return
                        emit(fft)
                    }
                },
                Visualizer.getMaxCaptureRate() / 2,
                false,
                true,
            )
            v.enabled = true
            visualizer = v
        } catch (e: Exception) {
            // 权限不足 / 设备不支持：静默失败
            visualizer = null
        }
    }

    private fun stopVisualizer() {
        try {
            visualizer?.enabled = false
            visualizer?.release()
        } catch (_: Exception) {
        }
        visualizer = null
    }

    /** 把 FFT 幅度（有符号字节，取无符号值）压成 64 段归一化幅度 */
    private fun emit(fft: ByteArray) {
        val bars = 64
        val out = ArrayList<Double>(bars)
        for (i in 0 until bars) {
            val idx = (i * fft.size) / bars
            val magnitude = (fft[idx].toInt() and 0xFF) / 255.0
            out.add(magnitude)
        }
        runOnUiThread { sink?.success(out) }
    }

    override fun onDestroy() {
        stopVisualizer()
        super.onDestroy()
    }
}