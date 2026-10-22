package com.hermesagent.hermes_android

import android.annotation.TargetApi
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/**
 * AudioTrack sink for Hermes Agent's `/api/audio/speak-stream` protocol.
 *
 * Configure, write and finish share one ordered worker. Pause/Resume use a
 * separate control worker and only perform short operations under trackLock,
 * so they can pre-empt a blocked write or drain without racing release.
 * Non-blocking bounded writes preserve backpressure. Every call carries a
 * Dart-side generation; stale calls become no-ops and can never reach the
 * AudioTrack of a newer reply.
 */
internal class HermesPcmStreamHandler(context: Context) :
    MethodChannel.MethodCallHandler,
    AutoCloseable {

    private data class AudioFocusLease(
        // Kept as Any: app minSdk is 29, so AudioFocusRequest always resolves,
        // but the field stays loosely typed to avoid forcing eager class load.
        val modernRequest: Any?,
        val listener: AudioManager.OnAudioFocusChangeListener,
        val lastChange: AtomicInteger,
    )

    private data class FocusFailure(
        val generation: Long,
        val mayHavePlayed: Boolean,
        val reason: String,
    )

    private data class ActiveStream(
        val generation: Long,
        val sampleRate: Int,
        val channels: Int,
        val track: AudioTrack,
        val focusLease: AudioFocusLease,
        val trackLock: Any = Any(),
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        val released: AtomicBoolean = AtomicBoolean(false),
        val framesWritten: AtomicLong = AtomicLong(0),
        val focusPaused: AtomicBoolean = AtomicBoolean(false),
        val focusLost: AtomicBoolean = AtomicBoolean(false),
        val focusPauseDeadlineNanos: AtomicLong = AtomicLong(0),
        var trackPausedForFocus: Boolean = false,
        val userPaused: AtomicBoolean = AtomicBoolean(false),
        var trackPausedForUser: Boolean = false,
    )

    private val appContext = context.applicationContext
    private val audioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val writer = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "hermes-pcm-writer").apply { isDaemon = true }
    }
    private val control = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "hermes-pcm-control").apply { isDaemon = true }
    }
    private val stateLock = Any()
    private val stoppedThrough = AtomicLong(0)

    @Volatile
    private var active: ActiveStream? = null

    @Volatile
    private var lastFocusFailure: FocusFailure? = null

    @Volatile
    private var closed = false

    internal fun hasPrivateOutput(): Boolean {
        val stream = synchronized(stateLock) { active } ?: return false
        if (!isCurrent(stream)) return false
        val route = try {
            synchronized(stream.trackLock) {
                stream.track.routedDevice
            }
        } catch (_: Throwable) {
            null
        } ?: return false
        return when (route.type) {
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            -> true
            else -> false
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val generation = (call.argument<Number>("generation"))?.toLong()
        if (generation == null || generation <= 0) {
            result.error("invalid_generation", "Missing PCM generation", null)
            return
        }
        if (closed) {
            result.success(null)
            return
        }

        when (call.method) {
            "configure" -> {
                val sampleRate = (call.argument<Number>("sample_rate"))?.toInt()
                val channels = (call.argument<Number>("channels"))?.toInt()
                if (sampleRate == null || sampleRate !in MIN_SAMPLE_RATE..MAX_SAMPLE_RATE) {
                    result.error("invalid_sample_rate", "Unsupported PCM sample rate", null)
                    return
                }
                if (channels != 1) {
                    result.error("invalid_channels", "Only mono PCM is supported", null)
                    return
                }
                writer.execute {
                    configure(generation, sampleRate, channels, result)
                }
            }

            "write" -> {
                val pcm = call.argument<ByteArray>("pcm")
                if (pcm == null || pcm.isEmpty() || pcm.size % 2 != 0 || pcm.size > MAX_CHUNK_BYTES) {
                    result.error("invalid_pcm", "PCM chunk is empty, unaligned, or too large", null)
                    return
                }
                writer.execute { write(generation, pcm, result) }
            }

            "pause" -> pause(generation, result)

            "resume" -> resume(generation, result)

            "finish" -> writer.execute { finish(generation, result) }

            "stop" -> stop(generation, result)

            else -> result.notImplemented()
        }
    }

    private fun configure(
        generation: Long,
        sampleRate: Int,
        channels: Int,
        result: MethodChannel.Result,
    ) {
        if (generation <= stoppedThrough.get() || closed) {
            result.success(null)
            return
        }
        try {
            val previous = synchronized(stateLock) {
                val old = active
                active = null
                old
            }
            previous?.let { release(it, flush = true) }

            val channelMask = AudioFormat.CHANNEL_OUT_MONO
            val minBuffer = AudioTrack.getMinBufferSize(
                sampleRate,
                channelMask,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuffer <= 0) {
                throw IllegalStateException("AudioTrack rejected the PCM format")
            }
            // Keep roughly 250 ms available while respecting the device's
            // minimum. This is large enough for network jitter without hiding
            // seconds of obsolete audio after stop.
            val targetBuffer = sampleRate * channels * BYTES_PER_SAMPLE / 4
            val bufferBytes = max(minBuffer * 2, targetBuffer)
            // App minSdk is 29 (> O), so USAGE_ASSISTANT is always available; the
            // SDK check and USAGE_MEDIA fallback are kept only as defense in depth.
            val usage = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                AudioAttributes.USAGE_ASSISTANT
            } else {
                AudioAttributes.USAGE_MEDIA
            }
            val attributes = AudioAttributes.Builder()
                .setUsage(usage)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            var track: AudioTrack? = null
            var focusLease: AudioFocusLease? = null
            try {
                track = AudioTrack.Builder()
                    .setAudioAttributes(attributes)
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(sampleRate)
                            .setChannelMask(channelMask)
                            .build(),
                    )
                    .setBufferSizeInBytes(bufferBytes)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                if (track.state != AudioTrack.STATE_INITIALIZED) {
                    throw IllegalStateException("AudioTrack did not initialize")
                }
                focusLease = requestAudioFocus(attributes, generation)
                track.play()
            } catch (error: Throwable) {
                try {
                    track?.release()
                } catch (_: Throwable) {
                }
                focusLease?.let(::abandonAudioFocus)
                throw error
            }
            val stream = ActiveStream(
                generation = generation,
                sampleRate = sampleRate,
                channels = channels,
                track = checkNotNull(track),
                focusLease = checkNotNull(focusLease),
            )
            val accepted = synchronized(stateLock) {
                if (generation <= stoppedThrough.get() || closed) {
                    false
                } else {
                    active = stream
                    true
                }
            }
            if (!accepted) {
                release(stream, flush = true)
            } else {
                applyPendingAudioFocusChange(stream)
            }
            result.success(null)
        } catch (error: Throwable) {
            result.error("pcm_configure_failed", safeMessage(error), null)
        }
    }

    private fun write(
        generation: Long,
        pcm: ByteArray,
        result: MethodChannel.Result,
    ) {
        val stream = activeFor(generation)
        if (stream == null) {
            val focusFailure = focusFailureFor(generation)
            if (focusFailure != null) {
                result.error(
                    "pcm_focus_lost",
                    focusFailure.reason,
                    writeDetails(0, focusFailure.mayHavePlayed),
                )
            } else {
                result.success(writeCancelledDetails())
            }
            return
        }
        var offset = 0
        try {
            while (offset < pcm.size) {
                if (stream.focusLost.get()) {
                    reportFocusWriteFailure(stream, offset, result)
                    return
                }
                if (!isCurrent(stream)) {
                    val focusFailure = focusFailureFor(generation)
                    if (focusFailure != null) {
                        result.error(
                            "pcm_focus_lost",
                            focusFailure.reason,
                            writeDetails(
                                offset,
                                focusFailure.mayHavePlayed || stream.framesWritten.get() > 0,
                            ),
                        )
                    } else {
                        result.success(writeCancelledDetails())
                    }
                    return
                }
                if (waitForUserResume(stream) == null) {
                    val focusFailure = focusFailureFor(generation)
                    if (focusFailure != null || stream.focusLost.get()) {
                        reportFocusWriteFailure(stream, offset, result)
                    } else {
                        result.success(writeCancelledDetails())
                    }
                    return
                }
                if (waitForUsableAudioFocus(stream) == null) {
                    val focusFailure = focusFailureFor(generation)
                    if (focusFailure != null) {
                        result.error(
                            "pcm_focus_lost",
                            focusFailure.reason,
                            writeDetails(
                                offset,
                                focusFailure.mayHavePlayed || stream.framesWritten.get() > 0,
                            ),
                        )
                    } else {
                        result.success(writeCancelledDetails())
                    }
                    return
                }
                val requested = min(MAX_NATIVE_WRITE_BYTES, pcm.size - offset)
                val written = synchronized(stream.trackLock) {
                    if (stream.userPaused.get() || !isCurrent(stream)) {
                        null
                    } else {
                        stream.track.write(
                            pcm,
                            offset,
                            requested,
                            AudioTrack.WRITE_NON_BLOCKING,
                        )
                    }
                }
                if (written == null) continue
                if (written < 0 || written % BYTES_PER_SAMPLE != 0) {
                    throw IllegalStateException("AudioTrack write failed ($written)")
                }
                if (written == 0) {
                    Thread.sleep(WRITE_RETRY_MS)
                    continue
                }
                offset += written
                stream.framesWritten.addAndGet(
                    (written / BYTES_PER_SAMPLE).toLong(),
                )
            }
            result.success(
                writeDetails(
                    acceptedBytes = offset,
                    mayHavePlayed = stream.framesWritten.get() > 0,
                ),
            )
        } catch (error: Throwable) {
            val focusFailure = focusFailureFor(generation)
            if (focusFailure != null || stream.focusLost.get()) {
                if (focusFailure == null) {
                    markFocusLost(stream, "Audio focus lost")
                }
                reportFocusWriteFailure(stream, offset, result)
            } else if (!isCurrent(stream)) {
                result.success(writeCancelledDetails())
            } else {
                release(stream, flush = true)
                invalidate(stream)
                result.error(
                    "pcm_write_failed",
                    safeMessage(error),
                    writeDetails(
                        acceptedBytes = offset,
                        mayHavePlayed = stream.framesWritten.get() > 0,
                    ),
                )
            }
        }
    }

    /**
     * Signals outside [writer], which may be draining the final tail. The
     * short AudioTrack operation runs under [ActiveStream.trackLock] on the
     * control executor, so Pause remains pre-emptive without flush/rebuild.
     */
    private fun pause(generation: Long, result: MethodChannel.Result) {
        val stream = activeFor(generation)
        if (stream == null) {
            result.success(null)
            return
        }
        Log.i(TAG, "pcm pause gen=$generation")
        stream.userPaused.set(true)
        control.execute {
            try {
                synchronized(stream.trackLock) {
                    if (isCurrent(stream) &&
                        stream.userPaused.get() &&
                        !stream.trackPausedForUser
                    ) {
                        if (!stream.trackPausedForFocus) {
                            stream.track.pause()
                        }
                        stream.trackPausedForUser = true
                    }
                }
                result.success(null)
            } catch (error: Throwable) {
                if (!isCurrent(stream)) {
                    result.success(null)
                } else {
                    release(stream, flush = true)
                    invalidate(stream)
                    result.error("pcm_pause_failed", safeMessage(error), null)
                }
            }
        }
    }

    /**
     * Keeps the writer attached to the same stream while Pause is active.
     * Returning the elapsed wait lets finish() exclude user-controlled pause
     * time from its drain deadline. Stop/close and focus loss always unblock.
     *
     * A user pause that never resumes (app to background, pause/stop race)
     * must not pin the AudioTrack: after [USER_PAUSE_MAX_MS] the stream is
     * released and invalidated, so finish/drain settle instead of leaking an
     * open AudioTrack. The writer then reports the write as cancelled.
     */
    private fun waitForUserResume(stream: ActiveStream): Long? {
        if (stream.focusLost.get()) return null
        if (!stream.userPaused.get()) {
            return if (isCurrent(stream)) 0L else null
        }

        val waitStarted = System.nanoTime()
        val deadline = waitStarted + USER_PAUSE_MAX_MS * 1_000_000L
        while (
            stream.userPaused.get() &&
            !stream.focusLost.get() &&
            isCurrent(stream)
        ) {
            if (System.nanoTime() >= deadline) {
                Log.w(
                    TAG,
                    "pcm user pause timeout gen=${stream.generation}: " +
                        "releasing AudioTrack after ${USER_PAUSE_MAX_MS}ms",
                )
                release(stream, flush = true)
                invalidate(stream)
                return null
            }
            Thread.sleep(USER_PAUSE_POLL_MS)
        }
        if (stream.focusLost.get() || !isCurrent(stream)) return null
        resumeTrackIfAllowed(stream)
        return System.nanoTime() - waitStarted
    }

    /** Resumes only when audio focus also permits playback; no flush/rebuild. */
    private fun resume(generation: Long, result: MethodChannel.Result) {
        val stream = activeFor(generation)
        if (stream == null) {
            result.success(null)
            return
        }
        // Wake a writer blocked in waitForUserResume before queuing the short
        // AudioTrack transition; the helper below is idempotent and lock-safe.
        Log.i(TAG, "pcm resume gen=$generation")
        stream.userPaused.set(false)
        control.execute {
            try {
                resumeTrackIfAllowed(stream)
                result.success(null)
            } catch (error: Throwable) {
                if (!isCurrent(stream)) {
                    result.success(null)
                } else {
                    release(stream, flush = true)
                    invalidate(stream)
                    result.error("pcm_resume_failed", safeMessage(error), null)
                }
            }
        }
    }

    private fun finish(generation: Long, result: MethodChannel.Result) {
        val stream = activeFor(generation)
        if (stream == null) {
            val focusFailure = focusFailureFor(generation)
            if (focusFailure != null) {
                result.error(
                    "pcm_focus_lost",
                    focusFailure.reason,
                    writeDetails(0, focusFailure.mayHavePlayed),
                )
            } else {
                result.success(null)
            }
            return
        }
        try {
            if (waitForUserResume(stream) == null) {
                val focusFailure = focusFailureFor(generation)
                if (focusFailure != null || stream.focusLost.get()) {
                    reportFocusFinishFailure(stream, result)
                } else {
                    result.success(null)
                }
                return
            }
            if (waitForUsableAudioFocus(stream) == null) {
                reportFocusFinishFailure(stream, result)
                return
            }
            val played = unsignedPlaybackHead(stream)
            val framesWritten = stream.framesWritten.get()
            val remaining = max(0L, framesWritten - played)
            val expectedMs = remaining * 1000L / stream.sampleRate
            val timeoutMs = min(MAX_DRAIN_MS, expectedMs + DRAIN_GRACE_MS)
            var deadline = System.nanoTime() + timeoutMs * 1_000_000L
            // El tiempo de Pause del usuario se excluye del drain, pero con
            // techo: pausas reiteradas no pueden aplazar la liberación del
            // AudioTrack más allá de MAX_DRAIN_PAUSE_EXTENSION_MS acumulados.
            var pauseExtensionNanos = 0L
            while (isCurrent(stream) &&
                unsignedPlaybackHead(stream) < stream.framesWritten.get()
            ) {
                val userWaitNanos = waitForUserResume(stream)
                if (userWaitNanos == null) {
                    val focusFailure = focusFailureFor(generation)
                    if (focusFailure != null || stream.focusLost.get()) {
                        reportFocusFinishFailure(stream, result)
                    } else {
                        result.success(null)
                    }
                    return
                }
                val extensionBudget =
                    MAX_DRAIN_PAUSE_EXTENSION_MS * 1_000_000L - pauseExtensionNanos
                deadline += min(userWaitNanos, max(0L, extensionBudget))
                pauseExtensionNanos += userWaitNanos
                val focusWaitNanos = waitForUsableAudioFocus(stream)
                if (focusWaitNanos == null) {
                    reportFocusFinishFailure(stream, result)
                    return
                }
                deadline += focusWaitNanos
                if (System.nanoTime() >= deadline &&
                    !stream.userPaused.get()
                ) {
                    break
                }
                Thread.sleep(DRAIN_POLL_MS)
            }
            if (!isCurrent(stream)) {
                val focusFailure = focusFailureFor(generation)
                if (focusFailure != null) {
                    result.error(
                        "pcm_focus_lost",
                        focusFailure.reason,
                        writeDetails(0, focusFailure.mayHavePlayed),
                    )
                } else {
                    // stop() already queued the ordered flush/release.
                    result.success(null)
                }
                return
            }
            // Some Android audio drivers (and the API 36 emulator) can stop
            // advancing playbackHeadPosition after the final non-blocking
            // write even though the queued audio has already been consumed.
            // The deadline is the authoritative upper bound: once it expires,
            // release cleanly instead of converting a completed reply into a
            // post-PCM protocol failure. Stop/cancel still pre-empts this loop
            // through isCurrent(stream).
            release(stream, flush = false)
            invalidate(stream)
            result.success(null)
        } catch (error: Throwable) {
            val focusFailure = focusFailureFor(generation)
            if (focusFailure != null || stream.focusLost.get()) {
                if (focusFailure == null) {
                    markFocusLost(stream, "Audio focus lost")
                }
                reportFocusFinishFailure(stream, result)
            } else if (!isCurrent(stream)) {
                result.success(null)
            } else {
                release(stream, flush = true)
                invalidate(stream)
                result.error("pcm_finish_failed", safeMessage(error), null)
            }
        }
    }

    private fun stop(generation: Long, result: MethodChannel.Result) {
        markStoppedThrough(generation)
        var queued = false
        synchronized(stateLock) {
            val current = active
            if (current != null && current.generation <= generation) {
                active = null
                current.cancelled.set(true)
                writer.execute {
                    release(current, flush = true)
                    result.success(null)
                }
                queued = true
            }
        }
        if (!queued) result.success(null)
    }

    private fun markStoppedThrough(generation: Long) {
        while (true) {
            val previous = stoppedThrough.get()
            if (generation <= previous) return
            if (stoppedThrough.compareAndSet(previous, generation)) return
        }
    }

    private fun activeFor(generation: Long): ActiveStream? {
        if (generation <= stoppedThrough.get() || closed) return null
        return synchronized(stateLock) {
            active?.takeIf {
                it.generation == generation &&
                    !it.cancelled.get() &&
                    !it.released.get()
            }
        }
    }

    private fun isCurrent(stream: ActiveStream): Boolean =
        !closed &&
            !stream.cancelled.get() &&
            !stream.released.get() &&
            stream.generation > stoppedThrough.get() &&
            synchronized(stateLock) { active === stream }

    private fun invalidate(stream: ActiveStream) {
        synchronized(stateLock) {
            if (active === stream) active = null
        }
    }

    private fun release(stream: ActiveStream, flush: Boolean) {
        stream.cancelled.set(true)
        if (!stream.released.compareAndSet(false, true)) return
        synchronized(stream.trackLock) {
            try {
                if (flush) {
                    stream.track.pause()
                    stream.track.flush()
                }
            } catch (_: Throwable) {
                // Release below is the authoritative cleanup.
            }
            try {
                stream.track.stop()
            } catch (_: Throwable) {
            }
            try {
                stream.track.release()
            } catch (_: Throwable) {
            }
        }
        abandonAudioFocus(stream.focusLease)
    }

    private fun applyPendingAudioFocusChange(stream: ActiveStream) {
        val change = stream.focusLease.lastChange.get()
        if (change != AudioManager.AUDIOFOCUS_GAIN) {
            onAudioFocusChange(stream.generation, change)
        }
    }

    private fun onAudioFocusChange(generation: Long, change: Int) {
        val stream = synchronized(stateLock) {
            active?.takeIf {
                it.generation == generation &&
                    !it.cancelled.get() &&
                    !it.released.get()
            }
        } ?: return

        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                stream.focusPaused.set(false)
                stream.focusPauseDeadlineNanos.set(0)
                writer.execute { waitForUsableAudioFocus(stream) }
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
            -> {
                if (stream.focusLost.get()) return
                stream.focusPauseDeadlineNanos.set(
                    System.nanoTime() + FOCUS_TRANSIENT_TIMEOUT_MS * 1_000_000L,
                )
                stream.focusPaused.set(true)
                writer.execute { waitForUsableAudioFocus(stream) }
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                markFocusLost(stream, "Audio focus lost")
                writer.execute { releaseAfterFocusLoss(stream) }
            }
        }
    }

    /**
     * Runs only on [writer]. A transient focus loss pauses the same generation
     * and therefore backpressures its pending MethodChannel write. Gain resumes
     * it; a bounded timeout becomes a permanent per-generation failure.
     *
     * @return nanoseconds spent waiting, or null when the generation is no
     * longer writable.
     */
    private fun waitForUsableAudioFocus(stream: ActiveStream): Long? {
        if (stream.focusLost.get()) {
            releaseAfterFocusLoss(stream)
            return null
        }
        if (!stream.focusPaused.get()) {
            try {
                resumeTrackIfAllowed(stream)
            } catch (_: Throwable) {
                markFocusLost(stream, "Audio focus resume failed")
                releaseAfterFocusLoss(stream)
                return null
            }
            return if (isCurrent(stream)) 0L else null
        }

        val waitStarted = System.nanoTime()
        try {
            synchronized(stream.trackLock) {
                if (!isCurrent(stream)) return null
                if (!stream.trackPausedForFocus) {
                    if (!stream.trackPausedForUser) {
                        stream.track.pause()
                    }
                    stream.trackPausedForFocus = true
                }
            }
            while (
                stream.focusPaused.get() &&
                !stream.focusLost.get() &&
                isCurrent(stream)
            ) {
                val deadline = stream.focusPauseDeadlineNanos.get()
                if (deadline <= 0 || System.nanoTime() >= deadline) {
                    markFocusLost(stream, "Transient audio focus timed out")
                    break
                }
                Thread.sleep(FOCUS_POLL_MS)
            }
            if (stream.focusLost.get()) {
                releaseAfterFocusLoss(stream)
                return null
            }
            if (!isCurrent(stream)) return null
            resumeTrackIfAllowed(stream)
            return System.nanoTime() - waitStarted
        } catch (_: Throwable) {
            markFocusLost(stream, "Audio focus transition failed")
            releaseAfterFocusLoss(stream)
            return null
        }
    }

    private fun resumeTrackIfAllowed(stream: ActiveStream) {
        synchronized(stream.trackLock) {
            if (!isCurrent(stream) ||
                stream.userPaused.get() ||
                stream.focusPaused.get() ||
                stream.focusLost.get()
            ) {
                return
            }
            if (stream.trackPausedForFocus || stream.trackPausedForUser) {
                stream.track.play()
                stream.trackPausedForFocus = false
                stream.trackPausedForUser = false
            }
        }
    }

    private fun markFocusLost(stream: ActiveStream, reason: String) {
        stream.focusPaused.set(false)
        stream.focusPauseDeadlineNanos.set(0)
        if (stream.focusLost.compareAndSet(false, true)) {
            ensureFocusFailure(stream, reason)
        }
    }

    private fun releaseAfterFocusLoss(stream: ActiveStream) {
        if (!stream.focusLost.get()) return
        release(stream, flush = true)
        invalidate(stream)
    }

    private fun focusFailureFor(generation: Long): FocusFailure? =
        lastFocusFailure?.takeIf { it.generation == generation }

    private fun ensureFocusFailure(
        stream: ActiveStream,
        reason: String,
    ): FocusFailure = synchronized(stateLock) {
        focusFailureFor(stream.generation)
            ?: FocusFailure(
                generation = stream.generation,
                mayHavePlayed = stream.framesWritten.get() > 0,
                reason = reason,
            ).also { lastFocusFailure = it }
    }

    private fun reportFocusWriteFailure(
        stream: ActiveStream,
        acceptedBytes: Int,
        result: MethodChannel.Result,
    ) {
        if (!stream.focusLost.get()) {
            markFocusLost(stream, "Audio focus lost")
        }
        val failure = ensureFocusFailure(stream, "Audio focus lost")
        val mayHavePlayed =
            failure.mayHavePlayed ||
                stream.framesWritten.get() > 0 ||
                acceptedBytes > 0
        releaseAfterFocusLoss(stream)
        result.error(
            "pcm_focus_lost",
            failure.reason,
            writeDetails(acceptedBytes, mayHavePlayed),
        )
    }

    private fun reportFocusFinishFailure(
        stream: ActiveStream,
        result: MethodChannel.Result,
    ) {
        if (!stream.focusLost.get()) {
            markFocusLost(stream, "Audio focus lost")
        }
        val failure = ensureFocusFailure(stream, "Audio focus lost")
        val mayHavePlayed =
            failure.mayHavePlayed || stream.framesWritten.get() > 0
        releaseAfterFocusLoss(stream)
        result.error(
            "pcm_focus_lost",
            failure.reason,
            writeDetails(0, mayHavePlayed),
        )
    }

    private fun writeDetails(
        acceptedBytes: Int,
        mayHavePlayed: Boolean,
    ): Map<String, Any> = mapOf(
        "acceptedBytes" to acceptedBytes,
        "mayHavePlayed" to mayHavePlayed,
    )

    private fun writeCancelledDetails(): Map<String, Any> = mapOf(
        "acceptedBytes" to 0,
        "mayHavePlayed" to false,
        "cancelled" to true,
    )

    private fun requestAudioFocus(
        attributes: AudioAttributes,
        generation: Long,
    ): AudioFocusLease {
        val lastChange = AtomicInteger(AudioManager.AUDIOFOCUS_GAIN)
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            lastChange.set(change)
            onAudioFocusChange(generation, change)
        }
        val modernRequest: Any?
        val requestResult: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = buildModernAudioFocusRequest(attributes, listener)
            modernRequest = request
            requestResult = requestModernAudioFocus(request)
        } else {
            modernRequest = null
            requestResult = requestLegacyAudioFocus(listener)
        }
        if (requestResult != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            throw IllegalStateException("Audio focus request was not granted")
        }
        return AudioFocusLease(
            modernRequest = modernRequest,
            listener = listener,
            lastChange = lastChange,
        )
    }

    @Suppress("DEPRECATION")
    private fun requestLegacyAudioFocus(
        listener: AudioManager.OnAudioFocusChangeListener,
    ): Int = audioManager.requestAudioFocus(
        listener,
        AudioManager.STREAM_MUSIC,
        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
    )

    @TargetApi(Build.VERSION_CODES.O)
    private fun buildModernAudioFocusRequest(
        attributes: AudioAttributes,
        listener: AudioManager.OnAudioFocusChangeListener,
    ): Any = AudioFocusRequest.Builder(
        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
    )
        .setAudioAttributes(attributes)
        .setOnAudioFocusChangeListener(listener, Handler(Looper.getMainLooper()))
        .build()

    @TargetApi(Build.VERSION_CODES.O)
    private fun requestModernAudioFocus(request: Any): Int =
        audioManager.requestAudioFocus(request as AudioFocusRequest)

    private fun abandonAudioFocus(lease: AudioFocusLease) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                lease.modernRequest != null
            ) {
                abandonModernAudioFocus(lease.modernRequest)
            } else {
                abandonLegacyAudioFocus(lease.listener)
            }
        } catch (_: Throwable) {
        }
    }

    @Suppress("DEPRECATION")
    private fun abandonLegacyAudioFocus(
        listener: AudioManager.OnAudioFocusChangeListener,
    ) {
        audioManager.abandonAudioFocus(listener)
    }

    @TargetApi(Build.VERSION_CODES.O)
    private fun abandonModernAudioFocus(request: Any) {
        audioManager.abandonAudioFocusRequest(request as AudioFocusRequest)
    }

    private fun unsignedPlaybackHead(stream: ActiveStream): Long =
        synchronized(stream.trackLock) {
            stream.track.playbackHeadPosition.toLong() and 0xffffffffL
        }

    private fun safeMessage(error: Throwable): String =
        error::class.java.simpleName.ifEmpty { "PCM playback failed" }

    override fun close() {
        if (closed) return
        synchronized(stateLock) {
            if (closed) return
            closed = true
            val current = active
            active = null
            current?.cancelled?.set(true)
            if (current != null) {
                writer.execute { release(current, flush = true) }
            }
            // Holding stateLock orders shutdown after a concurrent stop() has
            // queued its release callback.
            writer.shutdown()
            control.shutdown()
        }
    }

    private companion object {
        const val TAG = "HermesVoiceStab"
        const val MIN_SAMPLE_RATE = 8000
        const val MAX_SAMPLE_RATE = 96000
        const val BYTES_PER_SAMPLE = 2
        const val MAX_CHUNK_BYTES = 1024 * 1024
        const val MAX_NATIVE_WRITE_BYTES = 16 * 1024
        const val WRITE_RETRY_MS = 2L
        const val USER_PAUSE_POLL_MS = 10L
        const val USER_PAUSE_MAX_MS = 45_000L
        const val FOCUS_POLL_MS = 10L
        const val FOCUS_TRANSIENT_TIMEOUT_MS = 30_000L
        const val DRAIN_POLL_MS = 10L
        const val DRAIN_GRACE_MS = 2000L
        const val MAX_DRAIN_MS = 180_000L
        const val MAX_DRAIN_PAUSE_EXTENSION_MS = 60_000L
    }
}
