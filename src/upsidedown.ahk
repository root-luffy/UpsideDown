; UpsideDown - flip one monitor between two computers with a single hotkey.
; MIT License
;
; Talks to the monitor over DDC/CI (VCP code 0x60, "Input Select") through the
; Windows dxva2 API. No drivers, no helper executables.

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

ConfigFile := A_ScriptDir "\config.ini"
ThisPC  := Integer(IniRead(ConfigFile, "UpsideDown", "ThisPC", 15))
Other   := Integer(IniRead(ConfigFile, "UpsideDown", "Other", 17))
FlipKey := IniRead(ConfigFile, "UpsideDown", "Hotkey", "^F12")

; Assume we start on this PC; used when the monitor doesn't answer a read.
LastTarget := ThisPC

Hotkey(FlipKey, (*) => Flip())

A_IconHidden := false
A_IconTip := "UpsideDown  (" FlipKey ")"
tray := A_TrayMenu
tray.Delete()
tray.Add("Flip now", (*) => Flip())
tray.Default := "Flip now"
tray.Add()
tray.Add("Edit settings", (*) => Run('notepad.exe "' ConfigFile '"'))
tray.Add("Reload", (*) => Reload())
tray.Add("Exit", (*) => ExitApp())

; ---------------------------------------------------------------------------

Flip() {
    global LastTarget
    target := WithMonitor(FlipWith)
    if target {
        LastTarget := target
        SetTimer(Verify, -2500)  ; some monitors drop a command mid-switch; resend once
    }
}

FlipWith(h) {
    cur := ReadInput(h)
    if !cur
        cur := LastTarget
    target := cur = ThisPC ? Other : ThisPC
    return SetInput(h, target) ? target : 0
}

Verify() {
    WithMonitor(VerifyWith)
}

VerifyWith(h) {
    cur := ReadInput(h)
    if cur && cur != LastTarget
        SetInput(h, LastTarget)
}

; Runs fn(handle) against the primary monitor's physical handle.
WithMonitor(fn) {
    hMon := DllCall("MonitorFromPoint", "Int64", 0, "UInt", 1, "Ptr")  ; MONITOR_DEFAULTTOPRIMARY
    if !DllCall("dxva2\GetNumberOfPhysicalMonitorsFromHMONITOR", "Ptr", hMon, "UInt*", &n := 0) || n < 1
        return 0
    buf := Buffer(n * (A_PtrSize + 256), 0)  ; PHYSICAL_MONITOR[n]
    if !DllCall("dxva2\GetPhysicalMonitorsFromHMONITOR", "Ptr", hMon, "UInt", n, "Ptr", buf)
        return 0
    result := fn(NumGet(buf, 0, "Ptr"))
    DllCall("dxva2\DestroyPhysicalMonitors", "UInt", n, "Ptr", buf)
    return result
}

ReadInput(h) {
    Loop 5 {  ; DDC reads fail now and then, especially right after a switch
        if DllCall("dxva2\GetVCPFeatureAndVCPFeatureReply", "Ptr", h, "UChar", 0x60, "Ptr", 0, "UInt*", &cur := 0, "UInt*", &max := 0)
            return cur & 0xFF
        Sleep 50
    }
    return 0
}

SetInput(h, value) {
    Loop 3 {
        if DllCall("dxva2\SetVCPFeature", "Ptr", h, "UChar", 0x60, "UInt", value)
            return true
        Sleep 50
    }
    return false
}
