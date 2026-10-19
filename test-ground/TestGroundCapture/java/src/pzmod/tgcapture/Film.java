package pzmod.tgcapture;

import java.awt.image.BufferedImage;
import java.awt.image.DataBufferInt;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

// 1.0.2 film mode: frames for the showcase film, read from the back buffer just before each swap
// (after a still, when both land on the same swap) at the fps wanted by wall clock. The render
// thread only reads into pixel-buffer objects (Gl) and copies a mapped one from two frames back
// into a pooled array; one worker thread flips, scales, writes the JPEG and the frames.txt line.
// A full pool drops the frame and counts it; nothing here ever waits on the render thread.
// Lua (game thread) starts, tags and stops; the session and tag fields are volatile.
// 1.0.3 (review): a film also stops itself (Guard): 10 s without filmAlive or filmTag from Test
// Ground, 2 s out of the game (quit to the main menu), the length cap (filmMaxMinutes, 20 by
// default) or under 2 GB free under the film folder. filmTotal and filmStatus say why it stopped.
// 1.0.4: the one worker fell behind on the PC (4721 written, 1538 dropped at 30 fps, 1280 wide), so
// WRITERS threads now share a deeper queue (DEPTH 8, a pool of WRITERS + DEPTH + 1). seq is given
// when a frame is handed over, so a dropped frame leaves a gap in seq (and in the file names); each
// JPEG is written on its own and the frames.txt lines go through a small reorder buffer, in seq
// order. filmStop waited (bounded) for the writers to drain (not since 1.0.5). filmQuality sets the next film's JPEG
// quality.
// 1.0.5 (review): filmStop returns at once. Lua calls it on the game thread, and in the game the
// render thread didn't pick the stop up while 1.0.4's filmStop waited for it, so the game froze
// about 1 s and the last frames in the PBOs were lost. Now filmStop only marks the stop: the render
// thread flushes the PBOs at its next frame and hands the film to the writers, which drain and close
// frames.txt on their own threads (at most DRAIN_MS, then what is left is dropped). If no render
// frame comes within PICKUP_MS (the game quit, say), a watchdog thread ends the film without the
// PBO frames. filmStatus says "stopping" until all of that is done, then the reason ("stopped by
// filmStop", ...). A filmStart while the last film is still stopping is refused, with the reason
// in filmStatus (Lua tries again); a film stuck stopping for ABANDON_MS is left to its threads.
// Every pooled array goes back exactly once (a JPEG that failed to write gave it back twice).
public final class Film {
    private Film() {}

    public static final int WRITERS = 2;          // writer threads (clamped 1..4)
    public static final int DEPTH = 8;            // frames waiting for the writers; + one being written per writer
    public static final float QUALITY = 0.85f;    // the default JPEG quality
    /** No render frame this long after filmStop: the watchdog ends the film (PBO frames lost). */
    public static final long PICKUP_MS = 2000;
    /** The writers' time to write what is queued once the film is ended; then the rest is dropped. */
    public static final long DRAIN_MS = 3000;
    /** A film still stopping this long after its stop no longer holds up filmStart. */
    public static final long ABANDON_MS = 10_000;

    /** One film: the writers and its counters. Made on the game thread, ended on the render thread. */
    static final class Session {
        final String runId;
        final int fps, width;
        final long intervalNs;
        final Writer writer;
        final Stats stats = new Stats();
        final Guard guard;
        long nextDue;                              // render thread only
        volatile boolean stop;
        volatile long stopAt;
        volatile String why = "";
        volatile boolean pboLost;                  // ended by the watchdog or filmStart, not the render thread
        final AtomicBoolean finished = new AtomicBoolean();
        Session(String runId, int fps, int width, Writer writer) {
            this.runId = runId; this.fps = fps; this.width = width; this.writer = writer;
            this.intervalNs = 1_000_000_000L / fps;
            this.guard = new Guard(System.currentTimeMillis(), maxMinutes);
        }
    }

