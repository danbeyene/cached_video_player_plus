import Foundation
import CommonCrypto
import Flutter

class CacheManager {
    static let shared = CacheManager()
    
    private let fileManager = FileManager.default
    private let cacheDirectoryName = "cached_video_player_plus"
    
    // Concurrency & Priority
    let preCacheQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.cached_video_player_plus.preCacheQueue"
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    
    private let stateQueue = DispatchQueue(label: "com.cached_video_player_plus.stateQueue", attributes: .concurrent)
    private let _fileSystemQueue = DispatchQueue(label: "com.cached_video_player_plus.fileSystemQueue") // Serial queue for FS safety
    
    private var _activeDownloadCount = 0
    
    private var cacheDirectory: URL {
        return fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(cacheDirectoryName)
    }
    
    init() {
        createCacheDirectory()
    }
    
    private func createCacheDirectory() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    func getCachePath(for url: String) -> String {
        let fileName = sha256(url) + ".mp4"
        return cacheDirectory.appendingPathComponent(fileName).path
    }
    
    // MARK: - Priority Management
    
    func incrementActiveDownloadCount() {
        stateQueue.async(flags: .barrier) {
            self._activeDownloadCount += 1
            self.updateQueueSuspension()
        }
    }
    
    func decrementActiveDownloadCount() {
        stateQueue.async(flags: .barrier) {
            if self._activeDownloadCount > 0 {
                self._activeDownloadCount -= 1
            }
            self.updateQueueSuspension()
        }
    }
    
    private func updateQueueSuspension() {
        // If videos are downloading, suspend pre-caching (concurrency 0 effectively)
        let isSuspended = _activeDownloadCount > 0
        
        // We need to be careful not to trigger UI/main thread stuff here, just update the queue
        if preCacheQueue.isSuspended != isSuspended {
            preCacheQueue.isSuspended = isSuspended
            // print("CVPP: Pre-cache queue suspended? \(isSuspended) (Active downloads: \(_activeDownloadCount))")
        }
    }
    
    // MARK: - File System Operations
    
    func clearAllCache() {
        _fileSystemQueue.async {
            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil, options: [])
                for fileURL in fileURLs {
                    try self.fileManager.removeItem(at: fileURL)
                }
                // print("CVPP: Cleared all cache.")
            } catch {
                // print("CVPP: Error clearing cache: \(error)")
            }
        }
    }
    
    func removeFile(for url: String) {
        _fileSystemQueue.async {
            let path = self.getCachePath(for: url)
            if self.fileManager.fileExists(atPath: path) {
                do {
                    try self.fileManager.removeItem(atPath: path)
                    // print("CVPP: Removed file for url: \(url)")
                } catch {
                    // print("CVPP: Error removing file: \(error)")
                }
            }
        }
    }
    
    func enforceCacheLimit(maxSize: Int64) {
        _fileSystemQueue.async {
            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [])
                
                var totalSize: Int64 = 0
                var files = [(url: URL, size: Int64, date: Date)]()
                
                for fileURL in fileURLs {
                    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    if let size = values.fileSize, let date = values.contentModificationDate {
                        let sizeInt64 = Int64(size)
                        totalSize += sizeInt64
                        files.append((url: fileURL, size: sizeInt64, date: date))
                    }
                }
                
                if totalSize <= maxSize {
                    // print("CVPP: Cache size (\(totalSize)) is within limit (\(maxSize)).")
                    return
                }
                
                // Sort by date (oldest first)
                files.sort { $0.date < $1.date }
                
                for file in files {
                    if totalSize <= maxSize { break }
                    
                    try self.fileManager.removeItem(at: file.url)
                    totalSize -= file.size
                    // print("CVPP: Deleted old cache file: \(file.url.lastPathComponent)")
                }
                
            } catch {
                // print("CVPP: Error enforcing cache limit: \(error)")
            }
        }
    }
    
    private func sha256(_ string: String) -> String {
        let data = string.data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Pre-Caching
    
    func preCache(url: String, headers: [String: String], completion: @escaping (FlutterError?) -> Void) {
        let op = PreCacheOperation(url: url, headers: headers, cacheManager: self)
        op.completionBlock = {
            completion(op.error)
        }
        preCacheQueue.addOperation(op)
    }
}

class PreCacheOperation: Operation {
    let url: String
    let headers: [String: String]
    let cacheManager: CacheManager
    var error: FlutterError?
    
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    
    // State management for Async Operation
    private var _executing: Bool = false
    override var isExecuting: Bool {
        get { return _executing }
        set {
            willChangeValue(forKey: "isExecuting")
            _executing = newValue
            didChangeValue(forKey: "isExecuting")
        }
    }
    
    private var _finished: Bool = false
    override var isFinished: Bool {
        get { return _finished }
        set {
            willChangeValue(forKey: "isFinished")
            _finished = newValue
            didChangeValue(forKey: "isFinished")
        }
    }
    
    init(url: String, headers: [String: String], cacheManager: CacheManager) {
        self.url = url
        self.headers = headers
        self.cacheManager = cacheManager
        super.init()
    }
    
    override var isAsynchronous: Bool { return true }
    
    override func start() {
        if isCancelled {
            isFinished = true
            return
        }
        
        isExecuting = true
        
        let path = cacheManager.getCachePath(for: url)
        if FileManager.default.fileExists(atPath: path) {
            // Already cached
            finish()
            return
        }
        
        guard let remoteUrl = URL(string: url) else {
            self.error = FlutterError(code: "invalid_url", message: "Invalid URL", details: nil)
            finish()
            return
        }
        
        var request = URLRequest(url: remoteUrl)
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        
        task = URLSession.shared.downloadTask(with: request) { [weak self] localUrl, response, error in
            guard let self = self else { return }
            
            if let error = error {
                // print("CVPP: Pre-cache error: \(error)")
                self.error = FlutterError(code: "download_failed", message: error.localizedDescription, details: nil)
                self.finish()
                return
            }
            
            guard let localUrl = localUrl else {
                self.error = FlutterError(code: "download_failed", message: "No file", details: nil)
                self.finish()
                return
            }
            
            do {
                let destination = URL(fileURLWithPath: path)
                // Remove if exists
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                
                try FileManager.default.moveItem(at: localUrl, to: destination)
                // print("CVPP: Pre-cache success for \(self.url)")
                self.finish()
            } catch {
                // print("CVPP: Pre-cache move error: \(error)")
                self.error = FlutterError(code: "file_error", message: error.localizedDescription, details: nil)
                self.finish()
            }
        }
        
        task?.resume()
    }
    
    override func cancel() {
        task?.cancel()
        super.cancel()
    }
    
    private func finish() {
        isExecuting = false
        isFinished = true
    }
}
