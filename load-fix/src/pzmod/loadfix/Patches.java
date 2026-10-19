package pzmod.loadfix;

import java.io.File;
import java.lang.reflect.Field;
import java.net.URI;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import me.zed_0xff.zombie_buddy.Patch;
import zombie.Lua.LuaManager;
import zombie.ZomboidFileSystem;
import zombie.core.Core;
import zombie.network.GameServer;

/**
 * Puts FastWalk in place of the game's three folder walks, and answers the game's
 * getRelativeFile for the paths the file listing found. The Lua and file
 * listings collect the walk's results in their own list first; only if the whole
 * walk succeeds are they added to the game's list and the game's method skipped.
 * On any error nothing is added and the game's own method runs, so a failure
 * costs time, not results. The game+mod file walk hands each entry to the game's
 * visitor as it goes, so it can't start over; instead any folder it can't list
 * with NIO is listed the game's way.
 *
 * The advice bodies are copied into the game's own classes, so everything they
 * call here must be public (0.1.0 crashed on a package-private report()), and
 * each body except the visitor walk's catches everything so a mistake here can't
 * stop the game.
 */
public class Patches {
    /** Part 1: LuaManager.searchFolders, canonical parent once per folder. */
    public static boolean ENABLE_LUA_WALK = !"false".equals(System.getProperty("loadfix.lua"));
    /** Part 1b: the Lua listing with NIO from the canonical root (FastWalk.luaSearchFoldersNio);
     *  -Dloadfix.luanio=false goes back to part 1's per-folder canonical walk. */
    public static boolean ENABLE_LUA_NIO = !"false".equals(System.getProperty("loadfix.luanio"));
    /** Part 2: ZomboidFileSystem.searchFolders, NIO listing; -Dloadfix.files=false turns it off. */
    public static boolean ENABLE_FILE_WALK = !"false".equals(System.getProperty("loadfix.files"));

    /** Part 3: ZomboidFileSystem.walkGameAndModFilesInternal (resolveAllFiles, pzopt's
     *  Lua precompile listing), NIO listing; -Dloadfix.gamewalk=false turns it off. */
    public static boolean ENABLE_GAME_WALK = !"false".equals(System.getProperty("loadfix.gamewalk"));

    public static long luaCalls, luaNs, luaFallbacks, fileCalls, fileNs, fileFallbacks;
    public static long gameCalls, gameNs, gameFolderFallbacks;

    /** Part 4: ZomboidFileSystem.getRelativeFile(URI, String). The game makes a URI of
     *  each listed path with File.toURI(), which asks the file system whether it is a
     *  folder (0.3.0's reload: 29% of game-thread samples). For a path the last file
     *  listing found, that answer is known. -Dloadfix.relpath=false turns it off. */
    public static boolean ENABLE_REL_PATH = !"false".equals(System.getProperty("loadfix.relpath"));
    /** Folder or not, for each path the last file listing added; replaced by each walk. */
    public static volatile Map<String, Boolean> knownKinds;
    /** 0.5.1: the same for every file listing since this Lua load began (0.5.0 looked
     *  only at the last listing, and 57,661 of 102,778 paths on the PC went the game's way). */
    public static final Map<String, Boolean> loadKinds = new java.util.concurrent.ConcurrentHashMap<>();
    public static long relNoListing;
    /** The first few paths that went the game's way, and who asked, for the report. */
    static final List<String> missSamples = java.util.Collections.synchronizedList(new ArrayList<>());
    static final int MISS_SAMPLES = 12;
    static final boolean CASE_INSENSITIVE_FS = File.separatorChar == '\\';
    public static long relKnown, relOther;

    /** Part 5a: ZomboidFileSystem.init with the listing's folder-or-not answers
     *  (ZfsInit). -Dloadfix.init=false turns it off. */
    public static boolean ENABLE_INIT = !"false".equals(System.getProperty("loadfix.init"));
    public static long initCalls, initKnown, initOther;

