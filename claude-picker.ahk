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
g_logFile     := g_binDir "\session-closes.log"
g_iniFile     := g_binDir "\claude-picker.ini"
g_tracked     := Map()        ; pid -> Map(firstSeen,cmd,cwd,jsonl)
g_bySid       := Map()        ; SessionId -> row data Map
g_sortCol     := 2            ; ListView column to sort by (2 = LastModifyTime)
g_sortDir     := "SortDesc"   ; "Sort" (ascending) or "SortDesc" (descending)
g_colNames    := ["StartTime", "LastModifyTime", "CloseTime", "Mode", "Path", "SizeKB", "SessionId"]
g_perProject  := 5            ; most-recent sessions to show per project
g_lastSig     := ""
g_visible     := false
g_shown       := false
g_gui := "", g_lv := "", g_sb := "", g_btn := "", g_cfgBtn := ""

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

BuildGui()
SetupTray()
OnMessage(WM_SHOWPICKER, (*) => ShowPicker())
WatcherTick()                       ; prime tracking
SetTimer(WatcherTick, 3000)

if (argMode != "tray")
    ShowPicker()

Persistent()

; ========================= GUI =========================

BuildGui() {
    global g_gui, g_lv, g_sb, g_btn, g_cfgBtn, g_colNames, g_perProject
    g_gui := Gui("+Resize +MinSize760x360", "Claude Code Sessions")
    g_lv := g_gui.Add("ListView", "x8 y8 w1084 h560 Grid NoSort +LV0x20", g_colNames)
    g_cfgBtn := g_gui.Add("Button", "x8 y572 w180 h26", "Per-project recent: " g_perProject)
    g_btn := g_gui.Add("Button", "x950 y572 w130 h26 Default", "Resume Selected")
    g_sb  := g_gui.Add("StatusBar")
    ColWidths()
    g_lv.OnEvent("DoubleClick", (*) => ResumeSelected())
    g_lv.OnEvent("ColClick", ColClick)
    g_cfgBtn.OnEvent("Click", (*) => ConfigPerProject())
    g_btn.OnEvent("Click", (*) => ResumeSelected())
    g_gui.OnEvent("Size", Gui_Size)
    g_gui.OnEvent("Close", (*) => HidePicker())
    g_gui.OnEvent("Escape", (*) => HidePicker())
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
    global g_lv, g_btn, g_cfgBtn
    if (minMax = -1)
        return
    sbH := 24, btnH := 26
    btnY := h - sbH - btnH - 4
    g_lv.Move(8, 8, w - 16, h - 24 - btnH - sbH)
    g_cfgBtn.Move(8, btnY, 180, btnH)
    g_btn.Move(w - 8 - 130, btnY, 130, btnH)
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
        g_gui.Show("w1100 h640")
        g_shown := true
    }
    g_visible := true
    SetTimer(RefreshTick, 2500)
}

HidePicker() {
    global g_gui, g_visible
    g_visible := false
    SetTimer(RefreshTick, 0)
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

FmtT(ts) => (ts = "") ? "" : FormatTime(ts, "yyyy-MM-dd HH:mm")

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
            if g_tracked.Has(pid) {
                t := g_tracked[pid]
                if (t["jsonl"] = "") {
                    j := FindJsonl(t["cwd"])
                    if (j != "")
                        t["jsonl"] := j
                }
                continue
            }
            if RegExMatch(cmd, "i)\s(--version|-v|--help|-h|--update|--print|-p|config|mcp|update|doctor|migrate-installer|setup-token)(\s|$)")
                continue
            cwd := GetCwd(pid)
            if (cwd = "")
                continue
            g_tracked[pid] := Map("firstSeen", now, "cmd", cmd, "cwd", cwd, "jsonl", FindJsonl(cwd))
        }

        gone := []
        for pid, t in g_tracked
            if !live.Has(pid)
                gone.Push(pid)
        for pid in gone {
            t := g_tracked[pid]
            jsonl := (t["jsonl"] != "") ? t["jsonl"] : FindJsonl(t["cwd"])
            if (jsonl != "")
                WriteClose(pid, t["cwd"], jsonl, t["cmd"], DateDiff(now, t["firstSeen"], "Seconds"))
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

FindJsonl(cwd) {
    global g_projectsDir
    if (cwd = "")
        return ""
    dir := g_projectsDir "\" RegExReplace(cwd, "[\\:/.]", "-")
    if !DirExist(dir)
        return ""
    best := "", bestT := ""
    Loop Files, dir "\*.jsonl" {
        if (bestT = "" || A_LoopFileTimeModified > bestT) {
            bestT := A_LoopFileTimeModified
            best  := A_LoopFileFullPath
        }
    }
    return best
}

WriteClose(pid, cwd, jsonl, cmd, life) {
    global g_logFile
    ts := FormatTime(A_Now, "yyyy-MM-ddTHH:mm:ss")
    line := '{"ts":"' ts '","pid":' pid ',"cwd":"' JEsc(cwd) '","jsonl":"' JEsc(jsonl) '","cmd":"' JEsc(cmd) '","lifetimeSec":' life '}'
    try FileAppend(line "`n", g_logFile, "UTF-8-RAW")
}

JEsc(s) => StrReplace(StrReplace(s, "\", "\\"), '"', '\"')

; --- read a process's CWD from its PEB (x64) ---
GetCwd(pid) {
    h := DllCall("OpenProcess", "UInt", 0x1010, "Int", 0, "UInt", pid, "Ptr")
    if !h
        return ""
    cwd := ""
    try {
        pbi := Buffer(48, 0)
        st := DllCall("ntdll\NtQueryInformationProcess", "Ptr", h, "Int", 0,
            "Ptr", pbi, "UInt", 48, "Ptr", 0, "Int")
        if (st != 0)
            throw Error("")
        peb := NumGet(pbi, 8, "Ptr")
        if !peb
            throw Error("")
        ; PEB+0x20 -> ProcessParameters
        b := Buffer(8, 0)
        if !DllCall("ReadProcessMemory", "Ptr", h, "Ptr", peb + 0x20,
            "Ptr", b, "Ptr", 8, "Ptr", 0, "Int")
            throw Error("")
        pp := NumGet(b, 0, "Ptr")
        if !pp
            throw Error("")
        ; ProcessParameters+0x38 -> CurrentDirectory.DosPath (UNICODE_STRING)
        us := Buffer(16, 0)
        if !DllCall("ReadProcessMemory", "Ptr", h, "Ptr", pp + 0x38,
            "Ptr", us, "Ptr", 16, "Ptr", 0, "Int")
            throw Error("")
        len := NumGet(us, 0, "UShort")
        bufAddr := NumGet(us, 8, "Ptr")
        if (len = 0 || len > 32768 || !bufAddr)
            throw Error("")
        sb := Buffer(len, 0)
        if !DllCall("ReadProcessMemory", "Ptr", h, "Ptr", bufAddr,
            "Ptr", sb, "Ptr", len, "Ptr", 0, "Int")
            throw Error("")
        cwd := RTrim(StrGet(sb, len // 2, "UTF-16"), "\")
    }
    DllCall("CloseHandle", "Ptr", h)
    return cwd
}
