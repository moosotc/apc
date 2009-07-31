/* cc -o hog hog.c */
#define _POSIX_PTHREAD_SEMANTICS
#include <time.h>
#include <stdio.h>
#include <errno.h>
#include <stdarg.h>
#include <string.h>
#include <limits.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/time.h>

#define HIST 10

static volatile sig_atomic_t stop;

static void sighandler (int signr)
{
    (void) signr;
    stop = 1;
}

static unsigned long hog (unsigned long niters)
{
    stop = 0;
    while (!stop && --niters)
        ;
    return niters;
}

static void err (int status, const char *fmt, ...)
{
    va_list ap;
    int errno_code = errno;

    va_start (ap, fmt);
    vfprintf (stderr, fmt, ap);
    va_end (ap);
    fprintf (stderr, ": %s\n", strerror (errno_code));
    exit (status);
}

int main (int argc, char **argv)
{
    unsigned int i;
    struct itimerval it;
    struct sigaction act;
    sigset_t set;
    unsigned long v[HIST];
    double tmp = 0.0;
    unsigned long n;
    long divisor;

    if (argc > 1) {
        char *endptr;

        errno = 0;
        divisor = strtol (argv[1], &endptr, 0);
        if ((endptr && *endptr)
            || (errno == ERANGE && (divisor == LONG_MAX || divisor == LONG_MIN))
            || (errno && divisor == 0)) {
            err (EXIT_FAILURE, "Can't read `%s' as integer", argv[1]);
        }
    }
    else {
        divisor = 250;
    }

    act.sa_handler = sighandler;
    if (sigemptyset (&act.sa_mask)) {
        err (EXIT_FAILURE, "sigemptyset failed");
    }
    act.sa_flags = 0;

    it.it_interval.tv_sec = 0;
    it.it_interval.tv_usec = 1000000 / divisor;
    it.it_value.tv_sec = 0;
    it.it_value.tv_usec = 1000000 / divisor;

    if (sigaction (SIGALRM, &act, NULL)) {
        err (EXIT_FAILURE, "sigaction failed");
    }

    if (setitimer (ITIMER_REAL, &it, NULL)) {
        err (EXIT_FAILURE, "setitimer failed");
    }

    hog (ULONG_MAX);
    for (i = 0; i < HIST; ++i) {
        v[i] = ULONG_MAX - hog (ULONG_MAX);
    }

    for (i = 0; i < HIST; ++i) {
        printf ("%d = %ld\n", i, v[i]);
        tmp += v[i];
    }
    tmp /= HIST;
    n = tmp - (tmp / 3);

    if (sigemptyset (&set)) {
        err (EXIT_FAILURE, "sigemptyset failed");
    }

    if (sigaddset (&set, SIGALRM)) {
        err (EXIT_FAILURE, "sigaddset failed");
    }

    for (;;) {
        int signr;

        hog (n);
        if (sigwait (&set, &signr)) {
            err (EXIT_FAILURE, "sigwait failed");
        }
    }
}
