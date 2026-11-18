/*
 * OldDV Rescue - lossless Matroska (.mkv) rewrap: the DV frames untouched
 * (V_MS/VFW/FOURCC "dvsd") and 16-bit PCM audio, one track per stereo pair.
 * Same audio handling as the QuickTime rewrap (dvmov.c).
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>

typedef struct { uint8_t *d; size_t n, cap; int err; } ebuf;

static void eput(ebuf *b, const void *p, size_t n)
{
    if (b->n + n > b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 4096;
        uint8_t *nd;
        while (nc < b->n + n)
            nc *= 2;
        nd = (uint8_t *)realloc(b->d, nc);
        if (!nd) {
            b->err = 1;
            return;
        }
        b->d = nd;
        b->cap = nc;
    }
    memcpy(b->d + b->n, p, n);
    b->n += n;
}

static void e8(ebuf *b, unsigned v) { uint8_t x = (uint8_t)v; eput(b, &x, 1); }

static void eid(ebuf *b, uint32_t id)
{
    if (id > 0xFFFFFF) e8(b, id >> 24);
    if (id > 0xFFFF) e8(b, id >> 16);
    if (id > 0xFF) e8(b, id >> 8);
    e8(b, id);
}

/* element size, always 8 bytes long (simple, and easy to patch) */
static void esize8(ebuf *b, uint64_t v)
{
    int i;
    e8(b, 0x01);
    for (i = 6; i >= 0; i--)
        e8(b, (unsigned)(v >> (i * 8)));
}

static void esize(ebuf *b, uint64_t v)
{
    if (v < 127)
        e8(b, 0x80 | (unsigned)v);
    else if (v < 16383) {
        e8(b, 0x40 | (unsigned)(v >> 8));
        e8(b, (unsigned)v);
    } else
        esize8(b, v);
}

static void euint(ebuf *b, uint32_t id, uint64_t v, int bytes)
{
    int i;
    eid(b, id);
    esize(b, (uint64_t)bytes);
    for (i = bytes - 1; i >= 0; i--)
        e8(b, (unsigned)(v >> (i * 8)));
}

static void efloat(ebuf *b, uint32_t id, double v)
{
    union { double d; uint64_t u; } x;
    x.d = v;
    euint(b, id, x.u, 8);
}

static void estr(ebuf *b, uint32_t id, const char *s)
{
    eid(b, id);
    esize(b, strlen(s));
    eput(b, s, strlen(s));
}

/* master element: returns where its 8 byte size is, for eend() */
static size_t ebegin(ebuf *b, uint32_t id)
{
    eid(b, id);
    esize8(b, 0);
    return b->n;
}

static void eend(ebuf *b, size_t start)
{
    uint64_t v = b->n - start;
    int i;
    if (b->err || start < 8)
        return;
    for (i = 0; i < 7; i++)
        b->d[start - 1 - i] = (uint8_t)(v >> (i * 8));
}

typedef struct {
    FILE *fo;
    int flags;
    int dsf, aspect16;
    dv_audio_fmt af0;
    int ntracks;
    uint32_t vsize;
    uint8_t *frame;
    int16_t *pcm;
    uint8_t *valid, *out;
    dv_audio_conceal conceal[2];
    int have_fmt;
    unsigned last_samples;
    uint64_t nframes, total_samples;
    ebuf cl;                 /* cluster being built */
    uint64_t cl_time;        /* ms */
    unsigned cl_frames;
    uint64_t seg_start;      /* file offset of the segment data */
    uint64_t *cue_time, *cue_pos;
    size_t ncues, capcues;
    int err;
    dv_progress_cb progress;
    void *pctx;
    int64_t in_start, in_end;
} mkv;

static uint64_t frame_ms(const mkv *k, uint64_t i)
{
    return k->dsf ? i * 40 : (i * 1001 + 15) / 30;
}

static void block(mkv *k, int track, uint64_t ms, const uint8_t *data, size_t size)
{
    int64_t rel = (int64_t)ms - (int64_t)k->cl_time;
    eid(&k->cl, 0xA3);
    esize(&k->cl, size + 4);
    e8(&k->cl, 0x80 | (unsigned)track);
    e8(&k->cl, (unsigned)(rel >> 8));
    e8(&k->cl, (unsigned)rel);
    e8(&k->cl, 0x80); /* key frame */
    eput(&k->cl, data, size);
}

