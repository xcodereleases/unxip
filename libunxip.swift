import Compression
import Foundation

public protocol UnxipDelegate {
    func createDirectory(_ file: File) async throws
    func createFile(_ file: File) async throws
    
    func hardlink(_ original: String, to file: File) async throws
    func symlink(_ original: String, to file: File) async throws
    func chmod(file: File, mode: mode_t) async throws
}

public func unxip(options: Options) async throws {
    let handle = try FileHandle(forReadingFrom: options.input)
    try handle.seekToEnd()
    let length = Int(try handle.offset())
    let file = UnsafeBufferPointer(start: mmap(nil, length, PROT_READ, MAP_PRIVATE, handle.fileDescriptor, 0).bindMemory(to: UInt8.self, capacity: length), count: length)
    precondition(UnsafeMutableRawPointer(mutating: file.baseAddress) != MAP_FAILED)
    defer {
        munmap(UnsafeMutableRawPointer(mutating: file.baseAddress), length)
    }

    if let output = options.output {
        guard chdir(output.path) == 0 else {
            fputs("Failed to access output directory at \(output.path): \(String(cString: strerror(errno)))", stderr)
            exit(EXIT_FAILURE)
        }
    }

    let content = locateContent(in: file)
    await parseContent(content, options: options, delegate: options.delegate)
}

extension RandomAccessCollection {
    subscript(fromOffset fromOffset: Int = 0, toOffset toOffset: Int? = nil) -> SubSequence {
        let toOffset = toOffset ?? count
        return self[index(startIndex, offsetBy: fromOffset)..<index(startIndex, offsetBy: toOffset)]
    }

    subscript(fromOffset fromOffset: Int = 0, size size: Int) -> SubSequence {
        let base = index(startIndex, offsetBy: fromOffset)
        return self[base..<index(base, offsetBy: size)]
    }
}

extension AsyncStream.Continuation {
    func yieldWithBackoff(_ value: Element) async {
        let backoff: UInt64 = 1_000_000
        while case .dropped(_) = yield(value) {
            try? await Task.sleep(nanoseconds: backoff)
        }
    }
}

struct ConcurrentStream<TaskResult: Sendable> {
    let batchSize: Int
    var operations = [@Sendable () async throws -> TaskResult]()

    var results: AsyncStream<TaskResult> {
        AsyncStream(bufferingPolicy: .bufferingOldest(batchSize)) { continuation in
            Task {
                try await withThrowingTaskGroup(of: (Int, TaskResult).self) { group in
                    var queueIndex = 0
                    var dequeIndex = 0
                    var pending = [Int: TaskResult]()
                    while dequeIndex < operations.count {
                        if queueIndex - dequeIndex < batchSize,
                            queueIndex < operations.count
                        {
                            let _queueIndex = queueIndex
                            group.addTask {
                                let queueIndex = _queueIndex
                                return await (queueIndex, try operations[queueIndex]())
                            }
                            queueIndex += 1
                        } else {
                            let (index, result) = try await group.next()!
                            pending[index] = result
                            if index == dequeIndex {
                                while let result = pending[dequeIndex] {
                                    await continuation.yieldWithBackoff(result)
                                    pending.removeValue(forKey: dequeIndex)
                                    dequeIndex += 1
                                }
                            }
                        }
                    }
                    continuation.finish()
                }
            }
        }
    }

    init(batchSize: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.batchSize = batchSize
    }

    mutating func addTask(operation: @escaping @Sendable () async throws -> TaskResult) {
        operations.append(operation)
    }

    mutating func addRunningTask(operation: @escaping @Sendable () async -> TaskResult) -> Task<TaskResult, Never> {
        let task = Task {
            await operation()
        }
        operations.append({
            await task.value
        })
        return task
    }
}

final class Chunk: Sendable {
    let buffer: UnsafeBufferPointer<UInt8>
    let owned: Bool

    init(buffer: UnsafeBufferPointer<UInt8>, owned: Bool) {
        self.buffer = buffer
        self.owned = owned
    }

