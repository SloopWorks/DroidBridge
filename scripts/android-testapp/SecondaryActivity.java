package dev.droidbridge.testapp;
import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.graphics.Color;
import android.widget.*;
public final class SecondaryActivity extends Activity {
 @Override public void onCreate(Bundle state) { super.onCreate(state);
  int display = getDisplay().getDisplayId();
  Log.i("DroidBridgeProbe", "secondary display=" + display + " package=" + getPackageName());
  LinearLayout box = new LinearLayout(this); box.setOrientation(1); box.setPadding(24,50,24,24); box.setBackgroundColor(Color.rgb(229,249,226));
  TextView label = new TextView(this); label.setText("Real secondary Activity\nDisplay " + display); label.setTextSize(24); box.addView(label);
  Button back = new Button(this); back.setText("Return to input probe"); back.setOnClickListener(v -> finish()); box.addView(back);
  setContentView(box);
 }
}
