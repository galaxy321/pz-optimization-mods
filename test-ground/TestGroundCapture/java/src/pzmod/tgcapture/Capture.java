package pzmod.tgcapture;

import java.awt.image.BufferedImage;
import java.io.File;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

// One screenshot at a time. Lua's request() queues a call on the render thread, which runs after
// a frame has been shown: it reads the world there, and leaves the back read for the next frame's
// swap (beforeSwap, from the patch). Pixels are copied off the GPU on the render thread; the PNG
// is made and written on a daemon thread.
public final class Capture {
    private Capture() {}

    static final class Job {
        final String name, mode;
        final int screenW, screenH;
        final long t = System.currentTimeMillis();
        Job(String name, String mode, int w, int h) { this.name = cleanName(name); this.mode = mode; this.screenW = w; this.screenH = h; }
    }

    public static volatile String last = "none yet";
    static volatile Job queued, pendingBack;
    static volatile long swaps, backShots, worldShots, failures;
    static volatile String lastError = "";
    static volatile Images.Overlay overlay;
    static Images.Overlay building;
    static volatile long overlayUntil;
    static int lastWorldPrint;
    static final long EXPIRE_MS = 3000;
    static final ExecutorService WRITER = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "TGCapture-writer");
        t.setDaemon(true);
        return t;
    });

    public static boolean busy() {
        long now = System.currentTimeMillis();
        Job b = pendingBack;
        if (b != null && now - b.t > EXPIRE_MS) {
            pendingBack = null;
            last = b.name + ": back NOT captured, no frame was shown in " + EXPIRE_MS / 1000 + " s (" +
                (swaps == 0 ? "the swap patch never ran" : "the game stopped showing frames") + ")";
        }
        Job q = queued;
        if (q != null && now - q.t > EXPIRE_MS) {
            queued = null;
            last = q.name + ": NOT captured, the render thread didn't pick it up in " + EXPIRE_MS / 1000 + " s";
        }
        return pendingBack != null || queued != null;
    }

    // 1.0.1 (review of 18 Oct): the name from Lua becomes a plain file name in the Screenshots folder,
    // never a path: only letters, digits, '.', '_' and '-', no leading dot, at most 120 characters
    static String cleanName(String name) {
        String n = name == null ? "" : name;
        if (n.toLowerCase().endsWith(".png")) n = n.substring(0, n.length() - 4);
        StringBuilder b = new StringBuilder();
        for (char c : n.toCharArray()) b.append((c < 128 && (Character.isLetterOrDigit(c) || c == '.' || c == '_' || c == '-')) ? c : '_');
        String s = b.toString().replaceAll("^\\.+", "").replace("..", "_");
        if (s.length() > 120) s = s.substring(0, 120);
        return s.isEmpty() ? "TestGroundCapture" : s;
    }

    public static boolean request(String name, String mode) {
        if (busy()) return false;
        String m = mode == null ? "auto" : mode.toLowerCase();
        if (!m.equals("back") && !m.equals("world") && !m.equals("both")) m = "auto";
        int w = 0, h = 0;
        try {
            w = zombie.core.Core.getInstance().getScreenWidth();
            h = zombie.core.Core.getInstance().getScreenHeight();
        } catch (Throwable e) { /* the picture keeps its own size */ }
        Job j = new Job(name, m, w, h);
        overlayUntil = System.currentTimeMillis() + 1500;
        queued = j;
        zombie.core.opengl.RenderThread.queueInvokeOnRenderContext(() -> {
            try {
                onRender(j);
            } catch (Throwable e) {
                failed(e);
            } finally {
                if (queued == j) queued = null;
            }
        });
        return true;
    }

    static void onRender(Job j) {
        boolean min = Gl.minimised();
        boolean world = j.mode.equals("world") || j.mode.equals("both") || (j.mode.equals("auto") && min);
        boolean back = j.mode.equals("back") || j.mode.equals("both") || (j.mode.equals("auto") && !min);
        if (world) {
            Images.Pixels p;
            try {
                p = Gl.readWorld();
            } catch (Throwable e) {
                note(j.name + ": world NOT captured: " + e.getMessage());
                p = null;
            }
            if (p != null) write(j, p, j.mode.equals("both") ? "_world" : "", overlay, true, min);
        }
        if (back) {
            if (min) note(j.name + ": back NOT captured: the window is minimised" + (world ? "" : " (use capture = world or auto)"));
            else pendingBack = j;
        }
    }

    // A still and a film frame on the same swap: the still first (1.0.2). A failing still never
    // stops the film's frame.
    public static void beforeSwap() {
        swaps++;
        try {
            backStill();
        } catch (Throwable e) {
            failed(e);
        }
        Film.onSwap();
    }

    static void backStill() {
        Job j = pendingBack;
        if (j == null) return;
        pendingBack = null;
        Images.Pixels p;
        try {
            p = Gl.readBack();
        } catch (Throwable e) {
            note(j.name + ": back NOT captured: " + e.getMessage());
            return;
        }
        write(j, p, "", null, false, false);
    }

    static void write(Job j, Images.Pixels p, String suffix, Images.Overlay ov, boolean isWorld, boolean min) {
        int print = isWorld ? Images.fingerprint(p) : 0;
        boolean same = isWorld && print == lastWorldPrint && worldShots > 0;
        if (isWorld) lastWorldPrint = print;
        WRITER.submit(() -> {
            try {
                BufferedImage img = Images.compose(p, isWorld ? j.screenW : 0, isWorld ? j.screenH : 0, ov);
                String base = j.name;
                File f = new File(zombie.ZomboidFileSystem.instance.getScreenshotDir(), base + suffix + ".png");
                Images.writePng(img, f);
                double lit = Images.litShare(img);
                if (isWorld) worldShots++; else backShots++;
                note(String.format("%s: %s %dx%d%s, %.0f%% lit%s%s%s", f.getName(), isWorld ? "world" : "back", img.getWidth(), img.getHeight(),
                    isWorld ? " (from " + p.w + "x" + p.h + ")" : "", lit * 100, lit < 0.01 ? " BLANK" : "",
                    same ? ", world UNCHANGED since the last shot" : "", min ? ", window minimised" : ""));
            } catch (Throwable e) {
                failed(e);
            }
        });
    }

    static void note(String s) { last = s; }

    public static void failed(Throwable e) {
        failures++;
        lastError = e.getClass().getSimpleName() + ": " + e.getMessage();
        last = "failed: " + lastError;
    }

    public static String status() {
        return String.format("TestGroundCapture %s: swap patch %s (%d frames), %d back and %d world shots, %d failures%s; last: %s",
            TGCapture.VERSION, swaps > 0 ? "active" : "NOT active", swaps, backShots, worldShots, failures,
            lastError.isEmpty() ? "" : " (" + lastError + ")", last) + "; " + Film.status();
    }

    // The overlay: Lua sends it each frame while wantsOverlay(); a capture uses the last whole one.
    public static boolean wantsOverlay() { return System.currentTimeMillis() < overlayUntil; }
    public static void beginOverlay() { building = new Images.Overlay(); }
    public static void rect(float x, float y, float w, float h, float r, float g, float b, float a) {
        Images.Overlay o = building;
        if (o != null && o.rects.size() < 20000) o.rects.add(new float[] { x, y, w, h, r, g, b, a });
    }
    public static void text(float x, float y, String s, float r, float g, float b) {
        Images.Overlay o = building;
        if (o != null && o.texts.size() < 200) o.texts.add(new Object[] { s, new float[] { x, y, r, g, b } });
    }
    public static void endOverlay() {
        if (building != null) overlay = building;
        building = null;
    }
}
