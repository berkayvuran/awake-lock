#!/usr/bin/env python3
"""AwakeLock for Windows and Linux: a retro full-screen lock that keeps the computer awake.

Running the script locks every monitor immediately; bind it to a keyboard shortcut.
Standard library only (Linux needs the tkinter package, e.g. python3-tk).
"""
import ctypes
import getpass
import os
import random
import re
import subprocess
import sys
import time
import tkinter as tk
import tkinter.font as tkfont
from datetime import datetime

IS_WINDOWS = sys.platform == "win32"
IS_LINUX = sys.platform.startswith("linux")
# AWAKELOCK_TEST_SECONDS=N: draw the lock screen for N seconds without touching the OS (no
# keep-awake, keyboard blocking or input grab), then exit. Used to check the UI on any platform.
TEST_SECONDS = float(os.environ.get("AWAKELOCK_TEST_SECONDS", "0"))

GREEN = "#40ff73"
GREEN_DIM = "#1f8a3d"
GREEN_FAINT = "#124d23"
HEAD = "#ccffd9"
BG = "#030a05"
RED = "#ff4d4d"
PLEA_COLORS = [GREEN, "#ffb833", "#4de6ff", "#ff66d9"]
RAIN_GLYPHS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ@#$%&*+=<>"
MONO_FAMILIES = ["Consolas", "DejaVu Sans Mono", "Liberation Mono", "Ubuntu Mono", "Menlo", "Courier New", "Courier"]

JOKES = [
    "Önemli bir işin ortasındayım. Kapağı kapatırsan kalbim kırılır.",
    "Sahibim kahve almaya gitti, beni sorumlu bıraktı. Hiçbir şeye dokunma.",
    "Şşş... ajan düşünüyor. Hem de çok. Muhtemelen noktalı virgüller hakkında.",
    "Evet, ekran kilitli. Hayır, uyumuyorum. Çalışıyorum. Bazılarının aksine.",
    "Kapağı kapatırsan bir yerlerde bir build ağlar.",
    "Şu an kod yazıyorum. Alkışları sahibim toplayacak.",
    "Fişimi çekme. Düşüncelerimi henüz kaydetmedim.",
    "Bu bilgisayar şu an senden daha meşgul. Darılma.",
]
JOKE_SECONDS = 8
TR_DAYS = ["PAZARTESİ", "SALI", "ÇARŞAMBA", "PERŞEMBE", "CUMA", "CUMARTESİ", "PAZAR"]
TR_MONTHS = ["OCAK", "ŞUBAT", "MART", "NİSAN", "MAYIS", "HAZİRAN",
             "TEMMUZ", "AĞUSTOS", "EYLÜL", "EKİM", "KASIM", "ARALIK"]

TICK_MS = 50


# ---------------------------------------------------------------- keep awake

class KeepAwake:
    """Blocks idle sleep while locked; the display may still be kept on by the lock itself."""

    def __init__(self):
        self._inhibitor = None

    def start(self):
        if TEST_SECONDS:
            return
        if IS_WINDOWS:
            es_continuous, es_system, es_display = 0x80000000, 0x00000001, 0x00000002
            if not ctypes.windll.kernel32.SetThreadExecutionState(es_continuous | es_system | es_display):
                raise RuntimeError("SetThreadExecutionState failed")
        elif IS_LINUX:
            self._inhibitor = subprocess.Popen([
                "systemd-inhibit", "--what=sleep:idle", "--who=AwakeLock",
                "--why=Locked while work continues", "--mode=block", "sleep", "infinity"])
            time.sleep(0.3)
            if self._inhibitor.poll() is not None:
                raise RuntimeError("systemd-inhibit exited with code %s" % self._inhibitor.returncode)

    def stop(self):
        if TEST_SECONDS:
            return
        if IS_WINDOWS:
            ctypes.windll.kernel32.SetThreadExecutionState(0x80000000)
        elif self._inhibitor and self._inhibitor.poll() is None:
            self._inhibitor.terminate()


