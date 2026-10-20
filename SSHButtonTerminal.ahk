#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
;  SSH Button Terminal
;  KiTTY docked inside an AHK GUI + programmable command buttons + variables.
;
;  Variables: {NAME} tokens in button commands are replaced before sending.
;  {HOST}, {USER} are BUILT-IN (taken from the connection bar) and
;  always win over any user-defined variable of the same name.
;  Literal braces: write {{ and }}  (e.g. ${{HOME}} sends ${HOME}).
; ============================================================================

; ---------------------------------------------------------------- globals ---
; ===== EDIT THIS LIST: hosts shown in the Host drop-down ====================
; Key = name shown in the drop-down, Value = address passed to Connect.
; (AHK Maps list keys alphabetically, so the drop-down is sorted by name.)
global HostList := Map(
    "Web server",  "192.168.1.10",
    "DB server",   "192.168.1.20",
    "Example",     "server.example.com"
)
; Process name of the terminal program your Connect command launches.
; Used to find its window after launch so it can be docked in the GUI.
global KittyExeName := "kitty.exe"
; ============================================================================

global CfgFile := A_ScriptDir "\SSHButtonTerminal.json"
global RPW := 360                 ; right panel width
global Settings := Map()          ; connection + app settings (string keys)
global Groups := []               ; ordered group names
global Buttons := []              ; array of Map(Name, Group, Command, Desc)
global Vars := Map()              ; user variables (case-insensitive)

global MainGui := "", TermGui := "", TermLabel := "", SB := ""
global HostDDL := "", UserEdit := ""
global HostLbl := "", UserLbl := ""
global BtnConnect := "", BtnDisconnect := "", PasteChk := ""
global CmdLbl := "", CmdEdit := "", CmdSend := "", CmdCancel := ""
global VarLbl := "", VarLV := "", VarEdit := "", VarSetBtn := "", VarAddBtn := "", VarRemBtn := ""
global BtnLbl := "", GroupDDL := "", BtnGui := ""
global EditBtn := "", ImportBtn := "", ExportBtn := ""

global TermW := 700, TermH := 500
global BtnX := 0, BtnY := 350, BtnAreaH := 200
global WinW := 1100, WinH := 720

global KPid := 0, KHwnd := 0
global Connecting := false, Busy := false

; editor globals
global EdGui := "", EdLV := "", EdFilter := "", EdName := "", EdGroup := ""
global EdCmd := "", EdDesc := "", EdSel := 0, EdRows := []

; ======================================================== JSON (small) ======
; Parser: objects -> Map, arrays -> Array, strings, numbers, true/false -> 1/0,
; null -> "".
class JsonParser {
    __New(text) {
        this.s := text
        this.i := 1
        this.n := StrLen(text)
    }

    Fail(msg) {
        throw Error("JSON error at position " this.i ": " msg)
    }

    Ws() {
        while this.i <= this.n && InStr(" `t`r`n", SubStr(this.s, this.i, 1))
            this.i++
    }

    ParseValue() {
        this.Ws()
        c := SubStr(this.s, this.i, 1)
        if c = "{"
            return this.ParseObject()
        if c = "["
            return this.ParseArray()
        if c = '"'
            return this.ParseString()
        if SubStr(this.s, this.i, 4) = "true" {
            this.i += 4
            return 1
        }
        if SubStr(this.s, this.i, 5) = "false" {
            this.i += 5
            return 0
        }
        if SubStr(this.s, this.i, 4) = "null" {
            this.i += 4
            return ""
        }
        return this.ParseNumber()
    }

    ParseNumber() {
        if !RegExMatch(this.s, "-?\d+(\.\d+)?([eE][+-]?\d+)?", &m, this.i) || m.Pos != this.i
            this.Fail("unexpected character")
        this.i += m.Len
        return Number(m[0])
    }

    ParseString() {
        this.i++                      ; skip opening quote
        out := ""
        loop {
            if this.i > this.n
                this.Fail("unterminated string")
            c := SubStr(this.s, this.i, 1)
            this.i++
            if c = '"'
                return out
            if c = "\" {
                e := SubStr(this.s, this.i, 1)
                this.i++
                switch e {
                    case "n": out .= "`n"
                    case "r": out .= "`r"
                    case "t": out .= "`t"
                    case "b": out .= "`b"
                    case "f": out .= "`f"
                    case "u":
                        hex := SubStr(this.s, this.i, 4)
                        this.i += 4
                        out .= Chr(Integer("0x" hex))
                    default: out .= e
                }
            } else {
                out .= c
            }
        }
    }

    ParseArray() {
        arr := []
        this.i++
        this.Ws()
        if SubStr(this.s, this.i, 1) = "]" {
            this.i++
            return arr
        }
        loop {
            arr.Push(this.ParseValue())
            this.Ws()
            c := SubStr(this.s, this.i, 1)
            this.i++
            if c = "]"
                return arr
            if c != ","
                this.Fail("expected ',' or ']'")
        }
    }

    ParseObject() {
        m := Map()
        this.i++
        this.Ws()
        if SubStr(this.s, this.i, 1) = "}" {
            this.i++
            return m
        }
        loop {
            this.Ws()
            if SubStr(this.s, this.i, 1) != '"'
                this.Fail("expected string key")
            k := this.ParseString()
            this.Ws()
            if SubStr(this.s, this.i, 1) != ":"
                this.Fail("expected ':'")
            this.i++
            m[k] := this.ParseValue()
            this.Ws()
            c := SubStr(this.s, this.i, 1)
            this.i++
            if c = "}"
                return m
            if c != ","
                this.Fail("expected ',' or '}'")
        }
    }
}

Json_Parse(text) {
    if SubStr(text, 1, 1) = Chr(0xFEFF)
        text := SubStr(text, 2)
    p := JsonParser(text)
    v := p.ParseValue()
    p.Ws()
    if p.i <= p.n
        p.Fail("trailing data")
    return v
}

