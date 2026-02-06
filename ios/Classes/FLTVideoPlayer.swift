import Flutter
import AVFoundation
import CommonCrypto

class FLTVideoPlayer: NSObject, FlutterTexture {
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var resourceLoaderDelegate: ResourceLoaderDelegate?
    private let registrar: FlutterPluginRegistrar
    private var eventChannel: FlutterEventChannel?
    private var _eventSink: FlutterEventSink?
    
    var textureId: Int64 = -1
    private var isLooping = false
    private var isInitialized = false
    
    init(uri: String, registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        super.init()
        setupPlayer(uri: uri)
    }
    
    func setupEventChannel(textureId: Int64) {
        self.textureId = textureId
        let channel = FlutterEventChannel(name: "cached_video_player_plus/videoEvents\(textureId)", binaryMessenger: registrar.messenger())
        channel.setStreamHandler(self)
        self.eventChannel = channel
    }
    
    private func setupPlayer(uri: String) {
        guard let url = URL(string: uri) else { return }
        
        let asset: AVURLAsset
        if url.scheme == "cache" {
            // Custom scheme! Use ResourceLoader
            // Convert to https for internal remote URL logic (ResourceLoaderDelegate will handle)
            // But we pass the CUSTOM scheme URL to AVURLAsset so it triggers the delegate.
            asset = AVURLAsset(url: url)
            
            // Generate a valid cache path using shared manager
            // Reconstruct the actual remote URL (replace cache:// with https://)
            // Defaulting to https for security compliance.
            var remoteComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            remoteComponents.scheme = "https"
            let remoteUrl = remoteComponents.url!
            
            // Use unified path generation
            let cachePath = CacheManager.shared.getCachePath(for: remoteUrl.absoluteString)
            
            resourceLoaderDelegate = ResourceLoaderDelegate(remoteUrl: remoteUrl, cacheFilePath: cachePath)
            
            let queue = DispatchQueue(label: "com.cached_video_player_plus.resourceLoaderQueue")
            asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: queue)
        } else {
            // Standard URL
            asset = AVURLAsset(url: url)
        }
        
        playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        
        if #available(iOS 10.0, *) {
            player?.automaticallyWaitsToMinimizeStalling = false
        }
        
        setupVideoOutput()
        addObservers(item: playerItem!)
        setupDisplayLink()
    }
    
    private func setupVideoOutput() {
        let pixBuffAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixBuffAttributes)
        playerItem?.add(videoOutput!)
    }
    
    private func addObservers(item: AVPlayerItem) {
        item.addObserver(self, forKeyPath: "status", options: .new, context: nil)
        item.addObserver(self, forKeyPath: "loadedTimeRanges", options: .new, context: nil)
        item.addObserver(self, forKeyPath: "presentationSize", options: .new, context: nil)
        item.addObserver(self, forKeyPath: "duration", options: .new, context: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidPlayToEndTime), name: .AVPlayerItemDidPlayToEndTime, object: item)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath else { return }
        
        switch keyPath {
        case "status":
            if let item = playerItem {
                if item.status == .readyToPlay {
                    if !isInitialized {
                        isInitialized = true
                        sendInitialized()
                    }
                } else if item.status == .failed {
                    _eventSink?(FlutterError(code: "VideoError", message: "Failed to load video: \(String(describing: item.error))", details: nil))
                }
            }
        case "loadedTimeRanges":
            // Send buffering update
            if let ranges = playerItem?.loadedTimeRanges, let first = ranges.first {
                let range = first.timeRangeValue
                let start = CMTimeGetSeconds(range.start)
                let duration = CMTimeGetSeconds(range.duration)
                var values: [String: Any] = [:]
                values["event"] = "bufferingUpdate"
                values["values"] = [[Int(start * 1000), Int((start + duration) * 1000)]]
                _eventSink?(values)
            }
        case "presentationSize":
            if isInitialized { 
                // Handle size change if needed
            }
        case "duration":
            break
        default:
            break
        }
    }
    
    private func sendInitialized() {
        guard let item = playerItem, isInitialized else { return }
        let size = item.presentationSize
        var width = size.width
        var height = size.height
        let duration = Int(CMTimeGetSeconds(item.duration) * 1000)
        
        // Handle rotation if needed (skipped for brevity)
        
        var event: [String: Any] = [:]
        event["event"] = "initialized"
        event["duration"] = duration
        event["width"] = width
        event["height"] = height
        _eventSink?(event)
    }
    
    @objc func itemDidPlayToEndTime() {
        if isLooping {
            seek(to: 0)
            play()
        } else {
            _eventSink?(["event": "completed"])
        }
    }
    
    // Old controls removed

    
    private var displayLink: CADisplayLink?
    
    // MARK: - FlutterTexture
    
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let output = videoOutput, let item = playerItem else { return nil }
        let time = item.currentTime()
        
        if output.hasNewPixelBuffer(forItemTime: time) {
            if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                return Unmanaged.passRetained(buffer)
            }
        }
        return nil
    }

    func onTextureUnregistered(_ texture: FlutterTexture) {
        // Texture unregistered
    }
    
    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
        displayLink?.add(to: .current, forMode: .common)
        displayLink?.isPaused = true
    }
    
    @objc func onDisplayLink(_ link: CADisplayLink) {
        guard let output = videoOutput, let item = playerItem else { return }
        
        // We only notify if there is a new pixel buffer available.
        // The texture registry will then call copyPixelBuffer()
        let time = item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time) {
            registrar.textures().textureFrameAvailable(textureId)
        }
    }
    
    // MARK: - Method Handling
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "play": play(); result(nil)
        case "pause": pause(); result(nil)
        case "setLooping":
            if let args = call.arguments as? [String: Any], let looping = args["looping"] as? Bool {
                setLooping(looping)
            }
            result(nil)
        case "setVolume":
             if let args = call.arguments as? [String: Any], let volume = args["volume"] as? Double {
                setVolume(volume)
            }
            result(nil)
        case "seekTo":
            if let args = call.arguments as? [String: Any], let position = args["position"] as? Int {
                seek(to: position)
            }
            result(nil)
        case "setPlaybackSpeed":
             if let args = call.arguments as? [String: Any], let speed = args["speed"] as? Double {
                setPlaybackSpeed(speed)
            }
            result(nil)
        case "position":
            result(getPosition())
        case "dispose":
            dispose()
            registrar.textures().unregisterTexture(textureId)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Controls Implementation
    
    func play() {
        player?.play()
        displayLink?.isPaused = false
    }
    
    func pause() {
        player?.pause()
        displayLink?.isPaused = true
    }
    
    func setLooping(_ looping: Bool) { isLooping = looping }
    
    func setVolume(_ volume: Double) { player?.volume = Float(volume) }
    
    func setPlaybackSpeed(_ speed: Double) {
        let oldRate = player?.rate ?? 0
        player?.rate = Float(speed)
    }
    
    func seek(to position: Int) {
        let time = CMTimeMake(value: Int64(position), timescale: 1000)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func getPosition() -> Int {
        guard let player = player else { return 0 }
        return Int(CMTimeGetSeconds(player.currentTime()) * 1000)
    }
    
    func dispose() {
        
        displayLink?.invalidate()
        displayLink = nil
        
        playerItem?.removeObserver(self, forKeyPath: "status")
        playerItem?.removeObserver(self, forKeyPath: "loadedTimeRanges")
        playerItem?.removeObserver(self, forKeyPath: "presentationSize")
        playerItem?.removeObserver(self, forKeyPath: "duration")
        NotificationCenter.default.removeObserver(self)
        
        videoOutput = nil
        playerItem = nil
        player = nil
        resourceLoaderDelegate?.cancel()
        resourceLoaderDelegate = nil 
    }
}

extension FLTVideoPlayer: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self._eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self._eventSink = nil
        return nil
    }
}

