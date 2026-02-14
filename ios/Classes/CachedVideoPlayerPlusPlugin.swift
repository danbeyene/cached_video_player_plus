import Flutter
import UIKit
import AVFoundation

public class CachedVideoPlayerPlusPlugin: NSObject, FlutterPlugin {
    private let registrar: FlutterPluginRegistrar
    private var players = [Int64: FLTVideoPlayer]()
    private let playersQueue = DispatchQueue(label: "cached_video_player_plus.playersQueue")

    init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "cached_video_player_plus", binaryMessenger: registrar.messenger())
        let instance = CachedVideoPlayerPlusPlugin(registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "init":
            result(nil)
        case "create":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "invalid_args", message: "Arguments are missing", details: nil))
                return
            }
            create(args: args, result: result)
        case "setMixWithOthers":
            guard let args = call.arguments as? [String: Any],
                  let mixWithOthers = args["mixWithOthers"] as? Bool else {
                result(FlutterError(code: "invalid_args", message: "mixWithOthers argument missing", details: nil))
                return
            }
            let session = AVAudioSession.sharedInstance()
            do {
                if mixWithOthers {
                    try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
                } else {
                    try session.setCategory(.playback, mode: .default, options: [])
                }
                result(nil)
            } catch {
                result(FlutterError(code: "set_category_error", message: error.localizedDescription, details: nil))
            }
        case "clearAllCache":
            playersQueue.async {
                CacheManager.shared.clearAllCache()
                DispatchQueue.main.async { result(nil) }
            }
        case "enforceCacheLimit":
            if let args = call.arguments as? [String: Any], let max = args["maxCacheSize"] as? Int64 {
                playersQueue.async {
                    CacheManager.shared.enforceCacheLimit(maxSize: max)
                    DispatchQueue.main.async { result(nil) }
                }
            } else {
                 result(FlutterError(code: "invalid_args", message: "maxCacheSize missing", details: nil))
            }
        case "removeFile":
             if let args = call.arguments as? [String: Any], let url = args["url"] as? String {
                playersQueue.async {
                    CacheManager.shared.removeFile(for: url)
                    DispatchQueue.main.async { result(nil) }
                }
            } else {
                 result(FlutterError(code: "invalid_args", message: "url missing", details: nil))
            }
        case "preCache":
             if let args = call.arguments as? [String: Any], let url = args["url"] as? String {
                 let headers = args["headers"] as? [String: String] ?? [:]
                 preCache(url: url, headers: headers, result: result)
            } else {
                 result(FlutterError(code: "invalid_args", message: "url missing", details: nil))
            }
        default:
            guard let args = call.arguments as? [String: Any],
                  let textureId = args["textureId"] as? Int64 else {
                result(FlutterMethodNotImplemented)
                return
            }
            
            playersQueue.sync {
                guard let player = players[textureId] else {
                    result(FlutterError(code: "unknown_player", message: "No player found for textureId \(textureId)", details: nil))
                    return
                }
                
                if call.method == "setCaptionOffset" {
                    if let offset = args["offset"] as? Int {
                        player.setCaptionOffset(offset)
                    }
                    result(nil)
                    return
                }
                
                if call.method == "dispose" {
                    players.removeValue(forKey: textureId)
                }
                
                player.handle(call, result: result)
            }
        }
    }
    
    private func create(args: [String: Any], result: @escaping FlutterResult) {
        guard let uri = args["uri"] as? String else {
             result(FlutterError(code: "invalid_args", message: "URI is required", details: nil))
             return
        }
        
        let assetName = args["asset"] as? String
        let packageName = args["package"] as? String
        
        var finalUri = uri
        if let assetName = assetName {
            let assetKey: String
            if let packageName = packageName {
                assetKey = registrar.lookupKey(forAsset: assetName, fromPackage: packageName)
            } else {
                assetKey = registrar.lookupKey(forAsset: assetName)
            }
            
            if let path = Bundle.main.path(forResource: assetKey, ofType: nil) {
                finalUri = URL(fileURLWithPath: path).absoluteString
            }
        }
        
        let player = FLTVideoPlayer(
            uri: finalUri,
            registrar: registrar
        )
        
        playersQueue.sync {
            let textureId = registrar.textures().register(player)
            player.textureId = textureId
            player.setupEventChannel(textureId: textureId)
            players[textureId] = player
            result(["textureId": textureId])
        }
    }
    
    // We need to keep strong references to pre-cachers so they don't deallocate
    // Note: Pre-caching is now managed by CacheManager's queue.

    private func preCache(url: String, headers: [String: String], result: @escaping FlutterResult) {
        CacheManager.shared.preCache(url: url, headers: headers) { error in
            DispatchQueue.main.async {
                if let error = error {
                    result(error)
                } else {
                    result(nil)
                }
            }
        }
    }
}
