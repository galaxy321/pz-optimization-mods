import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.jar.JarFile;
import java.util.stream.Stream;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.analysis.Analyzer;
import org.objectweb.asm.tree.analysis.SimpleVerifier;

// Runs ASM's bytecode verifier over every method of the baked classes, with the class
// hierarchy read from the class files (the game jar is Java 25 and this JDK can't load it).
//   java -cp asm.jar:asm-tree.jar:asm-analysis.jar:. VerifyBaked <projectzomboid.jar> <mod classes dir> <baked dir>
public class VerifyBaked {
    static JarFile game;
    static Path mod, baked;
    static final Map<String, ClassNode> cache = new HashMap<>();

    static ClassNode node(String internal) {
        return cache.computeIfAbsent(internal, n -> {
            try {
                byte[] b = null;
                Path p = baked.resolve(n + ".class");
                if (Files.exists(p)) b = Files.readAllBytes(p);
                if (b == null && Files.exists(mod.resolve(n + ".class"))) b = Files.readAllBytes(mod.resolve(n + ".class"));
                if (b == null && game.getEntry(n + ".class") != null) try (InputStream in = game.getInputStream(game.getEntry(n + ".class"))) { b = in.readAllBytes(); }
                if (b == null) try (InputStream in = ClassLoader.getSystemResourceAsStream(n + ".class")) { if (in != null) b = in.readAllBytes(); }
                if (b == null) throw new IllegalStateException("class not found: " + n);
                ClassNode c = new ClassNode();
                new ClassReader(b).accept(c, ClassReader.SKIP_CODE);
                return c;
            } catch (java.io.IOException e) {
                throw new RuntimeException(e);
            }
        });
    }

    static class Verifier extends SimpleVerifier {
        Verifier() { super(Opcodes.ASM9, null, null, null, false); }
        @Override protected boolean isInterface(Type t) {
            return t.getSort() == Type.OBJECT && (node(t.getInternalName()).access & Opcodes.ACC_INTERFACE) != 0;
        }
        @Override protected Type getSuperClass(Type t) {
            if (t.getSort() == Type.ARRAY) return Type.getObjectType("java/lang/Object");
            String s = node(t.getInternalName()).superName;
            return s == null ? null : Type.getObjectType(s);
        }
        @Override protected boolean isAssignableFrom(Type t, Type u) {
            if (t.equals(u)) return true;
            if (t.getSort() == Type.OBJECT && t.getInternalName().equals("java/lang/Object")) return true;
            if (u.getSort() == Type.ARRAY) {
                if (t.getSort() == Type.ARRAY) {
                    Type te = Type.getType(t.getDescriptor().substring(1)), ue = Type.getType(u.getDescriptor().substring(1));
                    if (te.getSort() < Type.ARRAY || ue.getSort() < Type.ARRAY) return te.equals(ue);
                    return isAssignableFrom(te, ue);
                }
                String n = t.getInternalName();
                return n.equals("java/lang/Cloneable") || n.equals("java/io/Serializable");
            }
            if (t.getSort() != Type.OBJECT || u.getSort() != Type.OBJECT) return false;
            if (isInterface(t)) return true;   // the JVM verifier treats interfaces like Object
            for (Type c = u; c != null; c = getSuperClass(c)) if (c.equals(t)) return true;
            return false;
        }
        @Override protected Class<?> getClass(Type t) {
            throw new UnsupportedOperationException("not loading " + t);
        }
    }

    public static void main(String[] a) throws Exception {
        game = new JarFile(a[0]);
        mod = Path.of(a[1]);
        baked = Path.of(a[2]);
        int methods = 0, bad = 0;
        List<Path> files;
        try (Stream<Path> s = Files.walk(baked)) { files = s.filter(p -> p.toString().endsWith(".class")).toList(); }
        for (Path f : files) {
            ClassNode c = new ClassNode();
            new ClassReader(Files.readAllBytes(f)).accept(c, 0);
            for (MethodNode m : c.methods) {
                if ((m.access & (Opcodes.ACC_ABSTRACT | Opcodes.ACC_NATIVE)) != 0) continue;
                methods++;
                try {
                    new Analyzer<>(new Verifier()).analyze(c.name, m);
                } catch (Exception e) {
                    bad++;
                    System.out.println("FAIL " + c.name + "." + m.name + m.desc + ": " + e.getMessage());
                }
            }
            System.out.println("checked " + c.name + " (class version " + (c.version & 0xFFFF) + ")");
        }
        System.out.println(bad == 0 ? "VERIFY OK (" + methods + " methods)" : bad + " of " + methods + " methods FAILED");
        if (bad > 0) System.exit(1);
    }
}
