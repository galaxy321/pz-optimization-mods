package pzmod.tgcapture;

import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.File;
import java.util.ArrayList;
import javax.imageio.ImageIO;

// The picture side, without OpenGL (java/test/Smoke.java runs it outside the game).
public final class Images {
    private Images() {}

    /** RGBA rows as glReadPixels gives them (bottom row first). */
    public static final class Pixels {
        public final int w, h;
        public final byte[] rgba;
        public Pixels(int w, int h, byte[] rgba) { this.w = w; this.h = h; this.rgba = rgba; }
    }

    /** What Lua drew over the game this frame: rects and text in screen pixels. */
    public static final class Overlay {
        final ArrayList<float[]> rects = new ArrayList<>();
        final ArrayList<Object[]> texts = new ArrayList<>();
        public int size() { return rects.size() + texts.size(); }
    }

    /** The picture right way up and opaque (the alpha the game leaves is ignored), scaled to
     *  outW x outH when given, with the overlay drawn on top. */
    public static BufferedImage compose(Pixels p, int outW, int outH, Overlay ov) {
        BufferedImage img = new BufferedImage(p.w, p.h, BufferedImage.TYPE_INT_RGB);
        int[] row = new int[p.w];
        for (int y = 0; y < p.h; y++) {
            int src = (p.h - 1 - y) * p.w * 4;
            for (int x = 0; x < p.w; x++, src += 4) {
                row[x] = ((p.rgba[src] & 255) << 16) | ((p.rgba[src + 1] & 255) << 8) | (p.rgba[src + 2] & 255);
            }
            img.setRGB(0, y, p.w, 1, row, 0, p.w);
        }
        if (outW > 0 && outH > 0 && (outW != p.w || outH != p.h)) {
            BufferedImage s = new BufferedImage(outW, outH, BufferedImage.TYPE_INT_RGB);
            Graphics2D g = s.createGraphics();
            g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR);
            g.drawImage(img, 0, 0, outW, outH, null);
            g.dispose();
            img = s;
        }
        if (ov != null && ov.size() > 0) {
            Graphics2D g = img.createGraphics();
            for (float[] r : ov.rects) {
                g.setColor(new Color(clamp(r[4]), clamp(r[5]), clamp(r[6]), clamp(r[7])));
                g.fillRect(Math.round(r[0]), Math.round(r[1]), Math.max(1, Math.round(r[2])), Math.max(1, Math.round(r[3])));
            }
            g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
            Font f = new Font(Font.SANS_SERIF, Font.PLAIN, 16);
            g.setFont(f);
            int asc = g.getFontMetrics().getAscent();
            for (Object[] t : ov.texts) {
                float[] c = (float[]) t[1];
                g.setColor(new Color(clamp(c[2]), clamp(c[3]), clamp(c[4])));
                g.drawString((String) t[0], c[0], c[1] + asc);
            }
            g.dispose();
        }
        return img;
    }

    private static float clamp(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

    /** Share of pixels that aren't black, from a sample grid (a blank capture is 0). */
    public static double litShare(BufferedImage img) {
        int n = 0, lit = 0;
        for (int y = 0; y < img.getHeight(); y += 7) {
            for (int x = 0; x < img.getWidth(); x += 7) {
                n++;
                if ((img.getRGB(x, y) & 0xFFFFFF) != 0) lit++;
            }
        }
        return n == 0 ? 0 : (double) lit / n;
    }

    /** A cheap fingerprint of the picture (to tell an unchanged world from a fresh one). */
    public static int fingerprint(Pixels p) {
        int hsh = 17;
        int step = Math.max(4, (p.rgba.length / 4 / 4096) * 4);
        for (int i = 0; i < p.rgba.length; i += step) hsh = hsh * 31 + p.rgba[i];
        return hsh;
    }

    public static void writePng(BufferedImage img, File f) throws java.io.IOException {
        File dir = f.getParentFile();
        if (dir != null) dir.mkdirs();
        if (!ImageIO.write(img, "png", f)) throw new java.io.IOException("no PNG writer");
    }

    // 1.0.2 film mode: the film frames are scaled and turned into JPEG on the film's worker thread.

    /** A film frame's size for a source of srcW x srcH scaled to width (never wider than the
     *  source): both even, as the video encoder wants, the height kept to the aspect ratio. */
    public static int[] filmSize(int srcW, int srcH, int width) {
        int w = Math.max(2, Math.min(width, srcW) & ~1);
        int h = Math.max(2, (int) Math.round((double) w * srcH / srcW / 2) * 2);
        return new int[] { w, h };
    }

    /** GL rows (bottom first, RGBA) into out (top first, RGB ints) of outW x outH, each pixel the
     *  average of the source pixels it covers (a box filter: 2560 to 1280 averages 2x2). */
    public static void scaleFlip(byte[] rgba, int w, int h, int[] out, int outW, int outH) {
        if (w == outW * 2 && h == outH * 2) { half(rgba, w, h, out, outW, outH); return; }
        int[] x0 = new int[outW], x1 = new int[outW];
        for (int x = 0; x < outW; x++) {
            x0[x] = (int) ((long) x * w / outW);
            x1[x] = Math.max(x0[x] + 1, (int) ((long) (x + 1) * w / outW));
        }
        int[] r = new int[outW], g = new int[outW], b = new int[outW];
        for (int y = 0; y < outH; y++) {
            int y0 = (int) ((long) y * h / outH), y1 = Math.max(y0 + 1, (int) ((long) (y + 1) * h / outH));
            java.util.Arrays.fill(r, 0); java.util.Arrays.fill(g, 0); java.util.Arrays.fill(b, 0);
            for (int sy = y0; sy < y1; sy++) {
                int row = (h - 1 - sy) * w * 4;
                for (int x = 0; x < outW; x++) {
                    int rr = 0, gg = 0, bb = 0;
                    for (int sx = x0[x], i = row + sx * 4; sx < x1[x]; sx++, i += 4) {
                        rr += rgba[i] & 255; gg += rgba[i + 1] & 255; bb += rgba[i + 2] & 255;
                    }
                    r[x] += rr; g[x] += gg; b[x] += bb;
                }
            }
            int o = y * outW, dy = y1 - y0;
            for (int x = 0; x < outW; x++) {
                int n = dy * (x1[x] - x0[x]), half = n / 2;
                out[o + x] = ((r[x] + half) / n << 16) | ((g[x] + half) / n << 8) | ((b[x] + half) / n);
            }
        }
    }

    // The usual case (2560x1440 to 1280x720): each output pixel is a 2x2 block.
    private static void half(byte[] p, int w, int h, int[] out, int outW, int outH) {
        int stride = w * 4;
        for (int y = 0; y < outH; y++) {
            int i = (h - 1 - 2 * y) * stride, j = i - stride, o = y * outW;
            for (int x = 0; x < outW; x++, i += 8, j += 8) {
                int r = (p[i] & 255) + (p[i + 4] & 255) + (p[j] & 255) + (p[j + 4] & 255);
                int g = (p[i + 1] & 255) + (p[i + 5] & 255) + (p[j + 1] & 255) + (p[j + 5] & 255);
                int b = (p[i + 2] & 255) + (p[i + 6] & 255) + (p[j + 2] & 255) + (p[j + 6] & 255);
                out[o + x] = ((r + 2) >> 2 << 16) | ((g + 2) >> 2 << 8) | ((b + 2) >> 2);
            }
        }
    }

    /** JPEG at a set quality through one ImageWriter that is kept (one per film worker). */
    public static final class Jpeg {
        final javax.imageio.ImageWriter w = ImageIO.getImageWritersByFormatName("jpeg").next();
        final javax.imageio.plugins.jpeg.JPEGImageWriteParam p = new javax.imageio.plugins.jpeg.JPEGImageWriteParam(null);
        public Jpeg(float quality) {
            p.setCompressionMode(javax.imageio.ImageWriteParam.MODE_EXPLICIT);
            p.setCompressionQuality(quality);
        }
        public void write(BufferedImage img, File f) throws java.io.IOException {
            try (java.io.OutputStream fo = new java.io.BufferedOutputStream(new java.io.FileOutputStream(f), 1 << 16);
                 javax.imageio.stream.ImageOutputStream o = new javax.imageio.stream.MemoryCacheImageOutputStream(fo)) {
                w.setOutput(o);
                w.write(null, new javax.imageio.IIOImage(img, null, null), p);
            } finally {
                w.setOutput(null);
            }
        }
        public void dispose() { w.dispose(); }
    }
}