Json_Str(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    s := StrReplace(s, "`b", "\b")
    s := StrReplace(s, "`f", "\f")
    return '"' s '"'
}

Json_Dump(v, ind := "") {
    if v is Map {
        if v.Count = 0 {
            return "{}"
        }
        out := "{`n"
        first := true
        for k, x in v {
            out .= (first ? "" : ",`n") ind "  " Json_Str(String(k)) ": " Json_Dump(x, ind "  ")
            first := false
        }
        return out "`n" ind "}"
    }
    if v is Array {
        if v.Length = 0 {
            return "[]"
        }
        out := "[`n"
        first := true
        for x in v {
            out .= (first ? "" : ",`n") ind "  " Json_Dump(x, ind "  ")
            first := false
        }
        return out "`n" ind "]"
    }
    if v is Number {
        return String(v)
    }
    return Json_Str(String(v))
}

; ===================================================== data / config =======
NewVars() {
    m := Map()
    m.CaseSense := "Off"
    return m
}

DefaultSettings() {
    return Map("host", "", "user", "", "sendMode", "type", "winW", 1100, "winH", 720)
}

MkBtn(name, group, cmd, desc := "") {
    return Map("Name", name, "Group", group, "Command", cmd, "Desc", desc)
}

ArrIndex(arr, val) {
    for i, x in arr {
        if x = val
            return i
    }
    return 0
}

EnsureGroup(name) {
    if ArrIndex(Groups, name) = 0
        Groups.Push(name)
}

LoadDefaults() {
    global Groups, Buttons
    Groups := ["General", "Network", "Multi"]
    Buttons := []
    Buttons.Push(MkBtn("List files", "General", "ls -la", "List directory"))
    Buttons.Push(MkBtn("Disk usage", "General", "df -h", "Show disk usage"))
    Buttons.Push(MkBtn("Curl GET", "Network", "curl -X GET http://{IP}/", "HTTP GET to {IP}"))
    Buttons.Push(MkBtn("Ping host", "Network", "ping -c 4 {IP}", "Ping {IP} four times"))
    Buttons.Push(MkBtn("System info", "Multi", "uname -a`n#sleep 300`nuptime`nfree -h", "Several commands"))
}

; Apply parsed JSON (a Map) to the live data.
; replace=true : replace groups/buttons/variables ; false : merge.
ApplyData(data, replace, withSettings) {
    global Groups, Buttons, Vars, Settings
    if withSettings && data.Has("settings") && data["settings"] is Map {
        for k, v in data["settings"]
            Settings[k] := v
    }
    if replace {
        if data.Has("groups") || data.Has("buttons") {
            Groups := []
            Buttons := []
        }
    }
    if data.Has("groups") && data["groups"] is Array {
        for g in data["groups"] {
            g := Trim(String(g))
            if g != ""
                EnsureGroup(g)
        }
    }
    if data.Has("buttons") && data["buttons"] is Array {
        for b in data["buttons"] {
            if !(b is Map)
                continue
            nb := MkBtn(String(b.Get("Name", "")), Trim(String(b.Get("Group", "General"))), String(b.Get("Command", "")), String(b.Get("Desc", "")))
            if nb["Group"] = ""
                nb["Group"] := "General"
            EnsureGroup(nb["Group"])
            dup := false
            if !replace {
                for e in Buttons {
                    if e["Name"] = nb["Name"] && e["Group"] = nb["Group"] && e["Command"] == nb["Command"] {
                        dup := true
                        break
                    }
                }
            }
            if !dup
                Buttons.Push(nb)
        }
    }
    if data.Has("variables") && data["variables"] is Map {
        if replace
            Vars := NewVars()
        for k, v in data["variables"] {
            v := String(v)
            if replace || !Vars.Has(k) || Vars[k] = ""
                Vars[k] := v
        }
    }
    EnsureGroup("General")
}

LoadConfig() {
    global Settings, Groups, Buttons, Vars
    Settings := DefaultSettings()
    Groups := []
    Buttons := []
    Vars := NewVars()
    if !FileExist(CfgFile) {
        LoadDefaults()
        return
    }
    try {
        txt := FileRead(CfgFile, "UTF-8")
        data := Json_Parse(txt)
        if !(data is Map)
            throw Error("Root element is not an object")
        ApplyData(data, true, true)
    } catch as e {
        try FileCopy(CfgFile, CfgFile ".bad-" A_Now, 1)
        MsgBox("The config file could not be read and was backed up:`n" e.Message "`n`nDefaults will be used.", "Config error", "Icon!")
        Settings := DefaultSettings()
        Vars := NewVars()
        LoadDefaults()
    }
    EnsureGroup("General")
}

SyncSettings() {
    if !IsObject(HostDDL)
        return
    Settings["host"] := Trim(HostDDL.Text)
    Settings["user"] := Trim(UserEdit.Value)
    Settings["winW"] := WinW
    Settings["winH"] := WinH
}

SaveConfig() {
    SyncSettings()
    data := Map("settings", Settings, "groups", Groups, "buttons", Buttons, "variables", Vars)
    tmp := CfgFile ".tmp"
    try {
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        f.Write(Json_Dump(data))
        f.Close()
        FileMove(tmp, CfgFile, 1)
    } catch as e {
        SetStatus("Could not save config: " e.Message)
    }
}

; ============================================== variables / expansion ======
IsBuiltin(name) {
    n := StrUpper(name)
    return n = "HOST" || n = "USER"
}

; Make sure every {NAME} used by any button exists in Vars (keeps values).
ScanVars() {
    for b in Buttons {
        txt := StrReplace(StrReplace(b["Command"], "{{", Chr(1)), "}}", Chr(2))
        pos := 1
        while RegExMatch(txt, "\{([A-Za-z_][A-Za-z0-9_]*)\}", &m, pos) {
            pos := m.Pos + m.Len
            name := m[1]
            if IsBuiltin(name)
                continue
            if !Vars.Has(name)
                Vars[name] := ""
        }
    }
}

