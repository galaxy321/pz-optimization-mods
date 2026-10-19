import java.io.File;
import java.util.List;
import zombie.ZomboidFileSystem;
import zombie.gameStates.ChooseGameInfo;

// The built-in (pzopt-style) version on the stand-in game classes: run once with the
// plain stand-ins and once with the baked ones (Baker run on the stand-ins), each
// printing everything the game's methods left behind, then compare the two outputs.
// In the baked run, the reload must set no folder (all kept from the first read), and
// run.sh checks the [LoadFix] report line shows every part ran.
//   java -cp <stubs or baked+stubs>:<mod>:<ZB jar>:<test classes> BakedTest <tree> <baked|plain>
public class BakedTest {
    public static void main(String[] a) throws Exception {
        File root = new File(a[0]);
        boolean baked = a[1].equals("baked");
        ZBIntegrationTest.Run r = ZBIntegrationTest.run(root);
        List<String> two = ZBIntegrationTest.twoListings(root);
        File modDir = new File(root, "lower");
        String boot = ZBIntegrationTest.folders(ChooseGameInfo.readModInfo(modDir.getPath()));
        int sets = ZomboidFileSystem.PZFolder.sets;
        ChooseGameInfo.Reset();
        String reload = ZBIntegrationTest.folders(ChooseGameInfo.readModInfo(modDir.getPath()));
        zombie.Lua.LuaManager.LoadDirBase();
        System.out.println("RESULT lua=" + r.lua());
        System.out.println("RESULT files=" + r.files());
        System.out.println("RESULT rel=" + r.rel());
        System.out.println("RESULT visits=" + r.visits());
        System.out.println("RESULT init=" + r.init().replace('\n', '|'));
        System.out.println("RESULT two=" + two);
        System.out.println("RESULT boot=" + boot.replace('\n', '|'));
        System.out.println("RESULT reload=" + reload.replace('\n', '|'));
        if (baked) {
            System.out.println("baked: reload set " + (ZomboidFileSystem.PZFolder.sets - sets) + " folders (want 0)");
            System.out.println(ZomboidFileSystem.PZFolder.sets == sets ? "BAKED RUN OK" : "BAKED RUN FAILED");
        }
    }
}
