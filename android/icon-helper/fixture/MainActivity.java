package dev.droidbridge.iconfixture;
import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;
public final class MainActivity extends Activity {
 @Override public void onCreate(Bundle b) { super.onCreate(b); TextView text = new TextView(this); text.setText("Android alias icon fixture"); setContentView(text); }
}
