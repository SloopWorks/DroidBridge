package dev.droidbridge.companion;

import android.app.Activity;
import android.appwidget.AppWidgetHost;
import android.appwidget.AppWidgetHostView;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProviderInfo;
import android.content.ComponentName;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Real system widget host, test APK only. Grant bind only to this exact test package. */
public final class PlatformWidgetHostActivity extends Activity {
    private AppWidgetHost host;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String target = getIntent().getStringExtra("target_package");
        if (!"dev.droidbridge.companion".equals(target) && !"dev.droidbridge.companion.dev".equals(target)) throw new IllegalArgumentException("Unexpected test target");
        host = new AppWidgetHost(this, 416001);
        if (getIntent().getBooleanExtra("cleanup", false)) { host.deleteHost(); finish(); return; }
        int id = host.allocateAppWidgetId();
        ComponentName provider = new ComponentName(target, "dev.droidbridge.companion.BridgeWidget");
        AppWidgetManager manager = getSystemService(AppWidgetManager.class);
        if (!manager.bindAppWidgetIdIfAllowed(id, provider)) { host.deleteAppWidgetId(id); throw new IllegalStateException("Grant appwidget bind to the test APK before launching this host"); }
        AppWidgetProviderInfo info = manager.getAppWidgetInfo(id);
        if (info == null) throw new IllegalStateException("System did not bind actual provider");
        LinearLayout content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL); content.setPadding(24, 48, 24, 24);
        TextView title = new TextView(this); title.setText("Actual system-bound DroidBridge widget"); title.setTextSize(18); content.addView(title);
        AppWidgetHostView view = host.createView(this, id, info); view.setAppWidget(id, info);
        content.addView(view, new LinearLayout.LayoutParams(-1, 820)); setContentView(content);
        Log.i("DroidBridgeWidgetProof", "BOUND widget=" + id + " provider=" + provider.flattenToString() + " host=" + getPackageName());
    }
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); if (intent.getBooleanExtra("cleanup", false)) { if (host != null) host.deleteHost(); finish(); } }
    @Override protected void onStart() { super.onStart(); if (host != null) host.startListening(); }
    @Override protected void onStop() { if (host != null) host.stopListening(); super.onStop(); }
    @Override protected void onDestroy() { if (host != null) { host.stopListening(); host.deleteHost(); } super.onDestroy(); }
}
