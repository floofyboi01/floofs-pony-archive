' Ember's Pony Archive - Roku channel entry point.
'
' Streams MLP:FiM and MLP:EqG directly from the static MP4s backing
' fim.heartshine.gay / eqg.heartshine.gay.

sub Main(args as dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)

    scene = screen.CreateScene("MainScene")
    screen.show()

    ' Honour deep links so "launch and resume" style ECP calls still work.
    if args <> invalid and args.contentId <> invalid then
        scene.deepLinkContentId = args.contentId
    end if

    while true
        msg = wait(0, port)
        if type(msg) = "roSGScreenEvent" then
            if msg.isScreenClosed() then
                return
            end if
        end if
    end while
end sub