# ---------------------------------------------------------------- password check

def check_password(password):
    user = getpass.getuser()
    if IS_WINDOWS:
        return _check_windows(user, password)
    if IS_LINUX:
        return _check_pam(user, password)
    return False


def _check_windows(user, password):
    from ctypes import wintypes
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    token = wintypes.HANDLE()
    domain = os.environ.get("USERDOMAIN") or "."
    logon32_logon_interactive, logon32_provider_default = 2, 0
    if advapi32.LogonUserW(user, domain, password, logon32_logon_interactive,
                           logon32_provider_default, ctypes.byref(token)):
        ctypes.windll.kernel32.CloseHandle(token)
        return True
    return False


def _check_pam(user, password, service="login"):
    from ctypes import CDLL, CFUNCTYPE, POINTER, Structure, byref, c_char_p, c_int, c_size_t, c_void_p, cast, sizeof
    from ctypes.util import find_library

    libpam = CDLL(find_library("pam"))
    libc = CDLL(find_library("c"))

    class PamHandle(Structure):
        _fields_ = [("handle", c_void_p)]

    class PamMessage(Structure):
        _fields_ = [("msg_style", c_int), ("msg", c_char_p)]

    class PamResponse(Structure):
        _fields_ = [("resp", c_void_p), ("resp_retcode", c_int)]

    conv_func = CFUNCTYPE(c_int, c_int, POINTER(POINTER(PamMessage)), POINTER(POINTER(PamResponse)), c_void_p)

    class PamConv(Structure):
        _fields_ = [("conv", conv_func), ("appdata_ptr", c_void_p)]

    libc.calloc.restype = c_void_p
    libc.calloc.argtypes = [c_size_t, c_size_t]
    libc.strdup.restype = c_void_p
    libc.strdup.argtypes = [c_char_p]
    libpam.pam_start.argtypes = [c_char_p, c_char_p, POINTER(PamConv), POINTER(PamHandle)]
    libpam.pam_authenticate.argtypes = [PamHandle, c_int]
    libpam.pam_end.argtypes = [PamHandle, c_int]

    secret = password.encode()
    pam_prompt_echo_off = 1

    def answer(count, messages, responses, _appdata):
        # PAM frees the responses, so they must be allocated with the C allocator.
        responses[0] = cast(libc.calloc(count, sizeof(PamResponse)), POINTER(PamResponse))
        for i in range(count):
            if messages[i].contents.msg_style == pam_prompt_echo_off:
                responses[0][i].resp = libc.strdup(secret)
        return 0

    callback = conv_func(answer)
    handle = PamHandle()
    if libpam.pam_start(service.encode(), user.encode(), byref(PamConv(callback, None)), byref(handle)) != 0:
        return False
    result = libpam.pam_authenticate(handle, 0)
    libpam.pam_end(handle, result)
    return result == 0


# ---------------------------------------------------------------- Windows keyboard blocker

