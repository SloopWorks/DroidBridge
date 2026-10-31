package dev.droidbridge.companion;
import android.app.RemoteInput;
import android.content.*;
import java.util.UUID;
/** Test APK only; counts actual RemoteInput deliveries without storing or logging text. */
public final class NotificationProbeReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context,Intent intent){
        String token=intent.getStringExtra("token");if(token==null||!UUID.fromString(token).toString().equals(token)||RemoteInput.getResultsFromIntent(intent)==null)return;
        android.content.SharedPreferences state=context.getSharedPreferences("notification-probe-"+token,0);
        state.edit().putInt("deliveries",state.getInt("deliveries",0)+1).putInt("reply_generation",intent.getIntExtra("generation",0)).commit();
    }
}
