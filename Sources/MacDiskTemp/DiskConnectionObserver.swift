import Foundation
import DiskArbitration

@MainActor final class DiskConnectionObserver {
    private let session: DASession?
    private let changed: (String) -> Void
    init(changed: @escaping (String) -> Void) {
        self.changed = changed
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskChanged, pointer)
        DARegisterDiskDisappearedCallback(session, nil, diskChanged, pointer)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }
    deinit {
        if let session {
            DAUnregisterCallback(session, unsafeBitCast(diskChanged, to: UnsafeMutableRawPointer.self), Unmanaged.passUnretained(self).toOpaque())
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }
    fileprivate func receive(_ id: String) { changed(id) }
}

private let diskChanged: DADiskAppearedCallback = { disk, pointer in
    guard let pointer, let name = DADiskGetBSDName(disk),
          let description = DADiskCopyDescription(disk) as? [String: Any],
          description[kDADiskDescriptionMediaWholeKey as String] as? Bool == true else { return }
    let owner = Unmanaged<DiskConnectionObserver>.fromOpaque(pointer).takeUnretainedValue()
    let id = String(cString: name)
    Task { @MainActor [weak owner] in owner?.receive(id) }
}
