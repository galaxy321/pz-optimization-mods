// A -javaagent that only hands over the Instrumentation, for ZBIntegrationTest
// (where attaching to itself isn't allowed).
public class TestAgent {
    public static volatile java.lang.instrument.Instrumentation inst;
    public static void premain(String args, java.lang.instrument.Instrumentation i) { inst = i; }
}
