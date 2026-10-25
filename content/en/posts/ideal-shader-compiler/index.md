---
title: Shader compiler survey
date: 2026-10-24
toc: true
---

## Introduction

Over the years of maintaining [shaderc](/posts/shaderc-overview/) I formed an opinion of how a shader compiler should look. Not the language, I don't care much about the language (as long as it is C‑like 😉), but the thing itself: what goes in, what comes out, and how much of it I am allowed to touch. I made a list of what I think an ideal shader compiler looks like, shaped by offline and embedded use: platforms that do not allow compiling shaders at runtime, shipping optimized IR, keeping the executable small when a shader compiler is used at runtime, and being able to inject or skip stages. Then I went through what exists today, checked each one against the list, and benchmarked them all.

## The ideal shader compiler

<a id="ideal-1"></a>**1. Text in, text out.** The compiler must take text, lex and parse it, run some optimizations (or not), and be able to print text again. This is the [glsl‑optimizer](https://aras-p.info/blog/2010/09/29/glsl-optimizer/) case: the driver is bad at optimizing, the API accepts only source, and I want at least basic passes done before the shader ships.

<a id="ideal-2"></a>**2. Any proprietary compiler can be attached at the end.** On NDA (a.k.a. video game console) platforms compiling or generating code at runtime is not an option, and the platform compiler might sign the binary with an algorithm nobody outside knows. The last stage has to be replaceable with a black box.

<a id="ideal-3"></a>**3. Any part of it can be skipped.** Including all of it. When I need a feature the compiler doesn't support, and there is no time to add it properly, I want to go straight through to the back‑end compiler instead of bolting something on the side.

<a id="ideal-4"></a>**4. Things can be injected at any stage.** I must be able to get at the IR between stages and transform it into what I need.

<a id="ideal-5"></a>**5. It is configurable.** Everything I don't need for the target I'm building for should be strippable, and the binary should get smaller when I strip it.

<a id="ideal-6"></a>**6. It is a library.** Embeddable, and not structured as a command line tool that happens to have a `main()` you can call. Can go from text to shader binary. Or could be limited, where we skip lexing, parsing and optimization and just convert IR to target shader binary. "Embeddable" in this context also means that shader compiler should not dominate binary size of executable if it's embedded. If we have 100MiB library that gets linked with 1MiB executable, that is not really "embeddable".

<a id="ideal-7"></a>**7. The IR is serializable.** So that optimized shader IR can be shipped, and translated/emitted for the specific backend at runtime. This doesn't work everywhere, but where it does it's a nice feature.

<a id="ideal-8"></a>**8. The IR can be assembled at runtime, without the compiler.** If generating a shader is simple, and there is nothing to gain from optimization passes, I should be able to emit IR directly and link only the back‑end. This is a binary size optimization.

<a id="ideal-9"></a>**9. It runs where I build.** It must produce shaders the API can ingest from any major desktop OS: Windows, Linux, and macOS.

<a id="ideal-10"></a>**10. It should be fast.** Even if fast means reentrant and have to use multiple threads to achieve high speed when compiling multiple shaders. Compiling multiple shaders is not dependent on each other, so a shader compiler should not force sequential compiling.

Nothing on this list is exotic. None of it is impossible or unheard of; it is how LLVM [describes](https://llvm.org/#:~:text=The%20LLVM%20Project%20is%20a%20collection%20of%20modular%20and%20reusable%20compiler%20and%20toolchain%20technologies%2E) itself:

> The LLVM Project is a collection of modular and reusable compiler and toolchain technologies.

## The contenders

 - **[FXC](https://learn.microsoft.com/en-us/windows/win32/direct3dtools/fxc)**, `d3dcompiler_47.dll`. HLSL to DXBC, for Direct3D 11.
 - **[DXC](https://github.com/microsoft/DirectXShaderCompiler)**, `dxcompiler.dll`. HLSL to DXIL for Direct3D 12, or to SPIR‑V.
 - **[Metal compiler](https://developer.apple.com/metal/)**, `metal`. Metal Shading Language to AIR, for Metal.
 - **[Glslang](https://github.com/KhronosGroup/glslang)+[SPIRV‑Tools](https://github.com/KhronosGroup/SPIRV-Tools)+[SPIRV‑Cross](https://github.com/KhronosGroup/SPIRV-Cross)**. The Khronos stack: GLSL or HLSL to SPIR‑V, an optimizer, and SPIR‑V back to GLSL, ESSL, HLSL or MSL. Counted as one compiler because nobody uses just one of them.
 - **[Tint](https://dawn.googlesource.com/dawn/+/refs/heads/main/src/tint/)**, from Dawn. WGSL or SPIR‑V in; WGSL, SPIR‑V, HLSL, MSL or GLSL out.
 - **[Naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga)**, from wgpu. WGSL, SPIR‑V or GLSL in; WGSL, SPIR‑V, HLSL, MSL or GLSL out.
 - **[NIR](https://docs.mesa3d.org/nir/index.html)**, from Mesa. The IR every Mesa driver compiles through: SPIR‑V or GLSL in, an optimizer, and next to the hardware back‑ends, writers for SPIR‑V, DXIL and MSL.
 - **[Slang](https://shader-slang.org/)**. Slang or HLSL in; SPIR‑V, HLSL, MSL, WGSL or GLSL out, and DXIL through DXC.

How they stack up against the list. The last row counts a plain yes as a point and anything qualified as partly:

| | **FXC** | **DXC** | **Metal** | **Khronos stack** | **Tint** | **Naga** | **NIR** | **Slang** |
|---|---|---|---|---|---|---|---|---|
| 1. Text in, text out | no | no | no | yes | yes, no optimizer | yes, no optimizer | GLSL in, MSL out, inside a driver | yes |
| 2. Proprietary back‑end | *is one* | *is one* | *is one* | yes | yes | yes | yes | yes |
| 3. Parts can be skipped | no | no | partly | yes | partly | yes | yes | partly |
| 4. Inject at any stage | no | partly | no | partly | partly | yes | yes | no |
| 5. Configurable | no | no | no | partly | yes | yes | partly | no |
| 6. Library | yes | yes | no | yes | yes | Rust only | in‑tree only | yes |
| 7. Serializable IR | no | yes | yes | yes | partly | yes | yes, per build | yes |
| 8. IR assembled at runtime | no | no | no | partly | partly | yes | yes | no |
| 9. Windows, Linux, macOS | Windows | yes | no Linux | yes | yes | yes | yes | yes |
| 10. Fast, reentrant | yes | yes, per compiler instance | *is a process* | yes | yes | yes | yes | yes, one global session per thread |
| **Yes / partly** | **2** / 1 | **3** / 2 | **1** / 2 | **7** / 3 | **5** / 5 | **8** / 2 | **6** / 4 | **5** / 2 |

A few notes on each.

**FXC** is one function, [`D3DCompile`](https://learn.microsoft.com/en-us/windows/win32/api/d3dcompiler/nf-d3dcompiler-d3dcompile): HLSL in, DXBC out, nothing in between for you. Closed, Windows only, frozen at Shader Model 5.1. Close to zero on the list, and exactly what ideal [2](#ideal-2) is for.

**DXC** is LLVM 3.7 with an HLSL front‑end, so everything on my list exists inside it and almost none of it is reachable: [`IDxcOptimizer`](https://github.com/microsoft/DirectXShaderCompiler/blob/main/include/dxc/dxcapi.h) runs passes by name, and that is it. One 18MB DLL, whether you want the SPIR‑V back‑end or not. That back‑end matters, though. With Glslang's HLSL front‑end [on its way out](https://github.com/KhronosGroup/glslang/issues/4210), DXC is where HLSL for Vulkan is headed.

**Metal compiler** is Clang. `metal` compiles MSL to AIR, which is LLVM bitcode, as a command line tool and nothing else; the only in‑process Metal compiler is the one inside the OS. Apple ships it for macOS and Windows, not Linux.

**Glslang+SPIRV‑Tools+SPIRV‑Cross** does ideal [1](#ideal-1) in full, and is the best at [3](#ideal-3) by accident: three libraries by three sets of authors with a binary format between them, so every seam is a place to stop or to insert your own. The price is the same fact from the other side: nobody owns the whole, and a front‑end can be deprecated without the back‑end noticing. For HLSL the optimizer is not optional; what Glslang emits is not legal SPIR‑V until SPIRV‑Tools has legalized it. More on that in the benchmark.

**Tint** has a proper IR, a builder, transforms, and compile‑time switches for every reader and writer, which on paper covers ideals [4](#ideal-4), [5](#ideal-5) and [8](#ideal-8). In practice it is internal C++ with no stability promise, built by Dawn, and the public header [`tint.h`](https://github.com/google/dawn/blob/main/src/tint/api/tint.h) offers `Initialize`, `Shutdown` and `SpirvToWgsl`. No optimizer, by design. Its SPIR‑V reader does not feed the writers directly but round‑trips through a WGSL AST; remember this for the benchmark.

**Naga** is the closest to the list. [`naga::Module`](https://docs.rs/naga/latest/naga/ir/struct.Module.html) is plain public data: build it by hand, walk it, rewrite it, hand it to any back‑end. Every front‑end and back‑end can be compiled out, the module serializes, and front‑end, validator and back‑ends are separate calls. What it lacks is an optimizer and a C API. What comes out is legal and unoptimized; if you want it optimized, something else has to do it. It is written in Rust, and from C++ that means writing a C wrapper around its types yourself, and fixing it every time Naga changes them, which is often. For a Rust project it is the answer. For me it is ideal [6](#ideal-6) with a giant asterisk: for a C++ project it is close to non‑viable.

**NIR** is the IR inside every Mesa driver and Microsoft's OpenCL and OpenGL layers on Direct3D 12, which makes it the most used shader compiler there is, and it has most of what my list asks for, built for a driver's needs rather than mine. Passes are C functions called in any order, [`nir_builder`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/compiler/nir/nir_builder.h) builds IR by hand, [`nir_serialize`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/compiler/nir/nir_serialize.h) writes it out, and there is a real optimizer. Faith Ekstrand's [In defense of NIR](https://www.gfxstrand.net/faith/blog/2022/01/in-defense-of-nir/) explains why it is built this way. SPIR‑V and GLSL come in; SPIR‑V, DXIL and MSL come out, next to the hardware back‑ends. None of it is a library: no public header, no stable API, no release, and the serialized form is for the build that wrote it. Each writer was written for one driver; the MSL one would not run without the driver's descriptor lowering, so it is missing from the benchmark.

**Slang** is the only one designed as a whole compiler for more than one target: its own front‑end, IR, passes and writers, a proper API, every platform, and modules stored as serialized IR. It takes ideal [2](#ideal-2) most seriously: FXC, DXC and the rest are "downstream compilers" it knows how to call, with a pass‑through mode that hands them the source untouched. What it lacks is the middle of my list: the IR is internal, with no API to read, transform or build it. And it comes as one piece: `slang-compiler.dll` is 26MB, plus a 6MB Glslang and SPIRV‑Tools for SPIR‑V.

## Benchmark

There is a [shader translation benchmark](https://kvark.github.io/naga/shader/2022/02/17/shader-translation-benchmark.html) from 2022, by Naga's author, in‑process and with I/O excluded, in which Naga won every round by an order of magnitude. It is four years old; these are today's numbers.

**Corpus.** Every vertex, fragment and compute shader from the bgfx examples: 368 shaders, 120 vertex, 203 fragment and 45 compute, from a four‑line vertex shader to FSR and ASSAO. The same shaders exist in every language the compilers take:

 - HLSL, 316K lines. Every shader starts with the same thousand lines of helper functions, most of which it never calls, and every compiler parses them again for every shader.
 - SPIR‑V, optimized, 1.9MB.
 - WGSL, 41K lines, and MSL, 37K lines.

**Method.** One C++ executable links Glslang, SPIRV‑Tools, SPIRV‑Cross and Tint statically, and loads `d3dcompiler_47.dll` and `dxcompiler.dll`. Naga gets its own Rust executable, and Slang is used through the DLLs from its release package. Shaders are loaded into memory first, every compile runs 10 times (5 for Slang), the fastest run counts, and the result is the sum over the corpus. Single thread. Metal has no library, so it is one process per shader, best of 3, with process startup measured separately.

**Versions.** Glslang 16.1.0, SPIRV‑Tools v2025.5 and Tint as pinned by Dawn `4b91cc492`; SPIRV‑Cross from August 2026; Naga 30.0.1; Slang v2026.19; DXC 1.10.2605; FXC 10.0.26100; Metal 32023.850; Mesa `e2ab668`. FXC and DXC at `-O3`, SPIRV‑Tools with its legalization and performance passes, Slang at its defaults, Tint driven the way its command line tool does it, Mesa through [`spirv_to_nir`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/compiler/spirv/nir_spirv.h), then the passes and SPIR‑V writer of [Zink](https://docs.mesa3d.org/drivers/zink.html), its OpenGL‑on‑Vulkan driver, or [`spirv_to_dxil`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/microsoft/spirv_to_dxil/spirv_to_dxil.h). MSVC release builds, Ryzen 9 7950X, Windows 10.

### Source to something a driver accepts

Every number here is all 368 shaders of the corpus, each compiled on its own to what its API's driver loads, best of ten runs, summed.

<div align="center">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 760 286" width="100%" style="max-width:760px;height:auto" font-family="Noto, sans-serif" font-size="13" fill="currentColor">
<text x="170" y="29" text-anchor="end">Naga, from WGSL</text>
<rect x="180" y="14" width="5" height="22" rx="2" fill="currentColor" fill-opacity="0.35" stroke="currentColor" stroke-width="1"/>
<text x="193" y="29">0.2s</text>
<text x="170" y="67" text-anchor="end">Tint, from WGSL</text>
<rect x="180" y="52" width="15" height="22" rx="2" fill="currentColor" fill-opacity="0.35" stroke="currentColor" stroke-width="1"/>
<text x="203" y="67">0.6s</text>
<text x="170" y="105" text-anchor="end">Glslang+SPIRV‑Tools</text>
<rect x="180" y="90" width="118" height="22" rx="2" fill="currentColor" fill-opacity="0.35" stroke="currentColor" stroke-width="1"/>
<text x="306" y="105">5.0s</text>
<text x="170" y="143" text-anchor="end">DXC</text>
<rect x="180" y="128" width="142" height="22" rx="2" fill="currentColor" fill-opacity="0.35" stroke="currentColor" stroke-width="1"/>
<text x="330" y="143">6.0s</text>
<text x="170" y="181" text-anchor="end">Slang</text>
<rect x="180" y="166" width="348" height="22" rx="2" fill="currentColor" fill-opacity="0.35" stroke="currentColor" stroke-width="1"/>
<text x="536" y="181">14.7s</text>
<text x="170" y="219" text-anchor="end">FXC</text>
<rect x="180" y="204" width="366" height="22" rx="2" fill="currentColor" fill-opacity="0.35" stroke="currentColor" stroke-width="1"/>
<text x="554" y="219">15.4s</text>
<text x="170" y="257" text-anchor="end">Metal</text>
<rect x="180" y="242" width="530" height="22" rx="2" fill="currentColor" fill-opacity="0.35" stroke="currentColor" stroke-width="1"/>
<text x="718" y="257">22.4s</text>
</svg>
</div>

| | **Path** | **Compiled** | **Total** | **Median per shader** | **Slowest shader** |
|---|---|---:|---:|---:|---:|
| Naga | WGSL → SPIR‑V | 368 | 0.22s | 85µs | 39ms |
| Tint | WGSL → SPIR‑V | 368 | 0.64s | 408µs | 94ms |
| Glslang+SPIRV‑Tools | HLSL → SPIR‑V | 368 | 4.96s | 3.4ms | 915ms |
| DXC | HLSL → DXIL | 368 | 5.99s | 11.3ms | 269ms |
| DXC | HLSL → SPIR‑V | 366 | 8.56s | 10.6ms | 1053ms |
| Slang | HLSL → WGSL | 360 | 13.53s | 32.7ms | 102ms |
| Slang | HLSL → HLSL | 368 | 13.53s | 32.5ms | 100ms |
| Slang | HLSL → MSL | 366 | 13.68s | 32.9ms | 100ms |
| Slang | HLSL → GLSL | 368 | 13.71s | 32.4ms | 104ms |
| Slang | HLSL → SPIR‑V | 368 | 14.70s | 33.4ms | 183ms |
| FXC | HLSL → DXBC | 368 | 15.43s | 4.8ms | 4088ms |
| Metal | MSL → AIR | 368 | 22.37s | 56.5ms | 325ms |


**Naga and Tint are in a different race.** Neither reads HLSL, so they start from WGSL, and neither optimizes; they translate. What comes out needs no SPIRV‑Tools either: all 368 of Tint's modules pass the validator as emitted, 366 of Naga's do, the other two failing on a layout decoration on a workgroup array. Driver‑ready SPIR‑V comes out of Naga in 0.22s for the whole corpus and out of Tint in 0.64s. The rest of the table starts at 5s.

**Glslang is fast, SPIRV‑Tools is not, and Glslang on its own is not enough.** Parsing 316K lines of HLSL and emitting SPIR‑V takes Glslang 0.93s, 2.1ms per shader. But Glslang's own help warns that `-Od disables optimization; may cause illegal SPIR-V for HLSL`, and it does: 173 of the 368 modules fail the validator until SPIRV‑Tools has legalized them, and none after. So the two are a pair, and the pair takes 4.96s. Legalizing and optimizing is 81% of that. HLSL to MSL through the whole stack, Glslang, SPIRV‑Tools, SPIRV‑Cross, takes 5.1s, and the optimizer is 79% of it.

**FXC is two compilers.** Its median is 4.8ms, less than half of DXC's. Its total is 2.5 times DXC's. Three shaders from one example take 4.1s, 2.9s and 1.6s, more than the other 365 put together. The same example has the slowest shaders for DXC, SPIRV‑Tools, SPIRV‑Cross and Tint too, but there the worst case stays around a second. This is the FXC everybody who shipped a D3D11 game remembers.

**DXC is LLVM, and it shows.** Its floor is 11ms, for a shader Glslang and SPIRV‑Tools together finish in 3ms. And DXC to SPIR‑V is the same job as Glslang+SPIRV‑Tools, HLSL in, optimized SPIR‑V out: DXC takes 8.6s, Glslang and the optimizer 5.0s. DXC also failed two compute shaders that it compiles to DXIL without complaint, and that Glslang compiles to SPIR‑V.

**Slang is the slowest way from HLSL to SPIR‑V.** Three times the Khronos stack, 1.7 times DXC. Almost none of it depends on the target: printing HLSL back out costs the same 33ms per shader as emitting SPIR‑V. The time is in the front‑end. A one‑line vertex shader goes through in 0.5ms, so the 30ms is the thousand lines of helper functions in front of every shader, which Slang checks whether the shader calls them or not. On the other hand it has no bad day: its slowest shader is 183ms, where FXC, DXC and SPIRV‑Tools each have one around a second or more.

**Slang is also stricter than the HLSL compilers.** None of the 368 shaders compiled as they were, so the HLSL was edited until they did. FXC, DXC and Glslang accept all of this, Slang does not:

 - A `static` global struct holding a sampler and a texture is "global variable cannot have opaque type". 166 shaders; a macro that builds the struct where it is used gets around it.
 - A texel offset passed through a helper into `SampleLevel` or `Load` has to be `constexpr`, even in a function nobody calls, which rejects every shader that includes the helper.
 - `min16float` and friends don't exist.
 - Two `for (int k ...)` loops in one function are an ambiguous `k`.
 - When the output is WGSL, fragment outputs have to be returned in a struct; an `out float4 color : SV_TARGET0` parameter on the entry point is "system value semantic not supported".

With those five edits to the shaders, Slang compiles all 368 to SPIR‑V, GLSL and HLSL, 366 to MSL, and 360 to WGSL. What is left are things the target doesn't have, like `InterlockedAdd` in WGSL.

**Metal is a process.** Starting `metal` and doing nothing costs 10ms. Take that out and it is still 47ms per shader, 18.7s for the corpus, on the easiest input of the lot: 37K lines of machine‑written MSL against the 316K lines of HLSL the others chew through.

### SPIR‑V in, SPIR‑V out, optimizer in between

NIR and SPIRV‑Tools do the same job here: take the SPIR‑V Glslang emits with optimization off, optimize it, write SPIR‑V. Naga and Tint are in the table for scale; they translate the optimized corpus and optimize nothing.

| | **Input** | **Compiled** | **Total** | **Median per shader** | **Slowest shader** |
|---|---|---:|---:|---:|---:|
| Naga | SPIR‑V, optimized | 358 | 0.03s | 36µs | 2ms |
| Tint | SPIR‑V, optimized | 359 | 0.97s | 720µs | 128ms |
| Mesa, NIR | SPIR‑V, unoptimized | 368 | 3.80s | 169µs | 1111ms |
| SPIRV‑Tools | SPIR‑V, unoptimized | 368 | 4.03s | 1.23ms | 909ms |
| Mesa, NIR → DXIL | SPIR‑V, unoptimized | 366 | 7.12s | 472µs | 2160ms |


**NIR's optimizer is seven times cheaper per shader and costs the same in total.** The median shader spends 169µs in NIR and 1.23ms in SPIRV‑Tools. Reading SPIR‑V is 41ms of Mesa's 3.80s and writing it is 40ms; everything else is lowering and the optimizer loop. But 3.55s of it goes to the 20 shaders of one example, `54-s2h`, where SPIRV‑Tools spends 2.79s. On the other 348 shaders NIR is done in 0.17s and SPIRV‑Tools needs 1.24s.

**From HLSL, Glslang+NIR is the Khronos pipeline with Mesa's optimizer in the middle.** Same HLSL, same front‑end, NIR where SPIRV‑Tools was: 4.74s to SPIR‑V against 4.96s, and 8.04s to DXIL against DXC's 5.99s from HLSL directly.

**What comes out is written for a driver.** Zink has NIR scalarize everything and leaves the vectors to the driver underneath, so the output is 8.1MB for the corpus against SPIRV‑Tools' 1.9MB, and the `s2h` gather shader goes in at 72KB and comes out at 1.3MB. It is also not legal: the validator rejects 300 of the 368 modules, each on a uniform block with a matrix and no `MatrixStride`. The writer's native Vulkan mode is new this year, and nothing ships against it yet.

**DXIL is the long way round.** `spirv_to_dxil` is the compiler of [Dozen](https://gitlab.freedesktop.org/mesa/mesa/-/tree/main/src/microsoft/vulkan), Mesa's Vulkan driver on top of Direct3D 12, as a library that WebGPU on Direct3D 12 uses too: SPIR‑V to NIR, then NIR to LLVM bitcode written by hand, without LLVM. Two shaders failed, one on `SPV_EXT_shader_viewport_index_layer`, which Dozen does not advertise, and one that crashed the writer.

### SPIR‑V to source

Totals are over the 358 shaders that Naga, SPIRV‑Cross and Tint could all translate to all targets. Mesa appears for the one thing it writes:

| **SPIR‑V to** | **Naga** | **SPIRV‑Cross** | **Tint** | **Mesa (with optimizer)** |
|---|---:|---:|---:|---:|
| MSL | 38ms | 152ms | 1005ms | - |
| HLSL | 33ms | 152ms | 1095ms | - |
| GLSL | 31ms | 148ms | 1133ms | - |
| WGSL | 30ms | - | 787ms | - |
| SPIR‑V | 30ms | - | 970ms | 2426ms |
| Median per shader, MSL | 45µs | 87µs | 730µs | - |


Naga is 4x faster than SPIRV‑Cross and 26x faster than Tint. In 2022 it was 10x and 80x. The order has not changed and the gaps are smaller, but with a different corpus on a different machine that is all it says: the others may have got faster, or Naga slower.

**Tint's number is the round trip.** SPIR‑V to IR, IR to WGSL AST, AST back to IR, IR to target. Printing WGSL, where it stops halfway, is its fastest path, and still 5x slower than SPIRV‑Cross at anything.

**Not all SPIR‑V is welcome.** SPIRV‑Cross took all 368 shaders for GLSL, HLSL and MSL. Tint rejected 9: eight use `ImageGatherExtended` and one `SPV_EXT_shader_viewport_index_layer`. Naga rejected the same 9, and panicked in its SPIR‑V front‑end on a tenth. By design: both read the subset of SPIR‑V that maps onto WGSL, not Vulkan's SPIR‑V.

### WGSL to everything

The comparison Tint and Naga were built for. Totals over the 365 shaders that both could translate to all targets:

| **WGSL to** | **Naga** | **Tint** |
|---|---:|---:|
| IR, parsed and validated | 201ms | 431ms |
| SPIR‑V | 221ms | 629ms |
| MSL | 224ms | 663ms |
| HLSL | 221ms | 741ms |
| GLSL | 218ms | 779ms |
| Median per shader, SPIR‑V | 84µs | 407µs |


From WGSL, Naga is about 3x faster than Tint, against 13x in 2022. Most of the difference is in the front‑ends: Naga spends 201ms parsing and validating WGSL it reads from SPIR‑V in 30ms. Once the module exists, writing it out costs Naga around 20ms for any target and Tint 200-350ms. Tint accepted all 368. Naga's GLSL writer panicked on three compute shaders.

### Binary size

The other half of ideal [6](#ideal-6): the size of an executable that does the compiles above and nothing else:

| | **What is in it** | **Size** |
|---|---|---:|
| Naga | SPIR‑V reader, WGSL writer | 1.3MB |
| Glslang | GLSL and HLSL front‑ends, SPIR‑V writer | 2.1MB |
| SPIRV‑Cross | GLSL, HLSL and MSL back‑ends | 2.1MB |
| Naga | WGSL reader, SPIR‑V writer | 2.2MB |
| SPIRV‑Tools | optimizer | 2.8MB |
| Naga | everything | 3.7MB |
| FXC | `d3dcompiler_47.dll` | 4.7MB |
| Tint | SPIR‑V reader, WGSL writer | 5.3MB |
| Khronos stack | Glslang+SPIRV‑Tools+SPIRV‑Cross | 7.0MB |
| Tint | everything | 8.0MB |
| Mesa | SPIR‑V reader, NIR with optimizer, SPIR‑V writer | 8.6MB |
| Mesa | SPIR‑V reader, NIR with optimizer, DXIL writer | 9.0MB |
| DXC | `dxcompiler.dll` + `dxil.dll` | 19.7MB |
| Slang | `slang-compiler.dll`+`slang.dll`+`slang-glslang.dll` | 32.3MB |
| Metal | `metal.exe` alone | 119MB |


**Configurable means different things.** Naga with one reader and one writer is a third of Naga with everything. Tint with one reader and one writer is still two thirds of Tint with everything, and four times Naga doing the same job. The Khronos stack is configurable by leaving a whole library out, which is coarse but works: SPIR‑V to MSL is SPIRV‑Cross alone, about 2MB; HLSL to SPIR‑V is Glslang plus the optimizer it cannot do without, about 5MB.

**All of Naga is smaller than FXC.** Five back‑ends, three front‑ends and a validator, in less space than one closed‑source HLSL compiler from 2012.

**NIR's size is its optimizer.** Of the 8.6MB, 7MB is read‑only data, almost all of it the match tables [`nir_opt_algebraic`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/compiler/nir/nir_opt_algebraic.py) generates from its Python rule files. The reader and the writer are a few hundred kilobytes each. An optimizer is the one thing Naga lacks, and in Mesa it is 7MB of the binary.

## Conclusion

None of them is the ideal shader compiler. The API compilers, FXC, DXC and Metal, are ideal [2](#ideal-2) and nothing else: black boxes, one to three orders of magnitude slower than the translators. The Khronos stack is modular because it is three projects, which also means three sets of bugs and a deprecated HLSL front‑end, and it is still the fastest way from HLSL to SPIR‑V. Slang has the API and the targets, and an IR with no API to it. Naga is the fastest, the smallest, the most configurable, and the only one with a public IR, it has no optimizer, and it is written in Rust. NIR has the optimizer and a public IR, but it is not a library anyone can grab and add to a project.

In Khronos' [2026 shader ecosystem survey](https://members.khronos.org/document/dl/36688#page=26) (Q11, "Would a Higher‑Level Shader IR Benefit Your Project?", pages 26 and 27), nearly half of the respondents said their project would benefit from a standardized IR above SPIR‑V. An IR on its own is not much use; it needs a compiler around it, and that compiler is what the list above describes. None of it would have to be invented: every item on the list is implemented by somebody, and eight of ten by Naga alone. Nobody has put all ten in one library... Yet! 😉

## References

 - Shader translation benchmark  
   https://kvark.github.io/naga/shader/2022/02/17/shader-translation-benchmark.html

 - 2026 Real‑Time Shading Ecosystem Survey Report  
   https://members.khronos.org/document/dl/36688

 - In defense of NIR  
   https://www.gfxstrand.net/faith/blog/2022/01/in-defense-of-nir/
