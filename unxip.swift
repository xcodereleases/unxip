import Foundation
import libunxip

@main
struct Main {
    static let options: [(flag: String, name: StaticString, description: StringLiteralType)] = [
        ("c", "compression-disable", "Disable APFS compression of result."),
        ("h", "help", "Print this help message."),
        ("n", "dry-run", "Dry run. (Often useful with -v.)"),
        ("v", "verbose", "Print xip file contents."),
    ]
    
    static func buildOptions() -> Options {
        var compress = true
        var dryRun = false
        var verbose = false
        
        let options =
            Self.options.map {
                option(name: $0.name, has_arg: no_argument, flag: nil, val: $0.flag)
            } + [option(name: nil, has_arg: 0, flag: nil, val: 0)]
        repeat {
            let result = getopt_long(CommandLine.argc, CommandLine.unsafeArgv, Self.options.map(\.flag).reduce("", +), options, nil)
            if result < 0 {
                break
            }
            switch UnicodeScalar(UInt32(result)) {
                case "c":
                    compress = false
                case "n":
                    dryRun = true
                case "h":
                    Self.printUsage(nominally: true)
                case "v":
                    verbose = true
                default:
                    Self.printUsage(nominally: false)
            }
        } while true

        let arguments = UnsafeBufferPointer(start: CommandLine.unsafeArgv + Int(optind), count: Int(CommandLine.argc - optind)).map {
            String(cString: $0!)
        }

        guard let input = arguments.first else {
            Self.printUsage(nominally: false)
        }

        let inputURL = URL(fileURLWithPath: input)
        let outputURL = arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        
        let delegate: UnxipDelegate
        if dryRun {
            delegate = DryRunDelegate()
        } else if compress {
            delegate = CompressedDelegate()
        } else {
            delegate = DefaultDelegate()
        }
        
        return Options(input: inputURL,
                       output: outputURL,
                       verbose: verbose,
                       delegate: delegate)
    }
    
    static func printUsage(nominally: Bool) -> Never {
        fputs(
            """
            A fast Xcode unarchiver

            USAGE: unxip [options] <input> [output]

            OPTIONS:
            
            """, nominally ? stdout : stderr)

        assert(options.map(\.flag) == options.map(\.flag).sorted())
        let maxWidth = options.map(\.name.utf8CodeUnitCount).max()!
        for option in options {
            let line = "    -\(option.flag), --\(option.name.description.padding(toLength: maxWidth, withPad: " ", startingAt: 0))  \(option.description)\n"
            assert(line.count <= 80)
            fputs(line, nominally ? stdout : stderr)
        }

        exit(nominally ? EXIT_SUCCESS : EXIT_FAILURE)
    }
    
	static func main() async throws {
        let options = buildOptions()
        try await unxip(options: options)
	}
}

extension option {
    init(name: StaticString, has_arg: CInt, flag: UnsafeMutablePointer<CInt>?, val: StringLiteralType) {
        let _option = name.withUTF8Buffer {
            $0.withMemoryRebound(to: CChar.self) {
                option(name: $0.baseAddress, has_arg: has_arg, flag: flag, val: CInt(UnicodeScalar(val)!.value))
            }
        }
        self = _option
    }
}

struct CompressedDelegate: UnxipDelegate {
    
    let inner = DefaultDelegate()
    
    func createDirectory(_ file: libunxip.File) async throws {
        try await inner.createDirectory(file)
    }
    
    func createFile(_ file: libunxip.File) async throws {
        let fd = open(file.name, O_CREAT | O_WRONLY, mode_t(file.mode & 0o777))
        guard fd > 0 else {
            throw UnxipError(statusCode: errno)
        }
        
        var writeError: Error?
        var didWrite = false
        do {
            try await writeCompressedData(from: file, to: fd)
            didWrite = true
        } catch {
            writeError = error
        }
        
        if didWrite == false {
            do {
                writeError = nil
                try await inner.writeData(from: file, to: fd)
            } catch {
                writeError = error
            }
        }
        
        close(fd)
        if file.mode & Int(C_ISVTX) != 0 {
            try await chmod(file: file, mode: mode_t(file.mode))
        }
        
        if let err = writeError {
            throw err
        }
    }
    
    func hardlink(_ original: String, to file: libunxip.File) async throws {
        try await inner.hardlink(original, to: file)
    }
    
    func symlink(_ original: String, to file: libunxip.File) async throws {
        try await inner.symlink(original, to: file)
    }
    
