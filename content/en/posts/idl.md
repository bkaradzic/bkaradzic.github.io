---
title: bgfx is switching to IDL to generate API
date: 2019-04-08
toc: false
---

This article was originally published as a gist [here](https://gist.github.com/bkaradzic/05a1c86a6dd57bf86e2d828878e88dc2).

bgfx main API is using basic C++ that looks like C, but it's C++ enough that can't be used directly in C projects. C is important as it provides ability to bind API to other languages, and also as sanity check for API design.

Every time API changes manual process of process for adding/changing API for C99 bindings was changing header declarations of function and function type for interface virtual table (I'll use [`bgfx::createVertexBuffer`](https://bkaradzic.github.io/bgfx/bgfx.html#_CPPv2N4bgfx18createVertexBufferEPK6MemoryRK10VertexDecl8uint16_t) function as an example):
```cpp
/* ... bunch of funcs ... */

/**/
BGFX_C_API bgfx_vertex_buffer_handle_t bgfx_create_vertex_buffer(
	  const bgfx_memory_t* _mem
	, const bgfx_vertex_decl_t* _decl
	, uint16_t _flags
	);

/* ... bunch of funcs ... */

/**/
typedef struct bgfx_interface_vtbl
{
     /* ... bunch of funcs ... */
     
	bgfx_vertex_buffer_handle_t (*create_vertex_buffer)(
		  const bgfx_memory_t* _mem
		, const bgfx_vertex_decl_t* _decl
		, uint16_t _flags
		);
    
     /* ... bunch of funcs ... */
     
} bgfx_interface_vtbl_t;
```

And then adding/changing function definition, and call table:

```cpp
/* ... bunch of funcs ... */

BGFX_C_API bgfx_vertex_buffer_handle_t bgfx_create_vertex_buffer(
	  const bgfx_memory_t* _mem
	, const bgfx_vertex_decl_t* _decl
	, uint16_t _flags
	)
{
	const bgfx::VertexDecl& decl = *(const bgfx::VertexDecl*)_decl;
	union { bgfx_vertex_buffer_handle_t c; bgfx::VertexBufferHandle cpp; } handle;
	handle.cpp = bgfx::createVertexBuffer( (const bgfx::Memory*)_mem, decl, _flags);
	return handle.c;
}

/* ... bunch of funcs ... */

BGFX_C_API bgfx_interface_vtbl_t* bgfx_get_interface(uint32_t _version)
{
	if (_version == BGFX_API_VERSION)
	{
#define BGFX_IMPORT                            \
    /* ... bunch of funcs ... */               \
	BGFX_IMPORT_FUNC(create_vertex_buffer) \
    /* ... bunch of funcs ... */
    
    static bgfx_interface_vtbl_t s_bgfx_interface =
		{
#define BGFX_IMPORT_FUNC(_name) BX_CONCATENATE(bgfx_, _name),
			BGFX_IMPORT
#undef BGFX_IMPORT_FUNC
		};

		return &s_bgfx_interface;
	}

	return NULL;
}
```

That's two definitions, one implementation, and one list of functions available. As you can imagine this process of adding boilerplate code is not that fun, and often I forget to update something somewhere, or even expose certain API to C99. 

Idea with `bgfx_interface_vtbl_t` is that user can import single shared library function `bgfx_get_interface`, call it with version of bgfx API header used and get whole API. I call it [COM](https://en.wikipedia.org/wiki/Component_Object_Model) without GUIDs.

The most common approach when creating shared library is just to add dllimport/export (and GCC equivalents) attributes to their functions, and rely on linker magic to generate shim library for them, then they link the library and that's it. It's simple, but it this way of linking shared library causes issues with missing/corrupted shared library, and versioning. The main issue is that users of application are presented with generic fatal message "The dynamic library <filename>.dll failed to load." And solution for that issue is to load library manually and add some versioning mechanism. OpenGL API wrappers like GLEW, GLAD, and million other ones are good example of how loading shared library manually would look like with so many functions. Where on other side D3D COM interface shows simpler approach for loading shared library (lack of D3D loaders can attest that), but with some other baggage attached to it. My solution with loading shared library is to go COM-lite route. This approach solves two issues, loading shared library manually becomes trivial, and it provides versioning mechanism, but it doesn't bring any of other COM issues.

In case of any errors, for example not being to load shared library or version mismatch, application author can provide more information to user how to solve the problem, where the most common way of automatic linking/loading shared libraries would just show fatal error when running executable with generic dialog saying: "The dynamic library <filename>.dll failed to load."

But this single function returning interface causes issue where bgfx API is not anymore the same for C99, and it doesn't even exist for C++. In order to solve this a shim for shared library would need to be created that deals with loading shared library and obtaining interface. Creating shim would reverse problem because in shim I would need to go from C interface to C++ API, and all C functions would be just wrappers for interface. That would be 2 declarations, 3 implementations (static C99 to C++, shared library C++ to interface, and shared lib C99 to interface), and one list of functions available. At that point I decided that brute forcing manually is not way to go, and rather some [Interface Definition Language](https://en.wikipedia.org/wiki/Interface_description_language) needs to be used.

IDL is more like concept, and there is nothing like standard, or readily available tool to deal with it (or at least I didn't find anything). Even if you're unfamiliar with IDL, you probably at some point ran into headers and code generated from IDL. For example D3D headers, or Vulkan headers (example of IDL for [vkCreateBuffer](https://github.com/KhronosGroup/Vulkan-Docs/blob/8cc971fb3e1c25afb949cdc49d6a6de63f19c5c6/xml/vk.xml#L5336-L5342)). I attempted to generate headers by putting IDL into JSON tables, and use Go to generate headers. But the process was slow and I wasn't satisfied with it's feel.

I ran into serialization library project by [云风 @cloudwu](https://github.com/cloudwu) that could be used for IDL, but once I asked about it [云风 @cloudwu](https://github.com/cloudwu) thought his library is not appropriate for this use, but then he came up with very neat Lua DSL to describe IDL. After bunch of feedback and back and forth, IDL description for `bgfx::createVertexBuffer` function now looks like:

```lua
--- Create static vertex buffer.
func.createVertexBuffer
	"VertexBufferHandle"        --- Static vertex buffer handle.
	.mem   "const Memory*"      --- Vertex buffer data.
	.decl  "const VertexDecl &" --- Vertex declaration.
	.flags "uint16_t"           --- Buffer creation flags.
	                            ---  - `BGFX_BUFFER_NONE` - No flags.
	                            ---  - `BGFX_BUFFER_COMPUTE_READ` - Buffer will be read from by compute shader.
	                            ---  - `BGFX_BUFFER_COMPUTE_WRITE` - Buffer will be written into by compute shader. When buffer
	                            ---      is created with `BGFX_BUFFER_COMPUTE_WRITE` flag it cannot be updated from CPU.
	                            ---  - `BGFX_BUFFER_COMPUTE_READ_WRITE` - Buffer will be used for read/write by compute shader.
	                            ---  - `BGFX_BUFFER_ALLOW_RESIZE` - Buffer will resize on buffer update if a different amount of
	                            ---      data is passed. If this flag is not specified, and more data is passed on update, the buffer
	                            ---      will be trimmed to fit the existing buffer size. This flag has effect only on dynamic buffers.
	                            ---  - `BGFX_BUFFER_INDEX32` - Buffer is using 32-bit indices. This flag has effect only on index buffers.
```
All features needed to generate C++ and C99 headers are there (right now only C99 header is generated), function signature, default values, Doxygen comments, C99 alternative names, etc. Whole bgfx API is already described by IDL (scripts/bgfx.idl), and you can see how it looks here: https://github.com/bkaradzic/bgfx/blob/10e8a15ba1a13803e5152905be7bf53a5774e3d6/scripts/bgfx.idl#L901-L915

Once we have this definition we can generate (some of these are not ready yet, but it's WIP):

 - public headers for C++ and C99, including doxygen comments for both
 - C++ to C99 translation wrapper
 - shims for shared libraries (C++ to C99 interface wrapper, and C99 to C99 interface wrapper)
 - bgfx debug replay capture interface

Other potential IDL usage is to allow user to configure IDL to output bgfx API in their desired code style. bgfx C++ style for example function is `bgfx::createVertexBuffer`, C99 style is `bgfx_create_vertex_buffer`, but I can see that maybe someone would like to match bgfx with their code style and call it `bgfx::CreateVertexBuffer`, `bgfxCreateVertexBuffer`, or something along those lines. This kind of customization becomes trivial with IDL code generation. Another potential usage is versioning API functions and generating simple translation wrapper to convert old API to new one, in case maintaining backward compatibility between API functions is required.

Overall switch to IDL was a lot of work, but it simplifies maintenance and versioning in long run, and it opens some new options for users of bgfx from other languages. Since IDL scripts are in Lua, it nicely fits with [GENie project generator](https://github.com/bkaradzic/GENie#genie---project-generator-tool) used by bgfx, also demonstrates how extendable is [GENie](https://github.com/bkaradzic/GENie#genie---project-generator-tool) due use of Lua for scripting.
