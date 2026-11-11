// Reviewer probe: first-call vs steady cost of cursor reads, sampled at 30 Hz for 10 s (as a render tick would). Timings only.
import AppKit
import CoreGraphics
var sink = 0.0
func one(_ f: () -> Void) -> Double { let t0 = DispatchTime.now().uptimeNanoseconds; f(); return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000 }
let first = one { sink += Double(CGEvent(source: nil)?.location.x ?? 0) }
print(String(format: "CGEvent location first call: %.1f us", first))
var ts: [Double] = []
for _ in 0..<300 { ts.append(one { sink += Double(CGEvent(source: nil)?.location.x ?? 0) }); usleep(33_333) }
ts.sort()
print(String(format: "CGEvent location at 30 Hz x300: p50 %.1f us p99 %.1f us max %.1f us", ts[150], ts[297], ts[299]))
var ts2: [Double] = []
for _ in 0..<300 { ts2.append(one { sink += Double(NSEvent.mouseLocation.x) }); usleep(33_333) }
ts2.sort()
print(String(format: "NSEvent.mouseLocation at 30 Hz x300: p50 %.1f us p99 %.1f us max %.1f us", ts2[150], ts2[297], ts2[299]))
print(sink > -1 ? "ok" : "")
