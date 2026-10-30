package dev.droidbridge.companion;
import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import java.util.UUID;
/** Test APK runs in its own UID without the target APK's Kotlin runtime. */
public final class StagingGrantActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String token=getIntent().getStringExtra("token");
        if(token==null || !UUID.fromString(token).toString().equals(token))throw new IllegalArgumentException("Invalid nonce");
        String[] paths={"stall/"+token+"/a","stall/"+token+"/b","small/"+token,"status/"+token,"cleanup/"+token};
        ClipData clip=null;
        for(String path:paths){
            Uri uri=Uri.parse("content://dev.droidbridge.companion.test.staging/"+path);
            grantUriPermission("dev.droidbridge.companion",uri,Intent.FLAG_GRANT_READ_URI_PERMISSION);
            if(clip==null)clip=ClipData.newRawUri("Synthetic transfer fixture",uri);else clip.addItem(new ClipData.Item(uri));
        }
        Intent target=new Intent(Intent.ACTION_MAIN).setClassName("dev.droidbridge.companion","dev.droidbridge.companion.MainActivity")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_ACTIVITY_NEW_TASK);
        target.setClipData(clip);startActivity(target);finish();
    }
}
