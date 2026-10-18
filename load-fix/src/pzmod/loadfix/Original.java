package pzmod.loadfix;

import java.io.File;
import java.io.IOException;
import java.util.List;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

/**
 * The game's three walks, written out from the bytecode of projectzomboid.jar
 * (LuaManager.searchFolders, ZomboidFileSystem.searchFolders and
 * ZomboidFileSystem.walkGameAndModFilesInternal), and getRelativeFile,, used only to
 * check FastWalk gives the same results.
 */
public final class Original {
    private Original() {}

    public static void luaSearchFolders(File f, Consumer<String> luaFile) throws IOException {
        if (f.isDirectory()) {
            String[] names = f.list();
            for (int i = 0; i < names.length; i++) {
                luaSearchFolders(new File(f.getCanonicalFile().getAbsolutePath() + File.separator + names[i]), luaFile);
            }
        } else if (f.getAbsolutePath().toLowerCase().endsWith(".lua")) {
            luaFile.accept(f.getAbsolutePath());
        }
    }

    public static void zfsSearchFolders(File f, List<String> loadList, Runnable perEntry) {
        perEntry.run();
        if (f.isDirectory()) {
            String p = f.getAbsolutePath().replace("\\", "/").replace("./", "");
            if (p.contains("media/maps/")) loadList.add(p);
            String[] names = f.list();
            for (int i = 0; i < names.length; i++) {
                zfsSearchFolders(new File(f.getAbsolutePath() + File.separator + names[i]), loadList, perEntry);
            }
        } else {
            loadList.add(f.getAbsolutePath().replace("\\", "/").replace("./", ""));
        }
    }

    public static void gameWalk(File base, String rel, boolean recursive, BiConsumer<File, String> visit) {
        File dir = new File(base, rel);
        if (!dir.isDirectory()) return;
        File[] entries = dir.listFiles();
        if (entries == null) return;
        for (File e : entries) {
            visit.accept(e, rel);
            if (recursive && e.isDirectory()) gameWalk(base, rel + "/" + e.getName(), true, visit);
        }
    }

    /** ZomboidFileSystem.getRelativeFile(URI, String). */
    public static String relativeFile(java.net.URI base, String path) {
        String abs = new File(path).getAbsolutePath();
        java.net.URI u = new File(abs.toLowerCase(java.util.Locale.ENGLISH)).toURI();
        java.net.URI r = base.relativize(u);
        if (r.equals(u)) return path;
        String rel = r.getPath();
        if (path.endsWith("/") && !rel.endsWith("/")) rel = rel + "/";
        return rel;
    }
}
