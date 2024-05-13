package optimization

import sb "../graph"
import "core:math"
import "core:math/big"
import "core:mem"
import "core:slice"

// GLOBAL PASSES

perform_remove_dead :: proc() {
	g := sb.graph()

	// Find all nodes that are ancestors of End nodes
	// These do not include Start, End, or Pass nodes
	ancestors := make(map[sb.Node]struct {})
	defer delete(ancestors)

	add_ancestors :: proc(ancestors: ^map[sb.Node]struct {}, node: sb.Node) {
		inputs := sb.node_inputs(node)
		for i := 0; i < len(inputs); i += 1 {
			// reparent to canonical parents
			inputs[i] = sb.node_parent(node, i)
			parent := inputs[i].node

			if !(parent in ancestors) {
				ancestors[parent] = {}
				add_ancestors(ancestors, parent)
			}
		}
	}

	for function in g.functions {
		add_ancestors(&ancestors, function.end)
	}

	// Remove all non-ancestors
	for i := 0; i < len(g.nodes); i += 1 {
		#partial switch g.nodes[i].base.type {
		case .Start, .End: // do nothing
		case .Pass:
			// we reparented everything to their canonical parents
			// so all pass nodes can be removed
			varargs := g.nodes[i].pass.varargs
			if varargs > 0 {
				sb.node_destroy(g.nodes[i])
				g.nodes[i] = sb.node_nil()
			}
		case:
			if !(sb.Node(i) in ancestors) {
				sb.node_destroy(g.nodes[i])
				g.nodes[i] = sb.node_nil()
			}
		}
	}
}

// PER-NODE PASSES

perform_pass :: proc(pass: #type proc(n: sb.Node)) {
	for i := 0; i < len(sb.graph().nodes); i += 1 {
		if sb.node_type(sb.Node(i)) != .Pass {
			pass(sb.Node(i))
		}
	}
}

pass_optimize_merge :: proc(n: sb.Node) {
	// perform on Merge nodes
	#partial switch sb.node_type(n) {
	case .Merge:
	case:
		return
	}

	edges := make(map[sb.Node_Edge]struct {})
	defer delete(edges)

	inputs := sb.node_inputs(n)
	length := len(inputs)

	for i := len(inputs) - 1; i >= 0; i -= 1 {
		input := sb.canonical_edge(inputs[i])
		if input in edges {
			// this is a duplicate, swap it out
			length -= 1
			slice.swap(inputs, i, length)
		} else {
			edges[input] = {}
		}
	}

	if length < len(inputs) {
		data := sb.node_data(n)
		data.merge.varargs = u32(length)
	}

	if length == 1 {
		// change type of node to Pass 
		// this is allowed because Merge and Pass have the same structure
		data := sb.node_data(n)
		data.merge.type = .Pass
	}
}

