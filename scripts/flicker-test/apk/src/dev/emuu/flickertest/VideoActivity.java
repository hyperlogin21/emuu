package dev.emuu.flickertest;

import android.animation.ValueAnimator;
import android.app.Activity;
import android.graphics.Color;
import android.graphics.SurfaceTexture;
import android.media.MediaPlayer;
import android.os.Bundle;
import android.view.Gravity;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.TextureView;
import android.view.View;
import android.view.WindowManager;
import android.view.animation.LinearInterpolator;
import android.widget.FrameLayout;
import android.widget.TextView;
import java.io.File;

/**
 * Plays a test video looped with MediaPlayer (hardware decoder) like a short-video feed: in a SurfaceView
 * (extra mode=surface, default) or a TextureView (mode=texture), aspect-fit and scaled by extra "scale"
 * (1.0 = full screen, 0.6 = in-feed), with animated UI drawn over it (spinning disc, progress bar, captions).
 *
 * am start -n dev.emuu.flickertest/.VideoActivity --es file p1080x60.mp4 --es mode texture --ef scale 0.6
 * The file is read from getExternalFilesDir(null) (/sdcard/Android/data/dev.emuu.flickertest/files/).
 */
public class VideoActivity extends Activity {
    private MediaPlayer player;
    private FrameLayout root;
    private View video;
    private float scale;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        String name = getIntent().getStringExtra("file");
        if (name == null) name = "p1080x60.mp4";
        String mode = getIntent().getStringExtra("mode");
        scale = getIntent().getFloatExtra("scale", 1.0f);
        boolean overlay = getIntent().getBooleanExtra("overlay", true);
        File f = new File(getExternalFilesDir(null), name);

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        player = new MediaPlayer();
        try {
            player.setDataSource(f.getAbsolutePath());
        } catch (Exception e) {
            throw new RuntimeException("cannot open " + f, e);
        }
        player.setLooping(true);
        player.setVolume(0, 0);
        player.setOnVideoSizeChangedListener((mp, w, h) -> layoutVideo(w, h));

        if ("texture".equals(mode)) {
            TextureView tv = new TextureView(this);
            tv.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
                public void onSurfaceTextureAvailable(SurfaceTexture st, int w, int h) { start(new Surface(st)); }
                public void onSurfaceTextureSizeChanged(SurfaceTexture st, int w, int h) {}
                public boolean onSurfaceTextureDestroyed(SurfaceTexture st) { return true; }
                public void onSurfaceTextureUpdated(SurfaceTexture st) {}
            });
            video = tv;
        } else {
            SurfaceView sv = new SurfaceView(this);
            sv.getHolder().addCallback(new SurfaceHolder.Callback() {
                public void surfaceCreated(SurfaceHolder h) { start(h.getSurface()); }
                public void surfaceChanged(SurfaceHolder h, int fmt, int w, int hh) {}
                public void surfaceDestroyed(SurfaceHolder h) {}
            });
            video = sv;
        }
        root.addView(video, new FrameLayout.LayoutParams(1, 1, Gravity.CENTER));
        if (overlay) addOverlay();
        setContentView(root);
    }

    private void start(Surface s) {
        player.setSurface(s);
        player.setOnPreparedListener(MediaPlayer::start);
        player.prepareAsync();
    }

    private void layoutVideo(int vw, int vh) {
        if (vw <= 0 || vh <= 0) return;
        int W = root.getWidth(), H = root.getHeight();
        float fit = Math.min((float) W / vw, (float) H / vh) * scale;
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(Math.round(vw * fit), Math.round(vh * fit), Gravity.CENTER);
        video.setLayoutParams(lp);
    }

    /** TikTok-like UI over the video: a spinning disc, a caption, and a progress bar that moves every frame. */
    private void addOverlay() {
        TextView caption = new TextView(this);
        caption.setText("@emuu  flicker test  #video");
        caption.setTextColor(Color.WHITE);
        caption.setTextSize(16);
        caption.setBackgroundColor(0x66000000);
        caption.setPadding(16, 8, 16, 8);
        root.addView(caption, new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.START) {{ bottomMargin = 520; leftMargin = 200; }});

        View disc = new View(this);
        disc.setBackgroundColor(0xCC20C0C0);
        root.addView(disc, new FrameLayout.LayoutParams(96, 96, Gravity.BOTTOM | Gravity.END) {{ bottomMargin = 620; rightMargin = 200; }});
        ValueAnimator spin = ValueAnimator.ofFloat(0, 360);
        spin.setDuration(3000);
        spin.setRepeatCount(ValueAnimator.INFINITE);
        spin.setInterpolator(new LinearInterpolator());
        spin.addUpdateListener(a -> disc.setRotation((float) a.getAnimatedValue()));
        spin.start();

        View bar = new View(this);
        bar.setBackgroundColor(0xFFFFFFFF);
        bar.setPivotX(0);
        root.addView(bar, new FrameLayout.LayoutParams(-1, 6, Gravity.BOTTOM) {{ bottomMargin = 120; }});
        ValueAnimator prog = ValueAnimator.ofFloat(0, 1);
        prog.setDuration(10000);
        prog.setRepeatCount(ValueAnimator.INFINITE);
        prog.setInterpolator(new LinearInterpolator());
        prog.addUpdateListener(a -> bar.setScaleX((float) a.getAnimatedValue()));
        prog.start();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (player != null) player.release();
    }
}
