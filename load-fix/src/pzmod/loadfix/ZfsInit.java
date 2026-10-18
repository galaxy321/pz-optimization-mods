package pzmod.loadfix;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.Field;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import zombie.ZomboidFileSystem;

/**
 * ZomboidFileSystem.init(), written out from the bytecode of projectzomboid.jar,
 * with one change: for each path of the game folder listing, the game asks
 * isDirectory() to decide on a trailing separator (0.4.0's reload: init's own time
 * was 17% of game-thread samples). For a path the file listing just added, that
 * answer is known (Patches.knownKinds); for any other path it is asked as the game
 * does. Every other step is the game's, in the game's order, through the game's
 * own methods (PZFolder.set, searchFolders, getRelativeFile).
 */
public final class ZfsInit {
    private ZfsInit() {}

    static Field localWorkdir, workdir, anims, animsX, animSets, actiongroups, loadList, allAbsolutePaths;

    /** Looks up the private fields once. False if any is missing (then the game's init runs). */
    static synchronized boolean ready() {
        if (allAbsolutePaths != null) return true;
        try {
            Class<?> z = ZomboidFileSystem.class;
            Field[] fs = {
                z.getDeclaredField("localWorkdir"), z.getDeclaredField("workdir"), z.getDeclaredField("anims"),
                z.getDeclaredField("animsX"), z.getDeclaredField("animSets"), z.getDeclaredField("actiongroups"),
                z.getDeclaredField("loadList"), z.getDeclaredField("allAbsolutePaths")};
            for (Field f : fs) f.setAccessible(true);
            localWorkdir = fs[0]; workdir = fs[1]; anims = fs[2]; animsX = fs[3]; animSets = fs[4];
            actiongroups = fs[5]; loadList = fs[6]; allAbsolutePaths = fs[7];
            return true;
        } catch (Throwable e) {
            return false;
        }
    }

    @SuppressWarnings("unchecked")
    public static void run(ZomboidFileSystem z) throws IOException, IllegalAccessException {
        z.base.set(new File("./"));
        ZomboidFileSystem.PZFolder work = (ZomboidFileSystem.PZFolder) workdir.get(z);
        work.set(new File(z.base.canonicalFile, "media"));
        localWorkdir.set(z, z.base.canonicalFile.toPath().relativize(work.canonicalFile.toPath()).toFile());
        ((ZomboidFileSystem.PZFolder) anims.get(z)).set(new File(work.canonicalFile, "anims"));
        ((ZomboidFileSystem.PZFolder) animsX.get(z)).set(new File(work.canonicalFile, "anims_X"));
        ((ZomboidFileSystem.PZFolder) animSets.get(z)).set(new File(work.canonicalFile, "AnimSets"));
        ((ZomboidFileSystem.PZFolder) actiongroups.get(z)).set(new File(work.canonicalFile, "actiongroups"));
        z.searchFolders(work.canonicalFile);
        List<String> list = (List<String>) loadList.get(z);
        Set<String> all = (Set<String>) allAbsolutePaths.get(z);
        Map<String, Boolean> kinds = Patches.knownKinds;
        for (int i = 0; i < list.size(); i++) {
            String rel = z.getRelativeFile(list.get(i));
            String p = list.get(i);
            File af = new File(p).getAbsoluteFile();
            String abs = af.getAbsolutePath();
            Boolean known = kinds == null ? null : kinds.get(p);
            boolean dir;
            if (known != null) { dir = known; Patches.initKnown++; }
            else { dir = af.isDirectory(); Patches.initOther++; }
            if (dir) abs = abs + File.separator;
            z.activeFileMap.put(rel.toLowerCase(Locale.ENGLISH), abs);
            all.add(abs);
        }
        list.clear();
    }
}