pass_merge_stores :: proc(n: sb.Node) {
	// perform on Memory Merge nodes
	#partial switch sb.node_type(n) {
	case .Merge:
		if sb.node_output_type(n, 0) != sb.type_memory() do return
	case:
		return
	}

	ConstantStore :: struct {
		merge_input: u32,
		ptr_offset:  u32,
		int_value:   ^sb.Node_Data,
	}

	// map from "ptr origin" -> "constant stores"
	stores := make(map[sb.Node_Edge][dynamic]ConstantStore)
	defer delete(stores)

	for inputp, i in sb.node_inputs(n) {

		// check if input is a store
		input := sb.canonical_edge(inputp)
		if sb.node_type(input.node) != .Store do continue

		// check if input value is a constant integer
		value := sb.node_parent(input.node, 2)
		if sb.node_type(value.node) != .Integer do continue

		// get pointer origin
		ptr := sb.node_parent(input.node, 1)
		origin, offset := simple_ptr_offset(ptr)

		// add to the map
		if !(origin in stores) {
			stores[origin] = make([dynamic]ConstantStore)
		}
		append(
			&stores[origin],
			ConstantStore {
				merge_input = u32(i),
				ptr_offset = offset,
				int_value = sb.node_data(value.node),
			},
		)
	}

	char_bits := sb.graph().target.char_bits

	for origin, constants in stores {
		defer delete(constants)
		if len(constants) == 1 do continue

		store_interval :: proc(c: ConstantStore) -> (u32, u32) {
			return c.ptr_offset, c.ptr_offset + u32(sb.type_size(c.int_value.integer.int_type))
		}

		// iterate over overlapping segments
		constants_slice := constants[:]
		slice.sort_by_key(constants_slice, proc(c: ConstantStore) -> u32 {return c.ptr_offset})
		for overlapping in get_overlapping_by(&constants_slice, store_interval) {
			// do not do anything if there is nothing to merge
			if len(overlapping) == 1 do continue

			// get total range
			start_offset, _ := store_interval(overlapping[0])
			_, end_offset := store_interval(overlapping[len(overlapping) - 1])

			// NOTE: currently, the overlap will always extend to a regular bit width (multiple of the character size)
			// but it is possible that in reality, it should be a non-regular bit width

			// create the merged integer literal
			int_big := big.Int{}
			for store in overlapping {
				size := sb.type_size(store.int_value.integer.int_type)
				start := store.ptr_offset - start_offset
				if sb.graph().target.endian == .Big {
					start = end_offset - store.ptr_offset - u32(size)
				}

				// NOTE: this will do a bitwise OR when encountering overlapping stores
				// in reality, overlapping stores SHOULD not occur
				// perhaps we can check for this and give a poison value
				if store.int_value.integer.int_big == nil {
					value := store.int_value.integer.int_literal
					big_bitfield_or(
						&int_big,
						int(start) * int(char_bits),
						int(size) * int(char_bits),
						big._WORD(value),
					)
				} else {
					shifted := big.Int{}
					defer big.destroy(&shifted)

					big.copy(&shifted, store.int_value.integer.int_big)
					big.shl(&shifted, &shifted, int(start) * int(char_bits))
					big.bit_or(&int_big, &int_big, &shifted)
				}
			}

			// create integer literal node
			// FIXME: this can overflow!
			int_size := u16(end_offset - start_offset) * char_bits
			int_node := sb.push(sb.node_constant(sb.type_int(int_size), int_big))

			// create ptr member access node
			ptr_edge := origin
			ptr_node := origin.node
			if sb.node_type(ptr_node) == .Local {
				ptr_edge.output = 1
			}

			if start_offset != 0 {
				ptr_node = sb.push(sb.node_member_access(ptr_edge, start_offset))
				ptr_edge = sb.Node_Edge{ptr_node, 0}
			}

			// create merged world node
			worlds := make(map[sb.Node_Edge]struct {})
			defer delete(worlds)

			for store in overlapping {
				world := sb.node_parent(sb.node_parent(n, int(store.merge_input)).node, 0)
				worlds[world] = {}
			}

			world_edge: sb.Node_Edge
			if len(worlds) == 1 {
				for edge in worlds {
					world_edge = edge
				}
			} else {
				// TODO: handle error
				keys, err := slice.map_keys(worlds)
				world_edge = {
					sb.push(
						{
							merge = {
								type = .Merge,
								varargs = u32(len(keys)),
								inputs = raw_data(keys),
							},
						},
					),
					0,
				}
			}

			// create merged store node
			store_node := sb.push(sb.node_store(world_edge, ptr_edge, {int_node, 0}))

			// redirect merge inputs to new store
			inputs := sb.node_inputs(n)
			for store in overlapping {
				inputs[int(store.merge_input)] = {store_node, 0}
			}
		}
	}
}

pass_unalias_memory :: proc(n: sb.Node) {
	#partial switch sb.node_type(n) {
	case .Store, .Load, .End:
	case:
		return
	}

	if parent, ok := simple_memory_parent(n).?; ok {
		if do_nodes_alias(n, parent) do return

		// This node has a parent it does not alias with
		// i.e. these two nodes could be swapped without issue
		// so we make these nodes parallel and add a Merge node

		// first, find the first aliasing ancestor
		ancestor := parent
		for {
			if parent, ok := simple_memory_parent(ancestor).?; ok {
				ancestor = parent
				if do_nodes_alias(n, ancestor) do break
			} else {
				break
			}
		}

		// reparent node to that ancestor
		inputs := sb.node_inputs(n)
		old_parent := sb.canonical_edge(inputs[0]).node
		inputs[0].node = ancestor

		if sb.node_output_type(n, 0) == sb.type_memory() {

			// move node, create passthrough
			new_n := sb.push(sb.graph().nodes[int(n)])
			sb.graph().nodes[int(n)] = sb.node_pass(sb.node_outputs(new_n))

			if sb.node_type(old_parent) == .Merge {
				// if our old parent was a merge node, output to there
				old_inputs := sb.node_inputs(old_parent)
				new_inputs := make([]sb.Node_Edge, len(old_inputs) + 1)

				for edge, i in old_inputs do new_inputs[i] = edge
				new_inputs[len(old_inputs)] = {new_n, 0}

				sb.node_data(old_parent).merge.inputs = raw_data(new_inputs)
				sb.node_data(old_parent).merge.varargs += 1
				delete(old_inputs)

				sb.node_inputs(n)[0].node = old_parent
			} else {
				// else, create a new merge node,
				// with the current and old parent node pointing there
				merge := sb.push(sb.node_merge({{old_parent, 0}, {new_n, 0}}))
				sb.node_inputs(n)[0].node = merge
			}
		}
	}
}

pass_poison_read :: proc(n: sb.Node) {
	if sb.node_type(n) != .Load do return

	if parent, ok := simple_memory_parent(n).?; ok {
		if sb.node_type(parent) == .Local {
			// We read directly after declaring a local,
			// *before* writing anything to it
			// this is a poison read
			type := sb.node_output_type(n, 0).?
			sb.node_destroy(sb.node_data(n)^)
			sb.node_data(n)^ = sb.node_poison(type)
		}
	}
}
