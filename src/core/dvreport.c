/*
 * OldDV Rescue - frame list and DVRescue compatible XML report.
 * The XML layout follows DVRescue's Output_Xml (BSD-3-Clause, MIPoPS).
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

void dv_report_init(dv_report *r, const char *path)
{
    memset(r, 0, sizeof(*r));
    if (path) {
        r->path = (char *)malloc(strlen(path) + 1);
        if (r->path)
            strcpy(r->path, path);
    }
    dv_analyzer_init(&r->an, 0);
}

void dv_report_free(dv_report *r)
{
    uint32_t i;
    for (i = 0; i < r->count; i++)
        dv_frame_free(&r->frames[i]);
    free(r->frames);
    free(r->path);
    memset(r, 0, sizeof(*r));
}

void dv_report_add(dv_report *r, const dv_frame *f)
{
    dv_frame *d;
    if (r->count == r->cap) {
        uint32_t nc = r->cap ? r->cap * 2 : 1024;
        dv_frame *nf = (dv_frame *)realloc(r->frames, nc * sizeof(dv_frame));
        if (!nf)
            return;
        r->frames = nf;
        r->cap = nc;
    }
    d = &r->frames[r->count++];
    *d = *f;
    free(d->block_status);
    d->block_status = NULL;
    d->block_count = 0;
    if (dv_frame_has_errors(d))
        r->frames_with_errors++;
    if (d->video_errors)
        r->frames_video_errors++;
    if (d->audio_errors)
        r->frames_audio_errors++;
    if (d->tc_nc)
        r->tc_breaks++;
    if (d->rdt_nc)
        r->rdt_breaks++;
    if (d->rec_start)
        r->rec_starts++;
    if (d->full_conceal_vid && d->full_conceal_aud)
        r->full_conceal++;
}

void dv_report_feed(dv_report *r, const uint8_t *frame, size_t size, int64_t pos)
{
    dv_frame f;
    dv_analyze_frame(&r->an, frame, size, pos, &f);
    dv_report_add(r, &f);
}

static void feed_cb(void *ctx, const uint8_t *frame, size_t size, int64_t pos)
{
    dv_report_feed((dv_report *)ctx, frame, size, pos);
}

int dv_analyze_file(const char *path, dv_report *r, dv_progress_cb progress, void *ctx)
{
    FILE *fp = fopen(path, "rb");
    uint8_t *buf;
    size_t n;
    int64_t total = 0, done = 0;
    dv_splitter sp;
    int cancelled = 0;
    if (!fp)
        return -1;
    fseeko(fp, 0, SEEK_END);
    total = (int64_t)ftello(fp);
    fseeko(fp, 0, SEEK_SET);
    r->file_size = total;
    buf = (uint8_t *)malloc(1 << 20);
    if (!buf) {
        fclose(fp);
        return -1;
    }
    dv_splitter_init(&sp);
    while ((n = fread(buf, 1, 1 << 20, fp)) > 0) {
        dv_splitter_push(&sp, buf, n, feed_cb, r);
        done += (int64_t)n;
        if (progress && total > 0 && progress(ctx, (double)done / (double)total)) {
            cancelled = 1;
            break;
        }
    }
    dv_splitter_flush(&sp, feed_cb, r);
    dv_splitter_free(&sp);
    free(buf);
    fclose(fp);
    return cancelled ? 1 : 0;
}

/* ------------------------------------------------------------------ */
/* Formatting                                                          */

void dv_format_tc(char *buf, const dv_frame *f)
{
    if (!f->tc_valid) {
        buf[0] = 0;
        return;
    }
    sprintf(buf, "%02d:%02d:%02d%c%02d", f->tc_h, f->tc_m, f->tc_s, f->tc_df ? ';' : ':', f->tc_f);
}

static void format_date(char *buf, const dv_frame *f)
{
    sprintf(buf, "%s%02d-%02d-%02d", f->rd_y >= 70 ? "19" : "20", f->rd_y, f->rd_m, f->rd_d);
}

