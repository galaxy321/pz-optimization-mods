import java.awt.image.BufferedImage;
import java.io.File;
import java.nio.file.Files;
import java.util.List;
import javax.imageio.ImageIO;
import pzmod.tgcapture.Film;
import pzmod.tgcapture.Images;
// The film side outside the game (1.0.2, 1.0.3, 1.0.4): sizes, the box scaler and its flip, the JPEG,
// the writer's pool and queue with drop counting, frames.txt in seq order, the tags and the stats
// lines; the heartbeat, out-of-world, cap and disk stops; two writers with gaps in seq for dropped
// and failed frames, filmQuality, and filmStop draining both writers; (1.0.5) filmStop returning
// at once, "stopping" until a render frame or the watchdog ends the film, a filmStart refused
// meanwhile, and every pooled array back exactly once, a failed JPEG write included.
// Run: java -cp tgcapture.jar:. FilmTest <new out dir>
public class FilmTest {
    static boolean ok = true;
    static void check(String what, boolean good) { System.out.println((good ? "ok   " : "FAIL ") + what); ok &= good; }

    public static void main(String[] a) throws Exception {
        File out = new File(a.length > 0 ? a[0] : ".");
        // sizes: even, by aspect, never above the source
        int[] s1 = Images.filmSize(2560, 1440, 1280), s2 = Images.filmSize(1366, 768, 1280), s3 = Images.filmSize(1000, 601, 1280);
        check("size 2560x1440 at 1280 is " + s1[0] + "x" + s1[1], s1[0] == 1280 && s1[1] == 720);
        check("size 1366x768 at 1280 is " + s2[0] + "x" + s2[1], s2[0] == 1280 && s2[1] == 720);
        check("size 1000x601 at 1280 is " + s3[0] + "x" + s3[1], s3[0] == 1000 && s3[1] == 602);
        // scaler: 4x4 GL rows (bottom first) to 2x2; the bottom two rows red, the top two blue with
        // green 0/100 in turn, so each output pixel averages to green 50
        int w = 4, h = 4;
        byte[] px = new byte[w * h * 4];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int i = (y * w + x) * 4;
            px[i] = (byte) (y < 2 ? 200 : 0); px[i + 1] = (byte) (x % 2 == 0 ? 0 : 100); px[i + 2] = (byte) (y < 2 ? 0 : 250);
        }
        int[] o = new int[4];
        Images.scaleFlip(px, w, h, o, 2, 2);
        check(String.format("scaled top %06x bottom %06x", o[0], o[2]), o[0] == 0x0032FA && o[1] == 0x0032FA && o[2] == 0xC83200 && o[3] == 0xC83200);
        // the general box path: 6x3 to 2x1, red 0, 30 .. 150 across, so the halves average 30 and 120
        byte[] g6 = new byte[6 * 3 * 4];
        for (int i = 0; i < 18; i++) g6[i * 4] = (byte) ((i % 6) * 30);
        int[] o6 = new int[2];
        Images.scaleFlip(g6, 6, 3, o6, 2, 1);
        check(String.format("box 6x3 to 2x1: red %d %d", o6[0] >> 16, o6[1] >> 16), (o6[0] >> 16) == 30 && (o6[1] >> 16) == 120);
        // JPEG
        BufferedImage img = new BufferedImage(64, 32, BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < 32; y++) for (int x = 0; x < 64; x++) img.setRGB(x, y, y < 16 ? 0x2040C0 : 0xC08020);
        File jf = new File(out, "q85.jpg");
        Images.Jpeg jpeg = new Images.Jpeg(Film.QUALITY);
        jpeg.write(img, jf);
        jpeg.dispose();
        BufferedImage back = ImageIO.read(jf);
        int c = back.getRGB(32, 4);
        check("jpeg " + back.getWidth() + "x" + back.getHeight() + ", " + jf.length() + " bytes, top " + Integer.toHexString(c & 0xFFFFFF),
            back.getWidth() == 64 && Math.abs(((c >> 16) & 255) - 0x20) < 12 && Math.abs((c & 255) - 0xC0) < 12);
        // tags and lines
        check("tag \"" + Film.cleanTag(" walk to  car ") + "\"", Film.cleanTag(" walk to  car ").equals("walk_to_car") && Film.cleanTag(null).equals("none"));
        check("line " + Film.Writer.line(7, 1760000000123L, "drive", "000007.jpg"), Film.Writer.line(7, 1760000000123L, "drive", "000007.jpg").equals("7 1760000000123 drive 000007.jpg"));
        // one writer, before its thread starts: a queue of 3 and a pool of 1 + 3 + 1 = 5 arrays
        Film.Stats st = new Film.Stats();
        File dir = new File(out, "film" + File.separator + "run1");
        Film.Writer wr = new Film.Writer(dir, 1280, 3, st);
        wr.header("# test film");
        int fw = 2560, fh = 1440, bytes = fw * fh * 4;
        byte[][] got = new byte[6][];
        for (int i = 0; i < 6; i++) got[i] = wr.borrow(bytes);
        check("pool: 5 arrays (1 writer + 3 queued + 1), the 6th refused", got[4] != null && got[5] == null);
        wr.giveBack(got[4]);
        wr.dropped("drive");                                      // what Gl does when borrow gives null
        String[] tags = { "settle", "drive", "drive", "drive" };
        boolean[] in = new boolean[4];
        for (int i = 0; i < 4; i++) {
            java.util.Arrays.fill(got[i], (byte) (40 * i));
            in[i] = wr.submit(got[i], fw, fh, 1000 + i, tags[i]);
        }
        check("queue: 3 taken, the 4th dropped", in[0] && in[1] && in[2] && !in[3]);
        st.skipped("drive");
        st.cost("settle", 1_000_000); st.cost("drive", 2_000_000); st.cost("drive", 6_000_000);
        long t0 = System.nanoTime();
        wr.start();
        wr.close();
        boolean done = wr.await(30000);
        double ms = (System.nanoTime() - t0) / 1e6 / 3;
        List<String> lines = Files.readAllLines(new File(dir, "frames.txt").toPath());
        check("writer finished, " + wr.written() + " written (" + String.format("%.0f", ms) + " ms per 2560x1440 frame)", done && wr.written() == 3);
        check("frames.txt " + lines, lines.size() == 4 && lines.get(0).startsWith("#") && lines.get(1).equals("1 1000 settle 000001.jpg")
            && lines.get(2).equals("2 1001 drive 000002.jpg") && lines.get(3).equals("3 1002 drive 000003.jpg"));
        BufferedImage f2 = ImageIO.read(new File(dir, "000002.jpg"));
        check("000002.jpg " + f2.getWidth() + "x" + f2.getHeight() + ", grey " + (f2.getRGB(10, 10) & 255), f2.getWidth() == 1280 && f2.getHeight() == 720
            && Math.abs((f2.getRGB(10, 10) & 255) - 40) < 6 && !new File(dir, "000004.jpg").exists());
        // the stats
        String take = st.take(), again = st.take(), total = st.total();
        System.out.println("take:  " + take);
        System.out.println("again: " + again);
        System.out.println("total: " + total);
        check("take", take.equals("film: 3 frames written, 2 dropped (writer behind), 1 skipped (window minimised), capture 3.0 ms per frame on the render thread (worst 6.0); by tag written/dropped/skipped: drive 2/2/1 settle 1/0/0"));
        check("take resets", again.equals("film: 0 frames written, 0 dropped (writer behind), 0 skipped (window minimised), capture 0.0 ms per frame on the render thread (worst 0.0)"));
        check("total keeps", total.equals(take));
        // 1.0.3: the film stops by itself, on a made-up clock (ms)
        Film.Guard gd = new Film.Guard(0, 20);
        boolean beat = true;
        for (long t = 1000; t <= 60_000; t += 1000) { gd.word(t); beat &= gd.check(t, true) == null; }
        String quiet9 = gd.check(69_999, true), quiet10 = gd.check(70_000, true);
        check("heartbeat: quiet 9.999 s " + quiet9 + ", 10 s " + quiet10, beat && quiet9 == null
            && "stopped: no word from Test Ground for 10 s".equals(quiet10));
        Film.Guard cap = new Film.Guard(0, 20);
        cap.word(20 * 60_000 - 1);
        String under = cap.check(20 * 60_000 - 1, true);
        cap.word(20 * 60_000);
        String at = cap.check(20 * 60_000, true);
        cap.setMax(1.5);
        cap.word(90_000);
        check("cap: before " + under + ", at 20 min " + at + ", at 1.5 min " + cap.check(90_000, true), under == null
            && "stopped: reached the cap of 20 minutes".equals(at) && "stopped: reached the cap of 1.5 minutes".equals(cap.check(90_000, true)));
        Film.Guard og = new Film.Guard(0, 20);
        og.word(5000);
        String o1 = og.check(1000, false), o2 = og.check(2500, true), o3 = og.check(3000, false), o4 = og.check(5000, false);
        check("out of the world: brief " + o1 + "/" + o2 + ", 2 s " + o4, o1 == null && o2 == null && o3 == null
            && "stopped: the game left the world (quit to the main menu?)".equals(o4));
        String d1 = Film.Guard.disk(100, 1L << 30), d2 = Film.Guard.disk(150, 1L << 30), d3 = Film.Guard.disk(200, 5L << 30);
        check("disk: " + d1, "stopped: 1.0 GB free under the film folder, under 2 GB".equals(d1) && d2 == null && d3 == null);
        check("max minutes clamped", Film.maxMinutes(0) == 1 && Film.maxMinutes(500) == 120 && Film.maxMinutes(30) == 30 && Film.maxMinutes(20) == 20);
        // 1.0.4: two writers on a queue of 8 with a pool of 11; seq given at the hand-over, so frames
        // 9 and 10 (queue full) and 11 (fails to write) are gaps, and frames.txt stays in seq order
        Film.Stats st2 = new Film.Stats();
        File dir2 = new File(out, "film" + File.separator + "run2");
        Film.Writer w2 = new Film.Writer(dir2, 640, Film.DEPTH, Film.WRITERS, Film.QUALITY, st2);
        w2.header("# two writers");
        int bw = 1280, bh = 720;
        byte[][] g = new byte[12][];
        for (int i = 0; i < 12; i++) g[i] = w2.borrow(bw * bh * 4);
        check("2 writers: pool of 11 (2 + 8 + 1), the 12th refused", w2.writers == 2 && Film.WRITERS == 2 && Film.DEPTH == 8 && g[10] != null && g[11] == null);
        boolean[] in2 = new boolean[10];
        for (int i = 0; i < 10; i++) { java.util.Arrays.fill(g[i], (byte) (20 * (i % 8))); in2[i] = w2.submit(g[i], i % 2 == 0 ? bw : 320, i % 2 == 0 ? bh : 180, 5001 + i, "a" + (i + 1)); }
        w2.giveBack(g[10]);
        boolean eight = true;
        for (int i = 0; i < 8; i++) eight &= in2[i];
        check("2 writers: queue of 8 taken, 9 and 10 dropped", eight && !in2[8] && !in2[9] && w2.queued() == 8);
        w2.start();
        check("2 writers: both threads running", w2.alive() == 2);
        boolean all = true;
        for (int i = 10; i < 20; i++) {
            byte[] b;
            while ((b = w2.borrow(bw * bh * 4)) == null) Thread.sleep(2);
            while (w2.queued() >= Film.DEPTH) Thread.sleep(2);    // only this thread submits, so the next one is taken
            if (i == 10) all &= w2.submit(new byte[16], 4000, 4000, 5011, "bad");   // too short: fails in the writer
            else { java.util.Arrays.fill(b, (byte) 90); all &= w2.submit(b, i % 2 == 0 ? bw : 320, i % 2 == 0 ? bh : 180, 5001 + i, "a" + (i + 1)); }
            if (i == 10) w2.giveBack(b);
        }
        w2.close();
        boolean done2 = w2.await(30000);
        List<String> l2 = Files.readAllLines(new File(dir2, "frames.txt").toPath());
        StringBuilder want = new StringBuilder("# two writers");
        for (int q = 1; q <= 20; q++) if (q < 9 || q > 11) want.append('|').append(Film.Writer.line(q, 5000 + q, "a" + q, String.format("%06d.jpg", q)));
        check("2 writers: frames.txt in seq order, gaps at 9 10 11: " + String.join("|", l2), all && done2 && String.join("|", l2).equals(want.toString()));
        check("2 writers: both ended, 17 written, " + st2.total(), w2.alive() == 0 && w2.written() == 17 && !w2.error.isEmpty()
            && st2.total().startsWith("film: 17 frames written, 3 dropped") && new File(dir2, "000020.jpg").exists()
            && !new File(dir2, "000009.jpg").exists() && !new File(dir2, "000011.jpg").exists());
        // filmQuality: clamped, kept for the next filmStart; a lower quality gives a smaller JPEG
        double q1 = Film.quality(0.1), q2 = Film.quality(2), q3 = Film.quality(Double.NaN), q4 = Film.quality(0.7);
        BufferedImage noisy = new BufferedImage(160, 90, BufferedImage.TYPE_INT_RGB);
        java.util.Random rnd = new java.util.Random(7);
        for (int y = 0; y < 90; y++) for (int x = 0; x < 160; x++) noisy.setRGB(x, y, rnd.nextInt(0x1000000));
        File j50 = new File(out, "q50.jpg"), j95 = new File(out, "q95.jpg");
        Images.Jpeg ja = new Images.Jpeg(0.5f), jb = new Images.Jpeg(0.95f);
        ja.write(noisy, j50); jb.write(noisy, j95); ja.dispose(); jb.dispose();
        check("filmQuality clamps: 0.1 -> " + q1 + ", 2 -> " + q2 + ", NaN -> " + q3 + ", 0.7 -> " + q4 + "; q50 " + j50.length() + " < q95 " + j95.length() + " bytes",
            q1 == 0.5 && q2 == 0.95 && q3 == 0.85 && q4 == 0.7 && j50.length() < j95.length());
        // 1.0.5: a JPEG that fails to write (its file name is taken by a folder) gives its array back
        // once: one writer, 3 arrays made (of a pool of 5), all 3 back in the pool, no array twice
        File dir4 = new File(out, "film" + File.separator + "run4");
        Film.Writer w4 = new Film.Writer(dir4, 640, 3, new Film.Stats());
        new File(dir4, "000002.jpg").mkdirs();
        for (int i = 0; i < 3; i++) { byte[] b = w4.borrow(bw * bh * 4); java.util.Arrays.fill(b, (byte) 60); w4.submit(b, bw, bh, 9001 + i, "err"); }
        w4.start();
        w4.close();
        boolean done4 = w4.await(30000);
        check("write error: " + w4.written() + " written, error \"" + w4.error + "\", pool " + w4.pooled() + " of " + w4.made() + " made, distinct " + w4.pooledDistinct(),
            done4 && w4.written() == 2 && !w4.error.isEmpty() && w4.made() == 3 && w4.pooled() == 3 && w4.pooledDistinct()
            && Files.readAllLines(new File(dir4, "frames.txt").toPath()).equals(List.of("1 9001 err 000001.jpg", "3 9003 err 000003.jpg")));
        // filmStop with no render thread returns at once; the film is "stopping" (and a filmStart is
        // refused) until a render frame (here a made-up one: onSwap on another thread) flushes and
        // the writers have written what is queued
        boolean started = Film.start(new File(out, "films"), "run 3", 30, 640);
        Film.Writer w3 = Film.writer();
        boolean live = Film.alive();
        int sent = 0;
        for (int i = 0; i < 14; i++) {
            byte[] b;
            while ((b = w3.borrow(bw * bh * 4)) == null) Thread.sleep(2);
            while (w3.queued() >= Film.DEPTH) Thread.sleep(2);
            java.util.Arrays.fill(b, (byte) (10 * i));
            if (w3.submit(b, bw, bh, 7001 + i, "stop")) sent++;
        }
        int queuedAtStop = w3.queued();
        long s0 = System.nanoTime();
        boolean stopped = Film.stop();
        long stopNs = System.nanoTime() - s0;
        String st3 = Film.status();
        boolean again2 = Film.stop();
        boolean start2 = Film.start(new File(out, "films"), "run 3b", 30, 640);
        String refused = Film.status();
        check(String.format("filmStop returns in %.2f ms, status: %s", stopNs / 1e6, st3), stopped && stopNs < 50_000_000L && st3.startsWith("film run_3 stopping:") && !again2);
        check("filmStart while stopping refused: " + refused, !start2 && Film.writer() == w3 && refused.contains("filmStart refused: film run_3 is still stopping"));
        long r0 = System.currentTimeMillis();
        Thread render = new Thread(Film::onSwap, "made-up render thread");
        render.start();
        render.join();
        while (Film.status().contains(" stopping") && System.currentTimeMillis() - r0 < 10_000) Thread.sleep(5);
        long drainMs = System.currentTimeMillis() - r0;
        String st3b = Film.status();
        List<String> l3 = Files.readAllLines(new File(w3.dir, "frames.txt").toPath());
        boolean inOrder = l3.size() == 15 && l3.get(0).startsWith("# TestGroundCapture 1.0.7 film run_3 30 fps 640 wide");
        for (int q = 1; q < l3.size() && inOrder; q++) inOrder = l3.get(q).equals(Film.Writer.line(q, 7000 + q, "stop", String.format("%06d.jpg", q)));
        check("filmStop drains both writers: " + queuedAtStop + " queued at the stop, " + w3.written() + " written, " + drainMs + " ms after the render frame; " + Film.total(),
            started && live && w3.writers == 2 && w3.quality == 0.7f && sent == 14 && !Film.alive()
            && w3.finished() && w3.alive() == 0 && w3.written() == 14 && inOrder && drainMs < Film.PICKUP_MS
            && Film.total().endsWith("; stopped by filmStop") && w3.dir.getName().equals("run_3"));
        check("after the render frame: " + st3b, st3b.startsWith("film run_3 stopped by filmStop:") && st3b.endsWith("film run_3 stopped by filmStop, frames.txt complete")
            && w3.pooled() == w3.made() && w3.pooledDistinct());
        // no render frame at all (the game quit, say): the watchdog ends the film after PICKUP_MS,
        // without the PBO frames; filmTotal keeps the counts
        boolean started5 = Film.start(new File(out, "films"), "run 5", 30, 640);
        Film.Writer w5 = Film.writer();
        for (int i = 0; i < 3; i++) { byte[] b = w5.borrow(bw * bh * 4); java.util.Arrays.fill(b, (byte) 30); w5.submit(b, bw, bh, 8001 + i, "dog"); }
        long d0 = System.nanoTime();
        boolean stopped5 = Film.stop();
        long stop5Ns = System.nanoTime() - d0;
        String st5 = Film.status();
        Thread.sleep(Film.PICKUP_MS / 2);
        String st5mid = Film.status();
        while (Film.status().contains(" stopping") && (System.nanoTime() - d0) / 1_000_000 < 10_000) Thread.sleep(5);
        long dogMs = (System.nanoTime() - d0) / 1_000_000;
        String st5b = Film.status(), tot5 = Film.total();
        check(String.format("watchdog film: filmStop returns in %.2f ms; %s", stop5Ns / 1e6, st5), started5 && stopped5 && stop5Ns < 50_000_000L
            && st5.startsWith("film run_5 stopping:") && st5mid.startsWith("film run_5 stopping:") && w5 != w3);
        check("watchdog ended it " + dogMs + " ms after the stop: " + st5b, dogMs >= Film.PICKUP_MS && dogMs < Film.PICKUP_MS + Film.DRAIN_MS
            && st5b.startsWith("film run_5 stopped by filmStop:") && st5b.contains("frames still in the PBOs were lost") && w5.finished() && w5.written() == 3);
        check("filmTotal after the stop: " + tot5, tot5.startsWith("film: 3 frames written, 0 dropped") && tot5.endsWith("; stopped by filmStop"));
        Film.quality(0.85);
        System.out.println(ok ? "FILM OK" : "FILM FAILED");
        System.exit(ok ? 0 : 1);
    }
}
