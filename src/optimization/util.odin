package optimization

import sb "../graph"
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
			ptr := sb.node_inputs(other)[1].node
			return !is_ptr_local(ptr)
		}
	}

	if found, other, ok := check(a, b, .Store); ok {
		// check if other is a Store to the same pointer at a different offset
		if sb.node_type(other) == .Store {
			ptr_a := sb.node_inputs(found)[1].node
			ptr_b := sb.node_inputs(other)[1].node
			origin := simple_ptr_origin(ptr_a)
			if origin == simple_ptr_origin(ptr_b) {
				offset_a := simple_ptr_offset(ptr_a, origin)
				offset_b := simple_ptr_offset(ptr_b, origin)

				// TODO: take overlapping pointers into accouht
				if offset_a != nil && offset_b != nil && offset_a != offset_b {
					return false
				}
			}
		}
	}

	return true
}

is_ptr_local :: proc(a: sb.Node) -> bool {
	return sb.node_type(simple_ptr_origin(a)) == .Local
}

simple_ptr_offset :: proc(n: sb.Node, origin: sb.Node) -> Maybe(u32) {
	offset := u32(0)
	current := n
	for {
		if current == origin {
			return offset
		}
		#partial switch sb.node_type(n) {
		case .Member_Access:
			offset += sb.node_data(current).member_access.offset
			current = sb.node_parent(current, 0).node
		case .Array_Access:
			// TODO
			return nil
		case:
			return nil
		}
	}
}

simple_ptr_parent :: proc(n: sb.Node) -> Maybe(sb.Node) {
	#partial switch sb.node_type(n) {
	case .Member_Access, .Array_Access:
		return sb.node_parent(n, 0).node
	}
	return nil
}

simple_ptr_origin :: proc(n: sb.Node) -> sb.Node {
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

populate_int_buffer :: proc(
	buf: ^[dynamic]u16,
	data: ^sb.Node_Data,
	buf_offset: u16,
) -> big.Error {
	size := sb.type_size(data.integer.int_type)
	resize(buf, int(buf_offset + size))

	char_bits := sb.graph().target.char_bits
	bit_mask: i32 = (1 << char_bits) - 1

	current := int(buf_offset)

	if data.integer.int_big != nil {
		num := data.integer.int_big
		for !(big.is_zero(num) or_return) {
			defer current += 1
			buf[current] = u16(big.int_bitfield_extract(num, 0, int(char_bits)) or_return)
			big.int_shr(num, num, int(char_bits)) or_return
		}
	} else {
		// FIXME: I don't think this works with negative ints yet
		num := data.integer.int_literal
		for num != 0 {
			defer current += 1
			buf[current] = u16(num & bit_mask)
			num = num >> char_bits
		}
	}

	return .Okay
}
