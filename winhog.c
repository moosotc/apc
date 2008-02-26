#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>

#define NITERS 10
static volatile stop;

static DWORD_PTR hog (DWORD_PTR count)
{
    DWORD_PTR i = 0;
    while (i < count && !stop) ++i;
    return i;
}

static void CALLBACK timer_callback (
    UINT uTimerID,
    UINT uMsg,
    DWORD_PTR dwUser,
    DWORD_PTR dw1,
    DWORD_PTR dw2
    )
{
    if (!dwUser)
        stop = 1;
    else {
        stop = 0;
        hog (dwUser);
    }
}

static UINT settimer (DWORD_PTR val)
{
    MMRESULT mr;

    mr = timeSetEvent (1, 0, timer_callback, val,
                       TIME_PERIODIC | TIME_CALLBACK_FUNCTION);
    if (!mr) {
        fprintf (stderr, "timeSetEvent failed: %ld\n", GetLastError ());
        exit (EXIT_FAILURE);
    }
    return mr;
}

int main (int argc, char **argv)
{
    int i, mini, maxi;
    UINT id;
    MMRESULT mr;
    DWORD prevmask, wr;
    DWORD_PTR est[NITERS];
    double d;
    DWORD_PTR mask;

    if (argc > 1)
        mask = atoi (argv[1]);
    else
        mask = 1;

    prevmask = SetProcessAffinityMask (GetCurrentProcess (), mask);
    if (!prevmask) {
        fprintf (stderr, "SetProcessAffinityMask failed: %ld\n", GetLastError ());
        exit (EXIT_FAILURE);
    }
    id = settimer (0);

    for (i = 0; i < NITERS; ++i) {
        stop = 0;
        est[i] = hog ((DWORD_PTR) 0 - 1);
    }

    mr = timeKillEvent (id);
    if (mr != TIMERR_NOERROR) {
        fprintf (stderr, "timeKillEvent failed: %ld\n", GetLastError ());
        exit (EXIT_FAILURE);
    }

    mini = 0;
    maxi = 0;

    for (i = 0; i < NITERS; ++i) {
        if (est[i] < est[mini]) mini = i;
        if (est[i] > est[maxi]) maxi = i;
    }

    d = 0.0;
    for (i = 0; i < NITERS; ++i) {
        fprintf (stderr, "%f\n", (double) est[i]);
        if (i == mini || i == maxi) continue;
        d += est[i];
    }
    d = d / (NITERS - 2);
    d = d - d / 10;
    fprintf (stderr, "%f\n", d);

    settimer (d);

    Sleep (INFINITE);
    return 0;
}
