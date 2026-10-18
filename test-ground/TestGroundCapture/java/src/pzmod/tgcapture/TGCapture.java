package pzmod.tgcapture;

import me.zed_0xff.zombie_buddy.Exposer;

// Lua side (global TGCapture). request(name, mode) asks for one screenshot, written to
// Zomboid/Screenshots on a background thread; mode is "back", "world", "both" or "auto".
//   back:  the frame the game is about to show, read from the back buffer just before the game
//          swaps it to the screen (a patch on Display.swapBuffers). It has the whole UI. It does
//          not need the window in front, but a minimised window has no back buffer to read.
//   world: the game world from the offscreen buffer the game draws it into, scaled to the screen
//          size, with the overlay Lua sent (beginOverlay/rect/text/endOverlay) drawn on top. No UI.
//          Works while the window is minimised as long as the game still draws the world.
//   auto:  back while the window is on screen, world while it is minimised.
// The game's own takeScreenshot reads the front buffer: what is on the screen, so a covered or
// minimised window gives an empty picture (drive view run 2).
// 1.0.2 film mode, for the showcase film: frames from the back buffer at fps, scaled to width, as
// JPEGs in Zomboid/Lua/film/<runId>/000001.jpg ... with frames.txt ("<seq> <epoch ms> <tag> <file>").
//   filmStart(runId, fps, width) -> true, or false if a film is running or still stopping, or the folder can't be made
//                                   (filmStatus says why). fps 1..60, width 320..3840 (not above the window's).
//   filmTag(tag)    the tag of the frames read from now on (a step's tag, "gap"; "settle" at the start)
//   filmStop()      -> true if a film was running; returns at once (1.0.5). frames.txt is complete once
//                      filmStatus no longer says "stopping" (it then gives the reason, "stopped by filmStop")
//   filmStatus()    -> one line: state, frames written and queued, the read path, the folder
//   filmTake()      -> "film: N frames written, N dropped (writer behind), N skipped (window minimised),
//                      capture X ms per frame on the render thread (worst Y)" since the last take, then reset
//   filmTotal()     -> the same for the whole film
//   filmAlive()     -> true while a film runs. Test Ground's heartbeat (about once a second); 10 s
//                      without it or filmTag stops the film (1.0.3), as does leaving the world
//   filmMaxMinutes(m) -> the cap kept, 1..120 (20 by default); a film stops itself there, and under
//                      2 GB free disk. filmTotal ends with the reason a film stopped
//   filmQuality(q)  -> the JPEG quality kept for the next filmStart, 0.5..0.95 (0.85 by default) (1.0.4)
// 1.0.4: frames are written by Film.WRITERS (2) threads; filmStop waits (at most 3 s) for them.
// 1.0.5: filmStop no longer waits: the render thread flushes at its next frame and the writers finish
// on their own threads (a watchdog ends the film after 2 s without a render frame). A filmStart
// while the last film is still stopping is refused (filmStatus says so); Lua tries again later.
@Exposer.LuaClass
public class TGCapture {
    public static final String VERSION = "1.0.7";

    public static String version() { return VERSION; }
    public static boolean request(String name, String mode) { return Capture.request(name, mode); }
    public static String lastResult() { return Capture.last; }
    public static String status() { return Capture.status(); }
    public static boolean busy() { return Capture.busy(); }
    public static boolean wantsOverlay() { return Capture.wantsOverlay(); }
    public static void beginOverlay() { Capture.beginOverlay(); }
    public static void rect(double x, double y, double w, double h, double r, double g, double b, double a) {
        Capture.rect((float) x, (float) y, (float) w, (float) h, (float) r, (float) g, (float) b, (float) a);
    }
    public static void text(double x, double y, String s, double r, double g, double b) {
        Capture.text((float) x, (float) y, s, (float) r, (float) g, (float) b);
    }
    public static void endOverlay() { Capture.endOverlay(); }
    public static boolean filmStart(String runId, double fps, double width) { return Film.start(runId, (int) Math.round(fps), (int) Math.round(width)); }
    public static void filmTag(String tag) { Film.tag(tag); }
    public static boolean filmStop() { return Film.stop(); }
    public static String filmStatus() { return Film.status(); }
    public static String filmTake() { return Film.take(); }
    public static String filmTotal() { return Film.total(); }
    public static boolean filmAlive() { return Film.alive(); }
    public static double filmMaxMinutes(double minutes) { return Film.maxMinutes(minutes); }
    /**
     * Start a copy of Saves/<mode>/<src> to Saves/<mode>/<dst> on its own thread (1.0.7, Benchmark Save).
     * "" when it has started, else why not; then poll copySaveStatus(): copying N of M MB, done, or failed: why.
     */
    public static String copySaveStart(String mode, String src, String dst) {
        try {
            return SaveCopy.start(java.nio.file.Paths.get(zombie.ZomboidFileSystem.instance.getSaveDir()), mode, src, dst);
        } catch (Throwable t) {
            return "copy failed: " + t;
        }
    }
    public static String copySaveStatus() { return SaveCopy.status(); }
    public static double filmQuality(double q) { return Film.quality(q); }
}
