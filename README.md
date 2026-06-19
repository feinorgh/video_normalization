# Video Encoding Optimizer with Preserved Perceptual Quality

Re-encodes your videos with preserved perceptual quality, to the [SVT-AV1](https://gitlab.com/AOMediaCodec/SVT-AV1)
codec.

The script takes a source directory as its first parameter, then goes through all the
files in that directory and tries to determine whether it's a video file or not.

If it's a video file, it will try to re-encode a portion (30 s) of the video, attempting
to find the optimal parameters while still preserving the perceptual quality by
using an [SSIM](https://en.wikipedia.org/wiki/Structural_similarity_index_measure) score,
and a [VMAF](https://en.wikipedia.org/wiki/Video_Multimethod_Assessment_Fusion) score, making
sure it clears the requirements for preserved perceptual quality (i.e. you should not be able
to noticy any quality loss).

Depending on the original codec, the size of the re-encoded file will in many cases be around
50% of the original, sometimes less, and occasionally larger than the original.

In order not to waste time re-encoding files that do not gain significant size reductions,
a threshold of 80% of the original file is measured against the sample clip.

The script encodes all files in to the Matroska ([MKV](https://en.wikipedia.org/wiki/Matroska))
container format, which is an open standard, flexible, and widely supported container format
for most platforms.

It leaves the original file in-place, with the `.mkv` version in the same place, so you can
compare both files.

It avoids re-encoding files already encoded with an efficient format (H.265/HEVC, for instance).

This software is provided without any warranty. Always make backups of your important files, and
don't blindly run this on every single video file you have, and then removing the old files
without verifying the results first.
