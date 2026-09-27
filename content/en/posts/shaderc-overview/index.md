---
title: The bgfx shader compiler, 14 years of not being a compiler
date: 2026-09-27
toc: true
---

## Introduction

bgfx renders through many backends, and each of them wants shaders in its own language: HLSL for Direct3D, Metal Shading Language on Apple platforms, GLSL for OpenGL and ESSL for OpenGL ES, SPIR-V for Vulkan, WGSL for WebGPU, etc. Nobody wants to write and maintain one shader per API. So bgfx has a shader compiler, `shaderc`, that takes a single source written in bgfx's GLSL-flavoured dialect and produces a binary blob for whichever backend you ask for.

`shaderc` is the **jankiest** part of bgfx. I'll say that upfront, because the rest of this post explains why it is janky, why it still works after fourteen years, and why I haven't replaced it. It is not a compiler in the textbook sense. There is no parser, no AST, no IR of its own. It is a C preprocessor, a pile of `#define`s, textual patching of the source, and then a hand-off to somebody else's real compiler. The price is that every target reports errors in its own way. The benefit is that adding a new target has never required touching a front-end, because there isn't one. The language you write is GLSL. For every target that is not OpenGL, the text that actually gets compiled is HLSL.

`shaderc` was in the [initial commit](https://github.com/bkaradzic/bgfx/tree/dee3fe5266e9e17a4783df797333b86677e7e2c7) of bgfx, on 3 April 2012, as a single [`tools/shaderc.cpp`](https://github.com/bkaradzic/bgfx/blob/dee3fe5266e9e17a4783df797333b86677e7e2c7/tools/shaderc.cpp) of 664 lines. It came with two third-party dependencies, both of which outlived every other decision made that day: fcpp, a C preprocessor with [roots in 1984](/posts/preprocessor/), and [glsl-optimizer](https://github.com/aras-p/glsl-optimizer), an extraction of Mesa's GLSL compiler.

Android and [Native Client](/posts/native-client/) got GLSL through glsl-optimizer. Windows and Xbox 360 got HLSL through `D3DXCompileShader` from the D3DX9 library:

<div align="center">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 760 200" width="100%" style="max-width:760px;height:auto" font-family="Noto, sans-serif" font-size="13" fill="currentColor">
<defs><marker id="ah2012" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>
<rect x="250" y="12" width="260" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="380.0" y="31.5" text-anchor="middle">.sc source</text>
<rect x="250" y="72" width="260" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="380.0" y="91.5" text-anchor="middle">fcpp (C preprocessor)</text>
<rect x="60" y="140" width="260" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="190.0" y="158" text-anchor="middle" font-weight="600">glsl-optimizer</text>
<text x="190.0" y="174" text-anchor="middle" font-size="11" fill-opacity="0.75">GLSL → Android, Native Client</text>
<rect x="440" y="140" width="260" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="570.0" y="158" text-anchor="middle" font-weight="600">D3DXCompileShader</text>
<text x="570.0" y="174" text-anchor="middle" font-size="11" fill-opacity="0.75">DXBC → Windows, Xbox 360</text>
<polyline points="380.0,42 380.0,72" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ah2012)"/>
<line x1="380.0" y1="102" x2="380.0" y2="122" stroke="currentColor" stroke-width="1.2"/>
<line x1="190.0" y1="122" x2="570.0" y2="122" stroke="currentColor" stroke-width="1.2"/>
<polyline points="190.0,122 190.0,140" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ah2012)"/>
<polyline points="570.0,122 570.0,140" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ah2012)"/>
</svg>
</div>

The output container from that first version, a uniform table (name, type, count, register) followed by the shader blob, is still the same shape today, just with more fields.

## How does it work?

Take the simplest example in the repo, `vs_cubes.sc`:

```glsl
$input a_position, a_color0
$output v_color0

#include "../common/common.sh"

void main()
{
	gl_Position = mul(u_modelViewProj, vec4(a_position, 1.0) );
	v_color0 = a_color0;
}
```

Next to it sits `varying.def.sc`, which is the only place where types and semantics of inputs and outputs are declared:

```glsl
vec4 v_color0    : COLOR0    = vec4(1.0, 0.0, 0.0, 1.0);

vec3 a_position  : POSITION;
vec4 a_color0    : COLOR0;
```

A typical compile looks like this:

```
shaderc -f vs_cubes.sc --type vertex --platform windows -p s_5_0 -i src -o vs_cubes.bin
```

Then compiling it takes these steps:

**1. Preprocess, first pass.** The source goes through the C preprocessor once, with the platform, language and shader type defines set, so that includes are pulled in and any `#if` around the `$input` and `$output` lines is resolved.