    /** When a film has to stop by itself. The clock is passed in (FilmTest runs it on a made-up one). */
    public static final class Guard {
        public static final long QUIET_MS = 10_000, OUT_OF_GAME_MS = 2_000, MIN_FREE = 2L << 30;
        public static final int DISK_EVERY = 100;
        final long startMs;
        volatile long maxMs, wordMs;
        long outSince = -1;                         // render thread only
        public Guard(long now, double minutes) { startMs = now; wordMs = now; setMax(minutes); }
        public void setMax(double minutes) { maxMs = Math.round(minutes * 60_000); }
        /** filmAlive or filmTag came. */
        public void word(long now) { wordMs = now; }
        /** The reason the film must stop now, or null. */
        public String check(long now, boolean inGame) {
            if (now - wordMs >= QUIET_MS) return "stopped: no word from Test Ground for " + QUIET_MS / 1000 + " s";
            if (now - startMs >= maxMs) return String.format(java.util.Locale.ROOT, "stopped: reached the cap of %s minutes", minutes(maxMs));
            if (inGame) outSince = -1;
            else if (outSince < 0) outSince = now;
            else if (now - outSince >= OUT_OF_GAME_MS) return "stopped: the game left the world (quit to the main menu?)";
            return null;
        }
        /** Every DISK_EVERY frames written: the reason to stop when the film's disk is nearly full, or null. */
        public static String disk(int written, long usable) {
            if (written % DISK_EVERY != 0 || usable >= MIN_FREE) return null;
            return String.format(java.util.Locale.ROOT, "stopped: %.1f GB free under the film folder, under %d GB", usable / 1073741824.0, MIN_FREE >> 30);
        }
        static String minutes(long ms) {
            double m = ms / 60_000.0;
            return m == Math.rint(m) ? String.valueOf((long) m) : String.format(java.util.Locale.ROOT, "%.1f", m);
        }
    }

    static volatile double maxMinutes = 20;

    /** The length cap for this and later films, 1 to 120 minutes; gives the value kept. */
    public static double maxMinutes(double minutes) {
        double m = Double.isNaN(minutes) ? 20 : Math.max(1, Math.min(120, minutes));
        maxMinutes = m;
        Session s = cur;
        if (s != null) s.guard.setMax(m);
        return m;
    }

    static volatile double quality = 0.85;

    /** The JPEG quality for the next filmStart, 0.5 to 0.95 (0.85 by default); gives the value kept. */
    public static double quality(double q) {
        double v = Double.isNaN(q) ? 0.85 : Math.max(0.5, Math.min(0.95, q));
        quality = v;
        return v;
    }

    static volatile Session cur, ended;
    static volatile Thread renderThread;            // the thread onSwap last ran on
    static volatile String tag = "settle";
    static volatile String note = "no film yet";

    // ---- Lua side (game thread) ----

    public static boolean start(String runId, int fps, int width) {
        File root;
        try {
            root = new File(zombie.ZomboidFileSystem.instance.getCacheDirSub("Lua"), "film");
        } catch (Throwable e) {
            note = "filmStart failed: " + e.getClass().getSimpleName() + ": " + e.getMessage();
            return false;
        }
        return start(root, runId, fps, width);
    }

