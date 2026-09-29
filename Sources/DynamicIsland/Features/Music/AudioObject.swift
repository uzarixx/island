import CoreAudio

/// Reading and writing Core Audio object properties: devices, processes, taps.
enum AudioObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// A plain value: an object ID, a flag, a stream format.
    static func property<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        property(object, address(selector))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var string: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &string) == noErr else { return nil }
        // Core Audio hands the string over retained.
        return string?.takeRetainedValue() as String?
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        array(object, address(selector))
    }

    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        return Array(unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { buffer, count in
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
            count = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr
        else { return false }
        return settable.boolValue
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, to value: T) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}