**2. Parse the `$input` and `$output` lines.** These are not preprocessor directives. `shaderc` reads them off the top of the preprocessed text and strips them. They list which of the varyings from `varying.def.sc` this shader uses. `shaderc` also hashes the sorted list so that at runtime bgfx can verify a vertex shader's outputs match a fragment shader's inputs.

**3. Build a preamble.** This is where the target language is decided, and it is done by generating text and prepending it to the source. For HLSL-family targets the preamble starts with the type aliases:

```cpp
	preprocessor.writef(
		"#define lowp\n"
		"#define mediump\n"
		"#define highp\n"
		"#define ivec2 int2\n"
		"#define ivec3 int3\n"
		"#define ivec4 int4\n"
		"#define uvec2 uint2\n"
		"#define uvec3 uint3\n"
		"#define uvec4 uint4\n"
		"#define vec2 float2\n"
		"#define vec3 float3\n"
		"#define vec4 float4\n"
		"#define mat2 float2x2\n"
		"#define mat3 float3x3\n"
		"#define mat4 float4x4\n"
		);
```

And then the actual trick. GLSL has `void main()` with globals for inputs and outputs. HLSL wants an entry point with typed, semantic-annotated parameters and a return struct. `shaderc` generates a macro for that from the varyings, roughly for the vertex shader above:

```hlsl
struct Output
{
	vec4 gl_Position : SV_POSITION;
#define gl_Position _varying_.gl_Position
	vec4 v_color0 : COLOR0;
#define v_color0 _varying_.v_color0
};
#define void_main() \
Output main( \
	vec3 a_position : POSITION \
	, vec4 a_color0 : COLOR0 \
	) \
{ \
	Output _varying_; \
	v_color0 = vec4(1.0, 0.0, 0.0, 1.0);
#define __RETURN__ \
	} \
	return _varying_
```

The `vec3` and `vec4` in there are fine, because the type aliases above turn them into `float3` and `float4` on the way through. `smooth` and `flat` from `varying.def.sc` are rewritten to `linear` and `nointerpolation` while the struct is being generated.

**4. Patch the source.** The shader still says `void main()`. `shaderc` finds it and overwrites one byte, the space, with an underscore, so it now reads `void_main()` and expands to the macro above. For vertex shaders it then finds the closing brace of `main` and inserts `__RETURN__;` in front of it. That is the entire "translation" of the entry point: one byte and one string insert.

```cpp
	*const_cast<char*>(entry.getPtr() + 4) = '_';
```

The fragment shader side is the same idea, except `main` stays `void` and outputs become `out` parameters. `gl_FragColor` becomes `bgfx_FragData0 : SV_TARGET0`, `gl_FragCoord` becomes a `SV_POSITION` parameter, `gl_FrontFacing` is `SV_IsFrontFace`. Which of these get added to the signature is decided by searching the source text for the identifier.

**5. Preprocess, second pass.** The preamble plus the patched source go through the preprocessor again, and this time the macros do their work. `void_main()` expands, `vec4` becomes `float4`, and `bgfx_shader.sh`, which the shader included through `common.sh`, supplies the rest. That header is where `SAMPLER2D`, `texture2D`, `mul`, `mtxFromRows`, `vec4_splat` and friends are defined per language. For HLSL it wraps texture and sampler pairs into structs so that GLSL-style `texture2D(s_tex, uv)` works; for GLSL it defines `mul(a, b)` as `a * b`. The header, not the compiler, is where most of the language knowledge lives:

```glsl
// HLSL
#define SAMPLER2D(_name, _reg) \
	uniform SamplerState _name ## Sampler : REGISTER(s, _reg); \
	uniform Texture2D    _name ## Texture : REGISTER(t, _reg); \
	static BgfxSampler2D _name = { _name ## Sampler, _name ## Texture }

// GLSL
#define SAMPLER2D(_name, _reg) uniform sampler2D _name
#define mul(_a, _b) ( (_a) * (_b) )
```

For `vs_cubes.sc`, after that pass, the entry point FXC sees is roughly:

```hlsl
struct Output
{
	float4 gl_Position : SV_POSITION;
	float4 v_color0 : COLOR0;
};

Output main(float3 a_position : POSITION, float4 a_color0 : COLOR0)
{
	Output _varying_;
	_varying_.v_color0 = float4(1.0, 0.0, 0.0, 1.0);
	_varying_.gl_Position = mul(u_modelViewProj, float4(a_position, 1.0) );
	_varying_.v_color0 = a_color0;
	return _varying_;
}
```

Above that sits the rest of `bgfx_shader.sh`: built-in uniforms, `mul`, splat helpers, the lot. `--preprocess` dumps this text. When a target compiler complains, the code it is complaining about is this, not the `.sc` you wrote.

