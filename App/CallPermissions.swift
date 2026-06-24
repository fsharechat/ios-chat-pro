// App/CallPermissions.swift
import AVFoundation

/// Centralizes the mic/camera authorization check the design spec requires
/// before entering the dialing state (outgoing) or answering (incoming) —
/// see `docs/superpowers/specs/2026-06-23-phase3-av-call-design.md` §5's
/// edge-case table: denied mic/camera access must redirect to Settings and
/// must NOT enter the dialing state. Always calls back on the main queue —
/// `AVAudioSession.requestRecordPermission`/`AVCaptureDevice.requestAccess`
/// completion handlers are not guaranteed to fire on main.
enum CallPermissions {
    /// `completion(true)` only once both audio (always required) and, if
    /// `audioOnly` is false, video are authorized. Actively prompts via
    /// `requestRecordPermission`/`requestAccess` when a permission is
    /// `.notDetermined` (first launch); for an already-`.denied`/`.restricted`
    /// permission this does NOT re-prompt (the system never re-prompts once
    /// denied) — the caller is expected to show its own "go to Settings" UI
    /// in that case.
    static func ensureAuthorized(audioOnly: Bool, completion: @escaping (Bool) -> Void) {
        ensureMicrophoneAuthorized { micGranted in
            guard micGranted else {
                callOnMain(completion, false)
                return
            }
            guard !audioOnly else {
                callOnMain(completion, true)
                return
            }
            ensureCameraAuthorized { cameraGranted in
                callOnMain(completion, cameraGranted)
            }
        }
    }

    // MARK: - Microphone

    private static func ensureMicrophoneAuthorized(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            completion(true)
        case .denied, .undetermined:
            // `.undetermined` is the only case where re-asking is meaningful;
            // calling `requestRecordPermission` when already `.denied` is
            // harmless (the system just invokes the handler with `false`
            // immediately, no re-prompt), so routing both through the same
            // call keeps this simple without behaving incorrectly.
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted)
            }
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Camera

    private static func ensureCameraAuthorized(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                completion(granted)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Helpers

    private static func callOnMain(_ completion: @escaping (Bool) -> Void, _ result: Bool) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async { completion(result) }
        }
    }
}