    deinit {
        if owned {
            buffer.deallocate()
        }
    }
}

public struct File {
    public let dev: Int
    public let ino: Int
    public let mode: Int
    public let name: String
    public var data = [UnsafeBufferPointer<UInt8>]()
    // For keeping the data alive
    var chunks = [Chunk]()

    public struct Identifier: Hashable {
        public let dev: Int
        public let ino: Int
    }

    public var identifier: Identifier {
        Identifier(dev: dev, ino: ino)
    }
    
    public func uncompressedData() async -> Data? {
        if data.isEmpty {
            return nil
        }
        
        var d = Data()
        for buffer in data {
            d.append(buffer)
        }
        return d
    }

    public func compressedData() async -> [UInt8]? {
        if data.isEmpty {
            return nil
        }
        
        let blockSize = 64 << 10  // LZFSE with 64K block size
        var _data = [UInt8]()
        _data.reserveCapacity(self.data.map(\.count).reduce(0, +))
        let data = self.data.reduce(into: _data, +=)
        var compressionStream = ConcurrentStream<[UInt8]?>()
        var position = data.startIndex

        while position < data.endIndex {
            let _position = position
            compressionStream.addTask {
                try Task.checkCancellation()
                let position = _position
                let end = min(position + blockSize, data.endIndex)
                let data = [UInt8](unsafeUninitializedCapacity: (end - position) + (end - position) / 16) { buffer, count in
                    data[position..<end].withUnsafeBufferPointer { data in
                        count = compression_encode_buffer(buffer.baseAddress!, buffer.count, data.baseAddress!, data.count, nil, COMPRESSION_LZFSE)
                        guard count < buffer.count else {
                            count = 0
                            return
                        }
                    }
                }
                return !data.isEmpty ? data : nil
            }
            position += blockSize
        }
        var chunks = [[UInt8]]()
        for await chunk in compressionStream.results {
            if let chunk = chunk {
                chunks.append(chunk)
            } else {
                return nil
            }
        }

        let tableSize = (chunks.count + 1) * MemoryLayout<UInt32>.size
        let size = tableSize + chunks.map(\.count).reduce(0, +)
        guard size < data.count else {
            return nil
        }

        return [UInt8](unsafeUninitializedCapacity: size) { buffer, count in
            var position = tableSize

            func writePosition(toTableIndex index: Int) {
                precondition(position < UInt32.max)
                for i in 0..<MemoryLayout<UInt32>.size {
                    buffer[index * MemoryLayout<UInt32>.size + i] = UInt8(position >> (i * 8) & 0xff)
                }
            }

            writePosition(toTableIndex: 0)
            for (index, chunk) in zip(1..., chunks) {
                _ = UnsafeMutableBufferPointer(rebasing: buffer.suffix(from: position)).initialize(from: chunk)
                position += chunk.count
                writePosition(toTableIndex: index)
            }
            count = size
        }
    }
}

public struct Options {

    public var input: URL
    public var output: URL?
    public var verbose: Bool
    public var delegate: UnxipDelegate
    
    public init(input: URL, output: URL?, verbose: Bool, delegate: UnxipDelegate) {
        self.input = input
        self.output = output
        self.verbose = verbose
        self.delegate = delegate
    }
}

func read<Integer: BinaryInteger, Buffer: RandomAccessCollection>(_ type: Integer.Type, from buffer: inout Buffer) -> Integer where Buffer.Element == UInt8, Buffer.SubSequence == Buffer {
    defer {
        buffer = buffer[fromOffset: MemoryLayout<Integer>.size]
    }
    var result: Integer = 0
    var iterator = buffer.makeIterator()
    for _ in 0..<MemoryLayout<Integer>.size {
        result <<= 8
        result |= Integer(iterator.next()!)
    }
    return result
}

