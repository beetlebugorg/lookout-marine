/* stage0.c — pipeline smoke test for the Windows (Vulkan) chart core.
 *
 * The SMALLEST possible host: a plain Win32 top-level window whose client area
 * is handed straight to lookout as a VK_KHR_win32_surface. No WinUI, no NuGet,
 * no chrome — it exists only to prove, on this machine, that
 *   liblookout_marine.a + libtile57.a + vulkan-1.lib
 * link, that lookout_open_in_window() creates a Vulkan device and presents into
 * an HWND, and that pan/zoom/resize drive frames. Once this draws a chart, the
 * real C++/WinRT shell can host the same surface with confidence.
 *
 * Build: see windows/tools/build-stage0.ps1 (cl + the zig-out core).
 * Run:   stage0.exe [chart.pmtiles | folder-of-cells]   (else $LOOKOUT_OPEN,
 *        else the bundled android test cell if present).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

#include "lookout.h"

/* Sign-correct coordinate extractors (windowsx.h equivalents, kept local so the
 * smoke test pulls in nothing extra). LOWORD/HIWORD are unsigned; a point on a
 * left/top monitor is negative, so cast through short. */
#define GET_X_LPARAM_(lp) ((int) (short) LOWORD (lp))
#define GET_Y_LPARAM_(lp) ((int) (short) HIWORD (lp))

/* ---- one global handle; a smoke test needs no more structure -------------- */
static lookout *g_chart = NULL;
static int      g_dragging = 0;
static POINT    g_last_pt;               /* last drag point, pixels */
static LARGE_INTEGER g_qpc_freq, g_qpc_last;

/* Seconds since the previous call (0 on the first). */
static double
tick_dt (void)
{
  LARGE_INTEGER now;
  QueryPerformanceCounter (&now);
  if (g_qpc_last.QuadPart == 0)
    {
      g_qpc_last = now;
      return 0.0;
    }
  double dt = (double) (now.QuadPart - g_qpc_last.QuadPart) / (double) g_qpc_freq.QuadPart;
  g_qpc_last = now;
  if (dt > 0.05)
    dt = 0.05; /* cap after an idle gap so a resumed fling doesn't teleport */
  return dt;
}

/* Draw one frame when the view needs it or an animation is running. */
static void
pump_frame (void)
{
  if (g_chart == NULL)
    return;

  double dt = tick_dt ();
  int animating = lookout_animating (g_chart);
  if (animating)
    lookout_tick_anim (g_chart, dt);

  if (animating || lookout_needs_redraw (g_chart))
    lookout_render (g_chart);
}

static void
open_chart_for_hwnd (HWND hwnd)
{
  if (g_chart != NULL)
    return;

  RECT rc;
  GetClientRect (hwnd, &rc);
  uint32_t w = (uint32_t) (rc.right - rc.left);
  uint32_t h = (uint32_t) (rc.bottom - rc.top);
  if (w < 2 || h < 2)
    return; /* wait for a real size */

  /* Chart path: argv[1] (stashed in the window's userdata as a char*), then
   * $LOOKOUT_OPEN, then the android test cell that ships in the repo. */
  const char *path = (const char *) GetWindowLongPtrA (hwnd, GWLP_USERDATA);
  static char envbuf[1024];
  if (path == NULL || path[0] == '\0')
    {
      DWORD n = GetEnvironmentVariableA ("LOOKOUT_OPEN", envbuf, sizeof envbuf);
      if (n > 0 && n < sizeof envbuf)
        path = envbuf;
    }
  if (path == NULL || path[0] == '\0')
    path = "..\\..\\android\\app\\src\\main\\assets\\charts\\US5MD1MC.pmtiles";

  lookout_win32_window native = { .hinstance = GetModuleHandleA (NULL), .hwnd = hwnd };

  fprintf (stderr, "stage0: opening %s into a %ux%u HWND surface\n", path, w, h);
  g_chart = lookout_open_in_window (LOOKOUT_NATIVE_WIN32_HWND, &native, path, w, h, 1);
  if (g_chart == NULL)
    {
      MessageBoxA (hwnd,
                   "lookout_open_in_window returned NULL.\n"
                   "Either the chart path is wrong, or no Vulkan device could be created.",
                   "stage0: open failed", MB_ICONERROR | MB_OK);
      return;
    }

  /* One device pixel per logical point for the smoke test — DPI scaling is the
   * real shell's job. */
  lookout_set_pixel_density (g_chart, 1.0f);

  lookout_view v;
  lookout_fit_chart (g_chart, &v); /* frame the cell so the window shows the chart */
  lookout_set_view (g_chart, &v);

  SetTimer (hwnd, 1, 15, NULL); /* ~66 Hz pacemaker */
}

