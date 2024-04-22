package opt

import "../sb"

// GLOBAL PASSES

perform_remove_dead :: proc() {
	graph := sb.backend()

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

	for function in graph.functions {
		add_ancestors(&ancestors, function.end)
	}

	// Remove all non-ancestors
	for i := 0; i < len(graph.nodes); i += 1 {
		#partial switch graph.nodes[i].base.type {
		case .Start, .End: // do nothing
		case .Pass:
			varargs := graph.nodes[i].pass.varargs
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
					sb.node_destroy(graph.nodes[i])
					graph.nodes[i] = sb.node_nil()
				}
			}
		case:
			if !(sb.Node(i) in ancestors) {
				sb.node_destroy(graph.nodes[i])
				graph.nodes[i] = sb.node_nil()
			}
		}
	}
}

// PER-NODE PASSES

perform_pass :: proc(pass: #type proc(n: sb.Node)) {
	for i := 0; i < len(sb.backend().nodes); i += 1 {
		pass(sb.Node(i))
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
			new_n := sb.push(sb.backend().nodes[int(n)])
			sb.backend().nodes[int(n)] = sb.node_pass(sb.node_outputs(new_n))

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
