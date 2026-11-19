package dev.emuu.typetest;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.Log;
import android.view.KeyEvent;
import android.widget.EditText;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * One multi-line text field that records what Emuu's keyboard path delivers:
 * - every key event the window receives → logcat tag EmuuType ("KEY ...");
 * - the field's full text after every change → files/text.txt (read with `run-as dev.emuu.typetest cat files/text.txt`),
 *   plus the selection → files/sel.txt.
 * `am start -n dev.emuu.typetest/.TypeActivity --ez clear true` empties the field.
 */
public class TypeActivity extends Activity {
    private EditText field;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        field = new EditText(this);
        field.setGravity(android.view.Gravity.TOP | android.view.Gravity.START);
        field.setHint("Emuu typing test");
        field.setTextSize(18);
        field.setTextColor(0xff000000);
        field.setBackgroundColor(0xffffffff);
        field.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            public void onTextChanged(CharSequence s, int a, int b, int c) {}
            public void afterTextChanged(Editable s) { save(); }
        });
        setContentView(field);
        field.requestFocus();
        handle(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handle(intent);
    }

    private void handle(Intent intent) {
        if (intent != null && intent.getBooleanExtra("clear", false)) {
            field.setText("");
            field.requestFocus();
            save();
        }
    }

    private void save() {
        write("text.txt", field.getText().toString());
        write("sel.txt", field.getSelectionStart() + " " + field.getSelectionEnd());
    }

    private void write(String name, String value) {
        try (FileOutputStream out = openFileOutput(name, MODE_PRIVATE)) {
            out.write(value.getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            Log.w("EmuuType", "write failed", e);
        }
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        Log.i("EmuuType", "KEY " + (e.getAction() == KeyEvent.ACTION_DOWN ? "down" : e.getAction() == KeyEvent.ACTION_UP ? "up" : "multi")
                + " " + KeyEvent.keyCodeToString(e.getKeyCode()) + " meta=0x" + Integer.toHexString(e.getMetaState())
                + " repeat=" + e.getRepeatCount() + " chars=" + (e.getCharacters() == null ? "" : e.getCharacters().length())
                + " device=" + e.getDeviceId());
        boolean r = super.dispatchKeyEvent(e);
        field.post(this::save);   // selection-only changes (arrows) do not fire the text watcher
        return r;
    }
}
