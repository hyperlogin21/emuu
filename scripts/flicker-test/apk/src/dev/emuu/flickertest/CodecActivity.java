package dev.emuu.flickertest;

import android.app.Activity;
import android.graphics.Color;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Gravity;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.nio.ByteBuffer;

/**
 * Plays test videos the way a short-video feed player (TikTok's TTVideoEngine) drives MediaCodec, which
 * VideoActivity's MediaPlayer does not: asynchronous MediaCodec straight to a Surface, `KEY_PRIORITY` 0
 * (realtime), an optional flush() right after start(), looping by flush() + seek on the SAME codec instance,
 * and "swipes" to the next item that create a new codec while the previous one is still being released on
 * another thread (two full-screen SurfaceViews side by side, the strip slides like a pager).
 *
 * Extras:
 *   files      comma list played in turn on each swipe (default "h720x30.mp4,p720x30.mp4")
 *   swipe      seconds per item before swiping to the next (0 = stay on the first item; default 0)
 *   loop       "flush" (default: flush + seekTo(0) + start on EOS), "recreate" (release + new codec on EOS),
 *              "eos-only" (stop at the end)
 *   flushStart flush() + start() immediately after the first start(), like TikTok (default true)
 *   loopAfter  restart after this many output frames instead of at EOS (0 = at EOS)
 *   async      release the previous item's codec on a background thread while the next starts (default true)
 *   overlay    TikTok-like UI on top (default true)
 *   preload    number of extra hidden decoders (next items, off-screen SurfaceTextures) running at the same time
 *   out        "surface" (default: SurfaceView per item) or "gl" (SurfaceTexture owned by the app's GL context, drawn
 *              with its own samplerExternalOES shader into a GLSurfaceView, like a player with an effects pipeline)
 *   placeholder ms: configure the codec on an off-screen placeholder surface (SurfaceTexture), then move it to the
 *              visible surface with setOutputSurface() after this long (0 = configure on the visible surface)
 *   pingpong   ms: keep moving the running codec between the visible and the placeholder surface with
 *              setOutputSurface() every this long (0 = off)
 *
 * am start -n dev.emuu.flickertest/.CodecActivity --es files h720x30.mp4 --ei loopAfter 60
 * Log tag "EmuuCodec": one line per codec event (create, flush, loop, output format, release).
 */
