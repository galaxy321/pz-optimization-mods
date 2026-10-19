package pzmod.loadfix;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Runs the game's three walks and getRelativeFile (Original) and the faster ones (FastWalk) on the same
 * folders and checks they give identical lists, in identical order, then times
 * both. Read-only: it only lists folders. For the PC:
 *   <game jre>\bin\java.exe -cp loadfix-verify.jar pzmod.loadfix.Verify <folder> [<folder> ...]
 * Prints one line per folder and walk, and "ALL IDENTICAL" or the first difference.
 */
public final class Verify {
    public static void main(String[] args) throws Exception {
        System.out.println("java " + System.getProperty("java.version") + " on " + System.getProperty("os.name"));
        boolean allSame = true;
        for (String a : args) {
            File root = new File(a);
            List<String> o = new ArrayList<>(), n = new ArrayList<>();
            long t0 = System.nanoTime(); Original.luaSearchFolders(root, o::add);
            long t1 = System.nanoTime(); FastWalk.luaSearchFolders(root, n::add);
            long t2 = System.nanoTime();
            long gameLua = t1 - t0;
            allSame &= report("lua", a, o, n, gameLua, t2 - t1);
            n.clear();
            t1 = System.nanoTime(); FastWalk.luaSearchFoldersNio(root, n::add);
            t2 = System.nanoTime();
            allSame &= report("luaN", a, o, n, gameLua, t2 - t1);
            o.clear(); n.clear();
            long[] ticks = new long[2];
            t0 = System.nanoTime(); Original.zfsSearchFolders(root, o, () -> ticks[0]++);
            t1 = System.nanoTime(); FastWalk.zfsSearchFolders(root, n, () -> ticks[1]++);
            t2 = System.nanoTime();
            allSame &= report("files", a, o, n, t1 - t0, t2 - t1);
            if (ticks[0] != ticks[1]) System.out.println("  note: per-entry calls " + ticks[0] + " (game) vs " + ticks[1] + " (fast)");
            // Relative paths of everything the file listing found, against the
            // folder's parent (as the game does against a mod's or the game's folder).
            Map<String, Boolean> kinds = new HashMap<>();
            List<String> listed = new ArrayList<>();
            FastWalk.zfsSearchFolders(root, listed, () -> {}, kinds);
            java.net.URI base0 = root.getAbsoluteFile().getParentFile().toURI();
            boolean ci = File.separatorChar == '\\';
            List<String> ro = new ArrayList<>(), rn = new ArrayList<>();
            int unknown = 0;
            t0 = System.nanoTime();
            for (String p : listed) ro.add(Original.relativeFile(base0, p));
            t1 = System.nanoTime();
            for (String p : listed) {
                Boolean d = kinds.get(p);
                String r = d == null ? null : FastWalk.relativeFile(base0, p, d, ci);
                if (r == null) { unknown++; r = Original.relativeFile(base0, p); }
                rn.add(r);
            }
            t2 = System.nanoTime();
            allSame &= report("rel", a, ro, rn, t1 - t0, t2 - t1);
            // The listing's folder-or-not answers (used for relative paths and by init)
            // against asking the file system.
            ro.clear(); rn.clear();
            t0 = System.nanoTime();
            for (String p : listed) if (kinds.containsKey(p)) ro.add(p + " " + new File(p).getAbsoluteFile().isDirectory());
            t1 = System.nanoTime();
            for (String p : listed) if (kinds.containsKey(p)) rn.add(p + " " + kinds.get(p));
            t2 = System.nanoTime();
            allSame &= report("kinds", a, ro, rn, t1 - t0, t2 - t1);
            // Relative paths of the Lua files, which the Lua listing works out as files.
            List<String> luaFiles = new ArrayList<>();
            FastWalk.luaSearchFoldersNio(root, luaFiles::add);
            java.net.URI luaBase = root.getAbsoluteFile().toURI();
            ro.clear(); rn.clear();
            t0 = System.nanoTime();
            for (String p : luaFiles) ro.add(Original.relativeFile(luaBase, p));
            t1 = System.nanoTime();
            for (String p : luaFiles) { String r = FastWalk.relativeFile(luaBase, p, false, ci); rn.add(r != null ? r : Original.relativeFile(luaBase, p)); }
            t2 = System.nanoTime();
            allSame &= report("luarel", a, ro, rn, t1 - t0, t2 - t1);
            if (unknown > 0) System.out.println("  note: " + unknown + " path(s) left to the game's method");
            // The game+mod file walk, with a visitor that asks what resolveAllFiles'
            // visitor asks (isFile) plus isDirectory, and records the answers.
            o.clear(); n.clear();
            File base = root.getAbsoluteFile().getParentFile();
            String rel = root.getAbsoluteFile().getName();
            int[] fellBack = new int[1];
            t0 = System.nanoTime(); Original.gameWalk(base, rel, true, (f, r) -> o.add(seen(f, r)));
            t1 = System.nanoTime(); FastWalk.gameWalk(base, rel, true, (f, r) -> n.add(seen(f, r)), fellBack);
            t2 = System.nanoTime();
            allSame &= report("game", a, o, n, t1 - t0, t2 - t1);
            if (fellBack[0] > 0) System.out.println("  note: " + fellBack[0] + " folder(s) listed the game's way (links or unreadable)");
        }
        System.out.println(allSame ? "ALL IDENTICAL" : "DIFFERENCES FOUND");
        if (!allSame) System.exit(1);
    }

    static String seen(File f, String rel) {
        return f.getPath() + " | " + rel + " | file=" + f.isFile() + " dir=" + f.isDirectory();
    }

    static boolean report(String walk, String dir, List<String> o, List<String> n, long nsOld, long nsNew) {
        boolean same = o.equals(n);
        System.out.printf("%-5s %-60s %7d paths  game %8.0f ms  fast %7.0f ms  %s%n",
                walk, dir, o.size(), nsOld / 1e6, nsNew / 1e6, same ? "identical" : "DIFFERENT");
        if (!same) {
            int i = 0, m = Math.min(o.size(), n.size());
            while (i < m && o.get(i).equals(n.get(i))) i++;
            System.out.println("  first difference at " + i + ":");
            System.out.println("    game: " + (i < o.size() ? o.get(i) : "(end, " + o.size() + " paths)"));
            System.out.println("    fast: " + (i < n.size() ? n.get(i) : "(end, " + n.size() + " paths)"));
        }
        return same;
    }
}
