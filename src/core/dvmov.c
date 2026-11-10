/*
 * OldDV Rescue - lossless "DV in QuickTime" writer.
 *
 * Rewraps a raw DV stream into a .mov without re-encoding:
 *   - video track: the untouched DV frames ('dvc ' NTSC / 'dvcp' PAL),
 *     with pixel aspect ratio ('pasp') and field order ('fiel', bottom first)
 *   - one stereo 16-bit PCM track ('twos') per audio pair, extracted from
 *     the DV audio blocks (12-bit nonlinear audio is expanded to 16 bit)
 * This is the same packaging DVRescue's dvpackager produces with ffmpeg,
 * and plays in QuickTime 7 / X, iMovie, Final Cut and VLC.
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* DV audio extraction (IEC 61834-2 shuffling)                         */

static const int min_samples[2][3] = { { 1580, 1452, 1053 }, { 1896, 1742, 1264 } };
static const unsigned rates[3] = { 48000, 44100, 32000 };

static int16_t dv_12to16(unsigned s)
{
    unsigned shift;
    int r;
    s = s < 0x800 ? s : (s | 0xF000);
    s &= 0xFFFF;
    shift = (s & 0xF00) >> 8;
    if (shift < 2 || shift > 0xD)
        r = (int)s;
    else if (shift < 8) {
        shift--;
        r = (int)((s - 256 * shift) << shift);
    } else {
        shift = 0xE - shift;
        r = (int)(((s + 256 * shift + 1) << shift) - 1);
    }
    return (int16_t)(r & 0xFFFF);
}

int dv_audio_info(const uint8_t *f, size_t size, dv_audio_fmt *fmt)
{
    size_t bi, nb = size / DV_BLOCK_SIZE;
    memset(fmt, 0, sizeof(*fmt));
    if (nb < 150)
        return -1;
    fmt->dsf = (f[3] & 0x80) ? 1 : 0;
    for (bi = 0; bi < nb; bi++) {
        const uint8_t *b = f + bi * DV_BLOCK_SIZE;
        if ((b[0] & 0xE0) == 0x60 && b[3] == 0x50 && !(b[1] & 0x08)) {
            int smp = (b[4 + 3] >> 3) & 7, qu = b[4 + 3] & 7;
            if (smp > 2 || qu > 1)
                return -1;
            fmt->rate = rates[smp];
            fmt->quant = qu;
            fmt->samples = min_samples[fmt->dsf][smp] + (b[4] & 0x3F);
            fmt->pairs = qu == 1 ? 2 : 1;
            return 0;
        }
    }
    return -1;
}

/* Extract samples of stereo pair 'pair' (0 or 1) as interleaved native
 * int16 L/R into out (fmt->samples * 2 values). Missing data = silence. */
