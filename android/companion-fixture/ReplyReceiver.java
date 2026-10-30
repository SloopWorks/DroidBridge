package dev.droidbridge.companionfixture;
import android.content.*;
import android.app.RemoteInput;
import android.os.Bundle;
import android.util.Log;
public final class ReplyReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context,Intent intent){
        Bundle results=RemoteInput.getResultsFromIntent(intent); if(results==null)return;
        CharSequence value=results.getCharSequence(MainActivity.REPLY_KEY); if(value==null)return;
        android.content.SharedPreferences prefs=context.getSharedPreferences("probe",0);
        int deliveries=prefs.getInt("deliveries",0)+1;
        prefs.edit().putString("reply",value.toString()).putInt("deliveries",deliveries).commit();
        Log.i("DroidBridgeCompanionFixture","reply_deliveries="+deliveries+" generation="+intent.getIntExtra("generation",-1)+" text="+value);
    }
}