**6. Hand it to a real compiler.** The preprocessed text is now legal GLSL or legal HLSL, and it goes to FXC, DXC, Glslang, or whatever the profile wants. What comes back is the shader binary. Uniform and sampler reflection is taken from the compiler that produced it: `D3DReflect` after FXC, DXC's reflection blob after DXIL, Glslang's live uniforms or SPIRV-Cross resources after anything that went through SPIR-V. `shaderc` writes that into its own container, ahead of the shader blob, together with the `$input` and `$output` hashes from step 2.

## Before and after glsl-optimizer

This is what `shaderc` looked like just before the glsl-optimizer removal in August 2026, with every target it had accumulated:

<div align="center">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 940 540" width="100%" style="max-width:940px;height:auto" font-family="Noto, sans-serif" font-size="13" fill="currentColor">
<defs><marker id="ahBefore" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>
<rect x="300" y="12" width="340" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="470.0" y="31.5" text-anchor="middle">.sc source + varying.def.sc + bgfx_shader.sh</text>
<rect x="300" y="72" width="340" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="470.0" y="91.5" text-anchor="middle">fcpp (C preprocessor)</text>
<rect x="95" y="150" width="260" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="225.0" y="168" text-anchor="middle" font-weight="600">GLSL-style patching</text>
<text x="225.0" y="184" text-anchor="middle" font-size="11" fill-opacity="0.75">attribute/varying, #version, #extension</text>
<rect x="20" y="240" width="205" height="58" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" stroke-dasharray="5 4"/>
<text x="122.5" y="258" text-anchor="middle" font-weight="600">glsl-optimizer</text>
<text x="122.5" y="274" text-anchor="middle" font-size="11" fill-opacity="0.75">Mesa GLSL IR → GLSL / ESSL</text>
<text x="122.5" y="288" text-anchor="middle" font-size="11" fill-opacity="0.75">GLSL 1.20–4.00, ESSL 1.00–3.00</text>
<rect x="245" y="240" width="175" height="58" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="332.5" y="258" text-anchor="middle" font-weight="600">pass-through</text>
<text x="332.5" y="274" text-anchor="middle" font-size="11" fill-opacity="0.75">GLSL 4.10+, ESSL 3.10–3.20</text>
<text x="332.5" y="288" text-anchor="middle" font-size="11" fill-opacity="0.75">no validation at all</text>
<rect x="95" y="340" width="260" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="225.0" y="358" text-anchor="middle" font-weight="600">GLSL / ESSL text</text>
<text x="225.0" y="374" text-anchor="middle" font-size="11" fill-opacity="0.75">OpenGL, OpenGL ES, WebGL</text>
<rect x="560" y="150" width="280" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="700.0" y="168" text-anchor="middle" font-weight="600">HLSL-style patching</text>
<text x="700.0" y="184" text-anchor="middle" font-size="11" fill-opacity="0.75">void_main(), Output struct, semantics</text>
<rect x="440" y="240" width="165" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="522.5" y="258" text-anchor="middle" font-weight="600">FXC</text>
<text x="522.5" y="274" text-anchor="middle" font-size="11" fill-opacity="0.75">D3DCompiler_47, d3d4linux</text>
<rect x="620" y="240" width="125" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="682.5" y="258" text-anchor="middle" font-weight="600">DXC</text>
<text x="682.5" y="274" text-anchor="middle" font-size="11" fill-opacity="0.75">DXCompiler, SM 6.x</text>
<rect x="760" y="240" width="150" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="835.0" y="258" text-anchor="middle" font-weight="600">Glslang</text>
<text x="835.0" y="274" text-anchor="middle" font-size="11" fill-opacity="0.75">HLSL front-end</text>
<rect x="440" y="330" width="165" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="522.5" y="349.5" text-anchor="middle">DXBC → D3D11</text>
<rect x="620" y="330" width="125" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="682.5" y="349.5" text-anchor="middle">DXIL → D3D12</text>
<rect x="760" y="330" width="150" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="835.0" y="349.5" text-anchor="middle">SPIR-V</text>
<rect x="760" y="405" width="150" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="835.0" y="424.5" text-anchor="middle">SPIRV-Tools optimizer</text>
<rect x="600" y="480" width="100" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="650.0" y="498" text-anchor="middle" font-weight="600">SPIR-V</text>
<text x="650.0" y="514" text-anchor="middle" font-size="11" fill-opacity="0.75">Vulkan</text>
<rect x="710" y="480" width="110" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="765.0" y="498" text-anchor="middle" font-weight="600">SPIRV-Cross</text>
<text x="765.0" y="514" text-anchor="middle" font-size="11" fill-opacity="0.75">MSL → Metal</text>
<rect x="830" y="480" width="100" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="880.0" y="498" text-anchor="middle" font-weight="600">Tint</text>
<text x="880.0" y="514" text-anchor="middle" font-size="11" fill-opacity="0.75">WGSL → WebGPU</text>
<line x1="700.0" y1="194" x2="700.0" y2="220" stroke="currentColor" stroke-width="1.2"/>
<line x1="522.5" y1="220" x2="835.0" y2="220" stroke="currentColor" stroke-width="1.2"/>
<polyline points="522.5,220 522.5,240" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="682.5,220 682.5,240" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="835.0,220 835.0,240" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="522.5,284 522.5,330" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="682.5,284 682.5,330" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="835.0,284 835.0,330" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="835.0,360 835.0,405" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<line x1="835.0" y1="435" x2="835.0" y2="458" stroke="currentColor" stroke-width="1.2"/>
<line x1="650.0" y1="458" x2="880.0" y2="458" stroke="currentColor" stroke-width="1.2"/>
<polyline points="650.0,458 650.0,480" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="765.0,458 765.0,480" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="880.0,458 880.0,480" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="470.0,42 470.0,72" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<line x1="470.0" y1="102" x2="470.0" y2="122" stroke="currentColor" stroke-width="1.2"/>
<line x1="225.0" y1="122" x2="700.0" y2="122" stroke="currentColor" stroke-width="1.2"/>
<polyline points="225.0,122 225.0,150" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="700.0,122 700.0,150" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<line x1="225.0" y1="194" x2="225.0" y2="220" stroke="currentColor" stroke-width="1.2"/>
<line x1="122.5" y1="220" x2="332.5" y2="220" stroke="currentColor" stroke-width="1.2"/>
<polyline points="122.5,220 122.5,240" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="332.5,220 332.5,240" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
<polyline points="122.5,298 122.5,320 225.0,320" fill="none" stroke="currentColor" stroke-width="1.2"/>
<polyline points="332.5,298 332.5,320 225.0,320" fill="none" stroke="currentColor" stroke-width="1.2"/>
<polyline points="225.0,320 225.0,340" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahBefore)"/>
</svg>
</div>

