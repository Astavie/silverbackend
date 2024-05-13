package graph

import "core:mem"
import "core:slice"

Function :: distinct u32
Function_Data :: struct {
	inputs:  []Data_Type,
	outputs: []Data_Type,
	start:   Node,
	end:     Node,
	symbol:  Symbol,
}

Linkage :: enum {
	Internal,
	External,
}

Symbol :: struct {
	name:    string,
	linkage: Linkage,
}

start_function :: proc(
	inputs: []Data_Type,
	outputs: []Data_Type,
	symbol: Symbol = {linkage = .Internal},
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	fun: Function,
	err: mem.Allocator_Error,
) #optional_allocator_error {
	g := graph()
	fun = Function(len(g.functions))

	inputs := slice.clone(inputs, allocator, loc)
	outputs := slice.clone(outputs, allocator, loc)

	start := Node(len(g.nodes))
	append(&g.nodes, node_start(fun)) or_return
	append(
		&g.functions,
		Function_Data{inputs = inputs, outputs = outputs, start = start, symbol = symbol},
	) or_return

	return
}

end_function :: proc(
	fun: Function,
	outputs: []Node_Edge,
	allocator := context.allocator,
	loc := #caller_location,
) -> mem.Allocator_Error {
	g := graph()

	node := push(node_end(fun, outputs, allocator, loc) or_return) or_return
	g.functions[int(fun)].end = node

	return .None
}

function_is_constant :: proc(function: Function) -> bool {
	data := graph().functions[int(function)]
	return !node_is_ancestor(data.end, data.start)
}

function_graph_order :: proc(
	function: Function,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	slice: []Node,
	err: mem.Allocator_Error,
) #optional_allocator_error {
	nodes := make([dynamic]Node) or_return

	seen := make(map[Node]struct {}, allocator = allocator, loc = loc) or_return
	defer delete(seen)

	visit :: proc(
		node: Node,
		seen: ^map[Node]struct {},
		nodes: ^[dynamic]Node,
		loc := #caller_location,
	) -> mem.Allocator_Error {
		if (node in seen) do return nil

		for edge in node_inputs(node) {
			visit(edge.node, seen, nodes, loc) or_return
		}

		reserve(seen, len(seen) + 1, loc) or_return
		seen[node] = {}

		append(nodes, node, loc) or_return

		return nil
	}

	visit(graph().functions[int(function)].end, &seen, &nodes, loc) or_return

	return nodes[:], nil
}
