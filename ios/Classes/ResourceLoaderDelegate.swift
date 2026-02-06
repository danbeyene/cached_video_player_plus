import Foundation
import AVFoundation

class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    
    private let remoteUrl: URL
    private var isTaskRunning = false
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var response: URLResponse?
    private var cacheFileHandle: FileHandle?
    private let cacheFilePath: String
    
    // Track loaded ranges
    private var loadingRequests = [AVAssetResourceLoadingRequest]()
    
    // State
    private var isHandled416 = false
    private var isDownloadComplete = false
    private var isCacheReady = false
    private var hasIncrementedActiveCount = false
    
    // Queue for thread safety
    private let queue = DispatchQueue(label: "com.cached_video_player_plus.resourceLoader")

    init(remoteUrl: URL, cacheFilePath: String) {
        self.remoteUrl = remoteUrl
        self.cacheFilePath = cacheFilePath
        super.init()
        // File I/O moved to ensureCacheReady() called on queue
    }
    
    private func ensureCacheReady() {
        if isCacheReady { return }
        
        do {
            // Ensure directory exists
            let directory = (cacheFilePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
            
            // Create file if not exists
            if !FileManager.default.fileExists(atPath: cacheFilePath) {
                FileManager.default.createFile(atPath: cacheFilePath, contents: nil, attributes: nil)
            }
            
            self.cacheFileHandle = FileHandle(forUpdatingAtPath: cacheFilePath)
            isCacheReady = true
        } catch {
            // print("CVPP: Error ensuring cache ready: \(error)")
        }
    }
    
    func cancel() {
        session?.invalidateAndCancel()
        // Synchronize cleanup to avoid race with data writing
        queue.sync {
            cleanup()
            if hasIncrementedActiveCount {
                CacheManager.shared.decrementActiveDownloadCount()
                hasIncrementedActiveCount = false
            }
        }
    }
    
    private func cleanup() {
        cacheFileHandle?.closeFile()
        cacheFileHandle = nil
        isCacheReady = false
    }

    deinit {
        session?.invalidateAndCancel()
        cleanup()
    }
    
    // MARK: - AVAssetResourceLoaderDelegate
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        queue.sync {
            ensureCacheReady() // Lazy init on background queue
            loadingRequests.append(loadingRequest)
            processLoadingRequests()
            
            if !isTaskRunning && !isDownloadComplete {
                startDataRequest()
            }
        }
        
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        queue.sync {
            if let index = loadingRequests.firstIndex(of: loadingRequest) {
                loadingRequests.remove(at: index)
            }
        }
    }
    
    // MARK: - Logic
    
    private func startDataRequest() {
        if isDownloadComplete { return }
        
        // Simple implementation: Download from byte 0 to end (or resume)
        // Check how much we have downloaded
        let currentFileSize = getCurrentFileSize()
        
        // print("CVPP: Starting data request. Current Cache Size: \(currentFileSize)")
        
        if !hasIncrementedActiveCount {
            CacheManager.shared.incrementActiveDownloadCount()
            hasIncrementedActiveCount = true
        }

        // Create request
        var request = URLRequest(url: remoteUrl)
        
        if currentFileSize > 0 {
             request.addValue("bytes=\(currentFileSize)-", forHTTPHeaderField: "Range")
        }
        
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        dataTask = session?.dataTask(with: request)
        dataTask?.resume()
        isTaskRunning = true
    }
    
    private func processLoadingRequests() {
        // Iterate over requests and satisfy them if data is available
        let currentFileSize = Int64(getCurrentFileSize())
        
        loadingRequests.removeAll { request in
            // 1. Fill Content ContentInformationRequest
            if let contentInfo = request.contentInformationRequest {
                // If we have a successful response (200/206), use it.
                if let response = self.response as? HTTPURLResponse, (response.statusCode == 200 || response.statusCode == 206) {
                     let mimeType = response.mimeType ?? "application/octet-stream"
                     contentInfo.contentType = mimeType
                     let length = self.getTotalLength(response: response)
                     contentInfo.contentLength = length
                     contentInfo.isByteRangeAccessSupported = true
                     // print("CVPP: Responding to content info (Network). Type: \(mimeType), Length: \(length)")
                } else if self.isHandled416 || self.isDownloadComplete {
                     // We encountered a 416 but confirmed we have the file.
                     // Use local file size.
                     let mimeType = "video/mp4" 
                     let length = currentFileSize
                     contentInfo.contentType = mimeType
                     contentInfo.contentLength = length
                     contentInfo.isByteRangeAccessSupported = true
                     // print("CVPP: Responding to content info (Cached/Finished). Type: \(mimeType), Length: \(length)")
                } else {
                    // We don't have response yet, can't satisfy content info
                    return false
                }
            }
            
            // 2. dataRequest
            if let dataRequest = request.dataRequest {
                // Check if we have enough data to satisfy (at least partially)
                
                // Use currentOffset to know where to continue sending from
                let currentOffset = Int64(dataRequest.currentOffset)
                let requestedStart = Int64(dataRequest.requestedOffset)
                let lengthNeeded = Int64(dataRequest.requestedLength)
                let requestedEnd = requestedStart + lengthNeeded
                
                // print("CVPP: Request: \(requestedStart)-\(requestedEnd). Current: \(currentOffset). Available: \(currentFileSize)")
                
                if currentOffset < currentFileSize {
                     // We have some data starting from currentOffset
                     let availableEnd = min(requestedEnd, currentFileSize)
                     let lengthToRead = Int(availableEnd - currentOffset)
                     
                     if lengthToRead > 0 {
                         if let data = readCachedData(offset: UInt64(currentOffset), length: lengthToRead) {
                             dataRequest.respond(with: data)
                             // Re-calculate completion after writing
                             let newCurrentOffset = currentOffset + Int64(data.count)
                             
                             if newCurrentOffset >= requestedEnd {
                                 request.finishLoading()
                                 return true
                             }
                         }
                     }
                     
                     // If we are done downloading, and we gave all we had, we should finish.
                     if self.isDownloadComplete && availableEnd == currentFileSize {
                         request.finishLoading()
                         return true
                     }
                }
                
                // Special case for EOF conditions
                if requestedStart >= currentFileSize {
                    if self.isDownloadComplete || self.isHandled416 {
                        // We are done, no more data.
                         request.finishLoading()
                         return true
                    }
                }
            } else {
                // If it's just content info and we filled it
                request.finishLoading()
                return true
            }
            
            return false // Keep waiting
        }
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.sync {
            ensureCacheReady()
            self.response = response
            
            if let httpResponse = response as? HTTPURLResponse {
                // print("CVPP: Received Response: \(httpResponse.statusCode), MIME: \(httpResponse.mimeType ?? "nil")")
                
                if httpResponse.statusCode == 200 {
                    // Full content.
                     do {
                        if #available(iOS 13.0, *) {
                            try self.cacheFileHandle?.truncate(atOffset: 0)
                        } else {
                            self.cacheFileHandle?.truncateFile(atOffset: 0)
                        }
                    } catch {
                        // print("Error truncating file: \(error)")
                    }
                } else if httpResponse.statusCode == 416 {
                    // Invalid Range.
                    // print("CVPP: 416 Headers: \(httpResponse.allHeaderFields)")
                    let totalLength = getTotalLength(response: httpResponse)
                    let currentSize = Int64(getCurrentFileSize())
                    
                    if totalLength > 0 {
                        if currentSize > totalLength {
                            // print("CVPP: Cache size (\(currentSize)) > Total (\(totalLength)). Truncating to match.")
                            // Truncate
                             do {
                                if #available(iOS 13.0, *) {
                                    try self.cacheFileHandle?.truncate(atOffset: UInt64(totalLength))
                                } else {
                                    self.cacheFileHandle?.truncateFile(atOffset: UInt64(totalLength))
                                }
                                self.isHandled416 = true
                                self.isDownloadComplete = true
                                // print("CVPP: Truncation success. Download complete.")
                            } catch {
                                // print("Error truncating file: \(error)")
                            }
                        } else if currentSize == totalLength {
                            // print("CVPP: File size matches total. Download complete.")
                            self.isHandled416 = true
                            self.isDownloadComplete = true
                        } else {
                             // print("CVPP: 416 but local smaller than total? Local: \(currentSize), Total: \(totalLength)")
                             self.isDownloadComplete = true 
                        }
                    } else {
                         // print("CVPP: 416 received but could not determine total length. Stopping.")
                         self.isDownloadComplete = true
                    }
                     processLoadingRequests()
                } else if httpResponse.statusCode >= 400 {
                    // print("CVPP: Error status code received!")
                }
            }
            processLoadingRequests()
        }
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.sync {
            // Log data content if it looks like an error (small and XML)
            if let response = self.response as? HTTPURLResponse, 
               (response.mimeType == "application/xml" || response.mimeType == "text/xml" || response.statusCode >= 400),
               !self.isHandled416,
               let body = String(data: data, encoding: .utf8) {
                let logBody = body.count > 500 ? String(body.prefix(500)) + "..." : body
                // print("CVPP: Error Body: \(logBody)")
            }

            // Do NOT append data if status indicates error (like 416)
            if let response = self.response as? HTTPURLResponse, response.statusCode >= 400 {
                 // Do nothing
            } else {
                // Check if file still exists to avoid race condition with external deletion
                if !FileManager.default.fileExists(atPath: self.cacheFilePath) {
                    // File gone, stop writing.
                    return
                }
                
                // Append data to file
                if let handle = self.cacheFileHandle {
                    do {
                        if #available(iOS 13.4, *) {
                            try handle.seekToEnd()
                            try handle.write(contentsOf: data)
                        } else {
                            // Fallback for iOS 13.0-13.3 (risky but rare)
                            handle.seekToEndOfFile()
                            handle.write(data)
                        }
                    } catch {
                        // print("CVPP: Error writing to cache file: \(error)")
                    }
                }
            }
            
            processLoadingRequests()
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.sync {
            isTaskRunning = false
            
            if hasIncrementedActiveCount {
                CacheManager.shared.decrementActiveDownloadCount()
                hasIncrementedActiveCount = false
            }
            
            if let error = error {
                 let nsError = error as NSError
                 if nsError.code == NSURLErrorCancelled {
                     // Ignore cancelled errors (benign)
                 } else if !isHandled416 && !isDownloadComplete {
                     // print("CVPP: Download failed with error: \(error)")
                     for request in loadingRequests {
                         request.finishLoading(with: error)
                     }
                     loadingRequests.removeAll()
                 }
            } else {
                if !isDownloadComplete {
                     if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                         self.isDownloadComplete = true
                         // print("CVPP: Download finished (200).")
                     } else {
                         // Assume 206 partial finished means we got what we asked for.
                         // Check if we have the WHOLE file? Not necessarily, but for this simple loader we assume we stream to end.
                         self.isDownloadComplete = true
                         // print("CVPP: Download finished (206/Other).")
                     }
                }
                
                processLoadingRequests() 
                
                 for request in loadingRequests {
                    if let _ = request.contentInformationRequest {
                         request.finishLoading() 
                    } else if let dataReq = request.dataRequest {
                          let currentSize = Int64(getCurrentFileSize())
                          let reqStart = dataReq.requestedOffset
                          if reqStart >= currentSize {
                              request.finishLoading() // EOF
                          } else {
                              if isDownloadComplete {
                                  request.finishLoading()
                              }
                          }
                    } else {
                        request.finishLoading()
                    }
                }
                loadingRequests.removeAll()
            }
        }
    }
    
    // MARK: - Helpers
    
    private func getCurrentFileSize() -> UInt64 {
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: cacheFilePath)
            return attr[.size] as? UInt64 ?? 0
        } catch {
            return 0
        }
    }
    
    private func readCachedData(offset: UInt64, length: Int) -> Data? {
        // Ensure cache is ready before reading (though usually reading happens after ensureCacheReady in flow)
        if cacheFileHandle == nil { return nil }
        
        guard let handle = cacheFileHandle else { return nil }
        do {
            try handle.seek(toOffset: offset)
            return handle.readData(ofLength: length)
        } catch {
            return nil
        }
    }
    
    private func getTotalLength(response: HTTPURLResponse) -> Int64 {
        let headers = response.allHeaderFields
        
        // 1. Try x-goog-stored-content-length (GCS specific)
        let gcsLengthKey = headers.keys.first { ($0 as? String)?.localizedCaseInsensitiveContains("x-goog-stored-content-length") == true }
        if let key = gcsLengthKey {
            if let val = headers[key] as? String, let total = Int64(val) {
                return total
            } else if let val = headers[key] as? Int64 {
                return val
            } else if let val = headers[key] as? Int, let total = Int64("\(val)") {
                return total
            }
        }

        // 2. Try Content-Range
        let contentRangeKey = headers.keys.first { ($0 as? String)?.localizedCaseInsensitiveContains("Content-Range") == true }
        if let key = contentRangeKey, let rangeHeader = headers[key] as? String {
             if let lastSlash = rangeHeader.lastIndex(of: "/") {
                 let totalStr = rangeHeader[rangeHeader.index(after: lastSlash)...]
                 if let total = Int64(totalStr) {
                     return total
                 }
             }
        }
        
        // 3. Fallback to Content-Length if 200 OK
        if response.statusCode == 200 {
            return response.expectedContentLength
        }
        
        return 0
    }
}
