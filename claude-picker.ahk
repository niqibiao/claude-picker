#Requires AutoHotkey v2.0
#SingleInstance Off
; claude-picker.ahk - tray-resident picker + background watcher for Claude Code sessions.
; Run via the signed AutoHotkey64.exe (no compiled exe -> no AV false-positive).
;   AutoHotkey64.exe claude-picker.ahk            -> tray + show picker
;   AutoHotkey64.exe claude-picker.ahk --tray     -> tray only (autostart)
;   AutoHotkey64.exe claude-picker.ahk --install  -> register HKCU\Run autostart
;   AutoHotkey64.exe claude-picker.ahk --uninstall

SetWorkingDir(A_ScriptDir)
DetectHiddenWindows(true)
SetTitleMatchMode(3)

; ---- shared state (globals) ----
g_home        := EnvGet("USERPROFILE")
g_binDir      := g_home "\.claude\bin"
g_projectsDir := g_home "\.claude\projects"
g_sessionsDir := g_home "\.claude\sessions"
g_logFile     := g_binDir "\session-closes.log"
g_iniFile     := g_binDir "\claude-picker.ini"
g_tracked     := Map()        ; pid -> Map(firstSeen,cmd,cwd,sid,jsonl)
g_bySid       := Map()        ; SessionId -> row data Map
g_sortCol     := 2            ; ListView column to sort by (2 = LastModifyTime)
g_sortDir     := "SortDesc"   ; "Sort" (ascending) or "SortDesc" (descending)
g_colNames    := ["StartTime", "LastModifyTime", "CloseTime", "Mode", "Path", "SizeKB", "SessionId"]
g_perProject  := 5            ; most-recent sessions to show per project
g_lastSig     := ""
g_visible     := false
g_shown       := false
g_prevW       := 687          ; preferred preview-panel width (px); changes when splitter drags
g_dragging    := false        ; splitter drag in progress
g_dragStartScreenX := 0       ; mouse X at drag start (screen coords)
g_dragStartLvW     := 0       ; ListView width at drag start
g_pendingPreviewSid := ""     ; sid the next async DoPreview() should render (debounced)
g_pendingExportSid  := ""     ; sid the next async DoExport() should write
g_shownSid    := ""           ; sid currently rendered in the preview pane (cache key)
g_shownMod    := ""           ; jsonl mtime at the time of render — invalidates the cache if the file has grown since
; --- splitter drag ghost-line state ---
g_dragCurrentLvW := 0         ; latest clamped ListView width during the drag (committed at mouse-up)
g_overlayY    := 0            ; cached overlay screen Y (splitter doesn't move vertically during drag)
g_overlayH    := 0            ; cached overlay height
g_overlayW    := 0            ; cached overlay width (= splitW)
g_overlayGui  := ""           ; borderless tracking-line window; created once at startup
g_gui := "", g_lv := "", g_sb := "", g_btn := "", g_cfgBtn := "", g_exportBtn := "", g_prevHdr := "", g_prevEdit := "", g_split := ""

; restore the per-project count from the ini file
try {
    _v := IniRead(g_iniFile, "settings", "perProject", "5")
    if (IsInteger(_v) && (_v + 0) >= 1 && (_v + 0) <= 99)
        g_perProject := _v + 0
}

WM_SHOWPICKER := 0x8001

; ---- args ----
argMode := ""
for a in A_Args {
    if (a = "--install")
        argMode := "install"
    else if (a = "--uninstall")
        argMode := "uninstall"
    else if (a = "--tray")
        argMode := "tray"
}

if (argMode = "install") {
    cmd := A_IsCompiled
        ? '"' A_ScriptFullPath '" --tray'
        : '"' A_AhkPath '" "' A_ScriptFullPath '" --tray'
    RegWrite(cmd, "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "ClaudePicker")
    MsgBox("Autostart installed:`n" cmd, "Claude Picker")
    ExitApp()
}
if (argMode = "uninstall") {
    try RegDelete("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "ClaudePicker")
    MsgBox("Autostart removed.", "Claude Picker")
    ExitApp()
}

; ---- single instance: a named mutex is the race-free guard ----
g_mutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 1, "Str", "ClaudePicker-SingleInstance", "Ptr")
if (A_LastError = 183) {            ; ERROR_ALREADY_EXISTS -> another instance is running
    existing := WinExist("Claude Code Sessions")
    if (existing)
        PostMessage(WM_SHOWPICKER, 0, 0, , existing)
    ExitApp()
}

; ---- we are the tray instance ----
try DirCreate(g_binDir)
if !FileExist(g_logFile)
    try FileAppend("", g_logFile, "UTF-8-RAW")

; RICHEDIT50W lives in Msftedit.dll; LoadLibrary registers its window class.
DllCall("LoadLibrary", "Str", "Msftedit.dll")

BuildGui()
BuildDragOverlay()
SetupTray()
OnMessage(WM_SHOWPICKER, (*) => ShowPicker())
OnMessage(0x20,  SetCursorHook)     ; WM_SETCURSOR    -> show ↔ cursor over splitter
OnMessage(0x201, SplitDown)         ; WM_LBUTTONDOWN  -> drag start
OnMessage(0x202, SplitUp)           ; WM_LBUTTONUP    -> drag end
OnMessage(0x215, SplitCaptureChanged)  ; WM_CAPTURECHANGED -> someone stole capture (UAC, alt-tab)
; while dragging, a 16ms timer (SplitDragTick) polls cursor pos; cheaper than handling
; every WM_MOUSEMOVE through OnMessage thread overhead.
WatcherTick()                       ; prime tracking
SetTimer(WatcherTick, 3000)

if (argMode != "tray")
    ShowPicker()

Persistent()

; ========================= GUI =========================

BuildGui() {
    global g_gui, g_lv, g_sb, g_btn, g_cfgBtn, g_exportBtn, g_prevHdr, g_prevEdit, g_split, g_colNames, g_perProject
    g_gui := Gui("+Resize +MinSize900x360", "Claude Code Sessions")
    g_gui.SetFont("s9", "Segoe UI")
    ; layout: ListView | splitter | preview panel (header + read-only RichEdit)
    g_lv      := g_gui.Add("ListView", "x8 y8 w996 h574 Grid NoSort +LV0x20", g_colNames)
    ; thin gray bar — SS_NOTIFY (0x100) makes it intercept clicks so the OnMessage hooks see them
    g_split   := g_gui.Add("Text",     "x1006 y8 w6 h574 Background0xA0A0A0 +0x100", "")
    g_prevHdr := g_gui.Add("Text",     "x1014 y8 w478 h22", "Preview — select a row")
    ; RICHEDIT50W: WS_VSCROLL|WS_TABSTOP|ES_MULTILINE|ES_AUTOVSCROLL|ES_READONLY
    g_prevEdit := g_gui.Add("Custom",  "ClassRICHEDIT50W +0x00210844 x1014 y34 w478 h548")
    InitRichEdit(g_prevEdit)
    g_cfgBtn  := g_gui.Add("Button",   "x8 y586 w180 h26", "Per-project recent: " g_perProject)
    g_exportBtn := g_gui.Add("Button", "x1226 y586 w130 h26", "Export Selected")
    g_btn     := g_gui.Add("Button",   "x1362 y586 w130 h26 Default", "Resume Selected")
    g_sb      := g_gui.Add("StatusBar")
    ColWidths()
    g_lv.OnEvent("ItemFocus", LV_ItemFocus)          ; selected row -> preview in side panel
    g_lv.OnEvent("DoubleClick", (*) => ResumeSelected())
    g_lv.OnEvent("ColClick", ColClick)
    g_cfgBtn.OnEvent("Click", (*) => ConfigPerProject())
    g_exportBtn.OnEvent("Click", (*) => ExportSelected())
    g_btn.OnEvent("Click", (*) => ResumeSelected())
    g_gui.OnEvent("Size", Gui_Size)
    g_gui.OnEvent("Close", (*) => HidePicker())
    g_gui.OnEvent("Escape", (*) => HidePicker())
}

; Borderless, no-activate, always-on-top tracking-line window used as the drag ghost.
; Created once at startup so the first SplitDown doesn't pay window-creation cost.
;   -Caption        no title bar / borders
;   +ToolWindow     stays out of alt-tab
;   +AlwaysOnTop    floats above the picker during drag
;   +E0x08000000    WS_EX_NOACTIVATE — Show() won't steal focus
BuildDragOverlay() {
    global g_overlayGui
    g_overlayGui := Gui("-Caption +ToolWindow +AlwaysOnTop +E0x08000000")
    g_overlayGui.BackColor := 0x606060
}

; Force a sane default font + large text limit on the RichEdit. Default is Times New Roman
; at the system font size, which looks out of place next to the rest of the GUI.
InitRichEdit(ctl) {
    ; Gui.SetFont changes the default font for newly created controls but does not
    ; WM_SETFONT the GUI window itself, so WM_GETFONT on g_gui.Hwnd returns 0. Use
    ; DEFAULT_GUI_FONT directly — that's Segoe UI 9 on Win10/11 at default DPI,
    ; matching the rest of the window. RichAppend pins the per-run font anyway.
    hFont := DllCall("GetStockObject", "Int", 17, "Ptr")       ; DEFAULT_GUI_FONT
    SendMessage(0x30, hFont, 1, , "ahk_id " ctl.Hwnd)          ; WM_SETFONT
    SendMessage(0xC55, 0, 0x7FFFFFFE, , "ahk_id " ctl.Hwnd)    ; EM_EXLIMITTEXT
}

ColWidths() {
    global g_lv
    g_lv.ModifyCol(1, 130)   ; StartTime
    g_lv.ModifyCol(2, 130)   ; LastModifyTime
    g_lv.ModifyCol(3, 130)   ; CloseTime
    g_lv.ModifyCol(4, 55)    ; Mode
    g_lv.ModifyCol(5, 320)   ; Path
    g_lv.ModifyCol(6, "70 Float")  ; SizeKB (numeric sort)
    g_lv.ModifyCol(7, 240)   ; SessionId
}

Gui_Size(gui, minMax, w, h) {
    global g_lv, g_btn, g_cfgBtn, g_exportBtn, g_prevHdr, g_prevEdit, g_split, g_prevW
    if (minMax = -1)
        return
    pad := 8, sbH := 24, btnH := 26, hdrH := 22, splitW := 6
    minLv := 240, minPrev := 200
    btnY := h - sbH - btnH - 4
    lvH := h - pad*2 - btnH - sbH
    prevW := g_prevW
    lvW := w - pad - splitW - prevW - pad
    if (lvW < minLv) {
        lvW := minLv
        prevW := w - pad - splitW - lvW - pad
        if (prevW < minPrev)
            prevW := minPrev
        g_prevW := prevW        ; sync clamped width back so it survives the next resize
    }
    prevX := pad + lvW + splitW
    ; Atomic batch reposition. Sequential .Move() during a splitter drag paints each control
    ; at its own intermediate state — visible as cascade flicker. BeginDeferWindowPos coalesces
    ; all seven into a single SetWindowPos pass so the user sees one consistent frame per tick.
    ; flags = SWP_NOZORDER (0x4) | SWP_NOACTIVATE (0x10).
    flags := 0x14
    hDwp := DllCall("BeginDeferWindowPos", "Int", 7, "Ptr")
    hDwp := DllCall("DeferWindowPos", "Ptr", hDwp, "Ptr", g_lv.Hwnd,        "Ptr", 0, "Int", pad,                     "Int", pad,             "Int", lvW,    "Int", lvH,            "UInt", flags, "Ptr")
    hDwp := DllCall("DeferWindowPos", "Ptr", hDwp, "Ptr", g_split.Hwnd,     "Ptr", 0, "Int", pad + lvW,               "Int", pad,             "Int", splitW, "Int", lvH,            "UInt", flags, "Ptr")
    hDwp := DllCall("DeferWindowPos", "Ptr", hDwp, "Ptr", g_prevHdr.Hwnd,   "Ptr", 0, "Int", prevX,                   "Int", pad,             "Int", prevW,  "Int", hdrH,           "UInt", flags, "Ptr")
    hDwp := DllCall("DeferWindowPos", "Ptr", hDwp, "Ptr", g_prevEdit.Hwnd,  "Ptr", 0, "Int", prevX,                   "Int", pad + hdrH + 4,  "Int", prevW,  "Int", lvH - hdrH - 4, "UInt", flags, "Ptr")
    hDwp := DllCall("DeferWindowPos", "Ptr", hDwp, "Ptr", g_cfgBtn.Hwnd,    "Ptr", 0, "Int", pad,                     "Int", btnY,            "Int", 180,    "Int", btnH,           "UInt", flags, "Ptr")
    hDwp := DllCall("DeferWindowPos", "Ptr", hDwp, "Ptr", g_exportBtn.Hwnd, "Ptr", 0, "Int", w - pad - 130 - 6 - 130, "Int", btnY,            "Int", 130,    "Int", btnH,           "UInt", flags, "Ptr")
    hDwp := DllCall("DeferWindowPos", "Ptr", hDwp, "Ptr", g_btn.Hwnd,       "Ptr", 0, "Int", w - pad - 130,           "Int", btnY,            "Int", 130,    "Int", btnH,           "UInt", flags, "Ptr")
    DllCall("EndDeferWindowPos", "Ptr", hDwp)
}

SetupTray() {
    A_IconTip := "Claude Picker"
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Open Picker", (*) => ShowPicker())
    tray.Add("Start on login", ToggleAutostart)
    tray.Add()                              ; separator
    tray.Add("Quit", (*) => ExitApp())
    tray.Default := "Open Picker"
    RefreshAutostartCheck()
    OnMessage(0x404, TrayClick)
}

TrayClick(wParam, lParam, msg, hwnd) {
    if (lParam = 0x202)        ; WM_LBUTTONUP -> single left click
        ShowPicker()
    else if (lParam = 0x205)   ; WM_RBUTTONUP -> menu about to open
        RefreshAutostartCheck()
}

; flip the HKCU\Run autostart entry on/off
ToggleAutostart(*) {
    if IsAutostartEnabled() {
        try RegDelete("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "ClaudePicker")
    } else {
        cmd := A_IsCompiled
            ? '"' A_ScriptFullPath '" --tray'
            : '"' A_AhkPath '" "' A_ScriptFullPath '" --tray'
        try RegWrite(cmd, "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "ClaudePicker")
    }
    RefreshAutostartCheck()
}

IsAutostartEnabled() {
    try {
        v := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "ClaudePicker")
        return v != ""
    } catch {
        return false
    }
}

RefreshAutostartCheck() {
    if IsAutostartEnabled()
        A_TrayMenu.Check("Start on login")
    else
        A_TrayMenu.Uncheck("Start on login")
}

ShowPicker() {
    global g_gui, g_visible, g_shown
    RefreshPicker(true)
    if (g_shown) {
        g_gui.Show()
    } else {
        g_gui.Show("w1500 h926")
        g_shown := true
    }
    g_visible := true
    SetTimer(RefreshTick, 2500)
}

HidePicker() {
    global g_gui, g_visible, g_pendingPreviewSid, g_shownSid, g_shownMod
    g_visible := false
    SetTimer(RefreshTick, 0)
    SetTimer(DoPreview, 0)              ; cancel any pending async preview parse
    g_pendingPreviewSid := ""
    ; drop the preview cache so the next Show re-renders even if user re-selects the same row
    g_shownSid := ""
    g_shownMod := ""
    g_gui.Hide()
}

RefreshTick(*) {
    Critical
    RefreshPicker(false)
}

RefreshPicker(force := false) {
    global g_lv, g_bySid, g_sb, g_lastSig
    rows := LoadData()
    sig := rows.Length "|" (rows.Length ? rows[1]["mod"] : "") "|" CloseLogSize()
    if (!force && sig = g_lastSig)
        return
    g_lastSig := sig

    ; remember the current (possibly multi-row) selection by SessionId
    selSids := Map()
    n := 0
    loop {
        n := g_lv.GetNext(n)
        if (!n)
            break
        selSids[g_lv.GetText(n, 7)] := true
    }

    g_lv.Opt("-Redraw")
    g_lv.Delete()
    g_bySid := Map()
    for r in rows {
        g_lv.Add(, FmtT(r["start"]), FmtT(r["mod"]), FmtT(r["close"]),
            r["mode"], r["path"], r["sz"], r["sid"])
        g_bySid[r["sid"]] := r
    }
    ApplySort()                         ; keep the user's chosen sort column/direction
    g_lv.Opt("+Redraw")

    ; restore selection by SessionId (survives sorting / row reordering)
    if (selSids.Count > 0) {
        focused := false
        Loop g_lv.GetCount() {
            if selSids.Has(g_lv.GetText(A_Index, 7)) {
                g_lv.Modify(A_Index, focused ? "Select" : "Select Focus")
                focused := true
            }
        }
    }
    g_sb.SetText("  " rows.Length " sessions   -   Ctrl/Shift multi-select, Enter / double-click to resume   -   Esc to close")
}

; sort the ListView by the tracked column/direction
ApplySort() {
    global g_lv, g_sortCol, g_sortDir
    g_lv.ModifyCol(g_sortCol, g_sortDir)
    UpdateHeaders()
}

; mark the sorted column's header with a down/up arrow
UpdateHeaders() {
    global g_lv, g_colNames, g_sortCol, g_sortDir
    arrow := " " . Chr(g_sortDir = "SortDesc" ? 0x25BC : 0x25B2)
    for i, name in g_colNames
        g_lv.ModifyCol(i, "", (i = g_sortCol) ? name . arrow : name)
}

; header click: track the column + direction (mirrors first-asc-then-toggle), then sort
ColClick(lv, col) {
    global g_sortCol, g_sortDir
    if (col = g_sortCol)
        g_sortDir := (g_sortDir = "Sort") ? "SortDesc" : "Sort"
    else {
        g_sortCol := col
        g_sortDir := "Sort"
    }
    ApplySort()
}

; let the user set how many recent sessions to show per project
ConfigPerProject() {
    global g_perProject, g_cfgBtn, g_iniFile
    res := InputBox("Show how many recent sessions per project? (1-99)", "Claude Picker", "w340 h140", g_perProject)
    if (res.Result != "OK")
        return
    v := Trim(res.Value)
    if (!IsInteger(v) || (v + 0) < 1 || (v + 0) > 99) {
        MsgBox("Enter a whole number between 1 and 99.", "Claude Picker", "Icon!")
        return
    }
    g_perProject := v + 0
    try IniWrite(g_perProject, g_iniFile, "settings", "perProject")
    g_cfgBtn.Text := "Per-project recent: " g_perProject
    RefreshPicker(true)
}

; resume every selected row (one row = single resume, many = batch)
ResumeSelected() {
    global g_lv, g_bySid
    sids := []
    n := 0
    loop {
        n := g_lv.GetNext(n)
        if (!n)
            break
        s := g_lv.GetText(n, 7)         ; SessionId cell = identity, robust to sorting
        if g_bySid.Has(s)
            sids.Push(s)
    }
    if (sids.Length = 0)
        return
    failed := []
    for s in sids {
        if !LaunchRow(g_bySid[s])
            failed.Push(s)
        if (sids.Length > 1)
            Sleep(150)          ; stagger so wt opens tabs in order
    }
    if (failed.Length > 0) {
        msg := "Failed to launch " failed.Length " session(s):`n"
        for f in failed
            msg .= f "`n"
        MsgBox(msg, "Claude Picker", "Iconx")
    }
    HidePicker()
}

LaunchRow(r) {
    danger := (r["mode"] = "danger") ? "--dangerously-skip-permissions " : ""
    try {
        Run('wt.exe -w 0 nt -d "' r["path"] '" powershell.exe -NoExit -Command claude ' danger '--resume ' r["sid"])
    } catch {
        return false
    }
    return true
}

; Background export — read the jsonl, render a markdown file ourselves, then open Explorer
; with that file selected. Native /export requires an interactive TUI, so we can't run it
; without showing a terminal; this matches the output a user would expect from /export.
ExportSelected() {
    global g_lv, g_bySid, g_sb, g_exportBtn, g_pendingExportSid
    n := g_lv.GetNext(0)
    if (!n) {
        MsgBox("Select a session row first.", "Claude Picker", "Icon!")
        return
    }
    if (g_lv.GetNext(n)) {
        MsgBox("Export only supports one session at a time. Select a single row.", "Claude Picker", "Icon!")
        return
    }
    sid := g_lv.GetText(n, 7)
    if !g_bySid.Has(sid)
        return
    g_pendingExportSid := sid
    g_exportBtn.Enabled := false
    g_sb.SetText("  Exporting " sid " ...")
    SetTimer(DoExport, -16)             ; yield so the status bar / disabled button paint first
}

DoExport() {
    global g_bySid, g_sb, g_exportBtn, g_pendingExportSid
    sid := g_pendingExportSid
    g_pendingExportSid := ""
    try {
        if (sid = "" || !g_bySid.Has(sid)) {
            g_sb.SetText("  Export cancelled.")
            return
        }
        r := g_bySid[sid]
        data := BuildPreview(r["jsonl"], r["path"])
        if data.Has("error") {
            MsgBox("Cannot export: " data["error"], "Claude Picker", "Iconx")
            g_sb.SetText("  Export failed.")
            return
        }
        if (data["msgs"].Length = 0) {
            MsgBox("No user/assistant text messages in this session.", "Claude Picker", "Icon!")
            g_sb.SetText("  Export skipped (no messages).")
            return
        }
        path := WriteSessionMd(data, sid)
        if !FileExist(path) {
            MsgBox("Export failed (no file produced).", "Claude Picker", "Iconx")
            g_sb.SetText("  Export failed.")
            return
        }
        try Run('explorer.exe /select,"' path '"')
        g_sb.SetText("  Exported: " path)
    } catch as e {
        MsgBox("Export failed:`n" e.Message, "Claude Picker", "Iconx")
        g_sb.SetText("  Export failed: " e.Message)
    } finally {
        g_exportBtn.Enabled := true
    }
}

WriteSessionMd(data, sid) {
    global g_home
    ; Don't pollute the session's working directory (often a git repo, sometimes read-only).
    ; %USERPROFILE%\Documents\claude-sessions is a stable per-user location.
    outDir := g_home "\Documents\claude-sessions"
    try DirCreate(outDir)
    ts := FormatTime(A_Now, "yyyyMMdd-HHmmss")
    path := outDir "\claude-session-" sid "-" ts ".md"
    out := "# Claude Session`r`n`r`n"
    out .= "- **Session ID**: " sid "`r`n"
    out .= "- **Path**: " data["path"] "`r`n"
    out .= "- **Exported**: " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "`r`n`r`n"
    out .= "---`r`n"
    for m in data["msgs"]
        out .= "`r`n## " StrUpper(m["role"]) "`r`n`r`n" m["text"] "`r`n"
    f := FileOpen(path, "w", "UTF-8-RAW")
    if !f
        throw Error("could not open " path " for writing")
    try {
        f.Write(out)
    } finally {
        f.Close()
    }
    return path
}

FmtT(ts) => (ts = "") ? "" : FormatTime(ts, "yyyy-MM-dd HH:mm")

; ========================= PREVIEW =========================

; Focused row in the ListView changed -> refresh the side preview panel.
; The cache key is (sid, jsonl mtime) so the periodic 2.5s RefreshTick is cheap when nothing
; has changed, but a session file that grows (claude is actively writing to it) re-renders.
; g_shownSid is set ONLY by DoPreview after a successful render — early-returns can't poison it.
LV_ItemFocus(lv, row) {
    global g_shownSid, g_shownMod, g_bySid
    if (row <= 0)
        return
    sid := lv.GetText(row, 7)
    if (sid = "")
        return
    if (sid = g_shownSid && g_bySid.Has(sid) && g_bySid[sid]["mod"] = g_shownMod)
        return
    ShowPreview(sid)
}

; Two-phase preview: show a "Loading…" placeholder synchronously, then yield to the
; message loop so the placeholder actually paints, then parse + render on the next tick.
; The pending-sid debounce means rapid arrow-key scrolling only parses the last row.
ShowPreview(sid) {
    global g_bySid, g_prevHdr, g_prevEdit, g_pendingPreviewSid
    if !g_bySid.Has(sid) {
        g_prevHdr.Text := "Preview — session not found"
        RichClear(g_prevEdit)
        return
    }
    g_pendingPreviewSid := sid
    g_prevHdr.Text := "Loading: " sid
    RichClear(g_prevEdit)
    RichAppend(g_prevEdit, "Loading...", false, -1, 20)
    DllCall("UpdateWindow", "Ptr", g_prevEdit.Hwnd)         ; force the placeholder to paint now
    SetTimer(DoPreview, -16)                                ; one-shot; latest call wins
}

DoPreview() {
    global g_bySid, g_prevHdr, g_prevEdit, g_pendingPreviewSid, g_shownSid, g_shownMod
    sid := g_pendingPreviewSid
    if (sid = "" || !g_bySid.Has(sid))
        return
    r := g_bySid[sid]
    data := BuildPreview(r["jsonl"], r["path"])
    if (g_pendingPreviewSid != sid)                         ; user moved on while we were parsing
        return
    g_prevHdr.Text := "Preview: " sid
    RenderPreview(g_prevEdit, data)
    ; Cache key is updated only after a successful render. The (sid, mod) pair lets the next
    ; ItemFocus skip re-parsing unchanged sessions while still picking up growing files.
    g_shownSid := sid
    g_shownMod := r["mod"]
}

; Walk the jsonl and return a Map(error?, path, msgs) describing what to render.
BuildPreview(jpath, cwd) {
    if !FileExist(jpath)
        return Map("error", "(session file missing)`r`n" jpath)
    sz := 0
    try sz := FileGetSize(jpath)
    ; long-running sessions can reach hundreds of MB; loading those into RAM + parsing them
    ; freezes the UI for seconds and starves the watcher. 50 MB covers ~all real transcripts.
    if (sz > 50 * 1024 * 1024)
        return Map("error", "(session file too large: " Round(sz / 1024 / 1024, 1) " MB > 50 MB)")
    txt := ""
    try {
        txt := FileRead(jpath, "UTF-8")
    } catch as e {
        return Map("error", "(cannot read session file)`r`n" e.Message)
    }
    if (txt = "")
        return Map("error", "(empty session file)")

    msgs := []
    ; "unrolled loop" pattern — no nested alternation, so PCRE runs linearly
    ; (the previous ((?:\\.|[^"\\])*) form blew PCRE's recursion limit on long texts)
    textRe := '"type":"text","text":"([^"\\]*(?:\\.[^"\\]*)*)"'
    Loop Parse, txt, "`n", "`r" {
        line := A_LoopField
        if (line = "" || SubStr(line, 1, 1) != "{")
            continue
        if RegExMatch(line, '"isSidechain":true')
            continue
        if !RegExMatch(line, '"type":"(user|assistant)"', &mt)
            continue
        role := mt[1]
        parts := ""
        pos := 1
        while (p := RegExMatch(line, textRe, &m, pos)) {
            if (parts != "")
                parts .= "`n"
            parts .= JsonUnesc(m[1])
            pos := p + m.Len[0]
        }
        if (parts = "")
            continue                            ; pure tool_use / tool_result line — skip
        ; raw text — render-time decides whether to strip markdown; export keeps it intact
        msgs.Push(Map("role", role, "text", parts))
    }
    return Map("path", cwd, "msgs", msgs)
}

RenderPreview(ctl, data) {
    ; freeze BEFORE clearing — otherwise RichClear paints an empty flash while redraw is
    ; still on, and during a slow render the user sees "Loading…" → blank → final content
    RichSetRedraw(ctl, false)
    try {
        RichClear(ctl)
        if data.Has("error") {
            RichAppend(ctl, data["error"], false, -1)
            return
        }
        msgs := data["msgs"]
        RichAppend(ctl, "Path: " data["path"] "`r`n" msgs.Length " message(s)`r`n", false, -1)
        for m in msgs {
            ; COLORREF is 0x00BBGGRR — bright blue for USER, dark green for ASSISTANT
            color := (m["role"] = "user") ? 0x00FF8000 : 0x00008000
            RichAppend(ctl, "`r`n==== " StrUpper(m["role"]) " ====`r`n", true, color)
            RichAppend(ctl, NormalizeNL(StripMd(m["text"])) "`r`n", false, -1)
        }
        ; Scroll to the bottom while redraw is still frozen — the thaw below produces a
        ; single paint at the final scroll position instead of paint-top → paint-bottom.
        SendMessage(0x115, 7, 0, , "ahk_id " ctl.Hwnd)      ; WM_VSCROLL SB_BOTTOM
    } finally {
        RichSetRedraw(ctl, true)
    }
}

NormalizeNL(s) => StrReplace(StrReplace(s, "`r`n", "`n"), "`n", "`r`n")

; --------- RichEdit helpers ---------
RichClear(ctl) {
    empty := ""
    SendMessage(0xC, 0, StrPtr(empty), , "ahk_id " ctl.Hwnd)    ; WM_SETTEXT
}

RichSetRedraw(ctl, on) {
    SendMessage(0xB, on ? 1 : 0, 0, , "ahk_id " ctl.Hwnd)       ; WM_SETREDRAW
    if (on) {
        DllCall("InvalidateRect", "Ptr", ctl.Hwnd, "Ptr", 0, "Int", 1)
        DllCall("UpdateWindow",   "Ptr", ctl.Hwnd)               ; force the paint to happen now
    }
}

; Append `text` at the end with optional bold + RGB color (color < 0 = system default).
; sizePt > 0 overrides the default font size; 0 means "9pt Segoe UI" (the GUI default).
; SIZE + FACE are ALWAYS in the mask — if we only set them when sizePt > 0, the prior run's
; 20pt Loading state bleeds into subsequent normal-size appends via EM_SETCHARFORMAT's
; persistent selection input format.
RichAppend(ctl, text, bold, color, sizePt := 0) {
    SendMessage(0xB1, -1, -1, , "ahk_id " ctl.Hwnd)             ; EM_SETSEL: caret to end
    cf := Buffer(116, 0)
    NumPut("UInt", 116, cf, 0)                                  ; cbSize
    mask    := 0x40000001 | 0x80000000 | 0x20000000             ; CFM_BOLD | CFM_COLOR | CFM_SIZE | CFM_FACE
    effects := bold ? 0x1 : 0
    if (color < 0)
        effects |= 0x40000000                                   ; CFE_AUTOCOLOR
    else
        NumPut("UInt", color, cf, 20)                           ; crTextColor (offset 20)
    pt := (sizePt > 0) ? sizePt : 9                             ; matches Gui.SetFont("s9", "Segoe UI")
    NumPut("Int", pt * 20, cf, 12)                              ; yHeight in twips (1pt = 20)
    StrPut("Segoe UI", cf.Ptr + 26, 32, "UTF-16")               ; szFaceName (32 WCHARs max)
    NumPut("UInt", mask,    cf, 4)                              ; dwMask
    NumPut("UInt", effects, cf, 8)                              ; dwEffects
    SendMessage(0x444, 1, cf.Ptr, , "ahk_id " ctl.Hwnd)         ; EM_SETCHARFORMAT, SCF_SELECTION
    SendMessage(0xC2, 0, StrPtr(text), , "ahk_id " ctl.Hwnd)    ; EM_REPLACESEL (no undo)
}

; Paragraph alignment: 1 = PFA_LEFT, 2 = PFA_RIGHT, 3 = PFA_CENTER, 4 = PFA_JUSTIFY.
RichSetParaAlign(ctl, alignment) {
    pf := Buffer(188, 0)
    NumPut("UInt",   188,       pf, 0)                          ; cbSize (PARAFORMAT2)
    NumPut("UInt",   0x8,       pf, 4)                          ; dwMask = PFM_ALIGNMENT
    NumPut("UShort", alignment, pf, 20)                         ; wAlignment
    SendMessage(0x447, 1, pf.Ptr, , "ahk_id " ctl.Hwnd)         ; EM_SETPARAFORMAT, SCF_SELECTION
}

; --------- Splitter drag handlers ---------
; Ghost-line model: during the drag, ONLY a thin borderless overlay window tracks the cursor.
; The ListView, RichEdit, headers and buttons stay at their starting positions, so we avoid
; per-tick reflow on the heavy controls (RichEdit and ListView reflow on every WM_SIZE even
; with WM_SETREDRAW=0 — that's the "整体黏滞" the user was feeling). On mouse-up we do one
; Gui_Size pass that snaps the children to the final geometry. Worst case ~16ms of layout
; once instead of every tick.
; SS_NOTIFY on the static makes WM_LBUTTONDOWN land on g_split.Hwnd; once we SetCapture,
; WM_LBUTTONUP / WM_CAPTURECHANGED arrive on the GUI itself.
SplitDown(wp, lp, msg, hwnd) {
    global g_split, g_lv, g_gui, g_dragging, g_dragStartScreenX, g_dragStartLvW
    global g_overlayGui, g_overlayY, g_overlayH, g_overlayW, g_dragCurrentLvW
    if !IsObject(g_split) || hwnd != g_split.Hwnd
        return
    g_lv.GetPos(, , &lvW)
    g_dragStartLvW   := lvW
    g_dragCurrentLvW := lvW         ; if drag is aborted without movement, commit at the start
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    g_dragStartScreenX := NumGet(pt, 0, "Int")
    ; cache splitter screen geometry once — its Y/H/W don't change during the drag
    g_gui.GetClientPos(&gcx, &gcy)
    g_split.GetPos(&sx, &sy, &sw, &sh)
    g_overlayY := gcy + sy
    g_overlayH := sh
    g_overlayW := sw
    g_overlayGui.Show("NoActivate w" sw " h" sh " x" (gcx + sx) " y" g_overlayY)
    g_dragging := true
    DllCall("SetCapture", "Ptr", g_gui.Hwnd)
    SetTimer(SplitDragTick, 16)
}

SplitDragTick() {
    global g_dragging, g_dragStartScreenX, g_dragStartLvW, g_gui, g_dragCurrentLvW
    global g_overlayGui, g_overlayY, g_overlayH, g_overlayW
    static lastX := 0
    if !g_dragging {
        SetTimer(SplitDragTick, 0)
        return
    }
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    x := NumGet(pt, 0, "Int")
    if (x = lastX)
        return
    lastX := x
    dx := x - g_dragStartScreenX
    newLvW := g_dragStartLvW + dx
    g_gui.GetClientPos(&gcx, , &gw)
    if (gw <= 0)                ; window minimized mid-drag — skip until it's back
        return
    pad := 8, splitW := 6, minLv := 240, minPrev := 200
    if (newLvW < minLv)
        newLvW := minLv
    maxLv := gw - pad - splitW - minPrev - pad
    if (newLvW > maxLv)
        newLvW := maxLv
    g_dragCurrentLvW := newLvW
    ; The only per-tick work: move one borderless window. No children reflow.
    g_overlayGui.Move(gcx + pad + newLvW, g_overlayY, g_overlayW, g_overlayH)
}

SplitUp(wp, lp, msg, hwnd) {
    global g_dragging
    if !g_dragging
        return
    EndSplitDrag(false)         ; we still hold capture — release it ourselves
}

; If capture is lost mid-drag (UAC dialog, alt-tab, focus theft), WM_LBUTTONUP never lands here.
; Windows sends WM_CAPTURECHANGED to the window that had capture; bail out cleanly or we leave
; g_dragging=true forever, which keeps the polling timer alive and traps the cursor via
; SetCursorHook (which returns 1 to suppress the default cursor while dragging).
SplitCaptureChanged(wp, lp, msg, hwnd) {
    global g_dragging, g_gui
    if !g_dragging
        return
    if (hwnd != g_gui.Hwnd)
        return
    EndSplitDrag(true)          ; capture is already gone — don't ReleaseCapture again
}

EndSplitDrag(captureAlreadyLost) {
    global g_dragging, g_gui, g_overlayGui, g_prevW, g_dragCurrentLvW
    g_dragging := false
    SetTimer(SplitDragTick, 0)
    if !captureAlreadyLost
        DllCall("ReleaseCapture")
    if IsObject(g_overlayGui)
        g_overlayGui.Hide()
    g_gui.GetClientPos(, , &gw, &gh)
    if (gw <= 0)                ; window minimized at the moment of release — defer to next WM_SIZE
        return
    ; Commit the final layout in one Gui_Size pass (BeginDeferWindowPos coalesces all seven
    ; children into a single SetWindowPos). The heavy RichEdit/ListView reflow happens once
    ; here, not 60 times per second during the drag.
    pad := 8, splitW := 6
    g_prevW := gw - pad - splitW - g_dragCurrentLvW - pad
    Gui_Size(g_gui, 0, gw, gh)
}

; Show ↔ cursor while hovering the splitter or actively dragging.
SetCursorHook(wp, lp, msg, hwnd) {
    global g_split, g_dragging
    if !IsObject(g_split)
        return
    if (wp = g_split.Hwnd || g_dragging) {
        cur := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32644, "Ptr")  ; IDC_SIZEWE
        DllCall("SetCursor", "Ptr", cur)
        return 1
    }
}

; Strip the most common Markdown noise so the preview reads naturally in a plain Edit.
; Intentionally conservative — we drop syntax characters and keep the prose.
; \x60 = backtick: written as a PCRE hex escape so AHK's own escape parser leaves it alone.
StripMd(s) {
    ; drop ``` fence lines entirely (keep the code text on its own lines)
    s := RegExReplace(s, "m)^[ \t]*\x60{3,}[^\r\n]*$", "")
    ; ATX headings: drop leading #'s
    s := RegExReplace(s, "m)^[ \t]*#{1,6}[ \t]+", "")
    ; bold / strong emphasis
    s := RegExReplace(s, "\*\*([^*\r\n]+)\*\*", "$1")
    s := RegExReplace(s, "__([^_\r\n]+)__", "$1")
    ; italic (single * or _) — avoid eating intra-word characters
    s := RegExReplace(s, "(?<![A-Za-z0-9*])\*([^*\r\n]+)\*(?![A-Za-z0-9*])", "$1")
    s := RegExReplace(s, "(?<![A-Za-z0-9_])_([^_\r\n]+)_(?![A-Za-z0-9_])", "$1")
    ; inline code  `...`
    s := RegExReplace(s, "\x60([^\x60\r\n]+)\x60", "$1")
    ; images then links — order matters because images contain a link
    s := RegExReplace(s, "!\[([^\]]*)\]\([^)\r\n]+\)", "$1")
    s := RegExReplace(s, "\[([^\]]+)\]\([^)\r\n]+\)", "$1")
    ; blockquote markers
    s := RegExReplace(s, "m)^[ \t]*>[ \t]?", "")
    ; horizontal rules
    s := RegExReplace(s, "m)^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$", "")
    ; collapse 3+ blank lines down to one blank line
    s := RegExReplace(s, "(\r?\n[ \t]*){3,}", "`n`n")
    return s
}

; Single-pass JSON string unescape. Handles \n \r \t \" \\ \/ \b \f \uXXXX.
JsonUnesc(s) {
    out := ""
    len := StrLen(s)
    i := 1
    while (i <= len) {
        c := SubStr(s, i, 1)
        if (c = "\" && i < len) {
            nx := SubStr(s, i + 1, 1)
            if (nx = "n")
                out .= "`n"
            else if (nx = "r")
                out .= "`r"
            else if (nx = "t")
                out .= "`t"
            else if (nx = '"')
                out .= '"'
            else if (nx = "\")
                out .= "\"
            else if (nx = "/")
                out .= "/"
            else if (nx = "b")
                out .= Chr(8)
            else if (nx = "f")
                out .= Chr(12)
            else if (nx = "u" && i + 5 <= len) {
                hex := SubStr(s, i + 2, 4)
                out .= Chr("0x" hex)
                i += 4              ; consume the 4 hex digits in addition to the \u
            } else {
                out .= nx           ; unknown escape — keep the next char literally
            }
            i += 2
        } else {
            out .= c
            i++
        }
    }
    return out
}

; ========================= DATA =========================

LoadData() {
    global g_projectsDir, g_perProject
    closeMap := LoadCloseMap()
    rows := []
    if !DirExist(g_projectsDir)
        return rows

    Loop Files, g_projectsDir "\*", "D" {
        proj := A_LoopFileFullPath
        projRows := []
        Loop Files, proj "\*.jsonl" {
            jpath := A_LoopFileFullPath
            jname := A_LoopFileName
            jcre  := A_LoopFileTimeCreated
            jmod  := A_LoopFileTimeModified
            jsize := A_LoopFileSize

            txt := ReadHead(jpath)
            if !RegExMatch(txt, '"cwd":"([^"]+)"', &mc)
                continue
            cwd := StrReplace(mc[1], "\\", "\")
            if !DirExist(cwd)
                continue

            mode := ""
            if RegExMatch(txt, '"permissionMode":"([^"]+)"', &mm)
                if (mm[1] = "bypassPermissions")
                    mode := "danger"

            r := Map()
            r["start"] := jcre
            r["mod"]   := jmod
            r["close"] := closeMap.Has(jpath) ? closeMap[jpath] : ""
            r["mode"]  := mode
            r["path"]  := cwd
            r["sz"]    := Round(jsize / 1024, 1)
            r["sid"]   := RegExReplace(jname, "\.jsonl$")
            r["jsonl"] := jpath
            projRows.Push(r)
        }
        ; keep only the N most recent sessions of this project
        for r in TopByMod(projRows, g_perProject)
            rows.Push(r)
    }
    return TopByMod(rows, 200)          ; newest first, capped for safety
}

; return up to n rows with the newest "mod" timestamp, sorted descending
TopByMod(arr, n) {
    keyStr := ""
    for i, r in arr
        keyStr .= r["mod"] "`t" i "`n"
    if (keyStr = "")
        return []
    out := []
    Loop Parse, Sort(RTrim(keyStr, "`n"), "N R"), "`n", "`r" {
        if (A_LoopField = "")
            continue
        out.Push(arr[StrSplit(A_LoopField, "`t")[2] + 0])
        if (out.Length >= n)
            break
    }
    return out
}

ReadHead(path) {
    f := ""
    try f := FileOpen(path, "r", "UTF-8")
    if !f
        return ""
    txt := ""
    try txt := f.Read(32768)
    try f.Close()
    return txt
}

CloseLogSize() {
    global g_logFile
    return FileExist(g_logFile) ? FileGetSize(g_logFile) : 0
}

LoadCloseMap() {
    global g_logFile
    m := Map()
    if !FileExist(g_logFile)
        return m
    content := ""
    try content := FileRead(g_logFile, "UTF-8")
    Loop Parse, content, "`n", "`r" {
        line := A_LoopField
        if (line = "")
            continue
        if !RegExMatch(line, '"jsonl":"([^"]+)"', &mj)
            continue
        if !RegExMatch(line, '"ts":"([^"]+)"', &mt)
            continue
        jp := StrReplace(mj[1], "\\", "\")
        ts := ParseTs(mt[1])
        if (ts = "")
            continue
        if (!m.Has(jp) || m[jp] < ts)
            m[jp] := ts
    }
    return m
}

ParseTs(s) {
    if RegExMatch(s, "(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", &d)
        return d[1] d[2] d[3] d[4] d[5] d[6]
    return ""
}

; ========================= WATCHER =========================

WatcherTick(*) {
    Critical
    global g_tracked, g_binDir
    try {
        now := A_Now
        live := GetLiveClaude()

        for pid, cmd in live {
            if !g_tracked.Has(pid) {
                if RegExMatch(cmd, "i)\s(--version|-v|--help|-h|--update|--print|-p|config|mcp|update|doctor|migrate-installer|setup-token)(\s|$)")
                    continue
                g_tracked[pid] := Map("firstSeen", now, "cmd", cmd, "cwd", "", "sid", "", "jsonl", "")
            }
            ; re-read the live session id from ~/.claude/sessions/<pid>.json each tick;
            ; this follows /clear, which swaps the session id within the same process
            info := ReadSessionInfo(pid)
            if (info != "") {
                t := g_tracked[pid]
                t["cwd"]   := info["cwd"]
                t["sid"]   := info["sid"]
                t["jsonl"] := SessionJsonl(info["cwd"], info["sid"])
            }
        }

        gone := []
        for pid, t in g_tracked
            if !live.Has(pid)
                gone.Push(pid)
        for pid in gone {
            t := g_tracked[pid]
            if (t["jsonl"] != "")
                WriteClose(pid, t["cwd"], t["jsonl"], t["cmd"], DateDiff(now, t["firstSeen"], "Seconds"))
            g_tracked.Delete(pid)
        }
    } catch as e {
        try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  " e.Message "`n", g_binDir "\watcher.err.log", "UTF-8-RAW")
    }
}

GetLiveClaude() {
    live := Map()
    try {
        for p in ComObjGet("winmgmts:").ExecQuery(
            "SELECT ProcessId,CommandLine FROM Win32_Process WHERE Name='claude.exe'") {
            cmd := ""
            try cmd := p.CommandLine
            live[p.ProcessId] := (cmd = "") ? "" : cmd
        }
    }
    return live
}

; read ~/.claude/sessions/<pid>.json -> Map("cwd",..,"sid",..) or "" if unavailable.
; Claude writes one file per live process; its sessionId follows /clear in real time.
ReadSessionInfo(pid) {
    global g_sessionsDir
    path := g_sessionsDir "\" pid ".json"
    if !FileExist(path)
        return ""
    txt := ""
    try txt := FileRead(path, "UTF-8")
    if !RegExMatch(txt, '"sessionId":"([^"]+)"', &ms)
        return ""
    if !RegExMatch(txt, '"cwd":"([^"]+)"', &mc)
        return ""
    return Map("sid", ms[1], "cwd", StrReplace(mc[1], "\\", "\"))
}

; map a (cwd, sessionId) pair to its transcript path under ~/.claude/projects
SessionJsonl(cwd, sid) {
    global g_projectsDir
    if (cwd = "" || sid = "")
        return ""
    return g_projectsDir "\" RegExReplace(cwd, "[\\:/.]", "-") "\" sid ".jsonl"
}

WriteClose(pid, cwd, jsonl, cmd, life) {
    global g_logFile
    ts := FormatTime(A_Now, "yyyy-MM-ddTHH:mm:ss")
    line := '{"ts":"' ts '","pid":' pid ',"cwd":"' JEsc(cwd) '","jsonl":"' JEsc(jsonl) '","cmd":"' JEsc(cmd) '","lifetimeSec":' life '}'
    try FileAppend(line "`n", g_logFile, "UTF-8-RAW")
}

JEsc(s) => StrReplace(StrReplace(s, "\", "\\"), '"', '\"')
