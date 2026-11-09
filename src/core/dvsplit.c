/*
 * OldDV Rescue - packager: split a DV capture into one file per recording
 * (and/or per format change / time code break), like DVRescue's dvpackager
 * does before rewrapping. Output stays raw DV (.dv), which QuickTime 7,
 * iMovie and Final Cut on Mac OS X 10.6 open directly.
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>

static int format_differs(const dv_frame *a, const dv_frame *b)
{
    return a->width != b->width || a->height != b->height || a->rate_n != b->rate_n
        || a->aspect_n != b->aspect_n || a->audio_rate != b->audio_rate
        || a->channels != b->channels || a->bitdepth != b->bitdepth;
}

static int copy_range(FILE *in, const char *name, int64_t from, int64_t to)
{
    FILE *out = fopen(name, "wb");
    uint8_t *buf;
    int ret = 0;
    if (!out)
        return -1;
    buf = (uint8_t *)malloc(1 << 20);
    if (!buf || fseeko(in, from, SEEK_SET)) {
        fclose(out);
        free(buf);
        return -1;
    }
    while (from < to) {
        size_t want = (size_t)((to - from) > (1 << 20) ? (1 << 20) : (to - from));
        size_t got = fread(buf, 1, want, in);
        if (!got || fwrite(buf, 1, got, out) != got) {
            ret = -1;
            break;
        }
        from += (int64_t)got;
    }
    free(buf);
    if (fclose(out))
        ret = -1;
    return ret;
}

int dv_split_file(const char *path, const char *outbase, int flags,
                  uint32_t min_frames, char **names, int max_names,
                  dv_log_cb log, dv_progress_cb progress, void *ctx)
{
    dv_report r;
    FILE *in;
    uint32_t i, start = 0;
    int parts = 0;
    uint32_t *cuts;
    uint32_t ncuts = 0;

    dv_report_init(&r, path);
    if (dv_analyze_file(path, &r, progress, ctx) != 0 || !r.count) {
        dv_report_free(&r);
        return -1;
    }
    cuts = (uint32_t *)malloc((r.count + 1) * sizeof(uint32_t));
    if (!cuts) {
        dv_report_free(&r);
        return -1;
    }
    cuts[ncuts++] = 0;
    for (i = 1; i < r.count; i++) {
        const dv_frame *f = &r.frames[i], *p = &r.frames[i - 1];
        int cut = 0;
        if ((flags & DV_SPLIT_REC_START) && (f->rec_start || (f->rdt_nc && !p->rdt_nc)))
            cut = 1;
        if ((flags & DV_SPLIT_FORMAT) && format_differs(f, p))
            cut = 1;
        if ((flags & DV_SPLIT_TC_BREAK) && f->tc_nc)
            cut = 1;
        if (cut && i - start >= (min_frames ? min_frames : 1)) {
            cuts[ncuts++] = i;
            start = i;
        }
    }
    cuts[ncuts] = r.count;

    in = fopen(path, "rb");
    if (!in) {
        free(cuts);
        dv_report_free(&r);
        return -1;
    }
    for (i = 0; i < ncuts; i++) {
        const dv_frame *a = &r.frames[cuts[i]];
        const dv_frame *z = &r.frames[cuts[i + 1] - 1];
        int64_t from = a->pos, to = z->pos + z->size;
        size_t len = strlen(outbase) + 32;
        char *name = (char *)malloc(len);
        char rd[40], line[256];
        if (!name)
            break;
        snprintf(name, len, "%s_part%03u.dv", outbase, i + 1);
        if (copy_range(in, name, from, to)) {
            if (log) {
                snprintf(line, sizeof(line), "Error writing %s", name);
                log(ctx, line);
            }
            free(name);
            parts = -1;
            break;
        }
        if (log) {
            dv_format_rdt(rd, a);
            snprintf(line, sizeof(line), "%s: frames %u-%u (%u frames)%s%s", name, cuts[i], cuts[i + 1] - 1,
                     cuts[i + 1] - cuts[i], rd[0] ? ", recorded " : "", rd);
            log(ctx, line);
        }
        if (parts < max_names && names)
            names[parts] = name;
        else
            free(name);
        parts++;
    }
    fclose(in);
    free(cuts);
    dv_report_free(&r);
    return parts;
}
