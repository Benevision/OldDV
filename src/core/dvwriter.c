/*
 * OldDV Rescue - buffered background file writer.
 *
 * Capture data arrives at a fixed rate (3.6 MB/s for DV) and cannot wait.
 * Writing to a network share (NFS / SMB on a NAS such as Unraid) can stall
 * for seconds, which would make the capture callback block and frames be
 * dropped. The writer copies data into a large ring buffer (default
 * 256 MB = about 70 s of DV) that a separate thread flushes to the file.
 */
#include "dvcore.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct dv_writer {
    FILE *fp;
    uint8_t *ring;
    size_t cap, head, len;     /* head = read position, len = bytes queued */
    size_t peak;
    int error, closing;      /* error: write failed (disk full / share gone) */
    uint64_t dropped;        /* bytes refused because the buffer was full */
    uint64_t written;
    pthread_mutex_t mtx;
    pthread_cond_t has_data, has_room;
    pthread_t thread;
};

static void *writer_main(void *arg)
{
    dv_writer *w = (dv_writer *)arg;
    pthread_mutex_lock(&w->mtx);
    for (;;) {
        size_t n;
        uint8_t *p;
        while (!w->len && !w->closing)
            pthread_cond_wait(&w->has_data, &w->mtx);
        if (!w->len && w->closing)
            break;
        n = w->len;
        if (n > w->cap - w->head)
            n = w->cap - w->head; /* contiguous part */
        if (n > (4u << 20))
            n = 4u << 20;
        p = w->ring + w->head;
        pthread_mutex_unlock(&w->mtx);
        /* the slow part happens without the lock */
        if (!w->error && fwrite(p, 1, n, w->fp) != n)
            w->error = 1;
        if (!w->error && w->len == n && fflush(w->fp))
            w->error = 1;
        pthread_mutex_lock(&w->mtx);
        w->head = (w->head + n) % w->cap;
        w->len -= n;
        w->written += n;
        pthread_cond_broadcast(&w->has_room);
    }
    pthread_mutex_unlock(&w->mtx);
    return NULL;
}

dv_writer *dv_writer_open(const char *path, size_t buffer_bytes)
{
    dv_writer *w = (dv_writer *)calloc(1, sizeof(dv_writer));
    if (!w)
        return NULL;
    w->cap = buffer_bytes ? buffer_bytes : (256u << 20);
    w->ring = (uint8_t *)malloc(w->cap);
    w->fp = fopen(path, "wb");
    if (!w->ring || !w->fp) {
        if (w->fp)
            fclose(w->fp);
        free(w->ring);
        free(w);
        return NULL;
    }
    setvbuf(w->fp, NULL, _IOFBF, 1 << 20);
    pthread_mutex_init(&w->mtx, NULL);
    pthread_cond_init(&w->has_data, NULL);
    pthread_cond_init(&w->has_room, NULL);
    if (pthread_create(&w->thread, NULL, writer_main, w)) {
        fclose(w->fp);
        free(w->ring);
        free(w);
        return NULL;
    }
    return w;
}

int dv_writer_write(dv_writer *w, const void *data, size_t size)
{
    const uint8_t *d = (const uint8_t *)data;
    int ret = 0;
    pthread_mutex_lock(&w->mtx);
    if (w->error) {
        ret = -1;
    } else if (w->len + size > w->cap) {
        /* buffer full: the destination is far too slow. Callers write whole
         * DV frames, so dropping this one keeps the file aligned. */
        w->dropped += size;
        ret = 1;
    } else {
        size_t tail = (w->head + w->len) % w->cap;
        size_t first = size < w->cap - tail ? size : w->cap - tail;
        memcpy(w->ring + tail, d, first);
        memcpy(w->ring, d + first, size - first);
        w->len += size;
        if (w->len > w->peak)
            w->peak = w->len;
        pthread_cond_signal(&w->has_data);
    }
    pthread_mutex_unlock(&w->mtx);
    return ret;
}

size_t dv_writer_pending(dv_writer *w)
{
    size_t n;
    pthread_mutex_lock(&w->mtx);
    n = w->len;
    pthread_mutex_unlock(&w->mtx);
    return n;
}

size_t dv_writer_peak(dv_writer *w) { return w->peak; }
int dv_writer_error(dv_writer *w) { return w->error ? 1 : (w->dropped ? 2 : 0); }
uint64_t dv_writer_dropped(dv_writer *w) { return w->dropped; }

int dv_writer_close(dv_writer *w)
{
    int ret;
    if (!w)
        return -1;
    pthread_mutex_lock(&w->mtx);
    w->closing = 1;
    pthread_cond_signal(&w->has_data);
    pthread_mutex_unlock(&w->mtx);
    pthread_join(w->thread, NULL);
    if (fclose(w->fp) && !w->error)
        w->error = 1;
    ret = w->error ? -1 : (w->dropped ? 1 : 0);
    pthread_mutex_destroy(&w->mtx);
    pthread_cond_destroy(&w->has_data);
    pthread_cond_destroy(&w->has_room);
    free(w->ring);
    free(w);
    return ret;
}
