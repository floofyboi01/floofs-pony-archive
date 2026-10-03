' Browse + playback logic for Floof's Pony Archive.
'
' Navigation model: three columns (archive / season / episode). Left and Right
' move between columns, Up and Down are owned by the focused list, OK on an
' episode starts playback, and "*" opens the options overlay.

sub init()
    m.browse = m.top.findNode("browseGroup")
    m.status = m.top.findNode("statusLabel")
    m.info = m.top.findNode("infoLabel")
    m.hint = m.top.findNode("hintLabel")
    m.episodeHeading = m.top.findNode("episodeHeading")

    m.seriesList = m.top.findNode("seriesList")
    m.seasonList = m.top.findNode("seasonList")
    m.episodeList = m.top.findNode("episodeList")

    m.video = m.top.findNode("videoPlayer")

    m.optionsGroup = m.top.findNode("optionsGroup")
    m.optionsList = m.top.findNode("optionsList")
    m.optionsTitle = m.top.findNode("optionsTitle")

    m.toastGroup = m.top.findNode("toastGroup")
    m.toastLabel = m.top.findNode("toastLabel")

    m.prefs = paPrefsLoad()
    m.series = []

    m.seriesIndex = 0
    m.seasonIndex = 0
    m.episodeIndex = 0

    m.column = 0
    m.mode = "loading"
    m.optionsRows = []

    m.playing = invalid
    m.resumeKey = ""
    m.lastPosition = 0
    m.pendingSubtitle = ""
    m.pendingDeepLink = ""

    m.seriesList.observeField("itemFocused", "onSeriesFocused")
    m.seriesList.observeField("itemSelected", "onSeriesSelected")
    m.seasonList.observeField("itemFocused", "onSeasonFocused")
    m.seasonList.observeField("itemSelected", "onSeasonSelected")
    m.episodeList.observeField("itemFocused", "onEpisodeFocused")
    m.episodeList.observeField("itemSelected", "onEpisodeSelected")
    m.optionsList.observeField("itemSelected", "onOptionSelected")

    m.video.observeField("state", "onVideoState")
    m.video.observeField("position", "onVideoPosition")
    m.video.notificationInterval = 5

    m.top.observeField("deepLinkContentId", "onDeepLink")

    m.toastTimer = CreateObject("roSGNode", "Timer")
    m.toastTimer.duration = 6
    m.toastTimer.repeat = false
    m.toastTimer.observeField("fire", "onToastExpired")
    m.top.appendChild(m.toastTimer)

    print "[pa] start: quality="; m.prefs.resolution; "p subtitles="; m.prefs.subtitlesOn; " autoplay="; m.prefs.autoplay

    updateHint()
    startLoad()
end sub

'==============================================================
' Loading
'==============================================================

sub startLoad()
    m.mode = "loading"
    m.status.text = "Loading archive..."

    m.dbTask = CreateObject("roSGNode", "DbTask")
    m.dbTask.seriesSpec = [
        { key: "fim", host: "fim", label: "Friendship is Magic" },
        { key: "eqg", host: "eqg", label: "Equestria Girls" }
    ]
    m.dbTask.observeField("result", "onDbResult")
    m.dbTask.control = "RUN"
end sub

sub onDbResult()
    result = m.dbTask.result
    if result = invalid then return

    if not result.ok then
        print "[pa] db load FAILED: "; result.message
        m.mode = "error"
        m.status.text = result.message + "  -  press OK to retry."
        return
    end if

    print "[pa] db loaded, archives="; result.series.Count()
    m.series = result.series
    m.mode = "browse"
    m.seriesIndex = 0
    m.seasonIndex = 0
    m.episodeIndex = 0

    buildSeriesList()
    buildSeasonList()
    buildEpisodeList(false)

    if result.message <> "" then showToast(result.message)

    focusColumn(0)

    if m.pendingDeepLink <> "" then
        applyDeepLink(m.pendingDeepLink)
        m.pendingDeepLink = ""
    end if
end sub

'==============================================================
' List construction
'==============================================================

sub buildSeriesList()
    root = CreateObject("roSGNode", "ContentNode")
    for each entry in m.series
        node = root.CreateChild("ContentNode")
        node.title = entry.label
    end for
    m.seriesList.content = root
    if m.series.Count() > 0 then m.seriesList.jumpToItem = m.seriesIndex
