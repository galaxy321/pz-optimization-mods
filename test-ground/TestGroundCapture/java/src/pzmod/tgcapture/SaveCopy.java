package pzmod.tgcapture;

import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.Locale;
import java.util.Set;

/**
 * Benchmark Save (Test Ground Autorun 1.5.0): a copy of a save folder, so the run happens on a
 * throwaway copy and the original is never opened. Lua can only read and write inside Zomboid/Lua,
 * and the game's own copy (IngameState.copyWorld, used when it converts an old save) is not
 * reachable from Lua, so the copy is made here, on its own daemon thread (1.0.7: a big save no longer
 * freezes the menu) with a status Lua can poll. Both names are plain folder names under
 * Saves/<mode>/; the copy is refused if its folder exists, if it would not fit on the disk with room
 * to spare, or if it is over MAX_BYTES; links are not followed; a failed copy removes the folder it made.
 */
final class SaveCopy {
    static final Set<String> MODES = Set.of("Sandbox", "Apocalypse", "Survivor", "Builder", "Beginner", "Survival");
    static final long MAX_BYTES = 20L << 30;
    static final long SPARE_BYTES = 512L << 20;
    private static final Set<String> RESERVED = Set.of("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5",
            "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9");

    private static volatile String state = "idle";
    private static volatile long total, copied;
    private static Thread worker;

    private SaveCopy() {}

    static boolean plain(String s) {
        if (s == null || s.isEmpty() || s.length() > 120 || s.equals(".") || s.equals("..") || s.startsWith(".") || s.endsWith(".") || s.endsWith(" ")) return false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 32 || "/\\:*?\"<>|".indexOf(c) >= 0) return false;
        }
        String base = s.indexOf('.') >= 0 ? s.substring(0, s.indexOf('.')) : s;
        return !RESERVED.contains(base.toUpperCase(Locale.ROOT));
    }

    static String status() {
        String s = state;
        if (s.equals("copying")) return String.format("copying %d of %d MB", copied >> 20, total >> 20);
        return s;
    }

    /** "" when the copy has started (poll status()), else why not. */
    static synchronized String start(Path saves, String mode, String src, String dst) {
        if (worker != null && worker.isAlive()) return "a copy is already running";
        if (!MODES.contains(mode) || !plain(src) || !plain(dst)) return "not a plain save name";
        Path base = saves.resolve(mode).normalize();
        Path from = base.resolve(src).normalize();
        Path to = base.resolve(dst).normalize();
        if (!from.startsWith(base) || !to.startsWith(base) || from.equals(base) || to.equals(base)) return "outside the saves folder";
        if (!Files.isDirectory(from, LinkOption.NOFOLLOW_LINKS)) return "no save named " + src;
        if (Files.exists(to, LinkOption.NOFOLLOW_LINKS)) return "a save named " + dst + " already exists";
        total = 0;
        copied = 0;
        state = "copying";
        worker = new Thread(() -> run(base, from, to), "TestGroundCapture save copy");
        worker.setDaemon(true);
        worker.start();
        return "";
    }

    private static void run(Path base, Path from, Path to) {
        boolean made = false;
        try {
            long[] sum = new long[1];
            Files.walkFileTree(from, new SimpleFileVisitor<Path>() {
                @Override public FileVisitResult visitFile(Path f, BasicFileAttributes a) {
                    if (a.isRegularFile()) sum[0] += a.size();
                    return FileVisitResult.CONTINUE;
                }
            });
            total = sum[0];
            if (total > MAX_BYTES) throw new IOException("the save is " + (total >> 30) + " GB, over the " + (MAX_BYTES >> 30) + " GB limit");
            long free = Files.getFileStore(base).getUsableSpace();
            if (free < total + SPARE_BYTES) throw new IOException("not enough disk space: the save is " + (total >> 20) + " MB, " + (free >> 20) + " MB are free");
            Files.createDirectory(to);   // fails if it exists: the check and the create are one step
            made = true;
            Files.walkFileTree(from, new SimpleFileVisitor<Path>() {
                @Override public FileVisitResult preVisitDirectory(Path d, BasicFileAttributes a) throws IOException {
                    Path t = to.resolve(from.relativize(d));
                    if (!Files.isDirectory(t)) Files.createDirectory(t);
                    return FileVisitResult.CONTINUE;
                }
                @Override public FileVisitResult visitFile(Path f, BasicFileAttributes a) throws IOException {
                    if (!a.isRegularFile()) return FileVisitResult.CONTINUE;   // links and the like are left out
                    Files.copy(f, to.resolve(from.relativize(f)), StandardCopyOption.COPY_ATTRIBUTES, LinkOption.NOFOLLOW_LINKS);
                    copied += a.size();
                    return FileVisitResult.CONTINUE;
                }
            });
            state = "done";
        } catch (Throwable e) {
            if (made) removeOwn(to);
            state = "failed: " + (e.getMessage() != null ? e.getMessage() : e.toString());
        }
    }

    /** The folder this copy made and nothing else. */
    private static void removeOwn(Path to) {
        try {
            Files.walkFileTree(to, new SimpleFileVisitor<Path>() {
                @Override public FileVisitResult visitFile(Path f, BasicFileAttributes a) throws IOException { Files.delete(f); return FileVisitResult.CONTINUE; }
                @Override public FileVisitResult postVisitDirectory(Path d, IOException e) throws IOException { Files.delete(d); return FileVisitResult.CONTINUE; }
            });
        } catch (Throwable ignored) {
        }
    }

    static void await(long ms) throws InterruptedException {
        Thread t = worker;
        if (t != null) t.join(ms);
    }
}
