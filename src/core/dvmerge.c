/*
 * OldDV Rescue - merge several captures of the same tape.
 *
 * Same idea as DVRescue's merge (--merge): the frames of every input are
 * lined up, the input with the fewest bad blocks is taken for each frame
 * and its bad DIF blocks are replaced by good blocks from the other inputs.
 *
 * The first input is the timeline: the output has its frames, in its
 * order. The frames of the other inputs are attached to it by following
 * the sequence, and by looking up (absolute track number, time code) after
 * a jump. Neither value is unique on a real tape: time code restarts after
 * a blank section, and some camcorders restart the absolute track number
 * at every recording. So they are never used to sort the frames, only to
 * find where a run of frames belongs. Frames that exist only in a later
 * input (dropped in the first one) are inserted where they belong.
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

/* one copy of a tape frame: frame 'frame' of input 'input' */
typedef struct mcopy {
    int32_t input;
    uint32_t frame;
    int32_t next;      /* next copy of the same slot, -1 = end */
} mcopy;

/* one output frame */
typedef struct mslot {
    int64_t key;       /* (abst, tc) of the frame that created the slot */
    int32_t abst;      /* -1 = unknown */
    int32_t tc;        /* -1 = unknown */
    int32_t first, last; /* copies */
    int32_t after;     /* insertion: index of the slot it follows (-1: start) */
    uint32_t seq;
} mslot;

typedef struct mkey { int64_t key; int32_t slot; } mkey;

static int mkey_cmp(const void *a, const void *b)
{
    const mkey *x = (const mkey *)a, *y = (const mkey *)b;
    if (x->key != y->key) return x->key < y->key ? -1 : 1;
    return x->slot < y->slot ? -1 : (x->slot > y->slot);
}

static int mslot_ins_cmp(const void *a, const void *b)
{
    const mslot *x = (const mslot *)a, *y = (const mslot *)b;
    if (x->after != y->after) return x->after < y->after ? -1 : 1;
    return x->seq < y->seq ? -1 : (x->seq > y->seq);
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
                accept = good >= 2 || (seen == 1 && good == 1);
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

typedef struct mctx {
    int use_abst, use_tc;
    int32_t **pa, **pt;    /* per input, per frame: smoothed abst / tc, -1 = unknown */
    mslot *T; size_t nT, capT;
    mcopy *C; size_t nC;
    mkey *K; size_t nK;
} mctx;

/* position of a frame: abst / tc (-1 when unknown or unused), and the
 * combined key (-1 unless every used value is known) */
static void frame_pos(const mctx *m, int k, uint32_t index, int32_t *abst, int32_t *tc, int64_t *key)
{
    if (!m->use_abst && !m->use_tc) { /* no position on the tape: frame number */
        *abst = *tc = -1;
        *key = (int64_t)index;
        return;
    }
    *abst = m->use_abst ? m->pa[k][index] : -1;
    *tc = m->use_tc ? m->pt[k][index] : -1;
    if ((m->use_abst && *abst < 0) || (m->use_tc && *tc < 0))
        *key = -1;
    else
        *key = ((int64_t)(m->use_abst ? *abst : 0) << 28) | (int64_t)(m->use_tc ? *tc : 0);
}

static int32_t add_copy(mctx *m, mslot *sl, int32_t input, uint32_t frame)
{
    int32_t c = (int32_t)m->nC++;
    m->C[c].input = input;
    m->C[c].frame = frame;
    m->C[c].next = -1;
    if (sl->first < 0)
        sl->first = c;
    else
        m->C[sl->last].next = c;
    sl->last = c;
    return c;
}

static void rebuild_keys(mctx *m)
{
    size_t i;
    m->nK = 0;
    for (i = 0; i < m->nT; i++)
        if (m->T[i].key >= 0) {
            m->K[m->nK].key = m->T[i].key;
            m->K[m->nK].slot = (int32_t)i;
            m->nK++;
        }
    qsort(m->K, m->nK, sizeof(mkey), mkey_cmp);
}

/* slot with this key: the first one after 'cur', else the last one before */
static int32_t find_slot(const mctx *m, int64_t key, int32_t cur)
{
    size_t lo = 0, hi = m->nK;
    int32_t before = -1;
    if (key < 0)
        return -1;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (m->K[mid].key < key) lo = mid + 1; else hi = mid;
    }
    for (; lo < m->nK && m->K[lo].key == key; lo++) {
        if (m->K[lo].slot > cur)
            return m->K[lo].slot;
        before = m->K[lo].slot;
    }
    return before;
}

