package dev.droidbridge.companionfixture;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Process;
import android.widget.TextView;
import java.io.InputStream;
import java.security.MessageDigest;

/** Separate ordinary app UID verifies real Android Sharesheet URI grants. Test-only. */
public final class ReceiveActivity extends Activity {
    private TextView result;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        result = new TextView(this); result.setTextSize(18); result.setPadding(24, 96, 24, 64);
        result.setText("External transfer verifier: reading"); setContentView(result);
        Intent request = getIntent();
        Uri shared = request.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class);
        String probe = request.getStringExtra("probe_uri");
        final Uri uri = shared != null ? shared : probe == null ? null : Uri.parse(probe);
        new Thread(() -> {
            String receipt = "External UID: " + Process.myUid() + "\n";
            try {
                if (uri == null || !"content".equals(uri.getScheme()) ||
                    !("dev.droidbridge.companion.transfers".equals(uri.getAuthority()) ||
                      "dev.droidbridge.companion.dev.transfers".equals(uri.getAuthority()))) {
                    throw new IllegalArgumentException("Unsupported fixture URI");
                }
                boolean granted = checkUriPermission(uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED;
                MessageDigest digest = MessageDigest.getInstance("SHA-256"); long count = 0;
                try (InputStream input = getContentResolver().openInputStream(uri)) {
                    if (input == null) throw new IllegalStateException("Missing stream");
                    byte[] block = new byte[65536]; int length;
                    while ((length = input.read(block)) >= 0) {
                        count += length;
                        if (count > 50L * 1024 * 1024) throw new IllegalStateException("Fixture byte limit");
                        digest.update(block, 0, length);
                    }
                }
                StringBuilder hash = new StringBuilder();
                for (byte b : digest.digest()) hash.append(String.format("%02x", b & 255));
                receipt += "READ_OK\nGrant: " + granted + "\nBytes: " + count + "\nSHA256: " + hash;
            } catch (SecurityException denied) {
                receipt += "READ_REFUSED\nReason: SecurityException";
            } catch (Exception failure) {
                receipt += "READ_FAILED\nReason: " + failure.getClass().getSimpleName();
            }
            final String text = receipt;
            runOnUiThread(() -> result.setText(text));
        }, "ExternalTransferVerifier").start();
    }
}