void dv_audio_extract(const uint8_t *f, size_t size, const dv_audio_fmt *fmt, int pair, int16_t *out)
{
    int dseqs = fmt->dsf ? 12 : 10, half = dseqs / 2, n;
    int per = fmt->dsf ? 54 : 45, third = per / 3;
    memset(out, 0, (size_t)fmt->samples * 2 * sizeof(int16_t));
    for (n = 0; n < fmt->samples; n++) {
        int ds = (n / 3 + 2 * (n % 3)) % half;
        int blk = 3 * (n % 3) + (n % per) / third;
        int c;
        if (fmt->quant == 0) {
            if (pair)
                return;
            for (c = 0; c < 2; c++) {
                size_t off = (size_t)(ds + c * half) * DV_DSEQ_SIZE + (size_t)(6 + 16 * blk) * DV_BLOCK_SIZE + 8 + 2 * (n / per);
                int v;
                if (off + 1 >= size)
                    continue;
                v = (f[off] << 8) | f[off + 1];
                if (v == 0x8000)
                    v = 0; /* error code: silence */
                out[n * 2 + c] = (int16_t)v;
            }
        } else {
            size_t off = (size_t)(ds + pair * half) * DV_DSEQ_SIZE + (size_t)(6 + 16 * blk) * DV_BLOCK_SIZE + 8 + 3 * (n / per);
            unsigned l, r;
            if (off + 2 >= size)
                continue;
            l = ((unsigned)f[off] << 4) | (f[off + 2] >> 4);
            r = ((unsigned)f[off + 1] << 4) | (f[off + 2] & 0x0F);
            out[n * 2] = l == 0x800 ? 0 : dv_12to16(l);
            out[n * 2 + 1] = r == 0x800 ? 0 : dv_12to16(r);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Big endian writers                                                  */

typedef struct buf { uint8_t *d; size_t n, cap; } buf;

static void bput(buf *b, const void *p, size_t n)
{
    if (b->n + n > b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 4096;
        uint8_t *nd;
        while (nc < b->n + n)
            nc *= 2;
        nd = (uint8_t *)realloc(b->d, nc);
        if (!nd)
            return;
        b->d = nd;
        b->cap = nc;
    }
    memcpy(b->d + b->n, p, n);
    b->n += n;
}
static void b8(buf *b, unsigned v) { uint8_t x = (uint8_t)v; bput(b, &x, 1); }
static void b16(buf *b, unsigned v) { b8(b, v >> 8); b8(b, v); }
static void b32(buf *b, uint32_t v) { b16(b, v >> 16); b16(b, v & 0xFFFF); }
static void b64(buf *b, uint64_t v) { b32(b, (uint32_t)(v >> 32)); b32(b, (uint32_t)v); }
static void b4cc(buf *b, const char *s) { bput(b, s, 4); }
static size_t box_begin(buf *b, const char *t) { size_t p = b->n; b32(b, 0); b4cc(b, t); return p; }
static void box_end(buf *b, size_t p)
{
    uint32_t sz = (uint32_t)(b->n - p);
    b->d[p] = (uint8_t)(sz >> 24); b->d[p + 1] = (uint8_t)(sz >> 16);
    b->d[p + 2] = (uint8_t)(sz >> 8); b->d[p + 3] = (uint8_t)sz;
}
static void bzero_(buf *b, size_t n) { while (n--) b8(b, 0); }
static void matrix(buf *b)
{
    b32(b, 0x00010000); b32(b, 0); b32(b, 0);
    b32(b, 0); b32(b, 0x00010000); b32(b, 0);
    b32(b, 0); b32(b, 0); b32(b, 0x40000000);
}

static void write_u32be(FILE *fp, uint32_t v)
{
    uint8_t x[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    fwrite(x, 1, 4, fp);
}

/* ------------------------------------------------------------------ */

typedef struct mov_frame { int64_t pos; uint32_t size; uint16_t samples; } mov_frame;
typedef struct scan_ctx { mov_frame *f; size_t n, cap; } scan_ctx;

static void scan_cb(void *ctx, const uint8_t *frame, size_t size, int64_t pos)
{
    scan_ctx *s = (scan_ctx *)ctx;
    if (s->n == s->cap) {
        size_t nc = s->cap ? s->cap * 2 : 4096;
        mov_frame *nf = (mov_frame *)realloc(s->f, nc * sizeof(mov_frame));
        if (!nf)
            return;
        s->f = nf;
        s->cap = nc;
    }
    s->f[s->n].pos = pos;
    s->f[s->n].size = (uint32_t)size;
    s->f[s->n].samples = 0;
    s->n++;
    (void)frame;
}

static void write_audio_trak(buf *m, int id, uint32_t rate, uint64_t total, const mov_frame *fr, size_t n,
                             const uint64_t *offs, int track_index, int ntracks, uint32_t mvhd_dur, uint32_t mvts)
{
    size_t trak = box_begin(m, "trak"), p, q, r, s, t;
    size_t i, runs = 0;
    p = box_begin(m, "tkhd");
    b32(m, 0x0000000F); b32(m, 0); b32(m, 0); b32(m, (uint32_t)id); b32(m, 0); b32(m, mvhd_dur);
    b32(m, 0); b32(m, 0); b16(m, 0); b16(m, 1); b16(m, 0x0100); b16(m, 0);
    matrix(m); b32(m, 0); b32(m, 0);
    box_end(m, p);
    q = box_begin(m, "mdia");
    p = box_begin(m, "mdhd");
    b32(m, 0); b32(m, 0); b32(m, 0); b32(m, rate); b32(m, (uint32_t)total); b16(m, 0); b16(m, 0);
    box_end(m, p);
    p = box_begin(m, "hdlr");
    b32(m, 0); b4cc(m, "mhlr"); b4cc(m, "soun"); b32(m, 0); b32(m, 0); b32(m, 0);
    b8(m, 13); bput(m, "Sound Handler", 13);
    box_end(m, p);
    r = box_begin(m, "minf");
    p = box_begin(m, "smhd"); b32(m, 0); b16(m, 0); b16(m, 0); box_end(m, p);
    p = box_begin(m, "dinf");
    s = box_begin(m, "dref"); b32(m, 0); b32(m, 1);
    t = box_begin(m, "alis"); b32(m, 1); box_end(m, t);
    box_end(m, s);
    box_end(m, p);
    s = box_begin(m, "stbl");
    p = box_begin(m, "stsd"); b32(m, 0); b32(m, 1);
    t = box_begin(m, "twos");
    bzero_(m, 6); b16(m, 1);           /* data reference index */
    b16(m, 0); b16(m, 0); b32(m, 0);   /* version 0 sound description */
    b16(m, 2); b16(m, 16);             /* channels, bits */
    b16(m, 0); b16(m, 0);
    b32(m, rate << 16);
    box_end(m, t);
    box_end(m, p);
    p = box_begin(m, "stts"); b32(m, 0); b32(m, 1); b32(m, (uint32_t)total); b32(m, 1); box_end(m, p);
    /* stsc: runs of chunks with the same number of samples */
    p = box_begin(m, "stsc"); b32(m, 0);
    {
        size_t cnt_pos = m->n;
        b32(m, 0);
        for (i = 0; i < n; i++)
            if (!i || fr[i].samples != fr[i - 1].samples) {
                b32(m, (uint32_t)(i + 1)); b32(m, fr[i].samples); b32(m, 1);
                runs++;
            }
        m->d[cnt_pos] = (uint8_t)(runs >> 24); m->d[cnt_pos + 1] = (uint8_t)(runs >> 16);
        m->d[cnt_pos + 2] = (uint8_t)(runs >> 8); m->d[cnt_pos + 3] = (uint8_t)runs;
    }
    box_end(m, p);
    p = box_begin(m, "stsz"); b32(m, 0); b32(m, 1); b32(m, (uint32_t)total); box_end(m, p);
    p = box_begin(m, "co64"); b32(m, 0); b32(m, (uint32_t)n);
    for (i = 0; i < n; i++)
        b64(m, offs[i * (1 + ntracks) + 1 + track_index]);
    box_end(m, p);
    box_end(m, s);
    box_end(m, r);
    box_end(m, q);
    box_end(m, trak);
    (void)mvts;
}

int dv_write_mov(const char *in, int64_t start, int64_t end, const char *out,
                 dv_log_cb log, dv_progress_cb progress, void *ctx)
{
    FILE *fi = fopen(in, "rb"), *fo = NULL;
    scan_ctx sc;
    dv_splitter sp;
    uint8_t *data = NULL, *frame = NULL;
    int16_t *pcm = NULL;
    uint64_t *offs = NULL;
    size_t i, n;
    int ret = -1, ntracks = 0, k;
    dv_frame info;
    dv_analyzer an;
    dv_audio_fmt af0, af;
    uint32_t vsize, vts, vdur;
    uint64_t total_samples = 0, mdat_start, mdat_end;
    buf m;
    char line[256];

    memset(&sc, 0, sizeof(sc));
    memset(&m, 0, sizeof(m));
    if (!fi)
        return -1;
    /* 1. find the frames of the range */
    dv_splitter_init(&sp);
    data = (uint8_t *)malloc(1 << 20);
    if (!data)
        goto done;
    if (end <= 0) {
        fseeko(fi, 0, SEEK_END);
        end = (int64_t)ftello(fi);
    }
    fseeko(fi, start, SEEK_SET);
    sp.stream_pos = start;
    {
        int64_t pos = start;
        while (pos < end) {
            size_t want = (size_t)(end - pos > (1 << 20) ? (1 << 20) : end - pos);
            size_t got = fread(data, 1, want, fi);
            if (!got)
                break;
            dv_splitter_push(&sp, data, got, scan_cb, &sc);
            pos += (int64_t)got;
        }
    }
    dv_splitter_flush(&sp, scan_cb, &sc);
    dv_splitter_free(&sp);
    n = sc.n;
    if (!n) {
        if (log) log(ctx, "No DV frame found.");
        goto done;
    }

    /* 2. format from the first frame */
    frame = (uint8_t *)malloc(DV_MAX_FRAME * 4);
    pcm = (int16_t *)malloc(4000 * 2 * sizeof(int16_t));
    offs = (uint64_t *)calloc(n * 3, sizeof(uint64_t));
    if (!frame || !pcm || !offs)
        goto done;
    fseeko(fi, sc.f[0].pos, SEEK_SET);
    if (fread(frame, 1, sc.f[0].size > DV_MAX_FRAME * 4 ? DV_MAX_FRAME * 4 : sc.f[0].size, fi) == 0)
        goto done;
    dv_analyzer_init(&an, 0);
    dv_analyze_frame(&an, frame, sc.f[0].size, 0, &info);
    dv_frame_free(&info);
    /* look a few frames further for audio / aspect (first frame may be damaged) */
    memset(&af0, 0, sizeof(af0));
    for (i = 0; i < n && i < 30; i++) {
        fseeko(fi, sc.f[i].pos, SEEK_SET);
        if (fread(frame, 1, sc.f[i].size, fi) != sc.f[i].size)
            break;
        dv_analyze_frame(&an, frame, sc.f[i].size, 0, &info);
        dv_frame_free(&info);
        if (!af0.rate && dv_audio_info(frame, sc.f[i].size, &af0) == 0)
            break;
    }
    vsize = info.dsf ? 144000 : 120000;
    vts = info.dsf ? 25 : 30000;
    vdur = info.dsf ? 1 : 1001;
    ntracks = af0.rate ? af0.pairs : 0;

    fo = fopen(out, "wb");
    if (!fo) {
        if (log) { snprintf(line, sizeof(line), "Cannot write %s", out); log(ctx, line); }
        goto done;
    }
    /* ftyp + wide + mdat (64-bit size, patched at the end) */
    {
        static const uint8_t ftyp[] = { 0, 0, 0, 20, 'f', 't', 'y', 'p', 'q', 't', ' ', ' ', 0, 0, 2, 0, 'q', 't', ' ', ' ' };
        fwrite(ftyp, 1, sizeof(ftyp), fo);
        write_u32be(fo, 1);
        fwrite("mdat", 1, 4, fo);
        write_u32be(fo, 0);
        write_u32be(fo, 0);
    }
    mdat_start = 20;

    /* 3. interleave: one DV frame, then its audio for each pair */
    for (i = 0; i < n; i++) {
        size_t got;
        fseeko(fi, sc.f[i].pos, SEEK_SET);
        got = fread(frame, 1, sc.f[i].size > DV_MAX_FRAME * 4 ? DV_MAX_FRAME * 4 : sc.f[i].size, fi);
        if (got < vsize) /* damaged / short frame: pad (decoder conceals) */
            memset(frame + got, 0, vsize - got);
        offs[i * 3] = (uint64_t)ftello(fo);
        if (fwrite(frame, 1, vsize, fo) != vsize)
            goto done;
        if (ntracks) {
            uint16_t ns;
            if (dv_audio_info(frame, got, &af) == 0 && af.rate == af0.rate && af.quant == af0.quant)
                ns = (uint16_t)af.samples;
            else {
                af = af0;
                ns = (uint16_t)(i ? sc.f[i - 1].samples : af0.samples);
                af.samples = ns;
                memset(frame, 0, got); /* silence */
                got = 0;
            }
            sc.f[i].samples = ns;
            total_samples += ns;
            for (k = 0; k < ntracks; k++) {
                size_t j;
                uint8_t *o = (uint8_t *)pcm;
                if (got)
                    dv_audio_extract(frame, got, &af, k, pcm);
                else
                    memset(pcm, 0, (size_t)ns * 4);
                for (j = 0; j < (size_t)ns * 2; j++) { /* big endian 'twos' */
                    uint16_t v = (uint16_t)pcm[j];
                    o[j * 2] = (uint8_t)(v >> 8);
                    o[j * 2 + 1] = (uint8_t)v;
                }
                offs[i * 3 + 1 + k] = (uint64_t)ftello(fo);
                if (fwrite(pcm, 1, (size_t)ns * 4, fo) != (size_t)ns * 4)
                    goto done;
            }
        }
        if (progress && !(i % 50) && progress(ctx, (double)i / n))
            goto done;
    }
    mdat_end = (uint64_t)ftello(fo);
    /* patch mdat 64-bit size */
    fseeko(fo, (off_t)(mdat_start + 8), SEEK_SET);
    write_u32be(fo, (uint32_t)((mdat_end - mdat_start) >> 32));
    write_u32be(fo, (uint32_t)(mdat_end - mdat_start));
    fseeko(fo, 0, SEEK_END);

    /* 4. moov */
    {
        size_t moov = box_begin(&m, "moov"), p, q, r, s, t, trak;
        uint32_t movie_dur = (uint32_t)((uint64_t)n * vdur * 600 / vts);
        p = box_begin(&m, "mvhd");
        b32(&m, 0); b32(&m, 0); b32(&m, 0); b32(&m, 600); b32(&m, movie_dur);
        b32(&m, 0x00010000); b16(&m, 0x0100); bzero_(&m, 10); matrix(&m);
        bzero_(&m, 24); b32(&m, (uint32_t)(2 + ntracks));
        box_end(&m, p);

        /* video track */
        trak = box_begin(&m, "trak");
        p = box_begin(&m, "tkhd");
        b32(&m, 0x0000000F); b32(&m, 0); b32(&m, 0); b32(&m, 1); b32(&m, 0); b32(&m, movie_dur);
        b32(&m, 0); b32(&m, 0); b16(&m, 0); b16(&m, 0); b16(&m, 0); b16(&m, 0);
        matrix(&m);
        {
            /* display size in square pixels */
            uint32_t w = info.aspect_n == 16 ? (info.dsf ? 1024 : 853) : (info.dsf ? 768 : 640);
            uint32_t h = info.dsf ? 576 : 480;
            b32(&m, w << 16); b32(&m, h << 16);
        }
        box_end(&m, p);
        q = box_begin(&m, "mdia");
        p = box_begin(&m, "mdhd");
        b32(&m, 0); b32(&m, 0); b32(&m, 0); b32(&m, vts); b32(&m, (uint32_t)(n * vdur)); b16(&m, 0); b16(&m, 0);
        box_end(&m, p);
        p = box_begin(&m, "hdlr");
        b32(&m, 0); b4cc(&m, "mhlr"); b4cc(&m, "vide"); b32(&m, 0); b32(&m, 0); b32(&m, 0);
        b8(&m, 13); bput(&m, "Video Handler", 13);
        box_end(&m, p);
        r = box_begin(&m, "minf");
        p = box_begin(&m, "vmhd"); b32(&m, 1); b16(&m, 0x40); b16(&m, 0x8000); b16(&m, 0x8000); b16(&m, 0x8000); box_end(&m, p);
        p = box_begin(&m, "dinf");
        s = box_begin(&m, "dref"); b32(&m, 0); b32(&m, 1);
        t = box_begin(&m, "alis"); b32(&m, 1); box_end(&m, t);
        box_end(&m, s);
        box_end(&m, p);
        s = box_begin(&m, "stbl");
        p = box_begin(&m, "stsd"); b32(&m, 0); b32(&m, 1);
        t = box_begin(&m, info.dsf ? "dvcp" : "dvc ");
        bzero_(&m, 6); b16(&m, 1);
        b16(&m, 0); b16(&m, 0); b4cc(&m, "appl"); b32(&m, 0); b32(&m, 0x200);
        b16(&m, 720); b16(&m, info.dsf ? 576 : 480);
        b32(&m, 0x00480000); b32(&m, 0x00480000); b32(&m, 0); b16(&m, 1);
        {
            const char *cname = info.dsf ? "DV - PAL" : "DV - NTSC";
            size_t cl = strlen(cname);
            b8(&m, (unsigned)cl);
            bput(&m, cname, cl);
            bzero_(&m, 31 - cl);
        }
        b16(&m, 24); b16(&m, 0xFFFF);
        {
            size_t f = box_begin(&m, "fiel"); b16(&m, 0x0206); box_end(&m, f);
        }
        {
            size_t pa = box_begin(&m, "pasp");
            if (info.aspect_n == 16) { b32(&m, info.dsf ? 118 : 40); b32(&m, info.dsf ? 81 : 33); }
            else { b32(&m, info.dsf ? 59 : 10); b32(&m, info.dsf ? 54 : 11); }
            box_end(&m, pa);
        }
        box_end(&m, t);
        box_end(&m, p);
        p = box_begin(&m, "stts"); b32(&m, 0); b32(&m, 1); b32(&m, (uint32_t)n); b32(&m, vdur); box_end(&m, p);
        p = box_begin(&m, "stsc"); b32(&m, 0); b32(&m, 1); b32(&m, 1); b32(&m, 1); b32(&m, 1); box_end(&m, p);
        p = box_begin(&m, "stsz"); b32(&m, 0); b32(&m, vsize); b32(&m, (uint32_t)n); box_end(&m, p);
        p = box_begin(&m, "co64"); b32(&m, 0); b32(&m, (uint32_t)n);
        for (i = 0; i < n; i++)
            b64(&m, offs[i * 3]);
        box_end(&m, p);
        box_end(&m, s);
        box_end(&m, r);
        box_end(&m, q);
        box_end(&m, trak);

        for (k = 0; k < ntracks; k++)
            write_audio_trak(&m, 2 + k, af0.rate, total_samples, sc.f, n, offs, k, 2, movie_dur, 600);
        box_end(&m, moov);
        if (fwrite(m.d, 1, m.n, fo) != m.n)
            goto done;
    }
    if (fclose(fo)) {
        fo = NULL;
        goto done;
    }
    fo = NULL;
    if (progress)
        progress(ctx, 1.0);
    if (log) {
        snprintf(line, sizeof(line), "%s: %lu frames, %s%s", out, (unsigned long)n,
                 ntracks ? "PCM audio" : "no audio", ntracks == 2 ? " (2 stereo tracks)" : "");
        log(ctx, line);
    }
    ret = 0;
done:
    if (fo)
        fclose(fo);
    fclose(fi);
    free(sc.f);
    free(data);
    free(frame);
    free(pcm);
    free(offs);
    free(m.d);
    return ret;
}