public class CodecActivity extends Activity {
    static final String TAG = "EmuuCodec";
    private final SurfaceView[] views = new SurfaceView[2];
    private final Surface[] surfaces = new Surface[2];
    private LinearLayout strip;
    private GLVideoView glView;
    private String[] files;
    private int item = 0;
    private Player current;
    private String loopMode;
    private boolean flushStart, asyncRelease;
    private int loopAfter, placeholderMs, pingpongMs;
    private final Handler ui = new Handler();
    private HandlerThread releaser;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        String list = getIntent().getStringExtra("files");
        files = (list == null ? "h720x30.mp4,p720x30.mp4" : list).split(",");
        final int swipe = getIntent().getIntExtra("swipe", 0);
        loopMode = getIntent().getStringExtra("loop");
        if (loopMode == null) loopMode = "flush";
        flushStart = getIntent().getBooleanExtra("flushStart", true);
        asyncRelease = getIntent().getBooleanExtra("async", true);
        loopAfter = getIntent().getIntExtra("loopAfter", 0);
        placeholderMs = getIntent().getIntExtra("placeholder", 0);
        pingpongMs = getIntent().getIntExtra("pingpong", 0);
        releaser = new HandlerThread("releaser");
        releaser.start();

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        int W = getResources().getDisplayMetrics().widthPixels;
        strip = new LinearLayout(this);
        strip.setOrientation(LinearLayout.HORIZONTAL);
        boolean gl = "gl".equals(getIntent().getStringExtra("out"));
        if (gl) {
            glView = new GLVideoView(this, (a, bb) -> { surfaces[0] = a; surfaces[1] = bb; if (current == null) startItem(); });
            root.addView(glView, new FrameLayout.LayoutParams(W, W * 16 / 9, Gravity.CENTER));
        }
        for (int i = 0; i < 2 && !gl; i++) {
            final int k = i;
            views[i] = new SurfaceView(this);
            views[i].getHolder().addCallback(new SurfaceHolder.Callback() {
                public void surfaceCreated(SurfaceHolder h) {
                    surfaces[k] = h.getSurface();
                    if (surfaces[0] != null && surfaces[1] != null && current == null) startItem();
                }
                public void surfaceChanged(SurfaceHolder h, int f, int w, int hh) {}
                public void surfaceDestroyed(SurfaceHolder h) { surfaces[k] = null; }
            });
            // 9:16 like the test clips and a portrait feed, centred (letterboxed on a taller screen).
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(W, W * 16 / 9);
            lp.gravity = Gravity.CENTER_VERTICAL;
            strip.addView(views[i], lp);
        }
        root.addView(strip, new FrameLayout.LayoutParams(2 * W, -1));
        if (getIntent().getBooleanExtra("overlay", true)) {
            TextView t = new TextView(this);
            t.setText("@emuu  codec test  #feed");
            t.setTextColor(Color.WHITE);
            t.setTextSize(16);
            t.setBackgroundColor(0x66000000);
            root.addView(t, new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.START) {{ bottomMargin = 300; leftMargin = 40; }});
        }
        setContentView(root);
        final int preload = getIntent().getIntExtra("preload", 0);
        if (preload > 0) ui.postDelayed(() -> startPreload(preload), 1000);
        if (swipe > 0) {
            ui.postDelayed(new Runnable() {
                public void run() {
                    swipeNext();
                    ui.postDelayed(this, swipe * 1000L);
                }
            }, swipe * 1000L);
        }
    }

    /** Hidden decoders playing the next items into off-screen SurfaceTextures (feed preloading). */
    private final java.util.ArrayList<Player> preloaded = new java.util.ArrayList<>();
    private final java.util.ArrayList<android.graphics.SurfaceTexture> preloadTextures = new java.util.ArrayList<>();

    private void startPreload(int n) {
        for (int i = 0; i < n; i++) {
            android.graphics.SurfaceTexture t = new android.graphics.SurfaceTexture(false);
            t.setDefaultBufferSize(720, 1280);
            t.setOnFrameAvailableListener(x -> { try { x.updateTexImage(); } catch (Exception ignored) {} });
            preloadTextures.add(t);
            File f = new File(getExternalFilesDir(null), files[(i + 1) % files.length]);
            try { preloaded.add(new Player(f, new Surface(t), 1000 + i)); }
            catch (Exception e) { Log.e(TAG, "preload " + i + ": " + e); }
        }
    }

    private void startItem() {
        int slot = item % 2;
        if (glView != null) glView.active = slot; else strip.setTranslationX(-slot * views[0].getWidth());
        File f = new File(getExternalFilesDir(null), files[item % files.length]);
        try {
            current = new Player(f, surfaces[slot], item);
        } catch (Exception e) {
            Log.e(TAG, "item " + item + " " + f.getName() + ": cannot start: " + e);
        }
    }

    private void swipeNext() {
        final Player old = current;
        current = null;
        if (old != null) {
            if (asyncRelease) new Handler(releaser.getLooper()).post(old::release); else old.release();
        }
        item++;
        startItem();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        ui.removeCallbacksAndMessages(null);
        if (current != null) current.release();
        for (Player p : preloaded) p.release();
        releaser.quitSafely();
    }

    /** One feed item: an extractor and an async codec rendering to `surface` at the clip's frame rate. */
    final class Player extends MediaCodec.Callback {
        final MediaExtractor ex = new MediaExtractor();
        final HandlerThread thread;
        Handler handler;
        final Surface surface;
        final String name;
        final int id;
        MediaFormat format;
        MediaCodec codec;
        long baseNs = -1, basePtsUs;
        android.graphics.SurfaceTexture placeholderTexture;
        Surface placeholder;
        int outFrames, loops, totalFrames;
        final java.util.ArrayList<ByteBuffer> pendingCsd = new java.util.ArrayList<>();
        volatile boolean released;

        Player(File f, Surface s, int id) throws Exception {
            this.surface = s;
            this.id = id;
            this.name = f.getName();
            ex.setDataSource(f.getAbsolutePath());
            for (int i = 0; i < ex.getTrackCount(); i++) {
                MediaFormat fmt = ex.getTrackFormat(i);
                if (fmt.getString(MediaFormat.KEY_MIME).startsWith("video/")) { ex.selectTrack(i); format = fmt; break; }
            }
            thread = new HandlerThread("codec-" + id);
            thread.start();
            handler = new Handler(thread.getLooper());
            handler.post(() -> { try { create(); } catch (Exception e) { log("create failed: " + e); } });
        }

        void create() throws Exception {
            String mime = format.getString(MediaFormat.KEY_MIME);
            codec = MediaCodec.createDecoderByType(mime);
            MediaFormat fmt = new MediaFormat(format);
            fmt.setInteger(MediaFormat.KEY_PRIORITY, 0);
            codec.setCallback(this, handler);
            // Pre-warm like a feed player: decode into an off-screen placeholder surface first, then move the running
            // codec to the visible surface with setOutputSurface() (the call behind the user's "setOutputSurface --
            // failed to set consumer usage" log line).
            Surface first = surface;
            if (placeholderMs > 0 || pingpongMs > 0) {
                if (placeholder == null) {
                    placeholderTexture = new android.graphics.SurfaceTexture(false);
                    placeholderTexture.setDefaultBufferSize(format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT));
                    placeholderTexture.setOnFrameAvailableListener(st -> { try { st.updateTexImage(); } catch (Exception ignored) {} });
                    placeholder = new Surface(placeholderTexture);
                }
                if (placeholderMs > 0) first = placeholder;
            }
            codec.configure(fmt, first, null, 0);
            codec.start();
            if (placeholderMs > 0) handler.postDelayed(() -> switchTo(surface, "visible"), placeholderMs);
            if (pingpongMs > 0) handler.postDelayed(new Runnable() {
                boolean onVisible = placeholderMs == 0;
                public void run() {
                    if (released) return;
                    onVisible = !onVisible;
                    switchTo(onVisible ? surface : placeholder, onVisible ? "visible" : "placeholder");
                    handler.postDelayed(this, pingpongMs);
                }
            }, pingpongMs + placeholderMs);
            log("create " + codec.getName() + " " + format.getInteger(MediaFormat.KEY_WIDTH) + "x" + format.getInteger(MediaFormat.KEY_HEIGHT));
            if (flushStart) {
                codec.flush();
                // A flush before the first output drops the codec-specific data from configure(); players resubmit it.
                for (String k : new String[] {"csd-0", "csd-1", "csd-2"}) if (format.containsKey(k)) pendingCsd.add(format.getByteBuffer(k).duplicate());
                codec.start();
                log("flush right after start (resubmitting " + pendingCsd.size() + " csd buffers)");
            }
        }

        void switchTo(Surface s, String what) {
            if (released) return;
            try { codec.setOutputSurface(s); log("setOutputSurface -> " + what); }
            catch (Exception e) { log("setOutputSurface -> " + what + " failed: " + e); }
        }

        void restart() {
            loops++;
            outFrames = 0;
            baseNs = -1;
            ex.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
            if ("recreate".equals(loopMode)) {
                codec.release();
                try { create(); } catch (Exception e) { log("recreate failed: " + e); }
                log("loop " + loops + " (recreate)");
            } else {
                codec.flush();
                codec.start();
                log("loop " + loops + " (flush+seek)");
            }
        }

        void log(String s) { Log.i(TAG, "item " + id + " " + name + ": " + s); }

        @Override public void onInputBufferAvailable(MediaCodec c, int index) {
            if (released || c != codec) return;
            ByteBuffer buf;
            try { buf = c.getInputBuffer(index); } catch (IllegalStateException stale) { return; }
            if (!pendingCsd.isEmpty()) {
                ByteBuffer csd = pendingCsd.remove(0);
                int len = csd.remaining();
                buf.put(csd);
                c.queueInputBuffer(index, 0, len, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG);
                return;
            }
            int n = ex.readSampleData(buf, 0);
            if (n < 0) {
                c.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
            } else {
                c.queueInputBuffer(index, 0, n, ex.getSampleTime(), 0);
                ex.advance();
            }
        }

        @Override public void onOutputBufferAvailable(MediaCodec c, int index, MediaCodec.BufferInfo info) {
            if (released || c != codec) return;
            boolean eos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
            long now = System.nanoTime();
            if (baseNs < 0) { baseNs = now; basePtsUs = info.presentationTimeUs; }
            long due = baseNs + (info.presentationTimeUs - basePtsUs) * 1000;
            if (due > now) {
                try { Thread.sleep((due - now) / 1000000, (int) ((due - now) % 1000000)); } catch (InterruptedException ignored) {}
            }
            try { c.releaseOutputBuffer(index, info.size > 0); } catch (IllegalStateException stale) { return; }
            outFrames++;
            totalFrames++;
            if (totalFrames % 60 == 0) log("output frames " + totalFrames + " (size " + info.size + ", pts " + info.presentationTimeUs + ")");
            if (eos || (loopAfter > 0 && outFrames >= loopAfter)) {
                if ("eos-only".equals(loopMode)) { log("end"); return; }
                restart();
            }
        }

        @Override public void onError(MediaCodec c, MediaCodec.CodecException e) { log("error " + e.getDiagnosticInfo() + " " + e); }

        @Override public void onOutputFormatChanged(MediaCodec c, MediaFormat f) { log("output format " + f); }

        void release() {
            released = true;
            // Release on the codec's thread so it never races its callbacks; wait for it (like a player would).
            final Object done = new Object();
            final boolean[] ok = {false};
            handler.post(() -> { releaseNow(); synchronized (done) { ok[0] = true; done.notifyAll(); } });
            synchronized (done) { while (!ok[0]) try { done.wait(); } catch (InterruptedException e) { break; } }
            thread.quitSafely();
            log("released after " + loops + " loops");
        }

        void releaseNow() {
            try { codec.stop(); } catch (Exception ignored) {}
            codec.release();
            ex.release();
            if (placeholder != null) { placeholder.release(); placeholderTexture.release(); }
        }
    }
}