void dv_format_rdt(char *buf, const dv_frame *f)
{
    buf[0] = 0;
    if (f->rd_valid)
        format_date(buf, f);
    if (f->rt_valid) {
        char *p = buf + strlen(buf);
        if (f->rd_valid)
            *p++ = ' ';
        sprintf(p, "%02d:%02d:%02d", f->rt_h, f->rt_m, f->rt_s);
        if (f->rt_f < 0x3F) {
            p += strlen(p);
            sprintf(p, "%c%02d", f->tc_df ? ';' : ':', f->rt_f);
        }
    }
}

void dv_format_ts(char *buf, uint64_t ns)
{
    /* same double based truncation as DVRescue (keeps reports identical) */
    uint64_t us = (uint64_t)floor((double)ns / 1000000000.0 * 1000000.0);
    uint64_t s = us / 1000000;
    unsigned long frac = (unsigned long)(us % 1000000);
    unsigned long h = (unsigned long)(s / 3600);
    sprintf(buf, "%02lu:%02lu:%02lu.%06lu", h, (unsigned long)((s / 60) % 60), (unsigned long)(s % 60), frac);
}

static void xml_escape(FILE *out, const char *s)
{
    for (; *s; s++) {
        switch (*s) {
        case '&': fputs("&amp;", out); break;
        case '<': fputs("&lt;", out); break;
        case '>': fputs("&gt;", out); break;
        case '"': fputs("&quot;", out); break;
        default: fputc(*s, out);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Groups ("frames" elements)                                          */

typedef struct dv_group {
    uint32_t start;
    /* change attributes */
    int16_t width, height;
    int8_t chroma;
    uint8_t aspect_n, aspect_d;
    uint32_t rate_n, rate_d, audio_rate;
    uint8_t channels, bitdepth;
} dv_group;

static void group_from_frame(dv_group *g, const dv_frame *f, uint32_t start)
{
    g->start = start;
    g->width = f->width; g->height = f->height; g->chroma = f->chroma;
    g->aspect_n = f->aspect_n; g->aspect_d = f->aspect_d;
    g->rate_n = f->rate_n; g->rate_d = f->rate_d;
    g->audio_rate = f->audio_rate; g->channels = f->channels; g->bitdepth = f->bitdepth;
}

static int group_same(const dv_group *g, const dv_frame *f)
{
    return g->width == f->width && g->height == f->height && g->chroma == f->chroma
        && g->aspect_n == f->aspect_n && g->aspect_d == f->aspect_d
        && g->rate_n == f->rate_n && g->rate_d == f->rate_d
        && g->audio_rate == f->audio_rate && g->channels == f->channels && g->bitdepth == f->bitdepth;
}

static int speed_np(int s) { return dv_speed_is_normal(s) ? DV_SPEED_UNKNOWN : s; }

static dv_group *compute_groups(const dv_report *r, uint32_t *ngroups)
{
    uint32_t n = 0, cap = 16, i;
    dv_group *g = (dv_group *)malloc(cap * sizeof(dv_group));
    int flag = 0;
    if (!g)
        return NULL;
    for (i = 0; i < r->count; i++) {
        const dv_frame *f = &r->frames[i];
        int pattern;
        if (n + 2 > cap) {
            dv_group *ng;
            cap *= 2;
            ng = (dv_group *)realloc(g, cap * sizeof(dv_group));
            if (!ng)
                break;
            g = ng;
        }
        if (!n || !group_same(&g[n - 1], f)) {
            group_from_frame(&g[n], f, i);
            n++;
        }
        /* Split when audio source/control packs (re)appear, or DV speed changes */
        pattern = !f->no_pack_aud && f->no_sc_aud;
        if (!flag && pattern && g[n - 1].start == i)
            flag = 1;
        if ((flag && !pattern) || (i && speed_np(r->frames[i - 1].speed) != speed_np(f->speed))) {
            if (g[n - 1].start != i) {
                g[n] = g[n - 1];
                g[n].start = i;
                g[n - 1].audio_rate = 0;
                g[n - 1].channels = 0;
                g[n - 1].bitdepth = 0;
                n++;
            }
            flag = 0;
        }
    }
    *ngroups = n;
    return g;
}

static void write_frame(FILE *out, const dv_frame *f, const char *caption)
{
    char tmp[64];
    int d, s;
    fprintf(out, "\t\t\t<frame n=\"%u\" pos=\"%lld\"", f->index, (long long)f->pos);
    dv_format_ts(tmp, f->pts_ns);
    fprintf(out, " pts=\"%s\"", tmp);
    if (f->abst_valid)
        fprintf(out, " abst=\"%d\"", (int)f->abst);
    if (f->abst_r)
        fputs(" abst_r=\"1\"", out);
    if (f->abst_nc)
        fputs(" abst_nc=\"1\"", out);
    if (f->tc_valid) {
        dv_format_tc(tmp, f);
        fprintf(out, " tc=\"%s\"", tmp);
    }
    if (f->tc_r)
        fputs(" tc_r=\"1\"", out);
    if (f->tc_nc)
        fprintf(out, " tc_nc=\"%d\"", f->tc_nc);
    dv_format_rdt(tmp, f);
    if (tmp[0])
        fprintf(out, " rdt=\"%s\"", tmp);
    if (f->rdt_nc)
        fprintf(out, " rdt_nc=\"%d\"", f->rdt_nc);
    if (f->rec_start)
        fputs(" rec_start=\"1\"", out);
    if (f->rec_end)
        fputs(" rec_end=\"1\"", out);
    if (f->seqn_valid)
        fprintf(out, " seqn=\"%X\"", f->seqn);
    if (f->seqn_r)
        fputs(" seqn_r=\"1\"", out);
    if (f->seqn_nc)
        fprintf(out, " seqn_nc=\"%d\"", f->seqn_nc);
    if (caption)
        fprintf(out, " caption=\"%s\"", caption);
    if (f->caption_parity)
        fputs(" caption-parity=\"mismatch\"", out);
    if (f->no_pack_sub && f->no_pack_vid && f->no_pack_aud)
        fputs(" no_pack=\"1\"", out);
    else {
        if (f->no_pack_vid)
            fputs(" no_pack_vid=\"1\"", out);
        else if (f->no_sc_vid)
            fputs(" no_sourceorcontrol_vid=\"1\"", out);
        if (f->no_pack_aud)
            fputs(" no_pack_aud=\"1\"", out);
        else if (f->no_sc_aud)
            fputs(" no_sourceorcontrol_aud=\"1\"", out);
    }
    if (f->full_conceal_vid && f->full_conceal_aud)
        fputs(" full_conceal=\"1\"", out);
    else {
        if (f->full_conceal_vid)
            fputs(" full_conceal_vid=\"1\"", out);
        if (f->full_conceal_aud) {
            fputs(" full_conceal_aud=\"1\"", out);
            if (f->aud_values_n) {
                /* sorted unique values */
                uint16_t v[DV_MAX_AUD_VALUES];
                int nv = 0, i, j;
                for (i = 0; i < f->aud_values_n; i++) {
                    for (j = 0; j < nv; j++)
                        if (v[j] == f->aud_values[i].value)
                            break;
                    if (j == nv)
                        v[nv++] = f->aud_values[i].value;
                }
                for (i = 1; i < nv; i++)
                    for (j = i; j > 0 && v[j - 1] > v[j]; j--) {
                        uint16_t t = v[j]; v[j] = v[j - 1]; v[j - 1] = t;
                    }
                fputs(" conceal_aud_type=\"2\" conceal_aud_value=\"", out);
                for (i = 0; i < nv; i++)
                    fprintf(out, "%s0x%04X", i ? " " : "", v[i]);
                fputc('"', out);
            }
        }
    }
    if (!(f->full_conceal_vid && f->full_conceal_aud)
        && ((!f->full_conceal_vid && f->sta) || (!f->full_conceal_aud && f->audio_errors))) {
        uint32_t tot[16], even[16], atot = 0, aeven = 0;
        int any = 0;
        memset(tot, 0, sizeof(tot));
        memset(even, 0, sizeof(even));
        fputs(">\n", out);
        for (d = 0; d < 16; d++) {
            int has = 0, k;
            if (f->sta)
                for (s = 0; s < 16; s++)
                    if (f->sta[(d << 4) | s]) has = 1;
            if (f->aud[d])
                has = 1;
            if (!has)
                continue;
            any = 1;
            fprintf(out, "\t\t\t\t<dseq n=\"%d\">\n", d);
            if (f->sta)
                for (s = 0; s < 16; s++) {
                    uint32_t c = f->sta[(d << 4) | s];
                    if (!c)
                        continue;
                    tot[s] += c;
                    if (!(d % 2))
                        even[s] += c;
                    if (!f->full_conceal_vid)
                        fprintf(out, "\t\t\t\t\t<sta t=\"%d\" n=\"%u\"/>\n", s, c);
                }
            if (f->aud[d]) {
                atot += f->aud[d];
                if (!(d % 2))
                    aeven += f->aud[d];
                if (!f->full_conceal_aud) {
                    int first = 1;
                    fprintf(out, "\t\t\t\t\t<aud n=\"%u\"", f->aud[d]);
                    for (k = 0; k < f->aud_values_n; k++)
                        if (f->aud_values[k].dseq == d) {
                            fprintf(out, "%s0x%04X", first ? " t=\"2\" v=\"" : " ", f->aud_values[k].value);
                            first = 0;
                        }
                    if (!first)
                        fputc('"', out);
                    fputs("/>\n", out);
                }
            }
            fputs("\t\t\t\t</dseq>\n", out);
        }
        if (!f->full_conceal_vid)
            for (s = 0; s < 16; s++)
                if (tot[s])
                    fprintf(out, "\t\t\t\t<sta t=\"%d\" n=\"%u\" n_even=\"%u\"/>\n", s, tot[s], even[s]);
        if (!f->full_conceal_aud && atot)
            fprintf(out, "\t\t\t\t<aud n=\"%u\" n_even=\"%u\"/>\n", atot, aeven);
        (void)any;
        fputs("\t\t\t</frame>\n", out);
    } else
        fputs("/>\n", out);
}

static const char *chroma_names[] = { "4:1:1", "4:2:0", "4:2:2" };

static void write_media(FILE *out, dv_report *r)
{
    uint32_t ng = 0, gi, i;
    dv_group *g;
    fputs("\t<media", out);
    if (r->path) {
        fputs(" ref=\"", out);
        xml_escape(out, r->path);
        fputc('"', out);
    }
    if (!r->count) {
        fputs(" error=\"no frame received\"/>\n", out);
        return;
    }
    fprintf(out, " format=\"DV\" size=\"%lld\">\n", (long long)r->file_size);
    if (r->stop_method == 1)
        fputs("\t\t<stop method='timeout'/>\n", out);
    else if (r->stop_method == 2)
        fputs("\t\t<stop method='user'/>\n", out);
    g = compute_groups(r, &ng);
    if (!g)
        return;
    for (gi = 0; gi < ng; gi++) {
        uint32_t start = g[gi].start;
        uint32_t end = gi + 1 < ng ? g[gi + 1].start : r->count; /* exclusive */
        const dv_frame *f0 = &r->frames[start];
        uint64_t end_ns = end < r->count ? r->frames[end].pts_ns
                                         : r->frames[r->count - 1].pts_ns + r->frames[r->count - 1].dur_ns;
        const dv_frame *fend = end < r->count ? &r->frames[end] : &r->frames[r->count - 1];
        char ts[32];
        uint32_t cc = 0;
        int nosc_everywhere = 1;
        for (i = start; i < end; i++) {
            if (r->frames[i].captions)
                cc++;
            if (r->frames[i].no_pack_aud || !r->frames[i].no_sc_aud)
                nosc_everywhere = 0;
        }
        fprintf(out, "\t\t<frames count=\"%u\"", end - start);
        dv_format_ts(ts, f0->pts_ns);
        fprintf(out, " pts=\"%s\"", ts);
        dv_format_ts(ts, end_ns);
        fprintf(out, " end_pts=\"%s\"", ts);
        if (f0->abst_valid)
            fprintf(out, " abst=\"%d\"", (int)f0->abst);
        if (fend->abst_valid)
            fprintf(out, " end_abst=\"%d\"", (int)fend->abst);
        if (g[gi].width && g[gi].height)
            fprintf(out, " size=\"%dx%d\"", g[gi].width, g[gi].height);
        if (g[gi].rate_n) {
            if (g[gi].rate_d && g[gi].rate_d != 1)
                fprintf(out, " video_rate=\"%u/%u\"", g[gi].rate_n, g[gi].rate_d);
            else
                fprintf(out, " video_rate=\"%u\"", g[gi].rate_n);
        }
        if (g[gi].chroma >= 0 && g[gi].chroma < 3)
            fprintf(out, " chroma_subsampling=\"%s\"", chroma_names[(int)g[gi].chroma]);
        if (g[gi].aspect_n)
            fprintf(out, " aspect_ratio=\"%u/%u\"", g[gi].aspect_n, g[gi].aspect_d);
        if (g[gi].audio_rate)
            fprintf(out, " audio_rate=\"%u\"", g[gi].audio_rate);
        if (g[gi].channels)
            fprintf(out, " channels=\"%u\"", g[gi].channels);
        if (g[gi].bitdepth)
            fprintf(out, " audio_bitdepth=\"%u\"", g[gi].bitdepth);
        if (cc && cc == end - start)
            fputs(" captions=\"y\"", out);
        else if (cc)
            fputs(" captions=\"p\"", out);
        if (nosc_everywhere)
            fputs(" no_sourceorcontrol_aud=\"1\"", out);
        if (!dv_speed_is_normal(f0->speed))
            fprintf(out, " speed=\"%d\"", f0->speed);
        fputs(">\n", out);
        for (i = start; i < end; i++) {
            const dv_frame *f = &r->frames[i];
            const char *caption = NULL;
            int show = i == start || i == end - 1 || i == r->count - 1 || dv_frame_has_errors(f);
            if (cc && cc != end - start && i > start && f->captions != r->frames[i - 1].captions)
                caption = f->captions ? "on" : "off";
            if (cc && cc != end - start && i == start && f->captions)
                caption = "on";
            if (caption)
                show = 1;
            if (show)
                write_frame(out, f, caption);
        }
        fputs("\t\t</frames>\n", out);
    }
    free(g);
    fputs("\t</media>\n", out);
}

int dv_report_write_xml(FILE *out, dv_report **reports, int count)
{
    int i;
    fputs("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
          "<dvrescue xmlns=\"https://mediaarea.net/dvrescue\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
          "xsi:schemaLocation=\"https://mediaarea.net/dvrescue https://mediaarea.net/dvrescue/dvrescue.xsd\" version=\"1.2.1\">\n"
          "\t<creator>\n"
          "\t\t<program>OldDV Rescue</program>\n"
          "\t\t<version>" OLDDV_VERSION "</version>\n"
          "\t</creator>\n", out);
    for (i = 0; i < count; i++)
        write_media(out, reports[i]);
    fputs("</dvrescue>\n", out);
    return ferror(out) ? -1 : 0;
}

int dv_report_save_xml(const char *path, dv_report *r)
{
    FILE *fp = fopen(path, "w");
    int ret;
    if (!fp)
        return -1;
    ret = dv_report_write_xml(fp, &r, 1);
    if (fclose(fp))
        ret = -1;
    return ret;
}

/* ------------------------------------------------------------------ */

void dv_report_write_summary(FILE *out, const dv_report *r)
{
    char ts[32], tc0[16], tc1[16], rd[40];
    uint64_t vid = 0, aud = 0;
    uint32_t i;
    if (!r->count) {
        fprintf(out, "%s: no DV frames found\n", r->path ? r->path : "input");
        return;
    }
    for (i = 0; i < r->count; i++) {
        vid += r->frames[i].video_errors;
        aud += r->frames[i].audio_errors;
    }
    dv_format_ts(ts, r->frames[r->count - 1].pts_ns + r->frames[r->count - 1].dur_ns);
    dv_format_tc(tc0, &r->frames[0]);
    dv_format_tc(tc1, &r->frames[r->count - 1]);
    fprintf(out, "File:              %s\n", r->path ? r->path : "");
    fprintf(out, "Frames:            %u (%s)\n", r->count, ts);
    fprintf(out, "Format:            %dx%d %s%s\n", r->frames[0].width, r->frames[0].height,
            r->frames[0].dsf ? "PAL 25 fps" : "NTSC 29.97 fps",
            r->frames[0].aspect_n == 16 ? ", 16:9" : (r->frames[0].aspect_n ? ", 4:3" : ""));
    if (r->frames[0].audio_rate)
        fprintf(out, "Audio:             %u Hz, %u ch, %u bit\n", r->frames[0].audio_rate, r->frames[0].channels, r->frames[0].bitdepth);
    if (tc0[0] || tc1[0])
        fprintf(out, "Time code:         %s -> %s\n", tc0[0] ? tc0 : "none", tc1[0] ? tc1 : "none");
    dv_format_rdt(rd, &r->frames[0]);
    if (rd[0])
        fprintf(out, "First recording:   %s\n", rd);
    fprintf(out, "Frames with issues:%6u\n", r->frames_with_errors);
    fprintf(out, "  video errors:    %6u frames (%llu blocks)\n", r->frames_video_errors, (unsigned long long)vid);
    fprintf(out, "  audio errors:    %6u frames (%llu blocks)\n", r->frames_audio_errors, (unsigned long long)aud);
    fprintf(out, "  fully concealed: %6u frames\n", r->full_conceal);
    fprintf(out, "Time code breaks:  %6u\n", r->tc_breaks);
    fprintf(out, "Rec. date breaks:  %6u\n", r->rdt_breaks);
    fprintf(out, "Recording starts:  %6u\n", r->rec_starts);
}

void dv_report_write_csv(FILE *out, const dv_report *r)
{
    uint32_t i;
    fputs("frame,pos,pts,abst,tc,tc_flag,rdt,rdt_flag,rec_start,seqn,video_error_blocks,video_error_pct,audio_error_blocks,full_conceal\n", out);
    for (i = 0; i < r->count; i++) {
        const dv_frame *f = &r->frames[i];
        char ts[32], tc[16], rd[40];
        if (!dv_frame_has_errors(f) && !f->rec_start && i && i + 1 != r->count)
            continue;
        dv_format_ts(ts, f->pts_ns);
        dv_format_tc(tc, f);
        dv_format_rdt(rd, f);
        fprintf(out, "%u,%lld,%s,", f->index, (long long)f->pos, ts);
        if (f->abst_valid)
            fprintf(out, "%d", (int)f->abst);
        fprintf(out, ",%s,%s,%s,%s,%d,", tc, f->tc_r ? "repeat" : (f->tc_nc ? "jump" : ""), rd,
                f->rdt_nc ? "jump" : "", f->rec_start);
        if (f->seqn_valid)
            fprintf(out, "%X", f->seqn);
        fprintf(out, ",%u,%.1f,%u,%d\n", f->video_errors,
                f->video_blocks ? 100.0 * f->video_errors / f->video_blocks : 0.0,
                f->audio_errors, (f->full_conceal_vid && f->full_conceal_aud) ? 1 : 0);
    }
}
