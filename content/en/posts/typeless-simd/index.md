---
title: Making cross-platform SIMD code pleasant
date: 2026-05-03
toc: true
---

## Introduction

Writing fast, portable [SIMD (Single Instruction, Multiple Data)](https://en.wikipedia.org/wiki/Single_instruction,_multiple_data) code has always been painful - verbose [intrinsics](https://en.wikipedia.org/wiki/Intrinsic_function), platform differences, and a type system that fights you at every step. After three major iterations, the [bx library](https://github.com/bkaradzic/bx#bx) now has a much more pleasant solution.

The bx library has had SIMD support since its [initial commit](https://github.com/bkaradzic/bx/commit/4eb80393d11e4cfa65be28bc01057d51d99863a2#diff-5c4f7073eb8792c7b081e10bd217affa861267c6db904e4046d74ccf5ae99557), originally in the form of `float4_t`. A later [major update](https://github.com/bkaradzic/bx/commit/224e990ee4cbfdede21daa790970abebe141836c#diff-525cfe64c6f9487eba1592648cbeba17bdfd0d0182fc7f9388663e998e8a0345) renamed `float4_t` to `simd128_t` and added generics for the register-width type. That interface still leaned too heavily on floating point and lacked a proper lane type - largely because commonly available SIMD features on CPUs at the time were heavily floating-point centric. I’ve now done a third pass. This post walks through the architectural decisions behind the resulting cross-platform typeless SIMD library in bx.

If you’d rather skip the prose, the implementation lives [here](https://github.com/bkaradzic/bx/blob/master/include/bx/simd_t.h).

## How should SIMD code be written?

The single most important thing when SIMDifying code is changing the data layout so the SIMD processor can access data efficiently. That part is fundamentally cross-platform - the only thing that matters is the largest register width on the platforms you target. Just doing the layout change, before you touch a single intrinsic, often improves scalar performance too.

You should always start from a plain-C/C++ reference implementation, and that reference implementation should stay up-to-date with the SIMD one. It's useful for unit-testing, for debugging when the platform-specific code does something surprising, and as living documentation for what each operation is actually supposed to do.

For most use cases the reference plus a single cross-platform SIMD implementation is enough. If you have a hot inner loop that justifies the effort, you can add a third hand-tuned path for a specific CPU - but you shouldn't **start** there.

Prefer static single-assignment (SSA) form, meaning **each line is one SIMD op, producing one new `const`-named temporary**. No reassignment, no nested calls.

In practice that means, instead of:

```cpp
val = simd_or(val, simd_x32_srl(val, 1));
val = simd_or(val, simd_x32_srl(val, 2));
val = simd_or(val, simd_x32_srl(val, 4));
// ...
```

Where each line shadows the previous meaning of `val`, the operation order is hidden inside the nesting, and any debugger you point at it shows you a single name with eight different values along the way, we write:

```cpp
const auto shr1 = simd_x32_srl(val, 1);
const auto or1  = simd_or(val, shr1);
const auto shr2 = simd_x32_srl(or1, 2);
const auto or2  = simd_or(or1, shr2);
const auto shr4 = simd_x32_srl(or2, 4);
const auto or4  = simd_or(or2, shr4);
// ...
```

Every intermediate has a name, every name shows up exactly once on the left-hand side, and the dataflow reads top to bottom. The optimizer doesn't care - the same instructions come out either way.

## Why typeless?

I'd argue strong typing is detrimental to writing SIMD code. Real SIMD code constantly mixes integer and floating-point operations: compare instructions produce masks, masks get applied to lanes via bitwise ops, branchless code falls out of `selb(mask, a, b)`. Type punning between integer and floating-point views of the same register is unavoidable. The type system just gets in the way.

SSE/AVX intrinsics are half-typed: there are only a few types (`__m128`/`__m128i`/`__m128d`), but the instructions still encode the lane type in their name (`_mm_add_ps` vs `_mm_add_epi32`). The type system gets you nothing except compile errors when you reach for the wrong intrinsic. NEON intrinsics goes further and makes every lane configuration a distinct type (`float32x4_t`, `int32x4_t`, `uint8x16_t`, ...), with even more casting. Only WASM SIMD intrinsics took the sane path and dropped the types entirely - the instruction encodes the lane interpretation; the value is just a bag of bits, which is how the hardware sees it anyway.

Hardware SIMD registers (XMM, YMM, NEON registers) really are just bags of bits. The instruction you execute on them decides how those bits are interpreted. Once you accept that, two things happen:

- **Reinterpret casts disappear.** No more `_mm_castps_si128`, no `vreinterpretq_f32_u32`. The same `simd128_t` flows through `f32_add`, `u32_cmpgt`, `selb`, and back to `f32_mul`, with no syntactic ceremony in between.
- **The code reads like the algorithm.** Type-punning steps that used to be noise just aren't there.

## bx SIMD naming convention

    simd[register-width][_<lane-type><lane-type-width>]_<operation>(...)

    <> - not optional
    [] - optional

    register-width: 32, 64, 128, 256
        (omitted for width-generic templates to operate on any available register width)

    lane-type:
        f - floating point
        i - signed integer
        u - unsigned integer
        x - typeless bitwise

    lane-type-width: 8, 16, 32, 64

        +----+----+----+----+----+----+----+----+- ~ -+----+
        | 00 | 01 | 02 | 03 | 04 | 05 | 06 | 07 |  ~  | NN | bytes
        +----+----+----+----+----+----+----+----+- ~ -+----+
        |         register width 32, 64, 128, 256          |
        +----+----+----+----+----+----+----+----+- ~  -----+
        | u8 | u8 | u8 | u8 | u8 | u8 | u8 | u8 |  ~  ...  |
        +----+----+----+----+----+----+----+----+- ~  -----+
        |   u16   |   u16   |   u16   |   u16   |  ~  ...  |
        +---------+---------+---------+---------+- ~  -----+
        |        u32        |        u32        |  ~  ...  |
        +-------------------+-------------------+- ~  -----+
        |                  u64                  |  ~  ...  |
        +---------------------------------------+- ~  -----+

`simd32_f32_add` - arithmetic add on a 32-bit SIMD register with float components, i.e. a single float.
`simd128_f32_add` - same as above, but on a 128-bit SIMD register, which holds 4 floats.
`simd_f32_add` - width-generic implementation; the actual width depends on the SIMD type passed in. Most code should be written in this style, so it remains portable across all widths.

## `simd32_t` as the SIMDification on-ramp

`simd32_t` looks pointless at first - it's a single 32-bit lane, the same shape as a plain `uint32_t`. That's the point. It's not a width, it's a **convention**.

When you take an existing piece of plain C/C++ and start SIMDifying it, the first stop is to retype the locals as `simd32_t` and rewrite the operations as `simd32_*` calls. The data layout doesn't change yet. What changes is that you're now thinking in lanes instead of values. Branches turn into masks, masks turn into `selb`. Once the code is written that way, widening from 32-bit to 128-bit is mostly a search-and-replace - you replace `simd32_t` with `simd128_t`, point the loops at four-element strides, and the operations carry over unchanged.

In quite a few cases the rewrite to `simd32_t` is **all** you need to do - the result already runs perfectly fine on any width register, because nothing in the code cared about the width to begin with. That's the win: you get SIMD-shaped code in one step.

## ABI considerations

For native vector types (`__m128`, `__m256`, `float32x4_t`), pass-by-value is the fast path everywhere. They go straight into vector registers. Pass-by-reference forces a store-to-memory and load-via-pointer round trip, which is strictly worse.

| ABI | `__m128` / `float32x4_t` | `__m256` |
| --- | --- | --- |
| MSVC x64 (default) | XMM0-XMM3 (4 regs) | YMM0-YMM3 (4 regs) |
| MSVC x64 (`__vectorcall`) | XMM0-XMM5 (6 regs) | YMM0-YMM5 (6 regs) |
| GCC/Clang x64 (System V) | XMM0-XMM7 (8 regs) | YMM0-YMM7 (8 regs) |
| ARM64 (AAPCS64) | V0-V7 (8 regs) | N/A |

`__vectorcall` is a real win on MSVC - 6 vector argument registers versus 4 with the default Microsoft x64 ABI. System V already gives you 8, no special calling convention needed.

The `_ref` equivalents (the reference-backend POD structs) are different. `simd32_ref_t` and `simd64_ref_t` fit in a single GPR, and pass-by-value is optimal everywhere - same cost as passing a `uint32_t` or `uint64_t`. `simd128_ref_t` is where MSVC gets weird: System V will pass it in two GPRs, but MSVC's default x64 ABI silently converts any struct over 8 bytes to a hidden pointer, which means an implicit stack copy plus an indirection. `simd256_ref_t` ends up as a hidden pointer on every ABI; write it by-value or by-const-ref, the compiler does the same thing.

When inlining happens - and for `_ref` functions it almost always does, since each one is `inline BX_CONSTEXPR_FUNC` or `BX_SIMD_FORCE_INLINE` - none of this matters; the compiler inlines them out of existence. ABI details only start to bite when inlining doesn't happen: function pointers, virtual dispatch, translation-unit and DLL boundaries.

## Conclusion

None of this is novel in isolation. Data-oriented layout changes, reference implementations, SSA-style coding, typeless registers, and ABI-aware abstractions have all appeared in one form or another across the SIMD landscape. What the new bx SIMD layer delivers is the combination of all these pieces into a single, coherent interface that simply feels good to write.

By making the register a bag of bits, the naming convention predictable, and `simd32_t` a natural on-ramp, the library removes the friction that usually makes SIMD code painful. You spend your time thinking about the algorithm instead of fighting the type system or memorizing platform-specific intrinsics. The same code scales cleanly from a single lane to 256-bit registers, stays readable in the debugger, and performs well across ABIs without hidden costs.

If you've ever looked at a screen full of `_mm_castps_si128` calls and felt your enthusiasm drain away, give this approach a spin. The implementation is already merged and lives [here](https://github.com/bkaradzic/bx/blob/master/include/bx/simd_t.h). Drop `simd32_t` into a scalar hot path, widen it to simd128_t once the logic is clean, and watch the same code run faster on every platform you care about. SIMD doesn't have to be arcane. It's just data in lanes-and now the library gets out of your way so you can actually use it.
