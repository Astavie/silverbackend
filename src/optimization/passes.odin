package optimization

import sb "../graph"
import "core:math"
import "core:math/big"
import "core:mem"
import "core:slice"

// GLOBAL PASSES

perform_remove_dead :: proc() {
	g := sb.graph()

	// TODO: Remove unused functions

	// Find all nodes that are ancestors of End nodes
	// These do not include Start, End, or Pass nodes
	ancestors := make(map[sb.Node]struct {})
	defer delete(ancestors)

	add_ancestors :: proc(ancestors: ^map[sb.Node]struct {}, node: sb.Node) {
		inputs := len(sb.node_inputs(node))
		for i := 0; i < inputs; i += 1 {
			parent := sb.node_parent(node, i).node
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
			varargs := g.nodes[i].pass.varargs
			if varargs > 0 {
				// check if no inputs are End ancestors
				// if so, this Pass node may also be destroyed
				all_empty := true
				for j: u32 = 0; j < varargs; j += 1 {
					if sb.canonical_edge({node = sb.Node(i), output = j}).node in ancestors {
						all_empty = false
						break
					}
				}
				if all_empty {
					sb.node_destroy(g.nodes[i])
					g.nodes[i] = sb.node_nil()
				}
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

	// NOTE: a simple slice might be faster than map?
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

	// NOTE: this might be optimized using an Interval tree or a Segment tree?

	ConstantStore :: struct {
		merge_input: u32,
		ptr_offset:  u32,
		int_value:   ^sb.Node_Data,
	}

	// map from "ptr origin" -> "constant stores"
	// NOTE: a simple slice might be faster than map?
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

		// sort by starting offset
		slice.sort_by_key(constants[:], proc(c: ConstantStore) -> u32 {return c.ptr_offset})

		current := 0
		next := 1

		for current < len(constants) {
			from_offset := constants[current].ptr_offset

			int_value := constants[current].int_value
			div, to_bits := math.divmod(int_value.integer.int_type.integer.bits, char_bits)
			to_offset := from_offset + u32(div)

			// create u16 buffer
			// NOTE: this does not support targets with char size bigger than 16 bits
			buf := make([dynamic]u16)
			defer delete(buf)

			populate_int_buffer(&buf, int_value, 0)

			// merge following stores
			for next < len(constants) {
				offset := constants[next].ptr_offset
				if offset <= to_offset {
					defer next += 1

					int_value2 := constants[next].int_value
					div2, to_bits2 := math.divmod(
						int_value2.integer.int_type.integer.bits,
						char_bits,
					)
					to_offset2 := offset + u32(div2)

					if to_offset2 > to_offset {
						to_offset = to_offset2
						to_bits2 = to_bits
					} else if to_bits2 > to_bits {
						to_bits2 = to_bits
					}

					// FIXME: this can overflow!
					populate_int_buffer(&buf, int_value2, u16(offset - from_offset))
				} else {
					break
				}
			}

			defer current = next

			// get integer literal
			int_big := big.Int{}
			switch sb.graph().target.endian {
			case .Little:
				slice.reverse(buf[:])
				for i in buf {
					big.int_shl(&int_big, &int_big, int(char_bits))
					big.int_add_digit(&int_big, &int_big, big.DIGIT(i))
				}
			case .Big:
				for i, idx in buf {
					if to_bits > 0 && idx == len(buf) - 1 {
						big.int_shl(&int_big, &int_big, int(to_bits))
					} else {
						big.int_shl(&int_big, &int_big, int(char_bits))
					}
					big.int_add_digit(&int_big, &int_big, big.DIGIT(i))
				}
			}

			// FIXME: this can overflow!
			int_size := u16(to_offset - from_offset) * char_bits + to_bits
			int_node := sb.push(sb.node_constant(sb.type_int(int_size), int_big))

			// create offset pointer
			ptr_edge := origin
			ptr_node := origin.node
			if sb.node_type(ptr_node) == .Local {
				ptr_edge.output = 1
			}

			if from_offset != 0 {
				ptr_node = sb.push(sb.node_member_access(ptr_edge, from_offset))
				ptr_edge = sb.Node_Edge{ptr_node, 0}
			}

			// create merged world
			// NOTE: a simple slice might be faster than map?
			worlds := make(map[sb.Node_Edge]struct {})
			defer delete(worlds)

			for i in current ..< next {
				world := sb.node_parent(sb.node_parent(n, int(constants[i].merge_input)).node, 0)
				worlds[world] = {}
			}

			world_edge: sb.Node_Edge
			if len(worlds) == 1 {
				for edge in worlds {
					world_edge = edge
				}
			} else {
				// make allocator error optional
				map_keys :: proc(
					m: $M/map[$K]$V,
					allocator := context.allocator,
				) -> (
					keys: []K,
					err: mem.Allocator_Error,
				) #optional_allocator_error {
					return slice.map_keys(m, allocator)
				}

				keys := map_keys(worlds)
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

			// create store
			store_node := sb.push(sb.node_store(world_edge, ptr_edge, {int_node, 0}))

			// redirect merge inputs to new store
			inputs := sb.node_inputs(n)
			for i in current ..< next {
				inputs[int(constants[i].merge_input)] = {store_node, 0}
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
