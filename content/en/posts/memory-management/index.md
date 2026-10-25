---
title: 'Blocks with ownership: a novel approach to CPU and GPU memory in C++'
date: 2026-11-16
toc: true
---

## Introduction

Every C and C++ programmer knows the contract: `malloc(size)` returns a pointer, and `free(ptr)` takes it back. The size is missing from the second half, `free` gets only the pointer.

In case you're unfamiliar with how allocators work there is a great short introduction video about it, you can watch it here:

<div align="center">
{{< twitter user="davepl1968" id="2055402203133997328">}}
</div>

Most people visualize allocation as something like this:

You call `char* buffer = (char*)malloc(1);` and you get:

<div align="center">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 760 140" width="100%" style="max-width:760px;height:auto" font-family="Noto, sans-serif" font-size="13" fill="currentColor">
<defs><marker id="ahmm1" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>
<rect x="140" y="20" width="160" height="44" fill="currentColor" fill-opacity="0.03" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<text x="220.0" y="47" text-anchor="middle" fill-opacity="0.5">…</text>
<rect x="300" y="20" width="160" height="44" fill="currentColor" fill-opacity="0.16" stroke="currentColor" stroke-width="1.2"/>
<text x="380.0" y="47" text-anchor="middle" font-weight="600">memory block, size 1</text>
<rect x="460" y="20" width="160" height="44" fill="currentColor" fill-opacity="0.03" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<text x="540.0" y="47" text-anchor="middle" fill-opacity="0.5">…</text>
<polyline points="300,112 300,67" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahmm1)"/>
<text x="312" y="116"><tspan font-family="'Noto Sans Mono', monospace">buffer</tspan>, exactly 1 byte long</text>
</svg>
</div>

But actually it looks like this:

<div align="center">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 760 200" width="100%" style="max-width:760px;height:auto" font-family="Noto, sans-serif" font-size="13" fill="currentColor">
<defs><marker id="ahmm2" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>
<rect x="40" y="20" width="90" height="44" fill="currentColor" fill-opacity="0.03" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<text x="85.0" y="47" text-anchor="middle" fill-opacity="0.5">…</text>
<rect x="130" y="20" width="150" height="44" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2"/>
<text x="205.0" y="47" text-anchor="middle">memory header</text>
<rect x="280" y="20" width="220" height="44" fill="currentColor" fill-opacity="0.16" stroke="currentColor" stroke-width="1.2"/>
<text x="390.0" y="47" text-anchor="middle" font-weight="600">your memory block</text>
<rect x="500" y="20" width="150" height="44" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2"/>
<text x="575.0" y="47" text-anchor="middle">memory footer</text>
<rect x="650" y="20" width="70" height="44" fill="currentColor" fill-opacity="0.03" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<text x="685.0" y="47" text-anchor="middle" fill-opacity="0.5">…</text>
<polyline points="280,118 280,67" fill="none" stroke="currentColor" stroke-width="1.2" marker-end="url(#ahmm2)"/>
<text x="292" y="100"><tspan font-family="'Noto Sans Mono', monospace">malloc(size)</tspan> returns a pointer to here,</text>
<text x="292" y="117">and the block is usually larger than the size you asked for</text>
<line x1="130" y1="64" x2="130" y2="150" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<line x1="650" y1="64" x2="650" y2="150" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<polyline points="130,142 130,150 650,150 650,142" fill="none" stroke="currentColor" stroke-width="1.2"/>
<line x1="390" y1="150" x2="390" y2="160" stroke="currentColor" stroke-width="1.2"/>
<text x="390" y="178" text-anchor="middle">memory block the allocator actually allocated</text>
</svg>
</div>

Memory header and footer are usually allocator metadata which is used for allocator operations, optionally some memory tracking, and some mechanism to detect memory errors. Memory footer is not common unless allocator has some memory corruption detection mechanisms.

Memory header is usually where `malloc` stores the size of the block in order for `free(ptr)` to work. The allocator knew how much memory it handed out, the caller knew how much it asked for, but `free` gets only the pointer, so the allocator has to write the size down somewhere, usually in a header in front of the block, and find it again later. `std::allocator` passes the size back, but the rest is the same: an allocation is a bare pointer, and everything else about it, how big it really is, how it's aligned, who allocated it, lives somewhere else.

