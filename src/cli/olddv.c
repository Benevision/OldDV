/*
 * olddv - command line companion of OldDV Rescue.
 *
 *   olddv FILE.dv [FILE2.dv ...]           XML report on stdout
 *   olddv FILE.dv -x report.xml            XML report to a file
 *   olddv FILE.dv -s                       human readable summary
 *   olddv FILE.dv --csv                    frames with issues as CSV
 *   olddv A.dv B.dv C.dv -m merged.dv      merge captures of one tape
 *   olddv FILE.dv --split base [--by rec,format,tc] [--min N]
 */
#include "../core/dvcore.h"
#include <stdlib.h>
#include <string.h>

static void usage(void)
{
    fprintf(stderr,
        "OldDV Rescue command line v" OLDDV_VERSION "\n"
        "Usage: olddv FILE [FILE...] [options]\n"
        "  -x, --xml-output FILE   write DVRescue style XML report to FILE\n"
        "  -s, --summary           print a human readable summary\n"
        "      --csv               print frames with issues as CSV\n"
        "  -m, --merge FILE        merge all inputs (same tape) into FILE,\n"
        "                          picking the best blocks of each input\n"
        "      --merge-log FILE    write the merge log to FILE\n"
        "      --split BASE        split the input into BASE_partNNN.dv\n"
        "      --mov FILE          rewrap the input into a QuickTime .mov\n"
        "                          (DV video untouched + PCM audio, lossless)\n"
        "      --by LIST           split criteria: rec,format,tc (default rec,format)\n"
        "      --min N             minimum part length in frames (default 1)\n"
        "  -p, --progress          show progress on stderr\n"
        "  -h, --help              this help\n");
}

static FILE *merge_log_fp;
static void log_cb(void *ctx, const char *line)
{
    (void)ctx;
    fprintf(merge_log_fp ? merge_log_fp : stderr, "%s\n", line);
}

static int quiet = 1;
static int progress_cb(void *ctx, double f)
{
    static int last = -1;
    int p = (int)(f * 100);
    (void)ctx;
    if (!quiet && p != last) {
        fprintf(stderr, "\r%3d%%", p);
        if (p >= 100)
            fputc('\n', stderr);
        last = p;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *inputs[64];
    int ninputs = 0, i, ret = 0;
    const char *mov_out = NULL, *xml_out = NULL, *merge_out = NULL, *merge_log = NULL, *split_base = NULL;
    int summary = 0, csv = 0, split_flags = DV_SPLIT_REC_START | DV_SPLIT_FORMAT;
    unsigned min_frames = 1;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 0; }
        else if (!strcmp(a, "--version")) { printf("OldDV Rescue v" OLDDV_VERSION "\n"); return 0; }
        else if ((!strcmp(a, "-x") || !strcmp(a, "--xml-output")) && i + 1 < argc) xml_out = argv[++i];
        else if ((!strcmp(a, "-m") || !strcmp(a, "--merge")) && i + 1 < argc) merge_out = argv[++i];
        else if (!strcmp(a, "--merge-log") && i + 1 < argc) merge_log = argv[++i];
        else if (!strcmp(a, "--split") && i + 1 < argc) split_base = argv[++i];
        else if (!strcmp(a, "--mov") && i + 1 < argc) mov_out = argv[++i];
        else if (!strcmp(a, "--by") && i + 1 < argc) {
            const char *v = argv[++i];
            split_flags = 0;
            if (strstr(v, "rec")) split_flags |= DV_SPLIT_REC_START;
            if (strstr(v, "format")) split_flags |= DV_SPLIT_FORMAT;
            if (strstr(v, "tc")) split_flags |= DV_SPLIT_TC_BREAK;
        }
        else if (!strcmp(a, "--min") && i + 1 < argc) min_frames = (unsigned)atoi(argv[++i]);
        else if (!strcmp(a, "-s") || !strcmp(a, "--summary")) summary = 1;
        else if (!strcmp(a, "--csv")) csv = 1;
        else if (!strcmp(a, "-q")) quiet = 1;
        else if (!strcmp(a, "-p") || !strcmp(a, "--progress")) quiet = 0;
        else if (a[0] == '-' && a[1]) { fprintf(stderr, "Unknown option %s\n", a); usage(); return 1; }
        else if (ninputs < 64) inputs[ninputs++] = a;
    }
    if (!ninputs) { usage(); return 1; }

    if (merge_out) {
        dv_merge_stats st;
        dv_report r;
        if (merge_log) {
            merge_log_fp = fopen(merge_log, "w");
            if (!merge_log_fp) { fprintf(stderr, "Cannot write %s\n", merge_log); return 1; }
        }
        if (dv_merge_files(inputs, ninputs, merge_out, &st, log_cb, quiet ? NULL : progress_cb, NULL)) {
            fprintf(stderr, "Merge failed\n");
            return 1;
        }
        if (merge_log_fp)
            fclose(merge_log_fp);
        /* report on merged output */
        dv_report_init(&r, merge_out);
        dv_analyze_file(merge_out, &r, NULL, NULL);
        if (xml_out)
            dv_report_save_xml(xml_out, &r);
        if (summary)
            dv_report_write_summary(stdout, &r);
        dv_report_free(&r);
        return 0;
    }

    if (mov_out) {
        if (dv_write_mov(inputs[0], 0, 0, mov_out, log_cb, quiet ? NULL : progress_cb, NULL)) {
            fprintf(stderr, "Rewrap failed\n");
            return 1;
        }
        return 0;
    }

    if (split_base) {
        char *names[1000];
        int n = dv_split_file(inputs[0], split_base, split_flags, min_frames, names, 1000, log_cb, NULL, NULL);
        if (n < 0) { fprintf(stderr, "Split failed\n"); return 1; }
        for (i = 0; i < n; i++) { printf("%s\n", names[i]); free(names[i]); }
        return 0;
    }

    {
        dv_report *reps = (dv_report *)calloc((size_t)ninputs, sizeof(dv_report));
        dv_report **pr = (dv_report **)calloc((size_t)ninputs, sizeof(dv_report *));
        for (i = 0; i < ninputs; i++) {
            dv_report_init(&reps[i], inputs[i]);
            if (dv_analyze_file(inputs[i], &reps[i], quiet ? NULL : progress_cb, NULL) < 0) {
                fprintf(stderr, "Cannot read %s\n", inputs[i]);
                ret = 1;
            }
            pr[i] = &reps[i];
        }
        if (summary)
            for (i = 0; i < ninputs; i++) {
                dv_report_write_summary(stdout, &reps[i]);
                if (i + 1 < ninputs) fputc('\n', stdout);
            }
        if (csv)
            for (i = 0; i < ninputs; i++)
                dv_report_write_csv(stdout, &reps[i]);
        if (xml_out) {
            FILE *fp = fopen(xml_out, "w");
            if (!fp) { fprintf(stderr, "Cannot write %s\n", xml_out); ret = 1; }
            else { dv_report_write_xml(fp, pr, ninputs); fclose(fp); }
        } else if (!summary && !csv)
            dv_report_write_xml(stdout, pr, ninputs);
        for (i = 0; i < ninputs; i++)
            dv_report_free(&reps[i]);
        free(reps);
        free(pr);
    }
    return ret;
}
