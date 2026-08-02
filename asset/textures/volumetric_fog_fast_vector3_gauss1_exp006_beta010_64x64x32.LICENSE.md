# Volumetric Fog FAST Vector3 Noise

`volumetric_fog_fast_vector3_gauss1_exp006_beta010_64x64x32.rgba8` was generated
with Electronic Arts' [fastnoise](https://github.com/electronicarts/fastnoise) tool at
commit `2cf53e4bb510d07511fe63a312556d2a2e108c70`.

Generation parameters:

```text
FastNoise.exe Vector3 Uniform Gauss 1.0 Exponential 0.06 0.10 Separate 0.5 \
  64 64 32 vector3_uniform_gauss1_exp006_beta010_separate05_64x64x32 \
  -numsteps 2000 -seed 260801 -split
```

The 32 output slices are stored in ascending Z order. Each slice is a tightly packed
64x64 RGBA8 image in row-major order, so the complete raw texture occupies 524,288
bytes. RGB contains the three uniform Vector3 samples and A is 255. SHA-256:
`c6869eb1ed7fdbf63ec2c60f5f59d41ba1cff57b33b3fc391300039a2d7fe090`.

The temporal exponential filter uses alpha 0.06 to match MoerEngine's default history
weight of 0.94. The beta 0.10 and Separate 0.5 settings shape the perceptual spatial
objective without coupling the vector channels.

## License

Copyright (c) 2023 Electronic Arts Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are
permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list
   of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this
   list of conditions and the following disclaimer in the documentation and/or other
   materials provided with the distribution.
3. Neither the name of Electronic Arts, Inc. ("EA") nor the names of its contributors
   may be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.
