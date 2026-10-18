package pzmod.loadfix.bake;

import java.io.File;
import java.net.URI;
import net.bytebuddy.asm.Advice;
import pzmod.loadfix.Patches;
import zombie.ZomboidFileSystem;

/**
 * The same patches as Patches.Patch_*, written as ByteBuddy advice so Baker can copy them
 * into the game's own classes at build time (the pzopt way: no ZombieBuddy at run time).
 * The bodies match the ZombieBuddy ones line for line; see Patches for why each catches
 * what it does. Only the bodies are copied into the game's classes, so this class is
 * not shipped. Every advice first calls Patches.bakedStart(), which checks the game jar once
 * (whichever patched method runs first) and turns everything off if it has changed.
 */
public final class Advices {
    private Advices() {}

    /** LuaManager.searchFolders(URI, File) */
    public static final class LuaSearchFolders {
        @Advice.OnMethodEnter(skipOn = Advice.OnNonDefaultValue.class)
        public static boolean enter(@Advice.Argument(0) URI base, @Advice.Argument(1) File dir) {
            try {
                Patches.bakedStart();
                return Patches.luaWalk(base, dir);
            } catch (Throwable e) {
                return false;
            }
        }
    }

    /** ZomboidFileSystem.searchFolders(File) */
    public static final class ZfsSearchFolders {
        @Advice.OnMethodEnter(skipOn = Advice.OnNonDefaultValue.class)
        public static boolean enter(@Advice.This Object self, @Advice.Argument(0) File dir) {
            try {
                Patches.bakedStart();
                return Patches.fileWalk(self, dir);
            } catch (Throwable e) {
                return false;
            }
        }
    }

    /** ZomboidFileSystem.walkGameAndModFilesInternal(File, String, boolean, IWalkFilesVisitor); no catch, as in Patches. */
    public static final class WalkGameAndModFiles {
        @Advice.OnMethodEnter(skipOn = Advice.OnNonDefaultValue.class)
        public static boolean enter(@Advice.Argument(0) File base, @Advice.Argument(1) String rel, @Advice.Argument(2) boolean recursive,
                @Advice.Argument(3) ZomboidFileSystem.IWalkFilesVisitor visitor) {
            Patches.bakedStart();
            return Patches.gameWalk(base, rel, recursive, visitor);
        }
    }

    /** ZomboidFileSystem.getRelativeFile(URI, String) */
    public static final class GetRelativeFile {
        @Advice.OnMethodEnter(skipOn = Advice.OnNonDefaultValue.class)
        public static boolean enter(@Advice.Argument(0) URI base, @Advice.Argument(1) String path, @Advice.Local("lfRel") String rel) {
            try {
                Patches.bakedStart();
                rel = Patches.relativeFile(base, path);
            } catch (Throwable e) {
                rel = null;
            }
            return rel != null;
        }

        @Advice.OnMethodExit
        public static void exit(@Advice.Return(readOnly = false) String ret, @Advice.Local("lfRel") String rel) {
            if (rel != null) ret = rel;
        }
    }

    /** ZomboidFileSystem.init(); no catch-all, as in Patches. Also the console line at start. */
    public static final class Init {
        @Advice.OnMethodEnter(skipOn = Advice.OnNonDefaultValue.class)
        public static boolean enter(@Advice.This Object self) throws Exception {
            Patches.bakedStart();
            return Patches.zfsInit(self);
        }
    }

    /** ZomboidFileSystem$PZFolder.set(File); the exit runs only on a normal return. */
    public static final class PZFolderSet {
        @Advice.OnMethodEnter(skipOn = Advice.OnNonDefaultValue.class)
        public static boolean enter(@Advice.This Object self, @Advice.Argument(0) File f) {
            try {
                Patches.bakedStart();
                return Patches.setFolderFromCache(self, f);
            } catch (Throwable e) {
                return false;
            }
        }

        @Advice.OnMethodExit
        public static void exit(@Advice.This Object self, @Advice.Argument(0) File f) {
            try {
                Patches.rememberFolder(self, f);
            } catch (Throwable ignored) {
            }
        }
    }

    /** ChooseGameInfo.Reset() */
    public static final class ChooseGameInfoReset {
        @Advice.OnMethodEnter
        public static void enter() {
            try {
                Patches.bakedStart();
                Patches.harvestModFolders();
            } catch (Throwable ignored) {
            }
        }
    }

    /** LuaManager.LoadDirBase() */
    public static final class LoadDirBase {
        @Advice.OnMethodExit
        public static void exit() {
            try {
                Patches.bakedStart();
                Patches.report();
            } catch (Throwable ignored) {
            }
        }
    }
}
