import java.io.File;
import java.lang.reflect.Field;
import java.net.URI;
import java.util.ArrayList;
import java.util.List;
import pzmod.loadfix.Patches;
import zombie.Lua.LuaManager;
import zombie.ZomboidFileSystem;

// Applies the mod's patches to the stand-in game classes with ZombieBuddy's own
// PatchEngine (the jar's code, through a minimal agent, TestAgent), the way the game gets
// them, then checks every patched method was really replaced (its counter moved)
// and still gives what the stand-in gave before patching. The stand-ins are loaded
// and used first, as the game's classes are by the time a mod jar loads, so this
// also covers retransforming an already-loaded class. 0.2.0's file listing would
// fail here: its advice matched nothing.
//   java -javaagent:<TestAgent jar> -cp <stubs>:<mod>:<ZombieBuddy.jar>:<this> ZBIntegrationTest <tree>
public class ZBIntegrationTest {
    static int fails;
    static void check(String what, boolean ok) { System.out.println((ok ? "ok   " : "FAIL ") + what); if (!ok) fails++; }

    record Run(List<String> lua, List<String> files, List<String> rel, List<String> visits, String init) {}

    // ZomboidFileSystem.init on the stand-in game folder (the working directory),
    // and everything it leaves behind.
    static String init() {
        ZomboidFileSystem z = ZomboidFileSystem.instance;
        z.activeFileMap.clear(); z.all().clear();
        try { z.init(); } catch (Exception e) { throw new RuntimeException(e); }
        ZomboidFileSystem.PZFolder b = z.base;
        return new java.util.TreeMap<>(z.activeFileMap) + "\n" + new java.util.TreeSet<>(z.all()) + "\n" + z.localWorkdir()
                + "\n" + b.absoluteFile + " " + b.canonicalFile + " " + b.canonicalUri + " " + b.lowercaseUri + "\n" + z.list();
    }

    static Run run(File root) {
        ZomboidFileSystem z = ZomboidFileSystem.instance;
        URI base = root.toURI();
        LuaManager.loadList.clear();
        try { LuaManager.searchFolders(base, root); } catch (Exception e) { throw new RuntimeException(e); }
        List<String> lua = new ArrayList<>(LuaManager.loadList);
        z.list().clear(); z.searchFolders(root);
        List<String> files = new ArrayList<>(z.list());
        List<String> rel = new ArrayList<>();
        for (String p : files) rel.add(z.getRelativeFile(base, p));
        List<String> visits = new ArrayList<>();
        z.walkGameAndModFilesInternal(root, "lower", true, (f, r) -> visits.add(f.getPath() + "|" + r + "|" + f.isFile() + "|" + f.isDirectory()));
        return new Run(lua, files, rel, visits, init());
    }

    // Two file listings, then relative paths for the first one's files (0.5.0 knew
    // only the last listing's paths; loadMod lists a mod's common and version folders).
    static List<String> twoListings(File root) {
        ZomboidFileSystem z = ZomboidFileSystem.instance;
        URI base = root.toURI();
        z.list().clear(); z.searchFolders(new File(root, "lower"));
        List<String> first = new ArrayList<>(z.list());
        z.list().clear(); z.searchFolders(new File(root, "game"));
        List<String> rel = new ArrayList<>();
        for (String p : first) rel.add(z.getRelativeFile(base, p));
        return rel;
    }

    static String folders(zombie.gameStates.ChooseGameInfo.Mod m) {
        StringBuilder b = new StringBuilder();
        for (ZomboidFileSystem.PZModFolder mf : new ZomboidFileSystem.PZModFolder[] {m.baseFile, m.mediaFile, m.actionGroupsFile, m.animSetsFile, m.animsXFile})
            for (ZomboidFileSystem.PZFolder p : new ZomboidFileSystem.PZFolder[] {mf.common, mf.version})
                b.append(p.absoluteFile).append(' ').append(p.canonicalFile).append(' ').append(p.canonicalUri).append(' ').append(p.lowercaseUri).append('\n');
        return b.toString();
    }