func chunks(from content: UnsafeBufferPointer<UInt8>) -> ConcurrentStream<Chunk> {
    var remaining = content[fromOffset: 4]
    let chunkSize = read(UInt64.self, from: &remaining)
    var decompressedSize: UInt64 = 0

    var chunkStream = ConcurrentStream<Chunk>()

    repeat {
        decompressedSize = read(UInt64.self, from: &remaining)
        let compressedSize = read(UInt64.self, from: &remaining)
        let _remaining = remaining
        let _decompressedSize = decompressedSize

        chunkStream.addTask {
            let remaining = _remaining
            let decompressedSize = _decompressedSize

            if compressedSize == chunkSize {
                return Chunk(buffer: UnsafeBufferPointer(rebasing: remaining[fromOffset: 0, size: Int(compressedSize)]), owned: false)
            } else {
                let magic = [0xfd] + "7zX".utf8
                precondition(remaining.prefix(magic.count).elementsEqual(magic))
                let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(decompressedSize))
                precondition(compression_decode_buffer(buffer.baseAddress!, buffer.count, UnsafeBufferPointer(rebasing: remaining).baseAddress!, Int(compressedSize), nil, COMPRESSION_LZMA) == decompressedSize)
                return Chunk(buffer: UnsafeBufferPointer(buffer), owned: true)
            }
        }
        remaining = remaining[fromOffset: Int(compressedSize)]
    } while decompressedSize == chunkSize

    return chunkStream
}

func files<ChunkStream: AsyncSequence>(in chunkStream: ChunkStream) -> AsyncStream<File> where ChunkStream.Element == Chunk {
    AsyncStream(bufferingPolicy: .bufferingOldest(ProcessInfo.processInfo.activeProcessorCount)) { continuation in
        Task {
            var iterator = chunkStream.makeAsyncIterator()
            var chunk = try! await iterator.next()!
            var position = 0

            func read(size: Int) async -> [UInt8] {
                var result = [UInt8]()
                while result.count < size {
                    if position >= chunk.buffer.endIndex {
                        chunk = try! await iterator.next()!
                        position = 0
                    }
                    result.append(chunk.buffer[chunk.buffer.startIndex + position])
                    position += 1
                }
                return result
            }

            func readOctal(from bytes: [UInt8]) -> Int {
                Int(String(data: Data(bytes), encoding: .utf8)!, radix: 8)!
            }

            while true {
                let magic = await read(size: 6)
                // Yes, cpio.h really defines this global macro
                precondition(magic.elementsEqual(MAGIC.utf8))
                let dev = readOctal(from: await read(size: 6))
                let ino = readOctal(from: await read(size: 6))
                let mode = readOctal(from: await read(size: 6))
                let _ = await read(size: 6)  // uid
                let _ = await read(size: 6)  // gid
                let _ = await read(size: 6)  // nlink
                let _ = await read(size: 6)  // rdev
                let _ = await read(size: 11)  // mtime
                let namesize = readOctal(from: await read(size: 6))
                var filesize = readOctal(from: await read(size: 11))
                let name = String(cString: await read(size: namesize))
                var file = File(dev: dev, ino: ino, mode: mode, name: name)

                while filesize > 0 {
                    if position >= chunk.buffer.endIndex {
                        chunk = try! await iterator.next()!
                        position = 0
                    }
                    let size = min(filesize, chunk.buffer.endIndex - position)
                    file.chunks.append(chunk)
                    file.data.append(UnsafeBufferPointer(rebasing: chunk.buffer[fromOffset: position, size: size]))
                    filesize -= size
                    position += size
                }

                guard file.name != "TRAILER!!!" else {
                    continuation.finish()
                    return
                }

                await continuation.yieldWithBackoff(file)
            }
        }
    }
}