    /** filmStart with the film folder given (Zomboid/Lua/film in the game; FilmTest gives its own). */
    public static boolean start(File root, String runId, int fps, int width) {
        Session s = cur != null ? cur : ended;
        if (s != null && !done(s)) {
            if (!s.stop) { note = "filmStart refused: film " + s.runId + " is running (filmStop first)"; return false; }
            long t = System.currentTimeMillis() - s.stopAt;
            if (t < ABANDON_MS) {                   // never waits here: this is the game thread
                note = "filmStart refused: film " + s.runId + " is still stopping (" + t + " ms since its stop; try again when filmStatus no longer says stopping)";
                return false;
            }
            finish(s, true);                        // stuck: left to its own threads, in its own folder
        }
        fps = Math.max(1, Math.min(60, fps));
        width = Math.max(320, Math.min(3840, width));
        String id = Capture.cleanName(runId);
        try {
            File dir = new File(root, id);
            for (int n = 2; dir.exists(); n++) dir = new File(root, id + "_" + n);   // never mix two films
            Writer w = new Writer(dir, width, DEPTH, WRITERS, (float) quality, null);
            Session ns = new Session(dir.getName(), fps, width, w);
            w.stats = ns.stats;
            w.onEnd = () -> note = "film " + ns.runId + " " + (ns.why.isEmpty() ? "stopped" : ns.why) + ", frames.txt complete"
                + (ns.pboLost ? " (no render frame came within " + PICKUP_MS + " ms of the stop, so the frames still in the PBOs were lost)" : "");
            w.header("# TestGroundCapture " + TGCapture.VERSION + " film " + ns.runId + " " + fps + " fps " + width + " wide");
            tag = "settle";
            w.start();
            cur = ns;
            note = "film " + ns.runId + " started: " + fps + " fps, " + width + " wide, in " + dir;
            return true;
        } catch (Throwable e) {
            note = "filmStart failed: " + e.getClass().getSimpleName() + ": " + e.getMessage();
            return false;
        }
    }

    public static void tag(String t) { tag = cleanTag(t); alive(); }

    /** Test Ground's heartbeat, about once a second while the run goes on. */
    public static boolean alive() {
        Session s = cur;
        if (s == null || s.stop) return false;
        s.guard.word(System.currentTimeMillis());
        return true;
    }

    /** Stops taking frames and returns at once (1.0.5): the render thread flushes the PBOs at its
     *  next swap and hands the film to the writers, which write what is queued and close frames.txt
     *  on their own threads. If no render frame comes within PICKUP_MS, a watchdog ends the film
     *  without the PBO frames. filmStatus says "stopping" until frames.txt is complete. */
    public static boolean stop() {
        Session s = cur;
        if (s == null || !stopBy(s, "stopped by filmStop")) return false;
        if (Thread.currentThread() == renderThread) endOnRenderThread(s);   // Lua on the GL thread: flush here
        else watchdog(s);
        return true;
    }

    /** Ends the film without the render thread if it hasn't picked the stop up in PICKUP_MS. */
    private static void watchdog(Session s) {
        Thread t = new Thread(() -> {
            try {
                while (!s.finished.get() && System.currentTimeMillis() - s.stopAt < PICKUP_MS) Thread.sleep(20);
            } catch (InterruptedException e) { /* end it now */ }
            finish(s, true);
        }, "TGCapture-film-watchdog");
        t.setDaemon(true);
        t.start();
    }

    /** Stopped, ended and frames.txt closed. */
    static boolean done(Session s) { return s.stop && s.finished.get() && s.writer.finished(); }

    /** Marks the film stopping; false if it already was (the game thread and the render thread can
     *  both try: only the first reason counts). */
    static boolean stopBy(Session s, String why) {
        synchronized (s) {
            if (s.stop) return false;
            s.why = why;
            s.stopAt = System.currentTimeMillis();
            s.stop = true;
        }
        note = "film " + s.runId + " stopping (" + why + ")";
        return true;
    }

    /** The current film's writer, else the last one's, or null (for FilmTest). */
    public static Writer writer() {
        Session s = cur != null ? cur : ended;
        return s == null ? null : s.writer;
    }

    public static String take() {
        Session s = cur != null ? cur : ended;
        return s == null ? "film: no film" : s.stats.take() + extra(s);
    }

    public static String total() {
        Session s = cur != null ? cur : ended;
        return s == null ? "film: no film" : s.stats.total() + extra(s) + (s.why.isEmpty() ? "" : "; " + s.why);
    }

