import AppKit
import CoreServices
import Foundation

enum AppleMusicPositionQuery {
    typealias Sender = (NSAppleEventDescriptor, TimeInterval) throws -> NSAppleEventDescriptor

    static func fetch(timeout: TimeInterval) -> Double? {
        let pid = NSRunningApplication.runningApplications(
            withBundleIdentifier: MusicPlaybackController.appleMusicBundleIdentifier
        ).first?.processIdentifier
        return autoreleasepool { fetch(processID: pid, timeout: timeout) }
    }

    static func fetch(processID: pid_t?, timeout: TimeInterval,
                      send: Sender = { event, timeout in
                          try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
                      }) -> Double? {
        guard let processID, processID > 0, timeout.isFinite, timeout > 0 else { return nil }

        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)),
                               forKeyword: AEKeyword(keyAEDesiredClass))
        property.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)),
                               forKeyword: AEKeyword(keyAEKeyForm))
        // Music's scripting dictionary defines player position as the pPos property.
        property.setDescriptor(NSAppleEventDescriptor(typeCode: 0x70506F73),
                               forKeyword: AEKeyword(keyAEKeyData))
        property.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        guard let object = property.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { return nil }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: AEKeyword(keyDirectObject))

        guard let reply = try? send(event, timeout),
              (reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0) == 0,
              let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
              let number = result.coerce(toDescriptorType: DescType(typeIEEE64BitFloatingPoint)) else { return nil }
        let position = number.doubleValue
        return position.isFinite && position >= 0 ? position : nil
    }
}
