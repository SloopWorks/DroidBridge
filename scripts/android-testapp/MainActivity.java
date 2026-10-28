package dev.droidbridge.testapp;
import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.util.Log;
import android.widget.*;
import android.graphics.Color;
public final class MainActivity extends Activity {
 private int clicks=0, ticks=0; private final Handler handler=new Handler(); private TextView status; private Runnable update;
 @Override public void onCreate(Bundle state) { super.onCreate(state);
  LinearLayout box=new LinearLayout(this); box.setOrientation(1); box.setPadding(24,50,24,24); box.setBackgroundColor(Color.rgb(225,242,255));
  TextView title=new TextView(this); title.setText("DroidBridge input / frame probe"); title.setTextSize(23); box.addView(title);
  status=new TextView(this); status.setTextSize(24); box.addView(status);
  Button button=new Button(this); button.setText("Increment counter"); button.setOnClickListener(v -> { clicks++; Log.i("DroidBridgeProbe","click="+clicks+" display="+getDisplay().getDisplayId()); }); box.addView(button);
  EditText input=new EditText(this); input.setHint("Type a session-specific word"); input.setSingleLine(true); input.addTextChangedListener(new android.text.TextWatcher() { public void beforeTextChanged(CharSequence s,int a,int c,int f){} public void onTextChanged(CharSequence s,int a,int b,int c){Log.i("DroidBridgeProbe","text="+s+" display="+getDisplay().getDisplayId());} public void afterTextChanged(android.text.Editable e){} }); box.addView(input);
  Button next=new Button(this); next.setText("Open secondary activity"); next.setOnClickListener(v -> startActivity(new android.content.Intent(this, SecondaryActivity.class))); box.addView(next);
  setContentView(box); update=new Runnable(){public void run(){ticks++; status.setText("Display "+getDisplay().getDisplayId()+" • ticks "+ticks+"\nClicks "+clicks+" • "+getResources().getDisplayMetrics().widthPixels+"×"+getResources().getDisplayMetrics().heightPixels); handler.postDelayed(this,250);}}; handler.post(update);
 }
 @Override protected void onDestroy(){handler.removeCallbacks(update);super.onDestroy();}
}
