package dev.emuu.cameratest;

import android.app.Activity;
import android.graphics.ImageFormat;
import android.graphics.Rect;
import android.graphics.SurfaceTexture;
import android.graphics.YuvImage;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.util.Log;
import android.util.Size;
import android.view.Surface;
import android.view.TextureView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Camera2 probe for Emuu's camera tests. Opens one camera (extra "facing": back|front, or "id"), shows the preview
 * full screen and writes the newest frame as JPEG to files/latest.jpg (atomically) every "interval" ms (default 250),
 * plus files/info.txt (cameras, facings, sizes, the chosen size, frame count). Grant the permission first:
 *   adb shell pm grant dev.emuu.cameratest android.permission.CAMERA
 *   adb shell am start -n dev.emuu.cameratest/.CameraActivity --es facing back
 * Logcat tag "EmuuCamTest".
 */
public class CameraActivity extends Activity {
    static final String TAG = "EmuuCamTest";
    HandlerThread thread;
    Handler handler;
    CameraDevice device;
    CameraCaptureSession session;
    ImageReader reader;
    TextureView preview;
    volatile long frames;
    long lastWrite;
    int interval = 250;
    final StringBuilder info = new StringBuilder();

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        preview = new TextureView(this);
        setContentView(preview);
        interval = getIntent().getIntExtra("interval", 250);
        thread = new HandlerThread("cam");
        thread.start();
        handler = new Handler(thread.getLooper());
        preview.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            public void onSurfaceTextureAvailable(SurfaceTexture st, int w, int h) { handler.post(() -> open(st)); }
            public void onSurfaceTextureSizeChanged(SurfaceTexture st, int w, int h) {}
            public boolean onSurfaceTextureDestroyed(SurfaceTexture st) { return true; }
            public void onSurfaceTextureUpdated(SurfaceTexture st) {}
        });
    }

    void open(SurfaceTexture st) {
        CameraManager cm = getSystemService(CameraManager.class);
        try {
            String want = getIntent().getStringExtra("facing");
            String wantId = getIntent().getStringExtra("id");
            String chosen = null;
            String[] ids = cm.getCameraIdList();
            info.append("cameras=").append(Arrays.toString(ids)).append('\n');
            for (String id : ids) {
                CameraCharacteristics c = cm.getCameraCharacteristics(id);
                Integer f = c.get(CameraCharacteristics.LENS_FACING);
                String facing = f == null ? "?" : f == CameraCharacteristics.LENS_FACING_BACK ? "back"
                        : f == CameraCharacteristics.LENS_FACING_FRONT ? "front" : "external";
                StreamConfigurationMap m = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                Size[] yuv = m.getOutputSizes(ImageFormat.YUV_420_888);
                info.append("camera ").append(id).append(" facing=").append(facing)
                    .append(" orientation=").append(c.get(CameraCharacteristics.SENSOR_ORIENTATION))
                    .append(" yuv=").append(Arrays.toString(yuv)).append('\n');
                if (chosen == null && (wantId != null ? wantId.equals(id) : (want == null || want.equals(facing)))) chosen = id;
            }
            if (chosen == null) { fail("no camera matches facing=" + want + " id=" + wantId); return; }
            CameraCharacteristics c = cm.getCameraCharacteristics(chosen);
            Size[] sizes = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP).getOutputSizes(ImageFormat.YUV_420_888);
            Size size = sizes[0];
            for (Size s : sizes) if ((long) s.getWidth() * s.getHeight() > (long) size.getWidth() * size.getHeight()) size = s;
            int w = getIntent().getIntExtra("w", 0), h = getIntent().getIntExtra("h", 0);
            if (w > 0 && h > 0) size = new Size(w, h);
            info.append("chosen=").append(chosen).append(" size=").append(size).append('\n');
            writeInfo();
            reader = ImageReader.newInstance(size.getWidth(), size.getHeight(), ImageFormat.YUV_420_888, 3);
            reader.setOnImageAvailableListener(this::onImage, handler);
            st.setDefaultBufferSize(size.getWidth(), size.getHeight());
            final Surface previewSurface = new Surface(st);
            final long t0 = SystemClock.elapsedRealtime();
            cm.openCamera(chosen, new CameraDevice.StateCallback() {
                public void onOpened(CameraDevice d) {
                    device = d;
                    Log.i(TAG, "opened in " + (SystemClock.elapsedRealtime() - t0) + " ms");
                    final boolean withPreview = !getIntent().getBooleanExtra("nopreview", false);
                    List<Surface> outs = new ArrayList<>();
                    if (withPreview) outs.add(previewSurface);
                    outs.add(reader.getSurface());
                    Log.i(TAG, "configuring " + outs.size() + " stream(s)");
                    try {
                        d.createCaptureSession(outs, new CameraCaptureSession.StateCallback() {
                            public void onConfigured(CameraCaptureSession s) {
                                session = s;
                                try {
                                    CaptureRequest.Builder rb = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
                                    if (withPreview) rb.addTarget(previewSurface);
                                    rb.addTarget(reader.getSurface());
                                    s.setRepeatingRequest(rb.build(), null, handler);
                                    Log.i(TAG, "streaming");
                                } catch (CameraAccessException e) { fail("request: " + e); }
                            }
                            public void onConfigureFailed(CameraCaptureSession s) { fail("configure failed"); }
                        }, handler);
                    } catch (CameraAccessException e) { fail("session: " + e); }
                }
                public void onDisconnected(CameraDevice d) { fail("disconnected"); d.close(); }
                public void onError(CameraDevice d, int e) { fail("error " + e); d.close(); }
            }, handler);
        } catch (Exception e) { fail("open: " + e); }
    }

    void onImage(ImageReader r) {
        Image img = r.acquireLatestImage();
        if (img == null) return;
        try {
            frames++;
            long now = SystemClock.elapsedRealtime();
            if (now - lastWrite < interval) return;
            lastWrite = now;
            byte[] nv21 = toNV21(img);
            YuvImage y = new YuvImage(nv21, ImageFormat.NV21, img.getWidth(), img.getHeight(), null);
            File dir = getExternalFilesDir(null);
            File tmp = new File(dir, "latest.tmp");
            try (FileOutputStream o = new FileOutputStream(tmp)) {
                y.compressToJpeg(new Rect(0, 0, img.getWidth(), img.getHeight()), 92, o);
            }
            tmp.renameTo(new File(dir, "latest.jpg"));
            try (FileWriter fw = new FileWriter(new File(dir, "frames.txt"))) {
                fw.write(frames + " " + img.getWidth() + "x" + img.getHeight() + " " + now + "\n");
            }
        } catch (Exception e) {
            Log.w(TAG, "write: " + e);
        } finally {
            img.close();
        }
    }

    static byte[] toNV21(Image img) {
        int w = img.getWidth(), h = img.getHeight();
        byte[] out = new byte[w * h * 3 / 2];
        Image.Plane[] p = img.getPlanes();
        ByteBuffer yb = p[0].getBuffer();
        int ys = p[0].getRowStride();
        for (int row = 0; row < h; row++) { yb.position(row * ys); yb.get(out, row * w, w); }
        ByteBuffer ub = p[1].getBuffer(), vb = p[2].getBuffer();
        int us = p[1].getRowStride(), up = p[1].getPixelStride(), vs = p[2].getRowStride(), vp = p[2].getPixelStride();
        int o = w * h;
        for (int row = 0; row < h / 2; row++) {
            for (int col = 0; col < w / 2; col++) {
                out[o++] = vb.get(row * vs + col * vp);
                out[o++] = ub.get(row * us + col * up);
            }
        }
        return out;
    }

    void writeInfo() {
        try (FileWriter fw = new FileWriter(new File(getExternalFilesDir(null), "info.txt"))) { fw.write(info.toString()); }
        catch (Exception e) { Log.w(TAG, "info: " + e); }
        Log.i(TAG, info.toString());
    }

    void fail(String why) {
        info.append("error=").append(why).append('\n');
        writeInfo();
        Log.e(TAG, why);
    }

    @Override protected void onDestroy() {
        if (session != null) session.close();
        if (device != null) device.close();
        if (reader != null) reader.close();
        thread.quitSafely();
        super.onDestroy();
    }
}
