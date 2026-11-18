/*
 * olddv - command line companion of OldDV Rescue.
 *
 *   olddv FILE.dv [FILE2.dv ...]           XML report on stdout
 *   olddv FILE.dv -x report.xml            XML report to a file
 *   olddv FILE.dv -s                       human readable summary
 *   olddv FILE.dv --csv                    frames with issues as CSV
 *   olddv A.dv B.dv C.dv -m merged.dv      merge captures of one tape
 *   olddv --finish NAME.olddv              merge a capture and its re-reads
 *   olddv FILE.dv --split base [--by rec,format,tc] [--min N]
 */
#include "../core/dvcore.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
        "      --finish            the input is a capture whose re-read passes were\n"
        "                          not merged (NAME.olddv or NAME.dv): merge them into\n"
        "                          NAME.merged.dv and write its report\n"
        "      --split BASE        split the input into BASE_partNNN.dv\n"
        "      --mov FILE          rewrap the input into a QuickTime .mov\n"
        "                          (DV video untouched + PCM audio, lossless)\n"
        "                          audio error codes are repaired by interpolation\n"
        "      --mkv FILE          the same as a Matroska .mkv\n"
        "      --scc FILE          closed captions (NTSC) as Scenarist .scc, untouched\n"
        "      --srt FILE          closed captions as SubRip text\n"
        "      --vtt FILE          closed captions as WebVTT text\n"
        "      --cc-field N        captions of field 1 (default) or 2\n"
        "      --wav FILE          write the (repaired) audio as a .wav file\n"
        "      --no-audio-repair   keep unreadable audio samples as silence\n"
           "      --copy-to FILE      copy the input to FILE, waiting and retrying when\n"
           "                          the destination (network share) fails, then compare\n"
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
    const char *wav_out = NULL, *mkv_out = NULL; int export_flags = 0;
    const char *cc_out[3] = { NULL, NULL, NULL }; int cc_field = 1;
    const char *copy_to = NULL, *copy_until = NULL;
    const char *mov_out = NULL, *xml_out = NULL, *merge_out = NULL, *merge_log = NULL, *split_base = NULL;
    int finish = 0;
    int summary = 0, csv = 0, split_flags = DV_SPLIT_REC_START | DV_SPLIT_FORMAT;
    unsigned min_frames = 1;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 0; }
        else if (!strcmp(a, "--version")) { printf("OldDV Rescue v" OLDDV_VERSION "\n"); return 0; }
        else if ((!strcmp(a, "-x") || !strcmp(a, "--xml-output")) && i + 1 < argc) xml_out = argv[++i];
        else if ((!strcmp(a, "-m") || !strcmp(a, "--merge")) && i + 1 < argc) merge_out = argv[++i];
        else if (!strcmp(a, "--merge-log") && i + 1 < argc) merge_log = argv[++i];
        else if (!strcmp(a, "--finish")) finish = 1;
        else if (!strcmp(a, "--split") && i + 1 < argc) split_base = argv[++i];
        else if (!strcmp(a, "--mov") && i + 1 < argc) mov_out = argv[++i];
        else if (!strcmp(a, "--wav") && i + 1 < argc) wav_out = argv[++i];
        else if (!strcmp(a, "--mkv") && i + 1 < argc) mkv_out = argv[++i];
        else if (!strcmp(a, "--scc") && i + 1 < argc) cc_out[DV_CC_SCC] = argv[++i];
        else if (!strcmp(a, "--srt") && i + 1 < argc) cc_out[DV_CC_SRT] = argv[++i];
        else if (!strcmp(a, "--vtt") && i + 1 < argc) cc_out[DV_CC_VTT] = argv[++i];
        else if (!strcmp(a, "--cc-field") && i + 1 < argc) cc_field = atoi(argv[++i]);
        else if (!strcmp(a, "--copy-to") && i + 1 < argc) copy_to = argv[++i];
        else if (!strcmp(a, "--copy-until") && i + 1 < argc) copy_until = argv[++i];
        else if (!strcmp(a, "--no-audio-repair")) export_flags |= DV_EXPORT_NO_CONCEAL;
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

    if (copy_to) {
        /* copy with retries, then compare: the same code that moves a
         * capture from the local disk to a network share. With
         * --copy-until MARKER the input is still growing until the file
         * MARKER exists. */
        dv_mirror *m = dv_mirror_start(inputs[0], copy_to);
        dv_mirror_info mi;
        int st, told = 0, failing = 0;
        if (!m) { fprintf(stderr, "Cannot start the copy\n"); return 1; }
        if (!copy_until)
            dv_mirror_complete(m);
        while ((st = dv_mirror_status(m, &mi)) == DV_MIRROR_RUNNING) {
            if (copy_until && !told && !access(copy_until, F_OK)) {
                dv_mirror_complete(m);
                told = 1;
            }
            if (mi.failing != failing) {
                failing = mi.failing;
                fprintf(stderr, failing ? "Destination does not answer, trying again...\n" : "Destination is back.\n");
            }
            usleep(100000);
        }
        dv_mirror_free(m);
        if (st != DV_MIRROR_DONE) { fprintf(stderr, "Copy failed\n"); return 1; }
        if (dv_files_identical(inputs[0], copy_to, quiet ? NULL : progress_cb, NULL)) {
            fprintf(stderr, "The copy is NOT identical to %s\n", inputs[0]);
            return 1;
        }
        printf("Copied and verified: %lld bytes, %d interruption(s)\n", (long long)mi.copied, mi.failures);
        return 0;
    }

    if (finish) {
        dv_capture_set set;
        dv_merge_stats st;
        dv_report r;
        char *xml;
        if (dv_capture_open(inputs[0], &set)) {
            fprintf(stderr, "%s: no capture found (the first pass NAME.dv must be next to it)\n", inputs[0]);
            return 1;
        }
        for (i = 0; i < set.ntakes; i++)
            fprintf(stderr, "Take %d: %s\n", i + 1, set.takes[i]);
        if (set.missing)
            fprintf(stderr, "WARNING: %d take(s) of the list are missing\n", set.missing);
        if (set.ntakes < 2) {
            fprintf(stderr, "Only the first pass is there: nothing to merge.\n");
            dv_capture_free(&set);
            return 2;
        }
        if (set.merged_exists) {
            fprintf(stderr, "%s already exists: move it away first.\n", set.merged);
            dv_capture_free(&set);
            return 1;
        }
        if (merge_log)
            merge_log_fp = fopen(merge_log, "w");
        if (dv_merge_files((const char **)set.takes, set.ntakes, set.merged, &st, log_cb, quiet ? NULL : progress_cb, NULL)) {
            fprintf(stderr, "Merge failed\n");
            dv_capture_free(&set);
            return 1;
        }
        dv_report_init(&r, set.merged);
        dv_analyze_file(set.merged, &r, NULL, NULL);
        xml = (char *)malloc(strlen(set.merged) + 16);
        if (xml) {
            sprintf(xml, "%s.dvrescue.xml", set.merged);
            dv_report_save_xml(xml, &r);
            free(xml);
        }
        if (summary)
            dv_report_write_summary(stdout, &r);
        printf("%s\n", set.merged);
        dv_report_free(&r);
        dv_capture_free(&set);
        return 0;
    }

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

    if (cc_out[0] || cc_out[1] || cc_out[2]) {
        int f, none = 0;
        for (f = 0; f < 3; f++)
            if (cc_out[f]) {
                int r = dv_write_captions(inputs[0], 0, 0, cc_out[f], f, cc_field, log_cb, quiet ? NULL : progress_cb, NULL);
                if (r < 0) { fprintf(stderr, "Caption export failed\n"); return 1; }
                none |= r;
            }
        if (!mkv_out && !mov_out && !wav_out)
            return none ? 2 : 0;
    }

    if (mkv_out) {
        if (dv_write_mkv(inputs[0], 0, 0, mkv_out, export_flags, log_cb, quiet ? NULL : progress_cb, NULL)) {
            fprintf(stderr, "Rewrap failed\n");
            return 1;
        }
        if (!mov_out && !wav_out)
            return 0;
    }

    if (mov_out) {
        if (dv_write_mov_ex(inputs[0], 0, 0, mov_out, export_flags, log_cb, quiet ? NULL : progress_cb, NULL)) {
            fprintf(stderr, "Rewrap failed\n");
            return 1;
        }
        if (!wav_out)
            return 0;
    }

    if (wav_out) {
        int r = dv_write_wav(inputs[0], 0, 0, wav_out, export_flags, log_cb, quiet ? NULL : progress_cb, NULL);
        if (r) {
            fprintf(stderr, r > 0 ? "No audio in this file\n" : "Audio export failed\n");
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
