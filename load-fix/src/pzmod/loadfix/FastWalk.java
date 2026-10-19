package pzmod.loadfix;

import java.io.File;
import java.io.IOException;
import java.net.URI;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

/**
 * Faster versions of the three folder walks Project Zomboid runs on every boot and
 * every Lua reload. Each one gives the same paths, in the same order, as the
 * game's method it stands in for (see Original.java for the game's code, copied
 * from the bytecode of projectzomboid.jar, build 42).
 */
public final class FastWalk {
    private FastWalk() {}

    /**
     * Stands in for LuaManager.searchFolders(URI, File).
     * The game calls dir.getCanonicalFile() once for every entry of a folder; this
     * calls it once per folder. Same call, same folder, so the same string.
     * luaFile receives the absolute path of each .lua file, where the game passes
     * it to ZomboidFileSystem.getRelativeFile(base, path) and adds the result.
     */
    public static void luaSearchFolders(File f, Consumer<String> luaFile) throws IOException {
        if (f.isDirectory()) {
            String[] names = f.list();
            int n = names.length;              // a null listing throws here, as in the game
            if (n == 0) return;
            String parent = f.getCanonicalFile().getAbsolutePath();
            for (int i = 0; i < n; i++) {
                luaSearchFolders(new File(parent + File.separator + names[i]), luaFile);
            }
        } else if (f.getAbsolutePath().toLowerCase().endsWith(".lua")) {
            luaFile.accept(f.getAbsolutePath());
        }
    }

    /**
     * Second, faster stand-in for LuaManager.searchFolders(URI, File).
     * luaSearchFolders still asks isDirectory() of every entry and resolves every
     * folder's canonical path (0.1.1 measured 3.5 s for 894 walks). Here the root's
     * canonical path is resolved once and the walk starts from it, so each path
     * the NIO walk builds (canonical parent + separator + listed name) is already
     * the string the game builds. A folder's canonical path is its parent's plus
     * its listed name unless it's a link or a junction, so links and junctions
     * (symbolic links, and reparse-point folders, which NIO reports as "other")
     * are handed to luaSearchFolders, which does it the game's way.
     */
    public static void luaSearchFoldersNio(File f, Consumer<String> luaFile) throws IOException {
        if (!f.isDirectory()) {
            luaSearchFolders(f, luaFile);
            return;
        }
        String[] probe = f.list();
        if (probe.length == 0) return;          // the game resolves nothing for an empty folder
        Path root = Paths.get(f.getCanonicalFile().getAbsolutePath());
        IOException[] failed = new IOException[1];
        Files.walkFileTree(root, EnumSet.noneOf(FileVisitOption.class), Integer.MAX_VALUE,
                new SimpleFileVisitor<>() {
                    @Override public FileVisitResult preVisitDirectory(Path d, BasicFileAttributes a) throws IOException {
                        if (d != root && a.isOther()) {     // junction or other reparse folder
                            luaSearchFolders(new File(d.toString()), luaFile);
                            return FileVisitResult.SKIP_SUBTREE;
                        }
                        return FileVisitResult.CONTINUE;
                    }
                    @Override public FileVisitResult visitFile(Path file, BasicFileAttributes a) throws IOException {
                        String path = file.toString();
                        if (a.isSymbolicLink() || a.isOther()) {
                            luaSearchFolders(new File(path), luaFile);
                        } else if (path.toLowerCase().endsWith(".lua")) {
                            luaFile.accept(path);
                        }
                        return FileVisitResult.CONTINUE;
                    }
                    @Override public FileVisitResult visitFileFailed(Path file, IOException e) {
                        failed[0] = e;                      // the game would fail too; let it
                        return FileVisitResult.TERMINATE;
                    }
                });
        if (failed[0] != null) throw failed[0];
    }

    /**
     * Stands in for ZomboidFileSystem.searchFolders(File).
     * The game asks isDirectory() of every entry, one file-system call each. An NIO
     * walk gets that from the folder listing it already has. Folders under
     * media/maps/ and every file are added to loadList in the same depth-first,
     * folder-before-contents order, with the game's string clean-up.
     * perEntry runs once per entry, where the game yields and polls the keyboard.
     *
     * The walk doesn't follow links itself: following them makes NIO ask the file
     * system about every entry again (0.2.1 measured 1.8-2.0 s for 446 walks). A link
     * or junction is handed to zfsSearchFoldersGameWay at the point the game would
     * reach it, which does what the game does with it.
     */
    public static void zfsSearchFolders(File f, List<String> loadList, Runnable perEntry) throws IOException {
        zfsSearchFolders(f, loadList, perEntry, null);
    }

