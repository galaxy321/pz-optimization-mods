package pzmod.tgcapture;

import me.zed_0xff.zombie_buddy.Patch;

// The advice body is copied into Display, so what it calls must be public, and it catches
// everything so a mistake here can't stop the game's frame from being shown.
public class Patches {
    @Patch(className = "org.lwjglx.opengl.Display", methodName = "swapBuffers")
    public static class Patch_swapBuffers {
        @Patch.OnEnter
        public static void enter() {
            try {
                Capture.beforeSwap();
            } catch (Throwable e) {
                Capture.failed(e);
            }
        }
    }
}