end sub

sub buildSeasonList()
    root = CreateObject("roSGNode", "ContentNode")
    entry = activeSeries()
    if entry <> invalid then
        for each season in entry.seasons
            node = root.CreateChild("ContentNode")
            node.title = season.label
        end for
    end if
    m.seasonList.content = root
    if root.getChildCount() > 0 then
        if m.seasonIndex >= root.getChildCount() then m.seasonIndex = 0
        m.seasonList.jumpToItem = m.seasonIndex
    end if
end sub

sub buildEpisodeList(preserveFocus as boolean)
    season = activeSeason()
    entry = activeSeries()

    keep = 0
    if preserveFocus then keep = m.episodeIndex

    root = CreateObject("roSGNode", "ContentNode")
    if season <> invalid and entry <> invalid then
        for each episode in season.episodes
            node = root.CreateChild("ContentNode")
            node.title = episodeLabel(entry, season, episode)
        end for
    end if

    m.episodeList.content = root

    count = root.getChildCount()
    if count > 0 then
        if keep < 0 or keep >= count then keep = 0
        m.episodeIndex = keep
        m.episodeList.jumpToItem = keep
    else
        m.episodeIndex = 0
    end if

    if season <> invalid then
        m.episodeHeading.text = "EPISODE  (" + Str(count).Trim() + ")"
    else
        m.episodeHeading.text = "EPISODE"
    end if

    updateInfo()
    updateStatus()
end sub

function episodeLabel(entry as object, season as object, episode as object) as string
    label = episode.title
    if season.numberEpisodes then
        label = Str(episode.epNum).Trim() + ". " + episode.title
    end if

    resume = paResumeGet(paResumeKey(entry.key, season.seasNum, episode.epNum))
    if resume > 0 then
        label = label + "    - resume " + paFormatClock(resume)
    end if
    return label
end function

'==============================================================
' Current selection
'==============================================================

function activeSeries() as object
    if m.series = invalid or m.series.Count() = 0 then return invalid
    if m.seriesIndex < 0 or m.seriesIndex >= m.series.Count() then return invalid
    return m.series[m.seriesIndex]
end function

function activeSeason() as object
    entry = activeSeries()
    if entry = invalid then return invalid
    if m.seasonIndex < 0 or m.seasonIndex >= entry.seasons.Count() then return invalid
    return entry.seasons[m.seasonIndex]
end function

function activeEpisode() as object
    season = activeSeason()
    if season = invalid then return invalid
    if m.episodeIndex < 0 or m.episodeIndex >= season.episodes.Count() then return invalid
    return season.episodes[m.episodeIndex]
end function

'==============================================================
' List observers
'==============================================================

sub onSeriesFocused()
    index = m.seriesList.itemFocused
    if index = invalid or index < 0 then return
    if index = m.seriesIndex then return

    m.seriesIndex = index
    m.seasonIndex = 0
    m.episodeIndex = 0
    buildSeasonList()
    buildEpisodeList(false)
end sub

sub onSeriesSelected()
    focusColumn(1)
end sub

sub onSeasonFocused()
    index = m.seasonList.itemFocused
    if index = invalid or index < 0 then return
    if index = m.seasonIndex then return

    m.seasonIndex = index
    m.episodeIndex = 0
    buildEpisodeList(false)
end sub

sub onSeasonSelected()
    focusColumn(2)
end sub

sub onEpisodeFocused()
    index = m.episodeList.itemFocused
    if index = invalid or index < 0 then return
    m.episodeIndex = index
    updateInfo()
end sub

sub onEpisodeSelected()
    playEpisode()
end sub

'==============================================================
' Focus / chrome
'==============================================================

function focusColumn(index as integer) as boolean
    target = index
    if target < 0 then target = 0
    if target > 2 then return false

    if target = 1 and childCount(m.seasonList) = 0 then return false
    if target = 2 and childCount(m.episodeList) = 0 then return false

    m.column = target
    if target = 0 then m.seriesList.setFocus(true)
    if target = 1 then m.seasonList.setFocus(true)
    if target = 2 then m.episodeList.setFocus(true)

    m.seriesList.opacity = columnOpacity(0)
    m.seasonList.opacity = columnOpacity(1)
    m.episodeList.opacity = columnOpacity(2)

    updateHint()
    return true
end function

