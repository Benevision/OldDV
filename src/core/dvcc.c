/*
 * OldDV Rescue - closed captions (EIA-608) of a DV file.
 *
 * NTSC DV carries the two caption bytes of each field in VAUX pack 0x65
 * (repeated in every DIF sequence): 2 bytes of field 1, 2 bytes of field 2.
 * They are exported untouched as a Scenarist .scc file, or decoded
 * (channel 1 of the field: CC1 or CC3) to .srt / WebVTT text.
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>

/* caption bytes of one frame: 1 if the pack was found */
int dv_frame_captions(const uint8_t *f, size_t size, uint8_t cc[4])
{
    size_t seq, nseq = size / 12000, b;
    int p;
    for (seq = 0; seq < nseq; seq++)
        for (b = 0; b < 150; b++) {
            const uint8_t *blk = f + seq * 12000 + b * 80;
            if ((blk[0] >> 5) != 2)
                continue;
            for (p = 0; p < 15; p++)
                if (blk[3 + p * 5] == 0x65) {
                    memcpy(cc, blk + 3 + p * 5 + 1, 4);
                    return 1;
                }
        }
    return 0;
}

/* ------------------------------------------------------------------ */
/* EIA-608 decoder, one channel                                         */

#define ROWS 15
#define COLS 32

typedef struct { uint16_t c[ROWS][COLS]; } screen;

typedef struct {
    char *text;
    uint64_t t0, t1; /* ms */
} cue;

typedef struct {
    screen disp, back;
    int mode;        /* 0 pop-on, 1 roll-up, 2 paint-on, 3 text (ignored) */
    int ru;          /* rows of the roll-up window */
    int row, col;
    int chan;        /* channel of the last control code */
    int xds;
    int prev1, prev2;/* last control code, to drop its repetition */
    int dirty;
    uint64_t dirty_ms;
    char *cur;
    uint64_t cur_t0;
    cue *cues;
    size_t ncues, capcues;
    int err;
} cc608;

static const uint16_t special_chars[16] = {
    0xAE, 0xB0, 0xBD, 0xBF, 0x2122, 0xA2, 0xA3, 0x266A, 0xE0, 0x20, 0xE8, 0xE2, 0xEA, 0xEE, 0xF4, 0xFB
};
static const uint16_t ext1[32] = {
    0xC1, 0xC9, 0xD3, 0xDA, 0xDC, 0xFC, 0x2018, 0xA1, 0x2A, 0x27, 0x2014, 0xA9, 0x2120, 0x2022, 0x201C, 0x201D,
    0xC0, 0xC2, 0xC7, 0xC8, 0xCA, 0xCB, 0xEB, 0xCE, 0xCF, 0xEF, 0xD4, 0xD9, 0xF9, 0xDB, 0xAB, 0xBB
};
static const uint16_t ext2[32] = {
    0xC3, 0xE3, 0xCD, 0xCC, 0xEC, 0xD2, 0xF2, 0xD5, 0xF5, 0x7B, 0x7D, 0x5C, 0x5E, 0x5F, 0x7C, 0x7E,
    0xC4, 0xE4, 0xD6, 0xF6, 0xDF, 0xA5, 0xA4, 0x2502, 0xC5, 0xE5, 0xD8, 0xF8, 0x250C, 0x2510, 0x2514, 0x2518
};

static uint16_t basic_char(int c)
{
    switch (c) {
    case 0x2A: return 0xE1;
    case 0x5C: return 0xE9;
    case 0x5E: return 0xED;
    case 0x5F: return 0xF3;
    case 0x60: return 0xFA;
    case 0x7B: return 0xE7;
    case 0x7C: return 0xF7;
    case 0x7D: return 0xD1;
    case 0x7E: return 0xF1;
    case 0x7F: return 0x2588;
    }
    return (uint16_t)c;
}