    public static void main(String[] a) throws Exception {
        File root = new File(a[0]);
        Run before = run(root);
        List<String> twoBefore = twoListings(root);
        // The boot's mod list, read before the jar loads (so before any patch).
        File modDir = new File(root, "lower");
        String bootMod = folders(zombie.gameStates.ChooseGameInfo.readModInfo(modDir.getPath()));

        java.lang.instrument.Instrumentation inst = TestAgent.inst;
        Field f = Class.forName("me.zed_0xff.zombie_buddy.Loader").getDeclaredField("g_instrumentation");
        f.setAccessible(true);
        f.set(null, inst);
        me.zed_0xff.zombie_buddy.PatchEngine.applyPatches("pzmod.loadfix", ClassLoader.getSystemClassLoader());

        Patches.luaCalls = Patches.fileCalls = Patches.gameCalls = Patches.relKnown = Patches.initCalls = Patches.initKnown = 0;
        Run after = run(root);
        check("Lua listing patched (" + Patches.luaCalls + " walks) and identical", Patches.luaCalls > 0 && before.lua().equals(after.lua()));
        check("file listing patched (" + Patches.fileCalls + " walks) and identical", Patches.fileCalls > 0 && before.files().equals(after.files()));
        check("relative paths patched (" + Patches.relKnown + " from the listing) and identical", Patches.relKnown > 0 && before.rel().equals(after.rel()));
        check("game+mod file walk patched (" + Patches.gameCalls + " walks) and identical", Patches.gameCalls > 0 && before.visits().equals(after.visits()));
        check("init patched (" + Patches.initCalls + ", " + Patches.initKnown + " paths from the listing) and identical",
                Patches.initCalls > 0 && Patches.initKnown > 0 && before.init().equals(after.init()));
        if (!before.init().equals(after.init())) System.out.println("  game:\n" + before.init() + "\n  patched:\n" + after.init());
        // A folder set twice in one Lua load: the second time from the cache, same fields.
        ZomboidFileSystem.PZFolder p1 = new ZomboidFileSystem.PZFolder(), p2 = new ZomboidFileSystem.PZFolder();
        File mod = new File(root, "lower");
        int sets = ZomboidFileSystem.PZFolder.sets;
        p1.set(mod); p2.set(mod);
        check("folder set twice: game ran once, cache once, same fields",
                ZomboidFileSystem.PZFolder.sets == sets + 1 && Patches.folderHits > 0
                && p1.absoluteFile.equals(p2.absoluteFile) && p1.canonicalFile.equals(p2.canonicalFile)
                && p1.canonicalUri.equals(p2.canonicalUri) && p1.lowercaseUri.equals(p2.lowercaseUri));
        Patches.report();
        Patches.relKnown = Patches.relOther = 0;
        List<String> twoAfter = twoListings(root);
        check("relative paths from an earlier listing (" + Patches.relKnown + " known, " + Patches.relOther + " the game's way) and identical",
                !twoBefore.isEmpty() && Patches.relKnown == twoBefore.size() && Patches.relOther == 0 && twoBefore.equals(twoAfter));
        Patches.report();
        // A reload: Reset keeps the boot's mod folders, so reading the mod again sets none.
        int sets2 = ZomboidFileSystem.PZFolder.sets;
        zombie.gameStates.ChooseGameInfo.Reset();
        String reloadMod = folders(zombie.gameStates.ChooseGameInfo.readModInfo(modDir.getPath()));
        check("reload: " + Patches.folderHarvested + " mod folders kept, game set " + (ZomboidFileSystem.PZFolder.sets - sets2) + ", same fields",
                Patches.folderHarvested >= 10 && ZomboidFileSystem.PZFolder.sets == sets2 && bootMod.equals(reloadMod));
        // A folder that appeared since: the game sets that one again, and gets the new answer.
        File v = new File(modDir, "42");
        check("version folder absent before", !v.exists() && v.mkdir());
        int sets3 = ZomboidFileSystem.PZFolder.sets;
        long stale = Patches.folderStale;
        zombie.gameStates.ChooseGameInfo.Reset();
        String afterMkdir = folders(zombie.gameStates.ChooseGameInfo.readModInfo(modDir.getPath()));
        Patches.ENABLE_FOLDER_CACHE = false;
        String gameAfterMkdir = folders(new zombie.gameStates.ChooseGameInfo.Mod(modDir.getPath()));
        Patches.ENABLE_FOLDER_CACHE = true;
        check("changed folder set by the game (" + (Patches.folderStale - stale) + " changed), same fields as the game's",
                Patches.folderStale - stale == 1 && ZomboidFileSystem.PZFolder.sets == sets3 + 1 + 10 && afterMkdir.equals(gameAfterMkdir)
                && afterMkdir.contains(v.toURI().toString()));
        v.delete();
        System.out.println(fails == 0 ? "ZB INTEGRATION OK" : fails + " FAILED");
        if (fails > 0) System.exit(1);
    }
}
