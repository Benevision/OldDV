/*
 * OldDV Rescue - per frame DV DIF analysis.
 * Re-implementation of the DV analysis used by DVRescue (MediaInfoLib
 * File_DvDif_Analysis). See NOTICE.md.
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>

#define BCD2(b, hi_mask) ((((b) & (hi_mask)) >> 4) * 10 + ((b) & 0x0F))

void dv_analyzer_init(dv_analyzer *a, int keep_block_status)
{
    memset(a, 0, sizeof(*a));
    a->keep_block_status = keep_block_status;
    a->stype = -1;
    a->aspect = -1;
    a->smp = -1;
    a->qu = -1;
}

void dv_frame_free(dv_frame *f)
{
    if (!f)
        return;
    free(f->sta);
    f->sta = NULL;
    free(f->block_status);
    f->block_status = NULL;
}

int dv_speed_is_normal(int speed)
{
    return speed == 31 || speed == 32 || speed == DV_SPEED_UNKNOWN;
}

int dv_frame_has_errors(const dv_frame *f)
{
    return f->video_errors || f->audio_errors || f->tc_nc || f->tc_r
        || f->rdt_nc || f->seqn_nc || f->abst_nc || f->abst_r;
}

int dv_is_frame_start(const uint8_t *b)
{
    /* SCT=0 (header), Dseq=0, DBN=0, FSC=0, FSP=1, not a NULL block */
    if ((b[0] & 0xE0) != 0x00)
        return 0;
    if (b[0] == 0 && b[1] == 0 && b[2] == 0)
        return 0;
    return (b[1] & 0xF0) == 0 && b[2] == 0 && (b[1] & 0x08) == 0 && (b[1] & 0x04);
}

/* ------------------------------------------------------------------ */
/* Time helpers                                                        */

static int tc_pack(int h, int m, int s, int f) { return (h << 24) | (m << 16) | (s << 8) | f; }

static int tc_next(int tc, int frames_max, int df)
{
    int h = (tc >> 24) & 0xFF, m = (tc >> 16) & 0xFF, s = (tc >> 8) & 0xFF, f = tc & 0xFF;
    f++;
    if (f >= frames_max) {
        f = 0;
        s++;
        if (s >= 60) {
            s = 0;
            m++;
            if (df && (m % 10))
                f = 2; /* frames 0 and 1 dropped except every 10 minutes */
            if (m >= 60) {
                m = 0;
                h++;
                if (h >= 24)
                    h = 0;
            }
        }
    }
    return tc_pack(h, m, s, f);
}

static int rt_next(int rt) /* seconds resolution, packed h<<16|m<<8|s */
{
    int h = (rt >> 16) & 0xFF, m = (rt >> 8) & 0xFF, s = rt & 0xFF;
    s++;
    if (s >= 60) {
        s = 0;
        m++;
        if (m >= 60) {
            m = 0;
            h++;
            if (h >= 24)
                h = 0;
        }
    }
    return (h << 16) | (m << 8) | s;
}

/* ------------------------------------------------------------------ */

static int audio_block_error(const uint8_t *b, int qu, uint16_t *value)
{
    int c16 = 1, c12 = 1, i;
    for (i = 10; i < 80; i += 2)
        if (b[i] != b[8] || b[i + 1] != b[9]) { c16 = 0; break; }
    for (i = 11; i < 80; i += 3)
        if (b[i] != b[8] || b[i + 1] != b[9] || b[i + 2] != b[10]) { c12 = 0; break; }
    if ((qu == 0 && c16) || (qu == 1 && c12) || (qu < 0 && (c16 || c12))) {
        int is16 = qu < 0 ? c16 : qu == 0;
        uint16_t v = is16 ? (uint16_t)((b[8] << 8) | b[9]) : (uint16_t)((b[8] << 4) | (b[9] >> 4));
        if (v && v != (is16 ? 0xFFFF : 0x0FFF)) {
            *value = v;
            return 1;
        }
    }
    return 0;
}

