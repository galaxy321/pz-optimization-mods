package zombie.core;
public class Core {
    static final Core I = new Core();
    public static Core getInstance() { return I; }
    public void DoFrameReady() { zombie.ZomboidFileSystem.frames++; }
}