In 2015 [Andrei Alexandrescu](https://erdani.org/) proposed a different contract: an allocation is not a pointer, it's a block, the pointer and the size together. The allocator returns the block, the caller keeps it, and hands it back when it's done. Once allocators speak in blocks they can be small, do one thing, and be composed into larger ones.

This post is about `bx::Blk`, an implementation of that idea taken further than the talk. The block also knows which allocator it came from, it can't be copied or freed twice by accident, when it's invalid it says why, and it describes GPU memory the same way it describes CPU memory. On top of it there is a set of composable allocators, allocation debugging, memory tracking and a general purpose heap.

## History of composable allocators

Composition came from C first. Kiem‑Phong Vo's [Vmalloc](https://manpages.opensuse.org/Tumbleweed/ksh-devel/vmalloc.3ast.en.html) (1996) splits an allocator into a method, how blocks are handed out (`Vmbest`, `Vmpool`, `Vmlast`), and a discipline, where raw memory comes from (`Vmdcsystem` for `mmap`, `sbrk` or Win32). Any method works with any discipline, and debugging is just another method: `Vmdebug` checks for overruns and double frees, `Vmprofile` records usage.

Emery Berger, Benjamin Zorn and Kathryn McKinley's [Heap Layers](https://github.com/emeryberger/Heap-Layers) (PLDI 2001) brought it to C++. Each layer is a template that inherits from the layer below, and an allocator is a stack of layers. Composed allocators matched hand‑written ones, and Hoard and DieHard are built from it. The same year Andrei Alexandrescu's *Modern C++ Design* introduced policy‑based design, the mechanism his allocators would use fourteen years later, and Loki's small object allocator.

Also in 2001, Jeff Bonwick and Jonathan Adams added [magazines and vmem](https://www.usenix.org/legacy/event/usenix01/full_papers/bonwick/bonwick.pdf) to the Solaris slab allocator. Magazines are per‑CPU caches of free blocks. Vmem allocates arbitrary resources, ranges of integers, so it never touches what it manages.

Game developers kept running into the limits of `std::allocator`. Paul Pedriana's [N2271](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2007/n2271.html) (2007) says `std::allocator` was the largest reason EA wrote EASTL.

### Alexandrescu's talk

Alexandrescu presented composable allocators at CppCon 2015, in the "std::allocator Is to Allocation what std::vector Is to Vexation" talk:

<div align="center">
<iframe width="640" height="480" src="https://www.youtube.com/embed/LIb3L4vKZ7U" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
</div>

In the talk he introduces two main ideas:

 - Allocation returns `Blk { void* ptr; size_t length; }`. The allocator says how much it gave, the caller keeps it and hands it back, and the allocator doesn't have to store the size.

 - Allocators are small parts with the same interface, `allocate`, `deallocate`, `expand`, `reallocate` and `owns`, put together with templates. `FallbackAllocator<Primary, Fallback>` asks `Primary::owns` to decide who frees a block. `Segregator` splits by size, `Bucketizer` makes size classes, `AffixAllocator` adds a prefix or suffix for metadata, and `StatsCollector` counts.

Alexandrescu implemented the whole thing in D as [std.experimental.allocator](https://dlang.org/phobos/std_experimental_allocator.html), released with D 2.069 in November 2015, where a block is a `void[]` slice. It is the most complete implementation of the talk, and it is still in `experimental`.

In C++ there are [AllocatorBuilder](https://github.com/FelixPetriconi/AllocatorBuilder), [allocators](https://github.com/lukaszlaszko/allocators) and [KTL](https://github.com/KredeGC/KTL), which reproduce the building blocks from the talk, and [foonathan/memory](https://foonathan.net/2016/11/memory-0.6/), which passes `memory_block` between allocator layers and hands users plain pointers. The standard took one piece: [`allocate_at_least`](https://wg21.link/p0401) in C++23 returns `{ ptr, count }`.

On the GPU side, AMD's [Vulkan Memory Allocator](https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/virtual_allocator.html) and [D3D12 Memory Allocator](https://github.com/GPUOpen-LibrariesAndSDKs/D3D12MemoryAllocator) have virtual blocks, and Sebastian Aaltonen's [OffsetAllocator](https://github.com/sebbbi/OffsetAllocator) is TLSF for offsets. They hand out offsets into memory the CPU can't touch and keep metadata outside of it, each with its own API, separate from how the same program allocates CPU memory.

## bx::Blk

The `Blk` from the talk is two fields, `struct Blk { void* ptr; size_t length; }`, and it's a plain value. `bx::Blk` keeps the idea, the caller holds the block and hands it back, and changes almost everything else about it.

### Layout

```cpp
struct Blk                            // 24 bytes, 64-bit layout
{
    uint64_t ptr;                     // pointer, or offset into GPU memory

    uint64_t size            : 40;    // size of block, up to 1TiB
    uint64_t log2Alignment   :  5;    // alignment of block
    uint64_t cpuAccessible   :  1;    // can CPU read and write this memory?
    uint64_t allocatorOp     :  3;    // what the last operation did
    uint64_t allocatorHandle :  8;    // which allocator returned the block

    uint32_t bookKeeping;             // private data of the allocator
    uint16_t slotIndex;               // routing inside of composed allocator
    uint16_t unused0;

    uint32_t locationIdx;             // only with memory tracking, 32 bytes
    uint32_t unused1;
};
```

<div align="center">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 760 226" width="100%" style="max-width:760px;height:auto" font-family="Noto, sans-serif" font-size="13" fill="currentColor">
<text x="620" y="14" text-anchor="middle" font-size="11" fill-opacity="0.75">only with memory tracking</text>
<text x="50" y="67" text-anchor="end" font-size="11" fill-opacity="0.75">bytes</text>
<text x="50" y="157" text-anchor="end" font-size="11" fill-opacity="0.75">bits</text>
<text x="60" y="33" text-anchor="middle" font-size="11" fill-opacity="0.75">0</text>
<text x="220" y="33" text-anchor="middle" font-size="11" fill-opacity="0.75">8</text>
<text x="380" y="33" text-anchor="middle" font-size="11" fill-opacity="0.75">16</text>
<text x="460" y="33" text-anchor="middle" font-size="11" fill-opacity="0.75">20</text>
<text x="500" y="33" text-anchor="middle" font-size="11" fill-opacity="0.75">22</text>
<text x="540" y="33" text-anchor="middle" font-size="11" fill-opacity="0.75">24</text>
<text x="620" y="33" text-anchor="middle" font-size="11" fill-opacity="0.75">28</text>
<text x="700" y="33" text-anchor="middle" font-size="11" fill-opacity="0.75">32</text>
<rect x="60" y="40" width="160" height="44" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2"/>
<text x="140" y="67" text-anchor="middle">ptr</text>
<rect x="220" y="40" width="160" height="44" fill="currentColor" fill-opacity="0.16" stroke="currentColor" stroke-width="1.2"/>
<text x="300" y="67" text-anchor="middle" font-weight="600">bit fields</text>
<rect x="380" y="40" width="80" height="44" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2"/>
<text x="420" y="67" text-anchor="middle" font-size="12">bookKeeping</text>
<rect x="460" y="40" width="40" height="44" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2"/>
<text x="480" y="60" text-anchor="middle" font-size="11">slot</text>
<text x="480" y="73" text-anchor="middle" font-size="11">Index</text>
<rect x="500" y="40" width="40" height="44" fill="currentColor" fill-opacity="0.03" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<text x="520" y="67" text-anchor="middle" font-size="11" fill-opacity="0.6">unused</text>
<rect x="540" y="40" width="80" height="44" fill="currentColor" fill-opacity="0.03" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<text x="580" y="67" text-anchor="middle" font-size="12" fill-opacity="0.6">locationIdx</text>
<rect x="620" y="40" width="80" height="44" fill="currentColor" fill-opacity="0.03" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<text x="660" y="67" text-anchor="middle" font-size="11" fill-opacity="0.6">unused</text>
<line x1="220" y1="84" x2="60" y2="130" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<line x1="380" y1="84" x2="700" y2="130" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<rect x="60" y="130" width="400" height="44" fill="currentColor" fill-opacity="0.16" stroke="currentColor" stroke-width="1.2"/>
<text x="260" y="157" text-anchor="middle" font-weight="600">size : 40</text>
<rect x="460" y="130" width="50" height="44" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2"/>
<text x="485" y="157" text-anchor="middle">5</text>
<rect x="510" y="130" width="10" height="44" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2"/>
<rect x="520" y="130" width="30" height="44" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2"/>
<text x="535" y="157" text-anchor="middle">3</text>
<rect x="550" y="130" width="80" height="44" fill="currentColor" fill-opacity="0.06" stroke="currentColor" stroke-width="1.2"/>
<text x="590" y="157" text-anchor="middle">8</text>
<rect x="630" y="130" width="70" height="44" fill="currentColor" fill-opacity="0.03" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.35" stroke-dasharray="4 4"/>
<text x="665" y="157" text-anchor="middle" font-size="11" fill-opacity="0.6">unused</text>
<line x1="485" y1="174" x2="485" y2="184" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.5"/>
<text x="506" y="197" text-anchor="end" font-size="12">log2Alignment</text>
<line x1="590" y1="174" x2="590" y2="184" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.5"/>
<text x="544" y="197" font-size="12">allocatorHandle</text>
<line x1="515" y1="174" x2="515" y2="204" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.5"/>
<text x="521" y="217" text-anchor="end" font-size="12">cpuAccessible : 1</text>
<line x1="535" y1="174" x2="535" y2="204" stroke="currentColor" stroke-width="1.2" stroke-opacity="0.5"/>
<text x="529" y="217" font-size="12">allocatorOp</text>
</svg>
</div>

What the fields are for, compared to pointer and length in the talk:

 - `ptr` is 64 bits on every platform, including 32‑bit ones, because it's not always a pointer. For GPU memory it's an offset.

 - `size` is the size the allocator actually gave, which can be more than what was asked for.

 - `log2Alignment` is there because alignment is something the caller knows at allocation, and has to repeat on every resize and free. Now it's in the block.

 - `allocatorOp` says what happened to the block last: no‑operation, alias, allocate, free, grow, realign, or truncate. There is one entry point, `realloc(blk, size, alignment)`, and the caller can tell if the block grew in place or moved.

 - `allocatorHandle` is the allocator the block came from.

 - `bookKeeping` and `slotIndex` belong to allocators. Metadata that an allocator would write into a header in front of the memory can live in the block, which matters when the memory is on the GPU and there is nowhere to write the header.

### Unique pointer without automatic release

This is the largest change in behavior. In the talk a block is a plain struct, and nothing stops this:

```cpp
Blk a = allocator.allocate(100);
Blk b = a;               // copy of metadata
allocator.deallocate(a);
allocator.deallocate(b); // double free, and `b` looked completely valid
```

The same happens when a block is resized and the old copy is kept around, the old copy has the wrong pointer or the wrong size, and it's the caller's job to never use it.

`bx::Blk` behaves like `std::unique_ptr`, there is always only one owner of the block:

 - It can't be copied, only moved, and moving invalidates the source.

 - Every function that changes a block takes it as `Blk&&` and returns the result. The block that went in is invalid when the function returns. If a resize fails, the original block is what comes back, marked as no‑operation.

 - It's `[[nodiscard]]`, the result can't be dropped on the floor.

In code:

```cpp
bx::Blk blk = bx::alloc(allocator, 100);
blk = bx::realloc(bx::move(blk), 200); // old block is gone, there is only
                                       // the new one
blk = bx::free(bx::move(blk) );        // `blk` is now invalid, reason: freed

bx::Blk copy = blk;                    // doesn't compile
bx::free(blk);                         // doesn't compile
```

Unlike `std::unique_ptr`, `Blk` doesn't free memory when it goes out of scope. Allocation and release stay explicit, there are no frees hidden behind a closing brace, and without a destructor `Blk` is trivially relocatable, 24 bytes that containers and allocators can move around with `memcpy`. What `unique_ptr` gives for free at scope exit is done by containers that own a block: `ArrayT`, `HashMapT`, `UniquePtrT`.

Forgetting to free is caught another way. With memory tracking turned on, `Blk` gets a destructor that doesn't free, it asserts if the block that's going away still owns memory, and reports where that block was allocated. A leak is reported at the place where the block is lost, not as a list of leaked pointers at exit.

When more than one piece of code needs to look at the same block, the copy has to be asked for: `Blk(Copy, blk)` makes a non‑owning alias. It's marked as `AllocatorOp::Alias`, it can't be resized or freed, and it's not counted as a leak.

Memory tracking changes the size of `Blk`, so `Blk` lives in an inline namespace named after `BX_CONFIG_MEMORY_TRACKING`. Code built with tracking and code built without it doesn't link, instead of crashing at runtime.

### The block knows its allocator

In the talk the allocator is not part of the block. The caller has to remember which allocator a block came from, and composed allocators find the owner by asking each part `owns(blk)`.

`bx::Blk` carries an 8‑bit handle of the allocator that returned it. `free(blk)` and `realloc(blk, ...)` don't take an allocator argument, there is no header in front of the memory, and no lookup by address.

The handle is 8 bits because it has to fit into the block next to the size and alignment, and that makes 256 handles. A handle is an index into a table of allocators, so getting from a block to its allocator is one read from an array. Allocators get a handle when they're created, and handle 0 is the process default, which is the heap until it's set to something else with `setDefaultAllocatorBlk`.

256 sounds small, but handles are for allocators, not for allocations, and a program has few allocators. The whole bx heap takes about 12. The limit is also on allocators that are alive at the same time, not on how many are created: when an allocator is destroyed its handle is released, and released handles are reused in turn. Running out of handles is an assert, and code that creates and destroys allocators all the time should reset them instead.

Reuse of handles is why an allocator has to outlive every block it returned. A block that is still around after its allocator is gone carries a handle that sooner or later belongs to another allocator. With memory tracking, destroying an allocator that has live blocks is an assert.

Some allocators are never destroyed, they live as long as the process. Those can be marked with `setAllocatorPermanent`, and a permanent handle is never given to another allocator. That handle means the same allocator for as long as the process runs, so the pointer to the allocator can be cached instead of looked up. The heap marks its own allocators as permanent. The default handle is not permanent, because it can be pointed at another allocator.

Containers get smaller because of it. They take a one byte `AllocatorHandle` instead of an allocator pointer, and `ArrayT` or `UniquePtrT` store nothing but their `Blk`.

### Invalid blocks say why

A null pointer says that something failed. An invalid `Blk` says what: allocation failed, no block large enough (but smaller ones are available), resize failed, realign failed, not supported, or the block was freed. A block that was freed is distinguishable from one that was never allocated.

### One entry point

The allocator interface in the talk has `allocate`, `deallocate`, `reallocate` and `expand`. A bx allocator has one function, `realloc(blk, size, alignment)`. An invalid block going in is an allocation, size 0 is a free, anything else is a resize, and `allocatorOp` in the block that comes back says which one happened.

The functions users call are built on top of it, and each comes in three forms:

 - `tryAlloc`, `tryRealloc` report failure through `Error*`, and the caller has to deal with it.

 - `alloc`, `realloc`, `free` stop on failure.

 - `Unchecked` variants skip the checks, for hot paths where the caller guarantees the preconditions.

Not all code can hold a 24 byte block. For code that can only keep a pointer there are `allocPtr`, `reallocPtr`, `freePtr` and `BX_NEW_PTR`/`deletePtr`, which store the `Blk` in a header in front of the pointer. It's what `malloc` does, but only where it's asked for.

Block allocators and old pointer based `AllocatorI` can't be confused. Passing one where the other is expected doesn't compile.

### Allocators

Allocators are plain classes without virtual functions, composed with templates, so the calls between the parts inline. The parts:

 - **Memory sources.** [`SystemMemoryAllocator`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L918-L919) takes pages from the operating system. [`PageReserveAllocator`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L965-L971) reserves address space for each block and commits pages as the block grows, so the block grows in place and never moves. [`FixedCapacityAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L97-L103) hands out one block from inline storage.

 - **Managing a region.** [`FirstFitAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L262-L268), [`BitArrayAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L375-L386) and [`TwoLevelSegregatedFitAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L758-L764) (TLSF) for general use. [`FrameRingAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L461-L470) for transient per‑frame allocations with multiple frames in flight, [`DoubleEndedStackAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L574-L581) for a stack that grows from both ends.

 - **Composition.** [`ThresholdAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L188-L196) sends blocks up to a size to one allocator and the rest to another, it's the segregator from the talk. [`OverflowAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L141-L147) uses the secondary allocator when the primary is out of memory, the talk's fallback. [`MoreCoreAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L1332-L1338) takes memory from the secondary and adds it to the primary instead.

 - **Threads.** [`MutexAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L1402-L1407) puts a lock around any allocator. [`ThreadLocalAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L1462-L1472) gives each thread its own instance, and blocks can be freed on any thread. [`ThreadCacheAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L1563-L1576) adds a per‑thread cache of small blocks, with Bonwick's magazines.

 - **Sensitive data.** [`SecureAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L50-L55) wraps any allocator and clears the memory of freed and resized blocks, so keys and passwords don't stay behind in memory that was given back.

 - **Adapters.** [`ImplementAllocatorBlkInterfaceT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk.h#L782-L787) puts any of them behind the virtual [`AllocatorBlkI`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk.h#L363-L365) when a block allocator has to cross an API boundary, and [`IntrusiveBlkAllocatorT`](https://github.com/bkaradzic/bx/blob/93ab098066e57718fb80acc1987a48ccf91df392/include/bx/blk-allocators.h#L1128-L1133) exposes a block allocator as the old pointer based `AllocatorI`.

First fit and TLSF don't own the memory they manage. Memory is added to them and removed from them as slabs (`addSlab`, `removeUnusedSlab`), and that is the same interface whether the slab is RAM or a GPU heap.

### CPU and GPU memory

In the talk a block is CPU memory, `void*`, and allocators are free to write into memory they manage. In `bx::Blk` the `cpuAccessible` bit says if `ptr` can be dereferenced. When it can't, `ptr` is an offset, allocators keep all metadata outside of the memory, and debug features that touch memory are skipped.

That's all it takes for the same allocators and the same composition to work on both. TLSF, first fit, or frame ring sub‑allocate a GPU heap the same way they sub‑allocate RAM. bgfx does exactly this:

 - D3D12 and Vulkan renderers have one `TwoLevelSegregatedFitAllocatorT` per kind of memory. Each `ID3D12Heap` or `VkDeviceMemory` is added as a slab the CPU can't access, with the index of the heap in the upper bits of `ptr`. Heaps that are no longer used are removed and given back to the driver.

 - Dynamic vertex and index buffers are ranges of a larger GPU buffer, handed out by `FirstFitAllocatorT`, not TLSF. It's a different allocator behind the same slab interface, each GPU buffer is added as a slab.

This is how a `VkDeviceMemory` goes in and an allocation comes out in bgfx's Vulkan renderer, simplified:

```cpp
// Device memory is added as a slab. Index of the slab is in the upper 32 bits
// of `ptr`, and the block is marked as not accessible by the CPU.
allocator.addSlab(
      bx::Blk(uint64_t(slabIdx + 1) << 32
    , size
    , 0
    , false
    , bx::AllocatorOp::Allocate
    ) );

// Allocation is a block. Which device memory, and the offset into it,
// are both in `ptr`.
bx::Blk blk = allocator.alloc(requirements.size, requirements.alignment);

const uint16_t slabIdx = uint16_t( (blk.ptr >> 32) - 1);
const uint32_t offset  = uint32_t(blk.ptr);
```

Nothing is written into the device memory, what TLSF needs to free the block later is in the block's `bookKeeping`.

### Memory tracking and debugging

With `BX_CONFIG_MEMORY_TRACKING` every allocation records where in the source it was made. The location is a defaulted argument of `alloc`, like `std::source_location`, so there are no macros at call sites. Each location keeps the number of live blocks and bytes, their peaks, the number of operations, and the call stack of the first allocation from it, and all locations can be enumerated at any time. The block points to its location, which is how the leak assert in `~Blk` knows what to report. With tracking compiled out `Blk` goes back to 24 bytes with no destructor.

Debugging tools are allocators too, and they're added by composition, around any allocator and at any level:

 - `StatsAllocatorT` counts bytes, blocks and operations, and is thread safe.

 - `DebugClearAllocatorT` fills new memory with `0xcd` and freed memory with `0xdd`.

 - `DebugStompAllocator` places each block against a guard page, after the block to catch overruns or before it to catch underruns, so out of bounds access and use after free trap at the instruction that did it (see [Memory Stomp Allocator](https://web.archive.org/web/20251020214341/https://irradiance.ca/posts/stomp/)).

### General purpose heap from the same parts

`bx::malloc`, `realloc`, `alignedAlloc`, `free` and `usableSize` run on a heap composed from the same block allocators. It's a test of the whole idea: if composition from blocks had a cost, this is where it would show.

The heap has three modes, picked with `setHeap`:

 - **Throughput.** Threads own their pages.

 - **Footprint.** Threads share pages, and thread caches are bounded.

 - **Balanced**, the default. Blocks up to 8KiB come from pages owned by the thread, larger ones from shared pages.

Where the heap gets its memory from is also an allocator, set with `setHeapUpstream`.

## Performance

All bx results below are from the balanced heap, which is the default. The throughput and footprint modes are not represented.

### mimalloc‑bench

[mimalloc‑bench](https://github.com/daanx/mimalloc-bench) is the benchmark that matters the most, because it's based on reality. It runs real, familiar open source programs, redis, rocksdb, lean, espresso, cfrac, a Linux kernel build, next to the allocator stress tests, with each allocator loaded as the `malloc` of the process.

For each test an allocator gets the best result divided by its own, and the score is the geometric mean over all tests times 100, so 100 means the best on every test. Overall is time and memory weighted equally:

| allocator | time | memory | overall |
|:--|--:|--:|--:|
| mimalloc 1.8.2 | 90.0 | 82.0 | 85.9 |
| snmalloc 0.7.6 | 90.0 | 69.8 | 79.2 |
| **bx** | **83.9** | **74.7** | **79.2** |
| rpmalloc 2.0.1 | 82.9 | 70.9 | 76.7 |
| mimalloc 2.1.2 | 84.5 | 68.1 | 75.9 |
| glibc 2.39 | 61.4 | 81.2 | 70.6 |
| jemalloc 5.4.0 | 77.1 | 61.7 | 69.0 |
| mimalloc 3.6.0 | 87.2 | 45.8 | 63.2 |
| tcmalloc (gperftools 2.18) | 67.1 | 55.7 | 61.1 |

bx is in the leading group. It's 1.37x faster than glibc, about 7% behind mimalloc 1.8 and snmalloc, about even with mimalloc 2 and 3 and rpmalloc, and ahead of jemalloc and tcmalloc. Only glibc and mimalloc 1.8 use less memory overall. It ties for the fastest on the kernel build, and trails the most on small block churn, where sh6bench is about 2x behind the fastest.

### rpmalloc‑benchmark

[rpmalloc‑benchmark](https://github.com/mjansson/rpmalloc-benchmark) is synthetic. Threads do nothing but allocate and free blocks of random sizes, and hand some of them to other threads to free. A program that only allocates doesn't exist, so the differences it shows are much larger than what a real program would see, and it should be read as a stress test of the allocator and not as a prediction. It's useful for comparing against platform allocators, because it runs everywhere. Three ranges of block sizes at 1, 4 and 8 threads:

| platform | platform allocator | bx is faster by |
|:--|:--|--:|
| Windows, Ryzen 9 7950X | Windows heap | 1.6–54x |
| Linux, i9‑9900K | glibc 2.39 | 2.6–4.7x |
| macOS, Apple M4 | libmalloc | 3.1–9.1x |
| iPhone 16e, A18 | libmalloc | 4.2–8.5x |
| iPhone 17 Pro Max, A19 Pro | libmalloc | 3.6–15x |
| Pixel 9a, Tensor G4 | Scudo | 3.9–77x |

Peak memory is close to even, except on Linux where glibc uses 4–14% less. Against the other allocators on Windows, scored the same way as above, bx gets 90.5 for speed and 86.8 for memory, rpmalloc 75.5 and 70.7, mimalloc 60.0 and 83.7, snmalloc 57.0 and 79.8, tcmalloc 48.8 and 69.5.

### GPU sub‑allocation

bx allocators against [Vulkan Memory Allocator](https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator) and [D3D12 Memory Allocator](https://github.com/GPUOpen-LibrariesAndSDKs/D3D12MemoryAllocator), both as virtual blocks over a 256MiB virtual heap, with three workloads: churn of live blocks, transient blocks of one frame, and three frames in flight. For 256 allocations and 256 frees of each, bx TLSF, the one bgfx uses, takes 25.6µs in total, VMA 32.1µs and D3D12MA 31.4µs.

## Conclusion

Blocks are not new, composable allocators are not new, and neither is any single allocator described here. Blocks with a size come from Alexandrescu's talk, composition from Vmalloc and Heap Layers, and TLSF, magazines and GPU sub‑allocators all existed before. What is **novel** is what `bx::Blk` does with the block. As far as I know, no other implementation makes the block the single owner of its memory, puts the allocator into the block, or manages CPU and GPU memory with the same blocks and the same allocators, and none has built a general purpose `malloc` replacement out of blocks.

None of this is paid for with performance. On real programs the general purpose heap composed from these parts is in the same group as allocators that do nothing else, and 1.37x faster than glibc.

It's not an experiment. It landed in [bx](https://github.com/bkaradzic/bx/pull/501), and bgfx's D3D12 and Vulkan renderers sub‑allocate GPU memory with the same allocators.

## References

 - Andrei Alexandrescu, std::allocator Is to Allocation what std::vector Is to Vexation, CppCon 2015.  
   https://web.archive.org/web/20151016001552/https://www.youtube.com/watch?v=LIb3L4vKZ7U

 - Emery Berger, Benjamin Zorn, Kathryn McKinley, Composing High-Performance Memory Allocators, PLDI 2001.  
   https://web.archive.org/web/20260105020355/https://people.cs.umass.edu/~emery/pubs/berger-pldi2001.pdf

 - Jeff Bonwick, Jonathan Adams, Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources, USENIX 2001.  
   https://web.archive.org/web/20160523065206/https://www.usenix.org/legacy/event/usenix01/full_papers/bonwick/bonwick.pdf

 - Miguel Masmano et al., TLSF: a New Dynamic Memory Allocator for Real-Time Systems, ECRTS 2004.  
   https://web.archive.org/web/20230512151610/http://www.gii.upv.es/tlsf/files/ecrts04_tlsf.pdf

## Further reading

 - Memory Allocation  
   https://web.archive.org/web/20231127094923/https://samwho.dev/memory-allocation/

 - Storing data in pointers  
   https://web.archive.org/web/20231127202929/https://muxup.com/2023q4/storing-data-in-pointers

 - Visual overview of a custom malloc() implementation  
   https://web.archive.org/web/20240206233435/https://silent-tower.net/projects/visual-overview-malloc

 - How much memory does a call to ‘malloc’ allocates?  
   https://web.archive.org/web/20240627234824/https://lemire.me/blog/2024/06/27/how-much-memory-does-a-call-to-malloc-allocates/

 - A look at how malloc works on the Mac  
   https://web.archive.org/web/20231209160855/https://www.cocoawithlove.com/2010/05/look-at-how-malloc-works-on-mac.html

 - Memory Management Reference  
   https://web.archive.org/web/20180106220126/https://www.memorymanagement.org/index.html

 - Writing a Memory Allocator  
   https://web.archive.org/web/20191118033431/http://dmitrysoshnikov.com/compilers/writing-a-memory-allocator/

 - On programming without malloc  
   https://web.archive.org/web/20131204182051/https://jvns.ca/blog/2013/12/03/day-36-programming-without-malloc/

 - Memory Corruption: Finding and Fixing Elusive Crashes  
   https://web.archive.org/web/20201108133942/https://www.unrealengine.com/en-US/blog/memory-corruption-finding-and-fixing-elusive-crashes

 - Memory Stomp Allocator  
   https://web.archive.org/web/20251020214341/https://irradiance.ca/posts/stomp/

 - Writing Your Own Memory Allocators in C++  
   https://web.archive.org/web/20240522015807/https://screwjankgames.github.io/engine%20programming/2020/09/24/writing-your-own-memory-allocators.html

 - The Arena - Custom Memory Allocators in C  
   https://web.archive.org/web/20240423030055/https://www.bytesbeneath.com/p/the-arena-custom-memory-allocators

 - malloc() from Scratch  
   https://web.archive.org/web/20251124060603/https://medium.com/@tenzinmigmar/malloc-from-scratch-dbc1bc23dfde

 - Memory Allocation Strategies, series of 6 articles  
   https://web.archive.org/web/20260711111540/https://www.gingerbill.org/series/memory-allocation-strategies/