function columnOpacity(index as integer) as float
    if index = m.column then return 1.0
    return 0.55
end function

function childCount(listNode as object) as integer
    if listNode = invalid or listNode.content = invalid then return 0
    return listNode.content.getChildCount()
end function

sub updateHint()
    if m.mode = "loading" then
        m.hint.text = ""
        return
    end if
    if m.column = 0 then
        m.hint.text = "RIGHT / OK  choose season        *  options"
    else if m.column = 1 then
        m.hint.text = "RIGHT / OK  episodes        LEFT  back        *  options"
    else
        m.hint.text = "OK  play        LEFT  seasons        *  options"
    end if
end sub

sub updateStatus()
    entry = activeSeries()
    if entry = invalid then
        m.status.text = ""
        return
    end if

    episodeTotal = 0
    for each season in entry.seasons
        episodeTotal = episodeTotal + season.episodes.Count()
    end for

    m.status.text = entry.label + "  -  " + Str(entry.seasons.Count()).Trim() + " seasons, " + Str(episodeTotal).Trim() + " episodes"
end sub

sub updateInfo()
    entry = activeSeries()
    season = activeSeason()
    episode = activeEpisode()
    if entry = invalid or season = invalid or episode = invalid then
        m.info.text = ""
        return
    end if

    resolution = paPickResolution(episode.vidRes, m.prefs.resolution)
    line = paEpCode(season.seasNum, episode.epNum) + "   " + episode.title
    line = line + "        " + Str(resolution).Trim() + "p"

    if m.prefs.subtitlesOn then
        if subtitleChoice(episode) = invalid then
            line = line + "        no English subtitles"
        else
            line = line + "        English subtitles"
        end if
    end if

    m.info.text = line
end sub

'==============================================================
' Playback
'==============================================================

sub playEpisode()
    entry = activeSeries()
    season = activeSeason()
    episode = activeEpisode()
    if entry = invalid or season = invalid or episode = invalid then return

    resolution = paPickResolution(episode.vidRes, m.prefs.resolution)
    code = paEpCode(season.seasNum, episode.epNum)

    m.playing = {
        entry: entry,
        season: season,
        episode: episode,
        resolution: resolution,
        code: code,
        url: entry.vidPath + code + "-" + Str(resolution).Trim() + "p.mp4"
    }
    m.resumeKey = paResumeKey(entry.key, season.seasNum, episode.epNum)
    m.lastPosition = 0
    m.pendingSubtitle = ""

    print "[pa] play "; m.playing.url

    chosen = invalid
    if m.prefs.subtitlesOn then chosen = subtitleChoice(episode)

    if chosen <> invalid and entry.vttPath <> "" then
        print "[pa] fetching subtitles "; entry.vttPath + code + "-" + chosen.lang + ".vtt"
        m.status.text = "Preparing subtitles..."

        m.subtitleTask = CreateObject("roSGNode", "SubtitleTask")
        m.subtitleTask.request = {
            url: entry.vttPath + code + "-" + chosen.lang + ".vtt",
            name: entry.key + "_" + code + "_" + chosen.lang
        }
        m.subtitleTask.observeField("result", "onSubtitleReady")
        m.subtitleTask.control = "RUN"
    else
        startPlayback("")
    end if
end sub

' English only. 224 of 262 FiM episodes and 7 of 12 EqG episodes carry an
' English track; the rest simply play without subtitles.
function subtitleChoice(episode as object) as object
    if episode.subs = invalid or episode.subs.Count() = 0 then return invalid

    for each track in episode.subs
        if track.lang = "en" then return track
    end for
    return invalid
end function

sub onSubtitleReady()
    result = m.subtitleTask.result
    path = ""
    if result <> invalid and result.ok then
        path = result.path
        print "[pa] subtitles ready "; path; " cues="; result.cues
    else if result <> invalid and result.message <> "" then
        print "[pa] subtitles unavailable: "; result.message
        showToast(result.message)
    end if
    startPlayback(path)
end sub