; Names (keys) of HostList, for the drop-down.
HostNames() {
    names := []
    for k in HostList
        names.Push(k)
    return names
}

; Address (value) of the host currently selected in the drop-down.
HostAddress() {
    name := IsObject(HostDDL) ? HostDDL.Text : Settings["host"]
    return HostList.Get(name, "")
}

GetVarValue(name) {
    switch StrUpper(name) {
        case "HOST": return HostAddress()
        case "USER": return Trim(UserEdit.Value)
    }
    return Vars.Get(name, "")
}

; Replace {NAME} tokens. 'missing' receives names with empty values.
Expand(text, &missing) {
    missing := []
    text := StrReplace(StrReplace(text, "{{", Chr(1)), "}}", Chr(2))
    out := ""
    pos := 1
    while RegExMatch(text, "\{([A-Za-z_][A-Za-z0-9_]*)\}", &m, pos) {
        out .= SubStr(text, pos, m.Pos - pos)
        val := GetVarValue(m[1])
        if val = "" && ArrIndex(missing, m[1]) = 0
            missing.Push(m[1])
        out .= val
        pos := m.Pos + m.Len
    }
    out .= SubStr(text, pos)
    out := StrReplace(StrReplace(out, Chr(1), "{"), Chr(2), "}")
    return out
}

; Called after any change to buttons/groups/variables.
AfterChange() {
    ScanVars()
    SaveConfig()
    RefreshMainGroups()
    RebuildButtons()
    RefreshVarLV()
}

; Edit-control newline helpers
ToEdit(s) {
    return StrReplace(StrReplace(s, "`r`n", "`n"), "`n", "`r`n")
}
FromEdit(s) {
    return StrReplace(s, "`r`n", "`n")
}
FirstLine(s) {
    lines := StrSplit(s, "`n", "`r")
    return lines.Length ? lines[1] : ""
}

; ============================================================ main GUI =====
SetConn(text) {
    SB.SetText(text, 1)
}

SetStatus(text) {
    SB.SetText(text, 2)
}

BuildGui() {
    global MainGui, TermGui, TermLabel, SB, WinW, WinH
    global HostDDL, UserEdit, HostLbl, UserLbl
    global BtnConnect, BtnDisconnect, PasteChk, CmdLbl, CmdEdit, CmdSend, CmdCancel
    global VarLbl, VarLV, VarEdit, VarSetBtn, VarAddBtn, VarRemBtn
    global BtnLbl, GroupDDL, EditBtn, ImportBtn, ExportBtn

    MainGui := Gui("+Resize +MinSize1000x650 +0x02000000", "SSH Button Terminal")
    MainGui.SetFont("s9", "Segoe UI")
    MainGui.OnEvent("Close", OnMainClose)
    MainGui.OnEvent("Size", OnMainSize)

    ; --- connection bar (row 1)
    HostLbl := MainGui.Add("Text", "x10 y13 w32", "Host")
    ; Host list comes from the HostList array at the top of the script.
    ; The drop-down shows the names; the saved setting is the selected name.
    names := HostNames()
    hostIdx := ArrIndex(names, Settings["host"])
    HostDDL := MainGui.Add("DropDownList", "x45 y10 w170 r10" (names.Length ? " Choose" (hostIdx ? hostIdx : 1) : ""), names)
    ; Make the closed drop-down 23 px tall: CB_SETITEMHEIGHT on the selection
    ; field (wParam -1). The control adds ~6 px of border to this value.
    SendMessage(0x153, -1, 17, HostDDL)
    UserLbl := MainGui.Add("Text", "x225 y13 w30", "User")
    UserEdit := MainGui.Add("Edit", "x260 y10 w130", Settings["user"])
    BtnConnect := MainGui.Add("Button", "x405 y9 w90 h26", "Connect")
    BtnConnect.OnEvent("Click", Connect)
    BtnDisconnect := MainGui.Add("Button", "x501 y9 w90 h26", "Disconnect")
    BtnDisconnect.OnEvent("Click", Disconnect)
    ; Send mode: unchecked = type text directly (default), checked = paste via clipboard
    PasteChk := MainGui.Add("Checkbox", "x605 y14 w220", "Paste mode (clipboard)")
    PasteChk.Value := (Settings.Get("sendMode", "type") = "paste")
    PasteChk.OnEvent("Click", OnPasteToggle)

    ; --- command row (below terminal)
    CmdLbl := MainGui.Add("Text", "x10 y600 w62", "Command")
    CmdEdit := MainGui.Add("Edit", "x75 y597 w500")
    CmdSend := MainGui.Add("Button", "x585 y596 w70 h26", "Send")
    CmdSend.OnEvent("Click", OnSendCmd)
    CmdCancel := MainGui.Add("Button", "x660 y596 w70 h26", "Cancel")
    CmdCancel.OnEvent("Click", SendCtrlC)
    ; Hidden default button: Enter sends, but only when the Command box has focus.
    MainGui.Add("Button", "Default Hidden w0 h0", "SendHidden").OnEvent("Click", OnEnterKey)

    ; --- right panel: variables
    VarLbl := MainGui.Add("Text", "x10 y45 w" RPW, "Variables  (built-in: {HOST} {USER})")
    VarLbl.SetFont("bold")
    VarLV := MainGui.Add("ListView", "x10 y98 w" RPW " h130 -Multi", ["Name", "Value"])
    VarLV.ModifyCol(1, 110)
    VarLV.ModifyCol(2, RPW - 135)
    VarLV.OnEvent("ItemSelect", OnVarSelect)
    VarEdit := MainGui.Add("Edit", "x10 y232 w" (RPW - 60))
    VarSetBtn := MainGui.Add("Button", "x10 y231 w55 h24", "Set")
    VarSetBtn.OnEvent("Click", OnVarSet)
    VarAddBtn := MainGui.Add("Button", "x10 y262 w85 h24", "Add var")
    VarAddBtn.OnEvent("Click", OnVarAdd)
    VarRemBtn := MainGui.Add("Button", "x100 y262 w100 h24", "Remove var")
    VarRemBtn.OnEvent("Click", OnVarRemove)

    ; --- right panel: buttons
    BtnLbl := MainGui.Add("Text", "x10 y298 w" RPW, "Buttons")
    BtnLbl.SetFont("bold")
    GroupDDL := MainGui.Add("DropDownList", "x10 y318 w" RPW " Choose1", Groups)
    GroupDDL.OnEvent("Change", (*) => RebuildButtons())
    EditBtn := MainGui.Add("Button", "x10 y600 w130 h26", "Edit Buttons...")
    EditBtn.OnEvent("Click", OpenEditor)
    ImportBtn := MainGui.Add("Button", "x145 y600 w100 h26", "Import...")
    ImportBtn.OnEvent("Click", DoImport)
    ExportBtn := MainGui.Add("Button", "x250 y600 w100 h26", "Export...")
    ExportBtn.OnEvent("Click", DoExport)

    SB := MainGui.Add("StatusBar")
    SB.SetParts(260)
    SetConn("Disconnected")
    SetStatus("Ready.")

    ; --- child GUI hosting the KiTTY window
    TermGui := Gui("-Caption +Parent" MainGui.Hwnd " +0x02000000")
    TermGui.BackColor := "000000"
    TermGui.SetFont("s11", "Segoe UI")
    ; Solid background (not BackgroundTrans): with WS_CLIPCHILDREN a transparent
    ; label means nothing ever paints this area, leaving a stale "ghost" image.
    TermLabel := TermGui.Add("Text", "x0 y0 w700 h500 Center 0x200 cWhite Background000000", "Not connected.`nEnter Host / User and press Connect.")
    TermGui.Show("x10 y45 w700 h500 NoActivate")

    RefreshVarLV()
    RebuildButtons()

    w := 1100
    h := 720
    try {
        w := Max(1000, Integer(Settings["winW"]))
        h := Max(650, Integer(Settings["winH"]))
    }
    WinW := w
    WinH := h
    MainGui.Show("w" w " h" h)
}

