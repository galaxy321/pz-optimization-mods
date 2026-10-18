package zombie.gameStates;

import java.io.File;
import zombie.ZomboidFileSystem.PZModFolder;

// Stand-in: the game keeps every mod it has read in Mods until Reset(), which
// Core.ResetLua calls before the mods are read again.
public class ChooseGameInfo {
    private static final java.util.HashMap<String, Mod> Mods = new java.util.HashMap<>();
    public static void Reset() { Mods.clear(); }
    public static Mod readModInfo(String dir) {
        Mod m = new Mod(dir);
        Mods.put(dir, m);
        return m;
    }
    public static final class Mod {
        public final PZModFolder baseFile = new PZModFolder(), mediaFile = new PZModFolder(), actionGroupsFile = new PZModFolder(),
                animSetsFile = new PZModFolder(), animsXFile = new PZModFolder();
        public Mod(String dir) {
            baseFile.setWithCatch(new File(dir, "common"), new File(dir, "42"));
            mediaFile.setWithCatch(new File(dir, "common/media"), new File(dir, "42/media"));
            actionGroupsFile.setWithCatch(new File(dir, "common/media/actiongroups"), new File(dir, "42/media/actiongroups"));
            animSetsFile.setWithCatch(new File(dir, "common/media/AnimSets"), new File(dir, "42/media/AnimSets"));
            animsXFile.setWithCatch(new File(dir, "common/media/anims_X"), new File(dir, "42/media/anims_X"));
        }
    }
}
