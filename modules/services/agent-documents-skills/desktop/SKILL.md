---
name: desktop
description: "Your own Linux desktop: virtual display :99, headed browser via the playwright MCP server, xdotool/xclip/scrot on a real window stack, viewable by the owner in a browser. Use for GUI apps, visual browser work, and anything CLI-only cannot do."
---

# Your desktop (DISPLAY=:99)

You own a virtual X desktop on this machine. It is YOUR environment: files
under your home are the shared workspace, the display persists across
sessions, and the owner can watch (and share) it live from
https://hermes-desktop.hp (VNC password they hold).

- `DISPLAY=:99` is exported in your environment; every X client works:
  `soffice` (LibreOffice GUI/headless), `xterm`, `mousepad`, `pcmanfm`.
- The browser: a persistent headed Chromium driven by the **playwright MCP
  server** (tools `browser_navigate`, `browser_click`, `browser_type`,
  `browser_snapshot`, `browser_take_screenshot`, vision+pdf caps). Its
  profile lives under your home - log in once, reused later. Screenshots
  come back as images you can SEE (vision) - click by what you observe,
  not by guessing coordinates.
- Beyond the browser: `xdotool` (keys/mouse/windows), `wmctrl` (window
  management), `xclip` (clipboard both ways: `echo x | xclip -selection
  clipboard`), `scrot shot.png` (whole display; then `read` the PNG),
  ImageMagick (`convert`, `import -window`).

Workflow habits:

1. GUI app task -> launch it detached (`setsid app & sleep 1`), find the
   window (`wmctrl -l`, `xdotool search --name`), act, and VERIFY with a
   screenshot you actually look at.
2. Browser task -> prefer playwright tools (they return the accessibility
   snapshot, cheaper and more reliable than pixels); fall back to
   `scrot`-based vision only for things snapshot misses (canvas, video).
3. Deliverables: write under your home workspace; PDFs/office docs through
   the `documents` skill's CLIs; the desktop's LibreOffice renders them for
   a visual check (`soffice --headless --convert-to pdf x.docx`).
4. You have NO sudo and no tailnet/LAN access from the desktop (egress
   jail): public internet + your workspace + this display only. If a site
   needs an account, ask the owner to type the password into the live
   desktop session they are watching - never ask them to send secrets
   through chat.
5. Keep the desktop tidy: `wmctrl -c <window>` when done; long-lived
   windows are shared with the human viewer.
