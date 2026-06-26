# Video Encoding Optimizer with Preserved Perceptual Quality

Re-encodes your videos with preserved perceptual quality, to the [SVT-AV1](https://gitlab.com/AOMediaCodec/SVT-AV1)
codec for video and the [Opus](https://opus-codec.org/) audio codec.

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

## Installation & Dependencies

The script itself is standalone, and can be copied to anywhere in your `PATH`, or executed directly
from the checked out `git` directory.

This software has been developed and tested on Gentoo Linux 2.18 with Linux kernel 6.18.35-gentoo-dist,
however, it should work on any reasonably modern Linux OS, and possibly any BSD variety if it fulfills
the dependency requirements below.

The script relies on several other programs that need to be present on your system:

### ffmpeg

[ffmpeg](https://www.ffmpeg.org) and [ffprobe](https://ffmpeg.org/ffprobe.html) is usually installable
as a package on most operating systems. It records, converts, and streams audio
and video, and is what does the heavy work here.

You need a version with SVT-AV1 and Opus encoders enabled, as well as any codecs needed to decode the
source material. To check for these codecs, you can execute:

    ffmpeg -hide_banner -codecs | grep -Ei 'open media av1|opus interactive'

This should give you a list similar to this:

     DEV.LS av1                  Alliance for Open Media AV1 (decoders: libdav1d av1 av1_cuvid av1_qsv) (encoders: librav1e libsvtav1 av1_nvenc av1_qsv av1_vaapi av1_vulkan)
     DEAIL. opus                 Opus (Opus Interactive Audio Codec) (decoders: opus libopus) (encoders: opus libopus)

You also need a version of `ffmpeg` with VMAF and SSIM enabled. To check for these, execute:

    ffmpeg -hide_banner -filters | grep -E 'ssim|vmaf'

This should give you a list like this:

     .. libvmaf           VV->V      Calculate the VMAF between two video streams.
     TS ssim              VV->V      Calculate the SSIM between two video streams.
     .. ssim360           VV->V      Calculate the SSIM between two 360 video streams.
     .. vmafmotion        V->V       Calculate the VMAF Motion score.

#### libvmaf

[VMAF](https://github.com/Netflix/vmafi) is usually packaged as a C library, along with its datafiles. Normally,
the package maintainer for your OS should package these to a known location `/usr/share/vmaf/`, but if you have
problems, you might need to refer to the documentation specific for your OS.

### jq

[jq](https://jqlang.org/) is usually installable as a package on most operating systems. It is a command-line
JSON processor.

### GNU Coreutils (or equivalent)

GNU Coreutils is avaiable on most Linux distributions. Other operating systems, such as the BSD varieties,
should have these tools too, and they _should_ be roughly compatible.

* `stat`, `mktemp`, `cut`, `basename`, `dirname`, `mkdir`, `cat`, `rm`, and `tee`

### bc

[bc](https://www.gnu.org/software/bc/) is an arbitrary precision numeric processing language. A command-line calculator, if you will.

### file / libmagic

* [file](https://darwinsys.com/file/) determines what type a file is.

### find

* [find](https://www.gnu.org/software/findutils/) is a common tool on most Linux and BSD systems. The GNU `find`
command is usually the one available on Linux-based OS:es.

### grep

* [grep](https://www.gnu.org/software/grep/). The version of `grep` you use must be able to understand extended
regular expressions.

### awk
* [awk](https://www.gnu.org/software/gawk/) is a pattern scanning and processing language. It has many varieties,
but GNU awk (`gawk`) is the one this software has been tested with.

## Known Limitations

Sample encoding and evaluation takes time. Depending on the resolution and content of each media file, it can
take several minutes to evaluate just one 30 s clip from a file, and even longer to encode the whole file.

During the encoding, you're likely to need roughly 2x extra disk space compared to the file you're re-encoding,
but this may vary widely, again depending on the resolution and content.

SVT-AV1 requires a reasonably modern CPU is highly recommended, with at least AVX2 suppport. See https://github.com/AliveTeam/SVT-AV1/blob/master/Docs/System-Requirements.md

Audio is automatically reencoded to Opus, i.e. *it is not preserved as-is*.

## Exit Codes

0. Success or all files skipped
1. An error occurred (check the logs)

