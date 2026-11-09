/*
 * OldDV Rescue - merge several captures of the same tape.
 *
 * Same idea as DVRescue's merge (--merge): frames of every input are lined
 * up (by absolute track number when available, else by time code), the
 * input with the fewest bad blocks is taken for each frame and its bad DIF
 * blocks are replaced by good blocks from the other inputs.
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

typedef struct mentry {
    int64_t key;
    int32_t input;
    uint32_t frame;
} mentry;

static int mentry_cmp(const void *a, const void *b)
{
    const mentry *x = (const mentry *)a, *y = (const mentry *)b;
    if (x->key != y->key) return x->key < y->key ? -1 : 1;
    if (x->input != y->input) return x->input < y->input ? -1 : 1;
    if (x->frame != y->frame) return x->frame < y->frame ? -1 : 1;
    return 0;
}

static int64_t tc_frames(const dv_frame *f)
{
    int fps = f->dsf ? 25 : 30;
    return ((int64_t)f->tc_h * 3600 + f->tc_m * 60 + f->tc_s) * fps + f->tc_f;
}

static void logf_(dv_log_cb log, void *ctx, const char *fmt, ...)
{
    char line[512];
    va_list ap;
    if (!log)
        return;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    log(ctx, line);
}

typedef struct seg { int64_t first, min, max; int mapped; } seg;

/* Turn raw per-frame positions (time code in frames, or absolute track
 * number) into keys usable for lining up takes: isolated glitches (one
 * frame with a crazy value) are replaced by the predicted value, jumps
 * confirmed by the following frames are kept. ok[] is set to 1 for values
 * that were read from the tape, 0 for predicted ones. */
static int within(int64_t v, int64_t expect, int64_t tol)
{
    return v >= expect - tol && v <= expect + tol;
}

static void smooth_keys(int64_t *val, uint8_t *ok, uint32_t n, int64_t step)
{
    uint32_t j, m;
    int known = 0;
    int64_t last = 0, expect = 0, tol = 2 * step;
    for (j = 0; j < n; j++) {
        int accept = 0;
        if (ok[j]) {
            if (!known || within(val[j], expect, tol) || val[j] == last)
                accept = 1;
            else {
                /* confirmed by at least 2 of the next valid frames? */
                int seen = 0, good = 0;
                for (m = j + 1; m < n && m <= j + 6 && seen < 3; m++) {
                    if (!ok[m])
                        continue;
                    seen++;
                    if (within(val[m], val[j] + (int64_t)(m - j) * step, tol * (int64_t)(m - j)))
                        good++;
                }
                accept = good >= 2 || (seen < 2 && good == seen);
            }
        }
        if (accept) {
            last = val[j];
            expect = val[j] + step;
            known = 1;
        } else {
            ok[j] = 0;
            val[j] = known ? expect : 0;
            if (known) {
                last = expect;
                expect += step;
            }
        }
    }
}

