package expo.modules.mpv

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.view.View

/** Timed text is evaluated against mpv's native clock, including seeks and rate changes. */
internal class ExpoMpvPipOverlay(context: Context, private val position: () -> Double) : View(context) {
    private data class Cue(
        val start: Double, val end: Double, val text: String, val color: Int,
        val startX: Float, val endX: Float, val y: Float,
    )
    private var cues = emptyList<Cue>()
    private var maximumDuration = 0.0
    private var referenceWidth = 640f
    private var referenceHeight = 360f
    private var opacity = 1f
    private var fontSize = 24f
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.DEFAULT_BOLD }
    var playing = false
        set(value) { field = value; invalidate() }

    fun setOverlay(value: Map<String, Any?>?) {
        fun number(key: String, fallback: Double) = (value?.get(key) as? Number)?.toDouble()
            ?.takeIf { it.isFinite() } ?: fallback
        referenceWidth = number("width", 640.0).coerceIn(1.0, 10000.0).toFloat()
        referenceHeight = number("height", 360.0).coerceIn(1.0, 10000.0).toFloat()
        fontSize = number("fontSize", 24.0).coerceIn(1.0, 200.0).toFloat()
        opacity = number("opacity", 1.0).coerceIn(0.0, 1.0).toFloat()
        cues = (value?.get("cues") as? List<*>)?.mapNotNull { raw ->
            val cue = raw as? Map<*, *> ?: return@mapNotNull null
            fun finite(key: String) = (cue[key] as? Number)?.toDouble()?.takeIf { it.isFinite() }
            val start = finite("start") ?: return@mapNotNull null
            val end = finite("end") ?: return@mapNotNull null
            val text = cue["text"] as? String ?: return@mapNotNull null
            val startX = finite("startX") ?: return@mapNotNull null
            val endX = finite("endX") ?: return@mapNotNull null
            val y = finite("y") ?: return@mapNotNull null
            if (start < 0 || end <= start || text.isBlank()) return@mapNotNull null
            val color = try { Color.parseColor(cue["color"] as? String ?: "#ffffff") }
                catch (_: IllegalArgumentException) { Color.WHITE }
            Cue(start, end, text, color, startX.toFloat(), endX.toFloat(), y.toFloat())
        }?.sortedBy { it.start } ?: emptyList()
        maximumDuration = cues.maxOfOrNull { it.end - it.start } ?: 0.0
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (cues.isEmpty() || opacity <= 0) return
        val time = position()
        // Binary search skips expired history, so long episodes don't require
        // scanning every comment on each frame. Backward seeks work immediately.
        var low = 0
        var high = cues.size
        while (low < high) {
            val mid = (low + high) ushr 1
            if (cues[mid].start < time - maximumDuration) low = mid + 1 else high = mid
        }
        val scale = minOf(width / referenceWidth, height / referenceHeight)
        canvas.save()
        canvas.translate((width - referenceWidth * scale) / 2, (height - referenceHeight * scale) / 2)
        canvas.scale(scale, scale)
        canvas.clipRect(0f, 0f, referenceWidth, referenceHeight)
        paint.textSize = fontSize
        var count = 0
        for (index in low until cues.size) {
            val cue = cues[index]
            if (cue.start > time) break
            if (cue.end <= time) continue
            val progress = ((time - cue.start) / (cue.end - cue.start)).toFloat()
            val x = cue.startX + (cue.endX - cue.startX) * progress
            val baseline = cue.y - paint.fontMetrics.top
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 2f
            paint.color = Color.BLACK
            paint.alpha = (opacity * 255).toInt()
            canvas.drawText(cue.text, x, baseline, paint)
            paint.style = Paint.Style.FILL
            paint.color = cue.color
            paint.alpha = (opacity * Color.alpha(cue.color)).toInt()
            canvas.drawText(cue.text, x, baseline, paint)
            if (++count >= 100) break
        }
        canvas.restore()
        if (playing && isShown) postInvalidateOnAnimation()
    }
}