sub startPlayback(subtitlePath as string)
    if m.playing = invalid then return
    info = m.playing

    content = CreateObject("roSGNode", "ContentNode")
    content.title = info.episode.title
    content.titleSeason = info.season.label
    content.description = info.entry.label + "  -  " + info.season.label
    content.streamFormat = "mp4"
    content.url = info.url
    content.contentType = "episode"
    content.contentClassifier = "animated"
    content.programId = info.entry.key + "_" + info.code
    content.episodeNumber = Str(info.episode.epNum).Trim()

    resume = paResumeGet(m.resumeKey)
    if resume > 30 then content.playStart = resume

    if subtitlePath <> "" then
        ' Roku matches caption tracks on ISO 639-2/B three letter codes.
        content.subtitleTracks = [{
            TrackName: subtitlePath,
            Language: "eng",
            Description: "English"
        }]
        content.closedCaptions = true
        m.pendingSubtitle = subtitlePath
    end if

    m.video.content = content
    m.mode = "playing"
    m.status.text = ""
    m.browse.visible = false
    m.video.visible = true
    m.video.setFocus(true)

    if subtitlePath <> "" then
        m.video.globalCaptionMode = "On"
    end if

    m.video.control = "play"
end sub

sub onVideoState()
    state = m.video.state
    print "[pa] video state="; state

    if state = "playing" then
        ' availableSubtitleTracks is only populated once playback starts.
        if m.pendingSubtitle <> "" then
            m.video.subtitleTrack = m.pendingSubtitle
            m.pendingSubtitle = ""

            ' Confirm the device ingested the converted SRT rather than
            ' silently discarding it.
            tracks = m.video.availableSubtitleTracks
            accepted = 0
            if tracks <> invalid then accepted = tracks.Count()
            if accepted = 0 then
                print "[pa] WARNING: device rejected the converted subtitle track"
            else
                print "[pa] subtitle track active, captions="; m.video.globalCaptionMode
            end if
        end if
    else if state = "finished" then
        paRegDelete("pa_resume", m.resumeKey)
        m.lastPosition = 0

        ' Roll straight into the next episode rather than dumping the viewer
        ' back to the list. Only a natural "finished" triggers this; pressing
        ' Back goes through stopPlayback instead.
        if m.prefs.autoplay and advanceToNextEpisode() then
            upNext = activeEpisode()
            if upNext <> invalid then showToast("Up next:  " + upNext.title)
            m.video.control = "stop"
            playEpisode()
        else
            stopPlayback(false)
        end if
    else if state = "error" then
        message = m.video.errorMsg
        print "[pa] video ERROR code="; m.video.errorCode; " msg="; message
        print "[pa] errorStr="; m.video.errorStr
        if message = invalid or message = "" then message = "playback failed"
        stopPlayback(true)
        showToast("Could not play this episode: " + message)
    end if
end sub

sub onVideoPosition()
    if m.mode <> "playing" then return
    position = m.video.position
    if position <> invalid then m.lastPosition = position
end sub

' Moves the selection to the next episode within the current archive, rolling
' from the end of one season into the start of the next. Returns false at the
' end of the archive; it deliberately does not cross from FiM into EqG.
function advanceToNextEpisode() as boolean
    entry = activeSeries()
    season = activeSeason()
    if entry = invalid or season = invalid then return false

    if m.episodeIndex + 1 < season.episodes.Count() then
        m.episodeIndex = m.episodeIndex + 1
        buildEpisodeList(true)
        return true
    end if

    ' Find the next season that actually has episodes.
    nextSeason = m.seasonIndex + 1
    while nextSeason < entry.seasons.Count()
        if entry.seasons[nextSeason].episodes.Count() > 0 then
            m.seasonIndex = nextSeason
            m.episodeIndex = 0
            buildSeasonList()
            buildEpisodeList(false)
            return true
        end if
        nextSeason = nextSeason + 1
    end while

    return false
end function

sub stopPlayback(skipResume as boolean)
    if not skipResume and m.resumeKey <> "" then
        paResumeSet(m.resumeKey, m.lastPosition, m.video.duration)
    end if

    m.video.control = "stop"
    m.video.content = invalid
    m.video.visible = false

    m.mode = "browse"
    m.browse.visible = true
    m.playing = invalid

    buildEpisodeList(true)
    focusColumn(2)
end sub

'==============================================================
' Options overlay
'==============================================================

sub openOptions()
    m.mode = "options"
    m.optionsGroup.visible = true
    renderOptions()
    m.optionsList.setFocus(true)
end sub

sub closeOptions()
    m.optionsGroup.visible = false
    m.mode = "browse"
    paPrefsSave(m.prefs)
    buildEpisodeList(true)
    focusColumn(m.column)
