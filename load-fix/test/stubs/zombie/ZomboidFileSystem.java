package zombie;
// Test stand-in: the game's searchFolders (from the jar's bytecode), a private loadList,
// and a getRelativeFile that relativizes like the game's (exact rules don't matter here:
// both walks call it with the same arguments).
public class ZomboidFileSystem {
    public static final ZomboidFileSystem instance = new ZomboidFileSystem();
    private final java.util.List<String> loadList = new java.util.ArrayList<>();
    // init() and PZFolder, from the jar's bytecode.
    public static final class PZFolder {
        public java.io.File absoluteFile, canonicalFile;
        public java.net.URI canonicalUri, lowercaseUri;
        public static int sets;
        public void set(java.io.File f) throws java.io.IOException {
            sets++;
            absoluteFile = f.getAbsoluteFile();
            canonicalFile = absoluteFile.getCanonicalFile();
            canonicalUri = canonicalFile.toURI();
            lowercaseUri = new java.io.File(canonicalFile.getPath().toLowerCase(java.util.Locale.ENGLISH)).toURI();
        }
        public void setWithCatch(java.io.File f) {
            try { set(f); } catch (Exception e) { e.printStackTrace(); }
        }
    }
    public static final class PZModFolder {
        public PZFolder common = new PZFolder(), version = new PZFolder();
        public void setWithCatch(java.io.File c, java.io.File v) { common.setWithCatch(c); version.setWithCatch(v); }
    }
    public final java.util.Map<String, String> activeFileMap = new java.util.HashMap<>();
    private final java.util.Set<String> allAbsolutePaths = new java.util.HashSet<>();
    public final PZFolder base = new PZFolder();
    private final PZFolder workdir = new PZFolder();
    private java.io.File localWorkdir;
    private final PZFolder anims = new PZFolder(), animsX = new PZFolder(), animSets = new PZFolder(), actiongroups = new PZFolder();
    public void init() throws java.io.IOException {
        base.set(new java.io.File("./"));
        workdir.set(new java.io.File(base.canonicalFile, "media"));
        localWorkdir = base.canonicalFile.toPath().relativize(workdir.canonicalFile.toPath()).toFile();
        anims.set(new java.io.File(workdir.canonicalFile, "anims"));
        animsX.set(new java.io.File(workdir.canonicalFile, "anims_X"));
        animSets.set(new java.io.File(workdir.canonicalFile, "AnimSets"));
        actiongroups.set(new java.io.File(workdir.canonicalFile, "actiongroups"));
        searchFolders(workdir.canonicalFile);
        for (int i = 0; i < loadList.size(); i++) {
            String rel = getRelativeFile(loadList.get(i));
            java.io.File af = new java.io.File(loadList.get(i)).getAbsoluteFile();
            String abs = af.getAbsolutePath();
            if (af.isDirectory()) abs = abs + java.io.File.separator;
            activeFileMap.put(rel.toLowerCase(java.util.Locale.ENGLISH), abs);
            allAbsolutePaths.add(abs);
        }
        loadList.clear();
    }
    public String getRelativeFile(String path) { return getRelativeFile(base.lowercaseUri, path); }
    public java.util.Set<String> all() { return allAbsolutePaths; }
    public java.io.File localWorkdir() { return localWorkdir; }
    public java.util.List<String> list() { return loadList; }
    public static int frames;
    // From the jar's bytecode.
    public String getRelativeFile(java.net.URI base, String path) {
        String abs = new java.io.File(path).getAbsolutePath();
        java.net.URI u = new java.io.File(abs.toLowerCase(java.util.Locale.ENGLISH)).toURI();
        java.net.URI r = base.relativize(u);
        if (r.equals(u)) return path;
        String s = r.getPath();
        if (path.endsWith("/") && !s.endsWith("/")) s = s + "/";
        return s;
    }
    public void searchFolders(java.io.File f) {
        if (!zombie.network.GameServer.server) { Thread.yield(); zombie.core.Core.getInstance().DoFrameReady(); }
        if (f.isDirectory()) {
            String p = f.getAbsolutePath().replace("\\", "/").replace("./", "");
            if (p.contains("media/maps/")) loadList.add(p);
            String[] names = f.list();
            for (int i = 0; i < names.length; i++) searchFolders(new java.io.File(f.getAbsolutePath() + java.io.File.separator + names[i]));
        } else {
            loadList.add(f.getAbsolutePath().replace("\\", "/").replace("./", ""));
        }
    }

    // From the jar's bytecode (private there; public here so the test can call it).
    public interface IWalkFilesVisitor { void visit(java.io.File file, String relPath); }
    public void walkGameAndModFilesInternal(java.io.File base, String rel, boolean recursive, IWalkFilesVisitor v) {
        java.io.File dir = new java.io.File(base, rel);
        if (!dir.isDirectory()) return;
        java.io.File[] files = dir.listFiles();
        if (files == null) return;
        for (java.io.File f : files) {
            v.visit(f, rel);
            if (recursive && f.isDirectory()) walkGameAndModFilesInternal(base, rel + "/" + f.getName(), true, v);
        }
    }
}