/* do the frames after j continue from slot 'at' (frame j being at 'at')? */
static int confirmed(const mctx *m, const dv_report *r, int k, uint32_t j, int32_t at, int need_two)
{
    uint32_t q;
    int seen = 0, good = 0;
    for (q = j + 1; q < r->count && q <= j + 8 && seen < 3; q++) {
        int32_t a, t, d;
        int64_t key;
        frame_pos(m, k, q, &a, &t, &key);
        if (key < 0)
            continue;
        seen++;
        /* a jump may land a frame or two off; a damaged position must be
         * followed by exactly the next slots */
        for (d = need_two ? 0 : -2; d <= (need_two ? 0 : 2); d++) {
            int64_t p = (int64_t)at + (int64_t)(q - j) + d;
            if (p >= 0 && p < (int64_t)m->nT && m->T[p].key == key) { good++; break; }
        }
    }
    if (need_two)
        return good >= 2 || (seen == 1 && good == 1);
    return good >= 1 || seen == 0;
}

/* Positions are not unique on a tape (time code restarts, and so can the
 * absolute track number), so a match close to where we are wins over one
 * far away: a few frames missing in one input must not be taken for a
 * jump to another part of the tape that has the same time codes. */
#define MERGE_NEAR 16

static int is_near(int32_t slot, int32_t cur)
{
    return slot > cur && slot <= cur + MERGE_NEAR;
}

/* does one of the frames after j belong just after 'cur'? */
static int resyncs_near(const mctx *m, const dv_report *r, int k, uint32_t j, int32_t cur)
{
    uint32_t q;
    for (q = j + 1; q < r->count && q <= j + 8; q++) {
        int32_t a, t;
        int64_t key;
        frame_pos(m, k, q, &a, &t, &key);
        if (key >= 0 && is_near(find_slot(m, key, cur), cur))
            return 1;
    }
    return 0;
}

/* attach the frames of input k to the timeline */
static int align_input(mctx *m, const dv_report *r, int32_t k)
{
    mslot *ins = (mslot *)malloc((r->count + 1) * sizeof(mslot));
    size_t nins = 0, lead = 0, i, o, a;
    int32_t cur = -1;      /* slot of the previous frame */
    int in_ins = 0;        /* previous frame went to ins[nins - 1] */
    int synced = 0;
    uint32_t j, seq = 0;
    mslot *N;
    if (!ins)
        return -1;
    rebuild_keys(m);
    for (j = 0; j < r->count; j++) {
        int32_t abst, tc, hit = -1, pred;
        int64_t key;
        frame_pos(m, k, j, &abst, &tc, &key);
        pred = (synced && cur + 1 < (int32_t)m->nT) ? cur + 1 : -1;
        if (key >= 0 && in_ins && ins[nins - 1].key == key) {
            add_copy(m, &ins[nins - 1], k, j);          /* repeated frame */
            continue;
        }
        if (key >= 0 && synced && !in_ins && cur >= 0 && m->T[cur].key == key)
            hit = cur;                                   /* repeated frame */
        else if (key >= 0 && pred >= 0 && m->T[pred].key == key)
            hit = pred;                                  /* next frame */
        else {
            int32_t cand = find_slot(m, key, cur);
            if (cand >= 0 && synced && !is_near(cand, cur) && resyncs_near(m, r, k, j, cur))
                cand = -1;                               /* same position elsewhere on the tape */
            if (cand >= 0 && confirmed(m, r, k, j, cand, 0))
                hit = cand;                              /* jump, or first frame */
            else if (pred >= 0 && ((abst >= 0 && m->T[pred].abst == abst) || (tc >= 0 && m->T[pred].tc == tc)))
                hit = pred;                              /* one of the two values is damaged */
            else if (pred >= 0 && confirmed(m, r, k, j, pred, 1))
                hit = pred;                              /* damaged position, sequence goes on */
        }
        if (hit >= 0) {
            add_copy(m, &m->T[hit], k, j);
            if (!synced)                                 /* frames before the first match go just before it */
                for (i = 0; i < lead; i++)
                    ins[i].after = hit - 1;
            cur = hit;
            synced = 1;
            in_ins = 0;
        } else if (r->frames[j].full_conceal_vid) {
            /* no picture and no place on the timeline: nothing to add */
            in_ins = 0;
        } else {
            mslot *sl = &ins[nins++];
            sl->key = key; sl->abst = abst; sl->tc = tc;
            sl->first = sl->last = -1;
            sl->after = synced ? cur : 0x7FFFFFFF;
            sl->seq = seq++;
            add_copy(m, sl, k, j);
            if (!synced)
                lead = nins;
            in_ins = 1;
        }
    }
    if (!nins) {
        free(ins);
        return 0;
    }
    /* merge the new slots into the timeline */
    qsort(ins, nins, sizeof(mslot), mslot_ins_cmp);
    N = (mslot *)malloc((m->nT + nins) * sizeof(mslot));
    if (!N) { free(ins); return -1; }
    o = 0; a = 0;
    while (a < nins && ins[a].after < 0)
        N[o++] = ins[a++];
    for (i = 0; i < m->nT; i++) {
        N[o++] = m->T[i];
        while (a < nins && ins[a].after == (int32_t)i)
            N[o++] = ins[a++];
    }
    while (a < nins)
        N[o++] = ins[a++];
    free(ins);
    free(m->T);
    m->T = N;
    m->nT = o;
    return 0;
}

