package dev.emuu.flickertest;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.opengl.GLES20;
import android.opengl.GLUtils;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import android.opengl.GLSurfaceView;
import android.os.Bundle;
import android.view.WindowManager;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/**
 * 60 fps GL animation drawing the same pattern as scripts/flicker-test/make-pattern-video.swift (magenta
 * border, per-frame grey, moving bar, frame counter mod 512 in five 3-cell markers), but rendered by the
 * guest GPU every vsync instead of decoded: no video decoder involved.
 *
 * Extra "upload" (true): like a software video decoder feeding GL (what some players do), the pattern is drawn
 * on the CPU into a 1080x1920 bitmap and uploaded with texSubImage2D every frame, then drawn as an aspect-fit quad.
 */
public class GLActivity extends Activity {
    static final float[][] PALETTE = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 0}, {0, 1, 1}, {1, 0, 1}, {1, 1, 1}};

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        GLSurfaceView v = new GLSurfaceView(this);
        v.setEGLContextClientVersion(2);
        // Keep the whole pattern clear of the status and navigation bars (edge-to-edge is enforced on API 35+).
        android.widget.FrameLayout root = new android.widget.FrameLayout(this);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets bars = insets.getInsets(android.view.WindowInsets.Type.systemBars());
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return insets;
        });
        root.addView(v);
        if (getIntent().getBooleanExtra("upload", false)) { v.setRenderer(new UploadRenderer()); setContentView(root); return; }
        v.setRenderer(new GLSurfaceView.Renderer() {
            int W, H, n;
            public void onSurfaceCreated(GL10 gl, EGLConfig c) {}
            public void onSurfaceChanged(GL10 gl, int w, int h) { W = w; H = h; GLES20.glViewport(0, 0, w, h); }
            void fill(int x, int y, int w, int h, float r, float g, float bb) {
                GLES20.glScissor(x, H - y - h, w, h);   // GL origin is bottom-left
                GLES20.glClearColor(r, g, bb, 1);
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            }
            public void onDrawFrame(GL10 gl) {
                GLES20.glEnable(GLES20.GL_SCISSOR_TEST);
                int border = Math.max(4, W / 40), cell = W / 10, barW = Math.max(6, W / 40);
                float g = (40 + (n * 7) % 160) / 255f;
                fill(0, 0, W, H, g, g, g);
                int span = W - 2 * border - barW;
                fill(border + (n * W / 60) % span, border, barW, H - 2 * border, 1, 1, 1);
                int m = border + cell / 3;
                int[][] o = {{m, m}, {W - m - 3 * cell, m}, {m, H - m - cell}, {W - m - 3 * cell, H - m - cell},
                             {W / 2 - 3 * cell / 2, H / 2 - cell / 2}};
                for (int[] p : o) {
                    fill(p[0] - cell / 8, p[1] - cell / 8, 3 * cell + cell / 4, cell + cell / 4, 0.5f, 0.5f, 0.5f);
                    for (int k = 0; k < 3; k++) {
                        float[] c = PALETTE[(n >> (3 * (2 - k))) & 7];
                        fill(p[0] + k * cell, p[1], cell, cell, c[0], c[1], c[2]);
                    }
                }
                fill(0, 0, W, border, 1, 0, 1); fill(0, H - border, W, border, 1, 0, 1);
                fill(0, 0, border, H, 1, 0, 1); fill(W - border, 0, border, H, 1, 0, 1);
                n++;
            }
        });
        setContentView(root);
    }

    /** CPU-drawn pattern uploaded as a texture every frame. */
    static class UploadRenderer implements GLSurfaceView.Renderer {
        static final int BW = 1080, BH = 1920;
        final Bitmap bmp = Bitmap.createBitmap(BW, BH, Bitmap.Config.ARGB_8888);
        final Canvas canvas = new Canvas(bmp);
        final Paint paint = new Paint();
        int W, H, n, prog, tex;
        FloatBuffer quad;

        void fill(int x, int y, int w, int h, float r, float g, float b) {
            paint.setARGB(255, Math.round(r * 255), Math.round(g * 255), Math.round(b * 255));
            canvas.drawRect(x, y, x + w, y + h, paint);
        }

        void drawPattern() {
            int border = Math.max(4, BW / 40), cell = BW / 10, barW = Math.max(6, BW / 40);
            float g = (40 + (n * 7) % 160) / 255f;
            fill(0, 0, BW, BH, g, g, g);
            fill(border + (n * BW / 60) % (BW - 2 * border - barW), border, barW, BH - 2 * border, 1, 1, 1);
            int m = border + cell / 3;
            int[][] o = {{m, m}, {BW - m - 3 * cell, m}, {m, BH - m - cell}, {BW - m - 3 * cell, BH - m - cell}, {BW / 2 - 3 * cell / 2, BH / 2 - cell / 2}};
            for (int[] p : o) {
                fill(p[0] - cell / 8, p[1] - cell / 8, 3 * cell + cell / 4, cell + cell / 4, 0.5f, 0.5f, 0.5f);
                for (int k = 0; k < 3; k++) { float[] c = PALETTE[(n >> (3 * (2 - k))) & 7]; fill(p[0] + k * cell, p[1], cell, cell, c[0], c[1], c[2]); }
            }
            fill(0, 0, BW, border, 1, 0, 1); fill(0, BH - border, BW, border, 1, 0, 1);
            fill(0, 0, border, BH, 1, 0, 1); fill(BW - border, 0, border, BH, 1, 0, 1);
        }

        static int shader(int type, String src) { int s = GLES20.glCreateShader(type); GLES20.glShaderSource(s, src); GLES20.glCompileShader(s); return s; }

        public void onSurfaceCreated(GL10 gl, EGLConfig c) {
            prog = GLES20.glCreateProgram();
            GLES20.glAttachShader(prog, shader(GLES20.GL_VERTEX_SHADER, "attribute vec2 p; varying vec2 t; void main(){ t = vec2((p.x+1.0)*0.5, (1.0-p.y)*0.5); gl_Position = vec4(p,0.0,1.0); }"));
            GLES20.glAttachShader(prog, shader(GLES20.GL_FRAGMENT_SHADER, "precision mediump float; varying vec2 t; uniform sampler2D s; void main(){ gl_FragColor = texture2D(s, t); }"));
            GLES20.glLinkProgram(prog);
            int[] t = new int[1];
            GLES20.glGenTextures(1, t, 0);
            tex = t[0];
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
            drawPattern();
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bmp, 0);
            float[] v = {-1, -1, 1, -1, -1, 1, 1, 1};
            quad = ByteBuffer.allocateDirect(v.length * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
            quad.put(v).position(0);
        }

        public void onSurfaceChanged(GL10 gl, int w, int h) {
            W = w; H = h;
            float s = Math.min((float) w / BW, (float) h / BH);
            int vw = Math.round(BW * s), vh = Math.round(BH * s);
            GLES20.glViewport((w - vw) / 2, (h - vh) / 2, vw, vh);
        }

        public void onDrawFrame(GL10 gl) {
            drawPattern();
            GLES20.glClearColor(0, 0, 0, 1);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex);
            GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, bmp);
            GLES20.glUseProgram(prog);
            int p = GLES20.glGetAttribLocation(prog, "p");
            GLES20.glEnableVertexAttribArray(p);
            GLES20.glVertexAttribPointer(p, 2, GLES20.GL_FLOAT, false, 0, quad);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            n++;
        }
    }
}