func parseContent(_ content: UnsafeBufferPointer<UInt8>, options: Options, delegate: UnxipDelegate) async {
    var taskStream = ConcurrentStream<Void>(batchSize: 64)  // Worst case, should allow for files up to 64 * 16MB = 1GB
    var hardlinks = [File.Identifier: (String, Task<Void, Never>)]()
    var directories = [Substring: Task<Void, Never>]()
    for await file in files(in: chunks(from: content).results) {

        // The assumption is that all directories are provided without trailing slashes
        func parentDirectory<S: StringProtocol>(of path: S) -> S.SubSequence {
            path[..<path.lastIndex(of: "/")!]
        }

        // https://bugs.swift.org/browse/SR-15816
        func parentDirectoryTask(for: File) -> Task<Void, Never>? {
            directories[parentDirectory(of: file.name)] ?? directories[String(parentDirectory(of: file.name))[...]]
        }

        if file.name == "." {
            continue
        }

        if options.verbose {
            print(file.name)
        }

        if let (original, originalTask) = hardlinks[file.identifier] {
            let task = parentDirectoryTask(for: file)
            assert(task != nil, file.name)
            _ = taskStream.addRunningTask {
                _ = await (originalTask.value, task?.value)

                try? await delegate.hardlink(original, to: file)
            }
            continue
        }

        // The types we care about, anyways
        let typeMask = Int(C_ISLNK | C_ISDIR | C_ISREG)
        switch CInt(file.mode & typeMask) {
            case C_ISLNK:
                let task = parentDirectoryTask(for: file)
                assert(task != nil, file.name)
                _ = taskStream.addRunningTask {
                    await task?.value
                    
                    guard let original = String(data: Data(file.data.map(Array.init).reduce([], +)), encoding: .utf8) else {
                        return
                    }
                    
                    try? await delegate.symlink(original, to: file)
                    
                    if file.mode & Int(C_ISVTX) != 0 {
                        try? await delegate.chmod(file: file, mode: mode_t(file.mode))
                    }
                }
            case C_ISDIR:
                let task = parentDirectoryTask(for: file)
                assert(task != nil || parentDirectory(of: file.name) == ".", file.name)
                directories[file.name[...]] = taskStream.addRunningTask {
                    await task?.value

                    try? await delegate.createDirectory(file)
                    if file.mode & Int(C_ISVTX) != 0 {
                        try? await delegate.chmod(file: file, mode: mode_t(file.mode))
                    }
                }
            case C_ISREG:
                let task = parentDirectoryTask(for: file)
                assert(task != nil, file.name)
                hardlinks[file.identifier] = (
                    file.name,
                    taskStream.addRunningTask {
                        await task?.value
                        try? await delegate.createFile(file)
                    }
                )
            default:
                fatalError("\(file.name) with \(file.mode) is a type that is unhandled")
        }
    }

    // Run through any stragglers
    for await _ in taskStream.results {
    }
}

func locateContent(in file: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
    precondition(file.starts(with: "xar!".utf8))  // magic
    var header = file[4...]
    let headerSize = read(UInt16.self, from: &header)
    precondition(read(UInt16.self, from: &header) == 1)  // version
    let tocCompressedSize = read(UInt64.self, from: &header)
    let tocDecompressedSize = read(UInt64.self, from: &header)
    _ = read(UInt32.self, from: &header)  // checksum

    let toc = [UInt8](unsafeUninitializedCapacity: Int(tocDecompressedSize)) { buffer, count in
        let zlibSkip = 2  // Apple's decoder doesn't want to see CMF/FLG (see RFC 1950)
        count = compression_decode_buffer(buffer.baseAddress!, Int(tocDecompressedSize), file.baseAddress! + Int(headerSize) + zlibSkip, Int(tocCompressedSize) - zlibSkip, nil, COMPRESSION_ZLIB)
        precondition(count == Int(tocDecompressedSize))
    }

    let document = try! XMLDocument(data: Data(toc))
    let content = try! document.nodes(forXPath: "xar/toc/file").first {
        try! $0.nodes(forXPath: "name").first!.stringValue! == "Content"
    }!
    let contentOffset = Int(try! content.nodes(forXPath: "data/offset").first!.stringValue!)!
    let contentSize = Int(try! content.nodes(forXPath: "data/length").first!.stringValue!)!
    let contentBase = Int(headerSize) + Int(tocCompressedSize) + contentOffset

    let slice = file[fromOffset: contentBase, size: contentSize]
    precondition(slice.starts(with: "pbzx".utf8))
    return UnsafeBufferPointer(rebasing: slice)
}
