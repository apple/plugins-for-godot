//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc.
//
// Licensed under the MIT license (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// LICENSE
//
//===----------------------------------------------------------------------===//

#ifndef UTILITY_H
#define UTILITY_H

#import "Foundation/Foundation.h"
#import "Metal/Metal.h"

#undef MAX
#undef check
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/local_vector.hpp>

#include "scene_tree.h"
#include <iostream>
#include <tuple>

#define UNIT_SPAN(x) { &x, 1 }
#define VECTOR_SPAN(x) { x.ptr(), x.size() }
#define ARRAY_SPAN(x) { x, sizeof(x) / sizeof(x[0]) }

// These are intended to be used to print warnings when the gdrk plugin
// detects a case it can't represent in RealityKit
#if !defined(SUPPRESS_COMPAT_WARNINGS)
#define WARN_COMPAT_COND(cond)                                             \
	if (cond) {                                                            \
		WARN_PRINT("GodotRealityKit: Uncompatible with condition " #cond); \
	}

#define WARN_COMPAT_MSG(msg) \
	WARN_PRINT(godot::String("GodotRealityKit: {0}").format(godot::Array{ msg }));
#else
#define WARN_COMPAT_COND(cond)
#define WARN_COMPAT_MSG(msg)
#endif // !defined(SUPPRESS_COMPAT_WARNINGS)

namespace gdrk {

namespace detail {
template <typename T>
struct defer : T {
	defer(T g) :
			T(g) {}
	~defer() { T::operator()(); }
};
} // namespace detail

NSBundle *get_gdrk_bundle();

// Swift interop objects don't support assignment; destroy in place and re-construct.
template <typename T, typename... Args>
static void emplace_replace(T *ptr, const Args &...args) {
	ptr->~T();
	new (ptr) T(args...);
}

static inline godot::RenderingServer *rendering_server() {
	return godot::RenderingServer::get_singleton();
}

static inline godot::RenderingDevice *rendering_device() {
	return rendering_server()->get_rendering_device();
}

static inline id<MTLCommandQueue> get_metal_command_queue(godot::RenderingDevice *device = rendering_device()) {
	const uint64_t command_queue_u64 = device->get_driver_resource(godot::RenderingDevice::DRIVER_RESOURCE_COMMAND_QUEUE, godot::RID(), 0);
	return (__bridge id<MTLCommandQueue>)(void *)command_queue_u64;
}

static inline id<MTLDevice> get_metal_device(godot::RenderingDevice *device = rendering_device()) {
	const uint64_t device_u64 = device->get_driver_resource(godot::RenderingDevice::DRIVER_RESOURCE_LOGICAL_DEVICE, godot::RID(), 0);
	return (__bridge id<MTLDevice>)(void *)device_u64;
}

static inline RealitySceneTree *get_scene_tree() {
	godot::Engine *engine = godot::Engine::get_singleton();

	godot::MainLoop *main_loop = engine->get_main_loop();
	RealitySceneTree *scene_tree = godot::Object::cast_to<RealitySceneTree>(main_loop);
	ERR_FAIL_NULL_V(scene_tree, nullptr);

	return scene_tree;
}

static inline godot::Node *get_node_instance(uint64_t p_node_id) {
	godot::Object *node_obj = godot::ObjectDB::get_instance(p_node_id);
	return godot::Object::cast_to<godot::Node>(node_obj);
}

// A dynamically sized bitset
class LocalBitVector {
public:
	_FORCE_INLINE_ uint32_t size() const {
		return blocks.size() * bits_per_block;
	}

	_FORCE_INLINE_ uint32_t count() const {
		uint32_t res = 0;
		for (uint32_t subblock_idx = 0; subblock_idx < subblock_count(); subblock_idx++) {
			res += std::popcount(subblock(subblock_idx));
		}

		return res;
	}

	_FORCE_INLINE_ bool has(uint32_t p_key) const {
		if (p_key >= subblock_count() * bits_per_subblock) [[unlikely]] {
			return false;
		}

		const uint32_t subblock_idx = p_key / bits_per_subblock;
		const uint32_t subblock_key = p_key % bits_per_subblock;
		return subblock(subblock_idx) & (subblock_type(0x1) << subblock_key);
	}

	_FORCE_INLINE_ void insert(uint32_t p_key) {
		const uint32_t subblock_idx = p_key / bits_per_subblock;
		const uint32_t subblock_key = p_key % bits_per_subblock;
		subblock(subblock_idx) |= (subblock_type(0x1) << subblock_key);
	}

	_FORCE_INLINE_ void remove(uint32_t p_key) {
		const uint32_t subblock_idx = p_key / bits_per_subblock;
		const uint32_t subblock_key = p_key % bits_per_subblock;
		subblock(subblock_idx) &= ~(subblock_type(0x1) << subblock_key);
	}

	_FORCE_INLINE_ void clear() {
		if (!blocks.is_empty()) {
			std::memset(&blocks[0], 0, blocks.size() * sizeof(Block));
		}
	}

	_FORCE_INLINE_ void resize(uint32_t p_size) {
		if (p_size < blocks.size() * bits_per_block) {
			return;
		}

		blocks.resize((p_size + bits_per_block - 1) / bits_per_block);
	}

	template <std::invocable<uint32_t> Fn>
	void for_each(Fn &&fn) const {
		for (uint32_t subblock_idx = 0; subblock_idx < subblock_count(); subblock_idx++) {
			subblock_type temp = subblock(subblock_idx);
			const uint32_t subblock_key_base = subblock_idx * bits_per_subblock;
			while (temp != 0) {
				const uint32_t subblock_key = std::countr_zero(temp);
				fn(subblock_key_base + subblock_key);
				temp ^= subblock_type(0x1) << subblock_key;
			}
		}
	}

	template <std::invocable<uint32_t> Fn>
	bool for_each_n(Fn &&fn, uint32_t p_max_count, uint32_t &p_start_idx) const {
		uint32_t processed = 0;
		uint32_t start_subblock_idx = p_start_idx / bits_per_subblock;
		uint32_t start_subblock_key = p_start_idx % bits_per_subblock;

		for (uint32_t subblock_idx = start_subblock_idx; subblock_idx < subblock_count(); subblock_idx++) {
			subblock_type temp = subblock(subblock_idx);
			const uint32_t subblock_key_base = subblock_idx * bits_per_subblock;

			if (subblock_idx == start_subblock_idx && start_subblock_key > 0) {
				temp &= ~((subblock_type(0x1) << start_subblock_key) - 1);
			}

			while (temp != 0) {
				const uint32_t subblock_key = std::countr_zero(temp);
				if (processed >= p_max_count) {
					p_start_idx = subblock_key_base + subblock_key;
					return false;
				}
				fn(subblock_key_base + subblock_key);
				temp ^= subblock_type(0x1) << subblock_key;
				processed++;
			}
		}

		p_start_idx = size();
		return true;
	}

	void merge(const LocalBitVector &other) {
		const uint32_t min_subblock_count = std::min(subblock_count(), other.subblock_count());
		for (uint32_t subblock_idx = 0; subblock_idx < min_subblock_count; subblock_idx++) {
			subblock(subblock_idx) |= other.subblock(subblock_idx);
		}
	}

private:
	using subblock_type = uint64_t;
	static constexpr uint32_t subblocks_per_block = 1;
	static constexpr uint32_t bits_per_subblock = sizeof(subblock_type) * 8;
	static constexpr uint32_t bits_per_block = bits_per_subblock * subblocks_per_block;

	_FORCE_INLINE_ uint32_t subblock_count() const {
		return blocks.size() * subblocks_per_block;
	}

	_FORCE_INLINE_ subblock_type &subblock(uint32_t p_subblock_idx) {
		return reinterpret_cast<subblock_type *>(&blocks[0])[p_subblock_idx];
	}

	_FORCE_INLINE_ const subblock_type &subblock(uint32_t p_subblock_idx) const {
		return reinterpret_cast<const subblock_type *>(&blocks[0])[p_subblock_idx];
	}

	struct Block {
		std::array<subblock_type, subblocks_per_block> subblocks{};
	};

	godot::LocalVector<Block> blocks;
};

template <typename T>
class Span;

template <typename T, size_t N>
class alignas(8) SmallLocalVector {
	uint32_t _size = 0;
	uint32_t _capacity = 0;
	union {
		T *_heap_data = nullptr;
		alignas(T) uint8_t _stack_data[N * sizeof(T)];
	};

	constexpr static uint32_t HEADER_SIZE = sizeof(_size) + sizeof(_capacity);
	constexpr static uint32_t DATA_PADDING = godot::MAX(alignof(T), alignof(uint64_t)) - alignof(uint64_t);

public:
	_FORCE_INLINE_ SmallLocalVector() = default;
	_FORCE_INLINE_ SmallLocalVector(std::initializer_list<T> p_init) {
		reserve(p_init.size());
		for (const T &element : p_init) {
			memnew_placement(ptr() + _size++, T(element));
		}
	}

	_FORCE_INLINE_ explicit SmallLocalVector(Span<const T> p_span) {
		reserve(uint32_t(p_span.size()));
		if constexpr (std::is_trivially_copy_constructible_v<T>) {
			memcpy((void *)ptr(), p_span.ptr(), p_span.size() * sizeof(T));
			_size = uint32_t(p_span.size());
		} else {
			for (uint64_t i = 0; i < p_span.size(); i++) {
				memnew_placement(ptr() + _size++, T(p_span.ptr()[i]));
			}
		}
	}

	SmallLocalVector(const SmallLocalVector &p_from) {
		if (p_from._capacity > N) {
			_capacity = p_from._capacity;
			_heap_data = (T *)memrealloc((void *)_heap_data, _capacity * sizeof(T));
			CRASH_COND_MSG(!_heap_data, "Out of memory");
		}

		if constexpr (std::is_trivially_copy_constructible_v<T>) {
			_size = p_from._size;
			memcpy((void *)ptr(), p_from.ptr(), p_from.size() * sizeof(T));
		} else {
			for (const T &element : p_from) {
				memnew_placement(ptr() + _size++, T(element));
			}
		}
	}

	SmallLocalVector(SmallLocalVector &&p_from) {
		if (p_from._capacity > N) {
			memcpy((void *)&_size, (void *)&p_from._size, HEADER_SIZE + DATA_PADDING + sizeof(T *));
			memset((void *)&p_from._size, 0, HEADER_SIZE + DATA_PADDING + sizeof(T *));
		} else {
			if constexpr (std::is_trivially_move_constructible_v<T>) {
				memcpy((void *)&_size, (void *)&p_from._size, HEADER_SIZE + DATA_PADDING + p_from._size * sizeof(T));
				memset((void *)&p_from._size, 0, HEADER_SIZE + DATA_PADDING + p_from._size * sizeof(T));
			} else {
				for (T &&element : std::move(p_from)) {
					memnew_placement(ptr() + _size++, T(std::move(element)));
				}

				memset((void *)&p_from._size, 0, HEADER_SIZE);
			}
		}
	}

	_FORCE_INLINE_ ~SmallLocalVector() {
		if constexpr (!std::is_trivially_destructible_v<T>) {
			for (uint32_t i = 0; i < _size; i++) {
				ptr()[i].~T();
			}
		}

		if (_capacity > N) [[unlikely]] {
			memfree(_heap_data);
		}
	}

	void operator=(const SmallLocalVector &p_from) {
		resize(p_from.size());
		for (uint32_t i = 0; i < p_from.size(); i++) {
			ptr()[i] = p_from.ptr()[i];
		}
	}

	void operator=(SmallLocalVector &&p_from) {
		if (unlikely(this == &p_from)) {
			return;
		}

		reset();
		if (p_from._capacity > N) {
			memcpy((void *)&_size, (void *)&p_from._size, HEADER_SIZE + DATA_PADDING + sizeof(T *));
			memset((void *)&p_from._size, 0, HEADER_SIZE + DATA_PADDING + sizeof(T *));
		} else {
			if constexpr (std::is_trivially_move_assignable_v<T>) {
				memcpy((void *)&_size, (void *)&p_from._size, HEADER_SIZE + DATA_PADDING + p_from._size * sizeof(T));
				memset((void *)&p_from._size, 0, HEADER_SIZE + DATA_PADDING + p_from._size * sizeof(T));
			} else {
				resize(p_from._size);
				for (uint32_t i = 0; i < _size; i++) {
					ptr()[i] = std::move(p_from.ptr()[i]);
				}

				memset((void *)&p_from._size, 0, HEADER_SIZE);
			}
		}
	}

	_FORCE_INLINE_ T *ptr() {
		if (_capacity <= N) [[likely]] {
			return (T *)(_stack_data);
		} else {
			return _heap_data;
		}
	}

	_FORCE_INLINE_ const T *ptr() const {
		if (_capacity <= N) [[likely]] {
			return (const T *)(_stack_data);
		} else {
			return _heap_data;
		}
	}

	_FORCE_INLINE_ uint32_t size() const { return _size; }

	_FORCE_INLINE_ bool is_empty() const { return _size == 0; }
	_FORCE_INLINE_ uint32_t get_capacity() const { return _capacity; }

	void reserve(uint32_t p_size) {
		if (p_size <= N) {
			return;
		}

		const uint32_t old_capacity = _capacity;
		_capacity = godot::nearest_power_of_2_templated(p_size);
		if (old_capacity <= N) [[unlikely]] {
			T *heap_data = (T *)memalloc(_capacity * sizeof(T));
			CRASH_COND_MSG(!heap_data, "Out of memory");

			memcpy((void *)heap_data, _stack_data, _size * sizeof(T));
			_heap_data = heap_data;
		} else {
			_heap_data = (T *)memrealloc((void *)_heap_data, _capacity * sizeof(T));
			CRASH_COND_MSG(!_heap_data, "Out of memory");
		}
	}

	void resize(uint32_t p_size) {
		if (p_size < _size) {
			if constexpr (!std::is_trivially_destructible_v<T>) {
				for (uint32_t i = p_size; i < _size; i++) {
					ptr()[i].~T();
				}
			}
			_size = p_size;
		} else if (p_size > _size) {
			reserve(p_size);
			if constexpr (!std::is_trivially_constructible_v<T>) {
				for (uint32_t i = _size; i < p_size; i++) {
					memnew_placement(ptr() + i, T);
				}
			}
			_size = p_size;
		}
	}

	void reset() {
		if constexpr (!std::is_trivially_destructible_v<T>) {
			for (uint32_t i = 0; i < _size; i++) {
				ptr()[i].~T();
			}
		}

		if (_capacity > N) {
			memfree(_heap_data);
		}

		memset((void *)&_size, 0, HEADER_SIZE + DATA_PADDING + sizeof(T *));
	}

	_FORCE_INLINE_ const T &operator[](uint32_t p_index) const {
		CRASH_BAD_UNSIGNED_INDEX(p_index, _size);
		return ptr()[p_index];
	}
	_FORCE_INLINE_ T &operator[](uint32_t p_index) {
		CRASH_BAD_UNSIGNED_INDEX(p_index, _size);
		return ptr()[p_index];
	}

	struct Iterator {
		_FORCE_INLINE_ T &operator*() const {
			return *elem_ptr;
		}

		_FORCE_INLINE_ T *operator->() const { return elem_ptr; }
		_FORCE_INLINE_ Iterator &operator++() {
			elem_ptr++;
			return *this;
		}
		_FORCE_INLINE_ Iterator &operator--() {
			elem_ptr--;
			return *this;
		}

		_FORCE_INLINE_ bool operator==(const Iterator &b) const { return elem_ptr == b.elem_ptr; }
		_FORCE_INLINE_ bool operator!=(const Iterator &b) const { return elem_ptr != b.elem_ptr; }

		Iterator(T *p_ptr) { elem_ptr = p_ptr; }
		Iterator() {}
		Iterator(const Iterator &p_it) { elem_ptr = p_it.elem_ptr; }

	private:
		T *elem_ptr = nullptr;
	};

	struct ConstIterator {
		_FORCE_INLINE_ const T &operator*() const {
			return *elem_ptr;
		}
		_FORCE_INLINE_ const T *operator->() const { return elem_ptr; }
		_FORCE_INLINE_ ConstIterator &operator++() {
			elem_ptr++;
			return *this;
		}
		_FORCE_INLINE_ ConstIterator &operator--() {
			elem_ptr--;
			return *this;
		}

		_FORCE_INLINE_ bool operator==(const ConstIterator &b) const { return elem_ptr == b.elem_ptr; }
		_FORCE_INLINE_ bool operator!=(const ConstIterator &b) const { return elem_ptr != b.elem_ptr; }

		ConstIterator(const T *p_ptr) { elem_ptr = p_ptr; }
		ConstIterator() {}
		ConstIterator(const ConstIterator &p_it) { elem_ptr = p_it.elem_ptr; }

	private:
		const T *elem_ptr = nullptr;
	};

	_FORCE_INLINE_ Iterator begin() { return Iterator(ptr()); }
	_FORCE_INLINE_ Iterator end() { return Iterator(ptr() + size()); }

	_FORCE_INLINE_ ConstIterator begin() const { return ConstIterator(ptr()); }
	_FORCE_INLINE_ ConstIterator end() const { return ConstIterator(ptr() + size()); }

	_FORCE_INLINE_ void push_back(const T &p_element) {
		const uint32_t idx = _size++;
		reserve(_size);
		memnew_placement(ptr() + idx, T(p_element));
	}

private:
};

// Modified from templates/span.h in Godot, since godot-cpp doesn't include it
template <typename T>
class Span {
	const T *_ptr = nullptr;
	uint64_t _len = 0;

public:
	static constexpr bool is_string = std::disjunction_v<
			std::is_same<T, char>,
			std::is_same<T, char16_t>,
			std::is_same<T, char32_t>,
			std::is_same<T, wchar_t>>;

	_FORCE_INLINE_ constexpr Span() = default;

	_FORCE_INLINE_ Span(const T *p_ptr, uint64_t p_len) :
			_ptr(p_ptr), _len(p_len) {
	}

	// Allows creating Span directly from C arrays and string literals.
	template <size_t N>
	_FORCE_INLINE_ constexpr Span(const T (&p_array)[N]) :
			_ptr(p_array), _len(N) {
		if constexpr (is_string) {
			// Cut off the \0 terminator implicitly added to string literals.
			if (N > 0 && p_array[N - 1] == '\0') {
				_len--;
			}
		}
	}

	_FORCE_INLINE_ constexpr uint64_t size() const { return _len; }
	_FORCE_INLINE_ constexpr bool is_empty() const { return _len == 0; }

	_FORCE_INLINE_ constexpr const T *ptr() const { return _ptr; }

	// NOTE: Span subscripts validate the bounds to avoid undefined behavior.
	//       This is slower than direct buffer access and can prevent autovectorization.
	//       If the bounds are known, use ptr() subscript instead.
	_FORCE_INLINE_ constexpr const T &operator[](uint64_t p_idx) const {
		CRASH_COND(p_idx >= _len);
		return _ptr[p_idx];
	}

	_FORCE_INLINE_ constexpr const T *begin() const { return _ptr; }
	_FORCE_INLINE_ constexpr const T *end() const { return _ptr + _len; }
};

// Utility class for associating some data with a Godot RID outside of the RID_Owner
template <typename T>
class RID_Associated {
public:
	_FORCE_INLINE_ void reserve(uint32_t p_capacity) {
		data.reserve(p_capacity);
		validators.reserve(p_capacity);
	}

	_FORCE_INLINE_ T get(godot::RID p_key) const {
		CRASH_COND(validators[index(p_key)] != validator(p_key));
		return data[index(p_key)];
	}

	_FORCE_INLINE_ bool has(godot::RID p_key) const {
		const uint32_t idx = index(p_key);
		return idx < data.size() && validators[idx] == validator(p_key);
	}

	_FORCE_INLINE_ void insert(godot::RID p_key, T p_value) {
		const uint32_t idx = index(p_key);
		if (idx >= data.size()) [[unlikely]] {
			data.resize(idx + 1);

			const uint32_t prev_size = validators.size();
			validators.resize(idx + 1);
			memset(validators.ptr() + prev_size, 0, (idx - prev_size + 1) * sizeof(uint32_t));
		}

		validators[idx] = validator(p_key);
		data[idx] = p_value;
	}

	_FORCE_INLINE_ void remove(godot::RID p_key) {
		const uint32_t idx = index(p_key);
		if (idx < data.size() && validators[idx] == validator(p_key)) [[likely]] {
			validators[idx] = 0;
		}
	}

	_FORCE_INLINE_ bool overlaps(godot::RID p_key) const {
		const uint32_t idx = index(p_key);
		return idx < validators.size() && validators[idx] != 0;
	}

	_FORCE_INLINE_ godot::RID overlapping(godot::RID p_key) const {
		ERR_FAIL_COND_V(!overlaps(p_key), godot::RID());
		const uint64_t idx = index(p_key);
		const uint64_t id = idx | (uint64_t(validators[idx]) << 32);

		godot::RID res;
		std::memcpy(&res, &id, sizeof(id));
		return res;
	}

private:
	_FORCE_INLINE_ static uint32_t index(godot::RID p_rid) {
		return p_rid.get_id() & 0xFFFFFFFF;
	}

	_FORCE_INLINE_ static uint32_t validator(godot::RID p_rid) {
		return (p_rid.get_id() >> 32) & 0x7FFFFFFF;
	}

	godot::LocalVector<T> data;
	godot::LocalVector<uint32_t> validators;
};

template <typename F>
	requires std::is_enum_v<F>
struct Flag {};

template <std::derived_from<godot::Object> O, typename T>
struct ObjectProperty {
	using type = T;
	_FORCE_INLINE_ T get(const O *p_object) const { return (p_object->*getter)(); }
	T (O::*getter)() const;
};

template <std::derived_from<godot::Object> O, typename F>
	requires std::is_enum_v<F>
struct ObjectProperty<O, Flag<F>> {
	using type = bool;
	_FORCE_INLINE_ bool get(const O *p_object) const { return (p_object->*getter)(flag); }
	bool (O::*getter)(F) const;
	F flag;
};

template <std::derived_from<godot::Object> O, typename T>
static ObjectProperty<O, T> make_object_property(T (O::*p_getter)() const) {
	return ObjectProperty<O, T>{
		.getter = p_getter
	};
}

template <std::derived_from<godot::Object> O, std::derived_from<godot::Object> B, typename T>
static ObjectProperty<O, T> make_object_property(T (B::*p_getter)() const) {
	return ObjectProperty<O, T>{
		.getter = static_cast<T (O::*)() const>(p_getter)
	};
}

template <std::derived_from<godot::Object> O, typename T>
static ObjectProperty<O, T> make_object_property(T (O::*p_getter)()) {
	return ObjectProperty<O, T>{
		.getter = reinterpret_cast<T (O::*)() const>(p_getter)
	};
}

template <std::derived_from<godot::Object> O, typename F>
	requires std::is_enum_v<F>
static ObjectProperty<O, Flag<F>> make_object_property(bool (O::*p_getter)(F) const, F p_flag) {
	return ObjectProperty<O, Flag<F>>{
		.getter = p_getter,
		.flag = p_flag
	};
}

template <std::derived_from<godot::Object> O, typename... Ts>
class ObjectPropertyHasher;

template <typename T>
static uint32_t hash_object_property_value(const T &p_value) {
	using PtrToArg = godot::PtrToArg<T>;
	typename PtrToArg::EncodeT value;
	PtrToArg::encode(p_value, &value);
	return godot::Variant(value).hash();
}

// PtrToArg::encode expects engine-owned return storage, not a local uninitialized
// Ref. Hashing the Ref directly keeps its ownership intact and avoids a crash
// while loading or updating the label.
template <typename T>
static uint32_t hash_object_property_value(const godot::Ref<T> &p_value) {
	return godot::HashMapHasherDefault::hash(p_value);
}

template <std::derived_from<godot::Object> O, typename T>
class ObjectPropertyHasher<O, T> {
public:
	ObjectPropertyHasher(const ObjectProperty<O, T> &p_property) :
			property(p_property) {}

	uint32_t hash(const O *p_object, uint32_t p_state = HASH_MURMUR3_SEED) const {
		const uint32_t hash = hash_object_property_value(property.get(p_object));
		return godot::hash_murmur3_one_32(hash, p_state);
	}

private:
	ObjectProperty<O, T> property;
};

template <std::derived_from<godot::Object> O, typename T, typename... Ts>
class ObjectPropertyHasher<O, T, Ts...> : ObjectPropertyHasher<O, Ts...> {
public:
	ObjectPropertyHasher(const ObjectProperty<O, T> &p_property, const ObjectProperty<O, Ts> &...p_properties) :
			ObjectPropertyHasher<O, Ts...>(p_properties...),
			property(p_property) {}

	uint32_t hash(const O *p_object, uint32_t p_state = HASH_MURMUR3_SEED) const {
		const uint32_t hash = hash_object_property_value(property.get(p_object));
		const uint32_t hash_acc = godot::hash_murmur3_one_32(hash, p_state);
		return ObjectPropertyHasher<O, Ts...>::hash(p_object, hash_acc);
	}

private:
	ObjectProperty<O, T> property;
};

template <std::derived_from<godot::Object> O, typename... Ts>
static ObjectPropertyHasher<O, Ts...> make_object_property_hasher(const ObjectProperty<O, Ts> &...p_properties) {
	return ObjectPropertyHasher<O, Ts...>(p_properties...);
}

template <std::invocable<> T>
struct StaticInitializer {
	StaticInitializer(T &&p_init) { p_init(); }
};

template <typename Tuple, typename Fn>
void for_each_loader(Tuple &p_set, Fn &&p_fn) {
	std::apply([&](auto &...loaders) { (p_fn(loaders), ...); }, p_set);
}

} // namespace gdrk

// Define an initialization black that runs when the library is loads. This should
// not be used in header files. Use STATIC_INIT_NAMED when multiple are needed, though
// you probably can combine them together in one
#define STATIC_INIT_NAMED(name, content)                                 \
	namespace init {                                                     \
	namespace name {                                                     \
	namespace {                                                          \
	class StaticInitializer {                                            \
		static StaticInitializer instance;                               \
		StaticInitializer() { content }                                  \
	};                                                                   \
	StaticInitializer StaticInitializer::instance = StaticInitializer(); \
	}                                                                    \
	}                                                                    \
	}

#define STATIC_INIT(content) STATIC_INIT_NAMED(main, content)

// Defines a function table for the each element of the enum, that maps to the template
// function specialized by that enum value. This allows to bridge a runtime value to a statically
// defined function by just indexing in that table:
// Ex:
//		enum Alphabet {
// 			A = 0, // must start at 0
// 			B,
// 			C,
//			LETTER_COUNT
// 		}
// 		template<Alphabet A>
// 		void print() { print("Letter" << ('A' + A)); }
// 		// Specialize for any value:
// 		template<Alphabet C>
// 		void print() { print("This is a C"); }
// 		DEFINE_ENUM_FUNCTION_TABLE(my_print_table, Alphabet, LETTER_COUNT, print)
//		Usage:
//			void print(Alphabet val) {
//				my_print_table[val]();
//			}
#define DEFINE_ENUM_FUNCTION_TABLE(table_name, enum, max_value, template_function_name)                \
	static decltype(&template_function_name<enum ::max_value>) table_name[enum ::max_value];           \
	namespace init {                                                                                   \
	namespace initialize_table_##table_name {                                                          \
		template <std::size_t... Values>                                                               \
		void initialize(std::index_sequence<Values...>) {                                              \
			((table_name[Values] = template_function_name<static_cast<enum>(Values)>), ...);           \
		}                                                                                              \
	}                                                                                                  \
	}                                                                                                  \
	STATIC_INIT_NAMED(initialize_table_##table_name, {                                                 \
		init::initialize_table_##table_name::initialize(std::make_index_sequence<enum ::max_value>{}); \
	});

// Place this in a class to allow introspection while testing.
#if TESTING_ENABLED
namespace gdrk {
namespace testing {
class Observer;
}
} //namespace gdrk
#define TESTABLE() friend class gdrk::testing::Observer;
#else
#define TESTABLE()
#endif

#endif // UTILITY_H
