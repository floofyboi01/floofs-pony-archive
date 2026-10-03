' Fetches db.json for each configured archive and flattens it into the shape
' the browse UI consumes. Runs off the render thread.

sub init()
    m.top.functionName = "loadDatabase"
end sub

sub loadDatabase()
    spec = m.top.seriesSpec
    if spec = invalid or spec.Count() = 0 then
        m.top.result = { ok: false, message: "No archives configured.", series: [] }
        return
    end if

    collected = []
    failures = []

    for each entry in spec
        url = "https://" + entry.host + ".heartshine.gay/db.json"
        body = paHttpGetString(url, 20000)

        if body = invalid then
            failures.Push(entry.label + " (network)")
        else
            parsed = ParseJson(body)
            if parsed = invalid or parsed.series = invalid then
                failures.Push(entry.label + " (bad JSON)")
            else
                built = buildSeries(entry, parsed)
                if built <> invalid then collected.Push(built)
            end if
        end if
    end for

    if collected.Count() = 0 then
        message = "Could not reach the archive."
        if failures.Count() > 0 then
            message = "Failed to load: " + joinStrings(failures, ", ")
        end if
        m.top.result = { ok: false, message: message, series: [] }
        return
    end if

    note = ""
    if failures.Count() > 0 then
        note = "Partially loaded. Failed: " + joinStrings(failures, ", ")
    end if

    m.top.result = { ok: true, message: note, series: collected }
end sub

function joinStrings(items as object, separator as string) as string
    out = ""
    first = true
    for each item in items
        if first then
            out = item
            first = false
        else
            out = out + separator + item
        end if
    end for
    return out
end function

function buildSeries(entry as object, parsed as object) as object
    raw = parsed.series

    defaultRes = []
    if raw.vidRes <> invalid then
        for each r in raw.vidRes
            defaultRes.Push(Int(r))
        end for
    end if
    if defaultRes.Count() = 0 then defaultRes = [480]

    seasons = []
    if raw.seasons = invalid then return invalid

    for each rawSeason in raw.seasons
        seasNum = Int(rawSeason.seasNum)

        hasName = (rawSeason.seasName <> invalid and rawSeason.seasName <> "")
        hasNumberEps = (rawSeason.numberEps <> invalid)

        if hasName then
            seasonLabel = rawSeason.seasName
        else
            seasonLabel = "Season " + Str(seasNum).Trim()
        end if

        ' Mirrors the website's rule: a named season without an explicit
        ' numberEps flag lists bare episode titles, everything else is numbered.
        numberEpisodes = true
        if hasName and not hasNumberEps then numberEpisodes = false

        episodes = []
        if rawSeason.episodes <> invalid then
            for each rawEp in rawSeason.episodes
                epNum = Int(rawEp.epNum)

                epRes = defaultRes
                if rawEp.vidRes <> invalid then
                    override = []
                    for each r in rawEp.vidRes
                        override.Push(Int(r))
                    end for
                    if override.Count() > 0 then epRes = override
                end if

                subs = []
                if rawEp.epSubs <> invalid then
                    for each rawSub in rawEp.epSubs
                        if rawSub.lang <> invalid then
                            description = rawSub.label
                            if description = invalid or description = "" then
                                description = rawSub.lang
                            end if
                            subs.Push({ lang: rawSub.lang, label: description })
                        end if
                    end for
                end if

                title = rawEp.epTitle
                if title = invalid then title = "Episode " + Str(epNum).Trim()

                episodes.Push({
                    epNum: epNum
                    title: title
                    vidRes: epRes
                    subs: subs
                })
            end for
        end if

        if episodes.Count() > 0 then
            seasons.Push({
                seasNum: seasNum
                label: seasonLabel
                numberEpisodes: numberEpisodes
                episodes: episodes
            })
        end if
    end for

    if seasons.Count() = 0 then return invalid

    return {
        key: entry.key
        label: entry.label
        abbrev: paSafeString(raw.titleAbbrev, entry.label)
        vidPath: paSafeString(raw.vidPath, "")
        vttPath: paSafeString(raw.vttPath, "")
        vidRes: defaultRes
        seasons: seasons
    }
end function

function paSafeString(value as dynamic, fallback as string) as string
    if value = invalid then return fallback
    if type(value) <> "String" and type(value) <> "roString" then return fallback
    if value = "" then return fallback
    return value
end function
