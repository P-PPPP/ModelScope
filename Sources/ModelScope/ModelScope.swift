import Foundation
import Alamofire

public struct ModelScope {
    
    // MARK: - Models
    
    public struct ModelFile: Codable, Sendable {
        public let type: String
        public let name: String
        public let path: String
        public let size: Int
        public let revision: String
        
        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case name = "Name"
            case path = "Path"
            case size = "Size"
            case revision = "Revision"
        }
    }
    
    public struct ModelResponse: Codable, Sendable {
        public let code: Int
        public let data: ModelData
        
        enum CodingKeys: String, CodingKey {
            case code = "Code"
            case data = "Data"
        }
    }

    public struct ModelData: Codable, Sendable {
        let files: [ModelFile]
        
        enum CodingKeys: String, CodingKey {
            case files = "Files"
        }
    }
    
    /// 用于本地存储的文件状态信息（不存储绝对路径，只存储元数据）
    public struct FileStatus: Codable {
        let relativePath: String // 存储相对路径，例如 "model/config.json"
        let size: Int
        let revision: String
        let lastModified: Date
    }
    
    // MARK: - Download Manager
    
    @available(iOS 13.0, macOS 10.15, *)
    public actor DownloadManager: Sendable {
        
        private let repoPath: String
        private let baseURL = "https://modelscope.cn/api/v1/models"
        
        private var totalFiles = 0
        private var downloadedFilesCount = 0
        
        private let userDefaults = UserDefaults.standard
        private let downloadedFilesKey = "ModelDownloadManager.downloadedFiles"
        
        public init(repoPath: String) {
            self.repoPath = repoPath
        }
        
        /// 下载模型
        /// - Parameters:
        ///   - destinationURL: 下载的目标文件夹 URL。如果为 nil，默认下载到 Documents 目录。
        ///   - modelId: 模型 ID（用于过滤根目录下的文件夹名称）
        ///   - progress: 进度回调 (0.0 ~ 1.0)
        ///   - completion: 完成回调
        public func downloadModel(
            to destinationURL: URL? = nil,
            modelId: String,
            progress: ((Float) -> Void)? = nil,
            completion: @escaping (Result<Void, Error>) -> Void = { _ in }
        ) async {
            let progressHandler: (Float) -> Void = progress ?? { _ in }
            
            do {
                // 1. 确定目标根目录 (如果未指定，默认使用 Documents)
                let rootURL: URL
                if let destinationURL = destinationURL {
                    rootURL = destinationURL
                } else {
                    rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                }
                
                // 确保目标目录存在
                try createDirectory(at: rootURL)
                
                // 2. 获取根文件列表
                let files = try await fetchFileList(root: "", revision: "")
                
                // 3. 过滤出目标模型文件夹 (tree 类型且名字匹配)
                // 注意：这里保留了你原本的逻辑，即只下载根目录下名字等于 modelId 的文件夹
                let filteredFiles = files.filter { modelFile in
                    modelFile.name == modelId && modelFile.type == "tree"
                }
                
                // 计算需要下载的文件大致数量（这是一个估算，因为文件夹里还有文件，但用于初始化）
                // 更好的做法是在递归前先遍历所有层级计算总数，或者简单地在下载过程中动态更新进度。
                // 这里为了保持逻辑简单，暂时重置计数器。
                self.totalFiles = 0 
                self.downloadedFilesCount = 0
                
                // 4. 开始递归下载
                // 先简单计算一下第一层级的数量，实际进度在递归中会显得比较跳跃，这是文件树下载的常见问题
                self.totalFiles = filteredFiles.count 
                
                try await downloadFiles(
                    files: filteredFiles,
                    revision: "",
                    baseDestinationURL: rootURL,
                    progress: progressHandler
                )
                
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        
        // MARK: - Helper Methods
        
        private func createDirectory(at url: URL) throws {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            }
        }
        
        private func fetchFileList(root: String, revision: String) async throws -> [ModelFile] {
            let urlString = "\(baseURL)/\(repoPath)/repo/files"
            let parameters: Parameters = [
                "Root": root,
                "Revision": revision
            ]
            
            return try await withCheckedThrowingContinuation { continuation in
                AF.request(urlString, parameters: parameters)
                    .validate()
                    .responseDecodable(of: ModelResponse.self) { response in
                        switch response.result {
                        case .success(let modelResponse):
                            continuation.resume(returning: modelResponse.data.files)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
            }
        }
        
        private func downloadFiles(
            files: [ModelFile],
            revision: String,
            baseDestinationURL: URL,
            progress: @escaping (Float) -> Void
        ) async throws {
            // 如果这批文件是从子文件夹获取的，更新一下总数估算（可选优化）
            if files.count > 0 {
                self.totalFiles += files.count
            }

            for file in files {
                // 使用 URL API 拼接路径，自动处理分隔符
                let currentFileURL = baseDestinationURL.appendingPathComponent(file.name)
                
                if file.type == "tree" {
                    // 是文件夹
                    try createDirectory(at: currentFileURL)
                    
                    let subFiles = try await fetchFileList(root: file.path, revision: revision)
                    try await downloadFiles(
                        files: subFiles,
                        revision: revision,
                        baseDestinationURL: currentFileURL,
                        progress: progress
                    )
                } else if file.type == "blob" {
                    // 是文件
                    if isFileDownloaded(file, at: currentFileURL) {
                        print("文件已存在，跳过下载: \(file.path)")
                        incrementProgress(progress: progress)
                    } else {
                        try await downloadFile(
                            file: file,
                            to: currentFileURL
                        )
                        saveFileStatus(file, relativePath: file.path)
                        incrementProgress(progress: progress)
                    }
                }
            }
        }
        
        private func incrementProgress(progress: (Float) -> Void) {
            downloadedFilesCount += 1
            // 防止除以0
            let total = max(totalFiles, 1)
            progress(Float(downloadedFilesCount) / Float(total))
        }
        
        private func downloadFile(file: ModelFile, to destinationURL: URL) async throws {
            return try await withCheckedThrowingContinuation { continuation in
                // 构造下载 URL，注意参数编码
                // Alamofire 会处理参数编码，但这里 URL 是拼接的，需确保 file.path 被正确编码
                // 更好的方式是使用 components 或让 Alamofire 处理 parameters
                
                guard let encodedFilePath = file.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                    continuation.resume(throwing: URLError(.badURL))
                    return
                }
                
                let downloadUrl = "https://modelscope.cn/api/v1/models/\(repoPath)/repo?Revision=master&FilePath=\(encodedFilePath)"
                
                let destination: DownloadRequest.Destination = { _, _ in
                    return (destinationURL, [.removePreviousFile, .createIntermediateDirectories])
                }
                
                AF.download(downloadUrl, to: destination)
                    .validate()
                    .response { response in
                        switch response.result {
                        case .success:
                            continuation.resume()
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
            }
        }
        
        // MARK: - Persistence & Status Check
        
        /// 检查文件是否已下载
        /// - Parameters:
        ///   - file: 模型文件信息
        ///   - localURL: 本地完整 URL
        private func isFileDownloaded(_ file: ModelFile, at localURL: URL) -> Bool {
            // 1. 物理检查：文件是否存在
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                return false
            }
            
            // 2. 逻辑检查：检查 UserDefaults 里的记录
            // 使用 relativePath (即 file.path) 作为 Key，避免沙盒路径变化导致失效
            guard let statusDict = getDownloadedFilesMap(),
                  let status = statusDict[file.path] else {
                return false
            }
            
            // 3. 校验大小和版本
            // 注意：ModelScope 返回的 size 有时可能与本地文件系统略有差异，严格匹配需谨慎
            // 这里为了稳健，先对比 Revision
            return status.revision == file.revision && status.size == file.size
        }
        
        private func getDownloadedFilesMap() -> [String: FileStatus]? {
            guard let data = userDefaults.data(forKey: downloadedFilesKey),
                  let dict = try? JSONDecoder().decode([String: FileStatus].self, from: data) else {
                return nil
            }
            return dict
        }
        
        private func saveFileStatus(_ file: ModelFile, relativePath: String) {
            let status = FileStatus(
                relativePath: relativePath,
                size: file.size,
                revision: file.revision,
                lastModified: Date()
            )
            
            var dict = getDownloadedFilesMap() ?? [:]
            // Key 使用 modelscope 的相对路径，例如 "weights/pytorch_model.bin"
            // 这样即使 App 更新导致 Documents 路径改变，这个 Key 依然有效
            dict[relativePath] = status
            
            if let encoded = try? JSONEncoder().encode(dict) {
                userDefaults.set(encoded, forKey: downloadedFilesKey)
            }
        }
    }
}
