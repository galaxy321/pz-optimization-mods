import java.awt.image.BufferedImage;
import java.io.File;
import pzmod.tgcapture.Images;
// The picture side outside the game: rows flipped, scaled to the screen size, overlay drawn, a
// blank frame seen as blank, and a PNG written. Run: java -cp tgcapture.jar:. Smoke <out dir>
public class Smoke {
    public static void main(String[] a) throws Exception {
        int w = 200, h = 100;
        byte[] px = new byte[w * h * 4];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int i = (y * w + x) * 4;
            px[i] = (byte) (y < 50 ? 200 : 0); px[i + 1] = (byte) 100; px[i + 2] = 0; px[i + 3] = 0;   // bottom half red-ish (GL rows)
        }
        Images.Overlay ov = new Images.Overlay();
        java.lang.reflect.Field fr = Images.Overlay.class.getDeclaredField("rects"); fr.setAccessible(true);
        java.lang.reflect.Field ft = Images.Overlay.class.getDeclaredField("texts"); ft.setAccessible(true);
        ((java.util.List<float[]>) fr.get(ov)).add(new float[] { 10, 10, 12, 12, 1, 0.2f, 1, 1 });
        ((java.util.List<Object[]>) ft.get(ov)).add(new Object[] { "DRIVE VIEW test", new float[] { 20, 60, 1, 1, 1 } });
        BufferedImage img = Images.compose(new Images.Pixels(w, h, px), 400, 200, ov);
        int bottom = img.getRGB(300, 190), top = img.getRGB(300, 40), dot = img.getRGB(15, 15);
        BufferedImage blank = Images.compose(new Images.Pixels(w, h, new byte[w * h * 4]), 0, 0, null);
        File f = new File(a.length > 0 ? a[0] : ".", "smoke.png");
        Images.writePng(img, f);
        boolean ok = img.getWidth() == 400 && ((bottom >> 16) & 255) == 200 && ((top >> 16) & 255) == 0 && dot == 0xFFFF33FF
            && Images.litShare(blank) == 0 && Images.litShare(img) > 0.9 && f.length() > 100;
        System.out.printf("bottom %06x top %06x dot %08x lit %.2f blank %.2f png %d bytes%n", bottom & 0xFFFFFF, top & 0xFFFFFF, dot, Images.litShare(img), Images.litShare(blank), f.length());
        System.out.println(ok ? "SMOKE OK" : "SMOKE FAILED");
        System.exit(ok ? 0 : 1);
    }
}
