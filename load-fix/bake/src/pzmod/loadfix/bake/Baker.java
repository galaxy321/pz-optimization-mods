package pzmod.loadfix.bake;

import static net.bytebuddy.matcher.ElementMatchers.isConstructor;
import static net.bytebuddy.matcher.ElementMatchers.named;
import static net.bytebuddy.matcher.ElementMatchers.takesArguments;
import static net.bytebuddy.matcher.ElementMatchers.takesNoArguments;

import java.io.File;
import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import net.bytebuddy.ByteBuddy;
import net.bytebuddy.asm.Advice;
import net.bytebuddy.asm.AsmVisitorWrapper;
import net.bytebuddy.description.method.MethodDescription;
import net.bytebuddy.description.type.TypeDescription;
import net.bytebuddy.dynamic.ClassFileLocator;
import net.bytebuddy.dynamic.scaffold.TypeValidation;
import net.bytebuddy.matcher.ElementMatcher;
import net.bytebuddy.pool.TypePool;

/**
 * Writes copies of the game classes Load Fix patches, with the patches built in (the way
 * pzopt ships its changes), so the game needs no ZombieBuddy for Load Fix.
 *   java -Dnet.bytebuddy.experimental=true -cp byte-buddy:mod-classes:bake-classes pzmod.loadfix.bake.Baker
 *        <projectzomboid.jar> <out dir>
 * Each patch must match exactly one method, or nothing is written. out dir gets the
 * changed classes, and pzmod/loadfix/baked.properties with each original class's SHA-256
 * (checked at start by Patches.bakedStart).
 */
public final class Baker {
    record Target(String className, Class<?> advice, ElementMatcher<? super MethodDescription> method) {}

    static List<Target> targets(TypePool pool) {
        TypeDescription visitor = pool.describe("zombie.ZomboidFileSystem$IWalkFilesVisitor").resolve();
        List<Target> t = new ArrayList<>();
        t.add(new Target("zombie.Lua.LuaManager", Advices.LuaSearchFolders.class, named("searchFolders").and(takesArguments(URI.class, File.class))));
        t.add(new Target("zombie.Lua.LuaManager", Advices.LoadDirBase.class, named("LoadDirBase").and(takesNoArguments())));
        t.add(new Target("zombie.ZomboidFileSystem", Advices.ZfsSearchFolders.class, named("searchFolders").and(takesArguments(File.class))));
        t.add(new Target("zombie.ZomboidFileSystem", Advices.WalkGameAndModFiles.class, named("walkGameAndModFilesInternal")
                .and(takesArguments(new TypeDescription.ForLoadedType(File.class), new TypeDescription.ForLoadedType(String.class),
                        TypeDescription.ForLoadedType.of(boolean.class), visitor))));
        t.add(new Target("zombie.ZomboidFileSystem", Advices.GetRelativeFile.class, named("getRelativeFile").and(takesArguments(URI.class, String.class))));
        t.add(new Target("zombie.ZomboidFileSystem", Advices.Init.class, named("init").and(takesNoArguments())));
        t.add(new Target("zombie.ZomboidFileSystem$PZFolder", Advices.PZFolderSet.class, named("set").and(takesArguments(File.class))));
        t.add(new Target("zombie.gameStates.ChooseGameInfo", Advices.ChooseGameInfoReset.class, named("Reset").and(takesNoArguments())));
        return t;
    }

    public static void main(String[] a) throws Exception {
        Path gameJar = Path.of(a[0]), out = Path.of(a[1]);
        ClassFileLocator game = ClassFileLocator.ForJarFile.of(gameJar.toFile());
        ClassFileLocator locator = new ClassFileLocator.Compound(game, ClassFileLocator.ForClassLoader.ofSystemLoader());
        TypePool pool = TypePool.Default.of(locator);

        Map<String, List<Target>> byClass = new LinkedHashMap<>();
        for (Target t : targets(pool)) byClass.computeIfAbsent(t.className(), k -> new ArrayList<>()).add(t);

        Map<String, byte[]> written = new LinkedHashMap<>();
        StringBuilder info = new StringBuilder("# made by pzmod.loadfix.bake.Baker from " + gameJar.getFileName() + "\njar=" + gameJar.getFileName() + "\n");
        int bad = 0;
        for (Map.Entry<String, List<Target>> e : byClass.entrySet()) {
            String cls = e.getKey();
            TypeDescription type = pool.describe(cls).resolve();
            var builder = new ByteBuddy().with(TypeValidation.DISABLED).redefine(type, locator);
            List<AtomicInteger> hits = new ArrayList<>();
            for (Target t : e.getValue()) {
                AtomicInteger n = new AtomicInteger();
                hits.add(n);
                ElementMatcher<? super MethodDescription> m = t.method();
                ElementMatcher<MethodDescription> counting = md -> {
                    boolean ok = !isConstructor().matches(md) && m.matches(md);
                    if (ok) n.incrementAndGet();
                    return ok;
                };
                AsmVisitorWrapper w = Advice.to(pool.describe(t.advice().getName()).resolve(), locator).on(counting);
                builder = builder.visit(w);
            }
            byte[] bytes = builder.make().getBytes();
            for (int i = 0; i < hits.size(); i++) {
                Target t = e.getValue().get(i);
                int n = hits.get(i).get();
                // The matcher can be asked more than once per method; at least one, and one method only, is what matters.
                long methods = type.getDeclaredMethods().filter(md -> !md.isConstructor() && t.method().matches(md)).size();
                boolean ok = n > 0 && methods == 1;
                System.out.println((ok ? "ok   " : "FAIL ") + t.advice().getSimpleName() + " -> " + cls + ": " + methods + " method(s)");
                if (!ok) bad++;
            }
            written.put(cls, bytes);
            byte[] orig = game.locate(cls).resolve();
            info.append("class.").append(cls).append('=').append(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(orig))).append('\n');
        }
        if (bad > 0) {
            System.out.println(bad + " FAILED, nothing written");
            System.exit(1);
        }
        for (Map.Entry<String, byte[]> e : written.entrySet()) {
            Path p = out.resolve(e.getKey().replace('.', '/') + ".class");
            Files.createDirectories(p.getParent());
            Files.write(p, e.getValue());
        }
        Path ip = out.resolve("pzmod/loadfix/baked.properties");
        Files.createDirectories(ip.getParent());
        Files.writeString(ip, info.toString());
        System.out.println("BAKE OK (" + written.size() + " classes)");
    }
}
