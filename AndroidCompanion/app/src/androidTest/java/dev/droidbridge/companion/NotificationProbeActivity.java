package dev.droidbridge.companion;
import android.app.*;
import android.content.*;
import android.net.Uri;
import android.os.Bundle;
import java.util.*;
/** Test APK only: ordinary separate UID posts synthetic notifications; exact nonce read grant. */
public final class NotificationProbeActivity extends Activity {
    static final String CHANNEL="droidbridge-notification-regression";
    @Override public void onCreate(Bundle state){super.onCreate(state);
        String token=getIntent().getStringExtra("token"),mode=getIntent().getStringExtra("mode");
        if(token==null||!UUID.fromString(token).toString().equals(token)||!Arrays.asList("public","private","ongoing","cancel").contains(mode)){finish();return;}
        int generation=getIntent().getIntExtra("generation",1);if(generation<1||generation>1000){finish();return;}
        grantUriPermission("dev.droidbridge.companion",Uri.parse("content://dev.droidbridge.companion.test.staging/notification-status/"+token),Intent.FLAG_GRANT_READ_URI_PERMISSION);
        NotificationManager manager=getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL,"Synthetic notification regression",NotificationManager.IMPORTANCE_LOW));
        int id=token.hashCode()&0x7fffffff;
        getSharedPreferences("notification-probe-"+token,0).edit().putInt("posted_generation",generation).commit();
        if(mode.equals("cancel")){manager.cancel(id);finish();return;}
        Intent reply=new Intent(this,NotificationProbeReceiver.class).putExtra("token",token).putExtra("generation",generation);
        PendingIntent pending=PendingIntent.getBroadcast(this,id+generation,reply,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_MUTABLE);
        Notification.Action action=new Notification.Action.Builder(android.R.drawable.ic_menu_send,"Synthetic reply",pending)
            .addRemoteInput(new RemoteInput.Builder("probe_reply").setLabel("Synthetic reply").build()).build();
        Notification notification=new Notification.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Notification probe "+generation).setContentText("Synthetic "+mode+" generation "+generation)
            .setVisibility(mode.equals("private")?Notification.VISIBILITY_PRIVATE:Notification.VISIBILITY_PUBLIC)
            .setOngoing(mode.equals("ongoing")).addAction(action).build();
        manager.notify(id,notification);finish();
    }
}