    /** Part 5b: PZFolder.set(File) resolves the folder's canonical path and makes two
     *  URIs (two "is it a folder?" calls). ChooseGameInfo builds ten of them for every
     *  installed mod on each Lua load (0.5.1's reload: 3,326 sets, 2.3 s). Each folder is
     *  set once per load, so 0.5.0's within-one-load cache never hit. From 0.5.2 the cache
     *  keeps folders across loads, and ChooseGameInfo.Reset, which runs before a reload
     *  reads the mods again, adds the folders of every mod it is about to forget (the
     *  boot's, set before this jar loaded). A cached folder is used only if the file
     *  system still gives the same folder-or-not answer for it; otherwise the game sets
     *  it. -Dloadfix.foldercache=false turns it off. */
    public static boolean ENABLE_FOLDER_CACHE = !"false".equals(System.getProperty("loadfix.foldercache"));
    public static final Map<String, Object[]> folderCache = new java.util.concurrent.ConcurrentHashMap<>();
    public static long folderHits, folderMisses, folderStale, folderHarvested;
    public static boolean reportedFirstFallback;

    @Patch(className = "zombie.Lua.LuaManager", methodName = "searchFolders")
    public static class Patch_luaSearchFolders {
        @Patch.OnEnter(skipOn = true)
        public static boolean enter(URI base, File dir) {
            try {
                return luaWalk(base, dir);
            } catch (Throwable e) {
                return false;   // anything unexpected: the game's own walk runs
            }
        }
    }

    @Patch(className = "zombie.ZomboidFileSystem", methodName = "searchFolders")
    public static class Patch_zfsSearchFolders {
        // dir needs @Patch.Argument(0): ZombieBuddy takes an unannotated parameter's
        // position in this method as its position in the game's, so after @Patch.This
        // it looked for a second argument and patched nothing (0.2.0).
        @Patch.OnEnter(skipOn = true)
        public static boolean enter(@Patch.This Object self, @Patch.Argument(0) File dir) {
            try {
                return fileWalk(self, dir);
            } catch (Throwable e) {
                return false;
            }
        }
    }

    // No catch here: the walk calls the game's visitor, and an error from the visitor
    // must reach the game as it would from the game's own walk (catching it and
    // returning false would run the game's walk and visit everything twice). The
    // walk's own listing errors are handled inside it, one folder at a time.
    @Patch(className = "zombie.ZomboidFileSystem", methodName = "walkGameAndModFilesInternal")
    public static class Patch_walkGameAndModFiles {
        @Patch.OnEnter(skipOn = true)
        public static boolean enter(File base, String rel, boolean recursive, ZomboidFileSystem.IWalkFilesVisitor visitor) {
            return gameWalk(base, rel, recursive, visitor);
        }
    }

    // strictMatch: without it ZombieBuddy would also match the one-argument overloads,
    // because the exit advice has only special parameters.
    @Patch(className = "zombie.ZomboidFileSystem", methodName = "getRelativeFile", strictMatch = true)
    public static class Patch_getRelativeFile {
        @Patch.OnEnter(skipOn = true)
        public static boolean enter(URI base, String path, @Patch.Local("lfRel") String rel) {
            try {
                rel = relativeFile(base, path);
            } catch (Throwable e) {
                rel = null;
            }
            return rel != null;         // null: the game's own method runs
        }

        @Patch.OnExit
        public static void exit(@Patch.Return(readOnly = false) String ret, @Patch.Local("lfRel") String rel) {
            if (rel != null) ret = rel;
        }
    }

    // Part 5a. No catch-all: once ZfsInit.run starts it has changed the game's state,
    // so an error must reach the game as it would from the game's own init. Before
    // that, a missing field means false: the game's init runs.
    @Patch(className = "zombie.ZomboidFileSystem", methodName = "init", strictMatch = true)
    public static class Patch_init {
        @Patch.OnEnter(skipOn = true)
        public static boolean enter(@Patch.This Object self) throws Exception {
            return zfsInit(self);
        }
    }

    // Part 5b. Same path, same answers, within one Lua load: see setFolder.
    @Patch(className = "zombie.ZomboidFileSystem$PZFolder", methodName = "set")
    public static class Patch_PZFolderSet {
        @Patch.OnEnter(skipOn = true)
        public static boolean enter(@Patch.This Object self, @Patch.Argument(0) File f) {
            try {
                return setFolderFromCache(self, f);
            } catch (Throwable e) {
                return false;
            }
        }

        @Patch.OnExit
        public static void exit(@Patch.This Object self, @Patch.Argument(0) File f) {
            try {
                rememberFolder(self, f);
            } catch (Throwable ignored) {
            }
        }
    }

    // Part 5b: before the game forgets the mods it read (and their folders), keep the folders.
    @Patch(className = "zombie.gameStates.ChooseGameInfo", methodName = "Reset", strictMatch = true)
    public static class Patch_ChooseGameInfoReset {
        @Patch.OnEnter
        public static void enter() {
            try {
                harvestModFolders();
            } catch (Throwable ignored) {
            }
        }
    }

