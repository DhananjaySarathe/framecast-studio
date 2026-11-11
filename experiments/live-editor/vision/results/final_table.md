| Request | Input size | p50 ms | p95 ms | Notes |
|---|---|---:|---:|---|
| FaceRectangles | 640x360 camera (face clip, 430 s) | 3.11 | 3.35 | rev 3; runs on ANE by default (GPU util 0%); face found in 60/60 frames (18% of frame wide); first call 52 ms |
| FaceRectangles | 1280x720 camera (face clip, 430 s) | 3.42 | 3.88 | rev 3; runs on ANE by default (GPU util 0%); face found in 60/60 frames (18% of frame wide) |
| FaceRectangles | 1920x1080 camera (face clip, 430 s) | 3.85 | 4.25 | rev 3; runs on ANE by default (GPU util 0%); face found in 60/60 frames (18% of frame wide) |
| FaceLandmarks (incl. detect) | 640x360 camera (face clip, 430 s) | 3.71 | 3.89 | rev 3; includes its own face detection; first call 28 ms |
| FaceLandmarks (incl. detect) | 1280x720 camera (face clip, 430 s) | 3.86 | 4.06 | rev 3; includes its own face detection |
| FaceLandmarks (incl. detect) | 1920x1080 camera (face clip, 430 s) | 4.69 | 4.99 | rev 3; includes its own face detection |
| HumanRectangles upperBodyOnly=true | 640x360 camera (face clip, 430 s) | 2.49 | 2.57 | rev 2; ANE; person found in 98% of frames; first call 6 ms |
| HumanRectangles upperBodyOnly=true | 1280x720 camera (face clip, 430 s) | 2.65 | 2.78 | rev 2; ANE; person found in 98% of frames |
| HumanRectangles upperBodyOnly=true | 1920x1080 camera (face clip, 430 s) | 3.36 | 3.70 | rev 2; ANE; person found in 98% of frames |
| HumanRectangles upperBodyOnly=false | 640x360 camera (face clip, 430 s) | 2.46 | 2.53 | rev 2; full-body box found in only 80% of close-up frames; first call 2 ms |
| HumanRectangles upperBodyOnly=false | 1280x720 camera (face clip, 430 s) | 2.68 | 2.73 | rev 2; full-body box found in only 80% of close-up frames |
| HumanRectangles upperBodyOnly=false | 1920x1080 camera (face clip, 430 s) | 4.02 | 4.37 | rev 2; full-body box found in only 80% of close-up frames |
| TrackObject .fast (face init) | 640x360 camera (face clip, 430 s) | 0.79 | 0.90 | rev 2, VNSequenceRequestHandler; IoU vs per-frame detection 0.84-0.85, centre error about 1.1% of frame; boxes identical to .accurate; first call 11 ms |
| TrackObject .fast (face init) | 1280x720 camera (face clip, 430 s) | 1.00 | 1.11 | rev 2, VNSequenceRequestHandler; IoU vs per-frame detection 0.84-0.85, centre error about 1.1% of frame; boxes identical to .accurate |
| TrackObject .fast (face init) | 1920x1080 camera (face clip, 430 s) | 1.49 | 1.87 | rev 2, VNSequenceRequestHandler; IoU vs per-frame detection 0.84-0.85, centre error about 1.1% of frame; boxes identical to .accurate |
| TrackObject .accurate (face init) | 640x360 camera (face clip, 430 s) | 0.74 | 0.80 | rev 2; same boxes as .fast, slightly faster; confidence 0.96; first call 1 ms |
| TrackObject .accurate (face init) | 1280x720 camera (face clip, 430 s) | 0.88 | 1.00 | rev 2; same boxes as .fast, slightly faster; confidence 0.96 |
| TrackObject .accurate (face init) | 1920x1080 camera (face clip, 430 s) | 1.20 | 1.52 | rev 2; same boxes as .fast, slightly faster; confidence 0.96 |
| PersonSegmentation .fast | 640x360 camera (face clip, 430 s) | 1.83 | 2.49 | 256x192 mask; ANE; first call 32 ms |
| PersonSegmentation .fast | 1280x720 camera (face clip, 430 s) | 2.63 | 3.30 | 256x192 mask; ANE |
| PersonSegmentation .fast | 1920x1080 camera (face clip, 430 s) | 4.05 | 4.67 | 256x192 mask; ANE |
| PersonSegmentation .balanced | 640x360 camera (face clip, 430 s) | 7.37 | 7.66 | 512x384 mask; ANE; first call 29 ms |
| PersonSegmentation .balanced | 1280x720 camera (face clip, 430 s) | 7.98 | 8.46 | 512x384 mask; ANE |
| PersonSegmentation .balanced | 1920x1080 camera (face clip, 430 s) | 10.45 | 12.50 | 512x384 mask; ANE |
| PersonSegmentation .accurate | 640x360 camera (face clip, 430 s) | 27.06 | 28.00 | 2016x1512 mask; too slow to run on every frame; first call 39 ms |
| PersonSegmentation .accurate | 1280x720 camera (face clip, 430 s) | 26.88 | 28.13 | 2016x1512 mask; too slow to run on every frame |
| PersonSegmentation .accurate | 1920x1080 camera (face clip, 430 s) | 27.35 | 29.27 | 2016x1512 mask; too slow to run on every frame |
| AttentionSaliency | 640x360 camera (face clip, 430 s) | 2.90 | 3.02 | 68x68 heatmap + 1 salient box; ANE; first call 31 ms |
| AttentionSaliency | 1280x720 camera (face clip, 430 s) | 3.02 | 3.29 | 68x68 heatmap + 1 salient box; ANE |
| AttentionSaliency | 1920x1080 camera (face clip, 430 s) | 3.55 | 3.88 | 68x68 heatmap + 1 salient box; ANE |
| ObjectnessSaliency | 640x360 camera (face clip, 430 s) | 2.94 | 3.09 | about 1 salient box per frame; first call 13 ms |
| ObjectnessSaliency | 1280x720 camera (face clip, 430 s) | 3.01 | 3.16 | about 1 salient box per frame |
| ObjectnessSaliency | 1920x1080 camera (face clip, 430 s) | 3.74 | 4.03 | about 1 salient box per frame |
| HumanBodyPose | 640x360 camera (face clip, 430 s) | 3.43 | 3.50 | body found in about 50% of close-up frames (hips and legs out of shot); first call 76 ms |
| HumanBodyPose | 1280x720 camera (face clip, 430 s) | 3.63 | 3.69 | body found in about 50% of close-up frames (hips and legs out of shot) |
| HumanBodyPose | 1920x1080 camera (face clip, 430 s) | 4.51 | 4.76 | body found in about 50% of close-up frames (hips and legs out of shot) |
| HumanHandPose (max 2 hands) | 640x360 camera (face clip, 430 s) | 4.26 | 6.02 | 1.33 hands per frame on average; first call 51 ms |
| HumanHandPose (max 2 hands) | 1280x720 camera (face clip, 430 s) | 3.43 | 4.94 | 1.33 hands per frame on average |
| HumanHandPose (max 2 hands) | 1920x1080 camera (face clip, 430 s) | 4.86 | 6.83 | 1.33 hands per frame on average |
| ForegroundInstanceMask | 640x360 camera (face clip, 430 s) | 9.24 | 9.44 | subject-lift mask, 1 instance; ANE or GPU only; first call 79 ms |
| ForegroundInstanceMask | 1280x720 camera (face clip, 430 s) | 9.35 | 9.79 | subject-lift mask, 1 instance; ANE or GPU only |
| ForegroundInstanceMask | 1920x1080 camera (face clip, 430 s) | 9.56 | 9.85 | subject-lift mask, 1 instance; ANE or GPU only |
| FaceRectangles | 640x360 corner layout (100 s) | 3.11 | 3.37 | small face (9% of frame wide) in the corner layout; found in 60/60 frames |
| FaceRectangles | 1280x720 corner layout (100 s) | 3.22 | 3.41 | small face (9% of frame wide) in the corner layout; found in 60/60 frames |
| HumanRectangles upperBodyOnly=true | 640x360 corner layout (100 s) | 2.53 | 2.58 | found in 92-95% of frames |
| HumanRectangles upperBodyOnly=true | 1280x720 corner layout (100 s) | 2.66 | 2.73 | found in 92-95% of frames |
| HumanRectangles upperBodyOnly=false | 640x360 corner layout (100 s) | 2.53 | 2.60 | 0 humans found: full-body mode fails when only the upper body is visible |
| HumanRectangles upperBodyOnly=false | 1280x720 corner layout (100 s) | 2.70 | 2.85 | 0 humans found: full-body mode fails when only the upper body is visible |
| TrackObject .accurate (face init) | 640x360 corner layout (100 s) | 0.79 | 0.83 | small face: IoU 0.73-0.75, centre error 0.75% |
| TrackObject .accurate (face init) | 1280x720 corner layout (100 s) | 0.92 | 1.07 | small face: IoU 0.73-0.75, centre error 0.75% |
| ObjectnessSaliency | 640x360 corner layout (100 s) | 2.89 | 3.00 | 2.4-2.6 boxes (the graphic + the camera tile) |
| ObjectnessSaliency | 1280x720 corner layout (100 s) | 3.02 | 3.12 | 2.4-2.6 boxes (the graphic + the camera tile) |
| PersonSegmentation .fast | 640x360 corner layout (100 s) | 1.96 | 2.58 | 256x192 mask |
| PersonSegmentation .fast | 1280x720 corner layout (100 s) | 2.68 | 3.18 | 256x192 mask |
| GenerateOpticalFlow .low | 640x360 consecutive frame pairs | 13.65 | 18.58 | rev 2; GPU only (about 30% GPU util back-to-back), so it competes with the compositor; first call 196 ms |
| GenerateOpticalFlow .medium | 640x360 consecutive frame pairs | 14.43 | 18.09 | rev 2; GPU only (about 30% GPU util back-to-back), so it competes with the compositor; first call 140 ms |
| GenerateOpticalFlow .high | 640x360 consecutive frame pairs | 22.11 | 25.31 | rev 2; GPU only (about 30% GPU util back-to-back), so it competes with the compositor; first call 145 ms |
| GenerateOpticalFlow .veryHigh | 640x360 consecutive frame pairs | 34.44 | 36.51 | rev 2; GPU only (about 30% GPU util back-to-back), so it competes with the compositor; first call 176 ms |
| GenerateOpticalFlow .low | 1280x720 consecutive frame pairs | 12.31 | 13.17 | rev 2; GPU only (about 30% GPU util back-to-back), so it competes with the compositor |
| GenerateOpticalFlow .medium | 1280x720 consecutive frame pairs | 16.09 | 16.63 | rev 2; GPU only (about 30% GPU util back-to-back), so it competes with the compositor |
| RecognizeText .fast | 2880x1800 app UI walk-through (65 frames) | 65.93 | 71.46 | rev 3; 52.62 lines, 1076.6 characters per frame; CPU only, 100% of one core back-to-back |
| RecognizeText .accurate | 2880x1800 app UI walk-through (65 frames) | 84.08 | 88.17 | rev 3; 58.22 lines, 1066.8 characters per frame; 171% CPU back-to-back (ANE + CPU) |
| RecognizeText .fast | 1440x900 app UI walk-through (65 frames) | 73.00 | 76.75 | rev 3; 45.37 lines, 864.3 characters per frame; CPU only, 100% of one core back-to-back |
| RecognizeText .accurate | 1440x900 app UI walk-through (65 frames) | 82.14 | 86.95 | rev 3; 57.25 lines, 1061.7 characters per frame; 171% CPU back-to-back (ANE + CPU) |
| RecognizeText .fast | 2880x1800 UI stills (15 PNGs, cycled) | 41.15 | 123.15 | rev 3; 41.67 lines, 726.7 characters per frame; CPU only, 100% of one core back-to-back |
| RecognizeText .accurate | 2880x1800 UI stills (15 PNGs, cycled) | 74.62 | 120.74 | rev 3; 45.20 lines, 761.8 characters per frame; 171% CPU back-to-back (ANE + CPU) |
| RecognizeText .fast | 1440x900 UI stills (15 PNGs, cycled) | 42.08 | 116.01 | rev 3; 32.60 lines, 588.7 characters per frame; CPU only, 100% of one core back-to-back |
| RecognizeText .accurate | 1440x900 UI stills (15 PNGs, cycled) | 67.97 | 101.68 | rev 3; 40.40 lines, 718.4 characters per frame; 171% CPU back-to-back (ANE + CPU) |
| FaceRectangles [main=GPU] | 1280x720 camera, device forced | 6.05 | 6.44 | forced GPU; first call 674 ms |
| FaceRectangles [main=CPU] | 1280x720 camera, device forced | 17.42 | 17.79 | forced CPU; first call 26 ms |
| HumanRectangles(upper) [main=GPU] | 1280x720 camera, device forced | 4.79 | 5.01 | forced GPU; first call 14 ms |
| HumanRectangles(upper) [main=CPU] | 1280x720 camera, device forced | 16.50 | 16.78 | forced CPU; first call 17 ms |
| PersonSegmentation .fast [main=GPU] | 1280x720 camera, device forced | 5.32 | 5.67 | forced GPU; first call 501 ms |
| PersonSegmentation .fast [main=CPU] | 1280x720 camera, device forced | 18.24 | 18.64 | forced CPU; first call 33 ms |
| PersonSegmentation .balanced [main=GPU] | 1280x720 camera, device forced | 15.13 | 15.42 | forced GPU; first call 580 ms |
| PersonSegmentation .balanced [main=CPU] | 1280x720 camera, device forced | 49.92 | 50.73 | forced CPU; first call 62 ms |
| AttentionSaliency [main=GPU] | 1280x720 camera, device forced | 10.11 | 10.93 | forced GPU; first call 1122 ms |
| AttentionSaliency [main=CPU] | 1280x720 camera, device forced | 29.26 | 29.54 | forced CPU; first call 46 ms |
| HumanBodyPose [main=GPU] | 1280x720 camera, device forced | 3.57 | 3.62 | forced GPU; first call 63 ms |
| HumanBodyPose [main=CPU] | 1280x720 camera, device forced | 31.96 | 32.67 | forced CPU; first call 63 ms |
| HumanHandPose [main=GPU] | 1280x720 camera, device forced | 3.30 | 4.76 | forced GPU; first call 32 ms |
| HumanHandPose [main=CPU] | 1280x720 camera, device forced | 12.66 | 14.54 | forced CPU; first call 46 ms |
| Face detect + track loop at 15 Hz (background queue) | 1280x720, + 1 CPU thread spinning at 100% | 4.93 | 5.19 | vision CPU 9.2% of one core; face p50 3.9 ms, track p50 1.0 ms; max after warm-up 6.7 ms, warm-up max 35 ms; 0 overruns; timer p95 72.2 ms |
| Face detect + track loop at 15 Hz (background queue) | 1280x720, idle machine | 12.23 | 14.00 | vision CPU 18.3% of one core; face p50 9.9 ms, track p50 2.2 ms; max after warm-up 15.8 ms, warm-up max 18 ms; 0 overruns; timer p95 68.5 ms |
| Face detect + track loop at 15 Hz (background queue) | 1280x720, + busy CPU thread + 60 Hz CoreImage compositor (two canvases) | 5.05 | 5.44 | vision CPU 9.5% of one core; face p50 4.0 ms, track p50 1.0 ms; max after warm-up 5.6 ms, warm-up max 25 ms; 0 overruns; timer p95 73.8 ms |