static void flush_cluster(mkv *k)
{
    ebuf h;
    if (!k->cl_frames)
        return;
    memset(&h, 0, sizeof(h));
    if (k->ncues == k->capcues) {
        size_t nc = k->capcues ? k->capcues * 2 : 1024;
        uint64_t *a = (uint64_t *)realloc(k->cue_time, nc * sizeof(uint64_t));
        uint64_t *b = a ? (uint64_t *)realloc(k->cue_pos, nc * sizeof(uint64_t)) : NULL;
        if (a) k->cue_time = a;
        if (b) k->cue_pos = b;
        if (!a || !b) {
            k->err = 1;
            return;
        }
        k->capcues = nc;
    }
    k->cue_time[k->ncues] = k->cl_time;
    k->cue_pos[k->ncues++] = (uint64_t)ftello(k->fo) - k->seg_start;
    eid(&h, 0x1F43B675);
    esize8(&h, k->cl.n);
    if (h.err || k->cl.err || fwrite(h.d, 1, h.n, k->fo) != h.n || fwrite(k->cl.d, 1, k->cl.n, k->fo) != k->cl.n)
        k->err = 1;
    free(h.d);
    k->cl.n = 0;
    k->cl_frames = 0;
}

static void frame_cb(void *ctx, const uint8_t *data, size_t size, int64_t pos)
{
    mkv *k = (mkv *)ctx;
    uint64_t ms;
    size_t got = size > k->vsize ? k->vsize : size;
    int t;
    if (k->err)
        return;
    memcpy(k->frame, data, got);
    if (got < k->vsize) /* damaged / short frame: pad (decoder conceals) */
        memset(k->frame + got, 0, k->vsize - got);
    ms = frame_ms(k, k->nframes);
    if (!k->cl_frames) {
        k->cl_time = ms;
        euint(&k->cl, 0xE7, ms, 8);
    }
    block(k, 1, ms, k->frame, k->vsize);
    if (k->ntracks) {
        dv_audio_fmt cur, af;
        unsigned ns;
        uint64_t ams = k->total_samples * 1000 / k->af0.rate;
        if (dv_audio_info(k->frame, got, &cur) == 0) {
            if (cur.rate == k->af0.rate && cur.quant == k->af0.quant) {
                ns = (unsigned)cur.samples;
                k->have_fmt = 1;
            } else {
                /* another audio format than the file's tracks: silence */
                ns = k->last_samples;
                k->have_fmt = 0;
                got = 0;
            }
        } else {
            /* unreadable audio source pack: the samples may still be there */
            ns = k->last_samples;
            if (!k->have_fmt && k->nframes)
                got = 0;
        }
        af = k->af0;
        af.samples = (int)ns;
        k->last_samples = ns;
        for (t = 0; t < k->ntracks; t++) {
            size_t j;
            if (got)
                dv_audio_extract_ex(k->frame, got, &af, t, k->pcm, k->valid);
            else {
                memset(k->pcm, 0, (size_t)ns * 4);
                memset(k->valid, 0, (size_t)ns * 2);
            }
            if (!(k->flags & DV_EXPORT_NO_CONCEAL))
                dv_audio_conceal_frame(&k->conceal[t], k->pcm, k->valid, (int)ns);
            for (j = 0; j < (size_t)ns * 2; j++) { /* little endian */
                k->out[j * 2] = (uint8_t)k->pcm[j];
                k->out[j * 2 + 1] = (uint8_t)((uint16_t)k->pcm[j] >> 8);
            }
            block(k, 2 + t, ams, k->out, (size_t)ns * 4);
        }
        k->total_samples += ns;
    }
    k->nframes++;
    if (k->cl.err)
        k->err = 1;
    if (++k->cl_frames >= (unsigned)(k->dsf ? 25 : 30))
        flush_cluster(k);
    if (k->progress && !(k->nframes % 50) && k->in_end > k->in_start
        && k->progress(k->pctx, (double)(pos - k->in_start) / (double)(k->in_end - k->in_start)))
        k->err = 2;
}