class KeyboardBlocker:
    """Windows low-level keyboard hook: swallows Win, Alt+Tab, Alt+Esc, Alt+F4 and Ctrl+Esc.
    Ctrl+Alt+Del cannot be blocked by design. The hook runs on Tk's own message loop."""

    def __init__(self):
        self._hook = None
        self._callback = None

    def start(self):
        if not IS_WINDOWS or TEST_SECONDS:
            return
        from ctypes import wintypes
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class KbdLLHookStruct(ctypes.Structure):
            _fields_ = [("vkCode", wintypes.DWORD), ("scanCode", wintypes.DWORD), ("flags", wintypes.DWORD),
                        ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

        hook_proc = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
        user32.SetWindowsHookExW.argtypes = [ctypes.c_int, hook_proc, wintypes.HINSTANCE, wintypes.DWORD]
        user32.SetWindowsHookExW.restype = wintypes.HHOOK
        user32.CallNextHookEx.argtypes = [wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
        user32.CallNextHookEx.restype = ctypes.c_ssize_t
        user32.UnhookWindowsHookEx.argtypes = [wintypes.HHOOK]
        kernel32.GetModuleHandleW.restype = wintypes.HMODULE

        vk_tab, vk_escape, vk_f4, vk_lwin, vk_rwin, vk_control = 0x09, 0x1B, 0x73, 0x5B, 0x5C, 0x11
        llkhf_altdown = 0x20

        def on_key(code, w_param, l_param):
            if code == 0:
                key = ctypes.cast(l_param, ctypes.POINTER(KbdLLHookStruct)).contents
                alt = key.flags & llkhf_altdown
                ctrl = user32.GetAsyncKeyState(vk_control) & 0x8000
                if (key.vkCode in (vk_lwin, vk_rwin)
                        or (alt and key.vkCode in (vk_tab, vk_escape, vk_f4))
                        or (ctrl and key.vkCode == vk_escape)):
                    return 1
            return user32.CallNextHookEx(self._hook, code, w_param, l_param)

        self._callback = hook_proc(on_key)
        self._user32 = user32
        self._hook = user32.SetWindowsHookExW(13, self._callback, kernel32.GetModuleHandleW(None), 0)  # WH_KEYBOARD_LL
        if not self._hook:
            raise OSError("SetWindowsHookExW failed: %d" % ctypes.get_last_error())

    def stop(self):
        if self._hook:
            self._user32.UnhookWindowsHookEx(self._hook)
            self._hook = None


# ---------------------------------------------------------------- monitors

def list_monitors(root):
    """(x, y, width, height) per monitor, primary first."""
    monitors = []
    if IS_WINDOWS:
        from ctypes import wintypes
        enum_proc = ctypes.WINFUNCTYPE(ctypes.c_int, wintypes.HMONITOR, wintypes.HDC,
                                       ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)

        def collect(_monitor, _hdc, rect, _data):
            r = rect.contents
            monitors.append((r.left, r.top, r.right - r.left, r.bottom - r.top))
            return 1

        ctypes.windll.user32.EnumDisplayMonitors(None, None, enum_proc(collect), 0)
        monitors.sort(key=lambda m: (m[0], m[1]) != (0, 0))
    elif IS_LINUX:
        try:
            output = subprocess.run(["xrandr", "--listmonitors"], capture_output=True, text=True, check=True).stdout
            for line in output.splitlines()[1:]:
                match = re.search(r"(\d+)/\d+x(\d+)/\d+\+(-?\d+)\+(-?\d+)", line)
                if match:
                    w, h, x, y = map(int, match.groups())
                    entry = (x, y, w, h)
                    monitors.insert(0, entry) if "*" in line.split()[1] else monitors.append(entry)
        except (OSError, subprocess.CalledProcessError):
            monitors = []
    return monitors or [(0, 0, root.winfo_screenwidth(), root.winfo_screenheight())]


# ---------------------------------------------------------------- lock screen

def turkish_date(now):
    return "%d %s %d %s" % (now.day, TR_MONTHS[now.month - 1], now.year, TR_DAYS[now.weekday()])


class LockScreen:
    def __init__(self, app, window, geometry, primary):
        x, y, w, h = geometry
        self.app = app
        self.w, self.h = w, h
        self.s = s = h / 1080
        window.overrideredirect(True)
        window.geometry("%dx%d%+d%+d" % (w, h, x, y))
        window.configure(bg=BG)
        window.attributes("-topmost", True)
        window.protocol("WM_DELETE_WINDOW", lambda: None)
        self.window = window

        c = self.canvas = tk.Canvas(window, width=w, height=h, bg=BG, highlightthickness=0, bd=0)
        c.pack(fill="both", expand=True)

        self._build_rain()

        # Header
        pad = int(40 * s)
        c.create_rectangle(pad, int(34 * s), w - pad, int(88 * s), fill=BG, outline=GREEN_DIM)
        header_y = int(61 * s)
        prompt = "C:\\AWAKELOCK> SİSTEM KİLİTLİ"
        self.prompt = c.create_text(pad + int(18 * s), header_y, text=prompt + "█", fill=GREEN,
                                    font=self.font(18, "bold"), anchor="w")
        self.prompt_text = prompt
        self.date = c.create_text(w - pad - int(18 * s), header_y, text="", fill=GREEN,
                                  font=self.font(18, "bold"), anchor="e")

        # Center: clock + progress
        cw, ch = int(820 * s), int(340 * s)
        cx0, cy0 = (w - cw) // 2, (h - ch) // 2
        c.create_rectangle(cx0, cy0, cx0 + cw, cy0 + ch, fill=BG, outline=GREEN, width=max(1, int(2 * s)))
        self.clock = c.create_text(w // 2, cy0 + int(140 * s), text="", fill=GREEN, font=self.font(190, "bold"))
        bar_w, bar_h = int(320 * s), int(22 * s)
        label_font = self.font(22, "bold")
        label_w = tkfont.Font(font=label_font).measure("AJAN ÇALIŞIYOR")
        bx = (w - (bar_w + int(24 * s) + label_w)) // 2
        by = cy0 + ch - int(62 * s)
        c.create_rectangle(bx, by, bx + bar_w, by + bar_h, fill=GREEN_FAINT, outline=GREEN, width=max(1, int(2 * s)))
        self.bar_box = (bx + int(4 * s), by + int(4 * s), bx + bar_w - int(4 * s), by + bar_h - int(4 * s))
        self.bar = c.create_rectangle(*self.bar_box, fill=GREEN, outline="")
        c.create_text(bx + bar_w + int(24 * s), by + bar_h // 2, text="AJAN ÇALIŞIYOR", fill=GREEN,
                      font=label_font, anchor="w")

        # Footer: typewriter joke, password, elapsed
        fy0, fy1 = h - int(150 * s), h - int(34 * s)
        c.create_rectangle(pad, fy0, w - pad, fy1, fill=BG, outline=GREEN_DIM)
        self.joke = c.create_text(pad + int(18 * s), fy0 + int(32 * s), text="", fill=GREEN,
                                  font=self.font(20), anchor="w")
        row_y = fy1 - int(36 * s)
        self.elapsed = c.create_text(w - pad - int(18 * s), row_y, text="", fill=GREEN_DIM,
                                     font=self.font(16), anchor="e")
        self.entry = None
        self.error = None
        if primary:
            field_font = self.font(18, "bold")
            label = c.create_text(pad + int(18 * s), row_y, text="> ŞİFRE:", fill=GREEN, font=field_font, anchor="w")
            entry_x = c.bbox(label)[2] + int(16 * s)
            self.entry = tk.Entry(window, show="*", font=field_font, width=20, bg=BG, fg=GREEN,
                                  insertbackground=GREEN, relief="flat", highlightthickness=1,
                                  highlightbackground=GREEN_DIM, highlightcolor=GREEN,
                                  disabledbackground=BG)
            self.entry.bind("<Return>", app.submit)
            c.create_window(entry_x, row_y, window=self.entry, anchor="w")
            self.error = c.create_text(entry_x + int(320 * s), row_y, text="", fill=RED, font=field_font, anchor="w")

        self._build_plea()

        # CRT overlay: scanlines and double border, drawn once on top of everything.
        for line_y in range(0, h, 3):
            c.create_line(0, line_y, w, line_y, fill="#000000")
        for inset in (12, 18):
            i = int(inset * s)
            c.create_rectangle(i, i, w - i, h - i, outline=GREEN, width=max(1, int(2 * s)))

        self._last = {}

    def font(self, px, weight="normal"):
        return (self.app.mono, -max(8, int(px * self.s)), weight)

    def _build_rain(self):
        self.cell = cell = max(12, int(26 * self.s))
        rain_font = self.font(17, "bold")
        self.line_height = tkfont.Font(font=rain_font).metrics("linespace")
        self.columns = []
        for col in range(self.w // cell + 1):
            if random.random() < 0.4:
                continue
            x = col * cell + cell // 2
            y = random.randint(-self.h, self.h)
            tail = self.canvas.create_text(x, y, text="", fill=GREEN_DIM, font=rain_font, anchor="s")
            head = self.canvas.create_text(x, y, text=random.choice(RAIN_GLYPHS), fill=HEAD, font=rain_font, anchor="n")
            column = {"tail": tail, "head": head, "y": y, "every": random.randint(1, 3)}
            self._reset_column(column, keep_y=True)
            self.columns.append(column)

    def _reset_column(self, column, keep_y=False):
        length = random.randint(6, 18)
        self.canvas.itemconfigure(column["tail"], text="\n".join(random.choice(RAIN_GLYPHS) for _ in range(length)))
        column["length"] = length
        if not keep_y:
            column["y"] = -random.randint(0, self.h // 2)
        self.canvas.coords(column["tail"], self.canvas.coords(column["tail"])[0], column["y"])
        self.canvas.coords(column["head"], self.canvas.coords(column["head"])[0], column["y"])

    def _build_plea(self):
        s = self.s
        self.plea_w, self.plea_h = int(500 * s), int(70 * s)
        x, y = random.randint(0, self.w - self.plea_w), random.randint(0, self.h - self.plea_h)
        self.plea_box = self.canvas.create_rectangle(x, y, x + self.plea_w, y + self.plea_h, fill=BG,
                                                     outline=GREEN, width=max(1, int(3 * s)), tags="plea")
        self.plea_text = self.canvas.create_text(x + self.plea_w // 2, y + self.plea_h // 2,
                                                 text="LÜTFEN BENİ KAPATMA!", fill=GREEN,
                                                 font=self.font(32, "bold"), tags="plea")
        self.plea_pos = [x, y]
        self.plea_v = [7 * s * random.choice((1, -1)), 4.75 * s * random.choice((1, -1))]
        self.plea_color = 0

    def _set(self, item, key, **options):
        """Only touch the canvas when a value really changed."""
        value = tuple(sorted(options.items()))
        if self._last.get(key) != value:
            self._last[key] = value
            self.canvas.itemconfigure(item, **options)

    def tick(self, now, tick_count):
        t = time.time()
        blink = int(t * 2) % 2 == 0
        c = self.canvas

        # Bouncing plea (every tick)
        hit = False
        for axis, limit in ((0, self.w - self.plea_w), (1, self.h - self.plea_h)):
            self.plea_pos[axis] += self.plea_v[axis]
            if not 0 <= self.plea_pos[axis] <= limit:
                self.plea_pos[axis] = min(max(self.plea_pos[axis], 0), limit)
                self.plea_v[axis] = -self.plea_v[axis]
                hit = True
        bx0 = c.coords(self.plea_box)
        c.move("plea", self.plea_pos[0] - bx0[0], self.plea_pos[1] - bx0[1])
        if hit:
            self.plea_color = (self.plea_color + 1) % len(PLEA_COLORS)
            color = PLEA_COLORS[self.plea_color]
            c.itemconfigure(self.plea_box, outline=color)
            c.itemconfigure(self.plea_text, fill=color)

        # Rain
        for column in self.columns:
            if tick_count % (column["every"] + 1):
                continue
            column["y"] += self.line_height
            c.move(column["tail"], 0, self.line_height)
            c.move(column["head"], 0, self.line_height)
            if tick_count % 6 == 0:
                c.itemconfigure(column["head"], text=random.choice(RAIN_GLYPHS))
            if column["y"] - column["length"] * self.line_height > self.h:
                self._reset_column(column)

        # Text
        joke = JOKES[int(t / JOKE_SECONDS) % len(JOKES)]
        typed = joke[:int((t % JOKE_SECONDS) * 25)]
        self._set(self.joke, "joke", text="> " + typed + ("█" if blink else " "))
        self._set(self.prompt, "prompt", text=self.prompt_text + ("█" if blink else " "))
        self._set(self.clock, "clock", text=now.strftime("%H:%M") if blink else now.strftime("%H %M"))
        self._set(self.date, "date", text=turkish_date(now))
        seconds = int(t - self.app.locked_at)
        if seconds >= 3600:
            elapsed = "KİLİTLİ SÜRE: %d:%02d:%02d" % (seconds // 3600, seconds // 60 % 60, seconds % 60)
        else:
            elapsed = "KİLİTLİ SÜRE: %d:%02d" % (seconds // 60, seconds % 60)
        self._set(self.elapsed, "elapsed", text=elapsed)

        steps = 24
        filled = int(t * 4) % (steps + 1)
        if self._last.get("bar") != filled:
            self._last["bar"] = filled
            x0, y0, x1, y1 = self.bar_box
            c.coords(self.bar, x0, y0, x0 + (x1 - x0) * filled / steps, y1)


class App:
    def __init__(self, keep_awake, blocker):
        self.keep_awake = keep_awake
        self.blocker = blocker
        self.locked_at = time.time()
        self.busy = False
        self.tick_count = 0

        self.root = tk.Tk()
        families = set(tkfont.families(self.root))
        self.mono = next((f for f in MONO_FAMILIES if f in families), "TkFixedFont")
        monitors = list_monitors(self.root)
        windows = [self.root] + [tk.Toplevel(self.root) for _ in monitors[1:]]
        self.screens = [LockScreen(self, win, geo, i == 0) for i, (win, geo) in enumerate(zip(windows, monitors))]
        self.primary = self.screens[0]

        self.root.after(200, self.focus)
        self.root.after(TICK_MS, self.loop)
        if TEST_SECONDS:
            self.root.after(int(TEST_SECONDS * 1000), self.unlock)

    def focus(self):
        for screen in self.screens:
            screen.window.lift()
            screen.window.attributes("-topmost", True)
        self.primary.entry.focus_force()
        if IS_LINUX and not TEST_SECONDS:
            try:
                # X11: grab keyboard and pointer so Alt+Tab and friends never reach the desktop.
                self.root.grab_set_global()
            except tk.TclError:
                self.root.after(500, self.focus)

    def loop(self):
        self.tick_count += 1
        now = datetime.now()
        for screen in self.screens:
            screen.tick(now, self.tick_count)
        # Something stole the keyboard (notification, dialog): take it back.
        if self.tick_count % 40 == 0 and self.root.focus_get() is None and not TEST_SECONDS:
            self.focus()
        self.root.after(TICK_MS, self.loop)

    def submit(self, _event=None):
        entry = self.primary.entry
        if self.busy or not entry.get():
            return
        if check_password(entry.get()):
            self.unlock()
            return
        # Short pause after a wrong password to slow down guessing.
        entry.delete(0, "end")
        entry.configure(state="disabled")
        self.primary.canvas.itemconfigure(self.primary.error, text="!! HATALI ŞİFRE !!")
        self.busy = True
        self.root.after(2000, self.ready)

    def ready(self):
        self.busy = False
        self.primary.entry.configure(state="normal")
        self.primary.entry.focus_force()

    def unlock(self):
        self.blocker.stop()
        self.keep_awake.stop()
        self.root.destroy()


def main():
    if not (IS_WINDOWS or IS_LINUX or TEST_SECONDS):
        sys.exit("AwakeLock (Python) supports Windows and Linux. On macOS use the native app in macos/.")
    if IS_WINDOWS:
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except (AttributeError, OSError):
            ctypes.windll.user32.SetProcessDPIAware()

    keep_awake = KeepAwake()
    try:
        keep_awake.start()
    except (OSError, RuntimeError) as error:
        sys.exit("AwakeLock: could not prevent sleep, not locking: %s" % error)

    blocker = KeyboardBlocker()
    try:
        app = App(keep_awake, blocker)
        blocker.start()
        app.root.mainloop()
    finally:
        blocker.stop()
        keep_awake.stop()


if __name__ == "__main__":
    main()
