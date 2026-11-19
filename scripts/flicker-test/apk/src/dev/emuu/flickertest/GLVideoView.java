package dev.emuu.flickertest;

import android.content.Context;
import android.graphics.SurfaceTexture;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.view.Surface;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/**
 * Decoder output the way a player with its own GL pipeline (effects, filters) consumes it: the codec renders into a
 * SurfaceTexture owned by this app's GL context, and every vsync the app samples that GL_TEXTURE_EXTERNAL_OES texture
 * with its own shader into a GLSurfaceView (no SurfaceView/TextureView composition of the video buffer).
 * Two slots (one SurfaceTexture each) so the feed can swipe; `active` picks the one drawn.
 */
final class GLVideoView extends GLSurfaceView implements GLSurfaceView.Renderer {
    interface Ready { void onSurfaces(Surface a, Surface b); }

    private final SurfaceTexture[] st = new SurfaceTexture[2];
    private final int[] tex = new int[2];
    private final float[] m = new float[16];
    volatile int active;
    private final Ready ready;
    private int prog, aPos, uTex, uM;
    private FloatBuffer quad;

    GLVideoView(Context c, Ready ready) {
        super(c);
        this.ready = ready;
        setEGLContextClientVersion(2);
        setRenderer(this);
        setRenderMode(RENDERMODE_CONTINUOUSLY);
    }

    @Override public void onSurfaceCreated(GL10 gl, EGLConfig cfg) {
        GLES20.glGenTextures(2, tex, 0);
        for (int i = 0; i < 2; i++) {
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex[i]);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
            st[i] = new SurfaceTexture(tex[i]);
        }
        String vs = "attribute vec2 p; uniform mat4 M; varying vec2 t;"
                + "void main(){ t=(M*vec4((p+1.0)*0.5,0.0,1.0)).xy; gl_Position=vec4(p,0.0,1.0); }";
        String fs = "#extension GL_OES_EGL_image_external : require\nprecision mediump float; varying vec2 t;"
                + "uniform samplerExternalOES s; void main(){ gl_FragColor=texture2D(s,t); }";
        prog = GLES20.glCreateProgram();
        GLES20.glAttachShader(prog, shader(GLES20.GL_VERTEX_SHADER, vs));
        GLES20.glAttachShader(prog, shader(GLES20.GL_FRAGMENT_SHADER, fs));
        GLES20.glLinkProgram(prog);
        aPos = GLES20.glGetAttribLocation(prog, "p");
        uTex = GLES20.glGetUniformLocation(prog, "s");
        uM = GLES20.glGetUniformLocation(prog, "M");
        quad = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer();
        quad.put(new float[] {-1, -1, 1, -1, -1, 1, 1, 1}).position(0);
        post(() -> ready.onSurfaces(new Surface(st[0]), new Surface(st[1])));
    }

    private static int shader(int type, String src) {
        int s = GLES20.glCreateShader(type);
        GLES20.glShaderSource(s, src);
        GLES20.glCompileShader(s);
        return s;
    }

    @Override public void onSurfaceChanged(GL10 gl, int w, int h) { GLES20.glViewport(0, 0, w, h); }

    @Override public void onDrawFrame(GL10 gl) {
        for (SurfaceTexture s : st) { try { s.updateTexImage(); } catch (Exception ignored) {} }
        int k = active;
        st[k].getTransformMatrix(m);
        GLES20.glClearColor(0, 0, 0, 1);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
        GLES20.glUseProgram(prog);
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex[k]);
        GLES20.glUniform1i(uTex, 0);
        GLES20.glUniformMatrix4fv(uM, 1, false, m, 0);
        GLES20.glEnableVertexAttribArray(aPos);
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, quad);
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
    }
}
