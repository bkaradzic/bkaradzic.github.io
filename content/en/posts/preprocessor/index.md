---
title: Writing a C preprocessor for bgfx shader compiler
date: 2026-08-20
toc: true
---

## Introduction

For 14+ years, every shader that bgfx compiled, starting from the [initial commit](https://github.com/bkaradzic/bgfx/tree/dee3fe5266e9e17a4783df797333b86677e7e2c7), went through a preprocessor written for the Amiga with origins in 1984:

[fcpp - Frexx CPP (C Preprocessor)](https://github.com/bagder/fcpp)

> This is a C preprocessor. It is a project based on public domain code, then forked by Daniel in
> 1993 and future work has been done under a BSD license.

That public domain code is the [DECUS cpp](https://github.com/xianpinder/DecusCPP), written by Martin Minow in 1984–85. So the preprocessor bgfx shipped in 2026 had a code lineage reaching back forty years, by way of an Amiga port. The sources still carry `REG(a0)` register-parameter macros and `#ifdef AMIGA` blocks.

**And it worked.** This deserves emphasis, because the rest of this post is about replacing it. Over fourteen years fcpp needed only 25 commits' worth of attention in the bgfx tree, most of them routine resyncs with upstream. For a dependency you are supposed to forget about, that is close to the ideal outcome.

What made it a good fit specifically was how **configurable** it was. fcpp exposes 37 `FPPTAG_*` options through a single entry point:

```c
int fppPreProcess(struct fppTag *tags);
```

`shaderc` used 13 of them: `FPPTAG_INPUT` and `FPPTAG_OUTPUT` to route all I/O through bgfx's own file abstraction, `FPPTAG_ERROR` to capture diagnostics, `FPPTAG_DEPENDS` for makefile dependency output, plus `FPPTAG_LINE`, `FPPTAG_KEEPCOMMENTS`, `FPPTAG_RIGHTCONCAT` and others to shape the output. Crucially, fcpp keeps **no global mutable state**, everything lives in a `struct Global` allocated per call, and it never insists on calling `fopen` itself. Both properties are rarer than they should be, and both are exactly what an embedder wants. **fcpp got the architecture right.**

## So what's bad about it?

**The code is crufty.** It is K&R-flavoured C89 with 1980s conventions throughout, spread over six `.c` files with names that tell you nothing: `cpp1.c` through `cpp6.c`. State is threaded through a 250-line `struct Global`. Making a behavioural change means understanding a program written under constraints 512 KB of RAM, no function prototypes, that stopped applying decades ago.

**Upstream is frozen.** fcpp is not **abandoned**; Daniel Stenberg still merges the occasional PR. But the most recent one, in November 2025, is titled *"tidy-up whitespace, fix warnings, potential overflow"*. It is janitorial. There has been no functional development in many years. One detail captures the situation precisely. That November 2025 upstream commit fixes an `sprintf` buffer overflow in `cpp3.c`:

```
cpp3.c:336:28: warning: '%4d' directive writing between 4 and 11 bytes into
a region of size between 0 and 6 [-Wformat-overflow=]
```

bgfx had already fixed that exact bug locally in commit [`ab0a091`, on 8 December 2018](https://github.com/bkaradzic/bgfx/commit/ab0a09118e79f5da0a59731c9d8d21261cd3a758), **seven years earlier**. That is what a frozen dependency feels like from the outside: you carry local patches indefinitely, and upstream converges on your fix long after you forgot about it.

## Why bgfx shader compiler needs preprocessor?

It is worth being clear about what that preprocessor is actually doing there, because it is not typical role that C preprocessor usually plays in C/C++ code. bgfx targets a dozen graphics APIs, and each comes with its own shading language: HLSL for Direct3D, Metal Shading Language on Apple platforms, GLSL and its embedded variant for OpenGL, SPIR-V for Vulkan, WGSL for WebGPU. They are close relatives, but they disagree constantly on details, how you declare a texture and its sampler, how you bind one to a register, how you multiply a matrix, what an entry point looks like. Rather than ask people to write and maintain one shader per API, bgfx has them write one bgfx's GLSL-inspired style, then include a header at the top of it: `bgfx_shader.sh` for vertex and fragment shaders, `bgfx_compute.sh` for compute. Those headers are almost nothing **but** preprocessor, a few hundred macros and conditional branches that reshape that single source into whatever the target language expects, selected by defines the compiler sets per target. So the preprocessor is not a preliminary pass that strips comments before the real work begins, it **is** the portability layer, and every shader in every bgfx project goes through it.

## What else is out there?

I looked at what else was out there to find a comparable replacement.

| | **fcpp** | **ucpp** | **mcpp** | **tinycpp** | **tcpp** | **Desired** |
|---|---|---|---|---|---|---|
| Language | C89 | C89/C99 | C89 | C99 + POSIX | C++14 | **C99 or C++20 (or below)** |
| Core size | 5,737 LOC | 10,725 LOC | 17,489 LOC | 2,032 + 624 LOC | 2,331 LOC | **~2-3K LOC max** |
| Files | 6 `.c` + 7 `.h` | 8 `.c` + 7 `.h` | 7 `.c` + 5 `.h` | 2 `.c` + 2 `.h` + 4 `.h` | 1 `.hpp` | **1 `.cpp` + 1 `.h`** |
| Licence | BSD-3 / MIT | BSD-3 | BSD-2 | MIT *(+ LGPL dep)* | Apache-2.0 | **Permissive** |
| Last commit | 2025-11 (janitorial) | 2015 (archived) | 2017 | 2020 | 2025-04 | **active** |
| Third-party deps | none | none | none | libulz (LGPL-2.1) | none | **none** |
| C++ STL | no | no | no | no | heavy | **no** |
| Custom allocator | no | no | no | no | no | **yes** |
| Global mutable state | no | yes | yes | no | no | **no** |
| Virtual filesystem | partial | no | no | no | yes | **yes** |
| Structured error callback | yes | opt-in | text only | no / stderr | yes | **yes** |
| Calls `exit()` | no | yes | likely | no | no | **no** |
| Variadic macros | no | yes | yes | yes | no | **yes** |
| Trigraphs / digraphs | no | yes | yes | no | no | **Don't care!** |

</br>
A few notes on each.

**[ucpp](https://github.com/lpsantil/ucpp)** is the most standards-serious of the small ones, genuinely, fully C99, with trigraphs, digraphs, `_Pragma` and arbitrary-precision `#if` arithmetic. It is also the largest of them after mcpp: at 10,725 lines it is nearly twice fcpp and four times tinycpp, which is the price of that conformance. It is **archived on GitHub**, with its last commit in March 2015. It keeps preprocessor state in file-scope globals. That rules out two instances at once, which rules out ever compiling shaders on a thread pool. It also resolves `#include` by calling `fopen` itself, and its fatal path is `die()` → `exit(1)`.

**[mcpp](https://github.com/ned14/mcpp)** is the conformance champion, and is honest about it, the README claims *"the highest conformance"* and it ships a validation suite so respected that tinycpp's author used it to test his own implementation. It is also 17,489 lines with an autoconf build, module-level global state, a `mcpp_lib_main(int argc, char **argv)` entry point that wants *command-line arguments*, and no way to intercept include resolution. It is a compiler component that grew a library mode, not a library. **Last commit: 2017.**

**[tinycpp](https://github.com/rofl0r/tinycpp)** is the closest in spirit to what I wanted. The smallest real implementation in the survey at 2,032 lines, MIT, with a clean opaque-handle API and no globals. Three things stopped us, and the first is fatal on its own. tinycpp is MIT, but it is not self-contained: it needs `tglist.h` and `hbmap.h` from [libulz](https://github.com/rofl0r/libulz) which is **LGPL-2.1**! Then its I/O is `FILE*`-shaped, and diagnostics go straight to `stderr` with no callback.

**[tcpp](https://github.com/bnoazx005/tcpp)** is aimed squarely at shader preprocessing, which makes it the most obvious candidate on paper, and it has the nicest embedding story of the lot: an `IInputStream` interface and a `std::function` include callback, so it never touches the filesystem. But it is a single 2,331-line header that includes `<string>`, `<vector>`, `<list>`, `<unordered_map>`, `<unordered_set>`, `<sstream>`, `<functional>`, `<memory>`, `<algorithm>`, `<tuple>` and `<stack>`. 🤮 **Nope!** 

The pattern across all five: the ones with clean embedding stories are STL-heavy or unmaintained, the ones with real conformance are large and full of globals, the one that is small and well-designed drags in an LGPL dependency, and **none** of them let you supply an allocator.

## Writing C preprocessor from scratch

`shaderc::Preprocessor` is around 3K lines of code across `pp.cpp` and `pp.h`. The public surface is deliberately tiny - its entire public surface is one callback interface and one class:

```cpp
namespace shaderc
{
	/// Position in the source being preprocessed.
	///
	struct SourceLocation
	{
		/// Default constructor.
		///
		SourceLocation()
			: line(0) {}

		/// Constructor with specific file, and line number.
		///
		SourceLocation(const bx::StringView& _file, uint32_t _line)
			: file(_file), line(_line) {}

		bx::StringView file; //!< File the location is in.
		uint32_t       line; //!< One-based line number inside `file`.
	};

	/// Host hooks for the preprocessor.
	///
	/// All file IO and diagnostics are routed through these so the engine itself never touches
	/// the filesystem and stays reentrant. One `Preprocessor` instance is one independent unit
	/// of work.
	///
	struct BX_NO_VTABLE PreprocessorCallbackI
	{
		///
		virtual ~PreprocessorCallbackI() = 0;

		/// Resolve and read `#include`.
		///
		/// @param[in]  _name Include name, without quotes or angle brackets.
		/// @param[in]  _isSystem True for `<...>`, and false for `"..."`.
		/// @param[in]  _from File holding the directive, so that quoted include can be resolved
		///   relative to it.
		/// @param[out] _writer File text is written here. Preprocessor owns the storage, and
		///   copies it out before this call returns, so nothing has to outlive the call.
		/// @param[out] _outPath Resolved path, used for dependency reporting.
		/// @param[out] _err Error, set if writing file text fails.
		///
		/// @returns True if include is resolved and read, otherwise returns false.
		///
		virtual bool include(
			  const bx::StringView& _name
			, bool _isSystem
			, const bx::StringView& _from
			, bx::WriterI* _writer
			, bx::FilePath& _outPath
			, bx::Error* _err
			) = 0;

		/// Reports file the output depends on. It's called for the main source, and for every
		/// opened include.
		///
		/// @param[in] _path Resolved path of the file.
		///
		/// @remarks Default implementation ignores dependencies.
		///
		virtual void depend(const bx::StringView& _path) = 0;

		/// Diagnostic sink.
		///
		/// @param[in] _isError True for `#error` and hard failures, and false for `#warning`.
		/// @param[in] _location Source position the diagnostic originated from.
		/// @param[in] _message Diagnostic message.
		///
		virtual void message(
			  bool _isError
			, const SourceLocation& _location
			, const bx::StringView& _message
			) = 0;
	};

	inline PreprocessorCallbackI::~PreprocessorCallbackI()
	{
	}

	/// C-style preprocessor.
	///
	/// Supports object and function macros (including variadics and `__VA_OPT__`), `#` and `##`,
	/// `#if`, `#ifdef`, `#ifndef`, `#elif`, `#elifdef`, `#elifndef`, `#else`, `#endif`,
	/// `#include`, `#line`, `#pragma once`, `#error`, `#warning`, and `__LINE__`, `__FILE__` and
	/// `__COUNTER__`. There are no trigraphs or digraphs.
	///
	class Preprocessor
	{
		BX_CLASS(Preprocessor
			, NO_COPY
			);

	public:
		/// Constructor.
		///
		/// @param[in] _callback Host hooks. It must outlive Preprocessor.
		/// @param[in] _allocator Allocator. It must not be NULL, and it must outlive
		///   Preprocessor.
		///
		Preprocessor(PreprocessorCallbackI& _callback, bx::AllocatorI* _allocator);

		/// Destructor.
		///
		~Preprocessor();

		/// Predefine macro, mirroring `-D` command-line define.
		///
		/// @param[in] _define Macro in `NAME`, `NAME=VALUE`, or `NAME(a,b)=body` form.
		///
		void define(const bx::StringView& _define);

		/// Remove predefined, or previously defined macro.
		///
		/// @param[in] _name Macro name.
		///
		void undefine(const bx::StringView& _name);

		/// Emit `#line <line> "<file>"` directives into the output so that consumer can map the
		/// result back to the original source.
		///
		/// @param[in] _emit True to emit `#line` directives.
		///
		/// @remarks It's off by default. Directives, skipped `#if` branches, and `#include` all
		///   break 1:1 line mapping, so this is the only way to get meaningful positions, but it
		///   requires consumer to understand `#line`.
		///
		void setEmitLineDirectives(bool _emit);

		/// Preprocess source.
		///
		/// @param[in]  _name Source name, used for diagnostics and `__FILE__`.
		/// @param[in]  _source Source to preprocess.
		/// @param[out] _writer Result is written here.
		/// @param[out] _err Error, set if writing result fails.
		///
		/// @returns True on success, or false if `#error`, or hard error was reported.
		///
		bool preprocess(
			  const bx::StringView& _name
			, const bx::StringView& _source
			, bx::WriterI* _writer
			, bx::Error* _err
			);

	private:
		struct PreprocessorImpl* m_impl;
	};

} // namespace shaderc
```

That is the whole API. Compare it to fcpp's 37 tags, of which we used 13 and ignored 24.

It supports `#define`, `#undef`, `#if`, `#ifdef`, `#ifndef`, `#elif`, `#else`, `#endif`, `#include`, `#pragma`, `#error`, `#warning` and `#line`; object and function macros including variadics; `#` and `##`; and `__LINE__` and `__FILE__`.

**1. We do not care about full C99 conformance.** Trigraphs and digraphs exist so that 1980s terminals lacking `#`, `[` and `{` could write C. No shader has ever needed `??=define`. `_Pragma`, `#include_next`, universal character names in identifiers and multi-byte identifier support are all similarly irrelevant to GLSL and HLSL. Every one of those features is code that must be written, tested, and read by the next person. ucpp and mcpp are **correct** to implement them, they are targeting C compilers. We are targeting shaders, and the honest scope is much smaller.

**2. But we are conformant where it actually matters.** The two hardest parts of a C preprocessor are recursive macro expansion and `##`. And both are supported. This is not a hypothetical requirement: bgfx's own shader headers lean hard on both, and getting either subtly wrong produces a shader that still compiles and quietly does the wrong thing.

**3. The allocator is injectable, and nothing else allocates.** `Preprocessor` takes an `AllocatorI*`. Internally everything lands in an arena that bump-allocates 16-byte-aligned blocks and frees them all at once. Tokens, macro bodies and interned strings are arena-allocated and never individually freed, because a preprocessor run is a phase with a natural end. **None of the five alternatives offers this.** All four C implementations hard-code `malloc`/`free`; tcpp hard-codes the C++ default allocator. For a codebase whose whole premise is that you control your own memory, that is disqualifying on its own. 

**4. No third-party dependencies.** `pp.cpp` includes only bx headers:

```cpp
#include <bx/allocator.h>
#include <bx/filepath.h>
#include <bx/scanner.h>
#include <bx/sort.h>
#include <tinystl/vector.h>
```

**5. The lexer is `bx::Scanner`, not ad-hoc character scanning.** bx already had a [scanner](/posts/scanner.html) with `accept`, `acceptWhile` and character-class handling, and it does line counting for us. Every preprocessor in the comparison hand-rolls this, and hand-rolled lexers are where off-by-one and line-number bugs live. Reusing the scanner is the single biggest reason the implementation is 3,000 lines instead of 5,000.

**6. It is reentrant by construction.** No globals, no statics, no `errno`-style side channels, and one `Preprocessor` is one independent unit of work. Nothing prevents compiling shaders in parallel. ucpp and mcpp cannot make this claim.

**7. It never touches the filesystem and it never exits.** Every read goes through `PpCallbackI::include`, so `shaderc` resolves includes with its own search-path logic and could just as easily serve them from memory or an archive. Diagnostics go to `message()` with file, line and severity as *structured data*, not a formatted string on `stderr`. Failures return `false` and set a `bx::Error`. There is no path that calls `exit()` or `abort()` on the host.

## Conclusion

A preprocessor is not something I had longed to rewrite. I wanted to replace it eventually with something better-maintained, but the projects I had bookmarked for a while turned out to be worse than fcpp for the things that matter to me. Recently, after [fixing an issue](https://github.com/bkaradzic/bgfx/commit/c2fb64201b75b6af7ddae9a3e6409a8fc0e46343), I got the itch to challenge my [`bx::Scanner`](/posts/scanner.html) idea by writing something more complicated than an .ini-file parser.

You can check new C preprocessor code in bgfx repo [here](https://github.com/bkaradzic/bgfx/blob/8c283532679dda82de7454fe7af382b36299897a/tools/shaderc/pp.cpp#L6).

fcpp was removed in commit [`8c28353`](https://github.com/bkaradzic/bgfx/commit/8c283532679dda82de7454fe7af382b36299897a), 20 August 2026, after 14 years and 4 months of service. Thanks, fcpp!