static LRESULT CALLBACK
wnd_proc (HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
  switch (msg)
    {
    case WM_SIZE:
      if (g_chart == NULL)
        open_chart_for_hwnd (hwnd);
      else
        {
          lookout_resize (g_chart, (uint32_t) LOWORD (lp), (uint32_t) HIWORD (lp));
          pump_frame ();
        }
      return 0;

    case WM_TIMER:
      pump_frame ();
      return 0;

    case WM_LBUTTONDOWN:
      g_dragging = 1;
      g_last_pt.x = GET_X_LPARAM_ (lp);
      g_last_pt.y = GET_Y_LPARAM_ (lp);
      if (g_chart)
        lookout_fling_start (g_chart, 0, 0); /* grabbing stops any coast */
      SetCapture (hwnd);
      return 0;

    case WM_MOUSEMOVE:
      if (g_dragging && g_chart)
        {
          int x = GET_X_LPARAM_ (lp), y = GET_Y_LPARAM_ (lp);
          lookout_pan_logical (g_chart, (float) (x - g_last_pt.x), (float) (y - g_last_pt.y));
          g_last_pt.x = x;
          g_last_pt.y = y;
          pump_frame ();
        }
      return 0;

    case WM_LBUTTONUP:
      g_dragging = 0;
      ReleaseCapture ();
      return 0;

    case WM_MOUSEWHEEL:
      if (g_chart)
        {
          POINT p = { GET_X_LPARAM_ (lp), GET_Y_LPARAM_ (lp) };
          ScreenToClient (hwnd, &p); /* wheel gives screen coords */
          double dz = (double) GET_WHEEL_DELTA_WPARAM (wp) / WHEEL_DELTA * 0.25;
          lookout_zoom_at_logical (g_chart, dz, (float) p.x, (float) p.y);
          pump_frame ();
        }
      return 0;

    case WM_ERASEBKGND:
      return 1; /* lookout owns every client pixel; never let GDI clear it */

    case WM_DESTROY:
      if (g_chart)
        {
          lookout_close (g_chart);
          g_chart = NULL;
        }
      PostQuitMessage (0);
      return 0;
    }
  return DefWindowProcA (hwnd, msg, wp, lp);
}

/* Headless validation: if $LOOKOUT_SNAP is set, render the chart OFFSCREEN (no
 * window) to that PNG path and exit. This proves the whole core path — Vulkan
 * device, tessellation, render, readback — on this machine without a visible
 * window, so it can be checked from a non-interactive shell. Returns 1 when it
 * handled the run (caller should exit), 0 to fall through to the windowed app. */
static int
try_headless_snapshot (void)
{
  char snap[1024];
  DWORD sn = GetEnvironmentVariableA ("LOOKOUT_SNAP", snap, sizeof snap);
  if (sn == 0 || sn >= sizeof snap)
    return 0;

  char path[1024];
  DWORD pn = GetEnvironmentVariableA ("LOOKOUT_OPEN", path, sizeof path);
  const char *chart = (pn > 0 && pn < sizeof path)
      ? path
      : "..\\..\\android\\app\\src\\main\\assets\\charts\\US5MD1MC.pmtiles";

  fprintf (stderr, "snap: opening %s offscreen\n", chart);
  lookout *h = lookout_open (chart, 1280, 800, 0 /*want_window*/, 1 /*msaa*/);
  if (h == NULL)
    {
      fprintf (stderr, "snap: lookout_open returned NULL (chart path or Vulkan device)\n");
      return 1;
    }

  lookout_view v;
  lookout_fit_chart (h, &v); /* frame the whole cell, not the z5 world view */
  lookout_set_view (h, &v);
  fprintf (stderr, "snap: fit view lon=%.4f lat=%.4f zoom=%.2f\n", v.lon, v.lat, v.zoom);
  lookout_build (h);

  int ok = lookout_snapshot_png (h, snap);
  fprintf (stderr, "snap: wrote %s -> %s (ok=%d)\n", chart, snap, ok);
  lookout_close (h);
  return 1;
}

int WINAPI
WinMain (HINSTANCE hInstance, HINSTANCE prev, LPSTR cmdline, int show)
{
  (void) prev;
  QueryPerformanceFrequency (&g_qpc_freq);

  if (try_headless_snapshot ())
    return 0;

  /* Per-monitor DPI aware so the client size we hand lookout is real pixels. */
  SetProcessDpiAwarenessContext (DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

  WNDCLASSA wc = { 0 };
  wc.lpfnWndProc = wnd_proc;
  wc.hInstance = hInstance;
  wc.hCursor = LoadCursor (NULL, IDC_ARROW);
  wc.lpszClassName = "LookoutStage0";
  RegisterClassA (&wc);

  HWND hwnd = CreateWindowExA (0, wc.lpszClassName, "Lookout Marine — stage0",
                               WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                               1280, 800, NULL, NULL, hInstance, NULL);

  /* Stash the command-line chart path (first token) for open_chart_for_hwnd. */
  SetWindowLongPtrA (hwnd, GWLP_USERDATA, (LONG_PTR) (cmdline && cmdline[0] ? cmdline : NULL));

  ShowWindow (hwnd, show);
  UpdateWindow (hwnd);

  MSG m;
  while (GetMessageA (&m, NULL, 0, 0))
    {
      TranslateMessage (&m);
      DispatchMessageA (&m);
    }
  return (int) m.wParam;
}

/* windowsx.h's GET_X_LPARAM etc. pull in more than the smoke test wants; these
 * are the same two-line extractors, sign-correct for multi-monitor. */
