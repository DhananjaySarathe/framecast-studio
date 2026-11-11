// Throwaway: list cameras and their Center Stage / effects support. Does not open any camera or start a session.
import AVFoundation
setvbuf(stdout, nil, _IONBF, 0)
print("camera authorization status (not requested): \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)  (0 notDetermined, 1 restricted, 2 denied, 3 authorized)")
var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
let ds = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
print("centerStageControlMode=\(AVCaptureDevice.centerStageControlMode.rawValue) centerStageEnabled=\(AVCaptureDevice.isCenterStageEnabled) portraitEffectEnabled=\(AVCaptureDevice.isPortraitEffectEnabled) studioLightEnabled=\(AVCaptureDevice.isStudioLightEnabled) reactionEffectsEnabled=\(AVCaptureDevice.reactionEffectsEnabled) backgroundReplacementEnabled=\(AVCaptureDevice.isBackgroundReplacementEnabled)")
for d in ds.devices {
    print("\n== \(d.localizedName) type=\(d.deviceType.rawValue) model=\(d.modelID) continuity=\(d.isContinuityCamera)")
    print("   active: \(d.activeFormat.formatDescription.dimensions.width)x\(d.activeFormat.formatDescription.dimensions.height) centerStageActive=\(d.isCenterStageActive) deskViewCompanion=\(d.companionDeskViewCamera?.localizedName ?? "none")")
    var csFormats: [String] = []; var allFormats: [String] = []
    for f in d.formats {
        let dims = f.formatDescription.dimensions
        let fps = f.videoSupportedFrameRateRanges.map { String(format: "%.0f", $0.maxFrameRate) }.joined(separator: ",")
        let tag = "\(dims.width)x\(dims.height)@\(fps)"
        allFormats.append(tag)
        if f.isCenterStageSupported {
            let r = f.videoFrameRateRangeForCenterStage
            csFormats.append("\(tag) cs-fps \(r.map { String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate) } ?? "-") cs-zoom \(String(format: "%.2f-%.2f", f.videoMinZoomFactorForCenterStage, f.videoMaxZoomFactorForCenterStage)) portrait=\(f.isPortraitEffectSupported) studioLight=\(f.isStudioLightSupported) reactions=\(f.reactionEffectsSupported) bgReplace=\(f.isBackgroundReplacementSupported)")
        }
    }
    print("   formats: \(Array(Set(allFormats)).sorted().joined(separator: "  "))")
    print("   Center Stage formats (\(csFormats.count)):")
    for c in Set(csFormats).sorted() { print("     \(c)") }
    if #available(macOS 26.0, *) {
        let cin = d.formats.filter { $0.isCinematicVideoCaptureSupported }.count
        print("   formats supporting Cinematic Video capture (macOS 26 API): \(cin)")
    }
}
