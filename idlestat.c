#define _GNU_SOURCE
#include <err.h>
#include <time.h>
#include <stdio.h>
#include <fcntl.h>
#include <alloca.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/sysinfo.h>

static double now (void)
{
    struct timeval tv;

    if (gettimeofday (&tv, NULL))
        err (1, "gettimeofday");
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

static void idlenow (int fd, int nprocs, double *p)
{
    struct timeval tv;
    size_t n = nprocs * sizeof (tv);
    ssize_t m;
    struct timeval *buf;
    int i;

    buf = alloca (n);
    if (!buf) errx (1, "alloca failed");

    m = read (fd, buf, n);
    if (n - m) err (1, "read [n=%zu, m=%zi]", n, m);

    for (i = 0; i < nprocs; ++i)
        p[i] = buf[i].tv_sec + buf[i].tv_usec * 1e-6;
}

int main (int argc, char **argv)
{
    int fd;
    int nprocs;
    double *idle;
    int flip = 0;
    double *curr, *prev;

    (void) argc;
    (void) argv;

    nprocs = get_nprocs ();
    if (nprocs <= 0) errx (1, "get_nprocs returned %d", nprocs);

    idle = malloc (2 * nprocs * sizeof (idle[0]));
    if (!idle) errx (1, "malloc %zu failed", 2 * nprocs * sizeof (idle[0]));

    fd = open ("/dev/itc", O_RDONLY);
    if (fd < 0) errx (1, "open /dev/itc");

    idlenow (fd, nprocs, idle);

    flip = 0;
    curr = &idle[nprocs];
    prev = idle;

    for (;;) {
        int i;
        double s, e, d, *t;

        s = now ();
        idlenow (fd, nprocs, prev);
        sleep (1);
        e = now ();
        d = e - s;
        idlenow (fd, nprocs, curr);

        for (i = 0; i < nprocs; ++i) {
            double di = curr[i] - prev[i];

            printf ("cpu%d load - %.2f%%\n", i, 100.0 * (1.0 - di / d));
        }

        t = curr;
        curr = prev;
        prev = t;
    }
}