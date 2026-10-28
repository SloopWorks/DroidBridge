package dev.droidbridge.icons;

import android.content.Context;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import java.io.FileOutputStream;
import java.lang.reflect.Method;

/** Runs as the already-authorized adb shell, without installing an Android app. */
public final class IconHelper {
    public static void main(String[] args) {
        try {
            if (args.length != 2 || !args[0].matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")
                    || args[0].length() > 255
                    || !args[1].matches("/data/local/tmp/droidbridge-icon-[a-f0-9-]+\\.png")) {
                throw new IllegalArgumentException("Invalid icon request");
            }
            Looper.prepareMainLooper();
            // app_process has no Application. Bootstrap the framework's normal
            // system Context, then attribute PackageManager calls to shell UID.
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Method systemMain = activityThread.getDeclaredMethod("systemMain");
            Object thread = systemMain.invoke(null);
            Context system = (Context) activityThread.getDeclaredMethod("getSystemContext").invoke(thread);
            Context shell = system.createPackageContext("com.android.shell", 0);
            PackageManager pm = shell.getPackageManager();
            // getLaunchIntentForPackage prefers CATEGORY_INFO, which may carry
            // an entirely different icon from the phone launcher's MAIN entry.
            Intent preferred = pm.getLaunchIntentForPackage(args[0]);
            ComponentName preferredComponent = preferred == null ? null : preferred.getComponent();
            ResolveInfo resolved = null;
            String chosen = null;
            Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(args[0]);
            for (ResolveInfo candidate : pm.queryIntentActivities(launcher, 0)) {
                if (candidate.activityInfo == null || !args[0].equals(candidate.activityInfo.packageName)) continue;
                ComponentName component = new ComponentName(candidate.activityInfo.packageName, candidate.activityInfo.name);
                if (component.equals(preferredComponent)) { resolved = candidate; break; }
                String key = component.flattenToString();
                if (chosen == null || key.compareTo(chosen) < 0) { resolved = candidate; chosen = key; }
            }
            if (resolved == null) {
                Intent leanback = pm.getLeanbackLaunchIntentForPackage(args[0]);
                if (leanback != null) resolved = pm.resolveActivity(leanback, 0);
            }
            if (resolved == null || resolved.activityInfo == null
                    || !args[0].equals(resolved.activityInfo.packageName)) {
                throw new IllegalStateException("Cannot resolve launcher for " + args[0]);
            }
            Drawable icon = resolved.loadIcon(pm);
            if (icon == null) throw new IllegalStateException("Launcher icon unavailable for " + args[0]);
            Bitmap bitmap = Bitmap.createBitmap(512, 512, Bitmap.Config.ARGB_8888);
            icon.setBounds(0, 0, 512, 512);
            icon.draw(new Canvas(bitmap));
            try (FileOutputStream out = new FileOutputStream(args[1])) {
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                    throw new IllegalStateException("PNG encoding failed");
                }
            }
            System.out.println("DROIDBRIDGE_ICON_OK " + resolved.activityInfo.name + " " + icon.getClass().getName());
        } catch (Throwable error) {
            error.printStackTrace(System.err);
            System.exit(1);
        }
    }
}