    public static String status() {
        Session s = cur != null ? cur : ended;
        if (s == null) return "film: " + note;
        Writer w = s.writer;
        String state = !s.stop ? "running" : !done(s) ? "stopping" : s.why.isEmpty() ? "stopped" : s.why;
        return String.format(java.util.Locale.ROOT, "film %s %s: %d fps, %d wide, quality %.2f, %s, %d written, %d queued, %d writers %.1f ms per frame each%s; %s; %s",
            s.runId, state, s.fps, s.width, w.quality, Gl.filmMode(), w.written(), w.queued(), w.writers, w.msPerFrame(),
            w.error.isEmpty() ? "" : ", writer error " + w.error, w.dir, note);
    }

    private static String extra(Session s) {
        String f = Gl.filmFallback();
        return f.isEmpty() ? "" : " (plain glReadPixels: " + f + ")";
    }

    /** A tag is one word in frames.txt: white space becomes '_', and none is "none". */
    public static String cleanTag(String t) {
        String s = t == null ? "" : t.trim().replaceAll("\\s+", "_");
        if (s.length() > 80) s = s.substring(0, 80);
        return s.isEmpty() ? "none" : s;
    }

    // ---- render thread (Capture.beforeSwap) ----

    public static void onSwap() {
        renderThread = Thread.currentThread();
        Session s = cur;
        if (s == null) return;
        if (!s.stop) {
            String why = s.guard.check(System.currentTimeMillis(), inGame());
            if (why == null) why = s.writer.stopWhy;
            if (why != null) stopBy(s, why);
        }
        if (s.stop) {
            endOnRenderThread(s);
            return;
        }
        long now = System.nanoTime();
        if (s.nextDue != 0 && now < s.nextDue) return;
        // the wanted rate on average; a game slower than that gives every frame
        s.nextDue = (s.nextDue == 0 || now - s.nextDue > s.intervalNs) ? now + s.intervalNs : s.nextDue + s.intervalNs;
        String t = tag;
        if (Gl.minimised()) { s.stats.skipped(t); return; }
        long t0 = System.nanoTime();
        try {
            Gl.filmFrame(s, t, System.currentTimeMillis());
        } finally {
            s.stats.cost(t, System.nanoTime() - t0);
        }
    }

    private static void endOnRenderThread(Session s) {
        if (s.finished.get()) return;
        try {
            Gl.filmFlush(s);
        } finally {
            finish(s, false);
        }
    }

    /** Ends a stopped film once: no more frames, and the writers finish on their own threads (the
     *  render thread after its flush, or the watchdog / filmStart without it: pboLost). Never waits. */
    private static boolean finish(Session s, boolean pboLost) {
        if (!s.finished.compareAndSet(false, true)) return false;
        s.pboLost = pboLost;
        ended = s;
        if (cur == s) cur = null;
        note = "film " + s.runId + " stopping (" + s.why + "): the writers are writing the last frames";
        s.writer.close();                           // may end it here (onEnd) when no writer ran
        return true;
    }

    // Out of the world (the main menu, say) when the game's state isn't IngameState; a read of two
    // fields, from the render thread. If it can't be told, the heartbeat is left to do it.
    private static boolean inGame() {
        try {
            zombie.gameStates.GameStateMachine m = zombie.GameWindow.states;
            return m == null || m.current == null || m.current instanceof zombie.gameStates.IngameState;
        } catch (Throwable e) {
            return true;
        }
    }

    // ---- counters ----

    /** Per tag: frames written, dropped (pool full: the writer is behind), skipped (minimised), and
     *  the render-thread cost; for the film and since the last take. Render thread and writers add,
     *  Lua takes, so it is synchronized (a few adds a frame). */
    public static final class Stats {
        static final class C { long written, dropped, skipped, n, sumNs, worstNs; }
        final Map<String, C> period = new LinkedHashMap<>(), all = new LinkedHashMap<>();