OnMainSize(gui, minMax, w, h) {
    global WinW, WinH
    if minMax = -1
        return
    WinW := w
    WinH := h
    Layout(w, h)
}

; Reposition everything for a client size of w x h.
Layout(w, h) {
    global TermW, TermH, BtnX, BtnY, BtnAreaH
    sbh := 24
    try SB.GetPos(, , , &sbh)
    rx := w - RPW - 10
    top := 45
    cmdY := h - sbh - 36
    TermW := Max(100, rx - 20)
    TermH := Max(100, cmdY - top - 8)

    TermGui.Move(10, top, TermW, TermH)
    TermLabel.Move(0, 0, TermW, TermH)
    FitTerminal()

    CmdLbl.Move(10, cmdY + 4)
    CmdEdit.Move(75, cmdY, TermW - 75 - 154, 24)
    CmdSend.Move(10 + TermW - 146, cmdY - 1, 70, 26)
    CmdCancel.Move(10 + TermW - 70, cmdY - 1, 70, 26)

    VarLbl.Move(rx, 45)
    VarLV.Move(rx, 65, RPW, 130)
    VarEdit.Move(rx, 200, RPW - 60, 24)
    VarSetBtn.Move(rx + RPW - 55, 199, 55, 26)
    VarAddBtn.Move(rx, 231, 90, 26)
    VarRemBtn.Move(rx + 95, 231, 100, 26)
    BtnLbl.Move(rx, 267)
    GroupDDL.Move(rx, 287, RPW)

    BtnX := rx
    BtnY := 321
    BtnAreaH := Max(60, cmdY - BtnY - 8)
    if IsObject(BtnGui)
        BtnGui.Move(BtnX, BtnY, RPW, BtnAreaH)

    EditBtn.Move(rx, cmdY - 1, 130, 26)
    ImportBtn.Move(rx + 135, cmdY - 1, 105, 26)
    ExportBtn.Move(rx + 245, cmdY - 1, 105, 26)
}

; ------------------------------------------------------- command buttons ---
RefreshMainGroups() {
    cur := GroupDDL.Text
    GroupDDL.Delete()
    GroupDDL.Add(Groups)
    idx := ArrIndex(Groups, cur)
    GroupDDL.Choose(idx ? idx : 1)
}

; Destroy and recreate the child GUI holding the current group's buttons.
RebuildButtons() {
    global BtnGui
    if IsObject(BtnGui)
        BtnGui.Destroy()
    BtnGui := Gui("-Caption +Parent" MainGui.Hwnd)
    BtnGui.MarginX := 0
    BtnGui.MarginY := 0
    BtnGui.SetFont("s9", "Segoe UI")
    grp := GroupDDL.Text
    gap := 6
    bw := (RPW - gap) // 2
    bh := 30
    n := 0
    for i, b in Buttons {
        if b["Group"] != grp
            continue
        col := Mod(n, 2)
        row := n // 2
        label := b["Name"] = "" ? "(unnamed)" : StrReplace(b["Name"], "&", "&&")
        btn := BtnGui.Add("Button", "x" (col * (bw + gap)) " y" (row * (bh + gap)) " w" bw " h" bh, label)
        btn.OnEvent("Click", RunButton.Bind(i))
        n += 1
    }
    BtnGui.Show("x" BtnX " y" BtnY " w" RPW " h" BtnAreaH " NoActivate")
}