static size_t utf8(char *o, unsigned cp)
{
    if (cp < 0x80) { o[0] = (char)cp; return 1; }
    if (cp < 0x800) { o[0] = (char)(0xC0 | (cp >> 6)); o[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
    o[0] = (char)(0xE0 | (cp >> 12)); o[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); o[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
}

/* what is on the screen, rows separated by \n; malloc'ed, "" when empty */
static char *screen_text(const screen *s)
{
    char *t = (char *)malloc(ROWS * (COLS * 3 + 1) + 1);
    size_t n = 0;
    int r, c;
    if (!t)
        return NULL;
    for (r = 0; r < ROWS; r++) {
        int a = 0, b = COLS - 1;
        while (a < COLS && (!s->c[r][a] || s->c[r][a] == ' '))
            a++;
        while (b >= a && (!s->c[r][b] || s->c[r][b] == ' '))
            b--;
        if (a > b)
            continue;
        if (n)
            t[n++] = '\n';
        for (c = a; c <= b; c++)
            n += utf8(t + n, s->c[r][c] ? s->c[r][c] : ' ');
    }
    t[n] = 0;
    return t;
}

/* the screen changed (or may have): close the running cue, start another */
static void cc_update(cc608 *d, uint64_t ms)
{
    char *t = screen_text(&d->disp);
    d->dirty = 0;
    if (!t) {
        d->err = 1;
        return;
    }
    if (d->cur && !strcmp(t, d->cur)) {
        free(t);
        return;
    }
    if (d->cur && d->cur[0] && ms > d->cur_t0) {
        if (d->ncues == d->capcues) {
            size_t nc = d->capcues ? d->capcues * 2 : 256;
            cue *q = (cue *)realloc(d->cues, nc * sizeof(cue));
            if (!q) {
                d->err = 1;
                free(t);
                return;
            }
            d->cues = q;
            d->capcues = nc;
        }
        d->cues[d->ncues].text = d->cur;
        d->cues[d->ncues].t0 = d->cur_t0;
        d->cues[d->ncues++].t1 = ms;
        d->cur = NULL;
    }
    free(d->cur);
    d->cur = t;
    d->cur_t0 = ms;
}

static screen *cc_target(cc608 *d) { return d->mode == 0 ? &d->back : &d->disp; }

static void cc_put(cc608 *d, uint16_t cp, uint64_t ms)
{
    if (d->mode == 3)
        return;
    cc_target(d)->c[d->row][d->col] = cp;
    if (d->col < COLS - 1)
        d->col++;
    if (d->mode && !d->dirty) {
        d->dirty = 1;
        d->dirty_ms = ms;
    } else if (d->mode)
        d->dirty_ms = ms;
}

static void cc_backspace(cc608 *d)
{
    if (d->col > 0) {
        d->col--;
        cc_target(d)->c[d->row][d->col] = 0;
    }
}

static void cc_roll_to(cc608 *d, int row)
{
    int i;
    screen n;
    if (row == d->row)
        return;
    memset(&n, 0, sizeof(n));
    for (i = 0; i < d->ru; i++)
        if (d->row - i >= 0 && row - i >= 0)
            memcpy(n.c[row - i], d->disp.c[d->row - i], sizeof(n.c[0]));
    d->disp = n;
}

static void cc_command(cc608 *d, int c2, uint64_t ms)
{
    int i;
    switch (c2) {
    case 0x20: /* resume caption loading */
        d->mode = 0;
        break;
    case 0x21:
        cc_backspace(d);
        break;
    case 0x24: /* delete to end of row */
        if (d->mode != 3)
            for (i = d->col; i < COLS; i++)
                cc_target(d)->c[d->row][i] = 0;
        break;
    case 0x25: case 0x26: case 0x27: /* roll-up captions, 2 to 4 rows */
        if (d->mode != 1) {
            memset(&d->disp, 0, sizeof(d->disp));
            memset(&d->back, 0, sizeof(d->back));
            d->row = ROWS - 1;
            d->col = 0;
            cc_update(d, ms);
        }
        d->mode = 1;
        d->ru = c2 - 0x23;
        break;
    case 0x29: /* resume direct captioning */
        d->mode = 2;
        break;
    case 0x2A: case 0x2B: /* text */
        d->mode = 3;
        break;
    case 0x2C: /* erase displayed memory */
        memset(&d->disp, 0, sizeof(d->disp));
        cc_update(d, ms);
        break;
    case 0x2D: /* carriage return */
        if (d->mode != 1)
            break;
        cc_update(d, ms);
        for (i = d->row - d->ru + 1; i < d->row; i++)
            if (i >= 0)
                memcpy(d->disp.c[i], d->disp.c[i + 1], sizeof(d->disp.c[0]));
        memset(d->disp.c[d->row], 0, sizeof(d->disp.c[0]));
        d->col = 0;
        break;
    case 0x2E: /* erase non displayed memory */
        memset(&d->back, 0, sizeof(d->back));
        break;
    case 0x2F: /* end of caption: flip memories */
        {
            screen t = d->disp;
            d->disp = d->back;
            d->back = t;
        }
        d->mode = 0;
        cc_update(d, ms);
        break;
    }
}

static void cc_pair(cc608 *d, int c1, int c2, uint64_t ms)
{
    c1 &= 0x7F;
    c2 &= 0x7F;
    if (d->dirty && ms - d->dirty_ms >= 1000)
        cc_update(d, ms);
    if (!c1 && !c2) {
        d->prev1 = d->prev2 = 0;
        return;
    }
    if (c1 >= 0x10 && c1 <= 0x1F) {
        static const int pac_row[8] = { 10, 0, 2, 11, 13, 4, 6, 8 };
        int rep = c1 == d->prev1 && c2 == d->prev2;
        d->prev1 = rep ? 0 : c1;
        d->prev2 = rep ? 0 : c2;
        d->xds = 0;
        if (rep)
            return;
        d->chan = (c1 & 0x08) ? 2 : 1;
        if (d->chan != 1)
            return;
        c1 &= 0x17;
        if (c1 == 0x15) /* field 2 uses 15 for 14 */
            c1 = 0x14;
        if (c2 >= 0x40) {
            /* preamble address code: row, indent */
            int row = pac_row[c1 & 7] + ((c2 & 0x20) && c1 != 0x10 ? 1 : 0);
            if (d->mode == 1)
                cc_roll_to(d, row);
            d->row = row;
            d->col = (c2 & 0x10) ? ((c2 & 0x0E) >> 1) * 4 : 0;
        } else if (c1 == 0x11 && c2 >= 0x20 && c2 <= 0x2F)
            cc_put(d, ' ', ms); /* mid-row style change takes one cell */
        else if (c1 == 0x11 && c2 >= 0x30 && c2 <= 0x3F)
            cc_put(d, special_chars[c2 - 0x30], ms);
        else if ((c1 == 0x12 || c1 == 0x13) && c2 >= 0x20 && c2 <= 0x3F) {
            cc_backspace(d); /* replaces the plain character sent before it */
            cc_put(d, c1 == 0x12 ? ext1[c2 - 0x20] : ext2[c2 - 0x20], ms);
        } else if (c1 == 0x14 && c2 >= 0x20 && c2 <= 0x2F)
            cc_command(d, c2, ms);
        else if (c1 == 0x17 && c2 >= 0x21 && c2 <= 0x23) {
            d->col += c2 - 0x20;
            if (d->col > COLS - 1)
                d->col = COLS - 1;
        }
        return;
    }
    d->prev1 = d->prev2 = 0;
    if (c1 && c1 < 0x10) {
        /* extended data services (field 2): not captions */
        d->xds = c1 != 0x0F;
        return;
    }
    if (d->xds || d->chan != 1)
        return;
    if (c1 >= 0x20)
        cc_put(d, basic_char(c1), ms);
    if (c2 >= 0x20)
        cc_put(d, basic_char(c2), ms);
}

/* ------------------------------------------------------------------ */

typedef struct {
    int fmt, field;
    int dsf;
    uint64_t nframes;
    uint64_t pairs;        /* frames that carry caption data */
    cc608 dec;
    /* scc */
    char *scc;
    size_t nscc, capscc;
    int in_line;
    int err;
    dv_progress_cb progress;
    void *pctx;
    int64_t in_start, in_end;
} ccx;

static uint64_t cc_ms(const ccx *x, uint64_t frame)
{
    return x->dsf ? frame * 40 : (frame * 1001 + 15) / 30;
}

static void scc_add(ccx *x, const char *s)
{
    size_t n = strlen(s);
    if (x->nscc + n + 1 > x->capscc) {
        size_t nc = x->capscc ? x->capscc * 2 : 65536;
        char *p;
        while (nc < x->nscc + n + 1)
            nc *= 2;
        p = (char *)realloc(x->scc, nc);
        if (!p) {
            x->err = 1;
            return;
        }
        x->scc = p;
        x->capscc = nc;
    }
    memcpy(x->scc + x->nscc, s, n + 1);
    x->nscc += n;
}

static void cc_frame_cb(void *ctx, const uint8_t *data, size_t size, int64_t pos)
{
    ccx *x = (ccx *)ctx;
    uint8_t cc[4];
    int have, c1, c2;
    char t[40];
    if (x->err)
        return;
    if (!x->nframes)
        x->dsf = size >= 4 && (data[3] & 0x80);
    have = dv_frame_captions(data, size, cc);
    c1 = have ? cc[(x->field - 1) * 2] : 0x80;
    c2 = have ? cc[(x->field - 1) * 2 + 1] : 0x80;
    if ((c1 & 0x7F) || (c2 & 0x7F))
        x->pairs++;
    if (x->fmt == 0) {
        if ((c1 & 0x7F) || (c2 & 0x7F)) {
            if (!x->in_line) {
                uint64_t n = x->nframes;
                unsigned fps = x->dsf ? 25 : 30;
                if (!x->dsf) { /* drop frame time code */
                    uint64_t d = n / 17982, m = n % 17982;
                    n += 18 * d + (m >= 2 ? 2 * ((m - 2) / 1798) : 0);
                }
                snprintf(t, sizeof(t), "%s%02u:%02u:%02u%c%02u\t", x->nscc ? "\n\n" : "",
                         (unsigned)(n / fps / 3600), (unsigned)(n / fps / 60 % 60), (unsigned)(n / fps % 60),
                         x->dsf ? ':' : ';', (unsigned)(n % fps));
                scc_add(x, t);
                x->in_line = 1;
                snprintf(t, sizeof(t), "%02x%02x", c1, c2);
            } else
                snprintf(t, sizeof(t), " %02x%02x", c1, c2);
            scc_add(x, t);
        } else
            x->in_line = 0;
    } else
        cc_pair(&x->dec, c1, c2, cc_ms(x, x->nframes));
    x->nframes++;
    if (x->progress && !(x->nframes % 200) && x->in_end > x->in_start
        && x->progress(x->pctx, (double)(pos - x->in_start) / (double)(x->in_end - x->in_start)))
        x->err = 2;
}

static void fmt_time(char *o, size_t n, uint64_t ms, char sep)
{
    snprintf(o, n, "%02u:%02u:%02u%c%03u", (unsigned)(ms / 3600000), (unsigned)(ms / 60000 % 60),
             (unsigned)(ms / 1000 % 60), sep, (unsigned)(ms % 1000));
}

int dv_write_captions(const char *in, int64_t start, int64_t end, const char *out, int fmt, int field,
                      dv_log_cb log, dv_progress_cb progress, void *ctx)
{
    FILE *fi = fopen(in, "rb"), *fo = NULL;
    uint8_t *data = (uint8_t *)malloc(1 << 20);
    ccx *x = (ccx *)calloc(1, sizeof(ccx));
    dv_splitter sp;
    int64_t pos;
    int ret = -1;
    size_t i;
    char line[256];

    if (!fi || !data || !x)
        goto done;
    x->fmt = fmt;
    x->field = field == 2 ? 2 : 1;
    x->dec.chan = 1;
    x->dec.row = ROWS - 1;
    x->progress = progress;
    x->pctx = ctx;
    if (end <= 0) {
        fseeko(fi, 0, SEEK_END);
        end = (int64_t)ftello(fi);
    }
    x->in_start = start;
    x->in_end = end;
    dv_splitter_init(&sp);
    fseeko(fi, start, SEEK_SET);
    sp.stream_pos = start;
    for (pos = start; pos < end && !x->err;) {
        size_t want = (size_t)(end - pos > (1 << 20) ? (1 << 20) : end - pos);
        size_t got = fread(data, 1, want, fi);
        if (!got)
            break;
        dv_splitter_push(&sp, data, got, cc_frame_cb, x);
        pos += (int64_t)got;
    }
    if (!x->err)
        dv_splitter_flush(&sp, cc_frame_cb, x);
    dv_splitter_free(&sp);
    if (x->err || x->dec.err)
        goto done;
    if (fmt != 0) {
        /* close the caption that is still on the screen */
        if (x->dec.dirty) /* typed, not shown yet */
            cc_update(&x->dec, x->dec.dirty_ms);
        memset(&x->dec.disp, 0, sizeof(x->dec.disp));
        cc_update(&x->dec, cc_ms(x, x->nframes));
    }
    if (!x->pairs || (fmt != 0 && !x->dec.ncues)) {
        if (log) {
            snprintf(line, sizeof(line), "No closed captions in field %d of %s.", x->field, in);
            log(ctx, line);
        }
        ret = 1;
        goto done;
    }
    fo = fopen(out, "wb");
    if (!fo) {
        if (log) { snprintf(line, sizeof(line), "Cannot write %s", out); log(ctx, line); }
        goto done;
    }
    if (fmt == 0) {
        fputs("Scenarist_SCC V1.0\n\n", fo);
        fwrite(x->scc, 1, x->nscc, fo);
        fputs("\n\n", fo);
    } else {
        if (fmt == 2)
            fputs("WEBVTT\n\n", fo);
        for (i = 0; i < x->dec.ncues; i++) {
            char a[20], b[20];
            fmt_time(a, sizeof(a), x->dec.cues[i].t0, fmt == 2 ? '.' : ',');
            fmt_time(b, sizeof(b), x->dec.cues[i].t1, fmt == 2 ? '.' : ',');
            if (fmt == 1)
                fprintf(fo, "%lu\n", (unsigned long)i + 1);
            fprintf(fo, "%s --> %s\n%s\n\n", a, b, x->dec.cues[i].text);
        }
    }
    if (ferror(fo) || fclose(fo)) {
        fo = NULL;
        goto done;
    }
    fo = NULL;
    if (log) {
        if (fmt == 0)
            snprintf(line, sizeof(line), "%s: caption data of %lu frames", out, (unsigned long)x->pairs);
        else
            snprintf(line, sizeof(line), "%s: %lu captions", out, (unsigned long)x->dec.ncues);
        log(ctx, line);
    }
    if (progress)
        progress(ctx, 1.0);
    ret = 0;
done:
    if (fo)
        fclose(fo);
    if (fi)
        fclose(fi);
    if (x) {
        for (i = 0; i < x->dec.ncues; i++)
            free(x->dec.cues[i].text);
        free(x->dec.cues);
        free(x->dec.cur);
        free(x->scc);
        free(x);
    }
    free(data);
    return ret;
}
