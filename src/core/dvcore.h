/*
 * OldDV Rescue - DV analysis core
 *
 * Portable C99 (no dependencies) so that it builds with the gcc 4.2 /
 * clang toolchains shipped with Xcode 3.2.x on Mac OS X 10.6, and on Linux
 * for testing.
 *
 * The analysis semantics (what counts as an error, how timecode / recording
 * date / sequence number / absolute track number continuity is judged, the
 * XML report layout) follow DVRescue (https://github.com/mipops/dvrescue,
 * BSD-3-Clause, (c) MIPoPS) and the DV DIF analysis of MediaInfoLib
 * (BSD-2-Clause, (c) MediaArea.net SARL), re-implemented from scratch.
 * See NOTICE.md.
 */
#ifndef OLDDV_DVCORE_H
#define OLDDV_DVCORE_H

#include <stdio.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OLDDV_VERSION "1.0.0"

#define DV_BLOCK_SIZE   80
#define DV_DSEQ_SIZE    12000          /* 150 blocks of 80 bytes */
#define DV_MAX_DSEQ     16
#define DV_STA_VALUES   16
#define DV_MAX_FRAME    (12 * 150 * 80 * 2) /* PAL DV50 */
#define DV_MAX_BLOCKS   (DV_MAX_FRAME / DV_BLOCK_SIZE)
#define DV_SPEED_UNKNOWN (-100000)
#define DV_MAX_AUD_VALUES 32

/* Per-block status (same values as DVRescue merge) */
enum { DV_BS_UNKNOWN = 0, DV_BS_OK = 1, DV_BS_NOK = 2 };

typedef struct dv_aud_value {
    uint8_t  dseq;
    uint16_t value;
} dv_aud_value;

/* Everything known about one DV frame. */
typedef struct dv_frame {
    uint32_t index;          /* frame number in the stream */
    int64_t  pos;            /* byte offset of the frame in the stream */
    uint32_t size;           /* bytes */
    uint64_t pts_ns;
    uint64_t dur_ns;

    /* Format ("change" attributes) */
    uint8_t  dsf;            /* 0 = 525/60 (NTSC), 1 = 625/50 (PAL) */
    uint8_t  fsc;            /* 1 = DV50 style 2 channels */
    int16_t  width, height;
    int8_t   chroma;         /* -1 unknown, 0 4:1:1, 1 4:2:0, 2 4:2:2 */
    uint8_t  aspect_n, aspect_d;
    uint32_t rate_n, rate_d;
    uint32_t audio_rate;
    uint8_t  channels, bitdepth;
    uint8_t  captions;       /* closed captions pack present */
    int      speed;          /* DV speed from AAUX, DV_SPEED_UNKNOWN if none */

    /* Time code (subcode) */
    uint8_t  tc_valid, tc_df, tc_r, tc_nc; /* tc_nc: 1 = jump forward, 2 = backward */
    uint8_t  tc_h, tc_m, tc_s, tc_f;

    /* Recording date / time */
    uint8_t  rd_valid, rd_y, rd_m, rd_d;
    uint8_t  rt_valid, rt_h, rt_m, rt_s, rt_f; /* rt_f 0x3F = unknown */
    uint8_t  rdt_nc;         /* 1 = jump forward, 2 = backward */
    uint8_t  rec_start, rec_end;

    /* Sequence number ("arbitrary bits") */
    uint8_t  seqn_valid, seqn, seqn_r, seqn_nc;

    /* Absolute track number */
    uint8_t  abst_valid, abst_r, abst_nc, bf;
    int32_t  abst;

    /* Coherency */
    uint8_t  no_pack_sub, no_pack_vid, no_pack_aud;
    uint8_t  no_sc_vid, no_sc_aud;      /* missing source or source-control pack */
    uint8_t  full_conceal_vid, full_conceal_aud;
    uint8_t  caption_parity;

    /* Errors */
    uint32_t video_blocks;               /* video DIF blocks in this frame */
    uint32_t video_errors;               /* video blocks with STA != 0 (counted) */
    uint32_t audio_errors;               /* audio blocks containing error code */
    uint16_t *sta;                       /* [dseq<<4 | sta] counts, NULL if none */
    uint16_t aud[DV_MAX_DSEQ];           /* audio error blocks per Dseq */
    uint8_t  aud_values_n;
    dv_aud_value aud_values[DV_MAX_AUD_VALUES]; /* non trivial error values */

    /* Optional per-80-byte-block status (analyzer keep_block_status) */
    uint8_t  *block_status;
    uint32_t block_count;
} dv_frame;