; Click handler: idx is bound with .Bind(i); ctrl/info come from the event.
RunButton(idx, ctrl, info) {
    if idx < 1 || idx > Buttons.Length
        return
    b := Buttons[idx]
    RunCommandText(b["Command"])
    SetStatus("Button: " b["Name"] (b["Desc"] != "" ? "  -  " b["Desc"] : ""))
    FocusTerminal()
}

; ------------------------------------------------------------ variables ----
RefreshVarLV() {
    VarLV.Delete()
    for k, v in Vars
        VarLV.Add("", k, v)
}

OnVarSelect(lv, item, selected) {
    row := VarLV.GetNext()
    if row
        VarEdit.Value := VarLV.GetText(row, 2)
}

OnVarSet(*) {
    row := VarLV.GetNext()
    if !row {
        SetStatus("Select a variable first.")
        return
    }
    name := VarLV.GetText(row, 1)
    Vars[name] := VarEdit.Value
    VarLV.Modify(row, "", name, VarEdit.Value)
    SaveConfig()
    SetStatus("Variable " name " set.")
}

OnVarAdd(*) {
    ib := InputBox("Variable name (letters, digits, underscore):", "Add variable")
    if ib.Result != "OK"
        return
    name := Trim(ib.Value)
    if !RegExMatch(name, "^[A-Za-z_][A-Za-z0-9_]*$") {
        MsgBox("Invalid variable name.", "Add variable", "Icon!")
        return
    }
    if IsBuiltin(name) {
        MsgBox(name " is a built-in variable (taken from the connection bar).", "Add variable", "Icon!")
        return
    }
    if !Vars.Has(name)
        Vars[name] := ""
    RefreshVarLV()
    SaveConfig()
}

OnVarRemove(*) {
    row := VarLV.GetNext()
    if !row
        return
    name := VarLV.GetText(row, 1)
    Vars.Delete(name)
    ScanVars()          ; still-referenced variables come back (empty)
    RefreshVarLV()
    SaveConfig()
}

OnMainClose(*) {
    if KPid
        try ProcessClose(KPid)
    SaveConfig()
    ExitApp()
}

; ======================================================= KiTTY embedding ===
; Set of all top-level windows that exist right now (taken before launching).
SnapshotWindows() {
    m := Map()
    for h in WinGetList()
        m[h] := true
    return m
}

; Look for a NEW window (not in 'before') that belongs to the KiTTY we launched.
; Matches by PID, by executable name, or by PuTTY/KiTTY class, so it still works
; when KiTTY relaunches itself under a different PID or uses another class name.
; Sets 'dialog' to true if a KiTTY dialog (e.g. host-key alert) is showing.
FindNewTerm(before, pid, exeName, &dialog) {
    dialog := false
    for h in WinGetList() {
        if before.Has(h)
            continue
        try {
            id := "ahk_id " h
            cls := WinGetClass(id)
            wpid := WinGetPID(id)
            pname := WinGetProcessName(id)
            style := WinGetStyle(id)
        } catch {
            continue
        }
        ours := (wpid = pid) || (pname = exeName) || cls = "PuTTY" || cls = "KiTTY"
        if !ours
            continue
        if cls = "#32770" {          ; standard dialog box -> user must answer it
            dialog := true
            continue
        }
        if style & 0xC00000          ; has a caption = main terminal window
            return h
    }
    return 0
}

; Describe new windows for troubleshooting when nothing matched.
DescribeNewWindows(before) {
    out := ""
    for h in WinGetList() {
        if before.Has(h)
            continue
        try out .= WinGetProcessName("ahk_id " h) "  [" WinGetClass("ahk_id " h) "]  " WinGetTitle("ahk_id " h) "`n"
    }
    return out = "" ? "(no new windows appeared)" : out
}

Connect(*) {
    global KPid, KHwnd, Connecting
    if Connecting
        return
    if KHwnd && DllCall("IsWindow", "Ptr", KHwnd) {
        SetStatus("Already connected - disconnect first.")
        return
    }
    SyncSettings()
    hostName := Settings["host"]                 ; name shown in the drop-down
    host := HostList.Get(hostName, "")           ; its address from HostList
    user := Settings["user"]
    if host = "" {
        MsgBox("Please choose a host (edit HostList at the top of the script).", "Connect", "Icon!")
        return
    }
    SaveConfig()

    prefix := (user != "" ? user "@" : "")
    target := prefix host
    ; Replace with your own launch command. Available here: 'hostName' (the
    ; drop-down name), 'host' (its address), 'user', and 'target' (user@address).
    cmd := "placeholder"
    pid := 0
    exeName := KittyExeName
    before := SnapshotWindows()
    try {
        Run(cmd, , , &pid)
    } catch as e {
        MsgBox("Failed to start KiTTY:`n" e.Message, "Error", "Icon!")
        return
    }

    Connecting := true
    KPid := pid
    SetConn("Connecting...")
    SetStatus("Waiting for KiTTY window (accept any host-key dialog)...")
    start := A_TickCount
    limit := 15000
    hwnd := 0
    while true {
        hwnd := FindNewTerm(before, pid, exeName, &dialog)
        if hwnd
            break
        ; a KiTTY dialog (e.g. host key alert) is open: give the user more time
        if dialog
            limit := 120000
        if A_TickCount - start > limit
            break
        Sleep(150)
    }
    Connecting := false

    if !hwnd {
        if ProcessExist(pid)
            try ProcessClose(pid)
        KPid := 0
        SetConn("Disconnected")
        SetStatus("KiTTY window did not appear.")
        MsgBox("The KiTTY terminal window was not detected.`n`nNew windows seen:`n" DescribeNewWindows(before), "Connect", "Icon!")
        return
    }
    KHwnd := hwnd
    KPid := WinGetPID("ahk_id " hwnd)
    EmbedKitty(hwnd)
    SetConn("Connected: " hostName " (" target ")")
    SetStatus("Connected. Type your password in the terminal.")
    FocusTerminal()
}