The left side is the legacy. glsl-optimizer's front-end was Mesa as of the mid-2010s, and it never implemented GLSL 4.x, so anything above 4.00 (and ESSL above 3.00) had, since 2017, been passed through untouched. In practice that meant a GLSL 4.30 shader got **no validation at all** at build time. You found out it was broken when the driver rejected it at runtime, on whichever machine happened to run it first. Meanwhile every extension needed on the GLSL side was detected by grepping the source for identifiers and prepending `#extension` lines. glsl-optimizer would then add its own `EXT` and `ARB` suffixes to the functions those extensions provide, which had to be patched back out so that the same shader would load across GLSL and ESSL versions, and the runtime would re-add whatever the driver actually needed.

After removing glsl-optimizer and raising the minimum API versions on OpenGL to 4.3 and OpenGL ES to 3.0, and [replacing fcpp with a preprocessor of my own](/posts/preprocessor/), this is how the compiler looks today:

<div align="center">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 940 540" width="100%" style="max-width:940px;height:auto" font-family="Noto, sans-serif" font-size="13" fill="currentColor">
<defs><marker id="ahAfter" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>
<rect x="300" y="12" width="340" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="470.0" y="31.5" text-anchor="middle">.sc source + varying.def.sc + bgfx_shader.sh</text>
<rect x="300" y="72" width="340" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="470.0" y="91.5" text-anchor="middle">shaderc::Preprocessor (pp.cpp)</text>
<rect x="95" y="150" width="260" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="225.0" y="168" text-anchor="middle" font-weight="600">GLSL-style patching</text>
<text x="225.0" y="184" text-anchor="middle" font-size="11" fill-opacity="0.75">attribute/varying, #version, a few #extension</text>
<rect x="95" y="240" width="260" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="225.0" y="258" text-anchor="middle" font-weight="600">Glslang</text>
<text x="225.0" y="274" text-anchor="middle" font-size="11" fill-opacity="0.75">GLSL front-end</text>
<rect x="95" y="330" width="260" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="225.0" y="349.5" text-anchor="middle">SPIR-V</text>
<rect x="95" y="405" width="260" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="225.0" y="424.5" text-anchor="middle">SPIRV-Tools optimizer</text>
<rect x="95" y="480" width="260" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="225.0" y="498" text-anchor="middle" font-weight="600">SPIRV-Cross</text>
<text x="225.0" y="514" text-anchor="middle" font-size="11" fill-opacity="0.75">GLSL 3.30–4.40, ESSL 3.00–3.20</text>
<rect x="560" y="150" width="280" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="700.0" y="168" text-anchor="middle" font-weight="600">HLSL-style patching</text>
<text x="700.0" y="184" text-anchor="middle" font-size="11" fill-opacity="0.75">void_main(), Output struct, semantics</text>
<rect x="440" y="240" width="165" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="522.5" y="258" text-anchor="middle" font-weight="600">FXC</text>
<text x="522.5" y="274" text-anchor="middle" font-size="11" fill-opacity="0.75">D3DCompiler_47, d3d4linux</text>
<rect x="620" y="240" width="125" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="682.5" y="258" text-anchor="middle" font-weight="600">DXC</text>
<text x="682.5" y="274" text-anchor="middle" font-size="11" fill-opacity="0.75">DXCompiler, SM 6.x</text>
<rect x="760" y="240" width="150" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="835.0" y="258" text-anchor="middle" font-weight="600">Glslang</text>
<text x="835.0" y="274" text-anchor="middle" font-size="11" fill-opacity="0.75">HLSL front-end</text>
<rect x="440" y="330" width="165" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="522.5" y="349.5" text-anchor="middle">DXBC → D3D11</text>
<rect x="620" y="330" width="125" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="682.5" y="349.5" text-anchor="middle">DXIL → D3D12</text>
<rect x="760" y="330" width="150" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="835.0" y="349.5" text-anchor="middle">SPIR-V</text>
<rect x="760" y="405" width="150" height="30" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="835.0" y="424.5" text-anchor="middle">SPIRV-Tools optimizer</text>
<rect x="600" y="480" width="100" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="650.0" y="498" text-anchor="middle" font-weight="600">SPIR-V</text>
<text x="650.0" y="514" text-anchor="middle" font-size="11" fill-opacity="0.75">Vulkan</text>
<rect x="710" y="480" width="110" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="765.0" y="498" text-anchor="middle" font-weight="600">SPIRV-Cross</text>
<text x="765.0" y="514" text-anchor="middle" font-size="11" fill-opacity="0.75">MSL → Metal</text>
<rect x="830" y="480" width="100" height="44" rx="4" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2" />
<text x="880.0" y="498" text-anchor="middle" font-weight="600">Tint</text>
<text x="880.0" y="514" text-anchor="middle" font-size="11" fill-opacity="0.75">WGSL → WebGPU</text>
<line x1="700.0" y1="194" x2="700.0" y2="220" stroke="currentColor" stroke-width="1.2"/>
<line x1="522.5" y1="220" x2="835.0" y2="220" stroke="currentColor" stroke-width="1.2"/>
<polyline points="522.5,220 522.5,240" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="682.5,220 682.5,240" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="835.0,220 835.0,240" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="522.5,284 522.5,330" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="682.5,284 682.5,330" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="835.0,284 835.0,330" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="835.0,360 835.0,405" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<line x1="835.0" y1="435" x2="835.0" y2="458" stroke="currentColor" stroke-width="1.2"/>
<line x1="650.0" y1="458" x2="880.0" y2="458" stroke="currentColor" stroke-width="1.2"/>
<polyline points="650.0,458 650.0,480" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="765.0,458 765.0,480" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="880.0,458 880.0,480" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="470.0,42 470.0,72" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<line x1="470.0" y1="102" x2="470.0" y2="122" stroke="currentColor" stroke-width="1.2"/>
<line x1="225.0" y1="122" x2="700.0" y2="122" stroke="currentColor" stroke-width="1.2"/>
<polyline points="225.0,122 225.0,150" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="700.0,122 700.0,150" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="225.0,194 225.0,240" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="225.0,284 225.0,330" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="225.0,360 225.0,405" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
<polyline points="225.0,435 225.0,480" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahAfter)"/>
</svg>
</div>