        private void add(String tag, int kind, long ns) {
            for (Map<String, C> m : java.util.List.of(period, all)) {
                C c = m.computeIfAbsent(tag, k -> new C());
                if (kind == 0) c.written++;
                else if (kind == 1) c.dropped++;
                else if (kind == 2) c.skipped++;
                else { c.n++; c.sumNs += ns; c.worstNs = Math.max(c.worstNs, ns); }
            }
        }
        public synchronized void written(String tag) { add(tag, 0, 0); }
        public synchronized void dropped(String tag) { add(tag, 1, 0); }
        public synchronized void skipped(String tag) { add(tag, 2, 0); }
        public synchronized void cost(String tag, long ns) { add(tag, 3, ns); }

        public synchronized String take() {
            String s = line(period);
            period.clear();
            return s;
        }
        public synchronized String total() { return line(all); }

        static String line(Map<String, C> m) {
            C t = new C();
            for (C c : m.values()) {
                t.written += c.written; t.dropped += c.dropped; t.skipped += c.skipped;
                t.n += c.n; t.sumNs += c.sumNs; t.worstNs = Math.max(t.worstNs, c.worstNs);
            }
            String s = String.format(java.util.Locale.ROOT,
                "film: %d frames written, %d dropped (writer behind), %d skipped (window minimised), capture %.1f ms per frame on the render thread (worst %.1f)",
                t.written, t.dropped, t.skipped, t.n == 0 ? 0 : t.sumNs / 1e6 / t.n, t.worstNs / 1e6);
            if (m.size() > 1) {
                StringBuilder b = new StringBuilder("; by tag written/dropped/skipped:");
                for (Map.Entry<String, C> e : m.entrySet()) {
                    C c = e.getValue();
                    b.append(' ').append(e.getKey()).append(' ').append(c.written).append('/').append(c.dropped).append('/').append(c.skipped);
                }
                s += b;
            }
            return s;
        }
    }

    // ---- the writers ----

    /** A frame on its way: GL rows (bottom first, RGBA) in a pooled array, and its seq. */
    static final class Frame {
        final int seq; final byte[] rgba; final int w, h; final long ms; final String tag;
        final AtomicBoolean back = new AtomicBoolean();   // its array is back in the pool
        Frame(int seq, byte[] rgba, int w, int h, long ms, String tag) { this.seq = seq; this.rgba = rgba; this.w = w; this.h = h; this.ms = ms; this.tag = tag; }
    }

    /** The film's writer threads (1 to 4) on one queue of at most depth frames, with a pool of
     *  writers + depth + 1 arrays (one being filled, one being scaled per writer). borrow() gives
     *  null when they are all in use: the caller drops the frame. Each frame handed over (submit)
     *  gets the next seq, kept or dropped, so the files are 000001.jpg, 000002.jpg, ... with a gap
     *  for each frame dropped or failed. Each JPEG is written by whichever writer takes it; its
     *  frames.txt line waits in a reorder buffer until the lines before it are in, so frames.txt is
     *  in seq order. Every seq is settled (written, dropped or failed), so the buffer never waits
     *  for good; past REORDER_MAX lines waiting it moves on anyway. */
    public static final class Writer implements Runnable {
        public static final int REORDER_MAX = 64;
        public final File dir;
        public final int writers;
        public final float quality;
        final int width, poolSize;
        final ArrayBlockingQueue<Frame> queue;
        final ArrayBlockingQueue<byte[]> free;
        final AtomicInteger made = new AtomicInteger(), lastSeq = new AtomicInteger(), written = new AtomicInteger(), running = new AtomicInteger();
        final AtomicLong writeNs = new AtomicLong();
        final BufferedWriter list;
        final TreeMap<Integer, String> pending = new TreeMap<>();   // seq -> line ("" for a frame not written); under this
        int listed;                                                 // the last seq settled in frames.txt; under this
        final Thread[] threads;
        Stats stats;
        volatile boolean started, closing, done;
        public volatile String error = "";
        volatile String stopWhy;
        volatile long closeAt;
        volatile Runnable onEnd;                                    // run once frames.txt is closed