end sub

sub renderOptions()
    root = CreateObject("roSGNode", "ContentNode")
    m.optionsTitle.text = "Options"

    m.optionsRows = [
        "Video quality:  " + Str(m.prefs.resolution).Trim() + "p",
        "English subtitles:  " + onOff(m.prefs.subtitlesOn),
        "Autoplay next episode:  " + onOff(m.prefs.autoplay),
        "Clear resume history"
    ]
    for each text in m.optionsRows
        node = root.CreateChild("ContentNode")
        node.title = text
    end for

    m.optionsList.content = root
end sub

sub onOptionSelected()
    index = m.optionsList.itemSelected
    if index = invalid or index < 0 then return

    if index = 0 then
        m.prefs.resolution = nextResolution(m.prefs.resolution)
    else if index = 1 then
        m.prefs.subtitlesOn = not m.prefs.subtitlesOn
        m.video.globalCaptionMode = captionModeFor(m.prefs.subtitlesOn)
    else if index = 2 then
        m.prefs.autoplay = not m.prefs.autoplay
    else if index = 3 then
        paRegClearSection("pa_resume")
        showToast("Resume history cleared.")
        buildEpisodeList(true)
    end if

    paPrefsSave(m.prefs)
    renderOptions()
    m.optionsList.jumpToItem = index
    updateInfo()
end sub

function captionModeFor(enabled as boolean) as string
    if enabled then return "On"
    return "Off"
end function

function onOff(enabled as boolean) as string
    if enabled then return "On"
    return "Off"
end function

function nextResolution(current as integer) as integer
    if current = 480 then return 720
    if current = 720 then return 1080
    return 480
end function

'==============================================================
' Toast
'==============================================================

sub showToast(message as string)
    if message = "" then return
    m.toastLabel.text = message
    m.toastGroup.visible = true
    m.toastTimer.control = "stop"
    m.toastTimer.control = "start"
end sub

sub onToastExpired()
    m.toastGroup.visible = false
end sub

'==============================================================
' Deep link:  contentId "fim_s01e14"
'==============================================================

sub onDeepLink()
    value = m.top.deepLinkContentId
    if value = invalid or value = "" then return
    if m.mode = "loading" or m.series.Count() = 0 then
        m.pendingDeepLink = value
        return
    end if
    applyDeepLink(value)
end sub

sub applyDeepLink(value as string)
    parts = LCase(value).Split("_")
    if parts.Count() < 2 then return

    seriesKey = parts[0]
    code = parts[1]
    if Len(code) < 6 then return

    seasonNumber = Int(Val(Mid(code, 2, 2)))
    episodeNumber = Int(Val(Mid(code, 5, 2)))

    for seriesIdx = 0 to m.series.Count() - 1
        entry = m.series[seriesIdx]
        if entry.key = seriesKey then
            for seasonIdx = 0 to entry.seasons.Count() - 1
                season = entry.seasons[seasonIdx]
                if season.seasNum = seasonNumber then
                    for episodeIdx = 0 to season.episodes.Count() - 1
                        if season.episodes[episodeIdx].epNum = episodeNumber then
                            m.seriesIndex = seriesIdx
                            m.seasonIndex = seasonIdx
                            buildSeriesList()
                            buildSeasonList()
                            m.episodeIndex = episodeIdx
                            buildEpisodeList(true)
                            playEpisode()
                            return
                        end if
                    end for
                end if
            end for
        end if
    end for
end sub

'==============================================================
' Keys
'==============================================================

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false

    if m.mode = "playing" then
        ' Everything else belongs to the Video node: trick play, and the
        ' system caption dialog on "*".
        if key = "back" then
            stopPlayback(false)
            return true
        end if
        return false
    end if

    if m.mode = "options" then
        if key = "back" then
            closeOptions()
            return true
        end if
        return false
    end if

    if m.mode = "error" then
        if key = "OK" then
            startLoad()
            return true
        end if
        return false
    end if

    if m.mode <> "browse" then return false

    if key = "options" then
        openOptions()
        return true
    end if
    if key = "right" then
        return focusColumn(m.column + 1)
    end if
    if key = "left" then
        if m.column = 0 then return false
        return focusColumn(m.column - 1)
    end if
    if key = "back" then
        if m.column > 0 then return focusColumn(m.column - 1)
        return false
    end if

    return false
end function
