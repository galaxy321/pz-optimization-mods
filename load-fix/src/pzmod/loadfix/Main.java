package pzmod.loadfix;

public class Main {
    public static final String VERSION = "0.6.0";

    public static void main(String[] args) {
        System.out.println("[LoadFix] active (" + VERSION + "): Lua listing "
                + (Patches.ENABLE_LUA_WALK ? (Patches.ENABLE_LUA_NIO ? "on (nio)" : "on") : "off") + ", file listing "
                + (Patches.ENABLE_FILE_WALK ? "on" : "off") + ", game+mod file walk "
                + (Patches.ENABLE_GAME_WALK ? "on" : "off") + ", relative paths "
                + (Patches.ENABLE_REL_PATH ? "on" : "off") + ", init " + (Patches.ENABLE_INIT ? "on" : "off")
                + ", folder cache " + (Patches.ENABLE_FOLDER_CACHE ? "on" : "off"));
    }
}
