package dev.droidbridge.companionfixture;
import android.app.*;
import android.os.*;
import android.content.*;
import android.net.Uri;
import android.view.*;
import android.widget.*;
import android.graphics.*;

/** Original deterministic verification app. Never shipped inside DroidBridge. */
public final class MainActivity extends Activity {
    static final String CHANNEL="verification", REPLY_KEY="verification_reply";
    private TextView receipt;
    private Runnable refresh;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private int generation;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        NotificationManager manager=getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL,"Companion verification",NotificationManager.IMPORTANCE_DEFAULT));
        ScrollView scroll=new ScrollView(this); LinearLayout box=new LinearLayout(this); box.setOrientation(1); box.setPadding(24,64,24,64); scroll.addView(box);
        TextView title=new TextView(this); title.setText("Companion boundary verification"); title.setTextSize(22); box.addView(title);
        receipt=new TextView(this); receipt.setTextSize(18); box.addView(receipt);
        add(box,"Allow test notifications",()->requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS},1));
        add(box,"Post public reply notification",()->post(true,true));
        add(box,"Post public non-reply notification",()->post(true,false));
        add(box,"Post private notification",()->post(false,true));
        add(box,"Replace reply notification",()->post(true,true));
        add(box,"Clear notifications",()->manager.cancelAll());
        add(box,"Share deterministic 2 MiB file",()->shareFile("sample.bin","application/octet-stream"));
        add(box,"Share deterministic image",()->shareFile("sample.png","image/png"));
        add(box,"Share slow 2 MiB stream",()->shareFile("slow.bin","application/octet-stream"));
        add(box,"Share text to companion",()->shareText("text/plain","DroidBridge phone share verification"));
        add(box,"Share HTTPS URL to companion",()->shareText("text/plain","https://example.com/droidbridge-verification"));
        add(box,"Start 60 Hz frame probe",()->setContentView(new FrameProbe(this)));
        setContentView(scroll);
        refresh=new Runnable(){public void run(){receipt.setText(getSharedPreferences("probe",0).getString("reply","No reply received")+"\nReply deliveries: "+getSharedPreferences("probe",0).getInt("deliveries",0)); handler.postDelayed(this,300);}};
        handler.post(refresh);
    }
    private void add(LinearLayout box,String label,Runnable action){Button button=new Button(this);button.setText(label);button.setMinHeight(60);button.setOnClickListener(v->action.run());box.addView(button);}
    private void post(boolean visible,boolean reply){
        generation++;
        Notification.Builder builder=new Notification.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle("Boundary notification "+generation).setContentText("Deterministic fixture generation "+generation).setVisibility(visible?Notification.VISIBILITY_PUBLIC:Notification.VISIBILITY_PRIVATE).setAutoCancel(false);
        if(reply){
            Intent intent=new Intent(this,ReplyReceiver.class).putExtra("generation",generation);
            PendingIntent pending=PendingIntent.getBroadcast(this,0,intent,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_MUTABLE);
            RemoteInput input=new RemoteInput.Builder(REPLY_KEY).setLabel("Fixture reply").build();
            builder.addAction(new Notification.Action.Builder(android.R.drawable.ic_menu_send,"Reply",pending).addRemoteInput(input).build());
        }
        getSystemService(NotificationManager.class).notify(42,builder.build());
    }
    private void shareFile(String name,String mime){
        Uri uri=Uri.parse("content://dev.droidbridge.companionfixture.files/"+name);
        Intent intent=new Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM,uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).setPackage("dev.droidbridge.companion");
        intent.setClipData(ClipData.newRawUri("Verification file",uri));startActivity(intent);
    }
    private void shareText(String mime,String text){startActivity(new Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_TEXT,text).setPackage("dev.droidbridge.companion"));}
    @Override protected void onDestroy(){handler.removeCallbacksAndMessages(null);super.onDestroy();}
    private static final class FrameProbe extends View implements Choreographer.FrameCallback {
        long frames; final Paint paint=new Paint(); boolean attached;
        FrameProbe(Context c){super(c);setOnClickListener(v->{frames+=1000;invalidate();});}
        @Override protected void onAttachedToWindow(){super.onAttachedToWindow();attached=true;Choreographer.getInstance().postFrameCallback(this);}
        @Override protected void onDetachedFromWindow(){attached=false;Choreographer.getInstance().removeFrameCallback(this);super.onDetachedFromWindow();}
        public void doFrame(long time){if(attached){frames++;invalidate();Choreographer.getInstance().postFrameCallback(this);}}
        @Override protected void onDraw(Canvas canvas){canvas.drawColor(Color.rgb((int)(frames*3%255),80,180));paint.setColor(Color.WHITE);paint.setTextSize(42);canvas.drawText("Frames "+frames+" display "+getDisplay().getDisplayId(),24,150,paint);}
    }
}
