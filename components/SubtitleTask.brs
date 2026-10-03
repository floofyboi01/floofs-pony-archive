' Downloads a WebVTT file and rewrites it as SRT inside tmp:/.
'
' The archive only publishes .vtt, and Roku refuses standalone WebVTT for
' progressive MP4 playback (it is only honoured inside HLS/DASH manifests).
' SRT is accepted on every Roku OS version, including the legacy 3.1 players.

sub init()
    m.top.functionName = "convertSubtitle"
end sub

sub convertSubtitle()
    request = m.top.request
    if request = invalid or request.url = invalid or request.url = "" then
        m.top.result = { ok: false, path: "", message: "No subtitle URL supplied.", cues: 0 }
        return
    end if

    name = request.name
    if name = invalid or name = "" then name = "subtitle"
    outputPath = "tmp:/" + name + ".srt"

    ' Already converted during this channel session.
    if paFileExists(outputPath) then
        m.top.result = { ok: true, path: outputPath, message: "cached", cues: -1 }
        return
    end if

    vtt = paHttpGetString(request.url, 20000)
    if vtt = invalid then
        m.top.result = { ok: false, path: "", message: "Subtitle download failed.", cues: 0 }
        return
    end if

    srt = paVttToSrt(vtt)
    if srt = "" then
        m.top.result = { ok: false, path: "", message: "Subtitle file had no usable cues.", cues: 0 }
        return
    end if

    ' The archive ships stub tracks reading "[Subtitles under construction]"
    ' for some shorts. db.json normally omits those from epSubs, but guard
    ' anyway rather than painting placeholder text over the episode.
    if Instr(1, srt, "Subtitles under construction") > 0 then
        m.top.result = { ok: false, path: "", message: "No finished subtitles for this episode yet.", cues: 0 }
        return
    end if

    if not paWriteUtf8(outputPath, srt) then
        m.top.result = { ok: false, path: "", message: "Could not write converted subtitle.", cues: 0 }
        return
    end if

    m.top.result = { ok: true, path: outputPath, message: "", cues: paCountCues(srt) }
end sub

function paFileExists(path as string) as boolean
    fs = CreateObject("roFileSystem")
    if fs = invalid then return false
    return fs.Exists(path)
end function

function paCountCues(srt as string) as integer
    count = 0
    for each line in srt.Split(Chr(10))
        if Instr(1, line, "-->") > 0 then count = count + 1
    end for
    return count
end function
