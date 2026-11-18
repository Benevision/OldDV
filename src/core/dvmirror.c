/*
 * OldDV Rescue - background copy of a file that is still being written.
 *
 * A capture goes to the local disk; a mirror copies it to its real
 * destination (a network share) while it grows. A share that stalls or
 * disappears never touches the capture: the copy waits and tries again,
 * and the local file stays complete whatever happens.
 */
#include "dvcore.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/time.h>

#define MIRROR_CHUNK (1u << 20)

struct dv_mirror {
    pthread_mutex_t mtx;
    pthread_t thread;
    char *src, *dst;
    int64_t copied;      /* bytes of src that are in dst */
    int64_t src_size;    /* last size seen */
    int complete;        /* src will not grow any more */
    int cancel;
    int state;           /* DV_MIRROR_... */
    int failures;        /* destination errors so far */
    int failing;         /* the last attempt failed */
    double last_progress;
    int refs;            /* owner + thread */
};

static double mono_s(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + tv.tv_usec / 1e6;
}

static void mirror_unref(dv_mirror *m)
{
    int left;
    pthread_mutex_lock(&m->mtx);
    left = --m->refs;
    pthread_mutex_unlock(&m->mtx);
    if (!left) {
        pthread_mutex_destroy(&m->mtx);
        free(m->src);
        free(m->dst);
        free(m);
    }
}

/* sleeps up to `seconds`, returns 1 when cancelled */
static int mirror_wait(dv_mirror *m, double seconds)
{
    double t0 = mono_s();
    for (;;) {
        int c;
        pthread_mutex_lock(&m->mtx);
        c = m->cancel;
        pthread_mutex_unlock(&m->mtx);
        if (c)
            return 1;
        if (mono_s() - t0 >= seconds)
            return 0;
        usleep(100000);
    }
}

static void *mirror_main(void *arg)
{
    dv_mirror *m = (dv_mirror *)arg;
    uint8_t *buf = (uint8_t *)malloc(MIRROR_CHUNK);
    int in = -1, out = -1, result = DV_MIRROR_FAILED;

    if (!buf)
        goto done;
    for (;;) {
        struct stat st;
        int64_t off, size;
        int complete;
        ssize_t n, w;

        pthread_mutex_lock(&m->mtx);
        if (m->cancel) {
            pthread_mutex_unlock(&m->mtx);
            result = DV_MIRROR_CANCELLED;
            break;
        }
        complete = m->complete;
        off = m->copied;
        pthread_mutex_unlock(&m->mtx);

        if (in < 0 && (in = open(m->src, O_RDONLY)) < 0) {
            if (complete)
                break; /* the source never existed */
            if (mirror_wait(m, 0.5)) { result = DV_MIRROR_CANCELLED; break; }
            continue;
        }
        if (fstat(in, &st))
            break;
        size = (int64_t)st.st_size;
        pthread_mutex_lock(&m->mtx);
        m->src_size = size;
        pthread_mutex_unlock(&m->mtx);

        if (out < 0) {
            /* (re)connect to the destination. After a failure the server may
             * have lost what it had not stored yet: continue from what the
             * destination really holds, and never past it. */
            struct stat ds;
            out = open(m->dst, O_WRONLY | O_CREAT, 0644);
            if (out >= 0 && fstat(out, &ds)) {
                close(out);
                out = -1;
            }
            if (out < 0) {
                pthread_mutex_lock(&m->mtx);
                if (!m->failing) { m->failing = 1; m->failures++; }
                pthread_mutex_unlock(&m->mtx);
                if (mirror_wait(m, 3)) { result = DV_MIRROR_CANCELLED; break; }
                continue;
            }
            if ((int64_t)ds.st_size < off) {
                off = (int64_t)ds.st_size;
                pthread_mutex_lock(&m->mtx);
                m->copied = off;
                pthread_mutex_unlock(&m->mtx);
            }
        }

        if (off >= size) {
            if (complete) {
                /* everything is there: cut off anything left from an older
                 * attempt and make sure it is stored */
                if (ftruncate(out, size) || fsync(out) || close(out)) {
                    out = -1;
                    pthread_mutex_lock(&m->mtx);
                    if (!m->failing) { m->failing = 1; m->failures++; }
                    pthread_mutex_unlock(&m->mtx);
                    if (mirror_wait(m, 3)) { result = DV_MIRROR_CANCELLED; break; }
                    continue;
                }
                out = -1;
                result = DV_MIRROR_DONE;
                break;
            }
            if (mirror_wait(m, 0.25)) { result = DV_MIRROR_CANCELLED; break; }
            continue;
        }

        n = pread(in, buf, (size_t)(size - off > (int64_t)MIRROR_CHUNK ? (int64_t)MIRROR_CHUNK : size - off), (off_t)off);
        if (n < 0)
            break; /* the local file cannot be read: nothing to retry */
        if (n == 0) {
            if (mirror_wait(m, 0.25)) { result = DV_MIRROR_CANCELLED; break; }
            continue;
        }
        w = pwrite(out, buf, (size_t)n, (off_t)off);
        if (w != n) {
            close(out);
            out = -1;
            pthread_mutex_lock(&m->mtx);
            if (!m->failing) { m->failing = 1; m->failures++; }
            pthread_mutex_unlock(&m->mtx);
            if (mirror_wait(m, 3)) { result = DV_MIRROR_CANCELLED; break; }
            continue;
        }
        pthread_mutex_lock(&m->mtx);
        m->copied = off + n;
        m->failing = 0;
        m->last_progress = mono_s();
        pthread_mutex_unlock(&m->mtx);
    }
done:
    if (in >= 0) close(in);
    if (out >= 0) close(out);
    free(buf);
    pthread_mutex_lock(&m->mtx);
    m->state = result;
    pthread_mutex_unlock(&m->mtx);
    mirror_unref(m);
    return NULL;
}

