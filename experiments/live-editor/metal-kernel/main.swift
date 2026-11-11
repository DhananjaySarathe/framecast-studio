// Can Framecast use custom Metal shader transitions without the offline `metal` compiler (Command Line Tools only)?
// CIKernel.kernels(withMetalString:) compiles [[stitchable]] Metal source at run time (macOS 12+).
import Foundation
import CoreImage
import Metal

let src = """
#include <CoreImage/CoreImage.h>
using namespace metal;
// Luma-ish radial wipe between two images: a typical shader transition.
extern "C" [[stitchable]] float4 radialWipe(coreimage::sample_t a, coreimage::sample_t b, float progress, float2 center, float soft, coreimage::destination dest) {
    float d = distance(dest.coord(), center) / 2203.0;
    float m = smoothstep(progress - soft, progress + soft, d);
    return mix(b, a, m);
}
"""
let dev = MTLCreateSystemDefaultDevice()!
print("supportsDynamicLibraries:", dev.supportsDynamicLibraries)
let t0 = Date()
do {
    let ks = try CIKernel.kernels(withMetalString: src)
    print(String(format: "compiled %d kernel(s) in %.0f ms: %@", ks.count, Date().timeIntervalSince(t0) * 1000, ks.map { "\($0.name) (\(type(of: $0)))" }.joined(separator: ", ")))
    guard let k = ks.first as? CIBlendKernel ?? nil else {
        // A two-sample kernel compiles as a CIColorKernel; apply it with two images.
        guard let ck = ks.first as? CIColorKernel else { print("unexpected kernel class"); exit(1) }
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let a = CIImage(color: .red).cropped(to: rect), b = CIImage(color: .blue).cropped(to: rect)
        let ctx = CIContext(mtlDevice: dev)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        var times: [Double] = []
        for i in 0..<120 {
            let p = Float(i % 60) / 60
            let out = ck.apply(extent: rect, arguments: [a, b, p, CIVector(x: 960, y: 540), Float(0.05)])!
            let s = Date(); ctx.render(out, to: pb!); times.append(Date().timeIntervalSince(s) * 1000)
        }
        print(String(format: "rendered 1080p shader transition: mean %.2f ms per frame", times.dropFirst(10).reduce(0, +) / Double(times.count - 10)))
        exit(0)
    }
    _ = k
} catch {
    print("compile failed:", error)
}