Every target now has a validated front-end; every target except FXC and DXC produces SPIR-V on the way. The GLSL / HLSL fork is still there: a shader can compile as `spirv` and fail as `430`, because those are not the same program.

### Could it be simpler?

If you look carefully at the diagram, you might notice that the GLSL and HLSL patching could be unified, because Glslang accepts HLSL and SPIRV-Cross is already used to output GLSL/ESSL. This would simplify the preprocessor macros and the patching, but having two paths keeps some flexibility for when a new shader language needs to be added, which doesn't happen often.

Another thing that might not be obvious is that the bgfx shader language could simply be HLSL. Some of the bgfx shaping happens with preprocessor macros, but it's feasible to do that transformation inside Glslang traversers, with plain HLSL as the front-end. It might look like the obvious choice to switch the default bgfx shader language to HLSL.

The problem is that this would tie `shaderc` to Glslang even further, and I don't control where Glslang goes. This is not hypothetical. In April 2026 Glslang [proposed deprecating and removing its HLSL front-end](https://github.com/KhronosGroup/glslang/issues/4210), and the README now reads:

> The HLSL front-end is deprecated as of April 2026 and will be removed at the next major version of glslang. [...] Projects that require continued HLSL support should maintain a fork of glslang at the tag corresponding to the deprecation announcement.

Had the bgfx shader language been HLSL, every existing shader would now need to move. Because the language is GLSL and HLSL is only an intermediate, the exposure is limited to the `spirv`, `metal` and `wgsl` paths, and those can be moved to another HLSL compiler, or to the GLSL front-end, without touching a single `.sc` file.

