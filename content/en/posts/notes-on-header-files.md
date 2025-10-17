---
title: Notes on header files
date: 2017-02-14
---

This article was originally published as a gist [here](https://gist.github.com/bkaradzic/6e5d447233137eeabaf240211aeb490c).

After over 20 years working with C/C++ I finally got clear idea how header files need to be organized. Most of the projects in C++ world simply dump everything in .h file, and most of my C++ code was organized this way. Lately I started to separate function declaration from implementation as it was done in C. Now `.h` headers are exclusevely intended for function and class declaration with doxygen documentation style comments. Inline implementation of functions, class method implementation, etc. goes into `.inl` headers or `.cpp` files.

For example `.h` file would contain only declaration and doxygen style documentation comment:

```cpp
	/// Convert size in bytes to human readable string.
	void prettify(char* _out, int32_t _max, uint64_t _value)
```

Implementation if it's in `.inl` file would prefix function with `inline`:

```cpp
	inline void prettify(char* _out, int32_t _max, uint64_t _value)
	{
		...
	}
```

Or if it's in `.cpp` file function would be implemented without `inline`:

```cpp
	void prettify(char* _out, int32_t _max, uint64_t _value)
	{
		...
	}
```

This solves multiple issues. Immediately obvious one is that functions are trivially transferable between .inl and .cpp file with minimum modification, adding or removing `inline` keyword. Non-obvious part is that functions now can be declared in any order in `.h` file, it can be sorted by name, or grouped by some other logic, which improves documentation. You won't need to move whole functions around in some unnatural way just because functionA calls functionB. Documentation for functions is located in one place, it's easy to glance since function is one to a few lines of code. The only downside of this approach is that there is two places where function signature exist, which in case of inline functions wasn't the case.

Anyhow, it's not some huge discovery, rather notes since it's not common practice in C++ world.