EmbedKitty(hwnd) {
    id := "ahk_id " hwnd
    TermLabel.Visible := false
    DllCall("SetParent", "Ptr", hwnd, "Ptr", TermGui.Hwnd)
    try WinSetStyle("-0xC40000", id)      ; WS_CAPTION | WS_THICKFRAME
    try WinSetStyle("-0x80000000", id)    ; WS_POPUP
    try WinSetStyle("+0x40000000", id)    ; WS_CHILD
    ; SWP_NOSIZE|NOMOVE|NOZORDER|NOACTIVATE|FRAMECHANGED
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x37)
    try WinShow(id)
    FitTerminal()
}

FitTerminal() {
    if KHwnd && DllCall("IsWindow", "Ptr", KHwnd)
        try WinMove(0, 0, TermW, TermH, "ahk_id " KHwnd)
}

ResetConn(msg) {
    global KPid, KHwnd
    KPid := 0
    KHwnd := 0
    TermLabel.Visible := true
    SetConn("Disconnected")
    SetStatus(msg)
}

; Timer: detect that KiTTY exited.
CheckKitty() {
    if !KHwnd
        return
    if !DllCall("IsWindow", "Ptr", KHwnd) || (KPid && !ProcessExist(KPid))
        ResetConn("KiTTY session ended.")
}

Disconnect(*) {
    if KPid
        try ProcessClose(KPid)
    ResetConn("Disconnected.")
}

; Give keyboard focus to the embedded terminal (cross-thread SetFocus).
FocusTerminal() {
    if !KHwnd || !DllCall("IsWindow", "Ptr", KHwnd)
        return
    try WinActivate("ahk_id " MainGui.Hwnd)
    tid := DllCall("GetWindowThreadProcessId", "Ptr", KHwnd, "Ptr", 0, "UInt")
    me := DllCall("GetCurrentThreadId", "UInt")
    DllCall("AttachThreadInput", "UInt", me, "UInt", tid, "Int", 1)
    DllCall("SetFocus", "Ptr", KHwnd)
    DllCall("AttachThreadInput", "UInt", me, "UInt", tid, "Int", 0)
}

; ================================================== sending text ===========
; Sends one line + Enter. Returns true on success.
SendToTerminal(text) {
    if !KHwnd || !DllCall("IsWindow", "Ptr", KHwnd) {
        SetStatus("Not connected.")
        return false
    }
    id := "ahk_id " KHwnd
    if text = "" {
        ControlSend("{Enter}", , id)
        return true
    }
    if Settings.Get("sendMode", "paste") = "type" {
        ControlSendText(text, , id)
        Sleep(50)
        ControlSend("{Enter}", , id)
        return true
    }
    saved := ClipboardAll()
    A_Clipboard := ""
    A_Clipboard := text
    if !ClipWait(1) {
        A_Clipboard := saved
        SetStatus("Clipboard error - nothing sent.")
        return false
    }
    ; Shift+Insert must be a real keystroke (background ControlSend can drop
    ; the Shift state), so focus the embedded terminal and Send normally.
    FocusTerminal()
    Sleep(50)
    Send("+{Insert}")
    Sleep(100)
    ControlSend("{Enter}", , id)
    Sleep(150)
    A_Clipboard := saved
    return true
}

; Multi-line command text: variables expanded, '#sleep ms' pauses, other '#' lines ignored.
RunCommandText(text) {
    global Busy
    if Busy {
        SetStatus("Busy - a command sequence is still running.")
        return
    }
    if !KHwnd || !DllCall("IsWindow", "Ptr", KHwnd) {
        SetStatus("Not connected.")
        return
    }
    steps := []
    allMissing := []
    for line in StrSplit(text, "`n", "`r") {
        t := Trim(line)
        if t = ""
            continue
        if SubStr(t, 1, 1) = "#" {
            if RegExMatch(t, "i)^#sleep\s+(\d+)", &m)
                steps.Push(["sleep", Integer(m[1])])
            continue
        }
        expanded := Expand(t, &miss)
        for nm in miss {
            if ArrIndex(allMissing, nm) = 0
                allMissing.Push(nm)
        }
        steps.Push(["cmd", expanded])
    }
    if allMissing.Length {
        list := ""
        for nm in allMissing
            list .= "  {" nm "}`n"
        MsgBox("These variables are empty - nothing was sent:`n`n" list "`nFill them in the Variables panel.", "Empty variables", "Icon!")
        return
    }
    Busy := true
    try {
        for st in steps {
            if st[1] = "sleep" {
                Sleep(st[2])
            } else {
                if !SendToTerminal(st[2])
                    break
                Sleep(50)
            }
        }
    } finally {
        Busy := false
    }
}

OnSendCmd(*) {
    text := CmdEdit.Value
    if SendToTerminal(text) {
        CmdEdit.Value := ""
        FocusTerminal()
    }
}

OnEnterKey(*) {
    fc := MainGui.FocusedCtrl
    if !IsObject(fc)
        return
    if fc.Hwnd = CmdEdit.Hwnd
        OnSendCmd()
    else if fc.Hwnd = VarEdit.Hwnd
        OnVarSet()
}

; Cancel button: send Ctrl+C (ETX, char 3) to interrupt the running command.
SendCtrlC(*) {
    if !KHwnd || !DllCall("IsWindow", "Ptr", KHwnd) {
        SetStatus("Not connected.")
        return
    }
    ControlSendText(Chr(3), , "ahk_id " KHwnd)
    SetStatus("Sent Ctrl+C.")
    FocusTerminal()
}

OnPasteToggle(*) {
    Settings["sendMode"] := PasteChk.Value ? "paste" : "type"
    SaveConfig()
    SetStatus("Send mode: " Settings["sendMode"])
}