/* first frames: format of the file */
typedef struct { dv_analyzer an; dv_frame info; dv_audio_fmt af; int n; } probe;

static void probe_cb(void *ctx, const uint8_t *data, size_t size, int64_t pos)
{
    probe *p = (probe *)ctx;
    (void)pos;
    if (p->n >= 250 || (p->n && p->af.rate))
        return;
    dv_analyze_frame(&p->an, data, size, 0, &p->info);
    dv_frame_free(&p->info);
    if (!p->af.rate)
        dv_audio_info(data, size, &p->af);
    p->n++;
}

/* SeekHead + Info + Tracks; always the same size for the same file */
static void write_head(const mkv *k, ebuf *b, uint64_t cues_pos, double duration_ms)
{
    size_t seek, info, tracks, p, q;
    static const uint32_t ids[3] = { 0x1549A966, 0x1654AE6B, 0x1C53BB6B };
    uint64_t posv[3];
    size_t patch[3];
    int i, t;
    seek = ebegin(b, 0x114D9B74);
    for (i = 0; i < 3; i++) {
        uint8_t idb[4];
        idb[0] = (uint8_t)(ids[i] >> 24); idb[1] = (uint8_t)(ids[i] >> 16); idb[2] = (uint8_t)(ids[i] >> 8); idb[3] = (uint8_t)ids[i];
        p = ebegin(b, 0x4DBB);
        eid(b, 0x53AB); esize(b, 4); eput(b, idb, 4);
        euint(b, 0x53AC, 0, 8);
        patch[i] = b->n - 8;
        eend(b, p);
    }
    eend(b, seek);
    posv[0] = b->n;
    info = ebegin(b, 0x1549A966);
    euint(b, 0x2AD7B1, 1000000, 4);
    efloat(b, 0x4489, duration_ms);
    estr(b, 0x4D80, "OldDV Rescue " OLDDV_VERSION);
    estr(b, 0x5741, "OldDV Rescue " OLDDV_VERSION);
    eend(b, info);
    posv[1] = b->n;
    tracks = ebegin(b, 0x1654AE6B);
    p = ebegin(b, 0xAE);
    euint(b, 0xD7, 1, 1);
    euint(b, 0x73C5, 1, 1);
    euint(b, 0x83, 1, 1);
    euint(b, 0x9C, 0, 1);
    euint(b, 0x23E383, k->dsf ? 40000000u : 33366667u, 4);
    estr(b, 0x22B59C, "und");
    estr(b, 0x86, "V_MS/VFW/FOURCC");
    {
        /* BITMAPINFOHEADER */
        uint8_t bi[40];
        uint32_t h = k->dsf ? 576 : 480;
        memset(bi, 0, sizeof(bi));
        bi[0] = 40;
        bi[4] = 720 & 0xFF; bi[5] = 720 >> 8;
        bi[8] = (uint8_t)h; bi[9] = (uint8_t)(h >> 8);
        bi[12] = 1;
        bi[14] = 24;
        memcpy(bi + 16, "dvsd", 4);
        bi[20] = (uint8_t)k->vsize; bi[21] = (uint8_t)(k->vsize >> 8); bi[22] = (uint8_t)(k->vsize >> 16);
        eid(b, 0x63A2); esize(b, 40); eput(b, bi, 40);
    }
    q = ebegin(b, 0xE0);
    euint(b, 0x9A, 1, 1);  /* interlaced */
    euint(b, 0x9D, 6, 1);  /* bottom field first */
    euint(b, 0xB0, 720, 2);
    euint(b, 0xBA, k->dsf ? 576 : 480, 2);
    euint(b, 0x54B0, k->aspect16 ? (k->dsf ? 1024 : 853) : (k->dsf ? 768 : 640), 2);
    euint(b, 0x54BA, k->dsf ? 576 : 480, 2);
    eend(b, q);
    eend(b, p);
    for (t = 0; t < k->ntracks; t++) {
        p = ebegin(b, 0xAE);
        euint(b, 0xD7, (uint64_t)(2 + t), 1);
        euint(b, 0x73C5, (uint64_t)(2 + t), 1);
        euint(b, 0x83, 2, 1);
        euint(b, 0x9C, 0, 1);
        estr(b, 0x22B59C, "und");
        estr(b, 0x86, "A_PCM/INT/LIT");
        q = ebegin(b, 0xE1);
        efloat(b, 0xB5, (double)k->af0.rate);
        euint(b, 0x9F, 2, 1);
        euint(b, 0x6264, 16, 1);
        eend(b, q);
        eend(b, p);
    }
    eend(b, tracks);
    posv[2] = cues_pos;
    /* the positions count from the start of the segment data, where this
     * buffer is written */
    for (i = 0; i < 3 && !b->err; i++) {
        int j;
        for (j = 0; j < 8; j++)
            b->d[patch[i] + j] = (uint8_t)(posv[i] >> ((7 - j) * 8));
    }
}