        /** One writer at the default quality (1.0.3's shape; FilmTest). */
        public Writer(File dir, int width, int depth, Stats stats) throws java.io.IOException { this(dir, width, depth, 1, QUALITY, stats); }

        public Writer(File dir, int width, int depth, int writers, float quality, Stats stats) throws java.io.IOException {
            this.dir = dir; this.width = width; this.stats = stats; this.quality = quality;
            this.writers = Math.max(1, Math.min(4, writers));
            this.poolSize = this.writers + depth + 1;
            queue = new ArrayBlockingQueue<>(depth);
            free = new ArrayBlockingQueue<>(poolSize);
            if (!dir.mkdirs() && !dir.isDirectory()) throw new java.io.IOException("can't make " + dir);
            list = new BufferedWriter(new OutputStreamWriter(new FileOutputStream(new File(dir, "frames.txt"), true), StandardCharsets.UTF_8));
            threads = new Thread[this.writers];
            for (int i = 0; i < this.writers; i++) {
                threads[i] = new Thread(this, "TGCapture-film-" + (i + 1));
                threads[i].setDaemon(true);
            }
        }

        public synchronized void start() {
            if (started || done) return;
            started = true;
            running.set(threads.length);
            for (Thread t : threads) t.start();
        }

        public synchronized void header(String s) throws java.io.IOException { list.write(s); list.newLine(); list.flush(); }

        /** An array of at least bytes for the next frame, or null when the writers are behind. */
        public byte[] borrow(int bytes) {
            byte[] b = free.poll();
            if (b == null && made.get() < poolSize) { made.incrementAndGet(); b = new byte[bytes]; }
            if (b != null && b.length < bytes) b = new byte[bytes];   // the window grew
            return b;
        }

        /** Hands a borrowed array over as the next seq; false (and it is counted as dropped, its seq
         *  left out) if the queue is full or the film is ending. Never waits. */
        public boolean submit(byte[] rgba, int w, int h, long ms, String tag) {
            Frame f = new Frame(lastSeq.incrementAndGet(), rgba, w, h, ms, tag);
            if (closing || !queue.offer(f)) { lost(f); return false; }
            if (done && queue.remove(f)) { lost(f); return false; }   // came in after the writers ended
            return true;
        }

        private void lost(Frame f) {
            recycle(f);
            dropped(f.tag);
            settle(f.seq, "");
        }

        public void dropped(String tag) { if (stats != null) stats.dropped(tag); }

        /** A frame's array goes back to the pool: once, whichever path gets there first. */
        private void recycle(Frame f) { if (f.back.compareAndSet(false, true)) free.offer(f.rgba); }

        /** An array borrowed and not submitted (a failed read). One already in the pool isn't added again. */
        public void giveBack(byte[] b) { if (b != null && !free.contains(b)) free.offer(b); }

        /** No more frames: the writers write what is queued (at most DRAIN_MS, then the rest is
         *  dropped), the last one closes frames.txt. Never waits. */
        public void close() {
            boolean end;
            synchronized (this) { if (!closing) closeAt = System.currentTimeMillis(); closing = true; end = !started; }
            if (end) end();
        }

        /** The pool: arrays made, arrays in it now, and whether those are all different (FilmTest). */
        public int made() { return made.get(); }
        public int pooled() { return free.size(); }
        public boolean pooledDistinct() {
            Object[] a = free.toArray();
            java.util.Set<Object> seen = java.util.Collections.newSetFromMap(new java.util.IdentityHashMap<>());
            for (Object o : a) if (!seen.add(o)) return false;
            return true;
        }

        public boolean finished() { return done; }

        /** Waits at most ms in all for the writers to end; true when frames.txt is closed. */
        public boolean await(long ms) throws InterruptedException {
            long until = System.currentTimeMillis() + ms;
            for (Thread t : threads) {
                long left = until - System.currentTimeMillis();
                if (left <= 0) break;
                if (t.isAlive()) t.join(left);
            }
            return done;
        }