; ======================================================= button editor =====
OpenEditor(*) {
    global EdGui, EdLV, EdFilter, EdName, EdGroup, EdCmd, EdDesc, EdSel, EdRows
    if IsObject(EdGui) {
        EdGui.Show()
        return
    }
    EdSel := 0
    EdRows := []
    MainGui.Opt("+Disabled")
    EdGui := Gui("+Owner" MainGui.Hwnd, "Edit Buttons")
    EdGui.SetFont("s9", "Segoe UI")
    EdGui.OnEvent("Close", EdClose)
    EdGui.OnEvent("Escape", EdClose)

    ; left: filter + list
    EdGui.Add("Text", "x10 y13 w80", "Group filter:")
    EdFilter := EdGui.Add("DropDownList", "x95 y9 w220")
    EdFilter.OnEvent("Change", EdOnFilter)
    EdLV := EdGui.Add("ListView", "x10 y40 w470 r16 -Multi", ["Group", "Name", "Command (first line)"])
    EdLV.ModifyCol(1, 90)
    EdLV.ModifyCol(2, 120)
    EdLV.ModifyCol(3, 240)
    EdLV.OnEvent("ItemSelect", EdOnSelect)
    b := EdGui.Add("Button", "x10 y+8 w110", "Move Up")
    b.OnEvent("Click", EdMove.Bind(-1))
    b := EdGui.Add("Button", "x+6 yp w110", "Move Down")
    b.OnEvent("Click", EdMove.Bind(1))
    b := EdGui.Add("Button", "x+6 yp w110", "Rename Group...")
    b.OnEvent("Click", EdRenameGroup)
    b := EdGui.Add("Button", "x+6 yp w110", "Delete Group...")
    b.OnEvent("Click", EdDeleteGroup)

    ; right: fields
    EdGui.Add("Text", "x495 y13 w60", "Name:")
    EdName := EdGui.Add("Edit", "x560 y9 w330")
    EdGui.Add("Text", "x495 y45 w60", "Group:")
    EdGroup := EdGui.Add("ComboBox", "x560 y41 w330 r8")
    EdGui.Add("Text", "x495 y77 w300", "Command (one per line):")
    EdCmd := EdGui.Add("Edit", "x495 y97 w395 r10")
    EdGui.Add("Text", "x495 y285 w300", "Description (optional):")
    EdDesc := EdGui.Add("Edit", "x495 y303 w395")
    b := EdGui.Add("Button", "x495 y340 w75", "New")
    b.OnEvent("Click", EdNew)
    b := EdGui.Add("Button", "x+6 yp w75 Default", "Save")
    b.OnEvent("Click", EdSave)
    b := EdGui.Add("Button", "x+6 yp w75", "Delete")
    b.OnEvent("Click", EdDelete)
    b := EdGui.Add("Button", "x+6 yp w80", "Duplicate")
    b.OnEvent("Click", EdDuplicate)
    b := EdGui.Add("Button", "x+6 yp w75", "Close")
    b.OnEvent("Click", EdClose)
    EdGui.Add("Text", "x495 y380 w395 r6", "Help: use {VARNAME} for variables (filled in the Variables panel; {HOST} {USER} are built-in). One command per line. A line '#sleep 500' pauses 500 ms. Other lines starting with # are comments. Use {{ and }} for literal braces, e.g. ${{HOME}}.")

    EdRefreshGroups("All")
    EdFillLV(0)
    EdGui.Show("w910")
}

EdClose(*) {
    global EdGui
    MainGui.Opt("-Disabled")
    EdGui.Destroy()
    EdGui := ""
    try WinActivate("ahk_id " MainGui.Hwnd)
}

SetComboText(ctrl, txt) {
    try {
        ctrl.Text := txt
    } catch {
        try ControlSetText(txt, ctrl)
    }
}

; Rebuild filter DDL and group ComboBox; optional filter selection by text.
EdRefreshGroups(filterSel := "") {
    names := ["All"]
    for g in Groups
        names.Push(g)
    cur := filterSel != "" ? filterSel : EdFilter.Text
    curGroup := EdGroup.Text
    EdFilter.Delete()
    EdFilter.Add(names)
    idx := ArrIndex(names, cur)
    EdFilter.Choose(idx ? idx : 1)
    EdGroup.Delete()
    EdGroup.Add(Groups)
    SetComboText(EdGroup, curGroup)
}

EdFillLV(selectIdx) {
    global EdRows
    EdLV.Delete()
    EdRows := []
    filter := EdFilter.Text
    for i, b in Buttons {
        if filter != "All" && b["Group"] != filter
            continue
        row := EdLV.Add("", b["Group"], b["Name"], FirstLine(b["Command"]))
        EdRows.Push(i)
        if i = selectIdx
            EdLV.Modify(row, "Select Focus Vis")
    }
}

EdOnFilter(*) {
    EdFillLV(EdSel)
}

EdClearFields() {
    EdName.Value := ""
    EdCmd.Value := ""
    EdDesc.Value := ""
}

EdOnSelect(lv, item, selected) {
    global EdSel
    row := EdLV.GetNext()
    if !row || row > EdRows.Length
        return
    EdSel := EdRows[row]
    b := Buttons[EdSel]
    EdName.Value := b["Name"]
    SetComboText(EdGroup, b["Group"])
    EdCmd.Value := ToEdit(b["Command"])
    EdDesc.Value := b["Desc"]
}

EdNew(*) {
    global EdSel
    EdSel := 0
    EdClearFields()
    g := EdFilter.Text
    SetComboText(EdGroup, g = "All" ? "General" : g)
    EdLV.Modify(0, "-Select")
    EdName.Focus()
}