    /** One summary line each time the Lua files have been listed and loaded. */
    @Patch(className = "zombie.Lua.LuaManager", methodName = "LoadDirBase", strictMatch = true)
    public static class Patch_LoadDirBase {
        @Patch.OnExit
        public static void exit() {
            try {
                report();
            } catch (Throwable ignored) {
            }
        }
    }

    public static boolean luaWalk(URI base, File dir) {
        if (!ENABLE_LUA_WALK) return false;
        long t0 = System.nanoTime();
        List<String> found = new ArrayList<>();
        try {
            // Every path the walk hands over is a file (folders are walked into), so the
            // game's getRelativeFile is worked out without asking (part 4).
            java.util.function.Consumer<String> add = path -> {
                String rel = ENABLE_REL_PATH && base != null ? FastWalk.relativeFile(base, path, false, CASE_INSENSITIVE_FS) : null;
                if (rel == null) rel = ZomboidFileSystem.instance.getRelativeFile(base, path);
                found.add(rel.toLowerCase(Locale.ENGLISH));
            };
            if (ENABLE_LUA_NIO) FastWalk.luaSearchFoldersNio(dir, add);
            else FastWalk.luaSearchFolders(dir, add);
        } catch (Throwable e) {
            luaFallbacks++;
            fallback("Lua", dir, e);
            return false;
        }
        LuaManager.loadList.addAll(found);
        luaCalls++;
        luaNs += System.nanoTime() - t0;
        return true;
    }

    private static Field zfsLoadList;

    @SuppressWarnings("unchecked")
    public static boolean fileWalk(Object self, File dir) {
        if (!ENABLE_FILE_WALK) return false;
        long t0 = System.nanoTime();
        List<String> found = new ArrayList<>();
        Map<String, Boolean> kinds = ENABLE_REL_PATH ? new HashMap<>() : null;
        List<String> target;
        try {
            if (zfsLoadList == null) {
                Field f = ZomboidFileSystem.class.getDeclaredField("loadList");
                f.setAccessible(true);
                zfsLoadList = f;
            }
            target = (List<String>) zfsLoadList.get(self);
            boolean client = !GameServer.server;
            FastWalk.zfsSearchFolders(dir, found, () -> {
                if (client) {
                    Thread.yield();
                    Core.getInstance().DoFrameReady();
                }
            }, kinds);
        } catch (Throwable e) {
            knownKinds = null;
            fileFallbacks++;
            fallback("file", dir, e);
            return false;
        }
        knownKinds = kinds;
        if (kinds != null) loadKinds.putAll(kinds);
        target.addAll(found);
        fileCalls++;
        fileNs += System.nanoTime() - t0;
        return true;
    }

    public static boolean gameWalk(File base, String rel, boolean recursive, ZomboidFileSystem.IWalkFilesVisitor visitor) {
        if (!ENABLE_GAME_WALK) return false;
        long t0 = System.nanoTime();
        int[] fellBack = new int[1];
        FastWalk.gameWalk(base, rel, recursive, visitor::visit, fellBack);
        gameCalls++;
        gameFolderFallbacks += fellBack[0];
        gameNs += System.nanoTime() - t0;
        return true;
    }

    /** The game's getRelativeFile(URI, String), with the folder-or-not answer taken
     *  from the last file listing; null (so the game's method runs) for any other path.
     *  The game lower-cases the path before asking, so on a case-sensitive file
     *  system a path with capitals is left to the game. */
    public static String relativeFile(URI base, String path) {
        if (!ENABLE_REL_PATH || base == null || path == null) return null;
        if (loadKinds.isEmpty()) {
            relNoListing++;
            return null;
        }
        Boolean dir = loadKinds.get(path);
        String rel = dir == null ? null : FastWalk.relativeFile(base, path, dir, CASE_INSENSITIVE_FS);
        if (rel != null) {
            relKnown++;
            return rel;
        }
        relOther++;
        if (missSamples.size() < MISS_SAMPLES) sampleMiss(path, dir);
        return null;
    }

    /** Records a path and the first game frames above getRelativeFile. */
    public static void sampleMiss(String path, Boolean dir) {
        StringBuilder b = new StringBuilder(path).append(dir == null ? " (not listed)" : " (listed, capitals)").append(" <-");
        int n = 0;
        for (StackTraceElement e : new Throwable().getStackTrace()) {
            String c = e.getClassName();
            if (c.startsWith("pzmod.loadfix.") || e.getMethodName().equals("getRelativeFile") && n == 0) continue;
            b.append(' ').append(c.substring(c.lastIndexOf('.') + 1)).append('.').append(e.getMethodName()).append(':').append(e.getLineNumber());
            if (++n == 4) break;
        }
        missSamples.add(b.toString());
    }