int dv_merge_files(const char **inputs, int n, const char *output,
                   dv_merge_stats *st, dv_log_cb log, dv_progress_cb progress, void *ctx)
{
    dv_report *reps;
    FILE **fps;
    FILE *out;
    mentry *e = NULL;
    size_t ne = 0, total = 0;
    int k, mode = 0, ret = 0;
    uint8_t *best_buf, *cand_buf, *best_st, *cand_st;
    dv_merge_stats dummy;

    if (!st)
        st = &dummy;
    memset(st, 0, sizeof(*st));
    if (n < 1)
        return -1;
    reps = (dv_report *)calloc((size_t)n, sizeof(dv_report));
    fps = (FILE **)calloc((size_t)n, sizeof(FILE *));
    best_buf = (uint8_t *)malloc(DV_MAX_FRAME * 4);
    cand_buf = (uint8_t *)malloc(DV_MAX_FRAME * 4);
    best_st = (uint8_t *)malloc(DV_MAX_BLOCKS * 4);
    cand_st = (uint8_t *)malloc(DV_MAX_BLOCKS * 4);
    if (!reps || !fps || !best_buf || !cand_buf || !best_st || !cand_st) {
        ret = -1;
        goto done;
    }

    /* Pass 1: analyze all inputs */
    for (k = 0; k < n; k++) {
        dv_report_init(&reps[k], inputs[k]);
        logf_(log, ctx, "Analyzing input %d: %s", k + 1, inputs[k]);
        if (dv_analyze_file(inputs[k], &reps[k], NULL, NULL) < 0) {
            logf_(log, ctx, "Error: cannot read %s", inputs[k]);
            ret = -1;
            goto done;
        }
        logf_(log, ctx, "  %u frames, %u with issues", reps[k].count, reps[k].frames_with_errors);
        total += reps[k].count;
        if (progress && progress(ctx, 0.3 * (k + 1) / n)) { ret = 1; goto done; }
    }

    /* Choose how to line up frames */
    {
        int all_abst = 1, all_tc = 1;
        for (k = 0; k < n; k++) {
            uint32_t a = 0, t = 0, j;
            for (j = 0; j < reps[k].count; j++) {
                a += reps[k].frames[j].abst_valid;
                t += reps[k].frames[j].tc_valid;
            }
            if (!reps[k].count || a < reps[k].count * 9 / 10) all_abst = 0;
            if (!reps[k].count || t < reps[k].count * 9 / 10) all_tc = 0;
        }
        mode = all_abst ? 1 : (all_tc ? 0 : 2);
        if (n == 1)
            mode = 2;
        st->key_mode = mode;
        logf_(log, ctx, "Lining up frames by %s", mode == 1 ? "absolute track number" : (mode == 0 ? "time code" : "frame position"));
    }

    e = (mentry *)malloc((total ? total : 1) * sizeof(mentry));
    if (!e) { ret = -1; goto done; }

    {
        seg *seg0 = NULL;
        int nseg0 = 0;
        for (k = 0; k < n; k++) {
            dv_report *r = &reps[k];
            uint32_t cnt = r->count, j;
            int64_t *val = (int64_t *)malloc((cnt + 1) * sizeof(int64_t));
            uint8_t *ok = (uint8_t *)malloc(cnt + 1);
            int64_t step = 1;
            seg *segs = NULL;
            int nseg = 0, cur_seg = -1, last_mapped = 0;
            if (!val || !ok) { free(val); free(ok); ret = -1; goto done; }
            for (j = 0; j < cnt; j++) {
                const dv_frame *f = &r->frames[j];
                ok[j] = mode == 1 ? f->abst_valid : (mode == 0 ? f->tc_valid : 1);
                val[j] = mode == 1 ? f->abst : (mode == 0 ? tc_frames(f) : (int64_t)j);
            }
            if (mode == 1) {
                /* tracks per frame: most common positive difference */
                int64_t cands[3] = { 10, 12, 15 };
                int votes[3] = { 0, 0, 0 }, c, b = 0;
                for (j = 1; j < cnt; j++)
                    if (ok[j] && ok[j - 1])
                        for (c = 0; c < 3; c++)
                            if (val[j] - val[j - 1] == cands[c]) votes[c]++;
                for (c = 1; c < 3; c++)
                    if (votes[c] > votes[b]) b = c;
                step = votes[b] ? cands[b] : (cnt && r->frames[0].dsf ? 12 : 10);
            }
            smooth_keys(val, ok, cnt, step);
            if (mode == 0) {
                /* time code segments: a new one at each confirmed backward jump */
                int64_t last = 0;
                segs = (seg *)malloc((cnt + 1) * sizeof(seg));
                if (!segs) { free(val); free(ok); ret = -1; goto done; }
                for (j = 0; j < cnt; j++) {
                    if (!ok[j])
                        continue;
                    if (cur_seg < 0 || val[j] < last) {
                        cur_seg = nseg++;
                        segs[cur_seg].first = segs[cur_seg].min = segs[cur_seg].max = val[j];
                    }
                    if (val[j] < segs[cur_seg].min) segs[cur_seg].min = val[j];
                    if (val[j] > segs[cur_seg].max) segs[cur_seg].max = val[j];
                    last = val[j];
                }
                if (k == 0) {
                    for (j = 0; j < (uint32_t)nseg; j++)
                        segs[j].mapped = (int)j;
                    seg0 = segs;
                    nseg0 = nseg;
                } else {
                    for (j = 0; j < (uint32_t)nseg; j++) {
                        int s2, found = -1;
                        for (s2 = last_mapped; s2 < nseg0 && found < 0; s2++)
                            if (segs[j].first >= seg0[s2].min && segs[j].first <= seg0[s2].max) found = s2;
                        for (s2 = 0; s2 < nseg0 && found < 0; s2++)
                            if (segs[j].first >= seg0[s2].min && segs[j].first <= seg0[s2].max) found = s2;
                        if (found < 0)
                            found = last_mapped;
                        segs[j].mapped = found;
                        last_mapped = found;
                    }
                }
                /* apply segment numbers */
                {
                    int64_t lastv = 0;
                    cur_seg = -1;
                    for (j = 0; j < cnt; j++) {
                        if (ok[j]) {
                            if (cur_seg < 0 || val[j] < lastv)
                                cur_seg++;
                            lastv = val[j];
                        }
                        val[j] += (int64_t)(cur_seg < 0 ? 0 : segs[cur_seg].mapped) << 32;
                    }
                }
            }
            for (j = 0; j < cnt; j++) {
                e[ne].key = val[j];
                e[ne].input = k;
                e[ne].frame = j;
                ne++;
            }
            if (segs && k)
                free(segs);
            free(val);
            free(ok);
        }
        free(seg0);
    }
    qsort(e, ne, sizeof(mentry), mentry_cmp);

    for (k = 0; k < n; k++) {
        fps[k] = fopen(inputs[k], "rb");
        if (!fps[k]) { ret = -1; goto done; }
    }
    out = fopen(output, "wb");
    if (!out) {
        logf_(log, ctx, "Error: cannot write %s", output);
        ret = -1;
        goto done;
    }

    /* Pass 2: one output frame per key */
    {
        size_t g = 0;
        int64_t last_key = 0;
        int have_last = 0;
        while (g < ne) {
            size_t h = g, c, best = (size_t)-1;
            const dv_frame *bf;
            uint32_t remaining = 0, fixed = 0;
            while (h < ne && e[h].key == e[g].key)
                h++;
            /* missing frames (time code mode, same segment) */
            if (have_last && mode == 0 && (e[g].key >> 32) == (last_key >> 32) && e[g].key > last_key + 1)
                st->frames_missing += (uint32_t)(e[g].key - last_key - 1);
            if (have_last && mode == 1 && e[g].key > last_key + 2 * ((reps[0].count && reps[0].frames[0].dsf) ? 12 : 10))
                st->frames_missing++;
            last_key = e[g].key;
            have_last = 1;

            for (c = g; c < h; c++) {
                const dv_frame *f = &reps[e[c].input].frames[e[c].frame];
                if (best == (size_t)-1) { best = c; continue; }
                bf = &reps[e[best].input].frames[e[best].frame];
                {
                    int fc_f = f->full_conceal_vid, fc_b = bf->full_conceal_vid;
                    if ((fc_b && !fc_f) || (fc_b == fc_f && dv_frame_error_blocks(f) < dv_frame_error_blocks(bf)))
                        best = c;
                }
            }
            bf = &reps[e[best].input].frames[e[best].frame];
            if (bf->size > DV_MAX_FRAME * 4 || fseeko(fps[e[best].input], bf->pos, SEEK_SET)
                || fread(best_buf, 1, bf->size, fps[e[best].input]) != bf->size) {
                logf_(log, ctx, "Error: read issue in %s", inputs[e[best].input]);
                ret = -1;
                break;
            }
            if (dv_frame_error_blocks(bf) && h - g > 1) {
                int qu = bf->bitdepth == 12 ? 1 : (bf->bitdepth == 16 ? 0 : -1);
                uint32_t nb = bf->size / DV_BLOCK_SIZE, b;
                dv_block_status(best_buf, bf->size, qu, best_st);
                for (c = g; c < h; c++) {
                    const dv_frame *f = &reps[e[c].input].frames[e[c].frame];
                    if (c == best || f->size != bf->size)
                        continue;
                    if (fseeko(fps[e[c].input], f->pos, SEEK_SET) || fread(cand_buf, 1, f->size, fps[e[c].input]) != f->size)
                        continue;
                    dv_block_status(cand_buf, f->size, qu, cand_st);
                    for (b = 0; b < nb; b++) {
                        if (best_st[b] == DV_BS_NOK && cand_st[b] == DV_BS_OK
                            && !memcmp(best_buf + b * DV_BLOCK_SIZE, cand_buf + b * DV_BLOCK_SIZE, 3)) {
                            memcpy(best_buf + b * DV_BLOCK_SIZE, cand_buf + b * DV_BLOCK_SIZE, DV_BLOCK_SIZE);
                            best_st[b] = DV_BS_OK;
                            fixed++;
                        }
                    }
                }
                for (b = 0; b < nb; b++)
                    if (best_st[b] == DV_BS_NOK)
                        remaining++;
            } else
                remaining = dv_frame_error_blocks(bf);

            if (fwrite(best_buf, 1, bf->size, out) != bf->size) {
                logf_(log, ctx, "Error: write failed (disk full?)");
                ret = -1;
                break;
            }
            st->frames_out++;
            st->blocks_fixed += fixed;
            st->blocks_remaining += remaining;
            if (!dv_frame_error_blocks(bf))
                st->frames_ok++;
            else if (!remaining)
                st->frames_repaired++;
            else
                st->frames_still_bad++;
            if (dv_frame_error_blocks(bf)) {
                char tc[16];
                dv_format_tc(tc, bf);
                logf_(log, ctx, "frame %6u %-11s input %d of %d copies: %4u bad blocks, %4u fixed from other takes, %4u remaining",
                      st->frames_out - 1, tc[0] ? tc : "--", e[best].input + 1, (int)(h - g),
                      dv_frame_error_blocks(bf), fixed, remaining);
            }
            if (progress && (st->frames_out % 100) == 0 && progress(ctx, 0.3 + 0.7 * (double)h / (double)ne)) {
                ret = 1;
                break;
            }
            g = h;
        }
    }
    if (fclose(out))
        ret = -1;
    if (progress)
        progress(ctx, 1.0);
    logf_(log, ctx, "Merge result: %u frames written, %u clean, %u repaired, %u still with errors",
          st->frames_out, st->frames_ok, st->frames_repaired, st->frames_still_bad);
    logf_(log, ctx, "Blocks fixed: %u, remaining bad blocks: %u, frames missing in all inputs: %u",
          st->blocks_fixed, st->blocks_remaining, st->frames_missing);

done:
    if (reps)
        for (k = 0; k < n; k++)
            dv_report_free(&reps[k]);
    if (fps)
        for (k = 0; k < n; k++)
            if (fps[k]) fclose(fps[k]);
    free(reps);
    free(fps);
    free(e);
    free(best_buf);
    free(cand_buf);
    free(best_st);
    free(cand_st);
    return ret;
}
