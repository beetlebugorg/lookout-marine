package org.beetlebug.lookout;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * The app: a plain Activity hosting a LookoutView — the Java shell owns the
 * Activity, the Surface and all gestures; the Zig core renders the chart into
 * the Surface via Vulkan (the exact Android analogue of the iOS app's SwiftUI
 * shell around the Metal core).
 *
 * The chart ships in the APK assets and is copied to internal storage once
 * (tile57 opens it by path / mmap, which can't read an APK asset directly).
 */
public class LookoutActivity extends Activity {
    private static final String TAG = "lookout";
    private static final String CHART_ASSET = "charts/US5MD1MC.pmtiles";
    private static final String CHART_NAME = "US5MD1MC.pmtiles";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        String chart = extractAsset(CHART_ASSET, CHART_NAME);
        if (chart == null) {
            Log.e(TAG, "chart asset extraction failed");
            finish();
            return;
        }
        setContentView(new LookoutView(this, chart));
    }

    /** Copy an APK asset to internal storage (skipped when already current). */
    private String extractAsset(String asset, String outName) {
        File out = new File(getFilesDir(), outName);
        try {
            long assetLen;
            try (InputStream in = getAssets().open(asset)) {
                assetLen = in.available();
            }
            if (out.length() != assetLen || assetLen == 0) {
                try (InputStream in = getAssets().open(asset);
                     OutputStream os = new FileOutputStream(out)) {
                    byte[] buf = new byte[1 << 16];
                    int n;
                    while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
                }
                Log.i(TAG, "chart extracted -> " + out + " (" + out.length() + " bytes)");
            }
            return out.getAbsolutePath();
        } catch (Exception e) {
            Log.e(TAG, "asset extract: " + e);
            return null;
        }
    }
}