    func chmod(file: libunxip.File, mode: mode_t) async throws {
        try await inner.chmod(file: file, mode: mode)
    }
    
    func writeCompressedData(from file: File, to fd: Int32) async throws {
        if let data = await file.compressedData() {
            
            let attribute =
                "cmpf".utf8.reversed()  // magic
                + [0x0c, 0x00, 0x00, 0x00]  // LZFSE, 64K chunks
                + ([
                    (data.count >> 0) & 0xff,
                    (data.count >> 8) & 0xff,
                    (data.count >> 16) & 0xff,
                    (data.count >> 24) & 0xff,
                    (data.count >> 32) & 0xff,
                    (data.count >> 40) & 0xff,
                    (data.count >> 48) & 0xff,
                    (data.count >> 56) & 0xff,
                ].map(UInt8.init) as [UInt8])

            guard fsetxattr(fd, "com.apple.decmpfs", attribute, attribute.count, 0, XATTR_SHOWCOMPRESSION) == 0 else {
                throw UnxipError(statusCode: errno)
            }

            let resourceForkDescriptor = open(file.name + _PATH_RSRCFORKSPEC, O_WRONLY | O_CREAT, 0o666)
            guard resourceForkDescriptor >= 0 else {
                throw UnxipError(statusCode: errno)
            }
            defer {
                close(resourceForkDescriptor)
            }

            var written: Int
            repeat {
                // TODO: handle partial writes smarter
                written = pwrite(resourceForkDescriptor, data, data.count, 0)
                guard written >= 0 else {
                    throw UnxipError(statusCode: errno)
                }
            } while written != data.count

            guard fchflags(fd, UInt32(UF_COMPRESSED)) == 0 else {
                throw UnxipError(statusCode: errno)
            }
        } else {
            try await inner.writeData(from: file, to: fd)
        }
    }
    
    
}

struct DefaultDelegate: UnxipDelegate {
    
    func createDirectory(_ file: libunxip.File) async throws {
        let status = Darwin.mkdir(file.name, mode_t(file.mode & 0o777))
        if status != 0 {
            throw UnxipError(statusCode: status)
        }
    }
    
    func createFile(_ file: libunxip.File) async throws {
        
        let fd = open(file.name, O_CREAT | O_WRONLY, mode_t(file.mode & 0o777))
        guard fd > 0 else {
            throw UnxipError(statusCode: errno)
        }
        
        var writeError: Error?
        do {
            writeError = nil
            try await writeData(from: file, to: fd)
        } catch {
            writeError = error
        }
        
        close(fd)
        if file.mode & Int(C_ISVTX) != 0 {
            try await chmod(file: file, mode: mode_t(file.mode))
        }
        
        if let err = writeError {
            throw err
        }
    }
    
    func hardlink(_ original: String, to file: libunxip.File) async throws {
        let status = Darwin.link(original, file.name)
        if status != 0 {
            throw UnxipError(statusCode: status)
        }
    }
    
    func symlink(_ original: String, to file: libunxip.File) async throws {
        let status = Darwin.symlink(original, file.name)
        if status != 0 {
            throw UnxipError(statusCode: status)
        }
    }
    
    func chmod(file: File, mode: mode_t) async throws {
        let status = Darwin.chmod(file.name, mode)
        if status != 0 {
            throw UnxipError(statusCode: status)
        }
    }
    
    func writeData(from file: File, to fd: Int32) async throws {
        
        // pwritev requires the vector count to be positive
        if file.data.count == 0 {
            return
        }

        var vector = file.data.map {
            iovec(iov_base: UnsafeMutableRawPointer(mutating: $0.baseAddress), iov_len: $0.count)
        }
        let total = file.data.map(\.count).reduce(0, +)
        var written = 0

        repeat {
            // TODO: handle partial writes smarter
            written = pwritev(fd, &vector, CInt(vector.count), 0)
            if written < 0 {
                throw UnxipError(statusCode: errno)
            }
        } while written != total
    }
    
}

struct DryRunDelegate: UnxipDelegate {
    func createDirectory(_ file: libunxip.File) async throws { }
    func createFile(_ file: libunxip.File) async throws { }
    func hardlink(_ original: String, to file: libunxip.File) async throws { }
    func symlink(_ original: String, to file: libunxip.File) async throws { }
    func chmod(file: libunxip.File, mode: mode_t) async throws { }
}

struct UnxipError: Error {
    
    let statusCode: Int32
    
}