uint32_t dv_block_status(const uint8_t *data, size_t size, int qu, uint8_t *status)
{
    size_t n = size / DV_BLOCK_SIZE, i;
    uint32_t nok = 0;
    for (i = 0; i < n; i++) {
        const uint8_t *b = data + i * DV_BLOCK_SIZE;
        uint16_t v;
        switch (b[0] & 0xE0) {
        case 0x60:
            status[i] = audio_block_error(b, qu, &v) ? DV_BS_NOK : DV_BS_OK;
            break;
        case 0x80:
            status[i] = (b[3] & 0xF0) ? DV_BS_NOK : DV_BS_OK;
            break;
        default:
            status[i] = DV_BS_UNKNOWN;
        }
        if (status[i] == DV_BS_NOK)
            nok++;
    }
    return nok;
}

/* ------------------------------------------------------------------ */

typedef struct abst_cand { int32_t value; int count; } abst_cand;

static void abst_add(abst_cand *c, int *n, int32_t v, int weight)
{
    int i;
    for (i = 0; i < *n; i++)
        if (c[i].value == v) { c[i].count += weight; return; }
    if (*n < 64) {
        c[*n].value = v;
        c[*n].count = weight;
        (*n)++;
    }
}

int dv_analyze_frame(dv_analyzer *a, const uint8_t *data, size_t size, int64_t pos, dv_frame *f)
{
    size_t nblocks = size / DV_BLOCK_SIZE, bi;
    int fsc_set = 0, fsc_not_set = 0;
    int tc_valid = 0, tc_h = 0, tc_m = 0, tc_s = 0, tc_f = 0, tc_df = 0;
    int rd_valid = 0, rd_y = 0, rd_mo = 0, rd_d = 0;
    int rt_valid = 0, rt_h = 0, rt_m = 0, rt_s = 0, rt_f = 0x3F;
    int arb_counters[16];
    int arb_any = 0;
    int pack_sub = 0, pack_vid = 0, pack_aud = 0;
    int vsrc = 0, vctl = 0, asrc = 0, actl = 0;
    int rec_valid = 0, rec_st = 1, rec_end = 1;
    int speed = DV_SPEED_UNKNOWN;
    int captions = 0, cc_parity = 0;
    int groups_this_frame = 0;
    uint16_t sta[DV_MAX_DSEQ * DV_STA_VALUES];
    int any_sta = 0;
    abst_cand cands[2][64], weak[2][64];
    int ncands[2] = { 0, 0 }, nweak[2] = { 0, 0 };
    int frames_max;

    memset(f, 0, sizeof(*f));
    memset(arb_counters, 0, sizeof(arb_counters));
    memset(sta, 0, sizeof(sta));
    f->index = a->frame_count;
    f->pos = pos;
    f->size = (uint32_t)size;
    f->speed = DV_SPEED_UNKNOWN;
    f->rt_f = 0x3F;
    if (a->keep_block_status && nblocks) {
        f->block_status = (uint8_t *)calloc(nblocks, 1);
        f->block_count = (uint32_t)nblocks;
    }

    for (bi = 0; bi < nblocks; bi++) {
        const uint8_t *b = data + bi * DV_BLOCK_SIZE;
        int dseq = b[1] >> 4;
        int fsc = (b[1] & 0x08) ? 1 : 0;
        int fsp = (b[1] & 0x04) ? 1 : 0;
        size_t p;

        if (fsc) fsc_set++; else fsc_not_set++;

        switch (b[0] & 0xE0) {
        case 0x00: /* header */
            if (bi == 0 && !(b[0] == 0 && b[1] == 0 && b[2] == 0)) {
                a->apt = b[4] & 0x07;
                a->dsf = (b[3] & 0x80) ? 1 : 0;
            }
            break;

        case 0x20: /* subcode */
            if (!fsc && fsp) {
                uint8_t bf[6];
                int i;
                int32_t v[2];
                int dseq_off = (int)((bi * DV_BLOCK_SIZE) / DV_DSEQ_SIZE);
                for (i = 0; i < 6; i++)
                    bf[i] = (uint8_t)(((b[8 * i + 3] & 0x0F) << 4) | (b[8 * i + 4] >> 4));
                for (i = 0; i < 2; i++)
                    v[i] = (int32_t)((bf[i * 3] >> 1) | (bf[i * 3 + 1] << 7) | (bf[i * 3 + 2] << 15));
                if (v[0] != 0x7FFFFF && v[0] == v[1]) {
                    int32_t val = v[0];
                    if (bf[2] == 0xFF)
                        val -= 0x800000;
                    /* standard: 1 track per Dseq; non standard decks: 1.5 */
                    abst_add(cands[0], &ncands[0], val - dseq_off, 1);
                    abst_add(cands[1], &ncands[1], val - dseq_off - (dseq_off / 2 + dseq_off % 2), 1);
                    if (bf[0] & 1)
                        f->bf = 1;
                } else {
                    for (i = 0; i < 2; i++)
                        if (bf[i * 3] != 0xFF && bf[i * 3 + 1] != 0xFF && bf[i * 3 + 2] != 0xFF)
                        {
                            abst_add(weak[0], &nweak[0], v[i] - dseq_off, 1);
                            abst_add(weak[1], &nweak[1], v[i] - dseq_off - (dseq_off / 2 + dseq_off % 2), 1);
                        }
                }
            }
            for (p = 0; p < 48; p += 8) {
                const uint8_t *pk = b + 3 + p + 3; /* pack type + 4 bytes */
                if (pk[0] != 0xFF)
                    pack_sub = 1;
                if (pk[0] == 0x13 && !tc_valid) {
                    int fr = BCD2(pk[1], 0x30), se = BCD2(pk[2], 0x70);
                    int mi = BCD2(pk[3], 0x70), ho = BCD2(pk[4], 0x30);
                    if (fr != 45 && se != 85 && mi != 85 && ho != 45 && se < 60 && mi < 60 && ho < 24) {
                        tc_valid = 1;
                        tc_f = fr; tc_s = se; tc_m = mi; tc_h = ho;
                        tc_df = (pk[1] & 0x40) ? 1 : 0;
                    }
                }
                if (pk[0] == 0x62 && !rd_valid) {
                    int d = BCD2(pk[2], 0x30), mo = BCD2(pk[3], 0x10), y = BCD2(pk[4], 0xF0);
                    if (y <= 99 && mo && mo <= 12 && d && d <= 31) {
                        rd_valid = 1; rd_d = d; rd_mo = mo; rd_y = y;
                    }
                }
                if (pk[0] == 0x63 && !rt_valid) {
                    int fr = BCD2(pk[1], 0x30), se = BCD2(pk[2], 0x70);
                    int mi = BCD2(pk[3], 0x70), ho = BCD2(pk[4], 0x30);
                    if (se < 60 && mi < 60 && ho < 24) {
                        rt_valid = 1; rt_s = se; rt_m = mi; rt_h = ho;
                        rt_f = (fr == 45) ? 0x3F : fr;
                    }
                }
            }
            break;

        case 0x40: /* VAUX */
        {
            int ok = 1, i, j;
            if (b[3 + 75] != 0xFF || b[3 + 76] != 0xFF)
                ok = 0;
            if (ok) {
                int has_ff = 0;
                for (i = 0; i < 15 && ok; i++) {
                    const uint8_t *pi = b + 3 + i * 5;
                    if (pi[0] == 0xFF)
                        has_ff = 1;
                    for (j = 0; j < i; j++) {
                        const uint8_t *pj = b + 3 + j * 5;
                        if (pj[0] == pi[0] && memcmp(pi, pj, 5)) { ok = 0; break; }
                    }
                }
                if (!has_ff)
                    ok = 0;
            }
            if (!ok)
                break;
            for (i = 0; i < 15; i++) {
                const uint8_t *pk = b + 3 + i * 5;
                if (pk[0] != 0xFF)
                    pack_vid = 1;
                switch (pk[0]) {
                case 0x60:
                    a->system = (pk[3] & 0x20) ? 1 : 0;
                    a->stype = pk[3] & 0x1F;
                    vsrc = 1;
                    break;
                case 0x61:
                    a->aspect = pk[2] & 0x07;
                    vctl = 1;
                    break;
                case 0x62:
                    if (!rd_valid) {
                        int d = BCD2(pk[2], 0x30), mo = BCD2(pk[3], 0x10), y = BCD2(pk[4], 0xF0);
                        if (y < 100 && mo && mo <= 12 && d && d <= 31) {
                            rd_valid = 1; rd_d = d; rd_mo = mo; rd_y = y;
                        }
                    }
                    break;
                case 0x63:
                    if (!rt_valid) {
                        int fr = BCD2(pk[1], 0x30), se = BCD2(pk[2], 0x70);
                        int mi = BCD2(pk[3], 0x70), ho = BCD2(pk[4], 0x30);
                        if (se < 60 && mi < 60 && ho < 24) {
                            rt_valid = 1; rt_s = se; rt_m = mi; rt_h = ho;
                            rt_f = (fr == 45) ? 0x3F : fr;
                        }
                    }
                    break;
                case 0x65:
                {
                    int k;
                    captions = 1;
                    for (k = 0; k < 2; k++) {
                        uint8_t b0 = pk[1 + k * 2], b1 = pk[2 + k * 2];
                        if (b0 != 0xFF && b1 != 0xFF) {
                            int c0 = 0, c1 = 0, bit;
                            for (bit = 0; bit < 8; bit++) { c0 += (b0 >> bit) & 1; c1 += (b1 >> bit) & 1; }
                            if (!(c0 % 2) || !(c1 % 2))
                                cc_parity = 1;
                        }
                    }
                    break;
                }
                }
            }
            break;
        }

        case 0x60: /* audio */
        {
            const uint8_t *pk = b + 3;
            uint16_t value;
            if (pk[0] != 0xFF)
                pack_aud = 1;
            if (pk[0] == 0x50) {
                a->smp = (pk[4] >> 3) & 0x07;
                a->qu = pk[4] & 0x07;
                groups_this_frame |= 1 << fsc;
                asrc = 1;
            } else if (pk[0] == 0x51) {
                rec_st = (pk[2] & 0x80) ? 1 : 0;
                rec_end = (pk[2] & 0x40) ? 1 : 0;
                rec_valid = 1;
                actl = 1;
                if (speed == DV_SPEED_UNKNOWN) {
                    int s = pk[3] & 0x7F;
                    speed = (pk[3] & 0x80) ? s : -s;
                }
            } else if (pk[0] == 0x52 && !rd_valid) {
                int d = BCD2(pk[2], 0x30), mo = BCD2(pk[3], 0x10), y = BCD2(pk[4], 0xF0);
                if (y < 100 && mo && mo <= 12 && d && d <= 31) {
                    rd_valid = 1; rd_d = d; rd_mo = mo; rd_y = y;
                }
            } else if (pk[0] == 0x53 && !rt_valid) {
                int fr = BCD2(pk[1], 0x30), se = BCD2(pk[2], 0x70);
                int mi = BCD2(pk[3], 0x70), ho = BCD2(pk[4], 0x30);
                if (se < 60 && mi < 60 && ho < 24) {
                    rt_valid = 1; rt_s = se; rt_m = mi; rt_h = ho;
                    rt_f = (fr == 45) ? 0x3F : fr;
                }
            }
            if (audio_block_error(b, a->qu, &value)) {
                f->audio_errors++;
                if (dseq < DV_MAX_DSEQ)
                    f->aud[dseq]++;
                /* remember values (trivial ones filtered at end of frame) */
                {
                    {
                        int k, found = 0;
                        for (k = 0; k < f->aud_values_n; k++)
                            if (f->aud_values[k].dseq == dseq && f->aud_values[k].value == value) { found = 1; break; }
                        if (!found && f->aud_values_n < DV_MAX_AUD_VALUES) {
                            f->aud_values[f->aud_values_n].dseq = (uint8_t)dseq;
                            f->aud_values[f->aud_values_n].value = value;
                            f->aud_values_n++;
                        }
                    }
                }
                if (f->block_status) f->block_status[bi] = DV_BS_NOK;
            } else if (f->block_status)
                f->block_status[bi] = DV_BS_OK;
            break;
        }

        case 0x80: /* video */
        {
            int arb = b[0] & 0x0F;
            int st = b[3] >> 4;
            arb_counters[arb]++;
            arb_any = 1;
            f->video_blocks++;
            if (st && a->stype >= 0) {
                sta[(dseq << 4) | st]++;
                any_sta = 1;
                f->video_errors++;
            }
            if (f->block_status)
                f->block_status[bi] = st ? DV_BS_NOK : DV_BS_OK;
            break;
        }
        }
    }

    /* ---- frame level results ---- */
    f->dsf = (uint8_t)a->dsf;
    f->fsc = (fsc_set > fsc_not_set) ? 1 : 0;
    {
        int sys = a->system; /* MediaInfoLib defaults to 525/60 until a VAUX source pack is seen */
        frames_max = (a->stype >= 0 ? a->system : a->dsf) ? 25 : 30;
        switch (a->stype) {
        case 0x00: case 0x04: f->width = 720; f->height = a->system ? 576 : 480; break;
        case 0x14: case 0x15: f->width = a->system ? 1440 : 1280; f->height = a->stype == 0x14 ? 1080 : 1035; break;
        case 0x18: f->width = 960; f->height = 720; break;
        default:
            if (!f->fsc) { f->width = 720; f->height = sys ? 576 : 480; }
        }
        f->chroma = -1;
        if (a->stype >= 0) {
            if (!f->fsc) {
                if (!a->system)
                    f->chroma = a->stype == 0 ? 0 : -1;
                else if (a->stype == 0 || a->stype == 1)
                    f->chroma = a->apt == 0 ? 1 : 0;
            } else
                f->chroma = 2;
            f->rate_n = a->system ? 25 : 30000;
            if (a->stype == 0x18)
                f->rate_n *= 2;
            f->rate_d = a->system ? 1 : 1001;
        }
        switch (a->aspect) {
        case 0: case 4: f->aspect_n = 4; f->aspect_d = 3; break;
        case 1: case 2: case 7: f->aspect_n = 16; f->aspect_d = 9; break;
        default: break;
        }
    }
    if (groups_this_frame)
        a->channel_groups = groups_this_frame;
    if (a->channel_groups && a->qu >= 0) {
        int groups = (a->channel_groups & 1) + ((a->channel_groups >> 1) & 1);
        switch (a->smp) {
        case 0: f->audio_rate = 48000; break;
        case 1: f->audio_rate = 44100; break;
        case 2: f->audio_rate = 32000; break;
        default: f->audio_rate = 0;
        }
        if (a->qu == 0) { f->channels = (uint8_t)(groups * 2); f->bitdepth = 16; }
        else if (a->qu == 1) { f->channels = (uint8_t)(groups * 4); f->bitdepth = 12; }
    }
    f->captions = (uint8_t)captions;
    f->caption_parity = (uint8_t)cc_parity;
    f->speed = speed;

    /* PTS */
    {
        int sys = a->system;
        uint64_t pts = a->count_system[0] * 100100000ULL / 3 + a->count_system[1] * 40000000ULL;
        uint64_t next;
        a->count_system[sys]++;
        next = a->count_system[0] * 100100000ULL / 3 + a->count_system[1] * 40000000ULL;
        f->pts_ns = pts;
        f->dur_ns = next - pts;
    }

    /* Time code continuity */
    if (tc_valid) {
        int cur = tc_pack(tc_h, tc_m, tc_s, tc_f);
        f->tc_valid = 1;
        f->tc_h = (uint8_t)tc_h; f->tc_m = (uint8_t)tc_m; f->tc_s = (uint8_t)tc_s; f->tc_f = (uint8_t)tc_f;
        f->tc_df = (uint8_t)(tc_df && !a->dsf);
        if (cur)
            a->tc_seen_nonzero = 1;
        if (a->tc_seen_nonzero && a->last_tc_valid) {
            if (cur == a->last_tc)
                f->tc_r = 1;
            else if (cur != tc_next(a->last_tc, frames_max, a->last_tc_df && !a->dsf))
                f->tc_nc = cur < a->last_tc ? 2 : 1;
        }
    }
    a->last_tc_valid = tc_valid;
    if (tc_valid) {
        a->last_tc = tc_pack(tc_h, tc_m, tc_s, tc_f);
        a->last_tc_df = tc_df;
    }

    /* Recording date / time */
    if (rd_valid) {
        f->rd_valid = 1; f->rd_y = (uint8_t)rd_y; f->rd_m = (uint8_t)rd_mo; f->rd_d = (uint8_t)rd_d;
    }
    if (rt_valid) {
        int cur = (rt_h << 16) | (rt_m << 8) | rt_s;
        f->rt_valid = 1; f->rt_h = (uint8_t)rt_h; f->rt_m = (uint8_t)rt_m; f->rt_s = (uint8_t)rt_s; f->rt_f = (uint8_t)rt_f;
        if (a->last_rt_valid && cur != a->last_rt && cur != rt_next(a->last_rt)) {
            /* like MediaInfoLib, a frame without date keeps the last date seen */
            int64_t c = ((int64_t)(rd_valid ? ((rd_y << 16) | (rd_mo << 8) | rd_d) : a->last_rd) << 24) | cur;
            int64_t p = ((int64_t)a->last_rd << 24) | a->last_rt;
            f->rdt_nc = c < p ? 2 : 1;
        }
    }
    a->last_rt_valid = rt_valid;
    if (rt_valid)
        a->last_rt = (rt_h << 16) | (rt_m << 8) | rt_s;
    a->last_rd_valid = rd_valid;
    if (rd_valid)
        a->last_rd = (rd_y << 16) | (rd_mo << 8) | rd_d;

    if (rec_valid && !rec_st)
        f->rec_start = 1;
    else if (rec_valid && !rec_end)
        f->rec_end = 1;

    /* Sequence number (arbitrary bits of video blocks) */
    if (arb_any) {
        int best = 0xF, best_count = 0, k;
        for (k = 0; k <= 0xF; k++)
            if (arb_counters[k] > best_count) { best = k; best_count = arb_counters[k]; }
        f->seqn_valid = 1;
        f->seqn = (uint8_t)best;
        if (best != 0)
            a->arb_seen = 1;
        if (a->arb_seen && a->arb_last_valid && best == a->arb_last && best != 0xF) {
            f->seqn_r = 1;
            a->arb_theory_valid = 0;
        } else if (a->arb_seen && a->arb_theory_valid && best != a->arb_theory) {
            f->seqn_nc = best < a->arb_theory ? 2 : 1;
            a->arb_theory = best;
        }
        if (!a->arb_theory_valid && best != 0xF) {
            a->arb_theory = best;
            a->arb_theory_valid = 1;
        }
        if (a->arb_theory_valid && best != 0xF) {
            a->arb_theory++;
            if (a->arb_theory >= 12)
                a->arb_theory = 0;
        }
        a->arb_last_valid = 1;
        a->arb_last = best;
    } else
        a->arb_last_valid = 0;

    /* Absolute track number */
    {
        int use_weak = !ncands[0];
        int alt = use_weak ? (nweak[1] < nweak[0]) : (ncands[1] < ncands[0]);
        abst_cand *c = use_weak ? weak[alt] : cands[alt];
        int n = use_weak ? nweak[alt] : ncands[alt], k, best = -1;
        for (k = 0; k < n; k++)
            if (best < 0 || c[k].count > c[best].count || (c[k].count == c[best].count && c[k].value < c[best].value))
                best = k;
        if (best >= 0 && c[best].value >= 0) {
            int32_t gap = (a->dsf ? 12 : 10) * (f->fsc ? 2 : 1);
            int32_t cur = c[best].value;
            f->abst_valid = 1;
            f->abst = cur;
            if (a->abst_prev_valid) {
                if (cur == a->abst_prev)
                    f->abst_r = 1;
                else if (cur < a->abst_prev || cur >= a->abst_prev + gap * 2)
                    f->abst_nc = 1;
            }
            a->abst_prev_valid = 1;
            a->abst_prev = cur;
        } else if (a->abst_prev_valid) {
            a->abst_prev += (a->dsf ? 12 : 10) * (f->fsc ? 2 : 1); /* theoretical */
        }
    }

    /* Keep audio error values only where they are not just the standard
     * error code (0x8000 / 0x800), judged with the final quantization */
    {
        int is16 = a->qu != 1, d, k, m = 0;
        uint16_t trivial = is16 ? 0x8000 : 0x0800;
        int cnt[DV_MAX_DSEQ], only_trivial[DV_MAX_DSEQ];
        for (d = 0; d < DV_MAX_DSEQ; d++) { cnt[d] = 0; only_trivial[d] = 1; }
        for (k = 0; k < f->aud_values_n; k++) {
            cnt[f->aud_values[k].dseq]++;
            if (f->aud_values[k].value != trivial)
                only_trivial[f->aud_values[k].dseq] = 0;
        }
        for (k = 0; k < f->aud_values_n; k++) {
            d = f->aud_values[k].dseq;
            if (cnt[d] > 1 || !only_trivial[d])
                f->aud_values[m++] = f->aud_values[k];
        }
        f->aud_values_n = (uint8_t)m;
        /* sort by dseq then value, as a std::set would */
        for (k = 1; k < m; k++) {
            int j = k;
            while (j > 0 && (f->aud_values[j - 1].dseq > f->aud_values[j].dseq
                   || (f->aud_values[j - 1].dseq == f->aud_values[j].dseq && f->aud_values[j - 1].value > f->aud_values[j].value))) {
                dv_aud_value t = f->aud_values[j]; f->aud_values[j] = f->aud_values[j - 1]; f->aud_values[j - 1] = t;
                j--;
            }
        }
    }

    /* Coherency */
    f->no_pack_sub = !pack_sub;
    f->no_pack_vid = !pack_vid;
    f->no_pack_aud = !pack_aud;
    f->no_sc_vid = !(vsrc && vctl);
    f->no_sc_aud = !(asrc && actl);
    {
        int max_sta = (a->dsf ? 1500 : 1350) * (f->fsc ? 2 : 1), st, d;
        for (st = 0; st < 16; st++) {
            int tot = 0;
            for (d = 0; d < 16; d++)
                tot += sta[(d << 4) | st];
            if (st && tot == max_sta)
                f->full_conceal_vid = 1;
        }
        if (f->audio_errors >= (uint32_t)((a->dsf ? 100 : 90) * (f->fsc ? 2 : 1)))
            f->full_conceal_aud = 1;
    }
    if (any_sta) {
        f->sta = (uint16_t *)malloc(sizeof(sta));
        if (f->sta)
            memcpy(f->sta, sta, sizeof(sta));
    }

    a->frame_count++;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Splitter                                                            */

void dv_splitter_init(dv_splitter *s)
{
    memset(s, 0, sizeof(*s));
}

void dv_splitter_free(dv_splitter *s)
{
    free(s->buf);
    memset(s, 0, sizeof(*s));
}

static void splitter_block(dv_splitter *s, const uint8_t *b, dv_frame_cb cb, void *ctx)
{
    int64_t block_pos = s->stream_pos;
    s->stream_pos += DV_BLOCK_SIZE;
    if (dv_is_frame_start(b)) {
        if (s->synced && s->len)
            cb(ctx, s->buf, s->len, s->frame_pos);
        s->len = 0;
        s->synced = 1;
        s->frame_pos = block_pos;
    }
    if (!s->synced) {
        s->skipped += DV_BLOCK_SIZE;
        return;
    }
    if (s->len + DV_BLOCK_SIZE > s->cap) {
        size_t nc = s->cap ? s->cap * 2 : 160000;
        uint8_t *nb;
        if (nc > (size_t)DV_MAX_FRAME * 4) {
            /* runaway frame without headers: emit what we have */
            cb(ctx, s->buf, s->len, s->frame_pos);
            s->len = 0;
            s->frame_pos = block_pos;
            nc = s->cap;
        }
        if (nc > s->cap) {
            nb = (uint8_t *)realloc(s->buf, nc);
            if (!nb)
                return;
            s->buf = nb;
            s->cap = nc;
        }
    }
    memcpy(s->buf + s->len, b, DV_BLOCK_SIZE);
    s->len += DV_BLOCK_SIZE;
}

void dv_splitter_push(dv_splitter *s, const uint8_t *data, size_t len, dv_frame_cb cb, void *ctx)
{
    if (s->part_len) {
        size_t need = DV_BLOCK_SIZE - s->part_len;
        if (len < need) {
            memcpy(s->part + s->part_len, data, len);
            s->part_len += len;
            return;
        }
        memcpy(s->part + s->part_len, data, need);
        splitter_block(s, s->part, cb, ctx);
        s->part_len = 0;
        data += need;
        len -= need;
    }
    while (len >= DV_BLOCK_SIZE) {
        splitter_block(s, data, cb, ctx);
        data += DV_BLOCK_SIZE;
        len -= DV_BLOCK_SIZE;
    }
    if (len) {
        memcpy(s->part, data, len);
        s->part_len = len;
    }
}

void dv_splitter_flush(dv_splitter *s, dv_frame_cb cb, void *ctx)
{
    if (s->synced && s->len)
        cb(ctx, s->buf, s->len, s->frame_pos);
    s->len = 0;
    s->part_len = 0;
}
