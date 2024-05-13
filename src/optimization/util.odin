package optimization

import sb "../graph"
import "base:intrinsics"
import "core:math/big"
import "core:slice"

do_nodes_alias :: proc(a: sb.Node, b: sb.Node) -> bool {

	check :: proc(
		a: sb.Node,
		b: sb.Node,
		type: sb.Node_Type,
	) -> (
		found: sb.Node,
		other: sb.Node,
		ok: bool,
	) {
		if sb.node_type(a) == type do return a, b, true
		if sb.node_type(b) == type do return b, a, true
		return a, b, false
	}

	if found, other, ok := check(a, b, .Merge); ok {
		if ancestor, ok := simple_memory_parent(found).?; ok {
			// check every merge case
			for input, i in sb.node_inputs(found) {
				current := sb.canonical_edge(input).node
				for {
					if current == ancestor do break
					if do_nodes_alias(current, other) {
						return true
					}

					// this merge node has a common ancestor for each case,
					// so we know each case must always have parents
					current = simple_memory_parent(current).?
				}
			}
			return false
		} else {
			return true
		}
	}

	if found, other, ok := check(a, b, .End); ok {
		// check if other is a Store to a Local
		if sb.node_type(other) == .Store {
			ptr := sb.node_inputs(other)[1]
			return !is_ptr_local(ptr)
		}
	}

	if found, other, ok := check(a, b, .Store); ok {
		// check if other is a Store to the same pointer at a different offset
		if sb.node_type(other) == .Store {
			ptr_a := sb.node_inputs(found)[1]
			ptr_b := sb.node_inputs(other)[1]
			origin_a, offset_a := simple_ptr_offset(ptr_a)
			origin_b, offset_b := simple_ptr_offset(ptr_b)
			if origin_a == origin_b && offset_a != offset_b {
				// TODO: take partially overlapping pointers into accouht
				return false
			}
		}
	}

	return true
}

is_ptr_local :: proc(a: sb.Node_Edge) -> bool {
	return sb.node_type(simple_ptr_origin(a).node) == .Local
}

simple_ptr_offset :: proc(n: sb.Node_Edge) -> (sb.Node_Edge, u32) {
	offset := u32(0)
	current := n
	for {
		#partial switch sb.node_type(current.node) {
		case .Member_Access:
			offset += sb.node_data(current.node).member_access.offset
			current = sb.node_parent(current.node, 0)
		case .Array_Access:
			// TODO: check if array access is constant
			return current, offset
		case:
			return current, offset
		}
	}
}

simple_ptr_parent :: proc(n: sb.Node_Edge) -> Maybe(sb.Node_Edge) {
	#partial switch sb.node_type(n.node) {
	case .Member_Access, .Array_Access:
		return sb.node_parent(n.node, 0)
	}
	return nil
}

simple_ptr_origin :: proc(n: sb.Node_Edge) -> sb.Node_Edge {
	current := n
	for {
		if parent, ok := simple_ptr_parent(current).?; ok {
			current = parent
		} else {
			return current
		}
	}
}

simple_memory_parent :: proc(n: sb.Node) -> Maybe(sb.Node) {
	#partial switch sb.node_type(n) {
	case .End, .Syscall, .Store, .Load:
		return sb.node_parent(n, 0).node
	case .Merge:
		inputs := sb.node_inputs(n)
		ancestor := sb.canonical_edge(inputs[0]).node
		for i in 1 ..< len(inputs) {
			if a, ok := simple_memory_ancestor(ancestor, sb.canonical_edge(inputs[i]).node).?; ok {
				ancestor = a
			} else {
				return nil
			}
		}
		return sb.canonical_edge({ancestor, 0}).node
	}
	return nil
}

simple_memory_ancestor :: proc(a: sb.Node, b: sb.Node) -> Maybe(sb.Node) {
	a_ancestors := make(map[sb.Node]struct {})
	defer delete(a_ancestors)

	// insert all ancestors inside map
	current := a
	for {
		a_ancestors[current] = {}
		if parent, ok := simple_memory_parent(current).?; ok {
			current = parent
		} else {
			break
		}
	}

	// get closest ancestor
	current = b
	for {
		if current in a_ancestors {
			return current
		} else if parent, ok := simple_memory_parent(current).?; ok {
			current = parent
		} else {
			return nil
		}
	}
}

// assumes the intervals are sorted by interval start!
get_overlapping_by :: proc(
	intervals: ^[]$T,
	interval: proc(t: T) -> ($K, K),
) -> (
	overlapping: []T,
	ok: bool,
) where intrinsics.type_is_ordered(K) {
	if len(intervals^) == 0 {
		ok = false
		return
	}

	_, end := interval(intervals[0])

	next := 1
	for next < len(intervals^) {
		start_next, end_next := interval(intervals[next])
		if start_next > end do break

		end = end_next
		next += 1
	}

	overlapping = intervals[:next]
	ok = true

	intervals^ = intervals[next:]
	return
}

big_bitfield_or :: proc(a: ^big.Int, offset, count: int, value: big._WORD) -> big.Error {

	big.int_grow(a, offset + count) or_return

	limb := offset / big._DIGIT_BITS
	bits_left := count
	bits_offset := offset % big._DIGIT_BITS

	num_bits := min(bits_left, big._DIGIT_BITS - bits_offset)

	shift := offset % big._DIGIT_BITS
	mask := (big._WORD(1) << uint(num_bits)) - 1

	a.digit[limb] |= big.DIGIT((value & mask) << uint(shift))

	bits_left -= num_bits
	if bits_left == 0 do return nil

	res_shift := num_bits
	num_bits = min(bits_left, big._DIGIT_BITS)
	mask = (1 << uint(num_bits)) - 1

	a.digit[limb + 1] |= big.DIGIT((value & mask) >> uint(res_shift))

	bits_left -= num_bits
	if bits_left == 0 do return nil

	mask = (1 << uint(bits_left)) - 1
	res_shift += big._DIGIT_BITS

	a.digit[limb + 2] |= big.DIGIT((value & mask) >> uint(res_shift))

	return nil
}