dv_mirror *dv_mirror_start(const char *src, const char *dst)
{
    dv_mirror *m = (dv_mirror *)calloc(1, sizeof(dv_mirror));
    pthread_attr_t at;
    if (!m)
        return NULL;
    m->src = strdup(src);
    m->dst = strdup(dst);
    if (!m->src || !m->dst) {
        free(m->src);
        free(m->dst);
        free(m);
        return NULL;
    }
    pthread_mutex_init(&m->mtx, NULL);
    m->state = DV_MIRROR_RUNNING;
    m->last_progress = mono_s();
    m->refs = 2;
    /* detached: a write to a share that hangs for good can never be joined */
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&m->thread, &at, mirror_main, m)) {
        pthread_attr_destroy(&at);
        pthread_mutex_destroy(&m->mtx);
        free(m->src);
        free(m->dst);
        free(m);
        return NULL;
    }
    pthread_attr_destroy(&at);
    return m;
}

void dv_mirror_complete(dv_mirror *m)
{
    pthread_mutex_lock(&m->mtx);
    m->complete = 1;
    pthread_mutex_unlock(&m->mtx);
}

int dv_mirror_status(dv_mirror *m, dv_mirror_info *info)
{
    int s;
    pthread_mutex_lock(&m->mtx);
    s = m->state;
    if (info) {
        info->copied = m->copied;
        info->source_size = m->src_size;
        info->failures = m->failures;
        info->failing = m->failing;
        info->seconds_idle = (m->state == DV_MIRROR_RUNNING && m->copied < m->src_size) ? mono_s() - m->last_progress : 0;
    }
    pthread_mutex_unlock(&m->mtx);
    return s;
}

void dv_mirror_free(dv_mirror *m)
{
    if (!m)
        return;
    pthread_mutex_lock(&m->mtx);
    m->cancel = 1;
    pthread_mutex_unlock(&m->mtx);
    mirror_unref(m);
}

/* 0: identical, 1: different (size or content), -1: cannot read, 2: cancelled */
int dv_files_identical(const char *a, const char *b, dv_progress_cb progress, void *ctx)
{
    int fa = open(a, O_RDONLY), fb = open(b, O_RDONLY), ret = -1;
    uint8_t *ba = (uint8_t *)malloc(MIRROR_CHUNK), *bb = (uint8_t *)malloc(MIRROR_CHUNK);
    struct stat sa, sb;
    int64_t off = 0;
    if (fa < 0 || fb < 0 || !ba || !bb || fstat(fa, &sa) || fstat(fb, &sb))
        goto out;
    if (sa.st_size != sb.st_size) {
        ret = 1;
        goto out;
    }
    for (;;) {
        ssize_t na = read(fa, ba, MIRROR_CHUNK), nb, got = 0;
        if (na < 0)
            goto out;
        while (got < na) {
            nb = read(fb, bb + got, (size_t)(na - got));
            if (nb < 0)
                goto out;
            if (nb == 0) {
                ret = 1;
                goto out;
            }
            got += nb;
        }
        if (na == 0) {
            ret = 0;
            break;
        }
        if (memcmp(ba, bb, (size_t)na)) {
            ret = 1;
            break;
        }
        off += na;
        if (progress && progress(ctx, sa.st_size ? (double)off / (double)sa.st_size : 1.0)) {
            ret = 2;
            break;
        }
    }
out:
    if (fa >= 0) close(fa);
    if (fb >= 0) close(fb);
    free(ba);
    free(bb);
    return ret;
}