    public static boolean zfsInit(Object self) throws Exception {
        loadKinds.clear();      // a new Lua load starts here
        if (!ENABLE_INIT || !(self instanceof ZomboidFileSystem) || !ZfsInit.ready()) return false;
        initCalls++;
        ZfsInit.run((ZomboidFileSystem) self);
        return true;
    }

    public static boolean setFolderFromCache(Object self, File f) {
        if (!ENABLE_FOLDER_CACHE || f == null) return false;
        File abs = f.getAbsoluteFile();
        Object[] r = folderCache.get(abs.getPath());
        if (r == null) {
            folderMisses++;
            return false;
        }
        File canonical = (File) r[0];
        URI canonicalUri = (URI) r[1], lowercaseUri = (URI) r[2];
        // toURI() ends a folder's URI with '/'. Ask once whether it is still a folder (and,
        // on a case-sensitive file system, the lower-cased path too).
        boolean dir = canonicalUri.getPath().endsWith("/"), lowerDir = lowercaseUri.getPath().endsWith("/");
        boolean same = canonical.isDirectory() == dir;
        if (same) {
            if (CASE_INSENSITIVE_FS) same = lowerDir == dir;
            else same = new File(canonical.getPath().toLowerCase(Locale.ENGLISH)).isDirectory() == lowerDir;
        }
        if (!same) {
            folderCache.remove(abs.getPath(), r);
            folderStale++;
            return false;
        }
        ZomboidFileSystem.PZFolder p = (ZomboidFileSystem.PZFolder) self;
        p.absoluteFile = abs;
        p.canonicalFile = canonical;
        p.canonicalUri = canonicalUri;
        p.lowercaseUri = lowercaseUri;
        folderHits++;
        return true;
    }

    /** After the game's set() returned normally: keep what it worked out. */
    public static void rememberFolder(Object self, File f) {
        if (!ENABLE_FOLDER_CACHE || f == null) return;
        remember((ZomboidFileSystem.PZFolder) self);
    }

    static boolean remember(ZomboidFileSystem.PZFolder p) {
        if (p == null || p.absoluteFile == null || p.canonicalFile == null || p.canonicalUri == null || p.lowercaseUri == null) return false;
        folderCache.put(p.absoluteFile.getPath(), new Object[] {p.canonicalFile, p.canonicalUri, p.lowercaseUri});
        return true;
    }

    private static Field chooseGameInfoMods;
    private static final String[] MOD_FOLDERS = {"baseFile", "mediaFile", "actionGroupsFile", "animSetsFile", "animsXFile"};
    private static final String[] MOD_SUBFOLDERS = {"common", "version"};

    /** Every folder of every mod ChooseGameInfo has read, into the folder cache. */
    public static void harvestModFolders() throws ReflectiveOperationException {
        if (!ENABLE_FOLDER_CACHE) return;
        if (chooseGameInfoMods == null) {
            Field f = Class.forName("zombie.gameStates.ChooseGameInfo").getDeclaredField("Mods");
            f.setAccessible(true);
            chooseGameInfoMods = f;
        }
        Map<?, ?> mods = (Map<?, ?>) chooseGameInfoMods.get(null);
        for (Object mod : mods.values()) {
            if (mod == null) continue;
            for (String name : MOD_FOLDERS) {
                Object mf = mod.getClass().getField(name).get(mod);
                if (mf == null) continue;
                for (String sub : MOD_SUBFOLDERS) {
                    if (remember((ZomboidFileSystem.PZFolder) mf.getClass().getField(sub).get(mf))) folderHarvested++;
                }
            }
        }
    }

    private static volatile boolean bakedStarted;
    /** Where the built-in (pzopt-style) classes list the game classes they were made from. */
    public static final String BAKED_INFO = "pzmod/loadfix/baked.properties";

    /**
     * Built into the game's classes (Baker), there is no ZombieBuddy to call Main, so the
     * first patched method to run does it (every baked advice calls this first). It also checks that projectzomboid.jar still
     * holds the classes these copies were made from; after a game update it turns every
     * part off and says which files to delete.
     */
    public static void bakedStart() {
        if (bakedStarted) return;
        synchronized (Patches.class) {
            if (bakedStarted) return;
            bakedStarted = true;
            bakedCheck();
        }
    }

