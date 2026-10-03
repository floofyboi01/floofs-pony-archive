' Shared helpers. Files under source/ are global to every SceneGraph thread,
' so everything here is prefixed "pa" to avoid colliding with node fields.

'==============================================================
' Formatting
'==============================================================

function paPad2(n as integer) as string
    if n < 10 then return "0" + Str(n).Trim()
    return Str(n).Trim()
end function

' "s01e14" - matches the file naming on static*.heartshine.gay
function paEpCode(seasNum as integer, epNum as integer) as string
    return "s" + paPad2(seasNum) + "e" + paPad2(epNum)
end function

function paFormatClock(totalSeconds as dynamic) as string
    if totalSeconds = invalid then return "0:00"
    secs = Int(totalSeconds)
    if secs < 0 then secs = 0
    hours = Int(secs / 3600)
    mins = Int((secs - hours * 3600) / 60)
    ' Not "rem": that is the BASIC comment keyword and silently swallows
    ' the rest of the line.
    leftover = secs - hours * 3600 - mins * 60
    if hours > 0 then
        return Str(hours).Trim() + ":" + paPad2(mins) + ":" + paPad2(leftover)
    end if
    return Str(mins).Trim() + ":" + paPad2(leftover)
end function

'==============================================================
' Registry (preferences + resume points)
'==============================================================

function paRegRead(section as string, key as string, fallback as string) as string
    sec = CreateObject("roRegistrySection", section)
    if sec <> invalid and sec.Exists(key) then
        v = sec.Read(key)
        if v <> invalid and v <> "" then return v
    end if
    return fallback
end function

sub paRegWrite(section as string, key as string, value as string)
    sec = CreateObject("roRegistrySection", section)
    if sec <> invalid then
        sec.Write(key, value)
        sec.Flush()
    end if
end sub

sub paRegDelete(section as string, key as string)
    sec = CreateObject("roRegistrySection", section)
    if sec <> invalid and sec.Exists(key) then
        sec.Delete(key)
        sec.Flush()
    end if
end sub

sub paRegClearSection(section as string)
    sec = CreateObject("roRegistrySection", section)
    if sec <> invalid then
        for each key in sec.GetKeyList()
            sec.Delete(key)
        end for
        sec.Flush()
    end if
end sub

' Streaming above the panel's native height just burns bandwidth to be
' downscaled, so the first-run default follows the display rather than
' assuming 1080p. A stored preference always wins.
function paDefaultResolution() as integer
    info = CreateObject("roDeviceInfo")
    if info = invalid then return 720

    height = 0
    size = info.GetDisplaySize()
    if size <> invalid and size.h <> invalid then height = Int(size.h)

    if height >= 1080 then return 1080
    if height >= 700 then return 720
    if height > 0 then return 480
    return 720
end function

function paPrefsLoad() as object
    return {
        resolution: Int(Val(paRegRead("pa_prefs", "resolution", Str(paDefaultResolution()).Trim())))
        subtitlesOn: (paRegRead("pa_prefs", "subtitlesOn", "0") = "1")
        autoplay: (paRegRead("pa_prefs", "autoplay", "1") = "1")
    }
end function

sub paPrefsSave(prefs as object)
    paRegWrite("pa_prefs", "resolution", Str(prefs.resolution).Trim())
    paRegWrite("pa_prefs", "subtitlesOn", paBoolToFlag(prefs.subtitlesOn))
    paRegWrite("pa_prefs", "autoplay", paBoolToFlag(prefs.autoplay))
end sub

function paBoolToFlag(value as boolean) as string
    if value then return "1"
    return "0"
end function

function paResumeKey(seriesKey as string, seasNum as integer, epNum as integer) as string
    return seriesKey + "_" + paEpCode(seasNum, epNum)
end function

' Returns 0 when there is nothing worth resuming.
function paResumeGet(key as string) as integer
    return Int(Val(paRegRead("pa_resume", key, "0")))
end function

sub paResumeSet(key as string, position as dynamic, duration as dynamic)
    if position = invalid then return
    ' Not "pos": reserved (the print-position function).
    elapsed = Int(position)

    ' Ignore the first 30s, and treat "almost finished" as finished.
    if elapsed < 30 then
        paRegDelete("pa_resume", key)
        return
    end if
    if duration <> invalid and duration > 0 and elapsed > (Int(duration) - 60) then
        paRegDelete("pa_resume", key)
        return
    end if

    paRegWrite("pa_resume", key, Str(elapsed).Trim())
end sub

'==============================================================
' Resolution selection
'==============================================================

' Picks the highest available resolution that does not exceed the preference,
' falling back to the lowest option when the preference is below everything.
function paPickResolution(available as object, preferred as integer) as integer
    if available = invalid or available.Count() = 0 then return preferred

    best = invalid
    lowest = invalid
    for each candidate in available
        value = Int(candidate)
        if lowest = invalid or value < lowest then lowest = value
        if value <= preferred then
            if best = invalid or value > best then best = value
        end if
    end for

    if best <> invalid then return best
    return lowest
end function

'==============================================================
' WebVTT -> SRT
'
' Roku only ingests sideloaded captions as SRT / TTML / DFXP. Standalone
' WebVTT is supported for HLS and DASH only, never for progressive MP4,
' so the .vtt files this archive serves must be rewritten before use.
'==============================================================

