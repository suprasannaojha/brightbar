import CoreFoundation
import Darwin
import Foundation
import IOKit

/// Opaque handle returned by `IOAVServiceCreateWithService`.
/// This is a CF object (`IOAVServiceRef`); Create-rule functions return +1.
typealias IOAVService = UnsafeMutableRawPointer

/// Owns an `IOAVService` created via the private IOKit SPI.
final class RetainedIOAVService {
    /// The Create function returns a +1 CF object; ARC holds it via `cf`.
    private let cf: AnyObject

    var raw: IOAVService {
        Unmanaged.passUnretained(cf).toOpaque()
    }

    init?(_ ioService: io_service_t) {
        guard let ptr = IOAVServiceBridge.createWithService(ioService) else { return nil }
        self.cf = Unmanaged<AnyObject>.fromOpaque(ptr).takeRetainedValue()
    }
}

/// Swift bindings for the private Apple Silicon `IOAVService` I2C SPI.
///
/// Loaded with `dlopen`/`dlsym` from IOKit so the package compiles without a
/// bridging header. Symbols are missing on Intel (and in some VMs); callers
/// must treat nil / `false` as "DDC unavailable".
enum IOAVServiceBridge {
    private static let ioKitPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
    private static let coreDisplayPath = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> IOAVService?
    private typealias ReadFn = @convention(c) (
        IOAVService?, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32
    ) -> IOReturn
    private typealias WriteFn = @convention(c) (
        IOAVService?, UInt32, UInt32, UnsafeRawPointer?, UInt32
    ) -> IOReturn

    private static let symbols: Symbols? = {
        loadSymbols()
    }()

    private struct Symbols {
        let create: CreateFn
        let read: ReadFn
        let write: WriteFn
    }

    /// True once the three IOAVService symbols resolved.
    static var isAvailable: Bool { symbols != nil }

    static func createWithService(_ service: io_service_t) -> IOAVService? {
        guard let symbols else { return nil }
        return symbols.create(kCFAllocatorDefault, service)
    }

    static func readI2C(
        _ service: IOAVService,
        chipAddress: UInt32,
        offset: UInt32,
        outputBuffer: UnsafeMutableRawPointer,
        outputBufferSize: UInt32
    ) -> IOReturn {
        guard let symbols else { return kIOReturnUnsupported }
        return symbols.read(service, chipAddress, offset, outputBuffer, outputBufferSize)
    }

    static func writeI2C(
        _ service: IOAVService,
        chipAddress: UInt32,
        dataAddress: UInt32,
        inputBuffer: UnsafeRawPointer,
        inputBufferSize: UInt32
    ) -> IOReturn {
        guard let symbols else { return kIOReturnUnsupported }
        return symbols.write(service, chipAddress, dataAddress, inputBuffer, inputBufferSize)
    }

    private static func loadSymbols() -> Symbols? {
        let paths = [ioKitPath, coreDisplayPath]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { continue }
            if let symbols = resolve(from: handle) {
                return symbols
            }
        }
        // Last resort: already-loaded image (IOKit is linked by the target).
        // RTLD_DEFAULT is a C macro ((void *)-2) that Swift does not import.
        if let symbols = resolve(from: UnsafeMutableRawPointer(bitPattern: -2)) {
            return symbols
        }
        return nil
    }

    private static func resolve(from handle: UnsafeMutableRawPointer?) -> Symbols? {
        guard
            let create = symbol(handle, "IOAVServiceCreateWithService", as: CreateFn.self),
            let read = symbol(handle, "IOAVServiceReadI2C", as: ReadFn.self),
            let write = symbol(handle, "IOAVServiceWriteI2C", as: WriteFn.self)
        else {
            return nil
        }
        return Symbols(create: create, read: read, write: write)
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as: T.Type) -> T? {
        guard let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }
}
