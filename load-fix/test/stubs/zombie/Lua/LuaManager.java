package zombie.Lua;
// Test stand-in: only the members Load Fix touches, with the game's walk (from the jar's bytecode).
public class LuaManager {
    public static java.util.List<String> loadList = new java.util.ArrayList<>();
    public static void LoadDirBase() throws Exception {}
    public static void searchFolders(java.net.URI base, java.io.File f) throws java.io.IOException {
        if (f.isDirectory()) {
            String[] names = f.list();
            for (int i = 0; i < names.length; i++)
                searchFolders(base, new java.io.File(f.getCanonicalFile().getAbsolutePath() + java.io.File.separator + names[i]));
        } else if (f.getAbsolutePath().toLowerCase().endsWith(".lua")) {
            loadList.add(zombie.ZomboidFileSystem.instance.getRelativeFile(base, f.getAbsolutePath()).toLowerCase(java.util.Locale.ENGLISH));
        }
    }
}
