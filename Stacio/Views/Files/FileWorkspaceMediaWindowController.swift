import AppKit
import WebKit

public struct FileWorkspaceMediaDocument: Equatable {
    public let sourceID: String
    public let fileName: String
    public let sourceURL: URL
    public let contentKind: RemoteFileContentKind
    public let byteCount: UInt64

    public init(
        sourceID: String,
        fileName: String,
        sourceURL: URL,
        contentKind: RemoteFileContentKind,
        byteCount: UInt64
    ) {
        self.sourceID = sourceID
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.contentKind = contentKind
        self.byteCount = byteCount
    }

    public init(localURL: URL) {
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        self.init(
            sourceID: localURL.standardizedFileURL.path,
            fileName: localURL.lastPathComponent,
            sourceURL: localURL,
            contentKind: StacioFileDisplay.contentKind(forFileName: localURL.lastPathComponent),
            byteCount: byteCount
        )
    }
}

@MainActor
public final class FileWorkspaceMediaViewController: NSViewController, WKNavigationDelegate {
    public let document: FileWorkspaceMediaDocument
    public var onCloseRequested: (() -> Void)?
    public var onPreferredAspectRatioChanged: ((CGFloat, CGFloat) -> Void)?

    private var webView: WKWebView?
    private var scriptMessageHandler: FileWorkspaceMediaScriptMessageHandler?