int dv_write_mkv(const char *in, int64_t start, int64_t end, const char *out, int flags,
                 dv_log_cb log, dv_progress_cb progress, void *ctx)
{
    FILE *fi = fopen(in, "rb");
    mkv k;
    probe pr;
    dv_splitter sp;
    uint8_t *data = NULL;
    ebuf h;
    int ret = -1;
    size_t head_size = 0, i;
    char line[256];
    int64_t pos;

    memset(&k, 0, sizeof(k));
    memset(&h, 0, sizeof(h));
    memset(&pr, 0, sizeof(pr));
    if (!fi)
        return -1;
    data = (uint8_t *)malloc(1 << 20);
    if (!data)
        goto done;
    if (end <= 0) {
        fseeko(fi, 0, SEEK_END);
        end = (int64_t)ftello(fi);
    }
    /* 1. format */
    dv_analyzer_init(&pr.an, 0);
    dv_splitter_init(&sp);
    fseeko(fi, start, SEEK_SET);
    sp.stream_pos = start;
    for (pos = start; pos < end && pr.n < 250 && !(pr.n && pr.af.rate);) {
        size_t want = (size_t)(end - pos > (1 << 20) ? (1 << 20) : end - pos);
        size_t got = fread(data, 1, want, fi);
        if (!got)
            break;
        dv_splitter_push(&sp, data, got, probe_cb, &pr);
        pos += (int64_t)got;
    }
    dv_splitter_flush(&sp, probe_cb, &pr);
    dv_splitter_free(&sp);
    if (!pr.n) {
        if (log) log(ctx, "No DV frame found.");
        goto done;
    }
    k.flags = flags;
    k.dsf = pr.info.dsf ? 1 : 0;
    k.aspect16 = pr.info.aspect_n == 16;
    k.af0 = pr.af;
    k.ntracks = pr.af.rate ? pr.af.pairs : 0;
    if (k.ntracks > 2)
        k.ntracks = 2;
    k.last_samples = (unsigned)pr.af.samples;
    k.vsize = k.dsf ? 144000 : 120000;
    k.frame = (uint8_t *)malloc(DV_MAX_FRAME * 4);
    k.pcm = (int16_t *)malloc(4000 * 2 * sizeof(int16_t));
    k.valid = (uint8_t *)malloc(4000 * 2);
    k.out = (uint8_t *)malloc(4000 * 4);
    if (!k.frame || !k.pcm || !k.valid || !k.out)
        goto done;
    dv_audio_conceal_init(&k.conceal[0]);
    dv_audio_conceal_init(&k.conceal[1]);
    k.progress = progress;
    k.pctx = ctx;
    k.in_start = start;
    k.in_end = end;

    k.fo = fopen(out, "wb");
    if (!k.fo) {
        if (log) { snprintf(line, sizeof(line), "Cannot write %s", out); log(ctx, line); }
        goto done;
    }
    /* 2. EBML header, segment, room for the head */
    {
        size_t p = ebegin(&h, 0x1A45DFA3);
        euint(&h, 0x4286, 1, 1);
        euint(&h, 0x42F7, 1, 1);
        euint(&h, 0x42F2, 4, 1);
        euint(&h, 0x42F3, 8, 1);
        estr(&h, 0x4282, "matroska");
        euint(&h, 0x4287, 4, 1);
        euint(&h, 0x4285, 2, 1);
        eend(&h, p);
        eid(&h, 0x18538067);
        esize8(&h, 0);
        k.seg_start = h.n;
        write_head(&k, &h, 0, 0);
        head_size = h.n - (size_t)k.seg_start;
        if (h.err || fwrite(h.d, 1, h.n, k.fo) != h.n)
            goto done;
    }
    /* 3. clusters */
    dv_splitter_init(&sp);
    fseeko(fi, start, SEEK_SET);
    sp.stream_pos = start;
    for (pos = start; pos < end && !k.err;) {
        size_t want = (size_t)(end - pos > (1 << 20) ? (1 << 20) : end - pos);
        size_t got = fread(data, 1, want, fi);
        if (!got)
            break;
        dv_splitter_push(&sp, data, got, frame_cb, &k);
        pos += (int64_t)got;
    }
    if (!k.err)
        dv_splitter_flush(&sp, frame_cb, &k);
    dv_splitter_free(&sp);
    if (!k.err)
        flush_cluster(&k);
    if (k.err)
        goto done;
    /* 4. cues, then the head and the segment size with their final values */
    {
        ebuf c;
        uint64_t cues_pos = (uint64_t)ftello(k.fo) - k.seg_start, seg_size;
        size_t p, q, r;
        memset(&c, 0, sizeof(c));
        p = ebegin(&c, 0x1C53BB6B);
        for (i = 0; i < k.ncues; i++) {
            q = ebegin(&c, 0xBB);
            euint(&c, 0xB3, k.cue_time[i], 8);
            r = ebegin(&c, 0xB7);
            euint(&c, 0xF7, 1, 1);
            euint(&c, 0xF1, k.cue_pos[i], 8);
            eend(&c, r);
            eend(&c, q);
        }
        eend(&c, p);
        if (c.err || fwrite(c.d, 1, c.n, k.fo) != c.n) {
            free(c.d);
            goto done;
        }
        free(c.d);
        seg_size = (uint64_t)ftello(k.fo) - k.seg_start;
        h.n = 0;
        write_head(&k, &h, cues_pos, (double)frame_ms(&k, k.nframes));
        if (h.err || h.n != head_size)
            goto done;
        fseeko(k.fo, (off_t)k.seg_start, SEEK_SET);
        if (fwrite(h.d, 1, h.n, k.fo) != h.n)
            goto done;
        h.n = 0;
        esize8(&h, seg_size);
        fseeko(k.fo, (off_t)(k.seg_start - 8), SEEK_SET);
        if (h.err || fwrite(h.d, 1, 8, k.fo) != 8)
            goto done;
    }
    if (fclose(k.fo)) {
        k.fo = NULL;
        goto done;
    }
    k.fo = NULL;
    if (progress)
        progress(ctx, 1.0);
    if (log) {
        uint64_t tot = k.conceal[0].total + k.conceal[1].total;
        uint64_t itp = k.conceal[0].interpolated + k.conceal[1].interpolated;
        uint64_t mut = k.conceal[0].muted + k.conceal[1].muted;
        snprintf(line, sizeof(line), "%s: %lu frames, %s%s", out, (unsigned long)k.nframes,
                 k.ntracks ? "PCM audio" : "no audio", k.ntracks == 2 ? " (2 stereo tracks)" : "");
        log(ctx, line);
        if (tot && (itp || mut)) {
            snprintf(line, sizeof(line), "  audio repair: %.1f%% of the samples were unreadable on the tape; "
                     "%.1f%% rebuilt by interpolation, %.1f%% muted",
                     100.0 * (double)(itp + mut) / (double)tot, 100.0 * (double)itp / (double)tot,
                     100.0 * (double)mut / (double)tot);
            log(ctx, line);
        }
    }
    ret = 0;
done:
    if (k.fo) {
        fclose(k.fo);
        remove(out);
    }
    fclose(fi);
    free(data);
    free(h.d);
    free(k.frame);
    free(k.pcm);
    free(k.valid);
    free(k.out);
    free(k.cl.d);
    free(k.cue_time);
    free(k.cue_pos);
    return ret;
}
