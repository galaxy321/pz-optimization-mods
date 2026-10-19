package pzmod.tgcapture;

import java.nio.ByteBuffer;

import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL15;
import org.lwjgl.opengl.GL21;
import org.lwjgl.opengl.GL30;
import org.lwjgl.system.MemoryUtil;
import org.lwjglx.opengl.Display;
import zombie.core.Core;
import zombie.core.textures.TextureFBO;

// The OpenGL reads; render thread only. Every bit of state touched is put back.
public final class Gl {
    private Gl() {}

    public static boolean minimised() {
        try {
            return GLFW.glfwGetWindowAttrib(Display.getWindow(), GLFW.GLFW_ICONIFIED) != 0;
        } catch (Throwable e) {
            return false;
        }
    }

    /** The world the game drew this frame, from its offscreen buffer (player 0). */
    public static Images.Pixels readWorld() {
        Core c = Core.getInstance();
        TextureFBO fbo = c.getOffscreenBuffer(0);
        if (fbo == null) throw new IllegalStateException("the game has no offscreen buffer (it draws the world straight to the screen)");
        int w = Math.min(c.getOffscreenWidth(0), fbo.getWidth()), h = Math.min(c.getOffscreenHeight(0), fbo.getHeight());
        if (w <= 0 || h <= 0) throw new IllegalStateException("offscreen buffer is " + w + "x" + h);
        int prev = GL11.glGetInteger(GL30.GL_READ_FRAMEBUFFER_BINDING);
        try {
            TextureFBO.getFuncs().glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, fbo.getBufferId());
            return read(w, h);
        } finally {
            TextureFBO.getFuncs().glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, prev);
        }
    }

    /** The frame about to be shown (call just before the swap). */
    public static Images.Pixels readBack() {
        int w = Display.getWidth(), h = Display.getHeight();
        if (w <= 0 || h <= 0) throw new IllegalStateException("the window is " + w + "x" + h + " (minimised)");
        int prevFb = GL11.glGetInteger(GL30.GL_READ_FRAMEBUFFER_BINDING);
        GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, 0);
        int prevBuf = GL11.glGetInteger(GL11.GL_READ_BUFFER);
        try {
            GL11.glReadBuffer(GL11.GL_BACK);
            return read(w, h);
        } finally {
            GL11.glReadBuffer(prevBuf);
            GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, prevFb);
        }
    }

    private static Images.Pixels read(int w, int h) {
        int prevAlign = GL11.glGetInteger(GL11.GL_PACK_ALIGNMENT);
        ByteBuffer b = MemoryUtil.memAlloc(w * h * 4);
        try {
            GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, 1);
            GL11.glReadPixels(0, 0, w, h, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, b);
            byte[] a = new byte[w * h * 4];
            b.get(a);
            return new Images.Pixels(w, h, a);
        } finally {
            MemoryUtil.memFree(b);
            GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, prevAlign);
        }
    }

    // ---- 1.0.2 film mode: render thread only ----
    // Three pixel-buffer objects in turn: this frame is read into one (glReadPixels into the bound
    // PBO returns at once), and the one read two film frames ago is mapped, copied into a pooled
    // array of the film's writer and unmapped, by then without waiting for the GPU. A frame the
    // writer has no array for is dropped without mapping. If the PBOs fail (an exception or a GL
    // error), the film goes on with a plain glReadPixels into a direct buffer, which waits for it.

    static final int PBOS = 3;
    private static int[] pbo;
    private static final int[] pboBytes = new int[PBOS], slotW = new int[PBOS], slotH = new int[PBOS];
    private static final long[] slotMs = new long[PBOS];
    private static final String[] slotTag = new String[PBOS];
    private static final boolean[] slotFull = new boolean[PBOS];
    private static int slot;
    private static Object owner;
    private static ByteBuffer plain;
    private static volatile String fallback = "";
    private static volatile boolean pbosMade;

    static String filmMode() { return !fallback.isEmpty() ? "plain glReadPixels (PBOs failed: " + fallback + ")" : pbosMade ? PBOS + " PBOs" : "PBOs not made yet"; }
    static String filmFallback() { return fallback; }

    /** One film frame from the back buffer (call just before the swap). */
    static void filmFrame(Film.Session s, String tag, long ms) {
        int w = Display.getWidth(), h = Display.getHeight();
        if (w <= 0 || h <= 0) { s.stats.skipped(tag); return; }
        if (owner != s) { java.util.Arrays.fill(slotFull, false); owner = s; }   // a new film: the old frames are not its
        if (fallback.isEmpty()) {
            try {
                pboFrame(s.writer, w, h, ms, tag);
                return;
            } catch (Throwable e) {
                fallback = e.getClass().getSimpleName() + ": " + e.getMessage();
                releasePbos();
            }
        }
        plainFrame(s.writer, w, h, ms, tag);
    }

    /** At filmStop: the frames still in the PBOs go to the writer, oldest first; then they are freed. */
    static void filmFlush(Film.Session s) {
        if (pbo != null && owner == s) {
            int prevPack = GL11.glGetInteger(GL21.GL_PIXEL_PACK_BUFFER_BINDING);
            try {
                for (int i = 0; i < PBOS; i++) {
                    int k = (slot + i) % PBOS;
                    if (slotFull[k]) handOff(k, s.writer);
                }
            } catch (Throwable e) {
                Capture.failed(e);
            } finally {
                GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, prevPack);
            }
        }
        releasePbos();
        if (plain != null) { MemoryUtil.memFree(plain); plain = null; }
        owner = null;
    }

    private static void pboFrame(Film.Writer wr, int w, int h, long ms, String tag) {
        if (pbo == null) {
            pbo = new int[PBOS];
            for (int i = 0; i < PBOS; i++) { pbo[i] = GL15.glGenBuffers(); pboBytes[i] = 0; slotFull[i] = false; }
            pbosMade = true;
        }
        drainErrors();
        int prevFb = GL11.glGetInteger(GL30.GL_READ_FRAMEBUFFER_BINDING);
        GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, 0);
        int prevBuf = GL11.glGetInteger(GL11.GL_READ_BUFFER);
        int prevPack = GL11.glGetInteger(GL21.GL_PIXEL_PACK_BUFFER_BINDING);
        int prevAlign = GL11.glGetInteger(GL11.GL_PACK_ALIGNMENT);
        try {
            GL11.glReadBuffer(GL11.GL_BACK);
            GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, 1);
            int k = slot, bytes = w * h * 4;
            GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, pbo[k]);
            if (pboBytes[k] != bytes) { GL15.glBufferData(GL21.GL_PIXEL_PACK_BUFFER, bytes, GL15.GL_STREAM_READ); pboBytes[k] = bytes; }
            GL11.glReadPixels(0, 0, w, h, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, 0L);
            check("glReadPixels into a PBO");
            slotFull[k] = true; slotW[k] = w; slotH[k] = h; slotMs[k] = ms; slotTag[k] = tag;
            slot = (k + 1) % PBOS;                  // the oldest, read two film frames ago
            if (slotFull[slot]) handOff(slot, wr);
        } finally {
            GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, prevPack);
            GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, prevAlign);
            GL11.glReadBuffer(prevBuf);
            GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, prevFb);
        }
    }

    /** Maps PBO k, copies it into an array from the writer's pool and hands it over. */
    private static void handOff(int k, Film.Writer wr) {
        slotFull[k] = false;
        int bytes = slotW[k] * slotH[k] * 4;
        byte[] b = wr.borrow(bytes);
        if (b == null) { wr.dropped(slotTag[k]); return; }
        boolean given = false;
        GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, pbo[k]);
        try {
            ByteBuffer m = GL15.glMapBuffer(GL21.GL_PIXEL_PACK_BUFFER, GL15.GL_READ_ONLY, bytes, null);
            if (m == null) { check("glMapBuffer"); throw new IllegalStateException("glMapBuffer gave nothing"); }
            try {
                m.get(b, 0, bytes);
            } finally {
                GL15.glUnmapBuffer(GL21.GL_PIXEL_PACK_BUFFER);
            }
            check("glMapBuffer");
            given = true;
            wr.submit(b, slotW[k], slotH[k], slotMs[k], slotTag[k]);
        } finally {
            if (!given) wr.giveBack(b);
        }
    }

    private static void plainFrame(Film.Writer wr, int w, int h, long ms, String tag) {
        int bytes = w * h * 4;
        byte[] b = wr.borrow(bytes);
        if (b == null) { wr.dropped(tag); return; }
        boolean given = false;
        if (plain == null || plain.capacity() < bytes) {
            if (plain != null) MemoryUtil.memFree(plain);
            plain = MemoryUtil.memAlloc(bytes);
        }
        int prevFb = GL11.glGetInteger(GL30.GL_READ_FRAMEBUFFER_BINDING);
        GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, 0);
        int prevBuf = GL11.glGetInteger(GL11.GL_READ_BUFFER);
        int prevPack = GL11.glGetInteger(GL21.GL_PIXEL_PACK_BUFFER_BINDING);
        int prevAlign = GL11.glGetInteger(GL11.GL_PACK_ALIGNMENT);
        try {
            if (prevPack != 0) GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, 0);   // or the read would go into that buffer
            GL11.glReadBuffer(GL11.GL_BACK);
            GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, 1);
            plain.clear().limit(bytes);
            GL11.glReadPixels(0, 0, w, h, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, plain);
            plain.get(b, 0, bytes);
            given = true;
            wr.submit(b, w, h, ms, tag);
        } finally {
            if (!given) wr.giveBack(b);
            if (prevPack != 0) GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, prevPack);
            GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, prevAlign);
            GL11.glReadBuffer(prevBuf);
            GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, prevFb);
        }
    }

    private static void releasePbos() {
        if (pbo == null) return;
        try {
            for (int id : pbo) GL15.glDeleteBuffers(id);
        } catch (Throwable e) { /* the context is going */ }
        pbo = null;
        java.util.Arrays.fill(slotFull, false);
    }

    // Errors the game left pending would be taken for ours; they are cleared first (the game does not read them).
    private static void drainErrors() {
        for (int i = 0; i < 16 && GL11.glGetError() != GL11.GL_NO_ERROR; i++) { /* cleared */ }
    }

    private static void check(String what) {
        int e = GL11.glGetError();
        if (e != GL11.GL_NO_ERROR) throw new IllegalStateException(what + ": GL error 0x" + Integer.toHexString(e));
    }
}
