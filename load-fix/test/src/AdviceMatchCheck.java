import java.lang.annotation.Annotation;
import java.lang.reflect.Method;
import java.util.*;
import me.zed_0xff.zombie_buddy.Patch;
import net.bytebuddy.description.method.MethodDescription;
import net.bytebuddy.description.type.TypeDescription;
import net.bytebuddy.dynamic.ClassFileLocator;
import net.bytebuddy.pool.TypePool;

/** Checks that each patch class in Patches would be applied by ZombieBuddy 2.3.4 to
 *  exactly one method of the game class it names. Follows PatchEngine's matcher:
 *  an unannotated parameter stands for the game argument at the same position, an
 *  @Patch.Argument(n) parameter for argument n, and This/Local/Return/Thrown/AllArguments
 *  are skipped. 0.2.0's file-listing patch failed this.
 *  The game's classes are read from its jar without loading them (they need Java 25).
 *    java -Dnet.bytebuddy.experimental=true -cp <ZombieBuddy jar>:<mod classes>:. AdviceMatchCheck <game jar> */
public class AdviceMatchCheck {
    static final Set<Class<?>> SPECIAL = Set.of(Patch.This.class, Patch.Local.class,
            Patch.Return.class, Patch.Thrown.class, Patch.AllArguments.class);

    public static void main(String[] a) throws Exception {
        boolean ok = true;
        TypePool pool = TypePool.Default.of(new ClassFileLocator.Compound(
                ClassFileLocator.ForJarFile.of(new java.io.File(a[0])), ClassFileLocator.ForClassLoader.ofSystemLoader()));
        for (Class<?> c : Class.forName("pzmod.loadfix.Patches").getDeclaredClasses()) {
            Patch p = c.getAnnotation(Patch.class);
            if (p == null) continue;
            TypeDescription target = pool.describe(p.className()).resolve();
            // As PatchEngine.applyPatches: the argument maps of all advice methods of the
            // patch class together, and whether any of them has no ordinary parameters.
            List<Map<Integer, Class<?>>> maps = new ArrayList<>();
            List<Boolean> exact = new ArrayList<>();
            boolean noParam = false, allArgs = false;
            int minParams = 0;
            for (Method adv : c.getDeclaredMethods()) {
                if (adv.getAnnotation(Patch.OnEnter.class) == null && adv.getAnnotation(Patch.OnExit.class) == null) continue;
                Map<Integer, Class<?>> args = new HashMap<>();
                boolean annotatedArg = false, allSpecial = adv.getParameterCount() > 0;
                Annotation[][] anns = adv.getParameterAnnotations();
                for (int i = 0; i < anns.length; i++) {
                    boolean skip = false, isArg = false;
                    for (Annotation an : anns[i]) {
                        if (an instanceof Patch.Argument arg) { args.put(arg.value(), adv.getParameterTypes()[i]); isArg = annotatedArg = true; allSpecial = false; break; }
                        if (an instanceof Patch.AllArguments) allArgs = true;
                        if (SPECIAL.contains(an.annotationType())) { skip = true; break; }
                    }
                    if (!skip && !isArg) { args.put(i, adv.getParameterTypes()[i]); allSpecial = false; }
                }
                if (adv.getParameterCount() == 0 || allSpecial) noParam = true;
                if (!args.isEmpty()) { maps.add(args); exact.add(!annotatedArg); }
                if (annotatedArg) minParams = Math.max(minParams, args.keySet().stream().mapToInt(Integer::intValue).max().getAsInt() + 1);
            }
            List<String> hits = new ArrayList<>();
            for (MethodDescription.InDefinedShape m : target.getDeclaredMethods()) {
                if (!m.getName().equals(p.methodName())) continue;
                List<String> params = new ArrayList<>();
                m.getParameters().forEach(x -> params.add(x.getType().asErasure().getName()));
                if (allArgs || (noParam && !p.strictMatch() && maps.isEmpty()) || matches(params, maps, exact, minParams, noParam, p.strictMatch()))
                    hits.add(p.methodName() + params);
            }
            boolean good = hits.size() == 1;
            System.out.println((good ? "ok   " : "FAIL ") + c.getSimpleName() + " -> " + p.className() + ": " + hits.size() + " method(s) matched " + hits);
            if (!good) ok = false;
        }
        System.out.println(ok ? "ADVICE MATCH OK" : "ADVICE MATCH FAILED");
        if (!ok) System.exit(1);
    }

    /** PatchEngine's signature-aware matcher. Argument types are compared by name,
     *  which is enough for the types used here. */
    static boolean matches(List<String> params, List<Map<Integer, Class<?>>> maps, List<Boolean> exact, int minParams, boolean noParam, boolean strict) {
        int n = params.size();
        if (noParam && n == 0) return true;
        if (strict && noParam && maps.isEmpty() && n > 0) return false;
        for (int i = 0; i < maps.size(); i++) {
            Map<Integer, Class<?>> args = maps.get(i);
            boolean ex = exact.get(i);
            if (ex && n != args.size()) continue;
            if (!ex && (n < args.size() || n < minParams)) continue;
            boolean all = true;
            for (var e : args.entrySet()) {
                if (e.getKey() >= n || (e.getValue() != Object.class && !e.getValue().getName().equals(params.get(e.getKey())))) { all = false; break; }
            }
            if (all) return true;
        }
        return noParam && !strict;
    }
}