function paNormaliseTimestamp(ts as string) as string
    ' Trim is an ifStringOps method, not a global function.
    t = ts.Trim()
    if t = "" then return ""
    t = t.Replace(",", ".")

    ' Split the fractional part off the end.
    dotAt = 0
    for idx = Len(t) to 1 step -1
        if Mid(t, idx, 1) = "." then
            dotAt = idx
            exit for
        end if
    end for

    millis = "000"
    head = t
    if dotAt > 0 then
        head = Mid(t, 1, dotAt - 1)
        millis = Mid(t, dotAt + 1)
    end if
    while Len(millis) < 3
        millis = millis + "0"
    end while
    millis = Mid(millis, 1, 3)

    bits = head.Split(":")
    hh = 0
    mm = 0
    ss = 0
    if bits.Count() = 3 then
        hh = Int(Val(bits[0]))
        mm = Int(Val(bits[1]))
        ss = Int(Val(bits[2]))
    else if bits.Count() = 2 then
        ' WebVTT permits MM:SS.mmm; SRT always wants hours.
        mm = Int(Val(bits[0]))
        ss = Int(Val(bits[1]))
    else
        return ""
    end if

    return paPad2(hh) + ":" + paPad2(mm) + ":" + paPad2(ss) + "," + millis
end function

function paParseCueTiming(line as string) as object
    arrowAt = Instr(1, line, "-->")
    if arrowAt <= 0 then return invalid

    startRaw = Mid(line, 1, arrowAt - 1).Trim()
    endRaw = Mid(line, arrowAt + 3).Trim()

    ' Discard any WebVTT cue settings ("align:start position:50%") that
    ' follow the end timestamp.
    cut = Instr(1, endRaw, " ")
    if cut > 0 then endRaw = Mid(endRaw, 1, cut - 1)
    cut = Instr(1, endRaw, Chr(9))
    if cut > 0 then endRaw = Mid(endRaw, 1, cut - 1)

    startTs = paNormaliseTimestamp(startRaw)
    endTs = paNormaliseTimestamp(endRaw)
    if startTs = "" or endTs = "" then return invalid

    return { start: startTs, finish: endTs }
end function

' Keeps <i>/<b>/<u>, drops WebVTT-only markup such as <c.loud> and <v Name>.
function paStripVttTags(line as string) as string
    if Instr(1, line, "<") <= 0 then return line

    result = ""
    i = 1
    total = Len(line)
    while i <= total
        ch = Mid(line, i, 1)
        if ch = "<" then
            closeAt = Instr(i, line, ">")
            if closeAt <= 0 then
                result = result + Mid(line, i)
                exit while
            end if
            tag = Mid(line, i + 1, closeAt - i - 1)
            if Left(tag, 1) = "/" then tag = Mid(tag, 2)
            tag = LCase(tag.Trim())
            if tag = "i" or tag = "b" or tag = "u" then
                result = result + Mid(line, i, closeAt - i + 1)
            end if
            i = closeAt + 1
        else
            result = result + ch
            i = i + 1
        end if
    end while
    return result
end function

function paVttToSrt(vtt as dynamic) as string
    if vtt = invalid or Len(vtt) = 0 then return ""

    text = vtt
    ' Strip a UTF-8 BOM, then normalise CRLF / lone CR to LF.
    if Len(text) >= 3 and Asc(Mid(text, 1, 1)) = 65279 then
        text = Mid(text, 2)
    end if
    text = text.Replace(Chr(13) + Chr(10), Chr(10))
    text = text.Replace(Chr(13), Chr(10))

    lines = text.Split(Chr(10))
    total = lines.Count()

    ' Two-level buffer: BrightScript has no StringBuilder, and naive
    ' concatenation over a few thousand lines reallocates far too much.
    chunks = CreateObject("roArray", 32, true)
    buffer = ""
    cueIndex = 0
    i = 0

    while i < total
        line = lines[i]
        if Instr(1, line, "-->") > 0 then
            timing = paParseCueTiming(line)
            if timing = invalid then
                i = i + 1
            else
                body = CreateObject("roArray", 4, true)
                j = i + 1
                while j < total
                    if lines[j].Trim() = "" then exit while
                    if Instr(1, lines[j], "-->") > 0 then exit while
                    body.Push(paStripVttTags(lines[j]))
                    j = j + 1
                end while

                if body.Count() > 0 then
                    cueIndex = cueIndex + 1
                    buffer = buffer + Str(cueIndex).Trim() + Chr(10)
                    buffer = buffer + timing.start + " --> " + timing.finish + Chr(10)
                    for each bodyLine in body
                        buffer = buffer + bodyLine + Chr(10)
                    end for
                    buffer = buffer + Chr(10)

                    if Len(buffer) > 8192 then
                        chunks.Push(buffer)
                        buffer = ""
                    end if
                end if
                i = j
            end if
        else
            i = i + 1
        end if
    end while

    if buffer <> "" then chunks.Push(buffer)
    if cueIndex = 0 then return ""

    out = ""
    for each chunk in chunks
        out = out + chunk
    end for
    return out
end function

'==============================================================
' HTTP
'==============================================================

' Synchronous GET intended for use inside a Task node only.
function paHttpGetString(url as string, timeoutMs as integer) as dynamic
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetUrl(url)
    xfer.EnableEncodings(true)
    xfer.AddHeader("User-Agent", "RokuPonyArchive/1.0")
    ' Required for HTTPS on Roku, otherwise the transfer fails silently.
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()

    if not xfer.AsyncGetToString() then return invalid

    while true
        msg = wait(timeoutMs, port)
        if msg = invalid then
            xfer.AsyncCancel()
            return invalid
        end if
        if type(msg) = "roUrlEvent" then
            if msg.GetResponseCode() = 200 then
                return msg.GetString()
            end if
            return invalid
        end if
    end while
    return invalid
end function

' Writes a UTF-8 string to tmp:/ via roByteArray so multi-byte subtitle
' text (Cyrillic, Greek, ...) survives the round trip intact.
function paWriteUtf8(path as string, contents as string) as boolean
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(contents)
    return bytes.WriteFile(path)
end function
