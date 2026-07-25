package org.beetlebug.lookout;

import org.libsdl.app.SDLActivity;

// The app's Activity — a thin SDLActivity subclass so the app is branded
// (org.beetlebug.lookout / "Lookout Marine") rather than org.libsdl.app.
// SDLActivity loads the native libraries below and calls SDL_main in libmain.so.
public class LookoutActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL3", "main" };
    }
}
