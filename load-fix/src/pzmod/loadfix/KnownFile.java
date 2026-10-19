package pzmod.loadfix;

import java.io.File;

/**
 * A File whose isDirectory() and isFile() answers come from the folder listing
 * that found it, instead of one file-system call each. Same path string as the
 * File the game's listFiles() would have made, so every other method behaves
 * the same. Only used for plain files and folders, never for links or junctions.
 */
public final class KnownFile extends File {
    private final boolean dir, file;

    public KnownFile(File parent, String name, boolean dir, boolean file) {
        super(parent, name);
        this.dir = dir;
        this.file = file;
    }

    public KnownFile(String path, boolean dir, boolean file) {
        super(path);
        this.dir = dir;
        this.file = file;
    }

    /** Keeps the known answers, so toURI(), which asks getAbsoluteFile().isDirectory()
     *  to decide on a trailing slash, doesn't ask the file system. */
    @Override public File getAbsoluteFile() {
        String abs = getAbsolutePath();
        return abs.equals(getPath()) ? this : new KnownFile(abs, dir, file);
    }

    @Override public boolean isDirectory() { return dir; }
    @Override public boolean isFile() { return file; }
}