EdSave(*) {
    global EdSel
    name := Trim(EdName.Value)
    if name = "" {
        MsgBox("Please enter a button name.", "Edit Buttons", "Icon!")
        return
    }
    grp := Trim(EdGroup.Text)
    if grp = ""
        grp := "General"
    cmd := FromEdit(EdCmd.Value)
    desc := EdDesc.Value
    EnsureGroup(grp)
    if EdSel >= 1 && EdSel <= Buttons.Length {
        b := Buttons[EdSel]
        b["Name"] := name
        b["Group"] := grp
        b["Command"] := cmd
        b["Desc"] := desc
    } else {
        Buttons.Push(MkBtn(name, grp, cmd, desc))
        EdSel := Buttons.Length
    }
    AfterChange()
    EdRefreshGroups()
    EdFillLV(EdSel)
}

EdDelete(*) {
    global EdSel
    if EdSel < 1 || EdSel > Buttons.Length {
        MsgBox("Select a button first.", "Edit Buttons", "Icon!")
        return
    }
    if MsgBox("Delete button '" Buttons[EdSel]["Name"] "'?", "Confirm delete", "YesNo Icon?") != "Yes"
        return
    Buttons.RemoveAt(EdSel)
    EdSel := 0
    EdClearFields()
    AfterChange()
    EdFillLV(0)
}

EdDuplicate(*) {
    global EdSel
    if EdSel < 1 || EdSel > Buttons.Length {
        MsgBox("Select a button first.", "Edit Buttons", "Icon!")
        return
    }
    b := Buttons[EdSel]
    nb := MkBtn(b["Name"] " (copy)", b["Group"], b["Command"], b["Desc"])
    Buttons.InsertAt(EdSel + 1, nb)
    EdSel := EdSel + 1
    AfterChange()
    EdFillLV(EdSel)
}

; dir = -1 (up) or +1 (down): swap with the neighbouring button of the same group.
EdMove(dir, *) {
    global EdSel
    if EdSel < 1 || EdSel > Buttons.Length
        return
    grp := Buttons[EdSel]["Group"]
    j := EdSel + dir
    while j >= 1 && j <= Buttons.Length && Buttons[j]["Group"] != grp
        j += dir
    if j < 1 || j > Buttons.Length
        return
    tmp := Buttons[EdSel]
    Buttons[EdSel] := Buttons[j]
    Buttons[j] := tmp
    EdSel := j
    AfterChange()
    EdFillLV(EdSel)
}

; Group to operate on: the filter selection, else the selected button's group.
EdTargetGroup() {
    g := EdFilter.Text
    if g = "All" && EdSel >= 1 && EdSel <= Buttons.Length
        g := Buttons[EdSel]["Group"]
    if g = "All" {
        MsgBox("Choose a group in the filter (or select a button) first.", "Edit Buttons", "Icon!")
        return ""
    }
    return g
}

EdRenameGroup(*) {
    g := EdTargetGroup()
    if g = ""
        return
    if g = "General" {
        MsgBox("The General group cannot be renamed.", "Edit Buttons", "Icon!")
        return
    }
    ib := InputBox("New name for group '" g "':", "Rename Group", , g)
    if ib.Result != "OK"
        return
    newName := Trim(ib.Value)
    if newName = "" || newName = g
        return
    idx := ArrIndex(Groups, g)
    if ArrIndex(Groups, newName) {
        if idx
            Groups.RemoveAt(idx)       ; merging into an existing group
    } else if idx {
        Groups[idx] := newName
    }
    for b in Buttons {
        if b["Group"] = g
            b["Group"] := newName
    }
    EnsureGroup(newName)
    AfterChange()
    EdRefreshGroups(newName)
    EdFillLV(EdSel)
}

EdDeleteGroup(*) {
    global EdSel
    g := EdTargetGroup()
    if g = ""
        return
    if g = "General" {
        MsgBox("The General group cannot be deleted.", "Edit Buttons", "Icon!")
        return
    }
    r := MsgBox("Delete group '" g "'?`n`nYes = move its buttons to General`nNo = delete its buttons too`nCancel = abort", "Delete Group", "YesNoCancel Icon?")
    if r = "Cancel"
        return
    i := Buttons.Length
    while i >= 1 {
        if Buttons[i]["Group"] = g {
            if r = "Yes"
                Buttons[i]["Group"] := "General"
            else
                Buttons.RemoveAt(i)
        }
        i -= 1
    }
    idx := ArrIndex(Groups, g)
    if idx
        Groups.RemoveAt(idx)
    EnsureGroup("General")
    EdSel := 0
    EdClearFields()
    AfterChange()
    EdRefreshGroups("All")
    EdFillLV(0)
}

; ================================================== import / export ========
DoImport(*) {
    f := FileSelect(3, A_ScriptDir, "Import buttons", "JSON (*.json)")
    if f = ""
        return
    try {
        data := Json_Parse(FileRead(f, "UTF-8"))
        if !(data is Map)
            throw Error("Root element is not an object")
    } catch as e {
        MsgBox("Could not import file:`n" e.Message, "Import", "Icon!")
        return
    }
    r := MsgBox("Merge with existing buttons (Yes) or Replace (No)?", "Import", "YesNoCancel Icon?")
    if r = "Cancel"
        return
    ApplyData(data, r = "No", false)
    AfterChange()
    SetStatus("Imported " f)
}

DoExport(*) {
    f := FileSelect("S16", A_ScriptDir "\SSHButtonTerminal-export.json", "Export buttons", "JSON (*.json)")
    if f = ""
        return
    if !RegExMatch(f, "i)\.json$")
        f .= ".json"
    data := Map("groups", Groups, "buttons", Buttons, "variables", Vars)
    try {
        fh := FileOpen(f, "w", "UTF-8-RAW")
        fh.Write(Json_Dump(data))
        fh.Close()
        SetStatus("Exported to " f)
    } catch as e {
        MsgBox("Export failed:`n" e.Message, "Export", "Icon!")
    }
}

; ============================================================ startup ======
LoadConfig()
ScanVars()
BuildGui()
SetTimer(CheckKitty, 1000)