    /** As above; kinds (if not null) also gets, for each path added from the NIO
     *  listing, whether it is a folder. Paths added the game's way are left out. */
    public static void zfsSearchFolders(File f, List<String> loadList, Runnable perEntry, Map<String, Boolean> kinds) throws IOException {
        Path root = Paths.get(f.getAbsolutePath());
        BasicFileAttributes ra;
        try {
            ra = Files.readAttributes(root, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        } catch (IOException e) {
            zfsSearchFoldersGameWay(f, loadList, perEntry);    // missing: the game adds it as a file
            return;
        }
        if (ra.isSymbolicLink() || ra.isOther()) {
            zfsSearchFoldersGameWay(f, loadList, perEntry);
            return;
        }
        Files.walkFileTree(root, EnumSet.noneOf(FileVisitOption.class), Integer.MAX_VALUE,
                new SimpleFileVisitor<>() {
                    @Override public FileVisitResult preVisitDirectory(Path d, BasicFileAttributes a) {
                        if (d != root && a.isOther()) {     // junction or other reparse folder
                            zfsSearchFoldersGameWay(new File(d.toString()), loadList, perEntry);
                            return FileVisitResult.SKIP_SUBTREE;
                        }
                        perEntry.run();
                        String p = clean(d.toString());
                        if (p.contains("media/maps/")) {
                            loadList.add(p);
                            if (kinds != null) kinds.put(p, Boolean.TRUE);
                        }
                        return FileVisitResult.CONTINUE;
                    }
                    @Override public FileVisitResult visitFile(Path file, BasicFileAttributes a) {
                        if (a.isSymbolicLink() || a.isOther()) {
                            zfsSearchFoldersGameWay(new File(file.toString()), loadList, perEntry);
                        } else {
                            perEntry.run();
                            String p = clean(file.toString());
                            loadList.add(p);
                            if (kinds != null) kinds.put(p, Boolean.FALSE);
                        }
                        return FileVisitResult.CONTINUE;
                    }
                    @Override public FileVisitResult visitFileFailed(Path file, IOException e) {
                        // The game adds a path it can't see into as a file.
                        perEntry.run();
                        loadList.add(clean(file.toString()));
                        return FileVisitResult.CONTINUE;
                    }
                });
    }

    /** The game's searchFolders, for links and junctions (Original.zfsSearchFolders,
     *  except that an unreadable folder is skipped instead of throwing, as the NIO
     *  walk does). Below a link everything is done the game's way. */
    static void zfsSearchFoldersGameWay(File f, List<String> loadList, Runnable perEntry) {
        perEntry.run();
        if (f.isDirectory()) {
            String p = clean(f.getAbsolutePath());
            if (p.contains("media/maps/")) loadList.add(p);
            String[] names = f.list();
            if (names == null) return;
            for (String name : names) {
                zfsSearchFoldersGameWay(new File(f.getAbsolutePath() + File.separator + name), loadList, perEntry);
            }
        } else {
            loadList.add(clean(f.getAbsolutePath()));
        }
    }

    /**
     * Stands in for ZomboidFileSystem.walkGameAndModFilesInternal(File, String, boolean,
     * IWalkFilesVisitor), behind resolveAllFiles and resolveAllDirectories (pzopt's Lua
     * precompile lists through it at boot: 3.1 s). The game lists each folder with
     * listFiles() and asks isDirectory() of every entry, and the usual visitor asks
     * isFile() as well: two file-system calls per entry. Here each folder is listed
     * once with NIO, which brings both answers with the listing, and the visitor gets
     * KnownFile objects carrying them. Same entries, same order, same path strings,
     * same visitor calls. If NIO can't list a folder, that folder is listed with
     * listFiles() as the game does (fellBack counts those). Errors from the visitor
     * itself are not caught, as in the game.
     */
    public static void gameWalk(File base, String rel, boolean recursive, BiConsumer<File, String> visit, int[] fellBack) {
        File dir = new File(base, rel);
        if (!dir.isDirectory()) return;
        File[] entries = list(dir, fellBack);
        if (entries == null) return;
        for (File e : entries) {
            visit.accept(e, rel);
            if (recursive && e.isDirectory()) gameWalk(base, rel + "/" + e.getName(), true, visit, fellBack);
        }
    }

    /** One folder's entries in listing order: KnownFile for plain files and folders,
     *  a plain File (asked the game's way) for links, junctions and anything else.
     *  A folder NIO can't list, or that is itself a link, is listed with listFiles(). */
    static File[] list(File dir, int[] fellBack) {
        try {
            File[] fast = listNio(dir);
            if (fast != null) return fast;
        } catch (IOException | RuntimeException e) {
            // listed below, the game's way
        }
        fellBack[0]++;
        return dir.listFiles();
    }

    static File[] listNio(File dir) throws IOException {
        Path root = dir.toPath();
        BasicFileAttributes ra = Files.readAttributes(root, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        if (!ra.isDirectory() || ra.isSymbolicLink() || ra.isOther()) return null;
        List<File> out = new ArrayList<>();
        boolean[] failed = new boolean[1];
        Files.walkFileTree(root, EnumSet.noneOf(FileVisitOption.class), 1, new SimpleFileVisitor<>() {
            @Override public FileVisitResult visitFile(Path p, BasicFileAttributes a) {
                if (p.equals(root)) { failed[0] = true; return FileVisitResult.TERMINATE; }
                String name = p.getFileName().toString();
                out.add(a.isSymbolicLink() || a.isOther() ? new File(dir, name)
                        : new KnownFile(dir, name, a.isDirectory(), a.isRegularFile()));
                return FileVisitResult.CONTINUE;
            }
            @Override public FileVisitResult visitFileFailed(Path p, IOException e) {
                failed[0] = true;
                return FileVisitResult.TERMINATE;
            }
        });
        return failed[0] ? null : out.toArray(new File[0]);
    }

    /**
     * ZomboidFileSystem.getRelativeFile(URI, String), with whether path is a folder
     * given instead of asked of the file system (File.toURI() asks). The game asks
     * about the lower-cased path; that's the same answer only on a case-insensitive
     * file system, so elsewhere a path with capitals gives null (ask the game).
     */
    public static String relativeFile(URI base, String path, boolean isDir, boolean caseInsensitiveFs) {
        String abs = new File(path).getAbsolutePath();
        String lower = abs.toLowerCase(Locale.ENGLISH);
        if (!caseInsensitiveFs && !lower.equals(abs)) return null;
        URI u = new KnownFile(lower, isDir, !isDir).toURI();
        URI r = base.relativize(u);
        if (r.equals(u)) return path;
        String rel = r.getPath();
        if (path.endsWith("/") && !rel.endsWith("/")) rel = rel + "/";
        return rel;
    }

    static String clean(String absolutePath) {
        return absolutePath.replace("\\", "/").replace("./", "");
    }
}
