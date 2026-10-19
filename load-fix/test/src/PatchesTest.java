import java.io.File;
import java.util.ArrayList;
import java.util.List;
import pzmod.loadfix.Patches;
import zombie.Lua.LuaManager;
import zombie.ZomboidFileSystem;

// Runs Patches.luaWalk / fileWalk (what the patches call in place of the game's
// methods) against the game's walks on the stand-in classes, and checks the
// game's lists end up identical, including the per-entry frame calls, and that a
// failing walk adds nothing and hands over to the game's method.
public class PatchesTest {
    static int fails;
    static void check(String what, boolean ok) { System.out.println((ok ? "ok   " : "FAIL ") + what); if (!ok) fails++; }

    // What a visitor can see of an entry: its path, the folder it was found in, and
    // the two answers the game's visitors ask for.
    static String seen(File f, String rel) { return f.getPath() + " | " + rel + " | file=" + f.isFile() + " dir=" + f.isDirectory() + " | " + f.getName(); }

    public static void main(String[] a) throws Exception {
        for (boolean nio : new boolean[] {false, true}) {
        Patches.ENABLE_LUA_NIO = nio;
        System.out.println("-- Lua listing " + (nio ? "nio" : "per-folder canonical"));
        for (String dir : a) {
            File root = new File(dir);
            java.net.URI base = new File(dir).toURI();

            LuaManager.loadList.clear(); LuaManager.searchFolders(base, root);
            List<String> game = new ArrayList<>(LuaManager.loadList);
            LuaManager.loadList.clear(); boolean skipped = Patches.luaWalk(base, root);
            check("lua walk " + dir + " (" + game.size() + " files) identical", skipped && game.equals(LuaManager.loadList));

            ZomboidFileSystem z = ZomboidFileSystem.instance;
            z.list().clear(); ZomboidFileSystem.frames = 0; z.searchFolders(root);
            List<String> g2 = new ArrayList<>(z.list()); int f1 = ZomboidFileSystem.frames;
            z.list().clear(); ZomboidFileSystem.frames = 0; skipped = Patches.fileWalk(z, root);
            check("file walk " + dir + " (" + g2.size() + " paths) identical", skipped && g2.equals(z.list()));
            check("file walk " + dir + " frame calls " + f1 + " = " + ZomboidFileSystem.frames, f1 == ZomboidFileSystem.frames);
        }
        }
        // Relative paths: for every path a file listing added, the patched answer
        // equals the game's, for a base that contains it and one that doesn't; paths
        // with capitals go to the game's method on this case-sensitive file system.
        {
            ZomboidFileSystem zz = ZomboidFileSystem.instance;
            zz.list().clear();
            check("file walk for relative paths", Patches.fileWalk(zz, new File(a[0])));
            List<String> paths = new ArrayList<>(zz.list());
            paths.add(new File(a[0]).getAbsolutePath() + "/not/listed.lua");
            int known = 0, same = 0;
            for (java.net.URI base : new java.net.URI[] {new File(a[0].toLowerCase()).toURI(), new File(a[0]).getParentFile().toURI(), new File("/elsewhere").toURI()}) {
                for (String p : paths) {
                    String g = zz.getRelativeFile(base, p), f = Patches.relativeFile(base, p);
                    if (f != null) { known++; if (f.equals(g)) same++; else System.out.println("  differs: " + p + " game=" + g + " fast=" + f); }
                }
            }
            check("relative paths: " + same + " of " + known + " answered from the listing are identical", known > 0 && same == known);
            check("a path not listed goes to the game", Patches.relativeFile(new File(a[0]).toURI(), new File(a[0]).getAbsolutePath() + "/not/listed.lua") == null);
            Patches.report();
            check("report clears the listing's answers", Patches.relativeFile(new File(a[0]).toURI(), paths.get(0)) == null);
        }
        // Game+mod file walk: same visitor calls, in the same order, with the same
        // answers to isFile()/isDirectory(), for recursive and flat walks.
        ZomboidFileSystem z = ZomboidFileSystem.instance;
        File base = new File(a[0]);
        for (String rel : new String[] {"mod A", "mod A/media/lua", "mod B", "mod C/media/lua/shared", "mod B/linked", "mod A/media/maps", "missing", "mod B/mod.info"}) {
            for (boolean rec : new boolean[] {true, false}) {
                List<String> g = new ArrayList<>(), f = new ArrayList<>();
                z.walkGameAndModFilesInternal(base, rel, rec, (file, r) -> g.add(seen(file, r)));
                boolean skipped = Patches.gameWalk(base, rel, rec, (file, r) -> f.add(seen(file, r)));
                check("game walk '" + rel + "' " + (rec ? "recursive" : "flat") + " (" + g.size() + " visits) identical", skipped && g.equals(f));
            }
        }
        check("linked folder listed the game's way, counted", Patches.gameFolderFallbacks > 0);
        // An error from the visitor reaches the caller, after the same visits.
        List<String> g = new ArrayList<>(), f = new ArrayList<>();
        Throwable eg = null, ef = null;
        try { z.walkGameAndModFilesInternal(base, "mod A", true, (file, r) -> { g.add(seen(file, r)); if (g.size() == 4) throw new IllegalStateException("x"); }); } catch (Throwable t) { eg = t; }
        try { Patches.gameWalk(base, "mod A", true, (file, r) -> { f.add(seen(file, r)); if (f.size() == 4) throw new IllegalStateException("x"); }); } catch (Throwable t) { ef = t; }
        check("visitor error reaches the caller after the same visits", eg != null && ef instanceof IllegalStateException && g.equals(f));
        // A walk that fails must add nothing and let the game's method run.
        LuaManager.loadList.clear();
        boolean skipped = Patches.luaWalk(null, new File(a[0]));   // null base: getRelativeFile throws
        check("failing lua walk falls back, adds nothing", !skipped && LuaManager.loadList.isEmpty());
        ZomboidFileSystem.instance.list().clear();
        skipped = Patches.fileWalk(new Object(), new File(a[0]));   // wrong object: field read throws
        check("failing file walk falls back, adds nothing", !skipped && ZomboidFileSystem.instance.list().isEmpty());
        // Flags off: the game's methods run.
        Patches.ENABLE_LUA_WALK = false; Patches.ENABLE_FILE_WALK = false; Patches.ENABLE_GAME_WALK = false;
        check("flags off leave the game's walks", !Patches.luaWalk(new File(a[0]).toURI(), new File(a[0])) && !Patches.fileWalk(ZomboidFileSystem.instance, new File(a[0]))
                && !Patches.gameWalk(new File(a[0]), "mod A", true, (file, r) -> {}));
        System.out.println(fails == 0 ? "ALL OK" : fails + " FAILED");
        if (fails > 0) System.exit(1);
    }
}