It cuts the other way too. The WGSL path exists only because I carry a stripped-down copy of Tint for one translation, SPIR-V to WGSL. SPIRV-Cross already does SPIR-V to GLSL, ESSL and MSL for me, so in January 2026 I [asked](https://github.com/KhronosGroup/SPIRV-Cross/issues/2587) whether it could do WGSL as well and let me drop Tint. The maintainer's answer:

> I don't have bandwidth to implement and maintain yet another backend. There is also no motivation to effectively duplicate the effort that Tint already does.

Fair enough on bandwidth. But SPIRV-Cross is not one person's side project, it is a Khronos project, and WGSL is a W3C standard implemented in every major browser. If the "Cross" in SPIRV-Cross is understood as "to every shading language", this is Khronos declining to cross to one of them, and pointing at Google's compiler instead. That is the whole reason `shaderc` looks the way it does. Every project in the pipeline solves its own problem, none of them shares bgfx's vision, and nobody is obliged to. The Frankenstein is not a design choice. It is what you get when you assemble a compiler from parts whose owners don't answer to you, and the seams between them are yours to maintain.

## glsl-optimizer was a great idea!

[glsl-optimizer](https://aras-p.info/blog/2010/09/29/glsl-optimizer/) was built for Unity 3.0, where it made mobile shaders faster on drivers whose own compilers did little or no optimization. bgfx picked it up for the same reason: in 2012 the GLSL targets were Android and Native Client, and the shader compilers behind those were not something you wanted to trust with unoptimized code.

**It is simple.** The library is Mesa's GLSL front-end, Mesa's IR, Mesa's optimization passes, and one file, `ir_print_glsl_visitor.cpp`, that walks the IR and prints GLSL. Metal support, when it came, was a second printer, `ir_print_metal_visitor.cpp`. The public API is a dozen C functions in one header, and the ones you need are initialize, optimize, get status, get log, get output, cleanup. The initial `shaderc.cpp` used it in 30 lines.

**The code is clear.** Mesa's GLSL IR is a plain tree of `ir_instruction` nodes with a visitor.

**It outputs source.** This is the property I want to underline, because it is the one that mattered most and the one that is rarest. Most shader compilers produce an IR that a driver consumes: DXBC, DXIL, SPIR-V. Or there is no optimizer, because text is always treated as source, and there is no split between text as source and text as IR. glsl-optimizer showed, in 2010, that the sane way to deal with text as an interchange format is not to ship the shader as the author wrote it, but to run it through a real compiler with real optimization passes and print the result: the minimum code required for the shader, with every dead uniform and unreachable branch already gone. I made this same argument in the [WebGPU post](/posts/webgpu/#wgsl-webgpu-shading-language) when defending WGSL as textual IR; glsl-optimizer is where I got this "aha" moment about how shader code/text should be treated.

**Why it had to go.** Its author stopped working on it in mid-2016 when Unity moved to a proper (proprietary) shader compiler. Mesa has since moved its optimization work to NIR, so the GLSL IR that glsl-optimizer is built on is no longer maintained upstream either. It's a dead project.

## What makes shaderc janky?

In a 2014 [survey of cross platform shaders](https://aras-p.info/blog/2014/03/28/cross-platform-shaders-in-2014/), bgfx was the example of the first, and least sophisticated, approach on the list:

> Write some helper macros to abstract away HLSL & GLSL differences, and make everyone aware of all the differences.

Twelve years later that is still what `shaderc` is, with real compilers bolted on behind the macros. A commenter on Hacker News [put it](https://news.ycombinator.com/item?id=44026828) more bluntly, in a thread about shader compilation for SDL_GPU:

> BGFX uses a different approach. You basically write your shader in a GLSL-like language but it's all just (either very clever or very horrible) macro expansions that handles all the platform differences. With that you get a very performant backend for OpenGL, WebGL, Vulkan, Metal, Direct3D 11 and 12 and Playstation. It's shader compiler program basically does minimal source level transformations before handing it over to the platforms' own shader compiler if available.

I'll take "either".

**Error messages depend on the target.** A shader that fails on `s_5_0` gives you an FXC error. The same shader on `spirv` gives you a Glslang error, on `metal` a Glslang error followed possibly by a SPIRV-Cross assertion, on `wgsl` any of those plus a Tint diagnostic, and on `430` a Glslang error in the GLSL dialect. They report different line numbers, because each one is looking at a different preamble prepended to your code. `shaderc` tries to help by printing the patched source around the reported line, but you still have to know which tool is talking.

**Features are detected by substring.** Whether `gl_FragDepth` appears in the source decides whether `SV_DEPTH` goes into the signature.

**The entry point is a macro.** For a vertex shader, everything about `main` is done by rewriting one byte and inserting `__RETURN__` before the last brace. An early `return;` inside a vertex shader's `main` is a compile error, because `main` now returns `Output`. The docs say attributes and varyings can only be accessed from `main()`, and now you know why: outside `main` there is no `_varying_` to expand to.

**The dialect is real.** `SAMPLER2D(s_tex, 0)` instead of `uniform sampler2D`, `vec4_splat(x)` instead of `vec4(x)`, `mul(a, b)` instead of `a * b`, `mtxFromRows` instead of a matrix constructor, etc. Each of those exists because the two sides disagree and the preprocessor cannot resolve the disagreement without a hint from you.

## How do others do it?

The alternatives I have seen in other open source libraries and engines do not do much better. Most take a similar Frankenstein approach: a shader compiler assembled from parts of other shader compilers, written by different teams with different goals. Here is how the ones I know of get from what you write to what the GPU driver accepts, sorted into four groups by how much of the job they actually do themselves.

**Janky.** Text goes in, gets transformed, and is handed to whichever compiler the target uses. Each of those compilers is free to accept or reject the result on its own terms, so the same source can pass on one API and fail on another. That is the jank, and this is the `shaderc` family:

| | **You write** | **How it gets there** | **Outputs** |
|---|---|---|---|
| **bgfx `shaderc`** | GLSL dialect + macros | preprocessor + text patching → FXC / DXC / Glslang → SPIRV-Cross / Tint | DXBC, DXIL, SPIR-V, GLSL, ESSL, MSL, WGSL, PSSL |
| [The Forge](https://github.com/ConfettiFX/The-Forge/tree/master/Common_3/Tools/ForgeShadingLanguage) | FSL, an HLSL superset | Python translator emits per-platform source → DXC / Glslang / metal / psslc | DXIL, SPIR-V, metallib, PSSL |
| [Magnum](https://github.com/mosra/magnum) | GLSL | runtime `#define` assembly per GL version, Glslang plugin | GLSL, SPIR-V |
| [Diligent Engine](https://github.com/DiligentGraphics/DiligentCore) | HLSL (also GLSL, MSL, WGSL) | own HLSL→GLSL text converter for OpenGL; FXC / DXC, Glslang → SPIR-V, Tint → WGSL elsewhere | DXBC, DXIL, GLSL, SPIR-V, MSL, WGSL |
| [Flax Engine](https://github.com/FlaxEngine/FlaxEngine) | HLSL | FXC for SM5, DXC for SM6, Glslang HLSL front-end → SPIR-V | DXBC, DXIL, SPIR-V |

**Text translators.** One parser of their own, one set of emitters of their own, and nothing you would call an optimizer in between. They print what you wrote in the target's language and let the driver's compiler do the rest. All three exist because a browser needed to compile somebody else's shading language safely:

| | **You write** | **How it gets there** | **Outputs** |
|---|---|---|---|
| [Dawn / Tint](https://github.com/google/dawn/tree/main/src/tint) | WGSL (also SPIR-V in) | own readers → Tint IR → own writers, [legalization and dead code elimination only](https://github.com/google/dawn/tree/main/src/tint/lang/core/ir/transform), no optimizer | SPIR-V, MSL, HLSL, GLSL, WGSL |
| [wgpu / Naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga) | WGSL (also GLSL, SPIR-V in) | own front-ends → Naga IR → own back-ends, constant evaluation and pruning only | SPIR-V, MSL, HLSL, GLSL, WGSL |
| [ANGLE](https://github.com/google/angle/blob/main/README.md) | GLSL ES | own translator → own AST → own back-ends, AST clean-up only, [no SPIRV-Tools](https://github.com/google/angle/blob/main/src/libANGLE/renderer/vulkan/doc/ShaderModuleCompilation.md) | HLSL, GLSL, SPIR-V, MSL, WGSL |

**A real front-end.** One compiler parses and validates the source, so an error is the same error no matter which backend you asked for, and one source really does target every backend. What happens after that is somebody else's back-end: usually SPIR-V as the interchange format and SPIRV-Cross or Tint printing whatever the target wants. Some of these have a parser of their own in front (Godot, O3DE, Stride), but it only produces text for the next tool in line:

| | **You write** | **How it gets there** | **Outputs** |
|---|---|---|---|
| [sokol-shdc](https://github.com/floooh/sokol-tools/blob/master/docs/sokol-shdc.md) | Vulkan GLSL 450 + `@` tags | Glslang → SPIRV-Tools → SPIRV-Cross / Tint | SPIR-V, GLSL, ESSL, HLSL, MSL, WGSL |
| [SDL_GPU](https://github.com/libsdl-org/SDL_shadercross) (SDL_shadercross) | HLSL or SPIR-V | DXC → DXIL / SPIR-V, FXC → DXBC, SPIRV-Cross → MSL | DXBC, DXIL, SPIR-V, MSL |
| [Filament](https://github.com/google/filament) | ESSL 3.0 | Glslang → SPIRV-Tools → SPIRV-Cross / Tint | SPIR-V, GLSL, ESSL, MSL, WGSL |
| [Godot 4](https://godotengine.org/article/d3d12-adventures-in-shaderland/) | Godot shading language | own parser emits GLSL → Glslang → SPIR-V → Mesa NIR → DXIL, SPIRV-Cross → MSL | SPIR-V, DXIL, MSL, GLSL |
| [O3DE](https://github.com/o3de/o3de-azslc) | AZSL, an HLSL superset | mcpp → AZSLc → HLSL → DXC, SPIRV-Cross → MSL | DXIL, SPIR-V, MSL |
| [Stride](https://github.com/stride3d/stride) | SDSL, an HLSL superset | own compiler → HLSL → FXC; SPIR-V pipeline in progress | DXBC, SPIR-V, GLSL |
| [Wicked Engine](https://github.com/turanszkij/WickedEngine) | HLSL SM6 | DXC → DXIL / SPIR-V, Metal Shader Converter → metallib | DXBC, DXIL, SPIR-V, metallib |
| [Veldrid](https://github.com/veldrid/veldrid-spirv) | Vulkan GLSL or SPIR-V | Glslang → SPIR-V → SPIRV-Cross, at runtime | HLSL, GLSL, ESSL, MSL |
| [ShaderConductor](https://github.com/microsoft/ShaderConductor) | HLSL | DXC → SPIR-V → SPIRV-Cross (archived 2025) | DXIL, SPIR-V, GLSL, ESSL, MSL |

**Actual compilers.** Text in, optimization in the middle, and out comes whatever the API accepts, with no other compiler in between. Where the API accepts source, as OpenGL, Metal and WebGPU do, that source counts as the API's IR. By that definition the list is short:

| | **You write** | **Straight to the API** | **Still needs** | **Optimization** |
|---|---|---|---|---|
| [Slang](https://github.com/shader-slang/slang) | Slang | SPIR-V, MSL, WGSL, GLSL | DXC / FXC for DXIL / DXBC, NVRTC for PTX | own IR passes (specialization, inlining, SSA, dead code), then SPIRV-Tools optimizer at `-O1` and up |
| [glsl-optimizer](https://github.com/aras-p/glsl-optimizer) (2010-2016) | GLSL | GLSL, ESSL, MSL | nothing | Mesa's GLSL IR passes |

Slang qualifies everywhere except Direct3D, because nobody in these tables emits DXIL on their own. It is LLVM 3.7 bitcode that until 2025 had to be signed by Microsoft's `dxil.dll` before a driver would accept it, and the one open source emitter I know of is [Mesa's `nir_to_dxil`](https://gitlab.freedesktop.org/mesa/mesa/-/tree/main/src/microsoft/compiler), which is [how Godot got there](https://godotengine.org/article/d3d12-adventures-in-shaderland/). glsl-optimizer is in the table because, for the one API it served, it was exactly this: parse, optimize, print what the driver accepts. The text translators above would qualify too if they optimized anything, and that is the situation glsl-optimizer was written to fix in 2010. The browsers have chosen to live with it.

Only the last group comes close to having no seam, and the one Slang keeps is Direct3D's doing, not Slang's. Everything above it hands text to a compiler someone else maintains. The real front-ends hide that better than `shaderc` does, at the cost of Glslang and SPIRV-Cross being load-bearing, which is exactly the exposure the HLSL front-end deprecation just demonstrated. None of them removes it, and the ones that look cleaner usually support fewer targets.

## Conclusion

And yet **it works!** Fourteen years, eight target languages, every one of them added without a front-end rewrite. The structure that made this possible is the same one that makes the error messages inconsistent: `shaderc` owns the front of the pipeline, delegates the back, and the seam between them is text. Nearly everyone else in the tables above has that seam in the same place.

The one real newcomer in those tables is [Slang](https://github.com/shader-slang/slang). It is an actual compiler: a front-end, an IR, modules, generics, and code generation for HLSL, GLSL, SPIR-V, MSL, WGSL, and even Slang round-trip from one source. That is the set bgfx needs. It came out of NVIDIA research and has been [hosted by Khronos](https://www.khronos.org/news/press/khronos-group-launches-slang-initiative-hosting-open-source-compiler-contributed-by-nvidia) since late 2024. The press release claims that "Valve compiled the entire production Source 2 HLSL codebase with Slang while modifying only 10 lines of code." It is the first thing in this space that solves the problem instead of routing around it. It did not exist in 2012, which is why `shaderc` is a preprocessor and a hand-off. If this were started today, Slang would be the approach it would take.