    public init(document: FileWorkspaceMediaDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
        title = document.fileName
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public var htmlForTesting: String {
        mediaHTML()
    }

    var webViewForTesting: WKWebView? {
        webView
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: .black)
        root.setAccessibilityIdentifier("Stacio.FileWorkspaceMedia.root")

        let content = makeWebView()
        let dragHandle = FileWorkspaceMediaDragHandleView()
        content.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        root.addSubview(dragHandle)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dragHandle.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dragHandle.topAnchor.constraint(equalTo: root.topAnchor, constant: 7),
            dragHandle.widthAnchor.constraint(equalToConstant: 72),
            dragHandle.heightAnchor.constraint(equalToConstant: 18)
        ])

        view = root
        content.loadHTMLString(mediaHTML(), baseURL: document.sourceURL.deletingLastPathComponent())
    }

    fileprivate func handleScriptMessage(_ body: Any) {
        guard let payload = body as? [String: Any],
              let action = payload["action"] as? String
        else { return }

        switch action {
        case "close":
            onCloseRequested?()
        case "metadata":
            guard let width = Self.number(payload["width"]),
                  let height = Self.number(payload["height"]),
                  width > 0,
                  height > 0
            else { return }
            onPreferredAspectRatioChanged?(CGFloat(width), CGFloat(height))
        default:
            break
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(
            RemoteFileOnlineMediaSchemeHandler.shared,
            forURLScheme: RemoteFileOnlineMediaRegistry.scheme
        )
        let handler = FileWorkspaceMediaScriptMessageHandler(owner: self)
        configuration.userContentController.add(handler, name: "stacioMedia")
        scriptMessageHandler = handler

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityIdentifier("Stacio.FileWorkspaceMedia.webView")
        webView = view
        return view
    }

    private func mediaHTML() -> String {
        let source = Self.jsonString(document.sourceURL.absoluteString)
        let fileName = Self.jsonString(document.fileName)
        let sizeText = Self.jsonString(ByteCountFormatter.string(fromByteCount: Int64(clamping: document.byteCount), countStyle: .file))
        let mode: String
        switch document.contentKind {
        case .image: mode = "image"
        case .video: mode = "video"
        case .audio: mode = "audio"
        case .text, .other: mode = "unsupported"
        }

        return #"""
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data: blob: stacio-remote-media: http://127.0.0.1:*; media-src file: data: blob: stacio-remote-media: http://127.0.0.1:*; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    * { box-sizing: border-box; }
    html, body, #app { width: 100%; height: 100%; margin: 0; overflow: hidden; }
    body { background: #08090b; color: #f5f6f7; letter-spacing: 0; user-select: none; }
    button { font: inherit; letter-spacing: 0; }
    #stage { position: absolute; inset: 0; display: grid; place-items: center; overflow: hidden; }
    #stage.image { overflow: auto; }
    #stage img { max-width: 100%; max-height: 100%; object-fit: contain; transform-origin: center; }
    #stage video { width: 100%; height: 100%; object-fit: contain; background: #000; }
    .floating { position: absolute; z-index: 5; display: flex; align-items: center; gap: 7px; padding: 7px; border: 1px solid rgba(255,255,255,.16); border-radius: 8px; background: rgba(26,27,31,.76); box-shadow: 0 10px 28px rgba(0,0,0,.35); backdrop-filter: blur(24px) saturate(1.15); transition: opacity 160ms ease, transform 160ms ease; }
    .top { top: 12px; right: 12px; }
    .transport { left: 50%; bottom: 16px; transform: translateX(-50%); min-width: min(680px, calc(100% - 32px)); justify-content: center; }
    .controls-hidden .floating { opacity: 0; pointer-events: none; }
    .controls-hidden .transport { transform: translateX(-50%) translateY(6px); }
    .control { width: 30px; height: 28px; border: 0; border-radius: 6px; padding: 0; display: grid; place-items: center; color: #f7f7f8; background: transparent; cursor: default; }
    .control:hover { background: rgba(255,255,255,.14); }
    .control:active { background: rgba(255,255,255,.22); }
    .control.primary { background: #f4f5f6; color: #111216; }
    .control.primary:hover { background: #fff; }
    .range { accent-color: #f2f3f4; min-width: 120px; flex: 1 1 260px; }
    .volume-range { accent-color: #f2f3f4; width: 82px; min-width: 82px; flex: 0 0 82px; }
    .time { min-width: 42px; color: rgba(255,255,255,.72); font-size: 11px; font-variant-numeric: tabular-nums; }
    .audio-shell { width: 100%; height: 100%; display: grid; grid-template-columns: 82px minmax(0,1fr) 30px; gap: 15px; align-items: center; padding: 23px 22px; background: linear-gradient(145deg, #202329, #111318); }
    .audio-art { width: 82px; height: 82px; border-radius: 8px; display: grid; place-items: center; color: #14161a; background: #f2f3f4; font-size: 30px; box-shadow: 0 8px 24px rgba(0,0,0,.28); }
    .audio-main { min-width: 0; display: grid; gap: 11px; }
    .audio-engine { display: none; }
    .audio-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; font-weight: 600; }
    .audio-meta { color: rgba(255,255,255,.58); font-size: 11px; }
    .audio-progress { display: grid; grid-template-columns: 38px minmax(0,1fr) 38px; gap: 8px; align-items: center; }
    .audio-actions { display: flex; align-items: center; justify-content: center; gap: 14px; }
    .audio-close { align-self: start; }
    .unsupported { display: grid; gap: 8px; text-align: center; color: rgba(255,255,255,.64); }
    .unsupported strong { color: #fff; font-size: 15px; }
  </style>
</head>
<body>
  <div id="app"></div>
  <script>
    const sourceURL = \#(source);
    const fileName = \#(fileName);
    const fileSize = \#(sizeText);
    const mode = "\#(mode)";
    const app = document.getElementById('app');
    let hideTimer = 0;

    function post(action, values = {}) {
      window.webkit.messageHandlers.stacioMedia.postMessage(Object.assign({ action }, values));
    }
    function control(label, title, action, primary = false) {
      const button = document.createElement('button');
      button.className = `control${primary ? ' primary' : ''}`;
      button.innerHTML = label;
      button.title = title;
      button.setAttribute('aria-label', title);
      button.addEventListener('click', event => { event.stopPropagation(); action(); });
      return button;
    }
    function formatTime(value) {
      if (!Number.isFinite(value) || value < 0) return '0:00';
      const minutes = Math.floor(value / 60);
      const seconds = Math.floor(value % 60).toString().padStart(2, '0');
      return `${minutes}:${seconds}`;
    }
    function installAutoHide() {
      const reveal = () => {
        document.body.classList.remove('controls-hidden');
        window.clearTimeout(hideTimer);
        hideTimer = window.setTimeout(() => document.body.classList.add('controls-hidden'), 1700);
      };
      document.addEventListener('pointermove', reveal, { passive: true });
      document.addEventListener('pointerdown', reveal, { passive: true });
      reveal();
    }
    function makeTopControls(extra = []) {
      const controls = document.createElement('div');
      controls.className = 'floating top';
      extra.forEach(item => controls.appendChild(item));
      controls.appendChild(control('&#x2715;', '关闭', () => post('close')));
      app.appendChild(controls);
      return controls;
    }
    function bindPlayer(player, progress, elapsed, duration, playButton) {
      const sync = () => {
        const total = Number.isFinite(player.duration) ? player.duration : 0;
        progress.max = total || 1;
        progress.value = player.currentTime || 0;
        elapsed.textContent = formatTime(player.currentTime);
        duration.textContent = formatTime(total);
        playButton.innerHTML = player.paused ? '&#x25B6;' : '&#x23F8;';
        playButton.title = player.paused ? '播放' : '暂停';
      };
      player.addEventListener('timeupdate', sync);
      player.addEventListener('durationchange', sync);
      player.addEventListener('play', sync);
      player.addEventListener('pause', sync);
      progress.addEventListener('input', () => { player.currentTime = Number(progress.value); sync(); });
      sync();
    }
    function bindVolume(player, muteButton, volumeSlider) {
      let lastAudibleVolume = player.volume > 0 ? player.volume : 1;
      const sync = () => {
        const silent = player.muted || player.volume === 0;
        volumeSlider.value = silent ? '0' : String(player.volume);
        muteButton.innerHTML = silent ? '&#x1F507;' : (player.volume < .5 ? '&#x1F509;' : '&#x1F50A;');
        muteButton.title = silent ? '取消静音' : '静音';
        muteButton.setAttribute('aria-label', muteButton.title);
        muteButton.style.opacity = silent ? '.62' : '1';
      };
      muteButton.addEventListener('click', () => {
        if (player.muted || player.volume === 0) {
          player.muted = false;
          player.volume = Math.max(lastAudibleVolume, .1);
        } else {
          lastAudibleVolume = player.volume;
          player.muted = true;
        }
        sync();
      });
      volumeSlider.addEventListener('input', () => {
        const nextVolume = Math.max(0, Math.min(1, Number(volumeSlider.value)));
        player.volume = nextVolume;
        player.muted = nextVolume === 0;
        if (nextVolume > 0) lastAudibleVolume = nextVolume;
        sync();
      });
      player.addEventListener('volumechange', sync);
      sync();
    }
    function renderImage() {
      app.innerHTML = '<div id="stage" class="image"></div>';
      const stage = document.getElementById('stage');
      const image = document.createElement('img');
      let scale = 1;
      let rotation = 0;
      let fit = true;
      const apply = () => {
        image.style.maxWidth = fit ? '100%' : 'none';
        image.style.maxHeight = fit ? '100%' : 'none';
        image.style.transform = `scale(${scale}) rotate(${rotation}deg)`;
      };
      image.addEventListener('load', () => post('metadata', { width: image.naturalWidth, height: image.naturalHeight }));
      image.src = sourceURL;
      image.alt = fileName;
      stage.appendChild(image);
      makeTopControls([
        control('&#x2212;', '缩小', () => { scale = Math.max(.2, scale - .1); apply(); }),
        control('&#x2B;', '放大', () => { scale = Math.min(5, scale + .1); apply(); }),
        control('1:1', '实际大小', () => { fit = !fit; scale = 1; apply(); }),
        control('&#x21BB;', '顺时针旋转', () => { rotation = (rotation + 90) % 360; apply(); })
      ]);
      apply();
      installAutoHide();
    }
    function renderVideo() {
      app.innerHTML = '<div id="stage"></div>';
      const stage = document.getElementById('stage');
      const video = document.createElement('video');
      video.preload = 'metadata';
      video.playsInline = true;
      video.src = sourceURL;
      video.addEventListener('loadedmetadata', () => post('metadata', { width: video.videoWidth, height: video.videoHeight }));
      stage.appendChild(video);
      makeTopControls();
      const transport = document.createElement('div');
      transport.className = 'floating transport';
      const rewind = control('-10', '快退 10 秒', () => { video.currentTime = Math.max(0, video.currentTime - 10); });
      const play = control('&#x25B6;', '播放', () => video.paused ? video.play() : video.pause(), true);
      const forward = control('+10', '快进 10 秒', () => { video.currentTime = Math.min(video.duration || Infinity, video.currentTime + 10); });
      const elapsed = document.createElement('span'); elapsed.className = 'time';
      const duration = document.createElement('span'); duration.className = 'time';
      const progress = document.createElement('input'); progress.className = 'range'; progress.type = 'range'; progress.min = '0'; progress.step = '.05';
      const mute = control('&#x1F50A;', '静音', () => {});
      const volume = document.createElement('input'); volume.id = 'video-volume'; volume.className = 'volume-range'; volume.type = 'range'; volume.min = '0'; volume.max = '1'; volume.step = '.01'; volume.value = '1'; volume.setAttribute('aria-label', '视频音量');
      [rewind, play, forward, elapsed, progress, duration, mute, volume].forEach(item => transport.appendChild(item));
      app.appendChild(transport);
      bindPlayer(video, progress, elapsed, duration, play);
      bindVolume(video, mute, volume);
      video.addEventListener('click', () => video.paused ? video.play() : video.pause());
      installAutoHide();
    }
    function renderAudio() {
      app.innerHTML = '<div class="audio-shell"><div class="audio-art">&#x266B;</div><div class="audio-main"><div><div class="audio-title"></div><div class="audio-meta"></div></div><div class="audio-progress"><span class="time elapsed"></span><input class="range" type="range" min="0" step=".05"><span class="time duration"></span></div><div class="audio-actions"></div></div><div class="audio-close"></div></div>';
      app.querySelector('.audio-title').textContent = fileName;
      app.querySelector('.audio-meta').textContent = fileSize;
      const audio = document.createElement('audio');
      audio.className = 'audio-engine';
      audio.setAttribute('aria-hidden', 'true');
      audio.preload = 'metadata';
      audio.src = sourceURL;
      app.appendChild(audio);
      const actions = app.querySelector('.audio-actions');
      const rewind = control('-10', '快退 10 秒', () => { audio.currentTime = Math.max(0, audio.currentTime - 10); });
      const play = control('&#x25B6;', '播放', () => audio.paused ? audio.play() : audio.pause(), true);
      const forward = control('+10', '快进 10 秒', () => { audio.currentTime = Math.min(audio.duration || Infinity, audio.currentTime + 10); });
      const mute = control('&#x1F50A;', '静音', () => {});
      const volume = document.createElement('input'); volume.id = 'audio-volume'; volume.className = 'volume-range'; volume.type = 'range'; volume.min = '0'; volume.max = '1'; volume.step = '.01'; volume.value = '1'; volume.setAttribute('aria-label', '音频音量');
      [rewind, play, forward, mute, volume].forEach(item => actions.appendChild(item));
      app.querySelector('.audio-close').appendChild(control('&#x2715;', '关闭', () => post('close')));
      bindPlayer(audio, app.querySelector('.range'), app.querySelector('.elapsed'), app.querySelector('.duration'), play);
      bindVolume(audio, mute, volume);
    }
    function renderUnsupported() {
      app.innerHTML = '<div id="stage"><div class="unsupported"><strong></strong><span>无法预览此媒体格式</span></div></div>';
      app.querySelector('strong').textContent = fileName;
      makeTopControls();
    }
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape') post('close');
    });
    if (mode === 'image') renderImage();
    else if (mode === 'video') renderVideo();
    else if (mode === 'audio') renderAudio();
    else renderUnsupported();
  </script>
</body>
</html>
"""#
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return string
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }
}

@MainActor
public final class FileWorkspaceMediaWindowController: NSWindowController, NSWindowDelegate {
    public let mediaViewController: FileWorkspaceMediaViewController
    public var onClose: ((FileWorkspaceMediaWindowController) -> Void)?
    private nonisolated let mediaSourceURL: URL
    private var didReleaseMediaSource = false

    public init(document: FileWorkspaceMediaDocument) {
        mediaViewController = FileWorkspaceMediaViewController(document: document)
        mediaSourceURL = document.sourceURL
        let isAudio = document.contentKind == .audio
        let initialSize = isAudio ? NSSize(width: 520, height: 156) : NSSize(width: 960, height: 640)
        var styleMask: NSWindow.StyleMask = [.borderless, .closable]
        if isAudio == false {
            styleMask.insert(.resizable)
        }
        let window = FileWorkspaceKeyableMediaWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = document.fileName
        window.contentViewController = mediaViewController
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = isAudio ? initialSize : NSSize(width: 480, height: 320)
        if isAudio {
            window.contentMaxSize = initialSize
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        window.setContentSize(initialSize)
        super.init(window: window)
        window.delegate = self
        mediaViewController.onCloseRequested = { [weak self] in
            self?.close()
        }
        mediaViewController.onPreferredAspectRatioChanged = { [weak self] width, height in
            self?.applyPreferredAspectRatio(width: width, height: height)
        }
        window.center()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func windowWillClose(_ notification: Notification) {
        releaseMediaSource()
        onClose?(self)
    }

    deinit {
        RemoteFileOnlineMediaRegistry.shared.unregister(url: mediaSourceURL)
    }

    private func applyPreferredAspectRatio(width: CGFloat, height: CGFloat) {
        guard let window,
              mediaViewController.document.contentKind != .audio,
              width > 0,
              height > 0
        else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let maximum = NSSize(width: visible.width * 0.82, height: visible.height * 0.82)
        let ratio = width / height
        let fitScale = min(maximum.width / width, maximum.height / height)
        let preferredScale = 640 / max(width, height)
        let scale = min(fitScale, max(1, preferredScale))
        let targetWidth = max(1, width * scale)
        let targetHeight = max(1, height * scale)
        let minimumLongEdge: CGFloat = 320
        window.contentMinSize = ratio >= 1
            ? NSSize(width: minimumLongEdge, height: minimumLongEdge / ratio)
            : NSSize(width: minimumLongEdge * ratio, height: minimumLongEdge)
        window.contentAspectRatio = NSSize(width: width, height: height)
        window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
        window.center()
    }

    private func releaseMediaSource() {
        guard didReleaseMediaSource == false else { return }
        didReleaseMediaSource = true
        RemoteFileOnlineMediaRegistry.shared.unregister(url: mediaSourceURL)
    }
}

private final class FileWorkspaceKeyableMediaWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class FileWorkspaceMediaScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: FileWorkspaceMediaViewController?

    init(owner: FileWorkspaceMediaViewController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in
            self?.owner?.handleScriptMessage(message.body)
        }
    }
}

private final class FileWorkspaceMediaDragHandleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let grip = NSRect(x: bounds.midX - 16, y: bounds.midY - 2, width: 32, height: 4)
        NSColor.white.withAlphaComponent(0.36).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
