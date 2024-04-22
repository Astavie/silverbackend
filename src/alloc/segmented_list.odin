package alloc

import "base:builtin"
import "base:intrinsics"
import "core:mem"

// where math.is_power_of_two(P)
Segmented_List :: struct($T: typeid, $P: int) where P & (P-1) == 0 {
	_prealloc: [P]T,
	_shelves: [][^]T,
	len: int,
}

@(private)
_log2_inc :: proc(x: int) -> int {
	return size_of(int) * 8 - intrinsics.count_leading_zeros(x)
}

@(private)
_log2_floor :: proc(x: int) -> int {
	return _log2_inc(x) - 1
}

@(private)
_log2_ceil :: proc(x: int) -> int {
	return _log2_inc(x - 1)
}

at :: proc(list: ^Segmented_List($T, $P), idx: int) -> ^T {
	if idx < P {
		return &list._prealloc[idx]
	} else if P == 0 {
		shelf_index := _log2_floor(idx + 1)
		box_index := idx + 1 - (1 << uint(shelf_index))
		return &list._shelves[shelf_index][box_index]
	} else {
		log_p := intrinsics.count_trailing_zeros(P)
		shelf_index := _log2_floor(idx + P) - log_p - 1
		box_index := idx + P - (1 << uint(log_p + 1 + shelf_index))
		return &list._shelves[shelf_index][box_index]
	}
}

grow_capacity :: proc(list: ^Segmented_List($T, $P), new_capacity: int, loc := #caller_location) -> mem.Allocator_Error {
	shelf_count: int
	if P == 0 {
		shelf_count = _log2_ceil(new_capacity + 1)
	} else {
		shelf_count = _log2_ceil(new_capacity + P) - intrinsics.count_trailing_zeros(P) - 1
	}
	if shelf_count <= len(list._shelves) do return nil

	new_array := mem.make_slice([][^]T, shelf_count, context.allocator, loc) or_return

	i := 0
	for ; i < len(list._shelves); i += 1 {
		new_array[i] = list._shelves[i]
	}

	err: mem.Allocator_Error = .None
	defer if err != .None {
		for ; i > len(list._shelves); i -= 1 {
			free(new_array[i], context.allocator, loc)
		}
		builtin.delete(new_array, context.allocator, loc)
	}

	for ; i < shelf_count; i += 1 {
		shelf_size: int
		if P == 0 {
			shelf_size = 1 << uint(i)
		} else {
			shelf_size = P * (1 << uint(i + 1))
		}

		array: []T
		array, err = mem.make_slice([]T, shelf_size, context.allocator, loc)
		if err != .None do return err

		new_array[i] = &array[0]
	}

	builtin.delete(list._shelves, context.allocator, loc)
	list._shelves = new_array
	return nil
}

append :: proc(list: ^Segmented_List($T, $P), elem: T, loc := #caller_location) -> mem.Allocator_Error {
	grow_capacity(list, list.len + 1) or_return
	at(list, list.len)^ = elem
	list.len += 1
	return .None
}

delete :: proc(list: Segmented_List($T, $P), loc := #caller_location) {
	for i := 0; i < len(list._shelves); i += 1 {
		free(list._shelves[i], context.allocator, loc)
	}
	builtin.delete(list._shelves, context.allocator, loc)
}
