/*
 * OldDV Rescue - the files of one capture.
 *
 * A capture with re-read passes is a set of files next to each other:
 *   NAME.dv            the first pass, the whole tape
 *   NAME.retryN.dv     what re-read pass N got
 *   NAME.olddv         a short text file that lists them (written when the
 *                      merge is left for later)
 *   NAME.merged.dv     the result of the merge
 * The merge can be done at once on the Mac that captured, or later on any
 * machine that sees these files.
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static char *str_dup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *d = (char *)malloc(n);
    if (d)
        memcpy(d, s, n);
    return d;
}

static char *str_cat(const char *a, const char *b)
{
    size_t la = strlen(a), lb = strlen(b);
    char *d = (char *)malloc(la + lb + 1);
    if (d) {
        memcpy(d, a, la);
        memcpy(d + la, b, lb + 1);
    }
    return d;
}

static int ends_with(const char *s, size_t len, const char *suffix)
{
    size_t n = strlen(suffix);
    return len >= n && !strncmp(s + len - n, suffix, n);
}

/* a take must hold at least one NTSC frame */
static int usable_take(const char *path)
{
    struct stat st;
    return !stat(path, &st) && S_ISREG(st.st_mode) && st.st_size >= 120000;
}

static int add_take(dv_capture_set *set, char *path)
{
    char **t;
    if (!path)
        return -1;
    t = (char **)realloc(set->takes, (size_t)(set->ntakes + 1) * sizeof(char *));
    if (!t) {
        free(path);
        return -1;
    }
    set->takes = t;
    set->takes[set->ntakes++] = path;
    return 0;
}

/* NAME of "NAME.dv", "NAME.retry2.dv", "NAME.merged.dv", "NAME.olddv",
 * "NAME.log", "NAME.dv.dvrescue.xml"... */
static char *base_of(const char *path)
{
    char *b = str_dup(path);
    size_t n, i;
    int again = 1;
    if (!b)
        return NULL;
    n = strlen(b);
    while (again) {
        again = 0;
        if (ends_with(b, n, ".dvrescue.xml")) { n -= 13; again = 1; }
        else if (ends_with(b, n, ".olddv")) { n -= 6; }
        else if (ends_with(b, n, ".log")) { n -= 4; }
        else if (ends_with(b, n, ".merged.dv")) { n -= 10; }
        else if (ends_with(b, n, ".dv")) {
            n -= 3;
            /* .retryN */
            for (i = n; i > 0 && b[i - 1] >= '0' && b[i - 1] <= '9'; i--)
                ;
            if (i < n && i >= 6 && !strncmp(b + i - 6, ".retry", 6))
                n = i - 6;
        }
    }
    b[n] = 0;
    return b;
}

void dv_capture_free(dv_capture_set *set)
{
    int i;
    if (!set)
        return;
    for (i = 0; i < set->ntakes; i++)
        free(set->takes[i]);
    free(set->takes);
    free(set->base);
    free(set->merged);
    free(set->list);
    memset(set, 0, sizeof(*set));
}

int dv_capture_open(const char *path, dv_capture_set *set)
{
    size_t len = strlen(path);
    struct stat st;
    char num[32];
    char *p;
    int i;
    memset(set, 0, sizeof(*set));
    set->base = base_of(path);
    if (!set->base || !set->base[0])
        goto fail;
    set->merged = str_cat(set->base, ".merged.dv");
    set->list = str_cat(set->base, ".olddv");
    if (!set->merged || !set->list)
        goto fail;

    /* the list, when there is one: file names without folder, the files
     * are next to the list wherever the folder was moved */
    if (ends_with(path, len, ".olddv") || !stat(set->list, &st)) {
        FILE *fp = fopen(set->list, "r");
        char line[2048];
        const char *slash = strrchr(set->base, '/');
        size_t dirlen = slash ? (size_t)(slash - set->base) + 1 : 0;
        while (fp && fgets(line, sizeof(line), fp)) {
            size_t n = strlen(line);
            char *full;
            while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
                line[--n] = 0;
            if (strncmp(line, "take=", 5) || !line[5] || strchr(line + 5, '/'))
                continue;
            full = (char *)malloc(dirlen + n);
            if (!full) {
                fclose(fp);
                goto fail;
            }
            memcpy(full, set->base, dirlen);
            strcpy(full + dirlen, line + 5);
            if (!usable_take(full)) {
                set->missing++;
                free(full);
                continue;
            }
            if (add_take(set, full)) {
                fclose(fp);
                goto fail;
            }
        }
        if (fp) {
            fclose(fp);
            set->has_list = 1;
        }
    }
    /* no list: look for the files by name */
    if (!set->ntakes) {
        set->missing = 0;
        p = str_cat(set->base, ".dv");
        if (!p)
            goto fail;
        if (!usable_take(p)) {
            free(p);
            goto fail;
        }
        if (add_take(set, p))
            goto fail;
        for (i = 1; i < 100; i++) {
            snprintf(num, sizeof(num), ".retry%d.dv", i);
            p = str_cat(set->base, num);
            if (!p)
                goto fail;
            if (!usable_take(p)) {
                free(p);
                continue;
            }
            if (add_take(set, p))
                goto fail;
        }
    }
    set->merged_exists = !stat(set->merged, &st) && st.st_size > 0;
    return 0;
fail:
    dv_capture_free(set);
    return -1;
}

int dv_capture_write_list(const char *base, const char **takes, int n)
{
    char *path = str_cat(base, ".olddv");
    const char *s;
    FILE *fp;
    int i, r;
    if (!path)
        return -1;
    fp = fopen(path, "w");
    free(path);
    if (!fp)
        return -1;
    fprintf(fp, "OldDV Rescue capture\nversion=1\n");
    for (i = 0; i < n; i++) {
        s = strrchr(takes[i], '/');
        fprintf(fp, "take=%s\n", s ? s + 1 : takes[i]);
    }
    s = strrchr(base, '/');
    fprintf(fp, "output=%s.merged.dv\n", s ? s + 1 : base);
    fprintf(fp, "# The takes of this capture are not merged yet. Open this file with\n"
                "# OldDV Rescue (Merge Takes > Open Capture...) or run: olddv --finish THIS_FILE\n");
    r = ferror(fp) ? -1 : 0;
    if (fclose(fp))
        r = -1;
    return r;
}