        /** Writer threads still running. */
        public int alive() { int n = 0; for (Thread t : threads) if (t.isAlive()) n++; return n; }
        public int written() { return written.get(); }
        public int queued() { return queue.size(); }
        public double msPerFrame() { int n = written.get(); return n == 0 ? 0 : writeNs.get() / 1e6 / n; }

        public static String line(int seq, long ms, String tag, String file) { return seq + " " + ms + " " + tag + " " + file; }

        /** seq is done: its line (or "" when it wasn't written) goes in, and every line now in order is written out. */
        private synchronized void settle(int seq, String line) {
            if (seq <= listed) return;                  // already passed over
            pending.put(seq, line);
            flushList(false);
        }

        private void flushList(boolean all) {           // under this
            boolean wrote = false;
            try {
                while (!pending.isEmpty()) {
                    int k = pending.firstKey();
                    if (!all && k != listed + 1 && pending.size() <= REORDER_MAX) break;
                    String l = pending.pollFirstEntry().getValue();
                    listed = k;
                    if (!l.isEmpty() && !done) { list.write(l); list.newLine(); wrote = true; }
                }
                if (wrote) list.flush();
            } catch (Throwable e) {
                error = "frames.txt: " + e.getClass().getSimpleName() + ": " + e.getMessage();
            }
        }

        @Override public void run() {
            Images.Jpeg jpeg = new Images.Jpeg(quality);
            BufferedImage img = null;
            try {
                while (true) {
                    if (closing && System.currentTimeMillis() - closeAt > DRAIN_MS) break;   // the rest is dropped in end()
                    Frame f = queue.poll(100, TimeUnit.MILLISECONDS);
                    if (f == null) { if (closing) break; continue; }
                    long t0 = System.nanoTime();
                    String name = String.format("%06d.jpg", f.seq);
                    try {
                        int[] sz = Images.filmSize(f.w, f.h, width);
                        if (img == null || img.getWidth() != sz[0] || img.getHeight() != sz[1]) img = new BufferedImage(sz[0], sz[1], BufferedImage.TYPE_INT_RGB);
                        Images.scaleFlip(f.rgba, f.w, f.h, ((DataBufferInt) img.getRaster().getDataBuffer()).getData(), sz[0], sz[1]);
                        recycle(f);                       // scaled: the array isn't needed for the write
                        jpeg.write(img, new File(dir, name));
                    } catch (Throwable e) {
                        recycle(f);                       // no-op when the write failed after the scale
                        error = e.getClass().getSimpleName() + ": " + e.getMessage();
                        dropped(f.tag);
                        settle(f.seq, "");
                        continue;
                    }
                    writeNs.addAndGet(System.nanoTime() - t0);
                    int n = written.incrementAndGet();
                    if (n % Guard.DISK_EVERY == 0) {             // each n is one writer's, so one check per 100
                        String why = Guard.disk(n, dir.getUsableSpace());
                        if (why != null && stopWhy == null) stopWhy = why;
                    }
                    if (stats != null) stats.written(f.tag);
                    settle(f.seq, line(f.seq, f.ms, f.tag, name));
                }
            } catch (InterruptedException e) {
                error = "interrupted";
            } finally {
                jpeg.dispose();
                if (running.decrementAndGet() == 0) end();
            }
        }

        /** The last writer has ended (or none started): what is left in the queue is dropped, the
         *  lines still waiting go out in seq order, and frames.txt is closed. Once. */
        private synchronized void end() {
            if (done) return;
            for (Frame f; (f = queue.poll()) != null; ) { recycle(f); dropped(f.tag); pending.put(f.seq, ""); }
            flushList(true);
            try { list.close(); } catch (Throwable e) { /* already closed */ }
            done = true;
            Runnable r = onEnd;
            if (r != null) try { r.run(); } catch (Throwable e) { /* only a note */ }
        }
    }
}
