package dev.emuu.securetest;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.TextView;

/** A window with FLAG_SECURE: guest-side capture (screencap, scrcpy) shows it black. */
public class SecureActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        TextView t = new TextView(this);
        t.setText("FLAG_SECURE window\n\nEmuu native display\nsecret: 4242");
        t.setTextSize(30);
        t.setGravity(Gravity.CENTER);
        t.setTextColor(Color.WHITE);
        t.setBackgroundColor(Color.rgb(0x1a, 0x73, 0xe8));
        setContentView(t);
    }
}