    private static void bakedCheck() {
        String problem;
        try {
            problem = bakedMismatch();
        } catch (Throwable e) {
            problem = "could not check the game jar: " + e;
        }
        if (problem != null) {
            ENABLE_LUA_WALK = ENABLE_FILE_WALK = ENABLE_GAME_WALK = ENABLE_REL_PATH = ENABLE_INIT = ENABLE_FOLDER_CACHE = false;
            System.out.println("[LoadFix] OFF: " + problem + ". The game was probably updated since Load Fix was built."
                    + " Its patches are off, but its old copies of the game's classes still replace the updated ones and can break the game."
                    + " Run uninstall-loadfix-builtin.ps1 (or delete the files listed in loadfix-installed.txt in the game folder) before playing,"
                    + " then install a Load Fix built for this game version.");
            return;
        }
        System.out.println("[LoadFix] built into the game's classes, checked against projectzomboid.jar");
        Main.main(new String[0]);
    }

    /** null if every class named in baked.properties matches projectzomboid.jar, else what differs. */
    static String bakedMismatch() throws Exception {
        java.util.Properties info = new java.util.Properties();
        try (java.io.InputStream in = Patches.class.getClassLoader().getResourceAsStream(BAKED_INFO)) {
            if (in == null) return "no " + BAKED_INFO;
            info.load(in);
        }
        java.net.URL jarUrl = null;
        for (java.util.Enumeration<java.net.URL> e = Patches.class.getClassLoader().getResources("zombie/ZomboidFileSystem.class"); e.hasMoreElements(); ) {
            java.net.URL u = e.nextElement();
            if ("jar".equals(u.getProtocol()) && u.getPath().contains(info.getProperty("jar", "projectzomboid.jar") + "!")) jarUrl = u;
        }
        if (jarUrl == null) return "projectzomboid.jar not found on the classpath";
        String jarPath = jarUrl.getPath().substring(0, jarUrl.getPath().indexOf("!"));
        try (java.util.jar.JarFile jar = new java.util.jar.JarFile(new File(new URI(jarPath)))) {
            for (String name : info.stringPropertyNames()) {
                if (!name.startsWith("class.")) continue;
                String entry = name.substring("class.".length()).replace('.', '/') + ".class";
                java.util.zip.ZipEntry ze = jar.getEntry(entry);
                if (ze == null) return entry + " is no longer in projectzomboid.jar";
                byte[] bytes;
                try (java.io.InputStream in = jar.getInputStream(ze)) {
                    bytes = in.readAllBytes();
                }
                String hash = java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(bytes));
                if (!hash.equals(info.getProperty(name))) return entry + " in projectzomboid.jar has changed";
            }
        }
        return null;
    }

    public static void fallback(String which, File dir, Throwable e) {
        if (reportedFirstFallback) return;
        reportedFirstFallback = true;
        System.out.println("[LoadFix] " + which + " walk of " + dir + " fell back to the game's own: " + e);
    }

    public static void report() {
        System.out.printf("[LoadFix] Lua listing: %d walks, %.0f ms, %d fell back; file listing: %d walks, %.0f ms, %d fell back; "
                + "game+mod file walks: %d, %.0f ms, %d folders listed the game's way; relative paths: %d from the listing, %d the game's way, %d before any listing; "
                + "init: %d, %d paths from the listing, %d the game's way; folders: %d from the cache, %d set by the game, %d changed on disk, %d kept from the mod list%n",
                luaCalls, luaNs / 1e6, luaFallbacks, fileCalls, fileNs / 1e6, fileFallbacks, gameCalls, gameNs / 1e6, gameFolderFallbacks,
                relKnown, relOther, relNoListing, initCalls, initKnown, initOther, folderHits, folderMisses, folderStale, folderHarvested);
        luaCalls = luaNs = luaFallbacks = fileCalls = fileNs = fileFallbacks = 0;
        gameCalls = gameNs = gameFolderFallbacks = 0;
        synchronized (missSamples) {
            for (String m : missSamples) System.out.println("[LoadFix]   the game's way: " + m);
            missSamples.clear();
        }
        relKnown = relOther = relNoListing = 0;
        initCalls = initKnown = initOther = folderHits = folderMisses = folderStale = folderHarvested = 0;
        knownKinds = null;      // the game has used this reload's listings by now
        loadKinds.clear();
    }
}
