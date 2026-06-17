package br.com.redesurftank.ecotrip.managers

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * Player de mídia para a tela Controles (página Veículo). Lê a sessão de mídia
 * ativa (MediaSession padrão do Android — funciona com qualquer app) e expõe o
 * estado + controles de transporte. Avisa por [onChanged] a cada mudança, pra
 * empurrar window.applyMedia(...) no WebView. Volume via AudioManager (STREAM_MUSIC).
 *
 * Requer permissão "Acesso a notificações" (concedida 1x) + o
 * MediaNotificationListenerService registrado no Manifest.
 */
class MediaPlaybackState {
    var title: String? = null
    var artist: String? = null
    var album: String? = null
    var artwork: Bitmap? = null
    var isPlaying: Boolean = false
    var durationMs: Long = 0L
    var elapsedMs: Long = 0L
    var canSeek: Boolean = false
    var packageName: String? = null
}

class MediaControllerHelper(private val context: Context) {
    val state = MediaPlaybackState()
    var onChanged: (() -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private var manager: MediaSessionManager? = null
    private var sessionsListener: MediaSessionManager.OnActiveSessionsChangedListener? = null
    private val callbacks = HashMap<MediaController, MediaController.Callback>()
    private val lock = Any()
    private val vol = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    fun start() {
        if (manager != null) return   // já iniciado com sucesso
        val mgr = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager ?: return
        val comp = defaultListenerComponent(context)
        val granted = isNotificationAccessGranted(context, comp)
        Log.w("EcotripMedia", "start: granted=$granted comp=${comp.flattenToShortString()}")
        if (!granted) return   // sem permissão — re-tenta no próximo start()
        val l = MediaSessionManager.OnActiveSessionsChangedListener { updateControllers(it.orEmpty()) }
        try {
            val active = mgr.getActiveSessions(comp)
            Log.w("EcotripMedia", "start: getActiveSessions=${active.size} -> ${active.joinToString { it.packageName }}")
            updateControllers(active)
            mgr.addOnActiveSessionsChangedListener(l, comp)
            manager = mgr; sessionsListener = l   // só marca iniciado se deu certo
            Log.w("EcotripMedia", "start: listener registrado OK")
        } catch (e: SecurityException) {
            Log.w("EcotripMedia", "start: SecurityException (listener ainda não vinculado pelo sistema) ${e.message}")
        }
    }

    fun stop() {
        synchronized(lock) {
            callbacks.forEach { (c, cb) -> runCatching { c.unregisterCallback(cb) } }
            callbacks.clear()
        }
        sessionsListener?.let { manager?.removeOnActiveSessionsChangedListener(it) }
        sessionsListener = null
        manager = null
    }

    private fun updateControllers(controllers: List<MediaController>) {
        synchronized(lock) {
            callbacks.forEach { (c, cb) -> runCatching { c.unregisterCallback(cb) } }
            callbacks.clear()
            controllers.forEach { c ->
                val cb = object : MediaController.Callback() {
                    override fun onMetadataChanged(metadata: MediaMetadata?) = publishBest()
                    override fun onPlaybackStateChanged(s: PlaybackState?) = publishBest()
                    override fun onSessionDestroyed() = publishBest()
                }
                runCatching { c.registerCallback(cb); callbacks[c] = cb }
            }
        }
        publishBest()
    }

    private fun publishBest() {
        val controllers = synchronized(lock) { callbacks.keys.toList() }
        val selected = controllers
            .filterNot { it.packageName == "com.android.server.telecom" }
            .sortedWith(
                compareByDescending<MediaController> { it.playbackState?.state == PlaybackState.STATE_PLAYING }
                    .thenByDescending { hasUsableMetadata(it.metadata) }
            )
            .firstOrNull { hasUsableMetadata(it.metadata) || it.playbackState != null }

        main.post {
            Log.w("EcotripMedia", "publishBest: controllers=${controllers.size} selected=${selected?.packageName ?: "null"}")
            if (selected == null) { clear(); onChanged?.invoke(); return@post }
            val m = selected.metadata
            val ps = selected.playbackState
            state.title = m?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: m?.description?.title?.toString()
            state.artist = m?.getString(MediaMetadata.METADATA_KEY_ARTIST)
                ?: m?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
                ?: m?.description?.subtitle?.toString()
            state.album = m?.getString(MediaMetadata.METADATA_KEY_ALBUM)
            state.artwork = resolveArtwork(m)
            state.isPlaying = ps?.state == PlaybackState.STATE_PLAYING
            state.durationMs = (m?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L).coerceAtLeast(0L)
            state.elapsedMs = (ps?.position ?: 0L).coerceAtLeast(0L)
            state.canSeek = state.durationMs > 0 && ((ps?.actions ?: 0L) and PlaybackState.ACTION_SEEK_TO) != 0L
            state.packageName = selected.packageName
            onChanged?.invoke()
        }
    }

    private fun clear() {
        state.title = null; state.artist = null; state.album = null; state.artwork = null
        state.isPlaying = false; state.durationMs = 0L; state.elapsedMs = 0L
        state.canSeek = false; state.packageName = null
    }

    // ── transporte ──
    fun playPause() {
        val playing = state.isPlaying
        pick(if (playing) PlaybackState.ACTION_PAUSE else PlaybackState.ACTION_PLAY)?.let { c ->
            runCatching { if (playing) c.transportControls.pause() else c.transportControls.play() }
        }
    }
    fun next() { pick(PlaybackState.ACTION_SKIP_TO_NEXT)?.let { runCatching { it.transportControls.skipToNext() } } }
    fun previous() { pick(PlaybackState.ACTION_SKIP_TO_PREVIOUS)?.let { runCatching { it.transportControls.skipToPrevious() } } }
    fun seekTo(ms: Long) { pick(PlaybackState.ACTION_SEEK_TO)?.let { runCatching { it.transportControls.seekTo(ms.coerceAtLeast(0L)) } } }

    private fun pick(action: Long): MediaController? {
        val controllers = synchronized(lock) { callbacks.keys.toList() }
        return controllers.firstOrNull { it.packageName == state.packageName && ((it.playbackState?.actions ?: 0L) and action) != 0L }
            ?: controllers.firstOrNull { ((it.playbackState?.actions ?: 0L) and action) != 0L }
    }

    // ── volume (AudioManager STREAM_MUSIC) ──
    fun volume(): Int = try { vol.getStreamVolume(AudioManager.STREAM_MUSIC) } catch (_: Exception) { 0 }
    fun volumeMax(): Int = try { vol.getStreamMaxVolume(AudioManager.STREAM_MUSIC) } catch (_: Exception) { 30 }
    fun setVolume(v: Int) {
        runCatching { vol.setStreamVolume(AudioManager.STREAM_MUSIC, v.coerceIn(0, volumeMax()), 0) }
        onChanged?.invoke()
    }

    private fun hasUsableMetadata(m: MediaMetadata?): Boolean {
        if (m == null) return false
        return !m.getString(MediaMetadata.METADATA_KEY_TITLE).isNullOrBlank() ||
               !m.getString(MediaMetadata.METADATA_KEY_ARTIST).isNullOrBlank()
    }

    private fun resolveArtwork(m: MediaMetadata?): Bitmap? = m?.let {
        it.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: it.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: it.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
    }

    // ── artwork → data-URI base64 (cache por faixa p/ não re-encodar a cada update) ──
    private var artCacheKey: String? = null
    private var artCacheUri: String? = null
    fun artworkDataUri(): String? {
        val bmp = state.artwork ?: return null
        val key = (state.title ?: "") + "|" + (state.album ?: "")
        if (key == artCacheKey && artCacheUri != null) return artCacheUri
        return try {
            val max = 256
            val scaled = if (bmp.width > max || bmp.height > max) {
                val s = max.toFloat() / maxOf(bmp.width, bmp.height)
                Bitmap.createScaledBitmap(bmp, (bmp.width * s).toInt(), (bmp.height * s).toInt(), true)
            } else bmp
            val bos = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, bos)
            val b64 = Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP)
            artCacheKey = key; artCacheUri = "data:image/jpeg;base64,$b64"
            artCacheUri
        } catch (_: Exception) { null }
    }

    companion object {
        fun defaultListenerComponent(context: Context) =
            ComponentName(context, MediaNotificationListenerService::class.java)

        fun isNotificationAccessGranted(context: Context, component: ComponentName): Boolean {
            val flat = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: return false
            return flat.split(":").any { ComponentName.unflattenFromString(it) == component }
        }
        fun requestNotificationAccess(context: Context) {
            runCatching {
                context.startActivity(
                    Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        }
    }
}

/** Necessário p/ getActiveSessions. Pode ficar vazio — o que importa é a permissão. */
class MediaNotificationListenerService : NotificationListenerService()