/* Stateful analyzer, one per stream (continuity tests need history). */
typedef struct dv_analyzer {
    int keep_block_status;
    uint32_t frame_count;
    uint64_t count_system[2];

    /* persistent stream state */
    int dsf, apt;
    int system;               /* 0 = 60, 1 = 50 (from VAUX) */
    int stype;                /* -1 unknown */
    int aspect;               /* -1 unknown */
    int smp, qu;              /* -1 unknown */
    int channel_groups;       /* bitmask */

    /* continuity state */
    int tc_seen_nonzero;
    int last_tc_valid; int last_tc; int last_tc_df;   /* last tc in frames (h*... encoded) */
    int last_rt_valid; int last_rt; int last_rd_valid; int last_rd;
    int arb_seen;
    int arb_last_valid; int arb_last;
    int arb_theory_valid; int arb_theory;
    int abst_prev_valid; int32_t abst_prev; int32_t abst_prev_theory;
} dv_analyzer;

void dv_analyzer_init(dv_analyzer *a, int keep_block_status);

/* Analyze one complete frame (as produced by dv_splitter). Fills *out
 * (caller must call dv_frame_free). Returns 0 on success. */
int  dv_analyze_frame(dv_analyzer *a, const uint8_t *data, size_t size,
                      int64_t pos, dv_frame *out);
void dv_frame_free(dv_frame *f);

/* Total number of "bad" blocks (video STA + audio) */
static inline uint32_t dv_frame_error_blocks(const dv_frame *f)
{ return f->video_errors + f->audio_errors; }

/* True if DVRescue would report this frame as having an issue */
int  dv_frame_has_errors(const dv_frame *f);
int  dv_speed_is_normal(int speed);

/* Compute per block status for an already split frame.
 * qu: audio quantization (0 = 16 bit, 1 = 12 bit, -1 unknown).
 * status must hold size/80 bytes. Returns count of NOK blocks. */
uint32_t dv_block_status(const uint8_t *data, size_t size, int qu, uint8_t *status);

/* --------------------------------------------------------------------- */
/* Frame splitter: feed it an arbitrary byte stream, get whole frames.    */

typedef void (*dv_frame_cb)(void *ctx, const uint8_t *frame, size_t size, int64_t pos);

typedef struct dv_splitter {
    uint8_t *buf;          /* current frame being accumulated */
    size_t   len, cap;
    uint8_t  part[DV_BLOCK_SIZE]; /* partial block carried between pushes */
    size_t   part_len;
    int64_t  stream_pos;   /* bytes consumed so far */
    int64_t  frame_pos;    /* position of current frame start */
    int      synced;       /* first frame header found */
    uint64_t skipped;      /* bytes before first header */
} dv_splitter;

void dv_splitter_init(dv_splitter *s);
void dv_splitter_push(dv_splitter *s, const uint8_t *data, size_t len, dv_frame_cb cb, void *ctx);
void dv_splitter_flush(dv_splitter *s, dv_frame_cb cb, void *ctx);
void dv_splitter_free(dv_splitter *s);
int  dv_is_frame_start(const uint8_t *block);

/* --------------------------------------------------------------------- */
/* Report: all frames of one file + XML writer                            */

typedef struct dv_report {
    char     *path;         /* reference written in XML */
    int64_t  file_size;
    dv_frame *frames;       /* block_status is always freed */
    uint32_t count, cap;
    dv_analyzer an;
    int      stop_method;   /* 0 none, 1 timeout, 2 user */
    /* summary */
    uint32_t frames_with_errors;
    uint32_t frames_video_errors, frames_audio_errors;
    uint32_t tc_breaks, rdt_breaks, rec_starts, full_conceal;
} dv_report;

void dv_report_init(dv_report *r, const char *path);
void dv_report_add(dv_report *r, const dv_frame *f); /* takes ownership of f->sta */
/* Analyze the frame and add it (convenience). */
void dv_report_feed(dv_report *r, const uint8_t *frame, size_t size, int64_t pos);
void dv_report_free(dv_report *r);

/* Analyze a whole file. progress(ctx, fraction) may be NULL; return
 * non-zero from it to cancel. Returns 0 on success. */