int dv_merge_files(const char **inputs, int n, const char *output,
                   dv_merge_stats *st, dv_log_cb log, dv_progress_cb progress, void *ctx)
{
    dv_report *reps;
    FILE **fps;
    FILE *out;
    mctx m;
    size_t total = 0;
    int k, ret = 0;
    uint8_t *best_buf, *cand_buf, *best_st, *cand_st;
    dv_merge_stats dummy;

    if (!st)
        st = &dummy;
    memset(st, 0, sizeof(*st));
    memset(&m, 0, sizeof(m));
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
        /* a capture that was cut off (crash, power cut) ends in a part of a
         * frame: it must not get into the output */
        while (reps[k].count) {
            dv_frame *lf = &reps[k].frames[reps[k].count - 1];
            if (lf->size >= (lf->dsf ? 144000u : 120000u))
                break;
            logf_(log, ctx, "  the last frame is incomplete (%u bytes, interrupted capture?): ignored", lf->size);
            free(lf->sta);
            lf->sta = NULL;
            reps[k].count--;
        }
        logf_(log, ctx, "  %u frames, %u with issues", reps[k].count, reps[k].frames_with_errors);
        total += reps[k].count;
        if (progress && progress(ctx, 0.3 * (k + 1) / n)) { ret = 1; goto done; }
    }

    /* Choose what identifies a frame on the tape */
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
        if (n == 1)
            all_abst = all_tc = 0;
        m.use_abst = all_abst;
        m.use_tc = all_tc;
        st->key_mode = all_abst ? 1 : (all_tc ? 0 : 2);
        logf_(log, ctx, "Lining up frames by %s", all_abst && all_tc ? "absolute track number and time code"
              : (all_abst ? "absolute track number" : (all_tc ? "time code" : "frame position")));
    }

    /* positions of all frames; isolated glitches are replaced by the value
     * predicted from the frames around */
    m.pa = (int32_t **)calloc((size_t)n, sizeof(int32_t *));
    m.pt = (int32_t **)calloc((size_t)n, sizeof(int32_t *));
    if (!m.pa || !m.pt) { ret = -1; goto done; }
    for (k = 0; k < n; k++) {
        dv_report *r = &reps[k];
        uint32_t cnt = r->count, j;
        int pass;
        int64_t *val = (int64_t *)malloc((cnt + 1) * sizeof(int64_t));
        uint8_t *ok = (uint8_t *)malloc(cnt + 1);
        m.pa[k] = (int32_t *)malloc((cnt + 1) * sizeof(int32_t));
        m.pt[k] = (int32_t *)malloc((cnt + 1) * sizeof(int32_t));
        if (!val || !ok || !m.pa[k] || !m.pt[k]) { free(val); free(ok); ret = -1; goto done; }
        for (pass = 0; pass < 2; pass++) { /* 0: abst, 1: tc */
            int64_t step = 1;
            int32_t *dst = pass ? m.pt[k] : m.pa[k];
            int known = 0;
            for (j = 0; j < cnt; j++) {
                const dv_frame *f = &r->frames[j];
                ok[j] = pass ? f->tc_valid : f->abst_valid;
                val[j] = pass ? tc_frames(f) : (int64_t)f->abst;
            }
            if (!pass) {
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
            for (j = 0; j < cnt; j++) {
                if (ok[j])
                    known = 1;
                dst[j] = (known && val[j] >= 0 && val[j] < 0x0FFFFFFF) ? (int32_t)val[j] : -1;
            }
        }
        free(val);
        free(ok);
    }

    m.T = (mslot *)malloc((reps[0].count + 1) * sizeof(mslot));
    m.C = (mcopy *)malloc((total ? total : 1) * sizeof(mcopy));
    m.K = (mkey *)malloc((total ? total : 1) * sizeof(mkey));
    if (!m.T || !m.C || !m.K) { ret = -1; goto done; }

    /* the first input is the timeline; a frame repeated by the deck (same
     * position as the frame before) is one slot */
    {
        uint32_t j;
        for (j = 0; j < reps[0].count; j++) {
            int32_t abst, tc;
            int64_t key;
            mslot *sl;
            frame_pos(&m, 0, j, &abst, &tc, &key);
            if (n > 1 && m.nT && key >= 0 && m.T[m.nT - 1].key == key) {
                add_copy(&m, &m.T[m.nT - 1], 0, j);
                continue;
            }
            sl = &m.T[m.nT++];
            sl->key = key; sl->abst = abst; sl->tc = tc;
            sl->first = sl->last = -1;
            sl->after = 0; sl->seq = 0;
            add_copy(&m, sl, 0, j);
        }
    }
    for (k = 1; k < n; k++) {
        size_t before = m.nT;
        if (align_input(&m, &reps[k], k) < 0) { ret = -1; goto done; }
        if (m.nT > before)
            logf_(log, ctx, "Input %d has %lu frame(s) that are in no earlier input", k + 1, (unsigned long)(m.nT - before));
    }

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

#define FRAME_SHORT(f) ((f)->size < ((f)->dsf ? 144000u : 120000u))
    /* Pass 2: one output frame per slot */
    {
        size_t g;
        int32_t last_tc = -1;
        for (g = 0; g < m.nT; g++) {
            int32_t c, best = -1, copies = 0;
            const dv_frame *bf;
            uint32_t remaining = 0, fixed = 0;

            for (c = m.T[g].first; c >= 0; c = m.C[c].next) {
                const dv_frame *f = &reps[m.C[c].input].frames[m.C[c].frame];
                copies++;
                if (best < 0) { best = c; continue; }
                bf = &reps[m.C[best].input].frames[m.C[best].frame];
                {
                    int fc_f = f->full_conceal_vid, fc_b = bf->full_conceal_vid;
                    int sh_f = FRAME_SHORT(f), sh_b = FRAME_SHORT(bf);
                    if (sh_f != sh_b) {
                        if (sh_b)
                            best = c;
                    } else if ((fc_b && !fc_f) || (fc_b == fc_f && dv_frame_error_blocks(f) < dv_frame_error_blocks(bf)))
                        best = c;
                }
            }
            bf = &reps[m.C[best].input].frames[m.C[best].frame];
            /* a part of a frame (data lost during the capture) would shift
             * everything after it in the output: leave it out */
            if (FRAME_SHORT(bf)) {
                logf_(log, ctx, "frame %6u: only an incomplete copy (%u bytes): left out", (unsigned)g, bf->size);
                st->frames_missing++;
                continue;
            }
            /* frames missing in every input: small forward steps of the time code */
            if (bf->tc_valid) {
                int32_t t = (int32_t)tc_frames(bf);
                if (last_tc >= 0 && t > last_tc + 1 && t <= last_tc + 250)
                    st->frames_missing += (uint32_t)(t - last_tc - 1);
                last_tc = t;
            }
            if (bf->size > DV_MAX_FRAME * 4 || fseeko(fps[m.C[best].input], bf->pos, SEEK_SET)
                || fread(best_buf, 1, bf->size, fps[m.C[best].input]) != bf->size) {
                logf_(log, ctx, "Error: read issue in %s", inputs[m.C[best].input]);
                ret = -1;
                break;
            }
            if (dv_frame_error_blocks(bf) && copies > 1) {
                int qu = bf->bitdepth == 12 ? 1 : (bf->bitdepth == 16 ? 0 : -1);
                uint32_t nb = bf->size / DV_BLOCK_SIZE, b;
                dv_block_status(best_buf, bf->size, qu, best_st);
                for (c = m.T[g].first; c >= 0; c = m.C[c].next) {
                    const dv_frame *f = &reps[m.C[c].input].frames[m.C[c].frame];
                    if (c == best || f->size != bf->size)
                        continue;
                    if (fseeko(fps[m.C[c].input], f->pos, SEEK_SET) || fread(cand_buf, 1, f->size, fps[m.C[c].input]) != f->size)
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
                      st->frames_out - 1, tc[0] ? tc : "--", m.C[best].input + 1, (int)copies,
                      dv_frame_error_blocks(bf), fixed, remaining);
            }
            if (progress && (st->frames_out % 100) == 0 && progress(ctx, 0.3 + 0.7 * (double)(g + 1) / (double)m.nT)) {
                ret = 1;
                break;
            }
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
    if (m.pa)
        for (k = 0; k < n; k++) free(m.pa[k]);
    if (m.pt)
        for (k = 0; k < n; k++) free(m.pt[k]);
    free(m.pa);
    free(m.pt);
    free(m.T);
    free(m.C);
    free(m.K);
    free(best_buf);
    free(cand_buf);
    free(best_st);
    free(cand_st);
    return ret;
}
