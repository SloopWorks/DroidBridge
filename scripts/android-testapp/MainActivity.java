package dev.droidbridge.testapp;
import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.util.Log;
import android.widget.*;
import android.graphics.Color;
public final class MainActivity extends Activity {
 private int clicks=0, ticks=0; private final Handler handler=new Handler(); private TextView status; private Runnable update;
 private volatile int toneGeneration=0;
 @Override public void onCreate(Bundle state) { super.onCreate(state);
  LinearLayout box=new LinearLayout(this); box.setOrientation(1); box.setPadding(24,50,24,24); box.setBackgroundColor(Color.rgb(225,242,255));
  TextView title=new TextView(this); title.setText("DroidBridge input / frame probe"); title.setTextSize(23); box.addView(title);
  status=new TextView(this); status.setTextSize(24); box.addView(status);
  Button button=new Button(this); button.setText("Increment counter"); button.setOnClickListener(v -> { clicks++; Log.i("DroidBridgeProbe","click="+clicks+" display="+getDisplay().getDisplayId()); }); box.addView(button);
  EditText input=new EditText(this); input.setHint("Type a session-specific word"); input.setSingleLine(true); input.addTextChangedListener(new android.text.TextWatcher() { public void beforeTextChanged(CharSequence s,int a,int c,int f){} public void onTextChanged(CharSequence s,int a,int b,int c){Log.i("DroidBridgeProbe","text="+s+" display="+getDisplay().getDisplayId());} public void afterTextChanged(android.text.Editable e){} }); box.addView(input);
  Button next=new Button(this); next.setText("Open secondary activity"); next.setOnClickListener(v -> startActivity(new android.content.Intent(this, SecondaryActivity.class))); box.addView(next);
  Button tone=new Button(this); tone.setText("Play test tone (10 seconds)"); tone.setOnClickListener(v -> playTone()); box.addView(tone);
  Button stop=new Button(this); stop.setText("Stop test tone"); stop.setOnClickListener(v -> toneGeneration++); box.addView(stop);
  setContentView(box); update=new Runnable(){public void run(){ticks++; status.setText("Display "+getDisplay().getDisplayId()+" • ticks "+ticks+"\nClicks "+clicks+" • "+getResources().getDisplayMetrics().widthPixels+"×"+getResources().getDisplayMetrics().heightPixels); handler.postDelayed(this,250);}}; handler.post(update);
 }
 private void playTone(){
  final int generation=++toneGeneration, display=getDisplay().getDisplayId();
  final int frequency=getPackageName().endsWith("2")?1499:997;
  new Thread(() -> {
   android.media.AudioTrack audio=null;
   try {
    android.media.AudioAttributes attributes=new android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA).setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC).setAllowedCapturePolicy(android.media.AudioAttributes.ALLOW_CAPTURE_BY_ALL).build();
    android.media.AudioFormat format=new android.media.AudioFormat.Builder().setSampleRate(48000).setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT).setChannelMask(android.media.AudioFormat.CHANNEL_OUT_STEREO).build();
    audio=new android.media.AudioTrack.Builder().setAudioAttributes(attributes).setAudioFormat(format).setTransferMode(android.media.AudioTrack.MODE_STREAM).setBufferSizeInBytes(19200).build();
    if(audio.getState()!=android.media.AudioTrack.STATE_INITIALIZED)throw new IllegalStateException("AudioTrack initialization failed");
    audio.play();Log.i("DroidBridgeProbe","tone_started frequency="+frequency+" display="+display);
    short[] samples=new short[4800];
    for(int frame=0;frame<480000&&toneGeneration==generation;){
     for(int i=0;i<samples.length/2;i++,frame++)samples[2*i]=samples[2*i+1]=(short)(2048*Math.sin(2*Math.PI*frequency*frame/48000));
     int written=audio.write(samples,0,samples.length);
     if(written!=samples.length)throw new IllegalStateException("AudioTrack write="+written);
    }
   }catch(Exception failure){Log.e("DroidBridgeProbe","tone_failed display="+display,failure);}
   finally{if(audio!=null){try{if(audio.getPlayState()==android.media.AudioTrack.PLAYSTATE_PLAYING)audio.stop();}finally{audio.release();}}Log.i("DroidBridgeProbe","tone_stopped display="+display);}
  },"DroidBridgeTestTone").start();
 }
 @Override protected void onDestroy(){toneGeneration++;handler.removeCallbacks(update);super.onDestroy();}
}