typedef int (*dv_progress_cb)(void *ctx, double fraction);
int  dv_analyze_file(const char *path, dv_report *r, dv_progress_cb progress, void *ctx);

/* DVRescue compatible XML (namespace https://mediaarea.net/dvrescue) */
int  dv_report_write_xml(FILE *out, dv_report **reports, int count);
int  dv_report_save_xml(const char *path, dv_report *r);
/* Human readable summary */
void dv_report_write_summary(FILE *out, const dv_report *r);
/* One line per frame with issues, CSV */
void dv_report_write_csv(FILE *out, const dv_report *r);

/* Formatting helpers */
void dv_format_tc(char *buf, const dv_frame *f);           /* "HH:MM:SS:FF" or "" */
void dv_format_rdt(char *buf, const dv_frame *f);          /* "YYYY-MM-DD HH:MM:SS" */
void dv_format_ts(char *buf, uint64_t ns);                 /* "HH:MM:SS.mmmmmm" */

/* --------------------------------------------------------------------- */
/* Merge several captures of the same tape, block by block.               */

typedef struct dv_merge_stats {
    uint32_t frames_out;
    uint32_t frames_ok;           /* error free in at least one input */
    uint32_t frames_repaired;     /* fixed by mixing blocks */
    uint32_t frames_still_bad;
    uint32_t blocks_fixed, blocks_remaining;
    uint32_t frames_missing;      /* gaps not present in any input */
    int      key_mode;            /* 0 timecode, 1 abst, 2 position */
} dv_merge_stats;

typedef void (*dv_log_cb)(void *ctx, const char *line);

int dv_merge_files(const char **inputs, int n, const char *output,
                   dv_merge_stats *stats, dv_log_cb log, dv_progress_cb progress, void *ctx);

/* --------------------------------------------------------------------- */
/* Packager: split a DV file in parts                                     */

enum {
    DV_SPLIT_REC_START = 1,   /* new recording (rec_start flag / rec date jump) */
    DV_SPLIT_FORMAT    = 2,   /* change of size / rate / aspect / audio */
    DV_SPLIT_TC_BREAK  = 4    /* time code discontinuity */
};

/* Writes <outbase>_partNNN.dv files. names receives up to max_names
 * malloc'ed file names (caller frees). Returns number of parts or -1. */
int dv_split_file(const char *path, const char *outbase, int flags,
                  uint32_t min_frames, char **names, int max_names,
                  dv_log_cb log, dv_progress_cb progress, void *ctx);

/* --------------------------------------------------------------------- */
/* Buffered background writer (for slow / network destinations)           */

typedef struct dv_writer dv_writer;
dv_writer *dv_writer_open(const char *path, size_t buffer_bytes); /* 0 = 256 MB */
/* 0 queued, 1 dropped (buffer full), -1 write error (disk full, share gone) */
int    dv_writer_write(dv_writer *w, const void *data, size_t size);
size_t dv_writer_pending(dv_writer *w);  /* bytes not yet written */
size_t dv_writer_peak(dv_writer *w);     /* highest buffer use */
int    dv_writer_error(dv_writer *w);    /* 0 ok, 1 write error, 2 data dropped */
uint64_t dv_writer_dropped(dv_writer *w);
int    dv_writer_close(dv_writer *w);    /* flush and close: 0 ok, 1 data was dropped, -1 error */

/* --------------------------------------------------------------------- */
/* Audio extraction and lossless QuickTime (.mov) rewrap                  */

typedef struct dv_audio_fmt {
    int dsf;         /* 0 NTSC, 1 PAL */
    unsigned rate;   /* 48000 / 44100 / 32000 */
    int quant;       /* 0 = 16 bit, 1 = 12 bit nonlinear */
    int samples;     /* samples in this frame */
    int pairs;       /* stereo pairs (2 for 12 bit 4 channels) */
} dv_audio_fmt;

int  dv_audio_info(const uint8_t *frame, size_t size, dv_audio_fmt *fmt);
void dv_audio_extract(const uint8_t *frame, size_t size, const dv_audio_fmt *fmt, int pair, int16_t *out);

/* Rewrap bytes [start, end) of a DV file (end <= 0: to the end) into a
 * QuickTime movie: DV video track + 16-bit PCM audio track(s). */
int dv_write_mov(const char *in, int64_t start, int64_t end, const char *out,
                 dv_log_cb log, dv_progress_cb progress, void *ctx);

#ifdef __cplusplus
}
#endif
#endif
